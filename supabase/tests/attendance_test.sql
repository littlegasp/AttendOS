\set ON_ERROR_STOP on
-- Helpers: act as a user; assert a condition.
create function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false) $$;
create function pg_temp.expect(ok boolean, what text) returns void language plpgsql as $$
begin if not coalesce(ok, false) then raise exception 'FAILED: %', what; end if; raise notice 'ok - %', what; end $$;

-- Four people: first is Admin automatically.
insert into auth.users (id, email, raw_user_meta_data) values
 ('00000000-0000-0000-0000-00000000000a', 'admin@x.in', '{"full_name":"Asha Admin"}'),
 ('00000000-0000-0000-0000-00000000000b', 'hr@x.in', '{"full_name":"Hema HR"}'),
 ('00000000-0000-0000-0000-00000000000c', 'mgr@x.in', '{"full_name":"Manoj Manager"}'),
 ('00000000-0000-0000-0000-00000000000d', 'emp@x.in', '{"full_name":"Esha Employee"}'),
 ('00000000-0000-0000-0000-00000000000e', 'other@x.in', '{"full_name":"Om Other"}');
select pg_temp.expect((select role from employees where email='admin@x.in') = 'admin', 'first sign-in becomes admin');
select pg_temp.expect((select count(*) from employees where role='employee') = 4, 'others start as employee');

set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
update employees set role='hr' where email='hr@x.in';
update employees set role='manager' where email='mgr@x.in';
update employees set manager_id='00000000-0000-0000-0000-00000000000c' where email='emp@x.in';
insert into locations (id, name, lat, lng, radius_m) values
 ('11111111-1111-1111-1111-111111111111', 'Andheri HQ', 19.1100, 72.8800, 150),
 ('22222222-2222-2222-2222-222222222222', 'Pune Plant', 18.5200, 73.8560, 200);
select pg_temp.expect((select count(*) from audit_log where target='locations') = 2, 'location changes are audited');

-- Employee cannot promote self or write roster
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
update employees set role='admin' where email='emp@x.in';
select pg_temp.expect((select role from employees where email='emp@x.in') = 'employee', 'employee cannot change own role (no rows updated)');
do $$ begin
  insert into roster_day (employee_id, day, work_mode) values ('00000000-0000-0000-0000-00000000000d', local_today(), 'remote');
  raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - employee cannot write roster'; end $$;

-- HR cannot change roles
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
do $$ begin
  update employees set role='admin' where email='hr@x.in';
  raise exception 'should fail';
exception when raise_exception then
  if sqlerrm like 'should fail' then raise; end if;
  raise notice 'ok - HR cannot change roles (%)', sqlerrm; end $$;

-- HR sets Esha: office at Andheri today
insert into roster_day (employee_id, day, work_mode, location_id) values
 ('00000000-0000-0000-0000-00000000000d', local_today(), 'office', '11111111-1111-1111-1111-111111111111');

-- Esha: no location → refused, nothing recorded
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select pg_temp.expect(punch('in') ->> 'code' = 'location_required', 'office day needs location');
select pg_temp.expect(punch('in', 19.1100, 72.8800, 500) ->> 'code' = 'accuracy_low', 'poor accuracy refused');
select pg_temp.expect(punch('in', 19.1300, 72.8800, 20) ->> 'code' = 'outside_area', 'outside geofence refused (~2.2 km)');
select pg_temp.expect(punch('in', 18.5200, 73.8560, 20) ->> 'code' = 'outside_area', 'other office refused when roster says Andheri');
select pg_temp.expect((select count(*) from attendance_events) = 0, 'no event created by refusals');
select pg_temp.expect((select count(*) from attendance_attempts) = 4, 'refusals logged for audit');
select pg_temp.expect(punch('out', 19.1100, 72.8800, 20) ->> 'code' = 'not_checked_in', 'cannot check out before checking in');

-- Inside the area → checked in, with server time
select pg_temp.expect((punch('in', 19.1105, 72.8801, 25)) ->> 'ok' = 'true', 'check-in inside geofence works');
select pg_temp.expect(punch('in', 19.1105, 72.8801, 25) ->> 'code' = 'already_in', 'second check-in returns existing session');
select pg_temp.expect((select count(*) from attendance_events where kind='in') = 1, 'never two open sessions');
select pg_temp.expect((my_today() ->> 'checked_in')::boolean, 'today shows checked in');
select pg_temp.expect(jsonb_array_length(my_today() -> 'events') = 1, 'today lists the event');

-- Visibility
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select pg_temp.expect((select count(*) from attendance_events) = 1, 'manager sees team member event');
select pg_temp.expect((select count(*) from attendance_coords) = 0, 'manager cannot see precise coordinates');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e');
select pg_temp.expect((select count(*) from attendance_events) = 0, 'other employee sees nothing of Esha');
select pg_temp.expect((select count(*) from employees) = 1, 'employee sees only own profile');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select pg_temp.expect((select count(*) from attendance_coords) = 1, 'HR can see coordinates');
select pg_temp.expect((select count(*) from audit_log where target='roster_day') = 1, 'roster change audited');

-- Esha: no direct inserts allowed
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
do $$ begin
  insert into attendance_events (employee_id, kind, work_mode, verified) values ('00000000-0000-0000-0000-00000000000d', 'in', 'office', true);
  raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - events can only be created by punch()'; end $$;

-- Check out outside → refused; inside → ok
select pg_temp.expect(punch('out', 19.2000, 72.9000, 20) ->> 'code' = 'outside_area', 'office check-out outside refused');
select pg_temp.expect(punch('out', 19.1101, 72.8799, 30) ->> 'ok' = 'true', 'check-out inside works');
select pg_temp.expect(not (my_today() ->> 'checked_in')::boolean, 'today shows checked out');

-- Remote day: no location needed (company policy default)
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
update roster_day set work_mode='remote', location_id=null where employee_id='00000000-0000-0000-0000-00000000000d';
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select pg_temp.expect(my_today() -> 'plan' ->> 'work_mode' = 'remote', 'plan reflects HR change to remote');
select pg_temp.expect(punch('in') ->> 'ok' = 'true', 'remote check-in without location allowed by policy');
select pg_temp.expect((select work_mode from attendance_events order by id desc limit 1) = 'remote', 'event recorded as remote');
select pg_temp.expect(punch('out') ->> 'ok' = 'true', 'remote check-out');

-- Remote with location required by policy
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
update organization set remote_location_required = true;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select pg_temp.expect(punch('in') ->> 'code' = 'location_required', 'remote needs location when policy says so');

-- Day off
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
update roster_day set work_mode='off' where employee_id='00000000-0000-0000-0000-00000000000d';
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select pg_temp.expect(punch('in', 19.11, 72.88, 10) ->> 'code' = 'day_off', 'day off blocks check-in');

-- Weekly pattern applies when no date change
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
delete from roster_day;
insert into roster_pattern (employee_id, weekday, work_mode) values ('00000000-0000-0000-0000-00000000000d', extract(dow from local_today())::int, 'remote');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select pg_temp.expect(my_today() -> 'plan' ->> 'source' = 'pattern', 'weekly pattern used when no date change');

-- Bulk weekly pattern, all or nothing
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select set_roster_pattern(array['00000000-0000-0000-0000-00000000000d','00000000-0000-0000-0000-00000000000e']::uuid[],
  '[{"weekday":1,"work_mode":"office","location_id":"11111111-1111-1111-1111-111111111111"},{"weekday":5,"work_mode":"remote"}]');
select pg_temp.expect((select count(*) from roster_pattern) = 4, 'bulk pattern replaced for two people');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
do $$ begin
  perform set_roster_pattern(array['00000000-0000-0000-0000-00000000000d']::uuid[], '[{"weekday":2,"work_mode":"off"}]');
  raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - employee cannot set patterns'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');

-- Deactivated employee cannot punch
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
update employees set active=false where email='other@x.in';
select pg_temp.as_user('00000000-0000-0000-0000-00000000000e');
select pg_temp.expect(punch('in') ->> 'code' = 'not_employee', 'inactive employee refused');

-- anon gets nothing
reset role; set role anon;
do $$ begin perform count(*) from public.employees; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - anon has no access'; end $$;
reset role;
select 'ALL DATABASE TESTS PASSED';
