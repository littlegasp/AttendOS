\set ON_ERROR_STOP on
-- Phase 3 verification (0005). Runs after employees_test.sql.
-- Company A: a=Admin, b=HR, c=Manager, d=Esha, e=inactive, f=Farhan (exited), Gita (login a9), Hari (manager), Isha, Kavya (inactive admin).
-- Company B: owner b0 (admin), Ben b1, Wes; b9 = stranger@beta.co (confirmed login, no record).
reset role; select pg_temp.as_user('');
select set_config('test.a', (select company_id::text from employees where id = '00000000-0000-0000-0000-00000000000a'), false);
select set_config('test.b', (select company_id::text from employees where email = 'owner@beta.co'), false);
select set_config('test.isha', (select id::text from employees where email = 'isha@acme.in'), false);
select set_config('test.hari', (select id::text from employees where email = 'hari@acme.in'), false);
select set_config('test.gita', (select id::text from employees where email = 'gita@acme.in'), false);
select set_config('test.bdept', (select id::text from departments where company_id = current_setting('test.b')::uuid limit 1), false);
-- Isha gets a confirmed login (linked) and a weekly roster pattern (Monday remote).
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000c1', 'isha@acme.in');
insert into roster_pattern (employee_id, weekday, work_mode) values (current_setting('test.isha')::uuid, 1, 'remote');
select pg_temp.expect((select user_id from employees where email = 'isha@acme.in') = '00000000-0000-0000-0000-0000000000c1', 'Isha''s confirmed login is linked');

-- ================================================================ audit log
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
update employees set phone = '+91 98200 22222' where email = 'gita@acme.in';
select pg_temp.expect((select actor = '00000000-0000-0000-0000-00000000000b' and actor_employee = '00000000-0000-0000-0000-00000000000b'
                         and source = 'app' and company_id = current_setting('test.a')::uuid
                         and before ->> 'phone' = '+91 98200 11111' and after ->> 'phone' = '+91 98200 22222' and at is not null
                         from audit_log where target = 'employees' order by id desc limit 1),
  'HR edit logged with the signed-in user, their employee record, company, time and before/after');
do $$ begin insert into public.audit_log (company_id, action, target, actor) values (current_setting('test.a')::uuid, 'update', 'employees', gen_random_uuid()); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - the app cannot write audit entries directly (no forged actor)'; end $$;
do $$ begin update public.audit_log set after = '{}' where true; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - HR cannot edit audit entries'; end $$;
do $$ begin delete from public.audit_log where true; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - HR cannot delete audit entries'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
do $$ begin delete from public.audit_log where true; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - Admin cannot delete audit entries'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select pg_temp.expect((select count(*) from audit_log) = 0, 'a Manager cannot read the audit log');
reset role; select pg_temp.as_user('');
do $$ begin update public.audit_log set after = '{}' where id = (select max(id) from public.audit_log); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - audit entries are append-only even from the SQL editor'; end $$;
do $$ begin delete from public.audit_log where id = (select max(id) from public.audit_log); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - audit entries cannot be deleted from the SQL editor'; end $$;
do $$ begin truncate public.audit_log; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - audit log cannot be emptied'; end $$;
-- Setup scripts: sample data is marked 'seed', other owner changes 'system'; a supplied actor is ignored.
select set_config('attendos.source', 'seed', false);
update departments set description = 'Sample text' where name = 'Operations';
select pg_temp.expect((select source = 'seed' and actor is null from audit_log order by id desc limit 1), 'sample-data changes are marked as seed');
select set_config('attendos.source', '', false);
insert into audit_log (company_id, action, target, actor, actor_employee) values (current_setting('test.a')::uuid, 'update', 'note', gen_random_uuid(), gen_random_uuid());
select pg_temp.expect((select source = 'system' and actor is null and actor_employee is null from audit_log order by id desc limit 1), 'owner writes are marked system and cannot claim an actor');
-- Through the API (session = authenticator) the 'seed' marker is ignored: real actions are never hidden as sample data.
select set_config('attendos.source', 'seed', false);
set session authorization authenticator; set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
update employees set phone = '+91 98200 44444' where email = 'gita@acme.in';
select pg_temp.expect((select source = 'app' and actor = '00000000-0000-0000-0000-00000000000b' from audit_log order by id desc limit 1), 'an API request cannot mark its action as sample data');
reset session authorization; select pg_temp.as_user(''); select set_config('attendos.source', '', false);
do $$ begin insert into public.audit_log (action, target) values ('update', 'note'); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - every audit entry has a company'; end $$;

-- ================================================================ adding people from the app (insert … returning, as PostgREST does)
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
create temp table t_new as with x as (insert into public.employees (full_name, email) values ('Read Back', 'readback@acme.in') returning id, emp_code) select * from x;
select pg_temp.expect((select count(*) from t_new where emp_code like 'E%') = 1, 'HR adds a person and reads the new row back in the same request');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select pg_temp.expect((select count(*) from employees) = (select count(*) from employees where id = '00000000-0000-0000-0000-00000000000c' or manager_id = '00000000-0000-0000-0000-00000000000c'),
  'a Manager still reads only themselves and their reports');
reset role; select pg_temp.as_user('');

-- ================================================================ exit workflow
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select pg_temp.expect(my_account_status() = 'active' and my_employee_id() = current_setting('test.isha')::uuid, 'Isha has access before leaving');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select set_config('test.people_before', (dashboard_summary() ->> 'people'), false);
update employees set employment_status = 'notice_period', exit_date = local_today(my_company()) where id = current_setting('test.isha')::uuid;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select pg_temp.expect(my_employee_id() is not null, 'on the last working day the person still has access');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
update employees set exit_date = local_today(my_company()) - 1 where id = current_setting('test.isha')::uuid;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select pg_temp.expect(my_employee_id() is null and my_account_status() = 'inactive', 'access ends automatically after the last working day');
select pg_temp.expect(punch('in') ->> 'code' = 'not_employee' and (select count(*) from employees) = 0, 'after the last day: no check-in, no data');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
do $$ begin update public.employees set employment_status = 'exited', exit_date = public.local_today(public.my_company()) + 5 where id = current_setting('test.isha')::uuid; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - exited with a future date refused (use notice period)'; end $$;
update employees set employment_status = 'exited' where id = current_setting('test.isha')::uuid;
select pg_temp.expect((select not active and exit_date = local_today(my_company()) - 1 from employees where id = current_setting('test.isha')::uuid), 'exit keeps the last working day and switches access off');
select pg_temp.expect((dashboard_summary() ->> 'people')::int = current_setting('test.people_before')::int - 1, 'people who left are not counted on the dashboard');
do $$ begin update public.employees set active = true where id = current_setting('test.isha')::uuid; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - cannot reactivate while status is Exited'; end $$;
do $$ begin update public.employees set employment_status = 'exited' where id = '00000000-0000-0000-0000-00000000000b'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - nobody can mark themselves exited'; end $$;
do $$ begin update public.employees set employment_status = 'exited' where id = '00000000-0000-0000-0000-00000000000a'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - HR cannot exit an Admin'; end $$;
reset role; select pg_temp.as_user('');
select pg_temp.expect((select count(*) from attendance_events where employee_id = current_setting('test.isha')::uuid) >= 0
  and (select count(*) from audit_log where target = 'employees' and target_id = current_setting('test.isha') and after ->> 'employment_status' = 'exited') = 1,
  'leaving keeps the record and logs the exit');
select pg_temp.expect((select count(*) from roster_pattern where employee_id = current_setting('test.isha')::uuid) = 1, 'roster pattern is kept while away');
-- Rejoining
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
update employees set employment_status = 'confirmed', active = true, joining_date = local_today(my_company()) where id = current_setting('test.isha')::uuid;
select pg_temp.expect((select active and exit_date is null and user_id = '00000000-0000-0000-0000-0000000000c1' from employees where id = current_setting('test.isha')::uuid),
  'rejoining clears the exit date and keeps the same login');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
select pg_temp.expect(my_employee_id() = current_setting('test.isha')::uuid, 'access is back after reactivation');
reset role; select pg_temp.as_user('');
select pg_temp.expect((select work_mode from plan_for(current_setting('test.isha')::uuid,
  local_today(current_setting('test.a')::uuid) + ((8 - extract(isodow from local_today(current_setting('test.a')::uuid))::int) % 7 + case when extract(isodow from local_today(current_setting('test.a')::uuid)) = 1 then 7 else 0 end))) = 'remote',
  'future roster (Monday remote) applies again after reactivation');
-- Days after someone left are not counted as absences
update employees set exit_date = local_today(company_id) - 2, joining_date = local_today(company_id) - 30 where id = '00000000-0000-0000-0000-00000000000f';
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select pg_temp.expect((select count(*) from attendance_history('00000000-0000-0000-0000-00000000000f', local_today(my_company()) - 6, local_today(my_company()))
                       where work_date > local_today(my_company()) - 2) = 0, 'history stops at the last working day');
select pg_temp.expect((select count(*) from attendance_history('00000000-0000-0000-0000-00000000000f', local_today(my_company()) - 6, local_today(my_company()))) = 5,
  'history before leaving is kept');

-- ================================================================ switched-off departments, designations, offices, shifts
update employees set designation_id = (select id from designations where name = 'Sales Executive') where id = current_setting('test.hari')::uuid;
update designations set active = false where name = 'Sales Executive';
select pg_temp.expect((select designation_id is not null from employees where id = current_setting('test.hari')::uuid), 'people keep a designation that was switched off');
update employees set phone = '+91 98200 33333' where id = current_setting('test.hari')::uuid;
select pg_temp.expect((select phone = '+91 98200 33333' from employees where id = current_setting('test.hari')::uuid), 'their record can still be edited');
do $$ begin update public.employees set designation_id = (select id from public.designations where name = 'Sales Executive') where id = current_setting('test.gita')::uuid; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - a switched-off designation cannot be newly assigned'; end $$;
do $$ begin insert into public.employees (full_name, email, designation_id) values ('New Person', 'new@acme.in', (select id from public.designations where name = 'Sales Executive')); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - new people cannot get a switched-off designation'; end $$;
do $$ begin delete from public.designations where name = 'Sales Executive'; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - designations are switched off, never deleted'; end $$;
update departments set active = false where name = 'Operations';
select pg_temp.expect((select d.name = 'Operations' from employees e join departments d on d.id = e.department_id where e.id = current_setting('test.gita')::uuid), 'people keep a department that was switched off');
do $$ begin update public.employees set department_id = (select id from public.departments where name = 'Operations') where id = current_setting('test.hari')::uuid; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - a switched-off department cannot be newly assigned'; end $$;
update departments set active = true where name = 'Operations';
update employees set department_id = (select id from departments where name = 'Operations') where id = current_setting('test.hari')::uuid;
select pg_temp.expect((select department_id is not null from employees where id = current_setting('test.hari')::uuid), 'switched back on: can be assigned again');
do $$ begin update public.departments set head_id = (select id from public.employees where email = 'kavya@acme.in') where name = 'Operations'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - department head must be active'; end $$;
insert into locations (name, lat, lng, radius_m, active) values ('Old Depot', 19.2, 72.9, 150, false);
do $$ begin update public.employees set home_location_id = (select id from public.locations where name = 'Old Depot') where id = current_setting('test.hari')::uuid; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - an office not in use cannot be assigned'; end $$;

-- ================================================================ multi-tenant: A HR vs company B
do $$ begin update public.designations set company_id = current_setting('test.b')::uuid where name = 'Plant Supervisor'; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - designation cannot be moved to another company'; end $$;
do $$ begin update public.departments set company_id = current_setting('test.b')::uuid where name = 'Operations'; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - department cannot be moved to another company'; end $$;
do $$ begin update public.employees set company_id = current_setting('test.b')::uuid where id = current_setting('test.hari')::uuid; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - employee cannot be moved to another company'; end $$;
do $$ begin insert into public.designations (name, company_id) values ('Spy', current_setting('test.b')::uuid); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - cannot create a designation in another company'; end $$;
do $$ begin insert into public.departments (name, company_id) values ('Spy Dept', current_setting('test.b')::uuid); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - cannot create a department in another company'; end $$;
do $$ begin insert into public.employees (full_name, email, company_id) values ('Spy Person', 'spy@acme.in', current_setting('test.b')::uuid); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - cannot add an employee to another company'; end $$;
do $$ begin update public.departments set name = 'Hacked' where id = current_setting('test.bdept')::uuid; if found then raise exception 'should fail'; end if;
raise notice 'ok - cannot edit another company''s department (no rows)'; end $$;
do $$ begin update public.employees set department_id = current_setting('test.bdept')::uuid where id = current_setting('test.hari')::uuid; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - cannot assign another company''s department'; end $$;
select pg_temp.expect((select count(*) from designations where company_id = current_setting('test.b')::uuid) = 0
  and (select count(*) from departments where company_id = current_setting('test.b')::uuid) = 0
  and (select count(*) from employees where company_id = current_setting('test.b')::uuid) = 0
  and (select count(*) from audit_log where company_id = current_setting('test.b')::uuid) = 0,
  'A HR reads none of B''s employees, departments, designations or audit entries even when asking by company');
update companies set name = 'Hacked' where id = current_setting('test.b')::uuid;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
do $$ begin update public.employees set company_id = current_setting('test.b')::uuid where id = '00000000-0000-0000-0000-00000000000a'; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - Admin cannot move themselves to another company'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a9');
do $$ begin update public.employees set company_id = current_setting('test.b')::uuid where email = 'gita@acme.in'; if found then raise exception 'should fail'; end if;
raise notice 'ok - an employee cannot change company_id (no rows)'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b0');
select pg_temp.expect((select name from companies) = 'Beta Logistics', 'B''s company was not renamed by A');
select pg_temp.expect(not exists (select 1 from people_directory() where full_name in ('Gita Rao', 'Hari Das')) and my_profile() ->> 'company' = 'Beta Logistics',
  'B directory and profile hold no A people');
select pg_temp.expect((select count(*) from designations) = 0 or not exists (select 1 from designations where name in ('Plant Supervisor', 'Sales Executive')), 'B sees no A designations');

-- ================================================================ sign-in linking
reset role; select pg_temp.as_user('');
select pg_temp.expect((select user_id from employees where email = 'kavya@acme.in') is null, 'Kavya (inactive) not linked yet');
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000c2', 'kavya@acme.in');
select pg_temp.expect((select user_id from employees where email = 'kavya@acme.in') is null, 'a confirmed login is not linked to a switched-off record');
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b0');
insert into employees (full_name, email) values ('Stan Ger', 'Stranger@Beta.co');
select pg_temp.expect((select user_id from employees where email = 'stranger@beta.co') = '00000000-0000-0000-0000-0000000000b9',
  'a login confirmed before HR added the person is linked when the record is created');
do $$ begin insert into public.employees (full_name, email) values ('Copy Gita', 'gita@acme.in'); raise exception 'should fail';
exception when unique_violation then raise notice 'ok - one work e-mail = one person across all companies'; end $$;
reset role; select pg_temp.as_user('');
-- The login of Gita changes e-mail (Supabase confirms the new address): the link only follows the work e-mail.
update auth.users set email = 'gita.private@gmail.com' where id = '00000000-0000-0000-0000-0000000000a9';
select pg_temp.expect((select user_id from employees where email = 'gita@acme.in') is null, 'login moved to a private e-mail is unlinked (no access)');
update auth.users set email = 'gita@acme.in' where id = '00000000-0000-0000-0000-0000000000a9';
select pg_temp.expect((select user_id from employees where email = 'gita@acme.in') = '00000000-0000-0000-0000-0000000000a9', 'back on the work e-mail: linked again');
-- A login that already belongs to one record is never linked to a second one.
insert into employees (company_id, full_name, email) values (current_setting('test.a')::uuid, 'Gita Second', 'gita.two@acme.in');
update auth.users set email_confirmed_at = now() where id = '00000000-0000-0000-0000-0000000000a9';
select pg_temp.expect((select count(*) from employees where user_id = '00000000-0000-0000-0000-0000000000a9') = 1, 'one login links to one employee only');
select pg_temp.expect((select count(*) from audit_log where target = 'employees' and source = 'system' and before ->> 'user_id' is not null and after ->> 'user_id' is null) >= 1,
  'unlinking is recorded in the audit log');
-- Removing a login (Supabase dashboard) keeps the employee record and history.
delete from auth.users where id = '00000000-0000-0000-0000-0000000000c2';
select pg_temp.expect(exists (select 1 from employees where email = 'kavya@acme.in'), 'deleting a login keeps the employee record');
-- Auth hook: only work e-mails HR added (and not yet linked) may create a login.
select pg_temp.expect(hook_before_user_created('{"user":{"email":"Gita.Two@acme.in"}}') = '{}'::jsonb, 'hook allows a work e-mail HR added');
select pg_temp.expect(hook_before_user_created('{"user":{"email":"random@gmail.com"}}') -> 'error' ->> 'http_code' = '403', 'hook refuses unknown e-mails');
select pg_temp.expect(hook_before_user_created('{"user":{"email":"gita@acme.in"}}') ? 'error', 'hook refuses an e-mail that already has a login');
select pg_temp.expect(hook_before_user_created('{"user":{"email":"kavya@acme.in"}}') ? 'error', 'hook refuses switched-off records');
set role authenticated;
do $$ begin perform public.hook_before_user_created('{}'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - users cannot call the Auth hook'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c9');
select pg_temp.expect(my_account_status() = 'not_linked', 'a login with no employee record is told it is not linked');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000f');
select pg_temp.expect(my_account_status() = 'inactive', 'an exited person is told their access is off');
do $$ begin perform public.day_for('00000000-0000-0000-0000-00000000000d', current_date); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - internal day calculation is not callable directly'; end $$;
reset role; select pg_temp.as_user(''); set role anon;
do $$ begin perform public.my_account_status(); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - anonymous cannot call account status'; end $$;
reset role; select pg_temp.as_user('');
select 'ALL VERIFICATION TESTS PASSED';
