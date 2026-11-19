-- AttendOS: create the Pilot 01 company. Run ONCE in the hosted SQL editor (as the project owner), after
-- migrations 0001–0008 and verify_hosted.sql all show ok. Replace the four values in the first block first.
-- It creates the company and its first Admin employee record only — no login is created here: the Admin signs
-- up afterwards at https://<site>/login?company=<slug> with exactly this e-mail.
begin;
select set_config('pilot.name',  'REPLACE: Company legal or display name', true);
select set_config('pilot.slug',  'REPLACE-lowercase-slug', true);            -- 2–40 chars: a–z, 0–9, hyphen
select set_config('pilot.email', 'REPLACE: admin work e-mail', true);
select set_config('pilot.admin', 'REPLACE: Admin full name', true);

do $$ begin
  if current_setting('pilot.name') like 'REPLACE%' or current_setting('pilot.slug') like 'REPLACE%'
     or current_setting('pilot.email') like 'REPLACE%' or current_setting('pilot.admin') like 'REPLACE%' then
    raise exception 'Fill in the four values first';
  end if;
  if exists (select 1 from public.companies where slug = lower(current_setting('pilot.slug'))) then
    raise exception 'A company with this address already exists';
  end if;
  if exists (select 1 from public.employees where lower(email) = lower(current_setting('pilot.email'))) then
    raise exception 'This e-mail already belongs to an employee record';
  end if;
end $$;

select public.create_company(current_setting('pilot.name'), lower(current_setting('pilot.slug')), 'Asia/Kolkata',
                             lower(current_setting('pilot.email')), current_setting('pilot.admin')) as company_id;

-- Check what was created before committing
select c.name, c.slug, c.timezone, e.full_name, e.email, e.role, e.emp_code, e.user_id is null as login_not_yet_linked,
       (select count(*) from public.leave_types t where t.company_id = c.id) as leave_types
  from public.companies c join public.employees e on e.company_id = c.id
 where c.slug = lower(current_setting('pilot.slug'));
commit;
-- (In the SQL editor, if anything above looks wrong, run "rollback;" instead of letting it commit.)
