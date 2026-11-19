\set ON_ERROR_STOP on
-- 0007: invitations. Runs after leave_reports_test.sql. Read Back (readback@acme.in) has no login yet.
reset role; select pg_temp.as_user('');
select set_config('test.rb', (select id::text from employees where email = 'readback@acme.in'), false);
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select set_config('test.inv', (prepare_invitation(current_setting('test.rb')::uuid) ->> 'id'), false);
select pg_temp.expect((select email = 'readback@acme.in' and status = 'sent' and invited_by = '00000000-0000-0000-0000-00000000000b' from employee_invitations where id = current_setting('test.inv')::bigint),
  'HR prepares an invitation; the e-mail comes from the employee record');
do $$ begin perform public.prepare_invitation(current_setting('test.rb')::uuid); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - no duplicate invitation within 10 minutes (%)', sqlerrm; end $$;
do $$ begin perform public.prepare_invitation('00000000-0000-0000-0000-00000000000d'); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - no invitation for someone who already has a login'; end $$;
do $$ begin perform public.prepare_invitation((select id from public.employees where email = 'kavya@acme.in')); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - no invitation while access is off'; end $$;
do $$ begin insert into public.employee_invitations (employee_id, email, invited_by) values (current_setting('test.rb')::uuid, 'attacker@evil.com', '00000000-0000-0000-0000-00000000000b'); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - invitations cannot be written directly (no chosen e-mail)'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select invitation_failed(current_setting('test.inv')::bigint, 'pretend');
select pg_temp.expect((select status from employee_invitations where id = current_setting('test.inv')::bigint) = 'sent', 'only the sender can mark an invitation failed');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select invitation_failed(current_setting('test.inv')::bigint, 'Email rate limit exceeded');
select pg_temp.expect((select status = 'failed' and error like 'Email rate%' from employee_invitations where id = current_setting('test.inv')::bigint), 'a failed send is recorded with the reason');
select set_config('test.inv2', (prepare_invitation(current_setting('test.rb')::uuid) ->> 'id'), false);
select pg_temp.expect(current_setting('test.inv2') <> '', 'after a failed send HR can send again at once');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
do $$ begin perform public.prepare_invitation(current_setting('test.rb')::uuid); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - employees cannot send invitations'; end $$;
select pg_temp.expect((select count(*) from employee_invitations) = 0, 'employees cannot see invitations');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
do $$ begin perform public.prepare_invitation(current_setting('test.rb')::uuid); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - managers cannot send invitations'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b0');
do $$ begin perform public.prepare_invitation(current_setting('test.rb')::uuid); raise exception 'should fail';
exception when insufficient_privilege then raise notice 'ok - another company cannot invite A''s people'; end $$;
select pg_temp.expect((select count(*) from employee_invitations) = 0, 'another company sees none of A''s invitations');
-- The person opens the link: Supabase Auth creates and confirms the login → linked → invitation accepted
reset role; select pg_temp.as_user('');
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000c5', 'ReadBack@acme.in');
select pg_temp.expect((select user_id from employees where id = current_setting('test.rb')::uuid) = '00000000-0000-0000-0000-0000000000c5'
  and (select status = 'accepted' and accepted_at is not null from employee_invitations where id = current_setting('test.inv2')::bigint), 'opening the link links the login and marks the invitation accepted');
select pg_temp.expect((select count(*) from audit_log where target = 'employee_invitations') >= 3, 'invitations are in the audit log');
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
do $$ begin perform public.prepare_invitation(current_setting('test.rb')::uuid); raise exception 'should fail';
exception when raise_exception then if sqlerrm = 'should fail' then raise; end if; raise notice 'ok - once linked, no more invitations'; end $$;
reset role; select pg_temp.as_user('');
select 'ALL INVITATION TESTS PASSED';
