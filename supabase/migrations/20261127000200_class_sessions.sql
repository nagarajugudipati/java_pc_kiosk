begin;

alter table public.kiosk_classes
    add column owner_id uuid references public.teacher_profiles(user_id),
    add column class_name text check (length(btrim(class_name)) between 1 and 120),
    add column subject text check (length(subject) <= 120);

create table kiosk_private.class_sessions (
    id uuid primary key default gen_random_uuid(),
    class_code text not null references public.kiosk_classes,
    join_code text not null unique default upper(left(replace(gen_random_uuid()::text, '-', ''), 12)),
    started_at timestamptz not null default statement_timestamp(),
    expires_at timestamptz not null default (statement_timestamp() + interval '3 hours'),
    ended_at timestamptz,
    app_mode text not null default 'BLOCKLIST' check (app_mode in ('BLOCKLIST', 'ALLOWLIST')),
    policy_version bigint not null default 0
);
create unique index kiosk_one_open_class on kiosk_private.class_sessions(class_code) where ended_at is null;

create table kiosk_private.student_sessions (
    id uuid primary key default gen_random_uuid(),
    session_id uuid not null references kiosk_private.class_sessions,
    device_id uuid not null references kiosk_private.kiosks(user_id) on delete cascade,
    student_name text not null check (length(btrim(student_name)) between 1 and 120),
    roll_number text not null check (length(btrim(roll_number)) between 1 and 80),
    joined_at timestamptz not null default statement_timestamp(),
    left_at timestamptz,
    last_seen timestamptz not null default statement_timestamp(),
    applied_version bigint,
    application_status text not null default 'PENDING'
        check (application_status in ('PENDING', 'APPLIED', 'FAILED'))
);
create unique index kiosk_one_student_per_pc on kiosk_private.student_sessions(device_id) where left_at is null;
create index kiosk_session_students on kiosk_private.student_sessions(session_id, last_seen desc);

alter table public.usage_logs
    add column class_session_id uuid references kiosk_private.class_sessions,
    add column student_session_id uuid references kiosk_private.student_sessions;
alter table public.pc_activity_logs
    add column class_session_id uuid references kiosk_private.class_sessions,
    add column student_session_id uuid references kiosk_private.student_sessions;

create table kiosk_private.join_attempts (
    device_id uuid primary key references kiosk_private.kiosks(user_id) on delete cascade,
    window_start timestamptz not null,
    attempts integer not null
);
create table kiosk_private.app_rules (
    session_id uuid not null references kiosk_private.class_sessions,
    scope text not null check (scope in ('CLASS', 'DEVICE', 'STUDENT')),
    target_id uuid not null,
    process_name text not null check (process_name ~ '^[a-z0-9][a-z0-9_. -]{0,119}[.]exe$'),
    blocked boolean not null,
    primary key (session_id, scope, target_id, process_name)
);
create table kiosk_private.policy_audit (
    id bigint generated always as identity primary key,
    session_id uuid not null references kiosk_private.class_sessions,
    actor_id uuid not null references public.teacher_profiles(user_id),
    changed_at timestamptz not null default statement_timestamp(),
    version bigint not null,
    scope text not null,
    target_id uuid not null,
    process_name text,
    blocked boolean,
    app_mode text,
    check ((process_name is not null and blocked is not null and app_mode is null)
        or (process_name is null and blocked is null and app_mode in ('BLOCKLIST', 'ALLOWLIST')))
);

alter table kiosk_private.class_sessions enable row level security;
alter table kiosk_private.student_sessions enable row level security;
alter table kiosk_private.join_attempts enable row level security;
alter table kiosk_private.app_rules enable row level security;
alter table kiosk_private.policy_audit enable row level security;
revoke all on all tables in schema kiosk_private from public, anon, authenticated;

create function public.kiosk_create_class(p_name text, p_subject text)
returns text language plpgsql security definer set search_path = ''
as $$
declare code text := gen_random_uuid()::text;
begin
    if not exists (select 1 from public.teacher_profiles where user_id = auth.uid()) then
        raise exception 'Teacher profile required' using errcode = '42501';
    end if;
    insert into public.kiosk_classes (class_code, owner_id, class_name, subject)
    values (code, auth.uid(), nullif(btrim(p_name), ''), btrim(p_subject));
    if nullif(btrim(p_name), '') is null then
        raise exception 'Class name required' using errcode = '22023';
    end if;
    insert into public.teacher_class_assignments values (auth.uid(), code);
    return code;
end;
$$;

create function public.kiosk_start_class(p_class text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare result uuid;
begin
    perform 1 from public.kiosk_classes where class_code = p_class and owner_id = auth.uid() for update;
    if not found then raise exception 'Class owner required' using errcode = '42501'; end if;
    update kiosk_private.class_sessions set ended_at = expires_at
    where class_code = p_class and ended_at is null and expires_at <= statement_timestamp();
    select id into result from kiosk_private.class_sessions where class_code = p_class and ended_at is null;
    if result is null then
        insert into kiosk_private.class_sessions (class_code) values (p_class) returning id into result;
    end if;
    return result;
end;
$$;

create function public.kiosk_end_class(p_session uuid)
returns void language plpgsql security definer set search_path = ''
as $$
begin
    update kiosk_private.class_sessions s set ended_at = least(s.expires_at, statement_timestamp())
    from public.kiosk_classes c where s.id = p_session and c.class_code = s.class_code
        and c.owner_id = auth.uid() and s.ended_at is null;
    if not found then raise exception 'Active owned session required' using errcode = '42501'; end if;
    update kiosk_private.student_sessions set left_at = statement_timestamp()
    where session_id = p_session and left_at is null;
end;
$$;

create function public.kiosk_join_class(p_code text, p_name text, p_roll text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
    device kiosk_private.kiosks%rowtype;
    class_session kiosk_private.class_sessions%rowtype;
    guesses integer;
    result uuid;
begin
    select * into device from kiosk_private.kiosks where user_id = auth.uid() for update;
    if not found then raise exception 'Registered device required' using errcode = '42501'; end if;
    insert into kiosk_private.join_attempts as existing values (device.user_id, statement_timestamp(), 1)
    on conflict (device_id) do update
    set attempts = case when existing.window_start <= statement_timestamp() - interval '5 minutes'
                        then 1 else least(existing.attempts + 1, 9) end,
        window_start = case when existing.window_start <= statement_timestamp() - interval '5 minutes'
                            then statement_timestamp() else existing.window_start end
    returning attempts into guesses;
    if guesses > 8 then return jsonb_build_object('error', 'Too many attempts. Try again later.'); end if;
    if coalesce(length(btrim(p_name)), 0) not between 1 and 120
        or coalesce(length(btrim(p_roll)), 0) not between 1 and 80 then
        return jsonb_build_object('error', 'Enter a student name and roll number.');
    end if;
    select * into class_session from kiosk_private.class_sessions
    where join_code = upper(btrim(p_code)) and class_code = any(device.class_codes)
        and ended_at is null and expires_at > statement_timestamp() for share;
    if not found then return jsonb_build_object('error', 'This code is unavailable on this computer.'); end if;

    update kiosk_private.student_sessions set left_at = statement_timestamp()
    where device_id = device.user_id and left_at is null;
    insert into kiosk_private.student_sessions (session_id, device_id, student_name, roll_number)
    values (class_session.id, device.user_id, btrim(p_name), btrim(p_roll)) returning id into result;
    delete from kiosk_private.join_attempts where device_id = device.user_id;
    return jsonb_build_object('student_session', result, 'class_code', class_session.class_code);
end;
$$;

create function public.kiosk_heartbeat(p_student uuid, p_applied bigint, p_status text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
    selected kiosk_private.student_sessions%rowtype;
    active kiosk_private.class_sessions%rowtype;
    blocked jsonb;
begin
    select * into selected from kiosk_private.student_sessions
    where id = p_student and device_id = auth.uid() and left_at is null;
    if not found then return jsonb_build_object('active', false); end if;
    select * into active from kiosk_private.class_sessions
    where id = selected.session_id and ended_at is null and expires_at > statement_timestamp()
        and exists (select 1 from kiosk_private.kiosks k
                    where k.user_id = auth.uid() and class_code = any(k.class_codes))
    for share;
    if not found then return jsonb_build_object('active', false); end if;
    update kiosk_private.student_sessions
    set last_seen = statement_timestamp(),
        applied_version = case when p_applied between 0 and active.policy_version then p_applied end,
        application_status = case when p_status in ('APPLIED', 'FAILED') then p_status else 'PENDING' end
    where id = selected.id and left_at is null;
    if not found then return jsonb_build_object('active', false); end if;

    if p_applied is distinct from active.policy_version or p_status is distinct from 'APPLIED' then
        select coalesce(jsonb_agg(process_name), '[]'::jsonb) into blocked from (
            select distinct on (process_name) process_name, r.blocked
            from kiosk_private.app_rules r where r.session_id = active.id and (
                (scope = 'CLASS' and target_id = active.id) or
                (scope = 'DEVICE' and target_id = selected.device_id) or
                (scope = 'STUDENT' and target_id = selected.id))
            order by process_name, case scope when 'STUDENT' then 1 when 'DEVICE' then 2 else 3 end
        ) effective where effective.blocked = (active.app_mode = 'BLOCKLIST');
    end if;
    return jsonb_build_object('active', true, 'version', active.policy_version, 'mode', active.app_mode,
        'blocked', blocked,
        'lease_seconds', floor(extract(epoch from least(interval '2 minutes',
            active.expires_at - statement_timestamp()))));
end;
$$;

create function public.kiosk_leave_class(p_student uuid)
returns void language sql security definer set search_path = ''
as $$
    update kiosk_private.student_sessions set left_at = statement_timestamp()
    where id = p_student and device_id = auth.uid() and left_at is null
$$;

create function public.kiosk_set_app_rule(p_session uuid, p_scope text, p_target uuid,
                                         p_process text, p_blocked boolean)
returns bigint language plpgsql security definer set search_path = ''
as $$
declare
    target uuid := case when p_scope = 'CLASS' then p_session else p_target end;
    process text := lower(btrim(p_process));
    version bigint;
begin
    update kiosk_private.class_sessions s set policy_version = policy_version + 1
    from public.kiosk_classes c where s.id = p_session and c.class_code = s.class_code
        and c.owner_id = auth.uid() and s.ended_at is null and s.expires_at > statement_timestamp()
    returning s.policy_version into version;
    if not found then raise exception 'Active owned session required' using errcode = '42501'; end if;
    if p_scope = 'STUDENT' and not exists (
        select 1 from kiosk_private.student_sessions where id = target and session_id = p_session and left_at is null
    ) or p_scope = 'DEVICE' and not exists (
        select 1 from kiosk_private.student_sessions where device_id = target and session_id = p_session and left_at is null
    ) then raise exception 'Invalid target for this class' using errcode = '22023'; end if;
    insert into kiosk_private.app_rules values (p_session, p_scope, target, process, p_blocked)
    on conflict (session_id, scope, target_id, process_name) do update set blocked = excluded.blocked;
    insert into kiosk_private.policy_audit (session_id, actor_id, version, scope, target_id, process_name, blocked)
    values (p_session, auth.uid(), version, p_scope, target, process, p_blocked);
    return version;
end;
$$;

create function public.kiosk_class_sessions(p_class text)
returns jsonb language sql stable security definer set search_path = ''
as $$
    select coalesce(jsonb_agg(to_jsonb(s) order by s.started_at desc), '[]'::jsonb)
    from (
        select s.id, s.join_code, s.started_at, s.expires_at, s.ended_at, s.policy_version, s.app_mode,
            (s.ended_at is null and s.expires_at > statement_timestamp()) as active
        from kiosk_private.class_sessions s join public.kiosk_classes c using (class_code)
        where s.class_code = p_class and c.owner_id = auth.uid()
        order by s.started_at desc limit 30
    ) s
$$;

create function public.kiosk_set_app_mode(p_session uuid, p_mode text)
returns bigint language plpgsql security definer set search_path = ''
as $$
declare version bigint;
begin
    update kiosk_private.class_sessions s set app_mode = p_mode, policy_version = policy_version + 1
    from public.kiosk_classes c where s.id = p_session and c.class_code = s.class_code
        and c.owner_id = auth.uid() and s.ended_at is null and s.expires_at > statement_timestamp()
    returning s.policy_version into version;
    if not found then raise exception 'Active owned session required' using errcode = '42501'; end if;
    insert into kiosk_private.policy_audit (session_id, actor_id, version, scope, target_id, app_mode)
    values (p_session, auth.uid(), version, 'CLASS', p_session, p_mode);
    return version;
end;
$$;

create function public.kiosk_class_presence(p_session uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
    select coalesce(jsonb_agg(jsonb_build_object(
        'student_session', d.id, 'device_id', d.device_id, 'pc_name', k.pc_name,
        'student_name', d.student_name, 'roll_number', d.roll_number, 'last_seen', d.last_seen,
        'online', d.left_at is null and d.last_seen > statement_timestamp() - interval '45 seconds'
            and s.ended_at is null and s.expires_at > statement_timestamp(),
        'applied_version', d.applied_version, 'status', d.application_status)
        order by d.last_seen desc), '[]'::jsonb)
    from kiosk_private.student_sessions d join kiosk_private.kiosks k on k.user_id = d.device_id
    join kiosk_private.class_sessions s on s.id = d.session_id join public.kiosk_classes c using (class_code)
    where s.id = p_session and c.owner_id = auth.uid()
$$;

create function kiosk_private.validate_class_event(p_class text, p_event jsonb)
returns kiosk_private.student_sessions language plpgsql stable security definer set search_path = ''
as $$
declare
    result kiosk_private.student_sessions%rowtype;
    event_time timestamptz := to_timestamp((p_event->>'timestamp')::bigint / 1000.0);
begin
    if not exists (select 1 from public.kiosk_classes where class_code = p_class and owner_id is not null) then
        return null;
    end if;
    select d.* into result from kiosk_private.student_sessions d
    join kiosk_private.class_sessions s on s.id = d.session_id
    where d.id = (p_event->>'student_session_id')::uuid and d.device_id = auth.uid()
        and s.class_code = p_class and event_time >= d.joined_at - interval '15 seconds'
        and event_time < least(s.ended_at, s.expires_at, d.left_at, statement_timestamp() + interval '15 seconds');
    if not found then raise exception 'Event is outside the authorized student session' using errcode = '42501'; end if;
    return result;
end;
$$;
revoke all on function kiosk_private.validate_class_event(text,jsonb) from public, anon, authenticated;

create or replace function public.record_usage_log(p_event jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
declare
    requested_class text := p_event->>'class_code';
    enrolled_pc text;
    student kiosk_private.student_sessions%rowtype;
begin
    select pc_name into enrolled_pc from kiosk_private.kiosks
    where user_id = auth.uid() and requested_class = any(class_codes);
    if not found then raise exception 'Kiosk is not enrolled for this class' using errcode = '42501'; end if;
    student := kiosk_private.validate_class_event(requested_class, p_event);
    insert into public.usage_logs (id, class_code, pc_name, student_id, app_name, process_name,
        student_log, student_name, "timestamp", class_session_id, student_session_id)
    values ((p_event->>'id')::uuid, requested_class, enrolled_pc,
        coalesce(student.roll_number, p_event->>'student_id'), p_event->>'app_name', p_event->>'process_name',
        p_event->>'student_log', coalesce(student.student_name, p_event->>'student_name'),
        (p_event->>'timestamp')::bigint, student.session_id, student.id)
    on conflict (id) do nothing;
end;
$$;

create or replace function public.record_pc_activity(p_event jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
declare
    requested_class text := p_event->>'class_code';
    enrolled_class text;
    enrolled_pc text;
    student kiosk_private.student_sessions%rowtype;
begin
    select pc_name, case when requested_class = any(class_codes) then requested_class end
    into enrolled_pc, enrolled_class from kiosk_private.kiosks
    where user_id = auth.uid() and pc_name = p_event->>'pc_name';
    if not found then raise exception 'Kiosk is not enrolled for this PC' using errcode = '42501'; end if;
    student := kiosk_private.validate_class_event(enrolled_class, p_event);
    insert into public.pc_activity_logs (id, class_code, student_id, pc_name, app_name, process_name,
        action, "timestamp", class_session_id, student_session_id)
    values ((p_event->>'id')::uuid, enrolled_class,
        case when enrolled_class is not null then coalesce(student.roll_number, p_event->>'student_id') end,
        enrolled_pc, p_event->>'app_name', p_event->>'process_name', p_event->>'action',
        (p_event->>'timestamp')::bigint, student.session_id, student.id)
    on conflict (id) do nothing;
end;
$$;

revoke all on function public.kiosk_create_class(text,text), public.kiosk_start_class(text),
    public.kiosk_end_class(uuid), public.kiosk_join_class(text,text,text), public.kiosk_heartbeat(uuid,bigint,text),
    public.kiosk_leave_class(uuid), public.kiosk_set_app_rule(uuid,text,uuid,text,boolean),
    public.kiosk_class_sessions(text), public.kiosk_class_presence(uuid), public.kiosk_set_app_mode(uuid,text)
    from public, anon, authenticated;
grant execute on function public.kiosk_create_class(text,text), public.kiosk_start_class(text),
    public.kiosk_end_class(uuid), public.kiosk_join_class(text,text,text), public.kiosk_heartbeat(uuid,bigint,text),
    public.kiosk_leave_class(uuid), public.kiosk_set_app_rule(uuid,text,uuid,text,boolean),
    public.kiosk_class_sessions(text), public.kiosk_class_presence(uuid), public.kiosk_set_app_mode(uuid,text)
    to authenticated;

commit;
