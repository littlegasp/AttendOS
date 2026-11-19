-- Times the main screens' database calls as the company's HR user. psql -v hr=<auth uid> -f timings.sql
\timing on
set role authenticated;
select set_config('request.jwt.claim.sub', :'hr', false);
\echo dashboard_summary
select length(dashboard_summary()::text);
\echo register_day
select count(*) from attendance_register(current_date - 1, current_date - 1, null, null, null, null, 5000);
\echo register_7d
select count(*) from attendance_register(current_date - 7, current_date - 1, null, null, null, null, 5000);
\echo register_month
select count(*) from attendance_register(current_date - 30, current_date - 1, null, null, null, null, 50);
\echo report_people_month
select count(*) from report_people(current_date - 30, current_date - 1);
\echo report_trend_month
select count(*) from report_trend(current_date - 30, current_date - 1);
\echo my_today
select length(my_today()::text);
\echo directory_page
select count(*) from (select * from employees order by full_name limit 25) x;
