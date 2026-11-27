begin;

create table public.teacher_profiles (
    user_id uuid primary key references auth.users(id) on delete cascade
);
create table public.kiosk_classes (
    class_code text primary key check (length(btrim(class_code)) between 1 and 255)
);
create table public.teacher_class_assignments (
    user_id uuid references public.teacher_profiles on delete cascade,
    class_code text references public.kiosk_classes on delete cascade,
    primary key (user_id, class_code)
);

alter table public.usage_logs
    add column student_id text check (length(btrim(student_id)) between 1 and 255),
    add column pc_name text,
    add column usage_duration_seconds integer check (usage_duration_seconds >= 0),
    add column report_date date,
    add column created_at timestamptz not null default clock_timestamp(),
    add column updated_at timestamptz not null default clock_timestamp(),
    add column deleted_at timestamptz;
alter table public.pc_activity_logs
    add column student_id text,
    add column class_code text,
    add column report_date date,
    add column created_at timestamptz not null default clock_timestamp(),
    add column updated_at timestamptz not null default clock_timestamp(),
    add column deleted_at timestamptz;

create function kiosk_private.institution_date(epoch_ms bigint)
returns date language sql immutable set search_path = ''
as $$ select (to_timestamp(epoch_ms / 1000.0) at time zone 'Asia/Kolkata')::date $$;

update public.usage_logs set report_date = kiosk_private.institution_date("timestamp");
update public.pc_activity_logs set report_date = kiosk_private.institution_date("timestamp");
alter table public.usage_logs alter column report_date set not null;
alter table public.pc_activity_logs alter column report_date set not null;

create table public.daily_summary (
    id uuid primary key default gen_random_uuid(),
    report_date date not null,
    student_id text not null,
    student_name text,
    class_code text not null,
    app_name text not null,
    process_name text not null,
    total_usage_seconds bigint,
    total_open_count bigint not null,
    total_blocked_count bigint not null,
    created_at timestamptz not null default clock_timestamp(),
    updated_at timestamptz not null default clock_timestamp(),
    deleted_at timestamptz,
    unique (report_date, student_id, class_code, process_name)
);

create index usage_logs_sync_idx on public.usage_logs (class_code, report_date, updated_at, id);
create index pc_activity_logs_sync_idx on public.pc_activity_logs (class_code, report_date, updated_at, id);
create index daily_summary_sync_idx on public.daily_summary (class_code, report_date, updated_at, id);
create index usage_logs_student_idx on public.usage_logs (student_id, "timestamp") where student_id is not null;
create index pc_activity_logs_student_idx on public.pc_activity_logs (student_id, "timestamp") where student_id is not null;
create index daily_summary_date_idx on public.daily_summary (report_date, class_code);

alter table public.teacher_profiles enable row level security;
alter table public.kiosk_classes enable row level security;
alter table public.teacher_class_assignments enable row level security;
alter table public.daily_summary enable row level security;

revoke all on public.teacher_profiles, public.kiosk_classes, public.teacher_class_assignments,
    public.daily_summary from public, anon, authenticated;
grant select on public.teacher_profiles, public.kiosk_classes, public.teacher_class_assignments,
    public.usage_logs, public.pc_activity_logs, public.daily_summary to authenticated;

create policy own_teacher_profile on public.teacher_profiles for select to authenticated
    using (user_id = (select auth.uid()));
create policy own_class_assignments on public.teacher_class_assignments for select to authenticated
    using (user_id = (select auth.uid()));
create policy assigned_classes on public.kiosk_classes for select to authenticated
    using (class_code in (select a.class_code from public.teacher_class_assignments a));
create policy teacher_usage_reads on public.usage_logs for select to authenticated
    using (class_code in (select a.class_code from public.teacher_class_assignments a));
create policy teacher_activity_reads on public.pc_activity_logs for select to authenticated
    using (class_code in (select a.class_code from public.teacher_class_assignments a));
create policy teacher_summary_reads on public.daily_summary for select to authenticated
    using (class_code in (select a.class_code from public.teacher_class_assignments a));

-- The singleton row serializes timestamp assignment through commit. A reader
-- sees only the last committed watermark, including when a writer is in flight.
create table kiosk_private.reporting_clock (
    singleton boolean primary key default true check (singleton),
    last_update timestamptz not null
);
insert into kiosk_private.reporting_clock (last_update)
select greatest(clock_timestamp(),
    (select max(updated_at) from public.usage_logs),
    (select max(updated_at) from public.pc_activity_logs));

create table kiosk_private.dirty_daily_reports (
    report_date date not null,
    class_code text not null,
    primary key (report_date, class_code)
);

alter table kiosk_private.reporting_clock enable row level security;
alter table kiosk_private.dirty_daily_reports enable row level security;

create function kiosk_private.stamp_report_change()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
    if tg_table_name <> 'daily_summary' then
        new.report_date := kiosk_private.institution_date(new."timestamp");
    end if;
    if tg_op = 'UPDATE' then
        if new.id is distinct from old.id or new.class_code is distinct from old.class_code
           or new.report_date is distinct from old.report_date then
            raise exception 'Move records by tombstoning the old record and inserting a new one';
        end if;
        new.created_at := old.created_at;
    else
        new.created_at := clock_timestamp();
    end if;

    update kiosk_private.reporting_clock
    set last_update = greatest(clock_timestamp(), last_update + interval '1 microsecond')
    where singleton returning last_update into new.updated_at;

    if tg_table_name <> 'daily_summary' and new.class_code is not null and new.student_id is not null then
        insert into kiosk_private.dirty_daily_reports values (new.report_date, new.class_code)
        on conflict do nothing;
    elsif tg_table_name <> 'daily_summary' and tg_op = 'UPDATE'
          and old.class_code is not null and old.student_id is not null then
        insert into kiosk_private.dirty_daily_reports values (old.report_date, old.class_code)
        on conflict do nothing;
    end if;
    return new;
end;
$$;

create trigger usage_report_changes before insert or update on public.usage_logs
for each row execute function kiosk_private.stamp_report_change();
create trigger pc_report_changes before insert or update on public.pc_activity_logs
for each row execute function kiosk_private.stamp_report_change();
create trigger summary_report_changes before insert or update on public.daily_summary
for each row execute function kiosk_private.stamp_report_change();

create function public.kiosk_reporting_watermark()
returns timestamptz language sql stable security definer set search_path = ''
as $$
    select last_update from kiosk_private.reporting_clock
    where singleton and exists (
        select 1 from public.teacher_profiles where user_id = auth.uid()
    )
$$;
revoke all on function public.kiosk_reporting_watermark() from public, anon, authenticated;
grant execute on function public.kiosk_reporting_watermark() to authenticated;

create function public.kiosk_teacher_access()
returns jsonb language sql stable security invoker set search_path = ''
as $$
    select jsonb_build_object('classes', coalesce(
        (select jsonb_agg(class_code order by class_code) from public.teacher_class_assignments),
        '[]'::jsonb))
    where exists (select 1 from public.teacher_profiles)
$$;
revoke all on function public.kiosk_teacher_access() from public, anon, authenticated;
grant execute on function public.kiosk_teacher_access() to authenticated;

create or replace function public.record_usage_log(p_event jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
declare enrolled_pc text;
begin
    select pc_name into enrolled_pc from kiosk_private.kiosks
    where user_id = auth.uid() and (p_event->>'class_code') = any(class_codes);
    if not found then
        raise exception 'Kiosk is not enrolled for this class' using errcode = '42501';
    end if;

    insert into public.usage_logs (id, class_code, pc_name, student_id, app_name, process_name,
                                   student_log, student_name, "timestamp")
    values ((p_event->>'id')::uuid, p_event->>'class_code', enrolled_pc, p_event->>'student_id',
            p_event->>'app_name', p_event->>'process_name', p_event->>'student_log',
            p_event->>'student_name', (p_event->>'timestamp')::bigint)
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
begin
    select pc_name, case when requested_class = any(class_codes) then requested_class end
    into enrolled_pc, enrolled_class from kiosk_private.kiosks
    where user_id = auth.uid() and pc_name = p_event->>'pc_name';
    if not found then
        raise exception 'Kiosk is not enrolled for this PC' using errcode = '42501';
    end if;

    insert into public.pc_activity_logs (id, class_code, student_id, pc_name, app_name, process_name,
                                         action, "timestamp")
    values ((p_event->>'id')::uuid, enrolled_class,
            case when enrolled_class is not null then p_event->>'student_id' end,
            enrolled_pc, p_event->>'app_name', p_event->>'process_name',
            p_event->>'action', (p_event->>'timestamp')::bigint)
    on conflict (id) do nothing;
end;
$$;

create function public.record_kiosk_events(p_events jsonb)
returns void language plpgsql security invoker set search_path = ''
as $$
declare event jsonb;
begin
    if jsonb_typeof(p_events) is distinct from 'array' or jsonb_array_length(p_events) not between 1 and 32 then
        raise exception 'Expected between 1 and 32 kiosk events' using errcode = '22023';
    end if;
    for event in select value from jsonb_array_elements(p_events) loop
        case event->>'kind'
            when 'usage' then perform public.record_usage_log(event->'fields');
            when 'activity' then perform public.record_pc_activity(event->'fields');
            else raise exception 'Invalid kiosk event kind' using errcode = '22023';
        end case;
    end loop;
end;
$$;
revoke all on function public.record_kiosk_events(jsonb) from public, anon, authenticated;
grant execute on function public.record_kiosk_events(jsonb) to authenticated;

-- Maintenance uses logical deletes so incremental readers receive tombstones.
create function kiosk_private.require_report_tombstone()
returns trigger language plpgsql set search_path = ''
as $$
begin
    raise exception 'Set deleted_at to send a tombstone to cached dashboards';
end;
$$;
create trigger usage_report_tombstones before delete or truncate on public.usage_logs
for each statement execute function kiosk_private.require_report_tombstone();
create trigger pc_report_tombstones before delete or truncate on public.pc_activity_logs
for each statement execute function kiosk_private.require_report_tombstone();
create trigger summary_report_tombstones before delete or truncate on public.daily_summary
for each statement execute function kiosk_private.require_report_tombstone();

create function kiosk_private.refresh_daily_reports(p_limit integer default 10)
returns integer language plpgsql security definer set search_path = ''
as $$
declare
    job record;
    processed integer := 0;
begin
    -- Match the ingestion lock order. Each job is restricted to one class/date.
    perform 1 from kiosk_private.reporting_clock where singleton for update;
    for job in
        select report_date, class_code from kiosk_private.dirty_daily_reports
        order by report_date, class_code limit greatest(1, least(p_limit, 20))
    loop
        with events as (
            select student_id, student_name, app_name, lower(process_name) as process_name,
                   usage_duration_seconds as seconds, 1 as opens, 0 as blocks, updated_at
            from public.usage_logs
            where report_date = job.report_date and class_code = job.class_code
                  and deleted_at is null and student_id is not null
            union all
            select student_id, null, app_name, lower(process_name), null, 0, 1, updated_at
            from public.pc_activity_logs
            where report_date = job.report_date and class_code = job.class_code
                  and deleted_at is null and student_id is not null and action = 'BLOCKED'
        ), totals as materialized (
            select student_id, process_name,
                   (array_agg(student_name order by updated_at desc, student_name)
                       filter (where student_name is not null))[1] as student_name,
                   (array_agg(app_name order by updated_at desc, app_name))[1] as app_name,
                   sum(seconds) as seconds, sum(opens) as opens, sum(blocks) as blocks
            from events group by student_id, process_name
        ), upserted as (
            insert into public.daily_summary as existing
                (report_date, class_code, student_id, student_name, app_name, process_name,
                 total_usage_seconds, total_open_count, total_blocked_count)
            select job.report_date, job.class_code, student_id, student_name, app_name,
                   process_name, seconds, opens, blocks from totals
            on conflict (report_date, student_id, class_code, process_name) do update
            set student_name = excluded.student_name, app_name = excluded.app_name,
                total_usage_seconds = excluded.total_usage_seconds,
                total_open_count = excluded.total_open_count,
                total_blocked_count = excluded.total_blocked_count, deleted_at = null
            where (existing.student_name, existing.app_name, existing.total_usage_seconds,
                   existing.total_open_count, existing.total_blocked_count, existing.deleted_at)
                is distinct from (excluded.student_name, excluded.app_name, excluded.total_usage_seconds,
                                  excluded.total_open_count, excluded.total_blocked_count, excluded.deleted_at)
            returning id
        )
        update public.daily_summary s set deleted_at = clock_timestamp()
        where s.report_date = job.report_date and s.class_code = job.class_code and s.deleted_at is null
              and not exists (select 1 from totals t
                              where t.student_id = s.student_id and t.process_name = s.process_name);

        delete from kiosk_private.dirty_daily_reports
        where report_date = job.report_date and class_code = job.class_code;
        processed := processed + 1;
    end loop;
    return processed;
end;
$$;
revoke all on function kiosk_private.refresh_daily_reports(integer) from public, anon, authenticated;

commit;
