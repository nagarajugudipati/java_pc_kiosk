begin;

create or replace function public.record_usage_log(p_event jsonb)
returns void language plpgsql security definer set search_path = ''
as $$
declare
    requested_class text := p_event->>'class_code';
    enrolled_pc text;
    duration_seconds integer := (p_event->>'usage_duration_seconds')::integer;
    student kiosk_private.student_sessions%rowtype;
    end_time timestamptz;
begin
    select pc_name into enrolled_pc from kiosk_private.kiosks
    where user_id = auth.uid() and requested_class = any(class_codes);
    if not found then raise exception 'Kiosk is not enrolled for this class' using errcode = '42501'; end if;
    student := kiosk_private.validate_class_event(requested_class, p_event);
    if duration_seconds is not null and (student.id is null or duration_seconds not between 0 and 10800) then
        raise exception 'Measured usage requires a valid class session and duration' using errcode = '22023';
    end if;
    if duration_seconds is not null then
        select least(ended_at, expires_at, student.left_at, statement_timestamp()) into end_time
        from kiosk_private.class_sessions where id = student.session_id;
        duration_seconds := least(duration_seconds, greatest(0, floor(extract(epoch from end_time)
            - (p_event->>'timestamp')::bigint / 1000.0)::integer));
    end if;
    insert into public.usage_logs (id, class_code, pc_name, student_id, app_name, process_name,
        student_log, student_name, "timestamp", class_session_id, student_session_id, usage_duration_seconds)
    values ((p_event->>'id')::uuid, requested_class, enrolled_pc,
        coalesce(student.roll_number, p_event->>'student_id'), p_event->>'app_name', p_event->>'process_name',
        p_event->>'student_log', coalesce(student.student_name, p_event->>'student_name'),
        (p_event->>'timestamp')::bigint, student.session_id, student.id, duration_seconds)
    on conflict (id) do nothing;
end;
$$;

commit;
