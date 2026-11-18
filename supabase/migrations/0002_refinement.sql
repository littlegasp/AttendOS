-- AttendOS refinement pass (after Phase 2 review).
-- Adds: shifts (separate from work location), breaks, overnight work dates, late / early /
-- overtime / missing check-out calculations, correction requests, holidays, assigned office
-- per employee, remote-work exceptions, verification history and a scoped dashboard summary.
-- Nothing from 0001 is removed; original attendance events are never edited or deleted.

-- ---------------------------------------------------------------- shifts
create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 60),
  start_time time not null,
  end_time time not null check (end_time <> start_time),
  break_minutes int not null default 60 check (break_minutes between 0 and 240),
  grace_minutes int not null default 10 check (grace_minutes between 0 and 120),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
comment on table public.shifts is 'A shift ending at or before its start time runs overnight into the next day.';

alter table public.organization add column default_shift_id uuid references public.shifts (id);
alter table public.employees add column default_shift_id uuid references public.shifts (id);

create table public.shift_pattern (
  employee_id uuid not null references public.employees (id) on delete cascade,
  weekday int not null check (weekday between 0 and 6),
  shift_id uuid not null references public.shifts (id),
  primary key (employee_id, weekday)
);

create table public.shift_day (
  employee_id uuid not null references public.employees (id) on delete cascade,
  day date not null,
  shift_id uuid not null references public.shifts (id),
  set_by uuid default auth.uid(),
  set_at timestamptz not null default now(),
  primary key (employee_id, day)
);

-- Shift for one person on one date: date change > weekly pattern > person's default > company default.
create function public.shift_for(emp uuid, d date)
returns table (shift_id uuid, source text)
language sql stable security definer set search_path = public as $$
  select x.shift_id, x.source from (
    select sd.shift_id, 'day'::text, 1 from public.shift_day sd where sd.employee_id = emp and sd.day = d
    union all
    select sp.shift_id, 'pattern', 2 from public.shift_pattern sp where sp.employee_id = emp and sp.weekday = extract(dow from d)::int
    union all
    select e.default_shift_id, 'employee', 3 from public.employees e where e.id = emp and e.default_shift_id is not null
    union all
    select o.default_shift_id, 'company', 4 from public.organization o where o.id = 1 and o.default_shift_id is not null
  ) x (shift_id, source, rank) order by rank limit 1
$$;

-- ---------------------------------------------------------------- holidays
create table public.holidays (
  id uuid primary key default gen_random_uuid(),
  day date not null,
  name text not null check (length(trim(name)) between 2 and 80),
  location_id uuid references public.locations (id), -- null = every office
  created_at timestamptz not null default now(),
  unique nulls not distinct (day, location_id)
);

-- ---------------------------------------------------------------- remote-work exceptions
create table public.remote_exceptions (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees (id) on delete cascade,
  start_date date not null,
  end_date date not null,
  reason text not null check (length(trim(reason)) >= 3),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (end_date >= start_date and end_date - start_date <= 366)
);
create index on public.remote_exceptions (employee_id, start_date);

-- ---------------------------------------------------------------- work location plan (replaces 0001 version)
-- Date change by HR > holiday > remote exception > weekly pattern > company default.
drop function public.plan_for(uuid, date);
create function public.plan_for(emp uuid, d date)
returns table (work_mode text, location_id uuid, source text, note text)
language sql stable security definer set search_path = public as $$
  with o as (select * from public.organization where id = 1),
  e as (select * from public.employees where id = emp),
  rd as (select r.work_mode, r.location_id, r.note from public.roster_day r where r.employee_id = emp and r.day = d),
  hol as (select h.name from public.holidays h, e where h.day = d and (h.location_id is null or h.location_id = e.home_location_id) limit 1),
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

-- ---------------------------------------------------------------- attendance events: breaks, work date, corrections
alter table public.attendance_events drop constraint attendance_events_kind_check;
alter table public.attendance_events add constraint attendance_events_kind_check check (kind in ('in', 'out', 'break_start', 'break_end'));
alter table public.attendance_events add column work_date date;
update public.attendance_events e set work_date = (e.at at time zone (select timezone from public.organization where id = 1))::date;
alter table public.attendance_events alter column work_date set not null;
alter table public.attendance_events add column correction_id bigint;
alter table public.attendance_events add column superseded_by bigint; -- set when an approved correction replaces this event (it is kept)
create index on public.attendance_events (employee_id, work_date);

-- ---------------------------------------------------------------- corrections
create table public.attendance_corrections (
  id bigint generated always as identity primary key,
  employee_id uuid not null references public.employees (id),
  work_date date not null,
  kind text not null check (kind in ('missing_in', 'missing_out', 'wrong_time', 'other')),
  requested_in timestamptz,
  requested_out timestamptz,
  reason text not null check (length(trim(reason)) >= 5),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  requested_by uuid not null default auth.uid(),
  requested_at timestamptz not null default now(),
  decided_by uuid,
  decided_at timestamptz,
  decision_note text,
  check (requested_in is null or requested_out is null or requested_out > requested_in)
);
create index on public.attendance_corrections (employee_id, work_date);
create unique index one_pending_correction_per_day on public.attendance_corrections (employee_id, work_date) where status = 'pending';
alter table public.attendance_events add constraint attendance_events_correction_fk foreign key (correction_id) references public.attendance_corrections (id);

-- ---------------------------------------------------------------- helpers
create function public.org_tz() returns text
language sql stable as $$ select timezone from public.organization where id = 1 $$;

create function public.at_local(d date, t time) returns timestamptz
language sql stable as $$ select (d + t) at time zone public.org_tz() $$;

-- Session state from the latest event: off / working / on_break
create function public.session_state(emp uuid)
returns table (state text, work_date date, work_mode text, open_since timestamptz)
language sql stable security definer set search_path = public as $$
  with last_ev as (
    select * from public.attendance_events where employee_id = emp and superseded_by is null order by at desc, id desc limit 1
  ),
  open_in as (
    select i.* from public.attendance_events i, last_ev l
    where i.employee_id = emp and i.kind = 'in' and i.superseded_by is null and i.work_date = l.work_date and i.at <= l.at
    order by i.at desc limit 1
  )
  select case when l.kind is null or l.kind = 'out' then 'off' when l.kind = 'break_start' then 'on_break' else 'working' end,
         case when l.kind is null or l.kind = 'out' then null else l.work_date end,
         case when l.kind is null or l.kind = 'out' then null else (select work_mode from open_in) end,
         case when l.kind is null or l.kind = 'out' then null else (select at from open_in) end
  from (select 1) one left join last_ev l on true
$$;

-- ---------------------------------------------------------------- one day of attendance, worked out
create type public.attendance_day as (
  employee_id uuid,
  work_date date,
  work_mode text,
  plan_source text,
  plan_note text,
  location_id uuid,
  shift_id uuid,
  shift_name text,
  shift_start timestamptz,
  shift_end timestamptz,
  break_allowance_min int,
  grace_min int,
  first_in timestamptz,
  last_out timestamptz,
  worked_min int,
  break_min int,
  late_min int,
  early_min int,
  overtime_min int,
  status text, -- present / late / working / on_break / missing_checkout / absent / not_started / off / holiday / scheduled / not_joined
  open boolean,
  pending_correction boolean
);

create function public.day_for(emp uuid, d date) returns public.attendance_day
language plpgsql stable security definer set search_path = public as $$
declare
  r public.attendance_day;
  p record;
  s public.shifts;
  ev record;
  t_now timestamptz := now();
  today date := public.local_today();
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
      r.shift_start := public.at_local(d, s.start_time);
      r.shift_end := public.at_local(d + case when s.end_time <= s.start_time then 1 else 0 end, s.end_time);
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
  -- An open session today keeps counting; an old open session is a missing check-out (not counted).
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
    when r.first_in is null and d < (select (e.created_at at time zone public.org_tz())::date from public.employees e where e.id = emp) then 'not_joined'
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

-- History for one person (the person, their manager, or HR/Admin), at most 92 days at a time.
create function public.attendance_history(emp uuid, d_from date, d_to date)
returns setof public.attendance_day
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_see(emp) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if d_to < d_from or d_to - d_from > 92 then raise exception 'Choose a range of up to 92 days'; end if;
  return query select x.* from (select (public.day_for(emp, g::date)).* from generate_series(d_from, d_to, interval '1 day') g) x
               where x.status <> 'not_joined' order by x.work_date desc;
end $$;

-- ---------------------------------------------------------------- work date for a new check-in (overnight shifts)
create function public.work_date_for_checkin(emp uuid) returns date
language plpgsql stable security definer set search_path = public as $$
declare
  today date := public.local_today();
  y_shift public.shifts;
begin
  -- Yesterday's overnight shift that has not ended yet: this check-in belongs to yesterday.
  select sh.* into y_shift from public.shift_for(emp, today - 1) f join public.shifts sh on sh.id = f.shift_id;
  if y_shift.id is not null and y_shift.end_time <= y_shift.start_time
     and (select work_mode from public.plan_for(emp, today - 1)) <> 'off'
     and now() < public.at_local(today, y_shift.end_time) then
    return today - 1;
  end if;
  return today;
end $$;

-- ---------------------------------------------------------------- today for the signed-in person (replaces 0001)
create or replace function public.my_today() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me public.employees;
  o public.organization;
  st record;
  d date;
  r public.attendance_day;
  loc public.locations;
  sh public.shifts;
begin
  select * into me from public.employees where id = auth.uid() and active;
  if me.id is null then return jsonb_build_object('ok', false, 'code', 'not_employee'); end if;
  select * into o from public.organization where id = 1;
  select * into st from public.session_state(me.id);
  d := coalesce(st.work_date, public.work_date_for_checkin(me.id));
  r := public.day_for(me.id, d);
  if r.location_id is not null then select * into loc from public.locations where id = r.location_id; end if;
  if r.shift_id is not null then select * into sh from public.shifts where id = r.shift_id; end if;

  return jsonb_build_object(
    'ok', true,
    'server_now', now(),
    'timezone', o.timezone,
    'today', public.local_today(),
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

-- ---------------------------------------------------------------- check in / out / breaks (replaces 0001)
drop function public.punch(text, double precision, double precision, double precision);
create function public.punch(p_kind text, p_lat double precision default null, p_lng double precision default null, p_accuracy double precision default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me public.employees;
  o public.organization;
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
  select * into me from public.employees where id = auth.uid() and active;
  if me.id is null then
    return jsonb_build_object('ok', false, 'code', 'not_employee', 'message', 'Your account is not set up as an active employee. Contact HR.');
  end if;

  -- One action at a time per person: a double tap can never create two sessions.
  perform pg_advisory_xact_lock(hashtextextended(me.id::text, 7));
  select * into o from public.organization where id = 1;
  select * into st from public.session_state(me.id);

  -- State rules
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

  -- Breaks: no location is read or stored.
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
    mode := st.work_mode; -- check out under the same rules as the check-in
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

  -- Checking out while on a break ends the break at the same moment.
  if p_kind = 'out' and st.state = 'on_break' then
    insert into public.attendance_events (employee_id, kind, work_mode, verified, work_date) values (me.id, 'break_end', mode, false, d);
  end if;

  if mode = 'office' then
    select l.id, l.name, l.radius_m, public.distance_m(p_lat, p_lng, l.lat, l.lng) as dist into best
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

-- ---------------------------------------------------------------- correction requests
create function public.request_correction(p_work_date date, p_kind text, p_in timestamptz, p_out timestamptz, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  c public.attendance_corrections;
  lo timestamptz := public.at_local(p_work_date, '00:00');
  hi timestamptz := public.at_local(p_work_date + 2, '00:00');
begin
  if not exists (select 1 from public.employees where id = me and active) then
    return jsonb_build_object('ok', false, 'message', 'Your account is not an active employee.');
  end if;
  if p_work_date > public.local_today() or p_work_date < public.local_today() - 31 then
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

create function public.cancel_correction(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update public.attendance_corrections set status = 'cancelled', decided_at = now(), decided_by = auth.uid()
   where id = p_id and employee_id = auth.uid() and status = 'pending';
  if not found then return jsonb_build_object('ok', false, 'message', 'Only your own pending requests can be cancelled.'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- HR/Admin decide any; a Manager decides their team's. Nobody decides their own.
-- Approving adds new events marked source = 'correction' and keeps the originals (marked superseded where replaced).
create function public.decide_correction(p_id bigint, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c public.attendance_corrections;
  p record;
  m text;
begin
  select * into c from public.attendance_corrections where id = p_id for update;
  if c.id is null or c.status <> 'pending' then return jsonb_build_object('ok', false, 'message', 'This request is no longer pending.'); end if;
  if c.employee_id = auth.uid() then return jsonb_build_object('ok', false, 'message', 'You cannot decide your own request.'); end if;
  if not (public.is_hr() or public.manages(c.employee_id)) then
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
  insert into public.audit_log (action, target, target_id, before, after)
    values (case when p_approve then 'approve' else 'reject' end, 'attendance_corrections', p_id::text, to_jsonb(c),
            (select to_jsonb(x) from public.attendance_corrections x where x.id = p_id));
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------- verification history (HR/Admin; no coordinates)
create function public.verification_log(p_limit int default 100)
returns table (at timestamptz, employee text, kind text, outcome text, work_mode text, location text, distance_m int, accuracy_m int, reason text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_hr() then raise exception 'Not allowed' using errcode = '42501'; end if;
  return query
  select * from (
    select e.at, emp.full_name, e.kind,
           case when e.source = 'correction' then 'corrected' when e.verified then 'verified' else 'not_required' end,
           e.work_mode, l.name, e.distance_m, e.accuracy_m, null::text
      from public.attendance_events e join public.employees emp on emp.id = e.employee_id
      left join public.locations l on l.id = e.location_id
     where e.kind in ('in', 'out')
    union all
    select a.at, emp.full_name, a.kind, 'refused', null, null, a.distance_m, a.accuracy_m, a.reason
      from public.attendance_attempts a join public.employees emp on emp.id = a.employee_id
  ) x order by 1 desc limit least(greatest(p_limit, 1), 500);
end $$;

-- ---------------------------------------------------------------- dashboard summary (scoped)
-- Admin/HR: everyone. Manager: their team and themselves. Employee: themselves.
create function public.dashboard_summary() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  today date := public.local_today();
  role text := public.my_role();
  scope text;
  res jsonb;
begin
  if role is null then return jsonb_build_object('ok', false, 'code', 'not_employee'); end if;
  scope := case when role in ('admin', 'hr') then 'organization' when role = 'manager' then 'team' else 'personal' end;

  with people as (
    select e.id, e.full_name, coalesce(dp.name, 'No department') as dept
      from public.employees e left join public.departments dp on dp.id = e.department_id
     where e.active and public.can_see(e.id)
  ),
  t as (select pp.full_name, pp.dept, (public.day_for(pp.id, today)).* from people pp),
  y as (select (public.day_for(pp.id, today - 1)).* from people pp),
  att as (select * from t where status in ('present', 'late', 'working', 'on_break', 'missing_checkout')),
  due_t as (select count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout', 'absent')) n,
                   count(*) filter (where status in ('present', 'late', 'working', 'on_break', 'missing_checkout')) a from t),
  due_y as (select count(*) filter (where status in ('present', 'late', 'missing_checkout', 'absent')) n,
                   count(*) filter (where status in ('present', 'late', 'missing_checkout')) a from y)
  select jsonb_build_object(
    'ok', true, 'scope', scope, 'today', today, 'timezone', public.org_tz(), 'server_now', now(),
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
        'can_decide', c.employee_id <> auth.uid() and (public.is_hr() or public.manages(c.employee_id))) order by c.requested_at)
        from public.attendance_corrections c join public.employees e on e.id = c.employee_id
       where c.status = 'pending' and public.can_see(c.employee_id)), '[]'),
    'upcoming_holidays', coalesce((select jsonb_agg(jsonb_build_object('day', h.day, 'name', h.name, 'location', l.name) order by h.day)
        from (select * from public.holidays where day >= today order by day limit 5) h left join public.locations l on l.id = h.location_id), '[]'),
    'recent_activity', coalesce((select jsonb_agg(x order by (x ->> 'at') desc) from (
        select jsonb_build_object('name', e.full_name, 'kind', ev.kind, 'at', ev.at, 'work_mode', ev.work_mode, 'location', l.name,
                                  'source', ev.source) x
          from public.attendance_events ev join public.employees e on e.id = ev.employee_id
          left join public.locations l on l.id = ev.location_id
         where ev.at > now() - interval '2 days' and public.can_see(ev.employee_id) and ev.superseded_by is null
         order by ev.at desc limit 12) r), '[]')
  ) into res;
  return res;
end $$;

-- ---------------------------------------------------------------- security
alter table public.shifts enable row level security;
alter table public.shift_pattern enable row level security;
alter table public.shift_day enable row level security;
alter table public.holidays enable row level security;
alter table public.remote_exceptions enable row level security;
alter table public.attendance_corrections enable row level security;

revoke all on public.shifts, public.shift_pattern, public.shift_day, public.holidays, public.remote_exceptions, public.attendance_corrections from anon;
revoke all on all functions in schema public from anon, public;

grant select, insert, update on public.shifts to authenticated;
grant select, insert, update, delete on public.shift_pattern, public.shift_day, public.holidays, public.remote_exceptions to authenticated;
grant select on public.attendance_corrections to authenticated;

create policy sh_read on public.shifts for select to authenticated using (true);
create policy sh_ins on public.shifts for insert to authenticated with check (public.is_hr());
create policy sh_upd on public.shifts for update to authenticated using (public.is_hr()) with check (public.is_hr());
create policy sp_read on public.shift_pattern for select to authenticated using (public.can_see(employee_id));
create policy sp_write on public.shift_pattern for all to authenticated using (public.is_hr()) with check (public.is_hr());
create policy sd_read on public.shift_day for select to authenticated using (public.can_see(employee_id));
create policy sd_write on public.shift_day for all to authenticated using (public.is_hr()) with check (public.is_hr());
create policy hol_read on public.holidays for select to authenticated using (true);
create policy hol_write on public.holidays for all to authenticated using (public.is_hr()) with check (public.is_hr());
create policy rx_read on public.remote_exceptions for select to authenticated using (public.can_see(employee_id));
create policy rx_write on public.remote_exceptions for all to authenticated using (public.is_hr()) with check (public.is_hr());
create policy corr_read on public.attendance_corrections for select to authenticated using (public.can_see(employee_id));

create trigger audit_shifts after insert or update on public.shifts for each row execute function public.audit();
create trigger audit_holidays after insert or update or delete on public.holidays for each row execute function public.audit();
create trigger audit_remote_exceptions after insert or update or delete on public.remote_exceptions for each row execute function public.audit();
create trigger audit_shift_pattern after insert or update or delete on public.shift_pattern for each row execute function public.audit();
create trigger audit_shift_day after insert or update or delete on public.shift_day for each row execute function public.audit();

-- Only Admin may change company-wide rules; HR may still set each person's office and shift.
create function public.guard_organization_update() returns trigger
language plpgsql set search_path = public as $$
begin
  -- auth.uid() is null only for the database owner (Supabase SQL editor, setup scripts).
  if auth.uid() is not null and not public.is_admin() then raise exception 'Only an administrator can change attendance rules'; end if;
  return new;
end $$;

-- Same rule for role changes: signed-in users need Admin; the database owner (setup) may too.
create or replace function public.guard_employee_update() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.role is distinct from old.role and auth.uid() is not null and not public.is_admin() then
    raise exception 'Only an administrator can change roles';
  end if;
  if new.id = auth.uid() and new.active is distinct from old.active then
    raise exception 'You cannot deactivate yourself';
  end if;
  return new;
end $$;
create trigger organization_guard before update on public.organization for each row execute function public.guard_organization_update();

-- HR may set office/shift/department/manager on people, but only Admin changes roles (0001 guard still applies).

-- Replace the weekly shift pattern of several people in one step.
create function public.set_shift_pattern(p_employees uuid[], p_rows jsonb) returns void
language plpgsql security invoker set search_path = public as $$
begin
  delete from public.shift_pattern where employee_id = any (p_employees);
  insert into public.shift_pattern (employee_id, weekday, shift_id)
  select e, (r ->> 'weekday')::int, (r ->> 'shift_id')::uuid
  from unnest(p_employees) e cross join jsonb_array_elements(p_rows) r;
end $$;

-- Internal helpers take any employee id, so they are not callable directly; the functions
-- below check who is asking and call them.
revoke execute on function public.plan_for(uuid, date), public.shift_for(uuid, date), public.session_state(uuid),
  public.day_for(uuid, date), public.work_date_for_checkin(uuid) from authenticated;

grant execute on function
  public.attendance_history(uuid, date, date), public.my_today(),
  public.punch(text, double precision, double precision, double precision),
  public.request_correction(date, text, timestamptz, timestamptz, text), public.cancel_correction(bigint),
  public.decide_correction(bigint, boolean, text), public.verification_log(int), public.dashboard_summary(),
  public.set_shift_pattern(uuid[], jsonb), public.org_tz(), public.at_local(date, time),
  public.my_role(), public.is_hr(), public.is_admin(), public.manages(uuid), public.can_see(uuid),
  public.distance_m(double precision, double precision, double precision, double precision), public.local_today(),
  public.set_roster_pattern(uuid[], jsonb)
to authenticated;
