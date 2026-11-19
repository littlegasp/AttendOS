\set ON_ERROR_STOP on
-- Phase 3 (0004). Company A: a=Admin, b=HR, c=Manager of d, d=Esha, e=inactive, f=Farhan. Company B: owner@beta.co admin, Ben.
reset role;
select set_config('test.ben', (select id::text from employees where email = 'ben@beta.co'), false);
set role authenticated;

-- HR adds people
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
insert into designations (name) values ('Sales Executive'), ('Plant Supervisor');
insert into departments (name, code, head_id, description) values ('Operations', 'OPS', '00000000-0000-0000-0000-00000000000c', 'Plant and logistics');
insert into employees (full_name, email, phone, joining_date, department_id, designation_id, employment_status)
  values ('Gita Rao', 'Gita@Acme.in', '+91 98200 11111', current_date - 10,
          (select id from departments where name = 'Operations'), (select id from designations where name = 'Plant Supervisor'), 'probation');
insert into employees (full_name, email) values ('Hari Das', 'hari@acme.in');
select pg_temp.expect((select emp_code from employees where email = 'gita@acme.in') = 'E0001', 'first employee ID generated (E0001)');
select pg_temp.expect((select emp_code from employees where email = 'hari@acme.in') = 'E0002', 'next employee ID follows');
select pg_temp.expect((select role from employees where email = 'gita@acme.in') = 'employee', 'new people start as Employee');
insert into employees (full_name, email, emp_code) values ('Isha Khan', 'isha@acme.in', ' ws-77 ');
select pg_temp.expect((select emp_code from employees where email = 'isha@acme.in') = 'WS-77', 'custom employee ID kept (tidied)');
do $$ begin insert into public.employees (full_name, email, emp_code) values ('Dup Code', 'dup@acme.in', 'WS-77'); raise exception 'should fail';
exception when unique_violation then raise notice 'ok - employee ID unique within the company'; end $$;
do $$ begin insert into public.employees (full_name, email) values ('Dup Mail', 'GITA@acme.in'); raise exception 'should fail';
exception when unique_violation then raise notice 'ok - e-mail can only be used once'; end $$;
do $$ begin insert into public.employees (full_name, email) values ('No Mail', 'not-an-email'); raise exception 'should fail';
exception when check_violation then raise notice 'ok - e-mail format checked'; end $$;
do $$ begin insert into public.employees (full_name, email, role) values ('Wannabe Boss', 'boss@acme.in', 'manager'); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - HR cannot create a Manager/HR/Admin (%)', sqlerrm; end $$;
do $$ begin update public.employees set role = 'manager' where email = 'gita@acme.in'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - HR cannot assign roles'; end $$;
do $$ begin update public.employees set active = false where id = '00000000-0000-0000-0000-00000000000a'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - HR cannot deactivate an Admin'; end $$;

-- Reporting lines
update employees set manager_id = '00000000-0000-0000-0000-00000000000c' where email = 'gita@acme.in';
do $$ begin update public.employees set manager_id = (select id from public.employees where email = 'gita@acme.in') where id = '00000000-0000-0000-0000-00000000000c'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - reporting loop refused'; end $$;
do $$ begin update public.employees set manager_id = id where email = 'hari@acme.in'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - cannot report to yourself'; end $$;
do $$ begin update public.employees set manager_id = '00000000-0000-0000-0000-00000000000e' where email = 'hari@acme.in'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - inactive manager refused'; end $$;

-- Cross-company references are refused for the new fields too
do $$ begin update public.departments set head_id = current_setting('test.ben')::uuid where name = 'Operations'; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - department head must be in the same company'; end $$;
do $$ begin perform 1;
  update public.employees set designation_id = gen_random_uuid() where email = 'hari@acme.in'; raise exception 'should fail';
exception when insufficient_privilege or foreign_key_violation then raise notice 'ok - unknown / foreign designation refused'; end $$;

-- Departments can't be hard-deleted (history refers to them)
do $$ begin delete from public.departments where name = 'Operations'; raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - departments are deactivated, not deleted'; end $$;

-- Admin assigns roles; the company always keeps an admin
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
update employees set role = 'manager' where email = 'hari@acme.in';
select pg_temp.expect((select role from employees where email = 'hari@acme.in') = 'manager', 'Admin assigns the Manager role');
insert into employees (full_name, email, role) values ('Kavya Admin', 'kavya@acme.in', 'admin');
select pg_temp.expect((select role from employees where email = 'kavya@acme.in') = 'admin', 'Admin can create another Admin');
do $$ begin update public.employees set role = 'employee' where id = '00000000-0000-0000-0000-00000000000a'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - cannot change your own role'; end $$;
update employees set active = false where email = 'kavya@acme.in';
reset role;
do $$ begin update public.employees set role = 'hr' where id = '00000000-0000-0000-0000-00000000000a'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - last active Admin cannot be removed (%)', sqlerrm; end $$;
set role authenticated;

-- Leaving switches access off
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
update employees set employment_status = 'exited' where id = '00000000-0000-0000-0000-00000000000f';
select pg_temp.expect((select not active and exit_date is not null from employees where id = '00000000-0000-0000-0000-00000000000f'), 'marking as exited deactivates and sets the exit date');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000f');
select pg_temp.expect(punch('in') ->> 'code' = 'not_employee', 'exited person cannot check in');
select pg_temp.expect((select count(*) from employees) = 0, 'exited person sees nothing');

-- New employee signs up: linked by e-mail
reset role;
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a9', 'gita@acme.in');
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a9');
select pg_temp.expect(my_profile() ->> 'manager' = 'Manoj Manager', 'employee sees own profile with manager name');
select pg_temp.expect(my_profile() ->> 'department' = 'Operations' and my_profile() ->> 'designation' = 'Plant Supervisor', 'profile shows department and designation');
select pg_temp.expect((select count(*) from employees) = 1, 'employee reads only own record');
select pg_temp.expect((select count(*) from people_directory()) = 1, 'employee directory shows only themselves');
update employees set full_name = 'Gita R' where email = 'gita@acme.in';
select pg_temp.expect((select full_name from employees where email = 'gita@acme.in') = 'Gita Rao', 'employee cannot edit own HR record');
do $$ begin insert into public.designations (name) values ('CEO'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - employee cannot add designations'; end $$;
do $$ begin insert into public.employees (full_name, email) values ('Sneaky', 'sneaky@acme.in'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - employee cannot add people'; end $$;

-- Manager sees their team (Esha, Gita) and themselves
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select pg_temp.expect((select count(*) from employees) = 3, 'manager sees self + team');
do $$ begin update public.employees set phone = '12345678' where email = 'gita@acme.in'; if found then raise exception 'should fail'; end if;
raise notice 'ok - manager cannot edit team records'; end $$;

-- HR: e-mail of a linked login can't be changed; directory shows everyone in the company only
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
do $$ begin update public.employees set email = 'g2@acme.in' where email = 'gita@acme.in'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - linked e-mail locked'; end $$;
select pg_temp.expect((select count(*) from people_directory()) = (select count(*) from employees), 'HR directory = company people');
select pg_temp.expect(not exists (select 1 from people_directory() where full_name like 'B%n %'), 'no other-company names in the directory');

-- Every important change is in the audit log
select pg_temp.expect((select count(*) from audit_log where target = 'employees' and action = 'insert') >= 4, 'new employees audited');
select pg_temp.expect(exists (select 1 from audit_log where target = 'employees' and before ->> 'role' = 'employee' and after ->> 'role' = 'manager'), 'role change audited with before/after');
select pg_temp.expect(exists (select 1 from audit_log where target = 'employees' and after ->> 'employment_status' = 'exited'), 'exit audited');
select pg_temp.expect(exists (select 1 from audit_log where target = 'departments' and action = 'insert'), 'department changes audited');
select pg_temp.expect(exists (select 1 from audit_log where target = 'designations'), 'designation changes audited');
select pg_temp.expect((select actor_employee from audit_log where target = 'employees' and after ->> 'employment_status' = 'exited' order by id desc limit 1) = '00000000-0000-0000-0000-00000000000b', 'audit records which employee made the change');

-- Company B is unaffected and can reuse the same employee ID
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b0');
insert into employees (full_name, email, emp_code) values ('Wes Seventy', 'wes@beta.co', 'WS-77');
select pg_temp.expect((select count(*) from employees where emp_code = 'WS-77') = 1, 'same employee ID allowed in another company (and A''s stays hidden)');

reset role;
select 'ALL EMPLOYEE TESTS PASSED';
