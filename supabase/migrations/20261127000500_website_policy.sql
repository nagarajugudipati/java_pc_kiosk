begin;

create table kiosk_private.website_rules (
    session_id uuid not null references kiosk_private.class_sessions,
    device_id uuid,
    domain text not null check (length(domain) between 3 and 240
        and domain ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'),
    blocked boolean not null,
    unique nulls not distinct (session_id, device_id, domain)
);
alter table kiosk_private.website_rules enable row level security;
revoke all on kiosk_private.website_rules from public, anon, authenticated;

create function public.kiosk_set_website_rule(p_session uuid, p_device uuid, p_domain text, p_blocked boolean)
returns bigint language plpgsql security definer set search_path = ''
as $$
declare version bigint;
begin
    update kiosk_private.class_sessions s set policy_version = policy_version + 1
    from public.kiosk_classes c where s.id = p_session and c.class_code = s.class_code
        and c.owner_id = auth.uid() and s.ended_at is null and s.expires_at > statement_timestamp()
    returning s.policy_version into version;
    if not found then raise exception 'Active owned session required' using errcode = '42501'; end if;
    if p_device is not null and not exists (
        select 1 from kiosk_private.student_sessions where session_id = p_session and device_id = p_device
    ) then raise exception 'Computer has not joined this class' using errcode = '22023'; end if;
    insert into kiosk_private.website_rules values (p_session, p_device, lower(btrim(p_domain)), p_blocked)
    on conflict (session_id, device_id, domain) do update set blocked = excluded.blocked;
    return version;
end;
$$;

create function public.kiosk_website_rules(p_session uuid)
returns table (device_id uuid, domain text, blocked boolean)
language sql stable security definer set search_path = ''
as $$
    select r.device_id, r.domain, r.blocked from kiosk_private.website_rules r
    join kiosk_private.class_sessions s on s.id = r.session_id
    join public.kiosk_classes c on c.class_code = s.class_code
    where s.id = p_session and c.owner_id = auth.uid()
    order by r.domain, r.device_id
$$;

create function public.kiosk_device_website_rules(p_student uuid)
returns table (domain text, blocked boolean)
language sql stable security definer set search_path = ''
as $$
    select distinct on (r.domain) r.domain, r.blocked
    from kiosk_private.website_rules r
    join kiosk_private.student_sessions d on d.session_id = r.session_id
    join kiosk_private.class_sessions s on s.id = d.session_id
    join kiosk_private.kiosks k on k.user_id = d.device_id and s.class_code = any(k.class_codes)
    where d.id = p_student and d.device_id = auth.uid() and d.left_at is null
      and s.ended_at is null and s.expires_at > statement_timestamp()
      and (r.device_id is null or r.device_id = d.device_id)
    order by r.domain, r.device_id nulls last
$$;

revoke all on function public.kiosk_set_website_rule(uuid,uuid,text,boolean), public.kiosk_website_rules(uuid),
    public.kiosk_device_website_rules(uuid) from public, anon, authenticated;
grant execute on function public.kiosk_set_website_rule(uuid,uuid,text,boolean), public.kiosk_website_rules(uuid),
    public.kiosk_device_website_rules(uuid) to authenticated;

commit;
