\set ON_ERROR_STOP on
-- Runs after attendance_test.sql (same people: a=Admin, b=HR, c=Manager of d, d=Esha employee, e=inactive).
reset role;
create function pg_temp.d(n int) returns date language sql as $$ select public.local_today() - n $$;
create function pg_temp.t(n int, hhmm text) returns timestamptz language sql as $$ select public.at_local(public.local_today() - n, hhmm::time) $$;

-- A new active employee outside Esha's team
insert into auth.users (id, email, raw_user_meta_data) values ('00000000-0000-0000-0000-00000000000f', 'farhan@x.in', '{"full_name":"Farhan"}');

-- Test people joined three weeks ago
update public.employees set created_at = now() - interval '21 days';
update public.employees set created_at = now() where id = '00000000-0000-0000-0000-00000000000f';

-- Shifts and test days (written directly, as the database owner, with fixed past dates)
insert into public.shifts (id, name, start_time, end_time, break_minutes, grace_minutes) values
 ('aaaaaaaa-0000-0000-0000-000000000001', 'General', '09:00', '18:00', 60, 10),
 ('aaaaaaaa-0000-0000-0000-000000000002', 'Night', '22:00', '06:00', 60, 10);
insert into public.shift_day (employee_id, day, shift_id)
select '00000000-0000-0000-0000-00000000000d', pg_temp.d(n), 'aaaaaaaa-0000-0000-0000-000000000001' from unnest(array[3,4,5,6]) n;
insert into public.shift_day values ('00000000-0000-0000-0000-00000000000d', pg_temp.d(7), 'aaaaaaaa-0000-0000-0000-000000000002');
insert into public.roster_day (employee_id, day, work_mode, location_id)
select '00000000-0000-0000-0000-00000000000d', pg_temp.d(n), 'office', '11111111-1111-1111-1111-111111111111' from unnest(array[3,4,5,6,7]) n;

insert into public.attendance_events (employee_id, kind, at, work_mode, verified, work_date) values
 ('00000000-0000-0000-0000-00000000000d', 'in',          pg_temp.t(3, '09:25'), 'office', true, pg_temp.d(3)),
 ('00000000-0000-0000-0000-00000000000d', 'break_start', pg_temp.t(3, '13:00'), 'office', false, pg_temp.d(3)),
 ('00000000-0000-0000-0000-00000000000d', 'break_end',   pg_temp.t(3, '13:45'), 'office', false, pg_temp.d(3)),
 ('00000000-0000-0000-0000-00000000000d', 'out',         pg_temp.t(3, '19:30'), 'office', true, pg_temp.d(3)),
 ('00000000-0000-0000-0000-00000000000d', 'in',          pg_temp.t(4, '09:08'), 'office', true, pg_temp.d(4)),
 ('00000000-0000-0000-0000-00000000000d', 'out',         pg_temp.t(4, '16:00'), 'office', true, pg_temp.d(4)),
 ('00000000-0000-0000-0000-00000000000d', 'in',          pg_temp.t(5, '09:00'), 'office', true, pg_temp.d(5)),
 ('00000000-0000-0000-0000-00000000000d', 'in',          pg_temp.t(7, '22:10'), 'office', true, pg_temp.d(7)),
 ('00000000-0000-0000-0000-00000000000d', 'out',         pg_temp.t(6, '06:05'), 'office', true, pg_temp.d(7));

-- Calculations
select pg_temp.expect((r).late_min = 25 and (r).break_min = 45 and (r).worked_min = 560 and (r).overtime_min = 80 and (r).early_min = 0 and (r).status = 'late',
  'late 25 min, 45 min break, 560 worked, 80 overtime') from (select public.day_for('00000000-0000-0000-0000-00000000000d', pg_temp.d(3)) r) x;
select pg_temp.expect((r).late_min = 0 and (r).early_min = 120 and (r).status = 'present', 'within grace is not late; left 2h early')
  from (select public.day_for('00000000-0000-0000-0000-00000000000d', pg_temp.d(4)) r) x;
select pg_temp.expect((r).status = 'missing_checkout' and (r).worked_min = 0, 'old open session = missing check-out, not counted')
  from (select public.day_for('00000000-0000-0000-0000-00000000000d', pg_temp.d(5)) r) x;
select pg_temp.expect((r).status = 'absent', 'rostered day with no check-in = absent')
  from (select public.day_for('00000000-0000-0000-0000-00000000000d', pg_temp.d(6)) r) x;
select pg_temp.expect((r).worked_min = 475 and (r).late_min = 0 and (r).overtime_min = 55 and (r).shift_end > (r).shift_start + interval '7 hours',
  'overnight shift: after-midnight check-out counts for the start date') from (select public.day_for('00000000-0000-0000-0000-00000000000d', pg_temp.d(7)) r) x;

-- Holidays and remote exceptions in the plan
insert into public.holidays (day, name) values (pg_temp.d(8), 'Diwali');
select pg_temp.expect((p).work_mode = 'off' and (p).source = 'holiday' and (p).note = 'Diwali', 'holiday makes the day off')
  from (select public.plan_for('00000000-0000-0000-0000-00000000000d', pg_temp.d(8)) p) x;
select pg_temp.expect((r).status = 'holiday', 'holiday status') from (select public.day_for('00000000-0000-0000-0000-00000000000d', pg_temp.d(8)) r) x;
insert into public.remote_exceptions (employee_id, start_date, end_date, reason) values ('00000000-0000-0000-0000-00000000000c', pg_temp.d(10), pg_temp.d(9), 'Knee surgery recovery');
select pg_temp.expect((p).work_mode = 'remote' and (p).source = 'exception', 'remote exception turns an office day remote')
  from (select public.plan_for('00000000-0000-0000-0000-00000000000c', pg_temp.d(9)) p) x
  where extract(dow from pg_temp.d(9)) <> 0;

set role authenticated;

-- Internal helpers are not callable directly
select pg_temp.as_user('00000000-0000-0000-0000-00000000000f');
do $$ begin perform public.day_for('00000000-0000-0000-0000-00000000000d', public.local_today()); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - internal day_for() not callable directly'; end $$;
do $$ begin perform public.plan_for('00000000-0000-0000-0000-00000000000d', public.local_today()); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - internal plan_for() not callable directly'; end $$;
do $$ begin perform public.attendance_history('00000000-0000-0000-0000-00000000000d', public.local_today() - 7, public.local_today()); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - another employee cannot read Esha''s history'; end $$;

-- Days before someone joined are not counted as absent
select pg_temp.expect((select count(*) from public.attendance_history('00000000-0000-0000-0000-00000000000f', pg_temp.d(30), pg_temp.d(0))) = 1, 'history starts on the joining date')
  from (select pg_temp.as_user('00000000-0000-0000-0000-00000000000f')) x;

-- History for self and manager
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select pg_temp.expect((select count(*) from public.attendance_history('00000000-0000-0000-0000-00000000000d', pg_temp.d(7), pg_temp.d(0))) = 8, 'own history (8 days)');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select pg_temp.expect((select late_min from public.attendance_history('00000000-0000-0000-0000-00000000000d', pg_temp.d(3), pg_temp.d(3))) = 25, 'manager reads team history');

-- Corrections
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select pg_temp.expect((public.request_correction(pg_temp.d(5), 'missing_out', null, pg_temp.t(5, '18:00'), 'Forgot to check out')) ->> 'ok' = 'true', 'employee requests missing check-out');
select pg_temp.expect((public.request_correction(pg_temp.d(5), 'missing_out', null, pg_temp.t(5, '18:10'), 'Again please')) ->> 'ok' = 'false', 'one pending request per day');
select pg_temp.expect((public.request_correction(pg_temp.d(40), 'missing_out', null, pg_temp.t(40, '18:10'), 'Too old now')) ->> 'ok' = 'false', 'older than 31 days refused');
select pg_temp.expect((public.request_correction(pg_temp.d(4), 'wrong_time', pg_temp.t(4, '09:00'), null, 'Gate scanner delay')) ->> 'ok' = 'true', 'employee requests wrong check-in time');
select pg_temp.expect((public.decide_correction((select id from attendance_corrections where work_date = pg_temp.d(5)), true)) ->> 'ok' = 'false', 'cannot decide own request');

select pg_temp.as_user('00000000-0000-0000-0000-00000000000f');
do $$ begin perform public.decide_correction(1, true); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - outsider cannot decide'; end $$;
select pg_temp.expect((select count(*) from attendance_corrections) = 0, 'outsider sees no corrections');

select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select pg_temp.expect((public.decide_correction((select id from attendance_corrections where work_date = pg_temp.d(5)), false, '')) ->> 'ok' = 'false', 'reject needs a reason');
select pg_temp.expect((public.decide_correction((select id from attendance_corrections where work_date = pg_temp.d(5)), true, 'OK')) ->> 'ok' = 'true', 'manager approves team request');
select pg_temp.expect((select status = 'present' and last_out = pg_temp.t(5, '18:00') from public.attendance_history('00000000-0000-0000-0000-00000000000d', pg_temp.d(5), pg_temp.d(5))), 'approved check-out completes the day');

select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select pg_temp.expect((public.decide_correction((select id from attendance_corrections where work_date = pg_temp.d(4)), true)) ->> 'ok' = 'true', 'HR approves wrong-time request');
select pg_temp.expect((select late_min = 0 and first_in = pg_temp.t(4, '09:00') from public.attendance_history('00000000-0000-0000-0000-00000000000d', pg_temp.d(4), pg_temp.d(4))), 'corrected check-in time used');
select pg_temp.expect((select count(*) from attendance_events where work_date = pg_temp.d(4) and superseded_by is not null) = 1, 'original event kept, marked replaced');
select pg_temp.expect((select count(*) from audit_log where target = 'attendance_corrections') = 2, 'decisions audited');

-- Breaks through punch (remote day, location not required)
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
update organization set remote_location_required = false;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
update public.organization set max_accuracy_m = 500;
select pg_temp.expect((select max_accuracy_m from organization) = 100, 'HR cannot change company rules');
insert into roster_day (employee_id, day, work_mode) values ('00000000-0000-0000-0000-00000000000d', local_today(), 'remote');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select pg_temp.expect(punch('break_start') ->> 'code' = 'not_checked_in', 'no break before check-in');
select pg_temp.expect(punch('in') ->> 'ok' = 'true', 'check in (remote)');
select pg_temp.expect(punch('break_end') ->> 'code' = 'not_on_break', 'cannot end a break that did not start');
select pg_temp.expect(punch('break_start') ->> 'ok' = 'true', 'break started');
select pg_temp.expect(my_today() ->> 'state' = 'on_break', 'state shows on break');
select pg_temp.expect(punch('break_start') ->> 'code' = 'already_on_break', 'no double break');
select pg_temp.expect(punch('out') ->> 'ok' = 'true', 'check out while on break');
select pg_temp.expect((select kind from attendance_events where employee_id = auth.uid() order by at desc, id desc offset 1 limit 1) = 'break_end', 'break closed automatically at check-out');
select pg_temp.expect(my_today() ->> 'state' = 'off', 'state off after check-out');
select pg_temp.expect((select count(*) from attendance_coords c join attendance_events e on e.id = c.event_id where e.kind like 'break%') = 0, 'no location stored for breaks');

-- Dashboard scopes
select pg_temp.expect(dashboard_summary() ->> 'scope' = 'personal' and (dashboard_summary() ->> 'people')::int = 1, 'employee dashboard is personal');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select pg_temp.expect(dashboard_summary() ->> 'scope' = 'team' and (dashboard_summary() ->> 'people')::int = 2, 'manager dashboard = self + team');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select pg_temp.expect(dashboard_summary() ->> 'scope' = 'organization' and (dashboard_summary() ->> 'people')::int = 5, 'HR dashboard = all active people');
select pg_temp.expect(jsonb_array_length(dashboard_summary() -> 'upcoming_holidays') = 0, 'past holidays not listed');
insert into holidays (day, name) values (local_today() + 5, 'Founders Day');
select pg_temp.expect(dashboard_summary() -> 'upcoming_holidays' -> 0 ->> 'name' = 'Founders Day', 'upcoming holiday listed');
select pg_temp.expect(jsonb_array_length(dashboard_summary() -> 'recent_activity') > 0, 'recent activity listed');

-- Verification history
select pg_temp.expect((select count(*) from verification_log(50)) > 0, 'HR reads verification history');
select pg_temp.expect((select count(*) from verification_log(50) where outcome = 'refused') > 0, 'refusals included');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
do $$ begin perform * from public.verification_log(10); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - employee cannot read verification history'; end $$;

-- Shifts, holidays, exceptions: HR only
do $$ begin insert into public.shifts (name, start_time, end_time) values ('Mine', '10:00', '11:00'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - employee cannot create shifts'; end $$;
do $$ begin insert into public.remote_exceptions (employee_id, start_date, end_date, reason) values (auth.uid(), current_date, current_date, 'self'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - employee cannot grant self remote exception'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select set_shift_pattern(array['00000000-0000-0000-0000-00000000000f']::uuid[], '[{"weekday":1,"shift_id":"aaaaaaaa-0000-0000-0000-000000000001"}]');
select pg_temp.expect((select count(*) from shift_pattern) = 1, 'HR sets weekly shift pattern');

reset role;
select 'ALL REFINEMENT TESTS PASSED';
