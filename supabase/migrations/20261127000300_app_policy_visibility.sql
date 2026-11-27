begin;

alter table kiosk_private.class_sessions alter column app_mode set default 'ALLOWLIST';

create function public.kiosk_app_rules(p_session uuid)
returns table (scope text, target_id uuid, process_name text, blocked boolean)
language sql stable security definer set search_path = ''
as $$
    select r.scope, r.target_id, r.process_name, r.blocked
    from kiosk_private.app_rules r
    join kiosk_private.class_sessions s on s.id = r.session_id
    join public.kiosk_classes c on c.class_code = s.class_code
    where s.id = p_session and c.owner_id = auth.uid()
$$;

revoke all on function public.kiosk_app_rules(uuid) from public, anon, authenticated;
grant execute on function public.kiosk_app_rules(uuid) to authenticated;

commit;
