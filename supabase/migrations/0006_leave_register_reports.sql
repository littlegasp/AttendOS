-- AttendOS 0006: Phase 4 (leave, attendance register) and Phase 5 (reports, settings, user access).
-- Follows the multi-company rules: company_id on every new table, policies through my_company() / can_see(),
-- cross-company references refused, company_id frozen, audit triggers. Leave requests change only through
-- checked functions (no direct writes).

-- ================================================================ company settings (Phase 5)
alter table public.companies
  add column date_format text not null default 'DD MMM YYYY' check (date_format in ('DD MMM YYYY', 'DD/MM/YYYY', 'MM/DD/YYYY', 'YYYY-MM-DD')),
  add column full_day_minutes int check (full_day_minutes is null or full_day_minutes between 60 and 960),
  add column leave_year_start_month int not null default 1 check (leave_year_start_month between 1 and 12);
comment on column public.companies.full_day_minutes is 'Half-day rule: a present day with less worked time than this counts as a half day in reports (null = off).';
comment on column public.companies.leave_year_start_month is 'Leave balances run for 12 months from this month (1 = January–December, 4 = April–March).';

-- ================================================================ leave types
create table public.leave_types (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null default public.my_company() references public.companies (id),
  name text not null check (length(trim(name)) between 2 and 40),
  code text not null check (code ~ '^[A-Z]{1,4}$'),
  paid boolean not null default true,
  yearly_days numeric(5,1) check (yearly_days is null or yearly_days between 0 and 365), -- null = no limit (e.g. Unpaid)
  needs_approval boolean not null default true,
  allow_half_day boolean not null default true,
  max_backdate_days int not null default 30 check (max_backdate_days between 0 and 365),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, name),
  unique (company_id, code)
);
create index on public.leave_types (company_id);

create function public.add_default_leave_types(c uuid) returns void
language sql security definer set search_path = public as $$
  insert into public.leave_types (company_id, name, code, paid, yearly_days) values
    (c, 'Casual', 'CL', true, 12), (c, 'Sick', 'SL', true, 8), (c, 'Earned', 'EL', true, 15), (c, 'Unpaid', 'UL', false, null)
  on conflict do nothing
$$;
select public.add_default_leave_types(id) from public.companies;
create function public.company_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.add_default_leave_types(new.id);
  return new;
end $$;
create trigger company_defaults after insert on public.companies for each row execute function public.company_defaults();

-- ================================================================ leave requests and balance adjustments
create table public.leave_requests (
  id bigint generated always as identity primary key,
  employee_id uuid not null references public.employees (id) on delete cascade,
  leave_type_id uuid not null references public.leave_types (id),
  start_date date not null,
  end_date date not null,
  half_day text check (half_day in ('first', 'second')),
  days numeric(5,1) not null check (days > 0),
  reason text not null check (length(trim(reason)) between 3 and 500),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  requested_by uuid not null, -- employee who filed it (the person, or HR on their behalf)
  requested_at timestamptz not null default now(),
  decided_by uuid,            -- employee who approved / rejected / cancelled
  decided_at timestamptz,
  decision_note text check (decision_note is null or length(decision_note) <= 300),
  check (end_date >= start_date),
  check (half_day is null or start_date = end_date)
);
create index on public.leave_requests (employee_id, start_date);
create index on public.leave_requests (status);

create table public.leave_adjustments (
  id bigint generated always as identity primary key,
  employee_id uuid not null references public.employees (id) on delete cascade,
  leave_type_id uuid not null references public.leave_types (id),
  year_start date not null,
  days numeric(5,1) not null check (days <> 0 and days between -365 and 365),
  reason text not null check (length(trim(reason)) between 3 and 200),
  created_by uuid not null default public.my_employee_id(),
  created_at timestamptz not null default now()
);
create index on public.leave_adjustments (employee_id, year_start);

create trigger company_refs before insert or update on public.leave_requests
  for each row execute function public.check_company_refs('leave_type_id:leave_types');
create trigger company_refs before insert or update on public.leave_adjustments
  for each row execute function public.check_company_refs('leave_type_id:leave_types');
create trigger freeze_company before update on public.leave_types for each row execute function public.freeze_company_id();

-- ================================================================ leave helpers
-- Start of the leave year that contains d, for the employee's company.
create function public.leave_year_start(c uuid, d date) returns date
language sql stable security definer set search_path = public as $$
  select make_date(extract(year from d)::int - case when extract(month from d)::int < m then 1 else 0 end, m, 1)
    from (select leave_year_start_month m from public.companies where id = c) s
$$;

-- Working days of a person between two dates: days their roster/holidays don't mark as off.
create function public.leave_days(emp uuid, d_from date, d_to date, half text) returns numeric
language sql stable security definer set search_path = public as $$
  select (case when half is not null then 0.5 else 1 end) *
    (select count(*) from generate_series(d_from, d_to, interval '1 day') g
      where (select work_mode from public.plan_for(emp, g::date)) <> 'off')::numeric
$$;

-- Approved full- or half-day leave on a date (for attendance, check-in and reports).
create function public.leave_on(emp uuid, d date) returns public.leave_requests
language sql stable security definer set search_path = public as $$
  select * from public.leave_requests
   where employee_id = emp and status = 'approved' and d between start_date and end_date
   order by half_day nulls first limit 1
$$;

-- Balance per leave type for one person and leave year. Pending requests are held back from "available".
create function public.leave_balance(emp uuid, p_year_start date default null)
returns table (leave_type_id uuid, name text, code text, paid boolean, yearly_days numeric, adjustments numeric,
               taken numeric, pending numeric, available numeric, year_start date, year_end date)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  c uuid := public.emp_company(emp);
  ys date;
begin
  if not public.can_see(emp) then raise exception 'Not allowed' using errcode = '42501'; end if;
  ys := coalesce(p_year_start, public.leave_year_start(c, public.local_today(c)));
  return query
  select t.id, t.name, t.code, t.paid, t.yearly_days,
         coalesce((select sum(a.days) from public.leave_adjustments a where a.employee_id = emp and a.leave_type_id = t.id and a.year_start = ys), 0),
         coalesce((select sum(r.days) from public.leave_requests r where r.employee_id = emp and r.leave_type_id = t.id and r.status = 'approved'
                    and r.start_date >= ys and r.start_date < (ys + interval '1 year')::date), 0),
         coalesce((select sum(r.days) from public.leave_requests r where r.employee_id = emp and r.leave_type_id = t.id and r.status = 'pending'
                    and r.start_date >= ys and r.start_date < (ys + interval '1 year')::date), 0),
         null::numeric, ys, ((ys + interval '1 year')::date - 1)
    from public.leave_types t
   where t.company_id = c and (t.active or exists (select 1 from public.leave_requests r where r.employee_id = emp and r.leave_type_id = t.id))
   order by t.paid desc, t.name;
end $$;

-- available = yearly days + adjustments − taken − pending (null when the type has no limit)
create or replace function public.leave_balance_view(emp uuid, p_year_start date default null)
returns table (leave_type_id uuid, name text, code text, paid boolean, yearly_days numeric, adjustments numeric,
               taken numeric, pending numeric, available numeric, year_start date, year_end date)
language sql stable security definer set search_path = public as $$
  select b.leave_type_id, b.name, b.code, b.paid, b.yearly_days, b.adjustments, b.taken, b.pending,
         case when b.yearly_days is null then null else b.yearly_days + b.adjustments - b.taken - b.pending end,
         b.year_start, b.year_end
    from public.leave_balance(emp, p_year_start) b
$$;

-- ================================================================ apply / decide / cancel / adjust
create function public.apply_leave(p_type uuid, p_start date, p_end date, p_half text, p_reason text, p_employee uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.my_employee_id();
  emp uuid := coalesce(p_employee, me);
  e public.employees;
  t public.leave_types;
  today date;
  n numeric;
  ys date;
  avail numeric;
  clash record;
  id_ bigint;
  st text;
  on_behalf boolean := p_employee is not null and p_employee <> me;
begin
  if me is null then raise exception 'Not signed in as an active employee' using errcode = '42501'; end if;
  if on_behalf and not public.hr_of(emp) then raise exception 'Only HR can record leave for someone else' using errcode = '42501'; end if;
  select * into e from public.employees where id = emp;
  select * into t from public.leave_types where id = p_type and company_id = e.company_id;
  if t.id is null or not t.active then raise exception 'Choose an active leave type'; end if;
  today := public.local_today(e.company_id);
  if p_start is null or p_end is null or p_end < p_start then raise exception 'The end date must be on or after the start date'; end if;
  if p_end - p_start > 90 then raise exception 'A single request can cover at most 91 days'; end if;
  if p_half is not null and (p_half not in ('first', 'second') or p_start <> p_end) then raise exception 'A half day must be a single date'; end if;
  if p_half is not null and not t.allow_half_day then raise exception '% leave cannot be taken as a half day', t.name; end if;
  if not on_behalf and p_start < today - t.max_backdate_days then
    raise exception '% leave can be applied at most % days back. Ask HR to record it.', t.name, t.max_backdate_days;
  end if;
  if e.joining_date is not null and p_start < e.joining_date then raise exception 'The dates are before the joining date'; end if;
  if e.exit_date is not null and p_end > e.exit_date then raise exception 'The dates are after the last working day'; end if;
  if public.leave_year_start(e.company_id, p_start) <> public.leave_year_start(e.company_id, p_end) then
    raise exception 'The dates cross into the next leave year. Apply separately for each year.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(emp::text, 21));
  select r.start_date, r.end_date, r.status into clash from public.leave_requests r
   where r.employee_id = emp and r.status in ('pending', 'approved') and r.start_date <= p_end and r.end_date >= p_start
     and not (p_half is not null and r.half_day is not null and r.half_day <> p_half)
   limit 1;
  if clash.start_date is not null then
    raise exception 'This overlaps a % request (% – %)', clash.status, to_char(clash.start_date, 'DD Mon'), to_char(clash.end_date, 'DD Mon');
  end if;
  if p_half is null and exists (select 1 from public.attendance_events v where v.employee_id = emp and v.work_date between p_start and p_end and v.superseded_by is null) then
    raise exception 'There is attendance on one of these days. Choose a half day or other dates.';
  end if;
  n := public.leave_days(emp, p_start, p_end, p_half);
  if n = 0 then raise exception 'These dates are all days off or holidays — no leave needed'; end if;
  ys := public.leave_year_start(e.company_id, p_start);
  select b.available into avail from public.leave_balance_view(emp, ys) b where b.leave_type_id = t.id;
  if t.yearly_days is not null and avail < n then
    raise exception 'Not enough % leave: % day(s) available, % requested', t.name, avail, n;
  end if;
  st := case when on_behalf or not t.needs_approval then 'approved' else 'pending' end;
  insert into public.leave_requests (employee_id, leave_type_id, start_date, end_date, half_day, days, reason, status, requested_by,
                                     decided_by, decided_at, decision_note)
  values (emp, t.id, p_start, p_end, p_half, n, trim(p_reason), st, me,
          case when st = 'approved' then me end, case when st = 'approved' then now() end,
          case when on_behalf then 'Recorded by HR' when st = 'approved' then 'No approval needed for this leave type' end)
  returning id into id_;
  return jsonb_build_object('ok', true, 'id', id_, 'days', n, 'status', st);
end $$;

create function public.decide_leave(p_id bigint, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r public.leave_requests;
  t public.leave_types;
  me uuid := public.my_employee_id();
  avail numeric;
begin
  select * into r from public.leave_requests where id = p_id for update;
  if r.id is null or not public.can_see(r.employee_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.employee_id = me then raise exception 'You cannot decide your own leave' using errcode = '42501'; end if;
  if not (public.hr_of(r.employee_id) or public.manages(r.employee_id)) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.status <> 'pending' then raise exception 'This request was already %', r.status; end if;
  if not p_approve and (p_note is null or length(trim(p_note)) < 3) then raise exception 'Give a short reason when rejecting'; end if;
  if p_approve then
    select * into t from public.leave_types where id = r.leave_type_id;
    select b.available + r.days into avail from public.leave_balance_view(r.employee_id, public.leave_year_start(public.emp_company(r.employee_id), r.start_date)) b
     where b.leave_type_id = r.leave_type_id;
    if t.yearly_days is not null and avail < r.days then raise exception 'Not enough % leave left to approve this', t.name; end if;
    if r.half_day is null and exists (select 1 from public.attendance_events v where v.employee_id = r.employee_id
                                       and v.work_date between r.start_date and r.end_date and v.superseded_by is null) then
      raise exception 'They have attendance on one of these days; ask them to change the request';
    end if;
  end if;
  update public.leave_requests set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = me, decided_at = now(), decision_note = nullif(trim(p_note), '')
   where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- The person cancels their own pending request, or an approved one that hasn't started; HR can cancel any.
create function public.cancel_leave(p_id bigint, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r public.leave_requests;
  me uuid := public.my_employee_id();
  hr boolean;
begin
  select * into r from public.leave_requests where id = p_id for update;
  if r.id is null or not public.can_see(r.employee_id) then raise exception 'Not allowed' using errcode = '42501'; end if;
  hr := public.hr_of(r.employee_id) and r.employee_id <> me;
  if not (r.employee_id = me or hr) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if r.status not in ('pending', 'approved') then raise exception 'This request is already %', r.status; end if;
  if r.status = 'approved' and not hr and r.start_date <= public.local_today(public.emp_company(r.employee_id)) then
    raise exception 'Leave that has started can only be cancelled by HR';
  end if;
  update public.leave_requests set status = 'cancelled', decided_by = me, decided_at = now(),
         decision_note = coalesce(nullif(trim(p_note), ''), case when hr then 'Cancelled by HR' else 'Cancelled by the employee' end)
   where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create function public.adjust_leave(p_employee uuid, p_type uuid, p_days numeric, p_reason text, p_year_start date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c uuid := public.emp_company(p_employee);
begin
  if not public.hr_of(p_employee) or p_employee = public.my_employee_id() then raise exception 'Only HR can adjust balances (not their own)' using errcode = '42501'; end if;
  insert into public.leave_adjustments (employee_id, leave_type_id, year_start, days, reason)
  values (p_employee, p_type, coalesce(p_year_start, public.leave_year_start(c, public.local_today(c))), p_days, trim(p_reason));
  return jsonb_build_object('ok', true);
end $$;


-- Shown in the form before submitting: days counted, balance left, and any conflict (nothing is saved).
create function public.leave_preview(p_type uuid, p_start date, p_end date, p_half text, p_employee uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  emp uuid := coalesce(p_employee, public.my_employee_id());
  t public.leave_types;
  n numeric;
  avail numeric;
  clash record;
begin
  if emp is null or not public.can_see(emp) or (p_employee is not null and p_employee <> public.my_employee_id() and not public.hr_of(emp)) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  select * into t from public.leave_types where id = p_type and company_id = public.emp_company(emp);
  if t.id is null or p_start is null or p_end is null or p_end < p_start or p_end - p_start > 90 then return jsonb_build_object('ok', false); end if;
  n := public.leave_days(emp, p_start, p_end, case when p_start = p_end then p_half end);
  select b.available into avail from public.leave_balance_view(emp, public.leave_year_start(public.emp_company(emp), p_start)) b where b.leave_type_id = t.id;
  select r.start_date, r.end_date, r.status into clash from public.leave_requests r
   where r.employee_id = emp and r.status in ('pending', 'approved') and r.start_date <= p_end and r.end_date >= p_start limit 1;
  return jsonb_build_object('ok', true, 'days', n, 'available', avail, 'unlimited', t.yearly_days is null,
    'overlap', case when clash.start_date is null then null else jsonb_build_object('status', clash.status, 'start', clash.start_date, 'end', clash.end_date) end,
    'attendance', exists (select 1 from public.attendance_events v where v.employee_id = emp and v.work_date between p_start and p_end and v.superseded_by is null));
end $$;

-- Requests visible to the caller in a date window (calendar, team requests). Names only, no contact details.
create function public.leave_list(p_from date, p_to date, p_status text default null)
returns table (id bigint, employee_id uuid, full_name text, emp_code text, department text, leave_type text, code text,
               start_date date, end_date date, half_day text, days numeric, reason text, status text,
               requested_at timestamptz, requested_by_name text, decided_by_name text, decided_at timestamptz, decision_note text, can_decide boolean, can_cancel boolean)
language sql stable security definer set search_path = public as $$
  select r.id, r.employee_id, e.full_name, e.emp_code, d.name, t.name, t.code, r.start_date, r.end_date, r.half_day, r.days, r.reason, r.status,
         r.requested_at, rb.full_name, db.full_name, r.decided_at, r.decision_note,
         r.status = 'pending' and r.employee_id <> public.my_employee_id() and (public.hr_of(r.employee_id) or public.manages(r.employee_id)),
         r.status in ('pending', 'approved') and (
           (r.employee_id = public.my_employee_id() and (r.status = 'pending' or r.start_date > public.local_today(e.company_id)))
           or (public.hr_of(r.employee_id) and r.employee_id <> public.my_employee_id()))
    from public.leave_requests r
    join public.employees e on e.id = r.employee_id
    join public.leave_types t on t.id = r.leave_type_id
    left join public.departments d on d.id = e.department_id
    left join public.employees rb on rb.id = r.requested_by
    left join public.employees db on db.id = r.decided_by
   where e.company_id = public.my_company() and public.can_see(r.employee_id)
     and r.start_date <= p_to and r.end_date >= p_from
     and (p_status is null or r.status = p_status)
   order by r.start_date desc, e.full_name
$$;

-- ================================================================ leave in attendance
-- Approved leave makes a day "on_leave" instead of absent (a half day only when nobody checked in).
create or replace function public.day_for(emp uuid, d date) returns public.attendance_day
language plpgsql stable security definer set search_path = public as $$
declare
  r public.attendance_day := public.day_for_core(emp, d);
  ex date := (select exit_date from public.employees where id = emp);
  lv public.leave_requests;
begin
  if ex is not null and d > ex and r.first_in is null then
    r.status := 'left';
    return r;
  end if;
  if r.first_in is null and r.status in ('absent', 'not_started', 'scheduled') then
    lv := public.leave_on(emp, d);
    if lv.id is not null then r.status := 'on_leave'; r.plan_note := coalesce((select name from public.leave_types where id = lv.leave_type_id), 'Leave'); end if;
  end if;
  return r;
end $$;

-- Check-in on a full day of approved leave is refused (cancel the leave first, or ask HR).
alter function public.punch(text, double precision, double precision, double precision) rename to punch_core;
create function public.punch(p_kind text, p_lat double precision default null, p_lng double precision default null, p_accuracy double precision default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.my_employee_id();
  lv public.leave_requests;
begin
  if p_kind = 'in' and me is not null then
    lv := public.leave_on(me, public.work_date_for_checkin(me));
    if lv.id is not null and lv.half_day is null then
      return jsonb_build_object('ok', false, 'code', 'on_leave',
        'message', 'You are on approved leave today. Cancel the leave first if you are working, or ask HR.', 'today', public.my_today());
    end if;
  end if;
  return public.punch_core(p_kind, p_lat, p_lng, p_accuracy);
end $$;

alter function public.my_today() rename to my_today_core;
create function public.my_today() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  t jsonb := public.my_today_core();
  lv public.leave_requests;
begin
  if not coalesce((t ->> 'ok')::boolean, false) then return t; end if;
  lv := public.leave_on(public.my_employee_id(), (t ->> 'work_date')::date);
  if lv.id is null then return t || jsonb_build_object('leave', null); end if;
  return t || jsonb_build_object('leave', jsonb_build_object('id', lv.id, 'type', (select name from public.leave_types where id = lv.leave_type_id),
                                                             'half_day', lv.half_day, 'start', lv.start_date, 'end', lv.end_date));
end $$;

alter function public.dashboard_summary() rename to dashboard_summary_core;
-- Performance: (f()).* calls f once per output column; the same summary with one day_for() call per person.
create or replace function public.dashboard_summary_core() returns jsonb
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
  t as (select pp.full_name, pp.dept, dd.* from people pp cross join lateral public.day_for(pp.id, today) dd),
  y as (select dd.* from people pp cross join lateral public.day_for(pp.id, today - 1) dd),
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

create or replace function public.attendance_history(emp uuid, d_from date, d_to date)
returns setof public.attendance_day
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_see(emp) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if d_to < d_from or d_to - d_from > 92 then raise exception 'Choose a range of up to 92 days'; end if;
  return query select dd.* from generate_series(d_from, d_to, interval '1 day') g cross join lateral public.day_for(emp, g::date) dd
               where dd.status not in ('not_joined', 'left') order by dd.work_date desc;
end $$;

create function public.dashboard_summary() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  s jsonb := public.dashboard_summary_core();
  cid uuid := public.my_company();
  today date;
begin
  if not coalesce((s ->> 'ok')::boolean, false) then return s; end if;
  today := public.local_today(cid);
  return s || jsonb_build_object(
    'on_leave_today', coalesce((s -> 'distribution' ->> 'on_leave')::int, 0),
    'on_leave', coalesce((select jsonb_agg(jsonb_build_object('name', l.full_name, 'type', l.leave_type, 'half_day', l.half_day, 'end', l.end_date) order by l.full_name)
                            from public.leave_list(today, today, 'approved') l), '[]'),
    'pending_leave', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.full_name, 'type', l.leave_type, 'start', l.start_date,
                                 'end', l.end_date, 'days', l.days, 'half_day', l.half_day, 'reason', l.reason, 'can_decide', l.can_decide) order by l.requested_at)
                                 from public.leave_list(today - 31, today + 366, 'pending') l), '[]'));
end $$;

-- ================================================================ attendance register and reports (one scope for all)
-- Every visible person × day in a range, with filters. The single source for the register, reports and exports,
-- so an export can never show more than the screen. At most 92 days per call.
create function public.report_days(p_from date, p_to date, p_department uuid default null, p_employee uuid default null, p_shift uuid default null)
returns table (employee_id uuid, emp_code text, full_name text, department text, designation text, work_date date, work_mode text,
               shift_name text, first_in timestamptz, last_out timestamptz, worked_min int, break_min int, late_min int, early_min int,
               overtime_min int, status text, note text, pending_correction boolean, half_day boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  cid uuid := public.my_company();
  fd int;
begin
  if cid is null then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then raise exception 'Choose a range of up to 93 days'; end if;
  fd := (select full_day_minutes from public.companies where id = cid);
  return query
  with people as (
    select e.id, e.emp_code, e.full_name, dp.name dept, dg.name desig
      from public.employees e
      left join public.departments dp on dp.id = e.department_id
      left join public.designations dg on dg.id = e.designation_id
     where e.company_id = cid and public.can_see(e.id)
       and (e.active or (e.exit_date is not null and e.exit_date >= p_from))
       and (p_department is null or e.department_id = p_department)
       and (p_employee is null or e.id = p_employee)
  ), days as (
    -- lateral: one day_for() call per person-day ((f()).* would call it once per column)
    select pp.*, dd.* from people pp cross join generate_series(p_from, p_to, interval '1 day') g cross join lateral public.day_for(pp.id, g::date) dd
  )
  select d.id, d.emp_code, d.full_name, d.dept, d.desig, d.work_date, d.work_mode, d.shift_name, d.first_in, d.last_out,
         d.worked_min, d.break_min, d.late_min, d.early_min, d.overtime_min, d.status, d.plan_note, d.pending_correction,
         (fd is not null and d.status in ('present', 'late') and d.worked_min < fd)
    from days d
   where d.status not in ('not_joined', 'left')
     and (p_shift is null or d.shift_id = p_shift)
   order by d.work_date desc, d.full_name;
end $$;

-- Attendance Register: report_days + status filter + paging (total included in each row).
create function public.attendance_register(p_from date, p_to date, p_department uuid default null, p_employee uuid default null,
                                           p_shift uuid default null, p_status text default null, p_limit int default 50, p_offset int default 0)
returns table (employee_id uuid, emp_code text, full_name text, department text, designation text, work_date date, work_mode text,
               shift_name text, first_in timestamptz, last_out timestamptz, worked_min int, break_min int, late_min int, early_min int,
               overtime_min int, status text, note text, pending_correction boolean, half_day boolean, total bigint)
language sql stable security definer set search_path = public as $$
  select r.*, count(*) over () from public.report_days(p_from, p_to, p_department, p_employee, p_shift) r
   where p_status is null
      or r.status = p_status
      or (p_status = 'attended' and r.status in ('present', 'late', 'working', 'on_break', 'missing_checkout'))
      or (p_status = 'late' and r.late_min > 0)
   order by r.work_date desc, r.full_name
   limit least(greatest(p_limit, 1), 5000) offset greatest(p_offset, 0)
$$;

-- Per-person totals for reports (attendance rate counts only days the person was due to work).
create function public.report_people(p_from date, p_to date, p_department uuid default null, p_employee uuid default null, p_shift uuid default null)
returns table (employee_id uuid, emp_code text, full_name text, department text, due_days bigint, attended_days bigint, absent_days bigint,
               leave_days bigint, late_days bigint, late_min bigint, early_days bigint, missing_checkout bigint, half_days bigint,
               worked_min bigint, overtime_min bigint, avg_worked_min int, rate numeric)
language sql stable security definer set search_path = public as $$
  with d as (select * from public.report_days(p_from, p_to, p_department, p_employee, p_shift))
  select employee_id, max(emp_code), max(full_name), max(department),
         count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout', 'absent')),
         count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout')),
         count(*) filter (where status = 'absent'),
         count(*) filter (where status = 'on_leave'),
         count(*) filter (where late_min > 0), coalesce(sum(late_min), 0),
         count(*) filter (where early_min > 0),
         count(*) filter (where status = 'missing_checkout'),
         count(*) filter (where half_day),
         coalesce(sum(worked_min), 0), coalesce(sum(overtime_min), 0),
         coalesce((avg(worked_min) filter (where status in ('present', 'late')))::int, 0),
         case when count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout', 'absent')) > 0 then
           round(100.0 * count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout'))
                 / count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout', 'absent')), 1) end
    from d group by employee_id order by max(full_name)
$$;

-- Per-day totals for trend charts.
create function public.report_trend(p_from date, p_to date, p_department uuid default null, p_employee uuid default null, p_shift uuid default null)
returns table (work_date date, due bigint, attended bigint, late bigint, on_leave bigint, absent bigint, avg_worked_min int, rate numeric)
language sql stable security definer set search_path = public as $$
  with d as (select * from public.report_days(p_from, p_to, p_department, p_employee, p_shift))
  select work_date,
         count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout', 'absent')),
         count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout')),
         count(*) filter (where late_min > 0),
         count(*) filter (where status = 'on_leave'),
         count(*) filter (where status = 'absent'),
         coalesce((avg(worked_min) filter (where status in ('present', 'late')))::int, 0),
         case when count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout', 'absent')) > 0 then
           round(100.0 * count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout'))
                 / count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout', 'absent')), 1) end
    from d group by work_date order by work_date
$$;

-- ================================================================ user access (Admin): who can sign in
create function public.user_access()
returns table (employee_id uuid, emp_code text, full_name text, email text, role text, active boolean, employment_status text,
               login_linked boolean, email_confirmed boolean, last_sign_in_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only an administrator can see user access' using errcode = '42501'; end if;
  return query
  select e.id, e.emp_code, e.full_name, e.email, e.role, e.active, e.employment_status,
         e.user_id is not null, u.email_confirmed_at is not null, u.last_sign_in_at
    from public.employees e left join auth.users u on u.id = e.user_id
   where e.company_id = public.my_company()
   order by case e.role when 'admin' then 0 when 'hr' then 1 when 'manager' then 2 else 3 end, e.full_name;
end $$;

-- ================================================================ security
alter table public.leave_types enable row level security;
alter table public.leave_requests enable row level security;
alter table public.leave_adjustments enable row level security;
revoke all on public.leave_types, public.leave_requests, public.leave_adjustments from anon, public;
grant select, insert, update on public.leave_types to authenticated;
grant select on public.leave_requests, public.leave_adjustments to authenticated;
create policy lt_read on public.leave_types for select to authenticated using (company_id = public.my_company());
create policy lt_write on public.leave_types for insert to authenticated with check (company_id = public.my_company() and public.is_hr());
create policy lt_update on public.leave_types for update to authenticated
  using (company_id = public.my_company() and public.is_hr()) with check (company_id = public.my_company() and public.is_hr());
create policy lr_read on public.leave_requests for select to authenticated using (public.can_see(employee_id));
create policy la_read on public.leave_adjustments for select to authenticated using (public.can_see(employee_id));

create trigger audit_leave_types after insert or update on public.leave_types for each row execute function public.audit();
create trigger audit_leave_requests after insert or update on public.leave_requests for each row execute function public.audit();
create trigger audit_leave_adjustments after insert on public.leave_adjustments for each row execute function public.audit();

revoke all on all functions in schema public from anon, public;
revoke execute on function public.add_default_leave_types(uuid), public.company_defaults(), public.leave_year_start(uuid, date),
  public.leave_days(uuid, date, date, text), public.leave_on(uuid, date), public.leave_balance(uuid, date),
  public.punch_core(text, double precision, double precision, double precision), public.my_today_core(), public.dashboard_summary_core(),
  public.report_days(date, date, uuid, uuid, uuid) from authenticated;
grant execute on function public.leave_balance_view(uuid, date), public.leave_preview(uuid, date, date, text, uuid), public.apply_leave(uuid, date, date, text, text, uuid),
  public.decide_leave(bigint, boolean, text), public.cancel_leave(bigint, text), public.adjust_leave(uuid, uuid, numeric, text, date),
  public.leave_list(date, date, text), public.punch(text, double precision, double precision, double precision), public.my_today(),
  public.dashboard_summary(), public.attendance_register(date, date, uuid, uuid, uuid, text, int, int),
  public.report_people(date, date, uuid, uuid, uuid), public.report_trend(date, date, uuid, uuid, uuid), public.user_access() to authenticated;
grant execute on function public.company_brand(text) to anon, authenticated;
