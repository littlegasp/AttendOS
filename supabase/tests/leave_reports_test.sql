\set ON_ERROR_STOP on
-- Phase 4/5 (0006): leave, attendance register, reports, settings, user access. Runs after verification_test.sql.
-- Company A: a=Admin, b=HR, c=Manager of d (Esha) and Gita (login a9), Hari (manager, no team), f=Farhan (left).
reset role; select pg_temp.as_user('');
select set_config('test.a', (select company_id::text from employees where id = '00000000-0000-0000-0000-00000000000a'), false);
select set_config('test.b', (select company_id::text from employees where email = 'owner@beta.co'), false);
select set_config('test.gita', (select id::text from employees where email = 'gita@acme.in'), false);
select set_config('test.cl', (select id::text from leave_types where company_id = current_setting('test.a')::uuid and code = 'CL'), false);
select set_config('test.ul', (select id::text from leave_types where company_id = current_setting('test.a')::uuid and code = 'UL'), false);
select set_config('test.today', local_today(current_setting('test.a')::uuid)::text, false);
-- Next working day for Gita within two weeks (avoids depending on today's weekday)
select set_config('test.wd', (select min(g::date)::text from generate_series(current_setting('test.today')::date + 1, current_setting('test.today')::date + 14, interval '1 day') g
                               where leave_days(current_setting('test.gita')::uuid, g::date, g::date, null) = 1), false);
select set_config('test.wde', (select min(g::date)::text from generate_series(current_setting('test.today')::date + 25, current_setting('test.today')::date + 40, interval '1 day') g
                               where leave_days('00000000-0000-0000-0000-00000000000d', g::date, g::date, null) = 1), false);
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000c3', 'hari@acme.in');
select pg_temp.expect((select count(*) from leave_types where company_id = current_setting('test.a')::uuid) = 4
  and (select count(*) from leave_types where company_id = current_setting('test.b')::uuid) = 4, 'every company starts with Casual, Sick, Earned and Unpaid');
select create_company('Gamma Foods', 'gamma', 'Asia/Kolkata', 'owner@gamma.in', 'Gopal Owner');
select pg_temp.expect((select count(*) from leave_types t join companies c on c.id = t.company_id where c.slug = 'gamma') = 4, 'a new company gets the default leave types');

set role authenticated;
-- ---------------------------------------------------------------- applying
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select set_config('test.r1', (apply_leave(current_setting('test.cl')::uuid, current_setting('test.today')::date + 15, current_setting('test.today')::date + 17, null, 'Family function') ->> 'id'), false);
select pg_temp.expect((select status = 'pending' and days > 0 from leave_requests where id = current_setting('test.r1')::bigint), 'leave request saved as pending');
select pg_temp.expect((leave_preview(current_setting('test.cl')::uuid, current_setting('test.today')::date + 16, current_setting('test.today')::date + 20, null) -> 'overlap' ->> 'status') = 'pending',
  'the form warns about an overlapping request before submitting');
do $$ begin perform public.leave_preview(current_setting('test.cl')::uuid, current_date + 1, current_date + 2, null, '00000000-0000-0000-0000-00000000000b'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - an employee cannot preview someone else''s leave'; end $$;
do $$ begin perform public.apply_leave(current_setting('test.cl')::uuid, current_setting('test.today')::date + 16, current_setting('test.today')::date + 20, null, 'Overlap'); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - overlapping request refused (%)', sqlerrm; end $$;
do $$ begin perform public.apply_leave(current_setting('test.cl')::uuid, current_setting('test.today')::date + 30, current_setting('test.today')::date + 90, null, 'Too long'); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - more days than the balance refused (%)', sqlerrm; end $$;
do $$ begin perform public.apply_leave(current_setting('test.cl')::uuid, current_setting('test.today')::date - 40, current_setting('test.today')::date - 40, null, 'Old'); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - too far back refused for employees'; end $$;
do $$ begin perform public.apply_leave(current_setting('test.cl')::uuid, make_date(extract(year from current_date)::int + 1, 12, 30), make_date(extract(year from current_date)::int + 2, 1, 3), null, 'New year'); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - request across two leave years refused'; end $$;
do $$ begin perform public.apply_leave(current_setting('test.cl')::uuid, current_setting('test.today')::date + 40, current_setting('test.today')::date + 41, 'first', 'Bad half'); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - half day must be one date'; end $$;
select set_config('test.r2', (apply_leave(current_setting('test.cl')::uuid, current_setting('test.wde')::date, current_setting('test.wde')::date, 'first', 'Doctor visit') ->> 'id'), false);
select pg_temp.expect((select days from leave_requests where id = current_setting('test.r2')::bigint) = 0.5, 'half day counts as 0.5');
do $$ begin perform public.apply_leave(current_setting('test.cl')::uuid, current_setting('test.wde')::date, current_setting('test.wde')::date, 'first', 'Again'); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - same half day twice refused'; end $$;
select pg_temp.expect((select available from leave_balance_view('00000000-0000-0000-0000-00000000000d') where code = 'CL')
  = 12 - (select sum(days) from leave_requests where employee_id = '00000000-0000-0000-0000-00000000000d' and status = 'pending'), 'pending days are held back from the balance');
do $$ begin insert into public.leave_requests (employee_id, leave_type_id, start_date, end_date, days, reason, requested_by)
  values ('00000000-0000-0000-0000-00000000000d', current_setting('test.cl')::uuid, current_date, current_date, 1, 'Direct', '00000000-0000-0000-0000-00000000000d'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - leave can only be requested through the checked function'; end $$;
do $$ begin perform public.decide_leave(current_setting('test.r1')::bigint, true); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - nobody approves their own leave'; end $$;
do $$ begin perform public.adjust_leave('00000000-0000-0000-0000-00000000000d', current_setting('test.cl')::uuid, 5, 'Gift'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - employees cannot adjust balances'; end $$;

-- ---------------------------------------------------------------- deciding
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a9'); -- Gita, a colleague
select pg_temp.expect((select count(*) from leave_list(current_date - 400, current_date + 400) where employee_id = '00000000-0000-0000-0000-00000000000d') = 0,
  'a colleague cannot see someone else''s leave');
do $$ begin perform public.decide_leave(current_setting('test.r1')::bigint, true); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - a colleague cannot approve'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c3');
do $$ begin perform public.decide_leave(current_setting('test.r1')::bigint, true); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - a manager of another team cannot approve'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select pg_temp.expect((select can_decide from leave_list(current_date, current_date + 400) where id = current_setting('test.r1')::bigint), 'the manager sees the request and may decide');
select pg_temp.expect(exists (select 1 from jsonb_array_elements(dashboard_summary() -> 'pending_leave') x where (x ->> 'id')::bigint = current_setting('test.r1')::bigint and (x ->> 'can_decide')::boolean),
  'pending leave appears on the manager''s dashboard');
select decide_leave(current_setting('test.r1')::bigint, true, 'Enjoy');
select pg_temp.expect((select status = 'approved' and decided_by = '00000000-0000-0000-0000-00000000000c' and decided_at is not null from leave_requests where id = current_setting('test.r1')::bigint),
  'manager approves; approver and time recorded');
do $$ begin perform public.decide_leave(current_setting('test.r1')::bigint, false, 'Changed my mind'); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - a decided request cannot be decided again'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
do $$ begin perform public.decide_leave(current_setting('test.r2')::bigint, false); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - rejecting needs a reason'; end $$;
select decide_leave(current_setting('test.r2')::bigint, false, 'Busy week, please move it');
select pg_temp.expect((select status from leave_requests where id = current_setting('test.r2')::bigint) = 'rejected', 'HR rejects with a reason');
select adjust_leave('00000000-0000-0000-0000-00000000000d', current_setting('test.cl')::uuid, 2, 'Carried over from last year');
do $$ begin perform public.adjust_leave('00000000-0000-0000-0000-00000000000b', current_setting('test.cl')::uuid, 2, 'For me'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - HR cannot adjust their own balance'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select pg_temp.expect((select yearly_days + adjustments - taken - pending = available and adjustments = 2 and taken >= 1 from leave_balance_view('00000000-0000-0000-0000-00000000000d') where code = 'CL'),
  'balance = yearly days + adjustments − taken − pending');
select cancel_leave(current_setting('test.r1')::bigint);
select pg_temp.expect((select status from leave_requests where id = current_setting('test.r1')::bigint) = 'cancelled', 'employee cancels approved leave that has not started');

-- ---------------------------------------------------------------- HR records leave; leave in attendance
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select apply_leave(current_setting('test.cl')::uuid, current_setting('test.wd')::date, current_setting('test.wd')::date, null, 'Recorded after a phone call', current_setting('test.gita')::uuid);
select pg_temp.expect((select status = 'approved' and decided_by = '00000000-0000-0000-0000-00000000000b' from leave_requests where employee_id = current_setting('test.gita')::uuid order by id desc limit 1),
  'leave recorded by HR is approved at once and shows who recorded it');
select pg_temp.expect((select status from attendance_register(current_setting('test.wd')::date, current_setting('test.wd')::date, null, current_setting('test.gita')::uuid)) = 'on_leave',
  'the register shows the day as On leave, not absent');
do $$ begin perform public.apply_leave(current_setting('test.cl')::uuid, current_setting('test.today')::date + 1, current_setting('test.today')::date + 1, null, 'After leaving', '00000000-0000-0000-0000-00000000000f'); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - no leave after the last working day'; end $$;
reset role; select pg_temp.as_user('');
select pg_temp.expect((select count(*) from audit_log where target = 'leave_requests' and target_id = current_setting('test.r1') and source = 'app'
  and actor_employee in ('00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-00000000000c')) >= 3, 'request, approval and cancellation are in the audit log with who did each');
select pg_temp.expect((select days = leave_days(employee_id, start_date, end_date, null) from leave_requests where id = current_setting('test.r1')::bigint),
  'days are counted by the server from the roster and holidays (days off excluded)');
select pg_temp.expect((day_for(current_setting('test.gita')::uuid, current_setting('test.wd')::date)).status = 'on_leave', 'approved leave turns a working day into On leave');
-- Check-in on a full day of leave (only when today is a working day for Gita)
do $$ declare r jsonb; begin
  if public.leave_days(current_setting('test.gita')::uuid, current_setting('test.today')::date, current_setting('test.today')::date, null) = 1
     and not exists (select 1 from public.attendance_events where employee_id = current_setting('test.gita')::uuid and work_date = current_setting('test.today')::date) then
    insert into public.leave_requests (employee_id, leave_type_id, start_date, end_date, days, reason, status, requested_by, decided_by, decided_at)
    values (current_setting('test.gita')::uuid, current_setting('test.ul')::uuid, current_setting('test.today')::date, current_setting('test.today')::date, 1, 'Test', 'approved', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000b', now());
    set local role authenticated;
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a9', true);
    r := public.punch('in', 19.1136, 72.8697, 10);
    if r ->> 'code' <> 'on_leave' then raise exception 'FAILED: check-in on leave day returned %', r; end if;
    if (public.my_today() -> 'leave' ->> 'type') is null then raise exception 'FAILED: My Attendance does not show the leave'; end if;
    raise notice 'ok - check-in refused on a full day of approved leave; My Attendance shows the leave';
  else raise notice 'ok - (skipped: today is not a working day for Gita)'; end if;
end $$;
reset role; select pg_temp.as_user('');

-- ---------------------------------------------------------------- leave types
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
insert into leave_types (name, code, paid, yearly_days, allow_half_day) values ('Maternity', 'ML', true, 182, false);
select pg_temp.expect((select count(*) from leave_types) = 5, 'HR adds a leave type for the company');
do $$ begin delete from public.leave_types where code = 'ML'; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - leave types are switched off, never deleted'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a9');
do $$ begin insert into public.leave_types (name, code) values ('Bonus', 'BL'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - employees cannot add leave types'; end $$;

-- ---------------------------------------------------------------- other companies
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b0');
select pg_temp.expect((select count(*) from leave_types where company_id = current_setting('test.a')::uuid) = 0
  and (select count(*) from leave_requests) = 0 and (select count(*) from leave_list(current_date - 400, current_date + 400)) = 0,
  'company B sees no leave types or requests of A');
do $$ begin perform public.apply_leave(current_setting('test.cl')::uuid, current_date + 50, current_date + 50, null, 'Cross', '00000000-0000-0000-0000-00000000000d'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - B cannot record leave for an A employee'; end $$;
do $$ begin perform public.decide_leave(current_setting('test.r2')::bigint, true); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - B cannot decide A leave'; end $$;
select pg_temp.as_user((select user_id::text from employees where email = 'ben@beta.co'));
do $$ begin perform public.apply_leave(current_setting('test.cl')::uuid, current_date + 50, current_date + 50, null, 'Wrong company type'); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - another company''s leave type cannot be used'; end $$;
select pg_temp.expect((select count(*) from attendance_register(current_date - 6, current_date, null, null, null, null, 5000) r
  where r.employee_id in ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000d')) = 0, 'B''s register holds no A people');

-- ---------------------------------------------------------------- register and reports: same scope as the screens
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select pg_temp.expect((select count(distinct employee_id) from attendance_register(current_date - 6, current_date, null, null, null, null, 5000))
  = (select count(*) from employees where active or exit_date >= current_date - 6), 'HR register covers everyone in the company');
select pg_temp.expect((select max(total) from attendance_register(current_date - 6, current_date, null, null, null, null, 10)) =
  (select count(*) from attendance_register(current_date - 6, current_date, null, null, null, null, 5000)), 'paging returns the full total with each page');
do $$ begin perform public.attendance_register(current_date - 120, current_date); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - register range limited'; end $$;
select pg_temp.expect((select bool_and(rate between 0 and 100) from report_people(current_date - 6, current_date) where rate is not null), 'report rates are percentages of due days');
select pg_temp.expect((select count(*) from report_trend(current_date - 6, current_date)) <= 7, 'trend has at most one row per day');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select pg_temp.expect((select bool_and(employee_id in (select id from employees where id = '00000000-0000-0000-0000-00000000000c' or manager_id = '00000000-0000-0000-0000-00000000000c'))
                         from report_people(current_date - 6, current_date)), 'a manager''s reports cover only their team');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select pg_temp.expect((select count(distinct employee_id) from attendance_register(current_date - 6, current_date)) = 1, 'an employee''s register is their own days only');
do $$ begin perform public.user_access(); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - employees cannot see user access'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
do $$ begin perform public.user_access(); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - HR cannot see user access (Admin only)'; end $$;

-- ---------------------------------------------------------------- settings (Admin only) and user access
do $$ begin update public.companies set date_format = 'DD/MM/YYYY'; if found then raise exception 'should fail'; end if;
  raise notice 'ok - HR cannot change company settings (no rows)';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - HR cannot change company settings'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
update companies set date_format = 'DD/MM/YYYY', full_day_minutes = 360, leave_year_start_month = 4;
select pg_temp.expect((select date_format = 'DD/MM/YYYY' and full_day_minutes = 360 from companies), 'Admin sets date format and the half-day rule');
select pg_temp.expect((select year_start <= local_today(my_company()) and year_end >= local_today(my_company()) from leave_balance_view('00000000-0000-0000-0000-00000000000d') limit 1)
  and extract(month from (select year_start from leave_balance_view('00000000-0000-0000-0000-00000000000d') limit 1)) = 4, 'leave year follows the company setting (April–March)');
update companies set leave_year_start_month = 1;
do $$ begin update public.companies set date_format = 'whenever'; raise exception 'should fail';
exception when check_violation then raise notice 'ok - unknown date format refused'; end $$;
select pg_temp.expect((select count(*) from user_access()) = (select count(*) from employees)
  and (select login_linked from user_access() where email = 'gita@acme.in'), 'Admin sees who can sign in (linked, confirmed, last sign-in)');
select pg_temp.expect((select count(*) from user_access() where email like '%beta%') = 0, 'user access lists only the own company');

reset role; select pg_temp.as_user('');
select 'ALL LEAVE AND REPORT TESTS PASSED';
