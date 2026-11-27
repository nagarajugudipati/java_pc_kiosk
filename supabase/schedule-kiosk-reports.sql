-- Run as a database administrator after enabling the pg_cron extension.
select cron.schedule(
    'kiosk-refresh-daily-reports',
    '*/5 * * * *',
    'select kiosk_private.refresh_daily_reports(5);'
);
