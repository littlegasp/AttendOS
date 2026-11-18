-- AttendOS Phase 2: attendance core.
-- One company per copy (each company gets its own Supabase project and branding).
-- Everything that must be trusted (time, geofence, duplicates) happens in this database,
-- never in the browser. Row level security is on for every table; anon gets nothing.

-- ---------------------------------------------------------------- organization
create table public.organization (
  id int primary key default 1 check (id = 1),
  name text not null default 'Company',
  timezone text not null default 'Asia/Kolkata',
  -- GPS policy
  max_accuracy_m int not null default 100 check (max_accuracy_m between 10 and 2000),
  remote_location_required boolean not null default false,
  -- When HR has set nothing for a person on a day
  default_work_mode text not null default 'office' check (default_work_mode in ('office', 'remote')),
  weekly_off int[] not null default '{0}', -- 0 = Sunday … 6 = Saturday
  updated_at timestamptz not null default now()
);
insert into public.organization (id) values (1);

-- ---------------------------------------------------------------- office locations
create table public.locations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 80),
  address text,
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  radius_m int not null default 150 check (radius_m between 25 and 2000),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.departments (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  code text,
  active boolean not null default true
);

-- ---------------------------------------------------------------- employees
create table public.employees (
  id uuid primary key references auth.users (id),
  emp_code text unique,
  full_name text not null,
  email text not null,
  role text not null default 'employee' check (role in ('admin', 'hr', 'manager', 'employee')),
  department_id uuid references public.departments (id),
  manager_id uuid references public.employees (id),
  home_location_id uuid references public.locations (id),
  active boolean not null default true, -- deactivate, never delete: attendance history depends on it
  created_at timestamptz not null default now()
);
create index on public.employees (manager_id);

-- New sign-in → employee row. The very first person becomes Admin.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.employees (id, full_name, email, role)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1)),
    new.email,
    case when exists (select 1 from public.employees) then 'employee' else 'admin' end
  );
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------- access helpers
create function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.employees where id = auth.uid() and active
$$;

create function public.is_hr() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() in ('admin', 'hr'), false)
$$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'admin', false)
$$;

-- True when the signed-in person manages this employee (directly).
create function public.manages(emp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.employees e
    where e.id = emp and e.manager_id = auth.uid() and public.my_role() = 'manager'
  )
$$;

create function public.can_see(emp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select emp = auth.uid() or public.is_hr() or public.manages(emp)
$$;

-- Only an Admin may change roles; nobody may promote themselves.
create function public.guard_employee_update() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.role is distinct from old.role and not public.is_admin() then
    raise exception 'Only an administrator can change roles';
  end if;
  if new.id = auth.uid() and new.active is distinct from old.active then
    raise exception 'You cannot deactivate yourself';
  end if;
  return new;
end $$;
create trigger employees_guard before update on public.employees
  for each row execute function public.guard_employee_update();

-- ---------------------------------------------------------------- work roster
-- Weekly pattern per person (HR sets which weekdays are office / remote / off) …
create table public.roster_pattern (
  employee_id uuid not null references public.employees (id) on delete cascade,
  weekday int not null check (weekday between 0 and 6),
  work_mode text not null check (work_mode in ('office', 'remote', 'off')),
  location_id uuid references public.locations (id),
  primary key (employee_id, weekday),
  check (work_mode = 'office' or location_id is null)
);

-- … and changes for a specific date, which win over the pattern.
create table public.roster_day (
  employee_id uuid not null references public.employees (id) on delete cascade,
  day date not null,
  work_mode text not null check (work_mode in ('office', 'remote', 'off')),
  location_id uuid references public.locations (id),
  note text,
  set_by uuid default auth.uid(),
  set_at timestamptz not null default now(),
  primary key (employee_id, day),
  check (work_mode = 'office' or location_id is null)
);

-- The plan for one person on one day: date change > weekly pattern > company default.
create function public.plan_for(emp uuid, d date)
returns table (work_mode text, location_id uuid, source text)
language sql stable security definer set search_path = public as $$
  with o as (select * from public.organization where id = 1),
  rd as (select r.work_mode, r.location_id from public.roster_day r where r.employee_id = emp and r.day = d),
  rp as (select r.work_mode, r.location_id from public.roster_pattern r where r.employee_id = emp and r.weekday = extract(dow from d)::int)
  select * from (
    select rd.work_mode, rd.location_id, 'day'::text from rd
    union all
    select rp.work_mode, rp.location_id, 'pattern' from rp where not exists (select 1 from rd)
    union all
    select case when extract(dow from d)::int = any (o.weekly_off) then 'off' else o.default_work_mode end,
           case when extract(dow from d)::int = any (o.weekly_off) or o.default_work_mode <> 'office' then null
                else (select home_location_id from public.employees where id = emp) end,
           'default'
    from o where not exists (select 1 from rd) and not exists (select 1 from rp)
  ) x limit 1
$$;

-- ---------------------------------------------------------------- attendance
create table public.attendance_events (
  id bigint generated always as identity primary key,
  employee_id uuid not null references public.employees (id),
  kind text not null check (kind in ('in', 'out')),
  at timestamptz not null default now(), -- server time is the only time that counts
  work_mode text not null check (work_mode in ('office', 'remote')),
  location_id uuid references public.locations (id),
  distance_m int,
  accuracy_m int,
  verified boolean not null,
  source text not null default 'web'
);
create index on public.attendance_events (employee_id, at desc);

-- Precise coordinates live apart so only the person and HR/Admin can read them.
create table public.attendance_coords (
  event_id bigint primary key references public.attendance_events (id) on delete cascade,
  lat numeric(9, 6) not null,
  lng numeric(9, 6) not null
);

-- Refused attempts are kept for audit (no coordinates stored).
create table public.attendance_attempts (
  id bigint generated always as identity primary key,
  employee_id uuid not null references public.employees (id),
  kind text not null,
  at timestamptz not null default now(),
  reason text not null,
  accuracy_m int,
  distance_m int
);
create index on public.attendance_attempts (employee_id, at desc);

-- ---------------------------------------------------------------- audit log
create table public.audit_log (
  id bigint generated always as identity primary key,
  actor uuid default auth.uid(),
  action text not null,
  target text not null,
  target_id text,
  before jsonb,
  after jsonb,
  at timestamptz not null default now()
);

create function public.audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  j jsonb := coalesce(to_jsonb(new), to_jsonb(old));
  k text := case tg_table_name
    when 'roster_pattern' then (j ->> 'employee_id') || ':' || (j ->> 'weekday')
    when 'roster_day' then (j ->> 'employee_id') || ':' || (j ->> 'day')
    else j ->> 'id' end;
begin
  insert into public.audit_log (action, target, target_id, before, after)
  values (lower(tg_op), tg_table_name, k,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

create trigger audit_organization after update on public.organization for each row execute function public.audit();
create trigger audit_locations after insert or update or delete on public.locations for each row execute function public.audit();
create trigger audit_employees after update on public.employees for each row execute function public.audit();
create trigger audit_roster_pattern after insert or update or delete on public.roster_pattern for each row execute function public.audit();
create trigger audit_roster_day after insert or update or delete on public.roster_day for each row execute function public.audit();

-- ---------------------------------------------------------------- geofence maths
create function public.distance_m(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns int language sql immutable as $$
  select round(2 * 6371000 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  )))::int
$$;

create function public.local_today() returns date
language sql stable as $$
  select (now() at time zone (select timezone from public.organization where id = 1))::date
$$;

-- ---------------------------------------------------------------- today for the signed-in person
create function public.my_today() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me public.employees;
  o public.organization;
  d date := public.local_today();
  p record;
  loc public.locations;
  last_ev public.attendance_events;
begin
  select * into me from public.employees where id = auth.uid() and active;
  if me.id is null then
    return jsonb_build_object('ok', false, 'code', 'not_employee');
  end if;
  select * into o from public.organization where id = 1;
  select * into p from public.plan_for(me.id, d);
  if p.location_id is not null then select * into loc from public.locations where id = p.location_id; end if;
  select * into last_ev from public.attendance_events where employee_id = me.id order by at desc limit 1;

  return jsonb_build_object(
    'ok', true,
    'server_now', now(),
    'timezone', o.timezone,
    'today', d,
    'max_accuracy_m', o.max_accuracy_m,
    'remote_location_required', o.remote_location_required,
    'employee', jsonb_build_object('id', me.id, 'full_name', me.full_name, 'role', me.role),
    'plan', jsonb_build_object('work_mode', p.work_mode, 'source', p.source,
                               'location', case when loc.id is null then null else
                                 jsonb_build_object('id', loc.id, 'name', loc.name, 'radius_m', loc.radius_m) end),
    'checked_in', coalesce(last_ev.kind = 'in', false),
    'open_since', case when last_ev.kind = 'in' then last_ev.at end,
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('kind', e.kind, 'at', e.at, 'work_mode', e.work_mode,
                                          'location', l.name, 'distance_m', e.distance_m, 'verified', e.verified) order by e.at)
      from public.attendance_events e left join public.locations l on l.id = e.location_id
      where e.employee_id = me.id and (e.at at time zone o.timezone)::date = d
    ), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------- check in / check out
-- The browser sends what the phone reported; this function decides. Returns
-- {ok:true, event, today} or {ok:false, code, message, ...} and never creates a second open session.
create function public.punch(p_kind text, p_lat double precision default null, p_lng double precision default null, p_accuracy double precision default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me public.employees;
  o public.organization;
  d date;
  p record;
  last_ev public.attendance_events;
  mode text;
  has_fix boolean := p_lat is not null and p_lng is not null and p_accuracy is not null;
  best record;
  ev public.attendance_events;
  acc int := case when p_accuracy is null then null else round(p_accuracy)::int end;
  plan_loc uuid;
  loc_name text;
begin
  if p_kind not in ('in', 'out') then
    return jsonb_build_object('ok', false, 'code', 'bad_request', 'message', 'Unknown action.');
  end if;
  if has_fix and (p_lat not between -90 and 90 or p_lng not between -180 and 180 or p_accuracy < 0) then
    return jsonb_build_object('ok', false, 'code', 'bad_request', 'message', 'The location received is not valid.');
  end if;

  select * into me from public.employees where id = auth.uid() and active;
  if me.id is null then
    return jsonb_build_object('ok', false, 'code', 'not_employee', 'message', 'Your account is not set up as an active employee. Contact HR.');
  end if;

  -- One punch at a time per person, so a double tap can never create two sessions.
  perform pg_advisory_xact_lock(hashtextextended(me.id::text, 7));

  select * into o from public.organization where id = 1;
  d := public.local_today();
  select * into last_ev from public.attendance_events where employee_id = me.id order by at desc limit 1;

  if p_kind = 'in' and last_ev.kind = 'in' then
    return jsonb_build_object('ok', false, 'code', 'already_in', 'message', 'You are already checked in.', 'today', public.my_today());
  end if;
  if p_kind = 'out' and coalesce(last_ev.kind, 'out') = 'out' then
    return jsonb_build_object('ok', false, 'code', 'not_checked_in', 'message', 'You are not checked in, so there is nothing to check out of.', 'today', public.my_today());
  end if;

  if p_kind = 'in' then
    select * into p from public.plan_for(me.id, d);
    if p.work_mode = 'off' then
      insert into public.attendance_attempts (employee_id, kind, reason) values (me.id, p_kind, 'day_off');
      return jsonb_build_object('ok', false, 'code', 'day_off', 'message', 'Today is not a working day on your roster. If you have been asked to work, ask HR to update your roster.');
    end if;
    mode := p.work_mode;
    plan_loc := p.location_id;
  else
    mode := last_ev.work_mode; -- check out under the same rules as the check-in
  end if;

  -- Location rules
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

  if mode = 'office' then
    -- The rostered office if one is set for check-in, otherwise any active office.
    select l.id, l.name, l.radius_m, public.distance_m(p_lat, p_lng, l.lat, l.lng) as dist
      into best
      from public.locations l
     where l.active and (plan_loc is null or l.id = plan_loc)
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
    insert into public.attendance_events (employee_id, kind, work_mode, location_id, distance_m, accuracy_m, verified)
      values (me.id, p_kind, 'office', best.id, best.dist, acc, true) returning * into ev;
    loc_name := best.name;
  else
    insert into public.attendance_events (employee_id, kind, work_mode, accuracy_m, verified)
      values (me.id, p_kind, 'remote', acc, has_fix and acc <= o.max_accuracy_m) returning * into ev;
  end if;

  if has_fix then
    insert into public.attendance_coords (event_id, lat, lng) values (ev.id, round(p_lat::numeric, 6), round(p_lng::numeric, 6));
  end if;

  return jsonb_build_object('ok', true, 'event', jsonb_build_object('kind', ev.kind, 'at', ev.at, 'work_mode', ev.work_mode,
           'location', loc_name, 'distance_m', ev.distance_m), 'today', public.my_today());
end $$;

-- Replace the weekly pattern of several people in one step (all or nothing).
-- Runs as the caller, so row level security still decides (HR/Admin only).
create function public.set_roster_pattern(p_employees uuid[], p_rows jsonb) returns void
language plpgsql security invoker set search_path = public as $$
begin
  delete from public.roster_pattern where employee_id = any (p_employees);
  insert into public.roster_pattern (employee_id, weekday, work_mode, location_id)
  select e, (r ->> 'weekday')::int, r ->> 'work_mode', nullif(r ->> 'location_id', '')::uuid
  from unnest(p_employees) e cross join jsonb_array_elements(p_rows) r;
end $$;

-- ---------------------------------------------------------------- row level security
alter table public.organization enable row level security;
alter table public.locations enable row level security;
alter table public.departments enable row level security;
alter table public.employees enable row level security;
alter table public.roster_pattern enable row level security;
alter table public.roster_day enable row level security;
alter table public.attendance_events enable row level security;
alter table public.attendance_coords enable row level security;
alter table public.attendance_attempts enable row level security;
alter table public.audit_log enable row level security;

revoke all on all tables in schema public from anon;
revoke all on all functions in schema public from anon, public;
revoke all on all sequences in schema public from anon;

grant select, update on public.organization to authenticated;
grant select, insert, update on public.locations, public.departments to authenticated;
grant select, update on public.employees to authenticated;
grant select, insert, update, delete on public.roster_pattern, public.roster_day to authenticated;
grant select on public.attendance_events, public.attendance_coords, public.attendance_attempts, public.audit_log to authenticated;
grant execute on function public.my_today(), public.punch(text, double precision, double precision, double precision),
  public.plan_for(uuid, date), public.my_role(), public.is_hr(), public.is_admin(), public.manages(uuid), public.can_see(uuid),
  public.distance_m(double precision, double precision, double precision, double precision), public.local_today(),
  public.set_roster_pattern(uuid[], jsonb) to authenticated;

create policy org_read on public.organization for select to authenticated using (true);
create policy org_admin on public.organization for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy loc_read on public.locations for select to authenticated using (true);
create policy loc_ins on public.locations for insert to authenticated with check (public.is_hr());
create policy loc_upd on public.locations for update to authenticated using (public.is_hr()) with check (public.is_hr());

create policy dep_read on public.departments for select to authenticated using (true);
create policy dep_ins on public.departments for insert to authenticated with check (public.is_hr());
create policy dep_upd on public.departments for update to authenticated using (public.is_hr()) with check (public.is_hr());

create policy emp_read on public.employees for select to authenticated using (public.can_see(id));
create policy emp_upd on public.employees for update to authenticated using (public.is_hr()) with check (public.is_hr());

create policy rp_read on public.roster_pattern for select to authenticated using (public.can_see(employee_id));
create policy rp_write on public.roster_pattern for all to authenticated using (public.is_hr()) with check (public.is_hr());
create policy rd_read on public.roster_day for select to authenticated using (public.can_see(employee_id));
create policy rd_write on public.roster_day for all to authenticated using (public.is_hr()) with check (public.is_hr());

create policy ev_read on public.attendance_events for select to authenticated using (public.can_see(employee_id));
create policy co_read on public.attendance_coords for select to authenticated using (
  public.is_hr() or exists (select 1 from public.attendance_events e where e.id = event_id and e.employee_id = auth.uid()));
create policy at_read on public.attendance_attempts for select to authenticated using (employee_id = auth.uid() or public.is_hr());
create policy audit_read on public.audit_log for select to authenticated using (public.is_hr());
