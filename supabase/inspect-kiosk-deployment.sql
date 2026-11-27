-- Read-only inventory for intranet quiz. Returns catalog metadata only.
with expected(signature, oid) as (
    values
      ('public.kiosk_app_rules(uuid)', to_regprocedure('public.kiosk_app_rules(uuid)')),
      ('public.record_usage_log(jsonb)', to_regprocedure('public.record_usage_log(jsonb)')),
      ('public.kiosk_set_website_rule(uuid,uuid,text,boolean)', to_regprocedure('public.kiosk_set_website_rule(uuid,uuid,text,boolean)')),
      ('public.kiosk_website_rules(uuid)', to_regprocedure('public.kiosk_website_rules(uuid)')),
      ('public.kiosk_device_website_rules(uuid)', to_regprocedure('public.kiosk_device_website_rules(uuid)'))
)
select 'function' as kind, signature as object_name,
       case when oid is null then 'missing'
            when signature = 'public.record_usage_log(jsonb)' then
                case when position('duration_seconds' in pg_get_functiondef(oid)) > 0
                     then 'present with duration' else 'present without duration' end
            else 'present' end as status
from expected
union all
select 'table', 'kiosk_private.website_rules',
       case when to_regclass('kiosk_private.website_rules') is null then 'missing' else 'present' end
union all
select 'column default', 'kiosk_private.class_sessions.app_mode',
       coalesce((select column_default from information_schema.columns
                 where table_schema = 'kiosk_private' and table_name = 'class_sessions'
                   and column_name = 'app_mode'), 'missing')
union all
select 'policy', schemaname || '.' || tablename || '.' || policyname, cmd
from pg_policies
where schemaname = 'kiosk_private' or (schemaname = 'public' and tablename in (
    'usage_logs', 'pc_activity_logs', 'daily_summary', 'teacher_profiles',
    'kiosk_classes', 'teacher_class_assignments'
))
union all
select 'table', n.nspname || '.' || c.relname, case when c.relrowsecurity then 'RLS enabled' else 'RLS disabled' end
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r', 'p') and (n.nspname = 'kiosk_private' or (n.nspname = 'public' and c.relname in (
    'usage_logs', 'pc_activity_logs', 'daily_summary', 'teacher_profiles',
    'kiosk_classes', 'teacher_class_assignments'
)))
order by kind, object_name;
