-- AttendOS 0005: Phase 3 verification fixes.
--   1. Sign-in: safe login ↔ employee linking (confirmed e-mail only, never twice, follows e-mail changes),
--      a status check for the sign-in page, and an optional Auth hook that only lets known work
--      e-mails create a login.
--   2. Audit log: the database (not the caller) fills in who/when/company/source; entries can't be
--      changed or deleted; sample/setup entries are marked apart from real actions.
--   3. Exit: exit date in the company's own time zone, access ends after the last day, reactivation rules,
--      days after leaving are not counted as absences.
--   4. Departments, designations, offices and shifts that are switched off can't be newly assigned.
-- Nothing is removed; existing data and functions keep working.

-- ================================================================ 1. sign-in and linking
-- Access needs an active employee record whose last day (if any) hasn't passed in the company's time zone.
create or replace function public.my_employee_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.employees
   where user_id = auth.uid() and active
     and (exit_date is null or exit_date >= public.local_today(company_id))
$$;

create or replace function public.my_company() returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from public.employees
   where user_id = auth.uid() and active
     and (exit_date is null or exit_date >= public.local_today(company_id))
$$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.employees
   where user_id = auth.uid() and active
     and (exit_date is null or exit_date >= public.local_today(company_id))
$$;

-- What the sign-in page tells someone whose login works but who has no access. Returns no personal data.
create function public.my_account_status() returns text
language sql stable security definer set search_path = public as $$
  select case
    when auth.uid() is null then 'signed_out'
    when public.my_employee_id() is not null then 'active'
    when exists (select 1 from public.employees where user_id = auth.uid()) then 'inactive'
    else 'not_linked' end
$$;

-- Link a confirmed login to the active employee with the same work e-mail — only if neither side is
-- already linked. Runs when the login is created, confirmed or changes e-mail (Supabase Auth writes auth.users).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- E-mail changed on a linked login: the link only holds while the login uses the work e-mail.
  if tg_op = 'UPDATE' and new.email is distinct from old.email then
    perform set_config('attendos.linking', 'on', true);
    update public.employees set user_id = null
     where user_id = new.id and lower(email) <> lower(coalesce(new.email, ''));
  end if;
  if new.email_confirmed_at is not null
     and not exists (select 1 from public.employees where user_id = new.id) then
    perform set_config('attendos.linking', 'on', true); -- tells the employee guard this is the sign-in link
    update public.employees set user_id = new.id
     where lower(email) = lower(new.email) and user_id is null and active;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_confirmed on auth.users;
create trigger on_auth_user_confirmed after update of email_confirmed_at, email on auth.users
  for each row when (old.email_confirmed_at is distinct from new.email_confirmed_at or old.email is distinct from new.email)
  execute function public.handle_new_user();

-- The employee guard also lets the link be removed (e-mail change above), nothing else.
create or replace function public.guard_employee_update() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is null then return new; end if; -- database owner (setup scripts)
  if current_setting('attendos.linking', true) = 'on' and new.user_id is distinct from old.user_id
     and (to_jsonb(new) - 'user_id' - 'updated_at') = (to_jsonb(old) - 'user_id' - 'updated_at') then
    return new; -- sign-in link set or removed by the database
  end if;
  if new.user_id is distinct from old.user_id then
    raise exception 'Logins are linked automatically by e-mail';
  end if;
  if new.role is distinct from old.role and not public.is_admin() then
    raise exception 'Only an administrator can change roles';
  end if;
  if old.user_id = auth.uid() and new.active is distinct from old.active then
    raise exception 'You cannot deactivate yourself';
  end if;
  if old.user_id = auth.uid() and new.role is distinct from old.role then
    raise exception 'You cannot change your own role';
  end if;
  if old.user_id = auth.uid() and new.employment_status is distinct from old.employment_status and new.employment_status = 'exited' then
    raise exception 'You cannot mark yourself as exited';
  end if;
  if old.role in ('admin', 'hr') and not public.is_admin()
     and (new.active is distinct from old.active or new.email is distinct from old.email
          or (new.employment_status is distinct from old.employment_status and new.employment_status = 'exited')) then
    raise exception 'Only an administrator can deactivate, exit or change the e-mail of an Admin or HR account';
  end if;
  if old.user_id is not null and new.email is distinct from old.email then
    raise exception 'The e-mail is linked to a login; it cannot be changed here';
  end if;
  new.updated_at := now();
  return new;
end $$;

-- A person who confirmed their e-mail before HR added them is linked as soon as the record exists
-- (or when HR corrects a mistyped e-mail on a record that has no login yet).
create function public.link_existing_login() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.user_id is null and new.active and (tg_op = 'INSERT' or new.email is distinct from old.email) then
    select u.id into new.user_id from auth.users u
     where lower(u.email) = lower(new.email) and u.email_confirmed_at is not null
       and not exists (select 1 from public.employees x where x.user_id = u.id)
     limit 1;
  end if;
  return new;
end $$;
-- Named to run after the guards (triggers fire in name order), so callers can't set user_id themselves.
create trigger zz_link_existing_login before insert or update of email on public.employees
  for each row execute function public.link_existing_login();

-- Optional Supabase Auth hook ("Before User Created"): only work e-mails that HR has added can create a
-- login. Turn it on in Authentication → Hooks (see docs/DEPLOYMENT.md). Without it, strangers can sign up
-- but are never linked and see nothing.
create function public.hook_before_user_created(event jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare em text := lower(coalesce(event -> 'user' ->> 'email', ''));
begin
  if em <> '' and exists (select 1 from public.employees where lower(email) = em and active and user_id is null) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object('http_code', 403,
    'message', 'This e-mail isn''t set up in AttendOS yet. Ask your HR team to add you with your work e-mail.'));
end $$;
revoke execute on function public.hook_before_user_created(jsonb) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    execute 'grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin';
    execute 'grant usage on schema public to supabase_auth_admin';
  end if;
end $$;

-- ================================================================ 2. audit log
alter table public.audit_log
  add column source text not null default 'app' check (source in ('app', 'system', 'seed'));
-- Entries written before this migration: from a signed-in person = app, otherwise setup/system.
update public.audit_log set source = case when actor is null then 'system' else 'app' end;

-- The database decides who, when, which company and the source — whatever the caller sent.
-- source: app = a signed-in person; seed = sample/demo data (setup scripts on the database set attendos.source = 'seed');
--         system = the database owner or Supabase Auth (sign-in linking, migrations).
create function public.audit_stamp() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.actor := auth.uid();
  new.actor_employee := case when auth.uid() is null then null else
    (select id from public.employees where user_id = auth.uid()) end;
  new.at := now();
  -- 'seed' is only honoured for setup scripts run directly on the database (never through the API,
  -- which connects as the authenticator role), so a real action can never be passed off as sample data.
  new.source := case when current_setting('attendos.source', true) = 'seed' and session_user <> 'authenticator' then 'seed'
                     when auth.uid() is not null then 'app'
                     else 'system' end;
  if new.company_id is null then raise exception 'Audit entry without a company'; end if;
  return new;
end $$;
create trigger audit_stamp before insert on public.audit_log for each row execute function public.audit_stamp();

-- Entries can't be edited or deleted — not through the app (no grant), and not by accident from the SQL
-- editor either. (The database owner can still disable this trigger; that is outside the application.)
create function public.audit_is_append_only() returns trigger
language plpgsql as $$
begin
  raise exception 'Audit entries cannot be changed or deleted' using errcode = '42501';
end $$;
create trigger audit_append_only before update or delete on public.audit_log
  for each row execute function public.audit_is_append_only();
create trigger audit_no_truncate before truncate on public.audit_log
  for each statement execute function public.audit_is_append_only();
revoke insert, update, delete, truncate on public.audit_log from authenticated, anon, public;

-- ================================================================ 3. exit and reactivation
create or replace function public.exit_switches_off() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.employment_status = 'exited' and old.employment_status is distinct from 'exited' then
    new.active := false;
    new.exit_date := coalesce(new.exit_date, public.local_today(new.company_id));
    if new.exit_date > public.local_today(new.company_id) then
      raise exception 'The exit date is in the future. Use “Notice period” with the last working day; access ends after that day.';
    end if;
  elsif old.employment_status = 'exited' and new.employment_status <> 'exited' then
    new.exit_date := null; -- rejoining: the earlier exit stays in the audit log
  elsif new.employment_status = 'exited' and new.active and not old.active then
    raise exception 'Change the employment status from “Exited” before reactivating';
  end if;
  return new;
end $$;

-- Days after the last working day are not attendance days (not counted as absent).
alter function public.day_for(uuid, date) rename to day_for_core;
create function public.day_for(emp uuid, d date) returns public.attendance_day
language plpgsql stable security definer set search_path = public as $$
declare
  r public.attendance_day := public.day_for_core(emp, d);
  ex date := (select exit_date from public.employees where id = emp);
begin
  if ex is not null and d > ex and r.first_in is null then
    r.status := 'left';
  end if;
  return r;
end $$;

create or replace function public.attendance_history(emp uuid, d_from date, d_to date)
returns setof public.attendance_day
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_see(emp) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if d_to < d_from or d_to - d_from > 92 then raise exception 'Choose a range of up to 92 days'; end if;
  return query select x.* from (select (public.day_for(emp, g::date)).* from generate_series(d_from, d_to, interval '1 day') g) x
               where x.status not in ('not_joined', 'left') order by x.work_date desc;
end $$;

-- ================================================================ 4. switched-off departments, designations, offices, shifts
-- Existing assignments stay (history stays correct); new or changed assignments must point at active ones.
create function public.check_active_refs() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.department_id is not null and (tg_op = 'INSERT' or new.department_id is distinct from old.department_id)
     and not (select active from public.departments where id = new.department_id) then
    raise exception 'That department is switched off. Choose an active department.';
  end if;
  if new.designation_id is not null and (tg_op = 'INSERT' or new.designation_id is distinct from old.designation_id)
     and not (select active from public.designations where id = new.designation_id) then
    raise exception 'That designation is switched off. Choose an active designation.';
  end if;
  if new.home_location_id is not null and (tg_op = 'INSERT' or new.home_location_id is distinct from old.home_location_id)
     and not (select active from public.locations where id = new.home_location_id) then
    raise exception 'That office is not in use. Choose an office that is in use.';
  end if;
  if new.default_shift_id is not null and (tg_op = 'INSERT' or new.default_shift_id is distinct from old.default_shift_id)
     and not (select active from public.shifts where id = new.default_shift_id) then
    raise exception 'That shift is switched off. Choose an active shift.';
  end if;
  return new;
end $$;
create trigger active_refs before insert or update on public.employees
  for each row execute function public.check_active_refs();

create function public.check_department_head() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.head_id is not null and (tg_op = 'INSERT' or new.head_id is distinct from old.head_id)
     and not coalesce((select active from public.employees where id = new.head_id), false) then
    raise exception 'The department head must be an active employee';
  end if;
  return new;
end $$;
create trigger department_head before insert or update on public.departments
  for each row execute function public.check_department_head();

-- ================================================================ 5. reading back a new employee
-- Found by the real sign-in check: the app adds a person and asks for the new row back (insert … returning).
-- The read policy used can_see(id), which looks the row up again and can't see it inside the same statement,
-- so adding an employee from the app failed with a permission error. The same rule, written on the row itself:
drop policy emp_read on public.employees;
create policy emp_read on public.employees for select to authenticated using (
  company_id = public.my_company()
  and (id = public.my_employee_id() or public.is_hr() or (manager_id = public.my_employee_id() and public.my_role() = 'manager'))
);

-- ================================================================ permissions
revoke execute on function public.audit_stamp(), public.audit_is_append_only(), public.link_existing_login(),
  public.check_active_refs(), public.check_department_head(), public.day_for_core(uuid, date), public.day_for(uuid, date),
  public.my_account_status() from public, anon, authenticated;
grant execute on function public.my_account_status() to authenticated;
