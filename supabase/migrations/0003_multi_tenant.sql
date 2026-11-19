-- AttendOS 0003: multi-tenant (one shared database, many companies).
--
-- Isolation model
--   * Every company-owned table carries company_id; tables keyed by an employee inherit the
--     employee's company. Row level security only ever shows rows of the signed-in person's
--     company, and only within their role's scope (Admin/HR: company, Manager: team, Employee: self).
--   * Triggers reject any row that points at another company's employee, office, shift,
--     department or designation, so a crafted request can't link data across companies.
--   * Employee records are now separate from logins: HR creates the employee first; a login
--     (auth.users) is linked to the employee with the same e-mail once that address is confirmed.
--   * Each company has its own time zone (default Asia/Kolkata), attendance rules and branding.
-- Nothing from 0001/0002 is lost: existing rows are moved into the first company.

-- ---------------------------------------------------------------- companies (replaces the single-row organization)
create function public.valid_timezone(tz text) returns boolean
language sql stable as $$ select exists (select 1 from pg_timezone_names where name = tz) $$;

create table public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 120),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  timezone text not null default 'Asia/Kolkata' check (public.valid_timezone(timezone)),
  -- attendance rules (from organization)
  max_accuracy_m int not null default 100 check (max_accuracy_m between 10 and 2000),
  remote_location_required boolean not null default false,
  default_work_mode text not null default 'office' check (default_work_mode in ('office', 'remote')),
  weekly_off int[] not null default '{0}',
  default_shift_id uuid references public.shifts (id),
  -- branding: each company's people see their own name, logo and accent colour
  app_name text,
  logo_url text check (logo_url is null or logo_url ~ '^https://'),
  accent_dark text check (accent_dark is null or accent_dark ~ '^#[0-9A-Fa-f]{6}$'),
  accent_light text check (accent_light is null or accent_light ~ '^#[0-9A-Fa-f]{6}$'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Existing single-company data (if any) becomes the first company. A fresh install starts with
-- no company; the platform owner creates each one with create_company().
do $$
declare cid uuid;
begin
  if exists (select 1 from public.employees) or exists (select 1 from public.locations) then
    insert into public.companies (name, slug, timezone, max_accuracy_m, remote_location_required, default_work_mode, weekly_off, default_shift_id)
    select o.name, 'company', case when public.valid_timezone(o.timezone) then o.timezone else 'Asia/Kolkata' end,
           o.max_accuracy_m, o.remote_location_required, o.default_work_mode, o.weekly_off, o.default_shift_id
      from public.organization o where o.id = 1
    returning id into cid;
  end if;
  perform set_config('attendos.first_company', coalesce(cid::text, ''), false);
end $$;

-- ---------------------------------------------------------------- company_id on company-owned tables
alter table public.locations   add column company_id uuid references public.companies (id);
alter table public.departments add column company_id uuid references public.companies (id);
alter table public.employees   add column company_id uuid references public.companies (id);
alter table public.shifts      add column company_id uuid references public.companies (id);
alter table public.holidays    add column company_id uuid references public.companies (id);
alter table public.audit_log   add column company_id uuid references public.companies (id);

update public.locations   set company_id = nullif(current_setting('attendos.first_company'), '')::uuid;
update public.departments set company_id = nullif(current_setting('attendos.first_company'), '')::uuid;
update public.employees   set company_id = nullif(current_setting('attendos.first_company'), '')::uuid;
update public.shifts      set company_id = nullif(current_setting('attendos.first_company'), '')::uuid;
update public.holidays    set company_id = nullif(current_setting('attendos.first_company'), '')::uuid;
update public.audit_log   set company_id = nullif(current_setting('attendos.first_company'), '')::uuid;

alter table public.locations   alter column company_id set not null;
alter table public.departments alter column company_id set not null;
alter table public.employees   alter column company_id set not null;
alter table public.shifts      alter column company_id set not null;
alter table public.holidays    alter column company_id set not null;
create index on public.locations (company_id);
create index on public.employees (company_id);
create index on public.shifts (company_id);
create index on public.holidays (company_id, day);
create index on public.audit_log (company_id, at desc);

-- Uniqueness is per company now.
alter table public.departments drop constraint departments_name_key;
alter table public.departments add constraint departments_company_name_key unique (company_id, name);
alter table public.employees drop constraint employees_emp_code_key;
alter table public.employees add constraint employees_company_code_key unique (company_id, emp_code);
alter table public.holidays drop constraint holidays_day_location_id_key;
alter table public.holidays add constraint holidays_company_day_location_key unique nulls not distinct (company_id, day, location_id);

-- ---------------------------------------------------------------- employees separate from logins
alter table public.employees drop constraint employees_pkey cascade; -- also drops FKs that pointed at it
alter table public.employees drop constraint if exists employees_id_fkey; -- the old link to auth.users
alter table public.employees add primary key (id);
alter table public.employees alter column id set default gen_random_uuid();
alter table public.employees add column user_id uuid unique references auth.users (id) on delete set null;
update public.employees set user_id = id; -- existing employees were created from their login
create unique index employees_email_key on public.employees (lower(email));
alter table public.employees add column joining_date date; -- days before it are not counted as absent

-- Re-create the foreign keys dropped by the cascade above.
alter table public.employees add constraint employees_manager_id_fkey foreign key (manager_id) references public.employees (id);
alter table public.roster_pattern add constraint roster_pattern_employee_id_fkey foreign key (employee_id) references public.employees (id) on delete cascade;
alter table public.roster_day add constraint roster_day_employee_id_fkey foreign key (employee_id) references public.employees (id) on delete cascade;
alter table public.attendance_events add constraint attendance_events_employee_id_fkey foreign key (employee_id) references public.employees (id);
alter table public.attendance_attempts add constraint attendance_attempts_employee_id_fkey foreign key (employee_id) references public.employees (id);
alter table public.shift_pattern add constraint shift_pattern_employee_id_fkey foreign key (employee_id) references public.employees (id) on delete cascade;
alter table public.shift_day add constraint shift_day_employee_id_fkey foreign key (employee_id) references public.employees (id) on delete cascade;
alter table public.remote_exceptions add constraint remote_exceptions_employee_id_fkey foreign key (employee_id) references public.employees (id) on delete cascade;
alter table public.attendance_corrections add constraint attendance_corrections_employee_id_fkey foreign key (employee_id) references public.employees (id);

-- The single-row organization table is replaced by companies.
drop table public.organization cascade;
drop function if exists public.guard_organization_update();

-- ---------------------------------------------------------------- who is asking
create function public.my_employee_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.employees where user_id = auth.uid() and active
$$;

create function public.my_company() returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from public.employees where user_id = auth.uid() and active
$$;

create function public.emp_company(emp uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from public.employees where id = emp
$$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.employees where user_id = auth.uid() and active
$$;

-- is_hr()/is_admin() describe the role inside the caller's own company; every policy
-- pairs them with a same-company check.
create or replace function public.is_hr() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('admin', 'hr'), false)
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'admin', false)
$$;

create function public.in_my_company(emp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select emp is not null and public.emp_company(emp) = public.my_company()
$$;

create or replace function public.manages(emp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.employees e
    where e.id = emp and e.manager_id = public.my_employee_id() and e.company_id = public.my_company()
      and public.my_role() = 'manager'
  )
$$;

create or replace function public.can_see(emp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.in_my_company(emp) and (emp = public.my_employee_id() or public.is_hr() or public.manages(emp))
$$;

create function public.hr_of(emp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_hr() and public.in_my_company(emp)
$$;

-- ---------------------------------------------------------------- time per company
create function public.company_tz(c uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select timezone from public.companies where id = c), 'Asia/Kolkata')
$$;

drop function public.local_today();
create function public.local_today(c uuid) returns date
language sql stable as $$ select (now() at time zone public.company_tz(c))::date $$;

drop function public.at_local(date, time);
create function public.at_local(c uuid, d date, t time) returns timestamptz
language sql stable as $$ select (d + t) at time zone public.company_tz(c) $$;

drop function public.org_tz();

-- ---------------------------------------------------------------- cross-company reference guard
-- TG_ARGV: pairs of "column:table". Each referenced row must belong to the same company as the row.
create function public.check_company_refs() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  j jsonb := to_jsonb(new);
  row_company uuid;
  pair text;
  col text;
  tbl text;
  ref_company uuid;
  i int;
begin
  row_company := case
    when j ? 'company_id' then (j ->> 'company_id')::uuid
    when j ? 'employee_id' then public.emp_company((j ->> 'employee_id')::uuid)
  end;
  if row_company is null then raise exception 'Row has no company'; end if;
  for i in 0 .. tg_nargs - 1 loop
    pair := tg_argv[i];
    col := split_part(pair, ':', 1);
    tbl := split_part(pair, ':', 2);
    if j ->> col is not null then
      execute format('select company_id from public.%I where id = $1', tbl) into ref_company using (j ->> col)::uuid;
      if ref_company is distinct from row_company then
        raise exception 'Cross-company reference refused (%.%)', tg_table_name, col using errcode = '42501';
      end if;
    end if;
  end loop;
  return new;
end $$;

create trigger company_refs before insert or update on public.employees
  for each row execute function public.check_company_refs('department_id:departments', 'manager_id:employees', 'home_location_id:locations', 'default_shift_id:shifts');
create trigger company_refs before insert or update on public.holidays
  for each row execute function public.check_company_refs('location_id:locations');
create trigger company_refs before insert or update on public.roster_pattern
  for each row execute function public.check_company_refs('location_id:locations');
create trigger company_refs before insert or update on public.roster_day
  for each row execute function public.check_company_refs('location_id:locations');
create trigger company_refs before insert or update on public.shift_pattern
  for each row execute function public.check_company_refs('shift_id:shifts');
create trigger company_refs before insert or update on public.shift_day
  for each row execute function public.check_company_refs('shift_id:shifts');
create trigger company_refs before insert or update on public.attendance_events
  for each row execute function public.check_company_refs('location_id:locations');

create function public.check_company_default_shift() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.default_shift_id is not null and (select company_id from public.shifts where id = new.default_shift_id) is distinct from new.id then
    raise exception 'Cross-company reference refused (companies.default_shift_id)' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger company_refs before insert or update on public.companies
  for each row execute function public.check_company_default_shift();

-- company_id can never be moved to another company by a signed-in user.
create function public.freeze_company_id() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.company_id is distinct from old.company_id and auth.uid() is not null then
    raise exception 'Records cannot be moved to another company' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger freeze_company before update on public.locations for each row execute function public.freeze_company_id();
create trigger freeze_company before update on public.departments for each row execute function public.freeze_company_id();
create trigger freeze_company before update on public.employees for each row execute function public.freeze_company_id();
create trigger freeze_company before update on public.shifts for each row execute function public.freeze_company_id();
create trigger freeze_company before update on public.holidays for each row execute function public.freeze_company_id();

-- New rows default to the caller's company.
alter table public.locations   alter column company_id set default public.my_company();
alter table public.departments alter column company_id set default public.my_company();
alter table public.employees   alter column company_id set default public.my_company();
alter table public.shifts      alter column company_id set default public.my_company();
alter table public.holidays    alter column company_id set default public.my_company();

-- ---------------------------------------------------------------- logins ↔ employees
-- A login is linked to the employee with the same e-mail once the address is confirmed
-- (Supabase sets email_confirmed_at). Unconfirmed sign-ups get no access at all.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email_confirmed_at is not null then
    perform set_config('attendos.linking', 'on', true); -- tells the employee guard this is the sign-up link
    update public.employees set user_id = new.id
     where lower(email) = lower(new.email) and user_id is null and active;
  end if;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();
create trigger on_auth_user_confirmed after update of email_confirmed_at on auth.users
  for each row when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
  execute function public.handle_new_user();

-- Platform owner only (not granted to users): create a company and its first administrator.
-- The administrator gets access when they sign up / accept an invite with that e-mail.
create function public.create_company(p_name text, p_slug text, p_timezone text, p_admin_email text, p_admin_name text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  insert into public.companies (name, slug, timezone) values (trim(p_name), lower(trim(p_slug)), coalesce(p_timezone, 'Asia/Kolkata')) returning id into cid;
  insert into public.employees (company_id, full_name, email, role) values (cid, trim(p_admin_name), lower(trim(p_admin_email)), 'admin');
  update public.employees e set user_id = u.id from auth.users u
   where e.company_id = cid and lower(u.email) = e.email and u.email_confirmed_at is not null and e.user_id is null;
  return cid;
end $$;

-- ---------------------------------------------------------------- guards
create or replace function public.guard_employee_update() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is null then return new; end if; -- database owner (setup scripts)
  if current_setting('attendos.linking', true) = 'on' and old.user_id is null and new.user_id is not null
     and (to_jsonb(new) - 'user_id') = (to_jsonb(old) - 'user_id') then
    -- only the login link changes during sign-up
    return new;
  end if;
  if new.role is distinct from old.role and not public.is_admin() then
    raise exception 'Only an administrator can change roles';
  end if;
  if new.user_id is distinct from old.user_id then
    raise exception 'Logins are linked automatically by e-mail';
  end if;
  if old.user_id = auth.uid() and new.active is distinct from old.active then
    raise exception 'You cannot deactivate yourself';
  end if;
  if old.user_id = auth.uid() and new.role is distinct from old.role then
    raise exception 'You cannot change your own role';
  end if;
  return new;
end $$;

create function public.guard_company_update() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if not public.is_admin() or new.id <> public.my_company() then
    raise exception 'Only an administrator can change company settings';
  end if;
  if new.slug is distinct from old.slug or new.active is distinct from old.active then
    raise exception 'The company address and status are managed by the platform owner';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger company_guard before update on public.companies for each row execute function public.guard_company_update();

-- ---------------------------------------------------------------- audit (company-aware)
create or replace function public.audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  j jsonb := coalesce(to_jsonb(new), to_jsonb(old));
  k text := case tg_table_name
    when 'roster_pattern' then (j ->> 'employee_id') || ':' || (j ->> 'weekday')
    when 'roster_day' then (j ->> 'employee_id') || ':' || (j ->> 'day')
    when 'shift_pattern' then (j ->> 'employee_id') || ':' || (j ->> 'weekday')
    when 'shift_day' then (j ->> 'employee_id') || ':' || (j ->> 'day')
    else j ->> 'id' end;
  c uuid := case
    when tg_table_name = 'companies' then (j ->> 'id')::uuid
    when j ? 'company_id' then (j ->> 'company_id')::uuid
    when j ? 'employee_id' then public.emp_company((j ->> 'employee_id')::uuid)
  end;
begin
  insert into public.audit_log (company_id, action, target, target_id, before, after)
  values (c, lower(tg_op), tg_table_name, k,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

create trigger audit_companies after update on public.companies for each row execute function public.audit();
drop trigger audit_employees on public.employees;
create trigger audit_employees after insert or update on public.employees for each row execute function public.audit();
create trigger audit_departments after insert or update or delete on public.departments for each row execute function public.audit();
create trigger audit_shifts_delete after delete on public.shifts for each row execute function public.audit();

-- ---------------------------------------------------------------- plan / shift for a person (company-aware)
create or replace function public.plan_for(emp uuid, d date)
returns table (work_mode text, location_id uuid, source text, note text)
language sql stable security definer set search_path = public as $$
  with e as (select * from public.employees where id = emp),
  o as (select c.* from public.companies c, e where c.id = e.company_id),
  rd as (select r.work_mode, r.location_id, r.note from public.roster_day r where r.employee_id = emp and r.day = d),
  hol as (select h.name from public.holidays h, e where h.company_id = e.company_id and h.day = d
            and (h.location_id is null or h.location_id = e.home_location_id) limit 1),
  rp as (select r.work_mode, r.location_id from public.roster_pattern r where r.employee_id = emp and r.weekday = extract(dow from d)::int),
  base as (
    select coalesce(rp.work_mode, case when extract(dow from d)::int = any (o.weekly_off) then 'off' else o.default_work_mode end) as work_mode,
           case when rp.work_mode is not null then rp.location_id
                when extract(dow from d)::int = any (o.weekly_off) or o.default_work_mode <> 'office' then null
                else (select home_location_id from e) end as location_id,
           case when rp.work_mode is not null then 'pattern' else 'default' end as source
    from o left join rp on true
  ),
  exc as (select x.reason from public.remote_exceptions x where x.employee_id = emp and d between x.start_date and x.end_date limit 1)
  select x.work_mode, x.location_id, x.source, x.note from (
    select rd.work_mode, rd.location_id, 'day'::text, rd.note, 1 from rd
    union all
    select 'off', null::uuid, 'holiday', hol.name, 2 from hol
    union all
    select 'remote', null::uuid, 'exception', exc.reason, 3 from exc, base where base.work_mode = 'office'
    union all
    select base.work_mode, base.location_id, base.source, null, 4 from base
  ) x (work_mode, location_id, source, note, rank) order by rank limit 1
$$;

create or replace function public.shift_for(emp uuid, d date)
returns table (shift_id uuid, source text)
language sql stable security definer set search_path = public as $$
  select x.shift_id, x.source from (
    select sd.shift_id, 'day'::text, 1 from public.shift_day sd where sd.employee_id = emp and sd.day = d
    union all
    select sp.shift_id, 'pattern', 2 from public.shift_pattern sp where sp.employee_id = emp and sp.weekday = extract(dow from d)::int
    union all
    select e.default_shift_id, 'employee', 3 from public.employees e where e.id = emp and e.default_shift_id is not null
    union all
    select c.default_shift_id, 'company', 4 from public.employees e join public.companies c on c.id = e.company_id
     where e.id = emp and c.default_shift_id is not null
  ) x (shift_id, source, rank) order by rank limit 1
$$;

-- ---------------------------------------------------------------- one day of attendance (company time zone)
create or replace function public.day_for(emp uuid, d date) returns public.attendance_day
language plpgsql stable security definer set search_path = public as $$
declare
  r public.attendance_day;
  p record;
  s public.shifts;
  ev record;
  cid uuid := public.emp_company(emp);
  tz text := public.company_tz(cid);
  t_now timestamptz := now();
  today date := public.local_today(cid);
  seg_start timestamptz;
  brk_start timestamptz;
  worked interval := '0';
  brk interval := '0';
  last_kind text;
  sched_min int;
begin
  r.employee_id := emp;
  r.work_date := d;
  select * into p from public.plan_for(emp, d);
  r.work_mode := p.work_mode; r.plan_source := p.source; r.plan_note := p.note; r.location_id := p.location_id;
  if p.work_mode <> 'off' then
    select sh.* into s from public.shift_for(emp, d) f join public.shifts sh on sh.id = f.shift_id;
    if s.id is not null then
      r.shift_id := s.id; r.shift_name := s.name; r.break_allowance_min := s.break_minutes; r.grace_min := s.grace_minutes;
      r.shift_start := public.at_local(cid, d, s.start_time);
      r.shift_end := public.at_local(cid, d + case when s.end_time <= s.start_time then 1 else 0 end, s.end_time);
    end if;
  end if;

  for ev in select kind, at from public.attendance_events
            where employee_id = emp and work_date = d and superseded_by is null order by at, id loop
    if ev.kind = 'in' then
      if r.first_in is null then r.first_in := ev.at; end if;
      seg_start := ev.at; brk_start := null;
    elsif ev.kind = 'break_start' and seg_start is not null then
      worked := worked + (ev.at - seg_start); seg_start := null; brk_start := ev.at;
    elsif ev.kind = 'break_end' and brk_start is not null then
      brk := brk + (ev.at - brk_start); brk_start := null; seg_start := ev.at;
    elsif ev.kind = 'out' then
      if seg_start is not null then worked := worked + (ev.at - seg_start); end if;
      if brk_start is not null then brk := brk + (ev.at - brk_start); end if;
      seg_start := null; brk_start := null; r.last_out := ev.at;
    end if;
    last_kind := ev.kind;
  end loop;

  r.open := last_kind is not null and last_kind <> 'out';
  if r.open and (d = today or (r.shift_end is not null and t_now < r.shift_end + interval '4 hours')) then
    if seg_start is not null then worked := worked + (t_now - seg_start); end if;
    if brk_start is not null then brk := brk + (t_now - brk_start); end if;
  end if;
  r.worked_min := floor(extract(epoch from worked) / 60);
  r.break_min := floor(extract(epoch from brk) / 60);

  if r.first_in is not null and r.shift_start is not null and r.first_in > r.shift_start + make_interval(mins => r.grace_min) then
    r.late_min := floor(extract(epoch from (r.first_in - r.shift_start)) / 60);
  else
    r.late_min := 0;
  end if;
  if r.last_out is not null and not r.open and r.shift_end is not null and r.last_out < r.shift_end then
    r.early_min := floor(extract(epoch from (r.shift_end - r.last_out)) / 60);
  else
    r.early_min := 0;
  end if;
  if r.shift_start is not null and not r.open then
    sched_min := floor(extract(epoch from (r.shift_end - r.shift_start)) / 60) - r.break_allowance_min;
    r.overtime_min := greatest(0, r.worked_min - sched_min);
  else
    r.overtime_min := 0;
  end if;

  r.status := case
    when r.first_in is null and d < (select coalesce(e.joining_date, (e.created_at at time zone tz)::date) from public.employees e where e.id = emp) then 'not_joined'
    when r.first_in is not null and r.open and (d = today or (r.shift_end is not null and t_now < r.shift_end + interval '4 hours'))
      then case when brk_start is not null then 'on_break' else 'working' end
    when r.first_in is not null and r.open then 'missing_checkout'
    when r.first_in is not null and r.late_min > 0 then 'late'
    when r.first_in is not null then 'present'
    when p.work_mode = 'off' and p.source = 'holiday' then 'holiday'
    when p.work_mode = 'off' then 'off'
    when d > today then 'scheduled'
    when d = today and (r.shift_start is null or t_now < r.shift_start + make_interval(mins => coalesce(r.grace_min, 0))) then 'not_started'
    else 'absent' end;

  r.pending_correction := exists (select 1 from public.attendance_corrections c where c.employee_id = emp and c.work_date = d and c.status = 'pending');
  return r;
end $$;

create or replace function public.work_date_for_checkin(emp uuid) returns date
language plpgsql stable security definer set search_path = public as $$
declare
  cid uuid := public.emp_company(emp);
  today date := public.local_today(cid);
  y_shift public.shifts;
begin
  select sh.* into y_shift from public.shift_for(emp, today - 1) f join public.shifts sh on sh.id = f.shift_id;
  if y_shift.id is not null and y_shift.end_time <= y_shift.start_time
     and (select work_mode from public.plan_for(emp, today - 1)) <> 'off'
     and now() < public.at_local(cid, today, y_shift.end_time) then
    return today - 1;
  end if;
  return today;
end $$;

-- ---------------------------------------------------------------- my_today / punch
create or replace function public.my_today() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me public.employees;
  o public.companies;
  st record;
  d date;
  r public.attendance_day;
  loc public.locations;
  sh public.shifts;
begin
  select * into me from public.employees where id = public.my_employee_id();
  if me.id is null then return jsonb_build_object('ok', false, 'code', 'not_employee'); end if;
  select * into o from public.companies where id = me.company_id;
  select * into st from public.session_state(me.id);
  d := coalesce(st.work_date, public.work_date_for_checkin(me.id));
  r := public.day_for(me.id, d);
  if r.location_id is not null then select * into loc from public.locations where id = r.location_id; end if;
  if r.shift_id is not null then select * into sh from public.shifts where id = r.shift_id; end if;

  return jsonb_build_object(
    'ok', true,
    'server_now', now(),
    'timezone', o.timezone,
    'today', public.local_today(o.id),
    'work_date', d,
    'max_accuracy_m', o.max_accuracy_m,
    'remote_location_required', o.remote_location_required,
    'employee', jsonb_build_object('id', me.id, 'full_name', me.full_name, 'role', me.role),
    'plan', jsonb_build_object('work_mode', r.work_mode, 'source', r.plan_source, 'note', r.plan_note,
                               'location', case when loc.id is null then null else
                                 jsonb_build_object('id', loc.id, 'name', loc.name, 'radius_m', loc.radius_m) end),
    'shift', case when sh.id is null then null else jsonb_build_object(
               'name', sh.name, 'start', r.shift_start, 'end', r.shift_end, 'break_minutes', sh.break_minutes,
               'grace_minutes', sh.grace_minutes, 'overnight', sh.end_time <= sh.start_time) end,
    'state', st.state,
    'checked_in', st.state <> 'off',
    'open_since', st.open_since,
    'summary', jsonb_build_object('worked_min', r.worked_min, 'break_min', r.break_min, 'late_min', r.late_min,
                                  'early_min', r.early_min, 'overtime_min', r.overtime_min, 'status', r.status,
                                  'pending_correction', r.pending_correction),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'work_mode', e.work_mode, 'location', l.name,
                                          'distance_m', e.distance_m, 'accuracy_m', e.accuracy_m, 'verified', e.verified,
                                          'source', e.source) order by e.at, e.id)
      from public.attendance_events e left join public.locations l on l.id = e.location_id
      where e.employee_id = me.id and e.work_date = d and e.superseded_by is null
    ), '[]'::jsonb)
  );
end $$;

create or replace function public.punch(p_kind text, p_lat double precision default null, p_lng double precision default null, p_accuracy double precision default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me public.employees;
  o public.companies;
  st record;
  d date;
  p record;
  mode text;
  has_fix boolean := p_lat is not null and p_lng is not null and p_accuracy is not null;
  best record;
  ev public.attendance_events;
  acc int := case when p_accuracy is null then null else round(p_accuracy)::int end;
  plan_loc uuid;
  loc_name text;
begin
  if p_kind not in ('in', 'out', 'break_start', 'break_end') then
    return jsonb_build_object('ok', false, 'code', 'bad_request', 'message', 'Unknown action.');
  end if;
  if has_fix and (p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy < 0) then
    return jsonb_build_object('ok', false, 'code', 'bad_request', 'message', 'The location received is not valid.');
  end if;
  select * into me from public.employees where id = public.my_employee_id();
  if me.id is null then
    return jsonb_build_object('ok', false, 'code', 'not_employee', 'message', 'Your account is not set up as an active employee. Contact HR.');
  end if;

  perform pg_advisory_xact_lock(hashtextextended(me.id::text, 7));
  select * into o from public.companies where id = me.company_id;
  if not o.active then
    return jsonb_build_object('ok', false, 'code', 'not_employee', 'message', 'This company account is not active.');
  end if;
  select * into st from public.session_state(me.id);

  if p_kind = 'in' and st.state <> 'off' then
    return jsonb_build_object('ok', false, 'code', 'already_in', 'message', 'You are already checked in.', 'today', public.my_today());
  end if;
  if p_kind in ('out', 'break_start') and st.state = 'off' then
    return jsonb_build_object('ok', false, 'code', 'not_checked_in', 'message', 'You are not checked in.', 'today', public.my_today());
  end if;
  if p_kind = 'break_start' and st.state = 'on_break' then
    return jsonb_build_object('ok', false, 'code', 'already_on_break', 'message', 'You are already on a break.', 'today', public.my_today());
  end if;
  if p_kind = 'break_end' and st.state <> 'on_break' then
    return jsonb_build_object('ok', false, 'code', 'not_on_break', 'message', 'You are not on a break.', 'today', public.my_today());
  end if;

  if p_kind in ('break_start', 'break_end') then
    insert into public.attendance_events (employee_id, kind, work_mode, verified, work_date)
      values (me.id, p_kind, st.work_mode, false, st.work_date) returning * into ev;
    return jsonb_build_object('ok', true, 'event', jsonb_build_object('kind', ev.kind, 'at', ev.at, 'work_mode', ev.work_mode), 'today', public.my_today());
  end if;

  if p_kind = 'in' then
    d := public.work_date_for_checkin(me.id);
    select * into p from public.plan_for(me.id, d);
    if p.work_mode = 'off' then
      insert into public.attendance_attempts (employee_id, kind, reason) values (me.id, p_kind, 'day_off');
      return jsonb_build_object('ok', false, 'code', 'day_off',
        'message', case when p.source = 'holiday' then format('Today is a holiday (%s). If you have been asked to work, ask HR to update your roster.', p.note)
                        else 'Today is not a working day on your roster. If you have been asked to work, ask HR to update your roster.' end);
    end if;
    mode := p.work_mode;
    plan_loc := p.location_id;
  else
    d := st.work_date;
    mode := st.work_mode;
  end if;

  if mode = 'office' or (mode = 'remote' and o.remote_location_required) then
    if not has_fix then
      insert into public.attendance_attempts (employee_id, kind, reason) values (me.id, p_kind, 'location_required');
      return jsonb_build_object('ok', false, 'code', 'location_required', 'message', 'Your location is needed to verify this. Allow location access and try again.');
    end if;
    if acc > o.max_accuracy_m then
      insert into public.attendance_attempts (employee_id, kind, reason, accuracy_m) values (me.id, p_kind, 'accuracy_low', acc);
      return jsonb_build_object('ok', false, 'code', 'accuracy_low', 'accuracy_m', acc, 'max_accuracy_m', o.max_accuracy_m,
        'message', format('Location accuracy is %s m; it must be %s m or better. Move near a window or outdoors and try again.', acc, o.max_accuracy_m));
    end if;
  end if;

  if p_kind = 'out' and st.state = 'on_break' then
    insert into public.attendance_events (employee_id, kind, work_mode, verified, work_date) values (me.id, 'break_end', mode, false, d);
  end if;

  if mode = 'office' then
    -- Only this company's offices are considered.
    select l.id, l.name, l.radius_m, public.distance_m(p_lat, p_lng, l.lat, l.lng) as dist into best
      from public.locations l
     where l.company_id = me.company_id and l.active and (plan_loc is null or l.id = plan_loc)
     order by public.distance_m(p_lat, p_lng, l.lat, l.lng) - l.radius_m
     limit 1;
    if best.id is null then
      return jsonb_build_object('ok', false, 'code', 'no_office', 'message', 'No office location is set up yet. Ask HR or an administrator to add one.');
    end if;
    if best.dist > best.radius_m then
      insert into public.attendance_attempts (employee_id, kind, reason, accuracy_m, distance_m) values (me.id, p_kind, 'outside_area', acc, best.dist);
      return jsonb_build_object('ok', false, 'code', 'outside_area', 'distance_m', best.dist, 'radius_m', best.radius_m, 'location', best.name,
        'message', format('You are about %s m from %s; you need to be within %s m.', best.dist, best.name, best.radius_m));
    end if;
    insert into public.attendance_events (employee_id, kind, work_mode, location_id, distance_m, accuracy_m, verified, work_date)
      values (me.id, p_kind, 'office', best.id, best.dist, acc, true, d) returning * into ev;
    loc_name := best.name;
  else
    insert into public.attendance_events (employee_id, kind, work_mode, accuracy_m, verified, work_date)
      values (me.id, p_kind, 'remote', acc, has_fix and acc <= o.max_accuracy_m, d) returning * into ev;
  end if;

  if has_fix then
    insert into public.attendance_coords (event_id, lat, lng) values (ev.id, round(p_lat::numeric, 6), round(p_lng::numeric, 6));
  end if;

  return jsonb_build_object('ok', true, 'event', jsonb_build_object('kind', ev.kind, 'at', ev.at, 'work_mode', ev.work_mode,
           'location', loc_name, 'distance_m', ev.distance_m), 'today', public.my_today());
end $$;

-- ---------------------------------------------------------------- corrections
create or replace function public.request_correction(p_work_date date, p_kind text, p_in timestamptz, p_out timestamptz, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.my_employee_id();
  cid uuid := public.my_company();
  c public.attendance_corrections;
  lo timestamptz;
  hi timestamptz;
begin
  if me is null then
    return jsonb_build_object('ok', false, 'message', 'Your account is not an active employee.');
  end if;
  lo := public.at_local(cid, p_work_date, '00:00');
  hi := public.at_local(cid, p_work_date + 2, '00:00');
  if p_work_date > public.local_today(cid) or p_work_date < public.local_today(cid) - 31 then
    return jsonb_build_object('ok', false, 'message', 'Corrections can be requested for the last 31 days only.');
  end if;
  if p_kind not in ('missing_in', 'missing_out', 'wrong_time', 'other') then
    return jsonb_build_object('ok', false, 'message', 'Choose what needs correcting.');
  end if;
  if (p_kind = 'missing_in' and p_in is null) or (p_kind = 'missing_out' and p_out is null) or (p_kind = 'wrong_time' and p_in is null and p_out is null) then
    return jsonb_build_object('ok', false, 'message', 'Enter the correct time.');
  end if;
  if (p_in is not null and (p_in < lo or p_in >= hi)) or (p_out is not null and (p_out < lo or p_out >= hi)) or p_in > now() or p_out > now() then
    return jsonb_build_object('ok', false, 'message', 'The times must be on that work day (or the next morning for overnight shifts) and not in the future.');
  end if;
  if p_in is not null and p_out is not null and p_out <= p_in then
    return jsonb_build_object('ok', false, 'message', 'Check-out must be after check-in.');
  end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then
    return jsonb_build_object('ok', false, 'message', 'Write a short reason (at least 5 characters).');
  end if;
  if exists (select 1 from public.attendance_corrections where employee_id = me and work_date = p_work_date and status = 'pending') then
    return jsonb_build_object('ok', false, 'message', 'There is already a pending request for this day.');
  end if;
  insert into public.attendance_corrections (employee_id, work_date, kind, requested_in, requested_out, reason)
    values (me, p_work_date, p_kind, p_in, p_out, trim(p_reason)) returning * into c;
  return jsonb_build_object('ok', true, 'id', c.id);
end $$;

create or replace function public.cancel_correction(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update public.attendance_corrections set status = 'cancelled', decided_at = now(), decided_by = auth.uid()
   where id = p_id and employee_id = public.my_employee_id() and status = 'pending';
  if not found then return jsonb_build_object('ok', false, 'message', 'Only your own pending requests can be cancelled.'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.decide_correction(p_id bigint, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.attendance_corrections;
  p record;
  m text;
begin
  select * into c from public.attendance_corrections where id = p_id for update;
  if c.id is null or not public.in_my_company(c.employee_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if c.status <> 'pending' then return jsonb_build_object('ok', false, 'message', 'This request is no longer pending.'); end if;
  if c.employee_id = public.my_employee_id() then return jsonb_build_object('ok', false, 'message', 'You cannot decide your own request.'); end if;
  if not (public.hr_of(c.employee_id) or public.manages(c.employee_id)) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if not p_approve and length(trim(coalesce(p_note, ''))) < 3 then
    return jsonb_build_object('ok', false, 'message', 'Give a short reason for rejecting.');
  end if;

  if p_approve then
    select * into p from public.plan_for(c.employee_id, c.work_date);
    m := case when p.work_mode = 'remote' then 'remote' else 'office' end;
    if c.requested_in is not null then
      update public.attendance_events set superseded_by = c.id
       where employee_id = c.employee_id and work_date = c.work_date and kind = 'in' and superseded_by is null
         and at = (select min(at) from public.attendance_events where employee_id = c.employee_id and work_date = c.work_date and kind = 'in' and superseded_by is null);
      insert into public.attendance_events (employee_id, kind, at, work_mode, location_id, verified, source, work_date, correction_id)
        values (c.employee_id, 'in', c.requested_in, m, p.location_id, false, 'correction', c.work_date, c.id);
    end if;
    if c.requested_out is not null then
      update public.attendance_events set superseded_by = c.id
       where employee_id = c.employee_id and work_date = c.work_date and kind = 'out' and superseded_by is null
         and at = (select max(at) from public.attendance_events where employee_id = c.employee_id and work_date = c.work_date and kind = 'out' and superseded_by is null);
      insert into public.attendance_events (employee_id, kind, at, work_mode, location_id, verified, source, work_date, correction_id)
        values (c.employee_id, 'out', c.requested_out, m, p.location_id, false, 'correction', c.work_date, c.id);
    end if;
  end if;

  update public.attendance_corrections
     set status = case when p_approve then 'approved' else 'rejected' end, decided_by = auth.uid(), decided_at = now(),
         decision_note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_id;
  insert into public.audit_log (company_id, action, target, target_id, before, after)
    values (public.emp_company(c.employee_id), case when p_approve then 'approve' else 'reject' end, 'attendance_corrections', p_id::text, to_jsonb(c),
            (select to_jsonb(x) from public.attendance_corrections x where x.id = p_id));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- verification history (own company only)
create or replace function public.verification_log(p_limit int default 100)
returns table (at timestamptz, employee text, kind text, outcome text, work_mode text, location text, distance_m int, accuracy_m int, reason text)
language plpgsql stable security definer set search_path = public as $$
declare cid uuid := public.my_company();
begin
  if not public.is_hr() then raise exception 'Not allowed' using errcode = '42501'; end if;
  return query
  select * from (
    select e.at, emp.full_name, e.kind,
           case when e.source = 'correction' then 'corrected' when e.verified then 'verified' else 'not_required' end,
           e.work_mode, l.name, e.distance_m, e.accuracy_m, null::text
      from public.attendance_events e join public.employees emp on emp.id = e.employee_id
      left join public.locations l on l.id = e.location_id
     where e.kind in ('in', 'out') and emp.company_id = cid
    union all
    select a.at, emp.full_name, a.kind, 'refused', null, null, a.distance_m, a.accuracy_m, a.reason
      from public.attendance_attempts a join public.employees emp on emp.id = a.employee_id
     where emp.company_id = cid
  ) x order by 1 desc limit least(greatest(p_limit, 1), 500);
end $$;

-- ---------------------------------------------------------------- dashboard (own company, role scope)
create or replace function public.dashboard_summary() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  cid uuid := public.my_company();
  today date;
  role text := public.my_role();
  me uuid := public.my_employee_id();
  scope text;
  res jsonb;
begin
  if role is null or cid is null then return jsonb_build_object('ok', false, 'code', 'not_employee'); end if;
  today := public.local_today(cid);
  scope := case when role in ('admin', 'hr') then 'organization' when role = 'manager' then 'team' else 'personal' end;

  with people as (
    select e.id, e.full_name, coalesce(dp.name, 'No department') as dept
      from public.employees e left join public.departments dp on dp.id = e.department_id
     where e.active and e.company_id = cid and public.can_see(e.id)
  ),
  t as (select pp.full_name, pp.dept, (public.day_for(pp.id, today)).* from people pp),
  y as (select (public.day_for(pp.id, today - 1)).* from people pp),
  att as (select * from t where status in ('present', 'late', 'working', 'on_break', 'missing_checkout')),
  due_t as (select count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout', 'absent')) n,
                   count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout')) a from t),
  due_y as (select count(*) filter (where status in ('present', 'late', 'missing_checkout', 'absent')) n,
                   count(*) filter (where status in ('present', 'late', 'missing_checkout')) a from y)
  select jsonb_build_object(
    'ok', true, 'scope', scope, 'today', today, 'timezone', public.company_tz(cid), 'server_now', now(),
    'people', (select count(*) from people),
    'rate', jsonb_build_object(
      'today', (select case when n > 0 then round(100.0 * a / n, 1) end from due_t),
      'today_attended', (select a from due_t), 'today_due', (select n from due_t),
      'yesterday', (select case when n > 0 then round(100.0 * a / n, 1) end from due_y)),
    'distribution', (select jsonb_object_agg(status, n) from (select status, count(*) n from t group by status) s),
    'late_today', (select count(*) from t where late_min > 0),
    'by_department', coalesce((select jsonb_agg(jsonb_build_object('department', dept, 'attended', a, 'due', n) order by dept) from (
        select dept, count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout')) a,
                     count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout', 'absent')) n
          from t group by dept) d), '[]'),
    'working_now', coalesce((select jsonb_agg(jsonb_build_object('name', full_name, 'since', first_in, 'work_mode', work_mode,
        'location', (select name from public.locations where id = att.location_id), 'on_break', status = 'on_break', 'late_min', late_min) order by first_in)
        from att where status in ('working', 'on_break')), '[]'),
    'not_checked_in', coalesce((select jsonb_agg(jsonb_build_object('name', full_name, 'shift_start', shift_start, 'status', status,
        'work_mode', work_mode) order by shift_start nulls last, full_name)
        from t where status in ('absent', 'not_started')), '[]'),
    'pending_corrections', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', e.full_name, 'work_date', c.work_date,
        'kind', c.kind, 'requested_in', c.requested_in, 'requested_out', c.requested_out, 'reason', c.reason, 'requested_at', c.requested_at,
        'can_decide', c.employee_id <> me and (public.is_hr() or public.manages(c.employee_id))) order by c.requested_at)
        from public.attendance_corrections c join public.employees e on e.id = c.employee_id
       where c.status = 'pending' and e.company_id = cid and public.can_see(c.employee_id)), '[]'),
    'upcoming_holidays', coalesce((select jsonb_agg(jsonb_build_object('day', h.day, 'name', h.name, 'location', l.name) order by h.day)
        from (select * from public.holidays where company_id = cid and day >= today order by day limit 5) h left join public.locations l on l.id = h.location_id), '[]'),
    'recent_activity', coalesce((select jsonb_agg(x order by (x ->> 'at') desc) from (
        select jsonb_build_object('name', e.full_name, 'kind', ev.kind, 'at', ev.at, 'work_mode', ev.work_mode, 'location', l.name,
                                  'source', ev.source) x
          from public.attendance_events ev join public.employees e on e.id = ev.employee_id
          left join public.locations l on l.id = ev.location_id
         where e.company_id = cid and ev.at > now() - interval '2 days' and public.can_see(ev.employee_id) and ev.superseded_by is null
         order by ev.at desc limit 12) r), '[]')
  ) into res;
  return res;
end $$;

-- ---------------------------------------------------------------- branding for the sign-in page (no personal data)
create function public.company_brand(p_slug text)
returns table (name text, app_name text, logo_url text, accent_dark text, accent_light text)
language sql stable security definer set search_path = public as $$
  select c.name, c.app_name, c.logo_url, c.accent_dark, c.accent_light from public.companies c where c.slug = lower(p_slug) and c.active
$$;

-- ---------------------------------------------------------------- row level security (all re-created company-aware)
do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies where schemaname = 'public' loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

alter table public.companies enable row level security;
revoke all on public.companies from anon;
grant select, update on public.companies to authenticated;
grant select, insert, update on public.employees to authenticated;
grant delete on public.departments to authenticated;

create policy co_read on public.companies for select to authenticated using (id = public.my_company());
create policy co_admin on public.companies for update to authenticated using (id = public.my_company() and public.is_admin()) with check (id = public.my_company() and public.is_admin());

create policy loc_read on public.locations for select to authenticated using (company_id = public.my_company());
create policy loc_ins on public.locations for insert to authenticated with check (company_id = public.my_company() and public.is_hr());
create policy loc_upd on public.locations for update to authenticated using (company_id = public.my_company() and public.is_hr()) with check (company_id = public.my_company() and public.is_hr());

create policy dep_read on public.departments for select to authenticated using (company_id = public.my_company());
create policy dep_write on public.departments for all to authenticated using (company_id = public.my_company() and public.is_hr()) with check (company_id = public.my_company() and public.is_hr());

create policy emp_read on public.employees for select to authenticated using (public.can_see(id));
create policy emp_ins on public.employees for insert to authenticated with check (company_id = public.my_company() and public.is_hr());
create policy emp_upd on public.employees for update to authenticated using (public.hr_of(id)) with check (company_id = public.my_company() and public.is_hr());

create policy sh_read on public.shifts for select to authenticated using (company_id = public.my_company());
create policy sh_ins on public.shifts for insert to authenticated with check (company_id = public.my_company() and public.is_hr());
create policy sh_upd on public.shifts for update to authenticated using (company_id = public.my_company() and public.is_hr()) with check (company_id = public.my_company() and public.is_hr());

create policy hol_read on public.holidays for select to authenticated using (company_id = public.my_company());
create policy hol_write on public.holidays for all to authenticated using (company_id = public.my_company() and public.is_hr()) with check (company_id = public.my_company() and public.is_hr());

create policy rp_read on public.roster_pattern for select to authenticated using (public.can_see(employee_id));
create policy rp_write on public.roster_pattern for all to authenticated using (public.hr_of(employee_id)) with check (public.hr_of(employee_id));
create policy rd_read on public.roster_day for select to authenticated using (public.can_see(employee_id));
create policy rd_write on public.roster_day for all to authenticated using (public.hr_of(employee_id)) with check (public.hr_of(employee_id));
create policy sp_read on public.shift_pattern for select to authenticated using (public.can_see(employee_id));
create policy sp_write on public.shift_pattern for all to authenticated using (public.hr_of(employee_id)) with check (public.hr_of(employee_id));
create policy sd_read on public.shift_day for select to authenticated using (public.can_see(employee_id));
create policy sd_write on public.shift_day for all to authenticated using (public.hr_of(employee_id)) with check (public.hr_of(employee_id));
create policy rx_read on public.remote_exceptions for select to authenticated using (public.can_see(employee_id));
create policy rx_write on public.remote_exceptions for all to authenticated using (public.hr_of(employee_id)) with check (public.hr_of(employee_id));

create policy ev_read on public.attendance_events for select to authenticated using (public.can_see(employee_id));
create policy coords_read on public.attendance_coords for select to authenticated using (
  exists (select 1 from public.attendance_events e where e.id = event_id
           and (public.hr_of(e.employee_id) or e.employee_id = public.my_employee_id())));
create policy at_read on public.attendance_attempts for select to authenticated using (employee_id = public.my_employee_id() or public.hr_of(employee_id));
create policy corr_read on public.attendance_corrections for select to authenticated using (public.can_see(employee_id));
create policy audit_read on public.audit_log for select to authenticated using (company_id = public.my_company() and public.is_hr());

-- ---------------------------------------------------------------- function access
revoke all on all functions in schema public from anon, public;
revoke execute on function public.plan_for(uuid, date), public.shift_for(uuid, date), public.session_state(uuid),
  public.day_for(uuid, date), public.work_date_for_checkin(uuid), public.emp_company(uuid),
  public.create_company(text, text, text, text, text), public.check_company_refs(), public.handle_new_user()
  from authenticated;
grant execute on function
  public.my_employee_id(), public.my_company(), public.my_role(), public.is_hr(), public.is_admin(),
  public.in_my_company(uuid), public.manages(uuid), public.can_see(uuid), public.hr_of(uuid),
  public.company_tz(uuid), public.local_today(uuid), public.at_local(uuid, date, time), public.valid_timezone(text),
  public.attendance_history(uuid, date, date), public.my_today(),
  public.punch(text, double precision, double precision, double precision),
  public.request_correction(date, text, timestamptz, timestamptz, text), public.cancel_correction(bigint),
  public.decide_correction(bigint, boolean, text), public.verification_log(int), public.dashboard_summary(),
  public.set_roster_pattern(uuid[], jsonb), public.set_shift_pattern(uuid[], jsonb),
  public.distance_m(double precision, double precision, double precision, double precision)
to authenticated;
grant execute on function public.company_brand(text) to anon, authenticated;
