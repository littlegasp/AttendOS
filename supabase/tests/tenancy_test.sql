\set ON_ERROR_STOP on
-- Runs after 0003. Company A = the existing test data (a=Admin, b=HR, c=Manager of d, d=Esha, e=inactive, f=Farhan).
reset role;

select pg_temp.expect((select count(*) from companies) = 1, 'existing data moved into the first company');
select pg_temp.expect((select count(*) from employees where company_id is null) = 0, 'every employee belongs to a company');
select pg_temp.expect((select count(*) from employees where user_id = id) = 6, 'existing logins stay linked to their employee');

-- Company B, created by the platform owner, with its first admin (linked when they sign up)
select create_company('Beta Logistics', 'beta', 'Europe/London', 'owner@beta.co', 'Bina Owner');
select pg_temp.expect((select user_id from employees where email = 'owner@beta.co') is null, 'admin not linked before sign-up');
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000b0', 'owner@beta.co');
select pg_temp.expect((select user_id from employees where email = 'owner@beta.co') = '00000000-0000-0000-0000-0000000000b0', 'confirmed sign-up links the login');
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000b9', 'stranger@beta.co');
do $$ begin perform public.create_company('Bad', 'Bad Slug!', 'Asia/Kolkata', 'x@y.z', 'X'); raise exception 'should fail';
exception when check_violation then raise notice 'ok - company address must be a simple slug'; end $$;
do $$ begin perform public.create_company('Mars', 'mars', 'Mars/Olympus', 'm@mars.co', 'M'); raise exception 'should fail';
exception when check_violation then raise notice 'ok - unknown time zone refused'; end $$;

set role authenticated;

-- B admin builds their company
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b0');
select pg_temp.expect(my_role() = 'admin', 'B owner is admin of B');
select pg_temp.expect(company_tz(my_company()) = 'Europe/London', 'B has its own time zone');
insert into locations (name, lat, lng, radius_m) values ('Beta HQ', 51.5007, -0.1246, 200);
insert into employees (full_name, email) values ('Ben Staff', 'ben@beta.co');
insert into departments (name) values ('Sales'); -- same name as nothing in A; names are per company
select pg_temp.expect((select count(*) from employees) = 2, 'B sees only its own 2 employees');
select pg_temp.expect((select count(*) from locations) = 1, 'B sees only its own office');
select pg_temp.expect((select count(*) from companies) = 1, 'B sees only its own company');
select pg_temp.expect((select count(*) from attendance_events) = 0, 'B sees no attendance of A');
select pg_temp.expect((select count(*) from attendance_corrections) = 0, 'B sees no corrections of A');
select pg_temp.expect((select count(*) from holidays) = 0 and (select count(*) from shifts) = 0, 'B sees no holidays or shifts of A');
select pg_temp.expect((select count(*) from audit_log) >= 2 and (select count(*) from audit_log where company_id <> my_company()) = 0, 'B audit log holds only B entries');
select pg_temp.expect((select count(*) from verification_log(100)) = 0, 'B verification history has no A entries');
select pg_temp.expect((dashboard_summary() ->> 'people')::int = 2, 'B dashboard counts only B');

-- Cross-company writes are refused
do $$ begin insert into public.roster_day (employee_id, day, work_mode) values ('00000000-0000-0000-0000-00000000000d', current_date, 'remote'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - B cannot roster an A employee'; end $$;
do $$ begin insert into public.holidays (day, name, location_id) values (current_date + 3, 'Fake', '11111111-1111-1111-1111-111111111111'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - B cannot attach a holiday to an A office'; end $$;
do $$ begin update public.employees set manager_id = '00000000-0000-0000-0000-00000000000c' where email = 'ben@beta.co'; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - B cannot set an A manager'; end $$;
do $$ begin update public.employees set company_id = (select company_id from public.employees where email = 'ben@beta.co') where id = '00000000-0000-0000-0000-00000000000d';
  if found then raise exception 'should fail'; end if; raise notice 'ok - B cannot pull an A employee across (no rows)'; end $$;
do $$ begin perform public.attendance_history('00000000-0000-0000-0000-00000000000d', current_date - 3, current_date); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - B cannot read A history'; end $$;
do $$ begin perform public.decide_correction(1, true); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - B cannot decide A corrections'; end $$;
update companies set max_accuracy_m = 55 where slug = 'company';
select pg_temp.expect((select count(*) from companies where max_accuracy_m = 55) = 0, 'B cannot change A settings');
do $$ begin update public.companies set slug = 'beta2'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - slug managed by platform owner'; end $$;
do $$ begin update public.companies set timezone = 'Nowhere/Land'; raise exception 'should fail';
exception when check_violation then raise notice 'ok - invalid time zone refused'; end $$;
update companies set timezone = 'Asia/Dubai';
select pg_temp.expect(company_tz(my_company()) = 'Asia/Dubai', 'admin changes own company time zone');
update companies set timezone = 'Europe/London';
do $$ begin update public.employees set active = false where email = 'owner@beta.co'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - cannot deactivate yourself'; end $$;

-- Ben signs up: unconfirmed first (no access), then confirmed (linked)
reset role;
insert into auth.users (id, email, email_confirmed_at) values ('00000000-0000-0000-0000-0000000000b1', 'Ben@Beta.co', null);
select pg_temp.expect((select user_id from employees where email = 'ben@beta.co') is null, 'unconfirmed e-mail is not linked');
update auth.users set email_confirmed_at = now() where id = '00000000-0000-0000-0000-0000000000b1';
select pg_temp.expect((select user_id from employees where email = 'ben@beta.co') = '00000000-0000-0000-0000-0000000000b1', 'linked once confirmed (case-insensitive)');
set role authenticated;

-- Ben checks in: only B offices count, B time zone used
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select pg_temp.expect(punch('in', 19.1100, 72.8800, 10) ->> 'location' = 'Beta HQ', 'standing at an A office does not count for B');
select pg_temp.expect(punch('in', 51.5008, -0.1247, 12) ->> 'ok' = 'true', 'check-in at own company office');
select pg_temp.expect(my_today() ->> 'timezone' = 'Europe/London', 'today uses the company time zone');
select pg_temp.expect((select count(*) from employees) = 1, 'employee sees only own profile');
do $$ begin update public.employees set full_name = 'Hacker' where email = 'owner@beta.co'; if found then raise exception 'should fail'; end if;
raise notice 'ok - employee cannot edit others'; end $$;

-- A login with no employee record sees nothing
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b9');
select pg_temp.expect(my_company() is null and (select count(*) from employees) = 0 and (select count(*) from companies) = 0, 'unlinked login has no access');
select pg_temp.expect(my_today() ->> 'code' = 'not_employee', 'unlinked login cannot check in');

-- A is untouched
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select pg_temp.expect((select count(*) from employees) = 6 and (select count(*) from locations) = 2, 'A HR still sees A only');
select pg_temp.expect((select count(*) from audit_log where target = 'locations' and after ->> 'name' = 'Beta HQ') = 0, 'A cannot see B audit entries');
select pg_temp.expect(dashboard_summary() ->> 'timezone' = 'Asia/Kolkata', 'A keeps Asia/Kolkata');

-- Sign-in page branding is the only anonymous access, and holds no personal data
reset role; set role anon;
select pg_temp.expect((select name from company_brand('beta')) = 'Beta Logistics', 'sign-in page can read a company name by address');
do $$ begin perform count(*) from public.companies; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - anonymous cannot read companies'; end $$;
reset role;
select 'ALL TENANCY TESTS PASSED';
