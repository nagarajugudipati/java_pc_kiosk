\set ON_ERROR_STOP on
begin;
create temporary table history_usage as select * from public.usage_logs with no data;
create temporary table history_activity as select * from public.pc_activity_logs with no data;
\copy history_usage (id, class_code, app_name, process_name, student_log, student_name, "timestamp") from 'usage_logs.csv' with (format csv, header true, encoding 'UTF8')
\copy history_activity (id, pc_name, app_name, process_name, action, "timestamp") from 'pc_activity_logs.csv' with (format csv, header true, encoding 'UTF8')
insert into public.usage_logs (id, class_code, app_name, process_name, student_log, student_name, "timestamp")
select id, class_code, app_name, process_name, student_log, student_name, "timestamp"
from history_usage on conflict (id) do nothing;
insert into public.pc_activity_logs (id, pc_name, app_name, process_name, action, "timestamp")
select id, pc_name, app_name, process_name, action, "timestamp"
from history_activity on conflict (id) do nothing;
commit;
