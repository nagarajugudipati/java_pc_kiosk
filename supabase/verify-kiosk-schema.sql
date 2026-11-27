-- Run after applying the migration. Every result should show passed = true.
with log_tables (relation) as (
    values ('public.usage_logs'::regclass), ('public.pc_activity_logs'::regclass)
),
api_roles (role_name) as (
    values ('anon'::name), ('authenticated'::name)
),
writers (routine) as (
    values ('public.record_usage_log(jsonb)'::regprocedure),
           ('public.record_pc_activity(jsonb)'::regprocedure)
)
select 'Log tables have row level security' as check_name,
       bool_and(c.relrowsecurity) as passed
from log_tables join pg_class c on c.oid = relation
union all
select 'API roles cannot directly access the log tables',
       not bool_or(has_table_privilege(role_name, relation, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
                   or has_any_column_privilege(role_name, relation, 'SELECT, INSERT, UPDATE, REFERENCES'))
from api_roles cross join log_tables
union all
select 'API roles cannot access the enrollment schema',
       not bool_or(has_schema_privilege(role_name, 'kiosk_private', 'USAGE, CREATE'))
from api_roles
union all
select 'Only authenticated API callers can execute the log writers',
       bool_and(has_function_privilege('authenticated', routine, 'EXECUTE')
                and not has_function_privilege('anon', routine, 'EXECUTE'))
from writers;
