\set ON_ERROR_STOP on
-- 0009: a login confirmed while access was off is linked when access is switched back on. Runs last.
reset role; select pg_temp.as_user('');
insert into employees (company_id, full_name, email, active)
  select company_id, 'Off Duty', 'offduty@acme.in', false from employees where email = 'readback@acme.in';
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000c9', 'offduty@acme.in'); -- confirmed now
select pg_temp.expect((select user_id is null from employees where email = 'offduty@acme.in'), 'a login confirmed while access is off is not linked');
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b'); -- HR
update employees set active = true where email = 'offduty@acme.in';
select pg_temp.expect((select user_id = '00000000-0000-0000-0000-0000000000c9' from employees where email = 'offduty@acme.in'), 'switching access back on links that confirmed login');
do $$ begin update public.employees set user_id = null where email = 'offduty@acme.in'; raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - HR still cannot set or clear a login link by hand'; end $$;
-- A login already linked to someone else is never taken over on reactivation.
reset role; select pg_temp.as_user('');
insert into employees (company_id, full_name, email, active)
  select company_id, 'Second Record', 'second@acme.in', false from employees where email = 'readback@acme.in';
update auth.users set email = 'second@acme.in' where id = '00000000-0000-0000-0000-0000000000c9'; -- login changes address
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
update employees set active = true where email = 'second@acme.in';
select pg_temp.expect((select count(*) from employees where user_id = '00000000-0000-0000-0000-0000000000c9') = 1, 'one login is never linked to two records');
reset role; select pg_temp.as_user('');
select 'ALL RELINK TESTS PASSED';
