-- Run on java-pc-kiosk after all migrations. Each check should return true.
with report_tables (relation) as (
    values ('public.usage_logs'::regclass), ('public.pc_activity_logs'::regclass),
           ('public.daily_summary'::regclass)
),
device_rpc (routine) as (
    values ('public.record_kiosk_events(jsonb)'::regprocedure),
           ('public.kiosk_join_class(text,text,text)'::regprocedure),
           ('public.kiosk_heartbeat(uuid,bigint,text)'::regprocedure)
)
select 'Report tables have RLS' as check_name, bool_and(c.relrowsecurity) as passed
from report_tables join pg_class c on c.oid = relation
union all
select 'Anonymous callers cannot read or write report tables',
       not bool_or(has_table_privilege('anon', relation, 'SELECT, INSERT, UPDATE, DELETE')
                   or has_any_column_privilege('anon', relation, 'SELECT, INSERT, UPDATE'))
from report_tables
union all
select 'Authenticated callers cannot write report tables directly',
       not bool_or(has_table_privilege('authenticated', relation, 'INSERT, UPDATE, DELETE')
                   or has_any_column_privilege('authenticated', relation, 'INSERT, UPDATE'))
from report_tables
union all
select 'Device RPCs require authentication',
       bool_and(has_function_privilege('authenticated', routine, 'EXECUTE')
                and not has_function_privilege('anon', routine, 'EXECUTE'))
from device_rpc
union all
select 'Private enrollment and session schema is closed to API roles',
       not has_schema_privilege('anon', 'kiosk_private', 'USAGE, CREATE')
       and not has_schema_privilege('authenticated', 'kiosk_private', 'USAGE, CREATE');
