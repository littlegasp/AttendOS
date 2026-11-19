-- AttendOS 0004: Phase 3 — employee management and departments.
-- Extends the existing employees and departments tables (no duplicates) and adds designations.
-- Permissions are enforced here: HR/Admin manage people of their own company; only Admin
-- assigns roles; nobody can lock the company out by removing its last active Admin.

-- ---------------------------------------------------------------- designations
create table public.designations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null default public.my_company() references public.companies (id),
  name text not null check (length(trim(name)) between 2 and 80),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, name)
);
create index on public.designations (company_id);

-- ---------------------------------------------------------------- employee profile fields
alter table public.employees
  add column phone text check (phone is null or phone ~ '^[0-9+ ()-]{6,20}$'),
  add column designation_id uuid references public.designations (id),
  add column employment_status text not null default 'confirmed'
    check (employment_status in ('probation', 'confirmed', 'contract', 'intern', 'notice_period', 'exited')),
  add column exit_date date,
  add column updated_at timestamptz not null default now(),
  add constraint employees_email_format check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  add constraint employees_name_length check (length(trim(full_name)) between 2 and 120),
  add constraint employees_exit_after_join check (exit_date is null or joining_date is null or exit_date >= joining_date);
create index on public.employees (company_id, department_id);
create index on public.employees (company_id, active);

-- ---------------------------------------------------------------- departments: head and description
alter table public.departments
  add column head_id uuid references public.employees (id),
  add column description text check (description is null or length(description) <= 300),
  add constraint departments_name_length check (length(trim(name)) between 2 and 80);

-- Cross-company guards for the new references (same mechanism as 0003).
drop trigger company_refs on public.employees;
create trigger company_refs before insert or update on public.employees
  for each row execute function public.check_company_refs('department_id:departments', 'manager_id:employees', 'home_location_id:locations',
                                                          'default_shift_id:shifts', 'designation_id:designations');
create trigger company_refs before insert or update on public.departments
  for each row execute function public.check_company_refs('head_id:employees');
create trigger freeze_company before update on public.designations for each row execute function public.freeze_company_id();

-- ---------------------------------------------------------------- employee IDs
-- If HR leaves the employee ID empty, the next number in the company is used (E0001, E0002, …).
create function public.assign_employee_code() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if new.emp_code is null or trim(new.emp_code) = '' then
    perform pg_advisory_xact_lock(hashtextextended(new.company_id::text, 11));
    select coalesce(max((regexp_match(emp_code, '^E(\d+)$'))[1]::int), 0) + 1 into n
      from public.employees where company_id = new.company_id;
    new.emp_code := 'E' || lpad(n::text, 4, '0');
  else
    new.emp_code := upper(trim(new.emp_code));
  end if;
  new.email := lower(trim(new.email));
  new.full_name := trim(new.full_name);
  return new;
end $$;
create trigger employee_code before insert on public.employees for each row execute function public.assign_employee_code();

-- ---------------------------------------------------------------- people rules
create or replace function public.guard_employee_update() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is null then return new; end if; -- database owner (setup scripts)
  if current_setting('attendos.linking', true) = 'on' and old.user_id is null and new.user_id is not null
     and (to_jsonb(new) - 'user_id') = (to_jsonb(old) - 'user_id') then
    return new; -- sign-up link
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
  if old.role in ('admin', 'hr') and not public.is_admin()
     and (new.active is distinct from old.active or new.email is distinct from old.email) then
    raise exception 'Only an administrator can deactivate or change the e-mail of an Admin or HR account';
  end if;
  if old.user_id is not null and new.email is distinct from old.email then
    raise exception 'The e-mail is linked to a login; it cannot be changed here';
  end if;
  new.updated_at := now();
  return new;
end $$;

-- Reporting lines: same company (0003), never yourself, never a loop, manager must be active.
create function public.check_reporting_line() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  cur uuid := new.manager_id;
  steps int := 0;
begin
  if new.manager_id is null then return new; end if;
  if new.manager_id = new.id then raise exception 'Someone cannot report to themselves'; end if;
  if not (select active from public.employees where id = new.manager_id) then
    raise exception 'The reporting manager must be an active employee';
  end if;
  while cur is not null and steps < 100 loop
    if cur = new.id then raise exception 'This reporting line would make a loop'; end if;
    select manager_id into cur from public.employees where id = cur;
    steps := steps + 1;
  end loop;
  return new;
end $$;
create trigger reporting_line before insert or update of manager_id on public.employees
  for each row execute function public.check_reporting_line();

-- New people start as Employee unless an Admin chooses another role.
create function public.guard_employee_insert() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is not null and new.role <> 'employee' and not public.is_admin() then
    raise exception 'Only an administrator can create accounts with the % role', new.role;
  end if;
  if auth.uid() is not null and new.user_id is not null then
    raise exception 'Logins are linked automatically by e-mail';
  end if;
  return new;
end $$;
create trigger employees_insert_guard before insert on public.employees for each row execute function public.guard_employee_insert();

-- A company always keeps at least one active Admin.
create function public.keep_an_admin() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.role = 'admin' and old.active and (new.role <> 'admin' or not new.active)
     and not exists (select 1 from public.employees where company_id = old.company_id and role = 'admin' and active and id <> old.id) then
    raise exception 'This is the last active administrator of the company';
  end if;
  return new;
end $$;
create trigger keep_an_admin before update on public.employees for each row execute function public.keep_an_admin();

-- Leaving: marking someone as exited switches off their access on the same save.
create function public.exit_switches_off() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.employment_status = 'exited' and old.employment_status is distinct from 'exited' then
    new.active := false;
    new.exit_date := coalesce(new.exit_date, current_date);
  end if;
  return new;
end $$;
create trigger a_exit_switches_off before update on public.employees for each row execute function public.exit_switches_off();

-- Reassign reports when a manager is deactivated? No: HR decides. They are shown on the profile.

-- ---------------------------------------------------------------- audit: who, as an employee
-- The login id was already recorded (actor); the employee record makes the name shown in the
-- Activity log stable even if the login is later removed.
alter table public.audit_log add column actor_employee uuid default public.my_employee_id();

-- ---------------------------------------------------------------- the signed-in person's own profile (names included)
create function public.my_profile() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', e.id, 'emp_code', e.emp_code, 'full_name', e.full_name, 'email', e.email, 'phone', e.phone, 'role', e.role,
    'employment_status', e.employment_status, 'joining_date', e.joining_date,
    'department', d.name, 'designation', g.name, 'manager', m.full_name, 'manager_email', m.email,
    'office', l.name, 'default_shift', s.name, 'company', c.name)
  from public.employees e
  join public.companies c on c.id = e.company_id
  left join public.departments d on d.id = e.department_id
  left join public.designations g on g.id = e.designation_id
  left join public.employees m on m.id = e.manager_id
  left join public.locations l on l.id = e.home_location_id
  left join public.shifts s on s.id = e.default_shift_id
  where e.id = public.my_employee_id()
$$;

-- Names of people the caller may see in pickers (reporting manager, department head),
-- limited to their own company. Returns only name, ID, role and department — no contact details.
create function public.people_directory() returns table (id uuid, emp_code text, full_name text, role text, department_id uuid, active boolean)
language sql stable security definer set search_path = public as $$
  select e.id, e.emp_code, e.full_name, e.role, e.department_id, e.active
    from public.employees e
   where e.company_id = public.my_company() and (public.is_hr() or public.can_see(e.id))
   order by e.full_name
$$;

-- ---------------------------------------------------------------- security
alter table public.designations enable row level security;
revoke all on public.designations from anon;
grant select, insert, update on public.designations to authenticated;
create policy des_read on public.designations for select to authenticated using (company_id = public.my_company());
create policy des_write on public.designations for all to authenticated
  using (company_id = public.my_company() and public.is_hr()) with check (company_id = public.my_company() and public.is_hr());

-- Departments: no hard delete (history and dashboards refer to them); deactivate instead.
revoke delete on public.departments from authenticated;

create trigger audit_designations after insert or update or delete on public.designations for each row execute function public.audit();

revoke all on all functions in schema public from anon, public;
revoke execute on function public.assign_employee_code(), public.check_reporting_line(), public.keep_an_admin(),
  public.exit_switches_off(), public.guard_employee_insert() from authenticated;
grant execute on function public.my_profile(), public.people_directory() to authenticated;
grant execute on function public.company_brand(text) to anon, authenticated;
