begin;

create schema kiosk_private;
revoke all on schema kiosk_private from public, anon, authenticated;

create table kiosk_private.kiosks (
    user_id uuid primary key references auth.users(id) on delete cascade,
    pc_name text not null unique check (length(btrim(pc_name)) between 1 and 255),
    class_codes text[] not null default '{}'
);
alter table kiosk_private.kiosks enable row level security;
revoke all on kiosk_private.kiosks from public, anon, authenticated;

create table public.usage_logs (
    id uuid primary key default gen_random_uuid(),
    class_code text not null check (length(btrim(class_code)) between 1 and 255),
    app_name text not null check (length(app_name) between 1 and 255),
    process_name text not null check (length(process_name) between 1 and 255),
    student_log text not null check (length(student_log) between 1 and 512),
    student_name text not null check (length(btrim(student_name)) between 1 and 255),
    "timestamp" bigint not null check ("timestamp" >= 0)
);

create table public.pc_activity_logs (
    id uuid primary key default gen_random_uuid(),
    pc_name text not null check (length(btrim(pc_name)) between 1 and 255),
    app_name text not null check (length(app_name) between 1 and 255),
    process_name text not null check (length(process_name) between 1 and 255),
    action text not null check (action in ('OPENED', 'BLOCKED')),
    "timestamp" bigint not null check ("timestamp" >= 0)
);

create index usage_logs_class_time_idx on public.usage_logs (class_code, "timestamp" desc);
create index pc_activity_logs_pc_time_idx on public.pc_activity_logs (pc_name, "timestamp" desc);

alter table public.usage_logs enable row level security;
alter table public.pc_activity_logs enable row level security;
revoke all on public.usage_logs, public.pc_activity_logs from public, anon, authenticated;
-- RLS denies direct access for API roles. The write functions enforce enrollment.

create function public.record_usage_log(p_event jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
begin
    if not exists (
        select 1 from kiosk_private.kiosks
        where user_id = auth.uid() and (p_event->>'class_code') = any(class_codes)
    ) then
        raise exception 'Kiosk is not enrolled for this class' using errcode = '42501';
    end if;

    insert into public.usage_logs (id, class_code, app_name, process_name, student_log, student_name, "timestamp")
    values ((p_event->>'id')::uuid, p_event->>'class_code', p_event->>'app_name',
            p_event->>'process_name', p_event->>'student_log', p_event->>'student_name',
            (p_event->>'timestamp')::bigint)
    on conflict (id) do nothing;
end;
$$;

create function public.record_pc_activity(p_event jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
begin
    if not exists (
        select 1 from kiosk_private.kiosks
        where user_id = auth.uid() and pc_name = (p_event->>'pc_name')
    ) then
        raise exception 'Kiosk is not enrolled for this PC' using errcode = '42501';
    end if;

    insert into public.pc_activity_logs (id, pc_name, app_name, process_name, action, "timestamp")
    values ((p_event->>'id')::uuid, p_event->>'pc_name', p_event->>'app_name',
            p_event->>'process_name', p_event->>'action', (p_event->>'timestamp')::bigint)
    on conflict (id) do nothing;
end;
$$;

revoke all on function public.record_usage_log(jsonb), public.record_pc_activity(jsonb)
    from public, anon, authenticated;
grant execute on function public.record_usage_log(jsonb), public.record_pc_activity(jsonb)
    to authenticated;

commit;
