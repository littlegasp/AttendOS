-- AttendOS 0012: biometric attendance projection (Phase B3.4). Design: docs/biometric/BIOMETRIC_B3_4_PROJECTION_DESIGN.md
-- (revision 6, approved for local implementation 20 Nov 2026). Summary:
--  * attendance_events gains five nullable columns that link a projected row to its immutable raw punch; a guard trigger
--    validates that link on insert, on any change of the attribution tuple and refuses any change of a row's source;
--  * projection (biometric_project_day) runs per employee-day under the punch lock (advisory key 7), writes stable slot
--    rows, never writes a provisional check-out, routes everything doubtful to HR review or to the correction workflow,
--    and never exceeds its write budget; a queue procedure (to be scheduled by pg_cron later, NOT here) drives it;
--  * decide_correction is wrapped to take the same lock; verification_log labels biometric/imported rows;
--  * projection stays OFF for every company (biometric_settings.projection_enabled default false, unchanged).
-- Existing attendance functions (punch, punch_core, session_state, day_for, day_for_core, my_today, reports) are unchanged.
-- Apply in a single transaction (supabase db push / psql --single-transaction): the preflight below must stop everything.


-- ===== A0. Source-value preflight (first statement of 0012)
-- Stops the whole migration, changing nothing, if any existing attendance row has a source value 0012 does not know.
-- Historical rows are never rewritten or deleted to make the new check pass.
do $$
declare bad text;
begin
  select string_agg(format('%s (%s rows)', coalesce(quote_literal(source), 'NULL'), n), ', ' order by source)
    into bad
    from (select source, count(*) n from public.attendance_events
           where source is null or source not in ('web', 'correction') group by source) x;
  if bad is not null then
    raise exception 'Migration 0012 stopped before any change: unexpected attendance_events.source values: %', bad
      using errcode = 'P0001', hint = 'Report these values to the owner. Do not edit attendance history to pass this check.';
  end if;
end $$;

-- ===== A1. `attendance_events` — additive columns, checks, indexes
alter table public.attendance_events
  add column device_id uuid,
  add column biometric_event_id bigint,
  add column import_batch_id uuid,
  add column projection_slot text,
  add column direction_basis text;
alter table public.attendance_events
  add constraint attendance_events_device_fk foreign key (device_id) references public.biometric_devices (id),
  add constraint attendance_events_raw_fk foreign key (biometric_event_id) references public.biometric_raw_events (id) on delete restrict,
  add constraint attendance_events_batch_fk foreign key (import_batch_id) references public.biometric_import_batches (id),
  add constraint attendance_events_slot_check check (projection_slot is null or projection_slot ~ '^(in|out|dev:[0-9]{1,19})$'),
  add constraint attendance_events_basis_check check (direction_basis is null or direction_basis in ('device', 'inferred_first_last')),
  add constraint attendance_events_source_check check (source in ('web', 'correction', 'biometric', 'import')) not valid,
  add constraint attendance_events_external_shape check (
    case when source in ('biometric', 'import') then
           biometric_event_id is not null and projection_slot is not null and direction_basis is not null
       and kind in ('in', 'out') and not verified and distance_m is null and accuracy_m is null and correction_id is null
       and ((source = 'biometric') = (device_id is not null)) and ((source = 'import') = (import_batch_id is not null))
       and ((direction_basis = 'device') = (projection_slot like 'dev:%'))
    else num_nulls(device_id, biometric_event_id, import_batch_id, projection_slot, direction_basis) = 5 end) not valid;
alter table public.attendance_events validate constraint attendance_events_source_check;
alter table public.attendance_events validate constraint attendance_events_external_shape;
create unique index attendance_events_slot_key on public.attendance_events (employee_id, work_date, projection_slot)
  where projection_slot is not null;
create unique index attendance_events_raw_key on public.attendance_events (biometric_event_id)
  where biometric_event_id is not null;

drop trigger company_refs on public.attendance_events;
create trigger company_refs before insert or update on public.attendance_events
  for each row execute function public.check_company_refs('location_id:locations', 'device_id:biometric_devices',
                                                          'import_batch_id:biometric_import_batches');

-- ===== A2. Guard trigger on `attendance_events`
create function public.attendance_external_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  r public.biometric_raw_events;
  s public.biometric_event_state;
  office uuid;
  projecting boolean := coalesce(current_setting('attendos.projection', true), '') = 'on';
begin
  -- (revision 6) the source of an existing row never changes, in either direction and in any context — projection
  -- included: web/correction rows never become biometric/import rows, and projected rows never become anything else.
  -- (No existing function changes a row's source: punch_core and decide_correction insert new rows.)
  if tg_op = 'UPDATE' and new.source is distinct from old.source then
    raise exception 'The source of an attendance event never changes (% to %)', old.source, new.source using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and old.source in ('biometric', 'import') then
    -- correction supersession: set once by decide_correction, never cleared or changed
    if old.superseded_by is not null and new.superseded_by is distinct from old.superseded_by then
      raise exception 'A replaced attendance event stays replaced' using errcode = '42501';
    end if;
    -- identity of the row (stable id, person, day, slot, kind, how it counts) never changes
    if (new.employee_id, new.kind, new.work_date, new.source, new.projection_slot, new.direction_basis, new.work_mode,
        new.verified, new.correction_id, new.distance_m, new.accuracy_m)
       is distinct from
       (old.employee_id, old.kind, old.work_date, old.source, old.projection_slot, old.direction_basis, old.work_mode,
        old.verified, old.correction_id, old.distance_m, old.accuracy_m) then
      raise exception 'A projected attendance event keeps its person, day, slot and kind' using errcode = '42501';
    end if;
    -- the attribution tuple may move only by projection, only on an unlocked slot
    if (new.at, new.biometric_event_id, new.device_id, new.import_batch_id, new.location_id)
       is distinct from (old.at, old.biometric_event_id, old.device_id, old.import_batch_id, old.location_id)
       and (not projecting or old.superseded_by is not null) then
      raise exception 'Only projection may move an unlocked projected slot' using errcode = '42501';
    end if;
  end if;

  -- full attribution check on INSERT, on ANY change of the attribution tuple (revision 5) and on a source transition
  -- (revision 6; defence in depth — the refusal above already stops every source change)
  if new.source in ('biometric', 'import')
     and (tg_op = 'INSERT'
          or new.source is distinct from old.source
          or (new.at, new.biometric_event_id, new.device_id, new.import_batch_id, new.location_id)
             is distinct from (old.at, old.biometric_event_id, old.device_id, old.import_batch_id, old.location_id)) then
    if (tg_op = 'INSERT' or new.source is distinct from old.source) and not projecting then
      raise exception 'Biometric attendance is written only by projection' using errcode = '42501';
    end if;
    select * into r from public.biometric_raw_events where id = new.biometric_event_id;
    select * into s from public.biometric_event_state where raw_event_id = new.biometric_event_id;
    office := case when r.device_id is not null then (select d.location_id from public.biometric_devices d where d.id = r.device_id) end;
    if r.id is null or s.raw_event_id is null                                            -- the raw punch and its state exist
       or r.company_id is distinct from public.emp_company(new.employee_id)              -- company
       or s.company_id is distinct from r.company_id
       or s.employee_id is distinct from new.employee_id                                  -- employee (frozen attribution)
       or s.work_date is distinct from new.work_date                                      -- work date (frozen)
       or r.punch_at is distinct from new.at                                              -- punch timestamp
       or r.device_id is distinct from new.device_id                                      -- device
       or r.import_batch_id is distinct from new.import_batch_id                          -- import batch
       or (new.source = 'biometric' and (office is null or new.location_id is distinct from office))   -- registered device office (Q6)
       or (new.source = 'import' and new.location_id is not null)                         -- imports: no office until 0013 defines one
       or (new.projection_slot like 'dev:%' and new.projection_slot is distinct from 'dev:' || new.biometric_event_id)
    then
      raise exception 'Projected attendance must match its raw punch (company, person, work day, time, device, batch, office)'
        using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
create trigger external_guard before insert or update on public.attendance_events
  for each row execute function public.attendance_external_guard();

-- ===== A3. Processing state — `held`, failure counter, frozen work date
alter table public.biometric_event_state
  add column hold_reason text check (hold_reason is null or hold_reason in ('employee_inactive', 'after_exit', 'before_joining',
    'non_working_day', 'on_leave', 'correction_pending', 'import_not_enabled', 'device_without_office')),
  add column held_since timestamptz,        -- when the punch entered 'held' (kept while it stays held)
  add column next_check_at timestamptz,     -- when the queue re-evaluates a held punch (backoff, §6.8)
  add column late_release_at timestamptz;   -- set when a hold ended after the automatic window: needs a NEW HR acceptance
alter table public.biometric_event_state add constraint biometric_event_state_held_timing
  check ((status = 'held') = (held_since is not null and next_check_at is not null));
-- 'stored' always means "awaiting processing" (no code before 0012 sets processed_at, so existing rows satisfy this)
alter table public.biometric_event_state add constraint biometric_event_state_stored_pending
  check (status <> 'stored' or processed_at is null) not valid;
alter table public.biometric_event_state validate constraint biometric_event_state_stored_pending;
create index biometric_event_state_pending on public.biometric_event_state (company_id, work_date, employee_id)
  where processed_at is null;
-- status list gains 'held' and 'correction_needed' (constraint name checked on 0010: biometric_event_state_status_check)
alter table public.biometric_event_state drop constraint biometric_event_state_status_check;
alter table public.biometric_event_state add constraint biometric_event_state_status_check check (status in ('stored', 'unmatched',
  'flagged', 'projected', 'provisional_out', 'extra', 'possible_duplicate', 'reconciled', 'after_correction', 'rejected',
  'dismissed', 'held', 'correction_needed'));
-- correction_needed: the punch can only reach the register through an approved attendance correction (session safety
-- and sequence problems, §6.6). HR acceptance cannot project it; HR may dismiss it; an approved correction for the day
-- turns it into after_correction.
alter table public.biometric_event_state add constraint biometric_event_state_hold check ((status = 'held') = (hold_reason is not null));
alter table public.biometric_event_state add constraint biometric_event_state_held_mapped check (status <> 'held' or mapping_id is not null);
create index biometric_event_state_due on public.biometric_event_state (company_id, work_date, employee_id)
  where status in ('stored', 'provisional_out');
create index biometric_event_state_held_due on public.biometric_event_state (next_check_at) where status = 'held';
-- revision 5: failures are counted from error records (one row per failed call) instead of a per-punch counter, so a
-- failure costs exactly one write
create index biometric_event_errors_day_failures on public.biometric_event_errors
  ((detail ->> 'employee_id'), (detail ->> 'work_date')) where kind = 'processing_failure' and resolved_at is null;
create function public.biometric_day_failures(p_emp uuid, p_day date) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.biometric_event_errors
   where kind = 'processing_failure' and resolved_at is null
     and detail ->> 'employee_id' = p_emp::text and detail ->> 'work_date' = p_day::text
$$;
-- biometric_event_reviews.action list is unchanged: 'dismiss' now also ends a correction_needed punch (A6).



-- ================================================================ state guard: work day frozen once set
create or replace function public.biometric_state_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare r public.biometric_raw_events; m public.biometric_employee_mappings;
begin
  if tg_op = 'UPDATE' then
    if new.raw_event_id <> old.raw_event_id or new.company_id <> old.company_id then
      raise exception 'Event state cannot move to another event or company' using errcode = '42501';
    end if;
    if old.mapping_id is not null and new.mapping_id is distinct from old.mapping_id then
      raise exception 'This punch was already attributed; its employee mapping cannot change' using errcode = '42501';
    end if;
    if old.decided and not new.decided then raise exception 'A review decision cannot be undone' using errcode = '42501'; end if;
    -- 0012: the work day of a punch is fixed once set
    if old.work_date is not null and new.work_date is distinct from old.work_date then
      raise exception 'The work day of a punch is fixed once set' using errcode = '42501';
    end if;
    new.version := old.version + 1;
    new.updated_at := now();
  end if;
  if new.mapping_id is not null and (tg_op = 'INSERT' or old.mapping_id is null) then
    select * into r from public.biometric_raw_events where id = new.raw_event_id;
    select * into m from public.biometric_employee_mappings where id = new.mapping_id;
    if m.employee_id is distinct from new.employee_id or m.employee_device_code <> r.employee_device_code
       or (m.device_id is not null and m.device_id is distinct from r.device_id)
       or r.punch_at < m.valid_from or (m.valid_to is not null and r.punch_at >= m.valid_to) then
      raise exception 'The mapping does not cover this punch (device, code and punch time)' using errcode = '23514';
    end if;
  end if;
  if new.projected_event_id is not null and (select employee_id from public.attendance_events where id = new.projected_event_id) is distinct from new.employee_id then
    raise exception 'Projected attendance must belong to the same person' using errcode = '42501';
  end if;
  if new.reconciled_with is not null and (select employee_id from public.attendance_events where id = new.reconciled_with) is distinct from new.employee_id then
    raise exception 'Reconciled attendance must belong to the same person' using errcode = '42501';
  end if;
  return new;
end $$;

-- ===== A4. Work date, day close, helpers, projection
create function public.biometric_work_date_at(p_emp uuid, p_at timestamptz, p_direction text default null,
                                              out work_date date, out ambiguous boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  cid uuid := public.emp_company(p_emp);
  close_min int := (public.biometric_settings_for(cid)).day_close_after_min;
  d date := (p_at at time zone public.company_tz(cid))::date;
  y public.shifts; t public.shifts;
  y_end timestamptz; t_start timestamptz;
begin
  ambiguous := false; work_date := d;
  select sh.* into y from public.shift_for(p_emp, d - 1) f join public.shifts sh on sh.id = f.shift_id;
  if y.id is null or y.end_time > y.start_time or (select p.work_mode from public.plan_for(p_emp, d - 1) p) = 'off' then return; end if;
  y_end := public.at_local(cid, d, y.end_time);
  if p_at < y_end then work_date := d - 1; return; end if;                 -- identical to work_date_for_checkin
  if p_direction = 'in' or p_at >= y_end + make_interval(mins => close_min) then return; end if;
  select sh.* into t from public.shift_for(p_emp, d) f join public.shifts sh on sh.id = f.shift_id;
  if t.id is not null and (select p.work_mode from public.plan_for(p_emp, d) p) <> 'off' then
    t_start := public.at_local(cid, d, t.start_time);
    if t_start < y_end + make_interval(mins => close_min) then ambiguous := true; end if;
  end if;
  work_date := d - 1;                                                       -- a night worker's departure after shift end
end $$;

create function public.biometric_day_close_at(p_emp uuid, p_day date) returns timestamptz
language sql stable security definer set search_path = public as $$
  select coalesce(
           (select public.at_local(public.emp_company(p_emp), p_day + case when sh.end_time <= sh.start_time then 1 else 0 end, sh.end_time)
              from public.shift_for(p_emp, p_day) f join public.shifts sh on sh.id = f.shift_id
             where (select p.work_mode from public.plan_for(p_emp, p_day) p) <> 'off'),
           public.at_local(public.emp_company(p_emp), p_day + 1, '00:00'))
         + make_interval(mins => (public.biometric_settings_for(public.emp_company(p_emp))).day_close_after_min)
$$;

-- when a still-held punch is looked at again: soon while the hold is fresh, rarely once it is old (§6.8)
create function public.biometric_hold_next_check(p_held_since timestamptz) returns timestamptz
language sql stable set search_path = public as $$
  select now() + case when p_held_since > now() - interval '1 day' then interval '15 minutes'
                      when p_held_since > now() - interval '7 days' then interval '1 hour'
                      else interval '6 hours' end
$$;

-- one role change for one raw punch; nothing written (no version bump, no audit) if nothing differs
create function public.biometric_set_role(p_raw bigint, p_status text, p_event bigint default null, p_slot text default null,
                                          p_reconciled bigint default null, p_flag text default null, p_hold text default null,
                                          p_late_release boolean default false)
returns boolean language plpgsql security definer set search_path = public as $$
-- returns true when it wrote: exactly one row write (used to count the per-call write budget, §6.9)
declare s public.biometric_event_state; a public.biometric_event_state;
begin
  select * into s from public.biometric_event_state where raw_event_id = p_raw;
  if s.status = p_status and s.projected_event_id is not distinct from p_event and s.projection_slot is not distinct from p_slot
     and s.reconciled_with is not distinct from p_reconciled and s.hold_reason is not distinct from p_hold
     and (p_flag is null or p_flag = any (s.flag_reasons))
     and (p_status = 'stored' or s.processed_at is not null)              -- nothing to change, no continuation mark to clear
     and not p_late_release then
    return false;
  end if;
  update public.biometric_event_state
     set status = p_status, projected_event_id = p_event, projection_slot = p_slot, reconciled_with = p_reconciled,
         hold_reason = p_hold,
         late_release_at = case when p_late_release then now() else late_release_at end,
         processed_at = case when p_status = 'stored' then null else now() end,   -- 'stored' always means "awaiting a role"
         held_since = case when p_status = 'held' then coalesce(case when s.status = 'held' then s.held_since end, now()) end,
         next_check_at = case when p_status = 'held'
                              then public.biometric_hold_next_check(coalesce(case when s.status = 'held' then s.held_since end, now())) end,
         flag_reasons = case when p_flag is null or p_flag = any (flag_reasons) then flag_reasons else array_append(flag_reasons, p_flag) end
   where raw_event_id = p_raw returning * into a;
  if (to_jsonb(s) - 'processed_at' - 'version' - 'updated_at' - 'next_check_at')
     is distinct from (to_jsonb(a) - 'processed_at' - 'version' - 'updated_at' - 'next_check_at') then
    insert into public.audit_log (company_id, action, target, target_id, before, after)
      values (s.company_id, 'biometric_role_' || p_status, 'biometric_event_state', p_raw::text, to_jsonb(s), to_jsonb(a));
  end if;
  return true;
end $$;

-- insert or move one slot row (same id); never touches a superseded slot
create function public.biometric_write_slot(p_emp uuid, p_day date, p_slot text, p_kind text, p_raw bigint, p_basis text,
                                            p_action text default 'biometric_project')
returns bigint language plpgsql security definer set search_path = public as $$
declare
  r public.biometric_raw_events := (select x from public.biometric_raw_events x where x.id = p_raw);
  loc uuid := (select location_id from public.biometric_devices where id = r.device_id);
  cur public.attendance_events;
  ev public.attendance_events;
begin
  select * into cur from public.attendance_events where employee_id = p_emp and work_date = p_day and projection_slot = p_slot for update;
  if cur.id is null then
    insert into public.attendance_events (employee_id, kind, at, work_mode, location_id, verified, source, work_date,
                                          device_id, biometric_event_id, projection_slot, direction_basis)
      values (p_emp, p_kind, r.punch_at, 'office', loc, false, 'biometric', p_day, r.device_id, p_raw, p_slot, p_basis)
      returning * into ev;
    insert into public.audit_log (company_id, action, target, target_id, after)
      values (r.company_id, p_action, 'attendance_events', ev.id::text, to_jsonb(ev) || jsonb_build_object('raw_event_id', p_raw));
  elsif cur.superseded_by is not null then
    raise exception 'Slot % of % is locked by a correction', p_slot, p_day using errcode = '42501';
  elsif cur.biometric_event_id = p_raw then
    return cur.id;
  else
    update public.attendance_events set at = r.punch_at, biometric_event_id = p_raw, device_id = r.device_id, location_id = loc
     where id = cur.id returning * into ev;
    insert into public.audit_log (company_id, action, target, target_id, before, after)
      values (r.company_id, 'biometric_slot_moved', 'attendance_events', ev.id::text, to_jsonb(cur), to_jsonb(ev));
  end if;
  return ev.id;
end $$;

create function public.biometric_project_day(p_emp uuid, p_day date, p_limit int default 200) returns jsonb
-- Budget rule (revision 5, §6.9): never more than p_limit row writes. Every operation of cost k runs only if
-- n + k <= lim - 1; the last write is reserved for a continuation mark. p_limit below 6 (largest atomic operation 5
-- + 1 reserved) defers the whole day: nothing is written.
language plpgsql security definer set search_path = public as $$
declare
  cid uuid := public.emp_company(p_emp);
  st public.biometric_settings := public.biometric_settings_for(cid);
  lim int := least(coalesce(p_limit, 200), 1000);                  -- row writes allowed in this call (§6.9), never raised
  s_cost int;                                                       -- writes of the atomic slot step
  n int := 0;                                                       -- writes made so far
  emp public.employees;
  pl record;
  lv public.leave_requests;
  hold text;
  want_hold text;
  closed boolean;
  locked boolean;
  modes text[];
  c record;
  x record;
  ss record;
  prev_at timestamptz;
  app_in public.attendance_events;
  app_out public.attendance_events;
  in_row public.attendance_events;
  out_row public.attendance_events;
  r_ids bigint[] := '{}';
  r_at timestamptz[] := '{}';
  r_pending boolean[] := '{}';
  done bigint[] := '{}';                                            -- punches already given a role in this call
  plan jsonb := '[]';                                               -- role decisions not yet written (§6.9)
  in_raw bigint; base_in timestamptz;
  out_raw bigint;
  ev_id bigint;
  last_kind text;
  newest timestamptz;
  i int;
begin
  if lim < 6 then                                                   -- not enough budget for a safe step: defer, write nothing
    return jsonb_build_object('ok', true, 'complete', false, 'written', 0, 'deferred', true);
  end if;
  perform set_config('lock_timeout', '5s', true);
  perform pg_advisory_xact_lock(hashtextextended(p_emp::text, 7));        -- (E1) the lock punch_core and the wrapper take
  perform set_config('lock_timeout', '0', true);
  perform set_config('attendos.projection', 'on', true);

  if not coalesce((select active from public.companies where id = cid), false) then
    return jsonb_build_object('ok', false, 'reason', 'company_inactive', 'complete', true, 'written', 0);
  end if;
  if not st.projection_enabled and not exists (select 1 from public.attendance_events
       where employee_id = p_emp and work_date = p_day and projection_slot is not null) then
    return jsonb_build_object('ok', false, 'reason', 'projection_disabled', 'complete', true, 'written', 0);
  end if;
  -- the rows this call may change, locked once in raw-id order (a review of one of them waits, then is re-read).
  -- Held punches that are not due are NOT locked, read or changed (§6.8).
  perform 1 from public.biometric_event_state
   where employee_id = p_emp and work_date = p_day
     and (status in ('stored', 'projected', 'provisional_out', 'extra', 'reconciled', 'correction_needed')
          or (status = 'held' and next_check_at <= now()))
   order by raw_event_id for update;

  select * into emp from public.employees where id = p_emp;
  closed := now() >= public.biometric_day_close_at(p_emp, p_day)
         or exists (select 1 from public.attendance_events where employee_id = p_emp and work_date > p_day and superseded_by is null);
  locked := exists (select 1 from public.attendance_corrections where employee_id = p_emp and work_date = p_day and status = 'approved')
         or exists (select 1 from public.attendance_events where employee_id = p_emp and work_date = p_day
                     and projection_slot is not null and superseded_by is not null);
  select * into pl from public.plan_for(p_emp, p_day);
  lv := public.leave_on(p_emp, p_day);
  hold := case
    when emp.exit_date is not null and p_day > emp.exit_date then 'after_exit'
    when not emp.active and emp.exit_date is null then 'employee_inactive'
    when p_day < coalesce(emp.joining_date, (emp.created_at at time zone public.company_tz(cid))::date) then 'before_joining'
    when pl.work_mode = 'off' then 'non_working_day'
    when lv.id is not null and lv.half_day is null then 'on_leave'
    when exists (select 1 from public.attendance_corrections where employee_id = p_emp and work_date = p_day and status = 'pending')
      then 'correction_pending' end;

  -- 1. gate: stored punches and DUE held punches only, oldest first, within the budget rule (§6.2, §6.8, §6.9).
  --    If the budget runs out, the rest are untouched and still stored / still due, so the queue returns to this day.
  for c in select s.raw_event_id id, s.status, s.decided, s.flag_reasons, s.late_release_at,
                  r.punch_at, r.source_auth, r.time_flags, r.import_batch_id, r.direction,
                  (select d.location_id from public.biometric_devices d where d.id = r.device_id) device_office
             from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
            where s.employee_id = p_emp and s.work_date = p_day
              and (s.status = 'stored' or (s.status = 'held' and s.next_check_at <= now()))
            order by r.punch_at, s.raw_event_id loop
    -- no mark needed here: what is not reached is still stored or still due
    if n + 1 > lim - 1 then return jsonb_build_object('ok', true, 'complete', false, 'written', n, 'stopped_in', 'gate'); end if;
    if c.punch_at > now() then continue; end if;
    want_hold := case when c.import_batch_id is not null then 'import_not_enabled'
                      when locked then null
                      when c.device_office is null then 'device_without_office'          -- Q6
                      else hold end;
    if locked and c.import_batch_id is null then
      n := n + public.biometric_set_role(c.id, 'after_correction')::int;
    -- (a) a hold applies now (decided from current data on every look)
    elsif want_hold is not null then
      if public.biometric_set_role(c.id, 'held', p_hold => want_hold) then n := n + 1;
      elsif c.status = 'held' then                        -- same hold, due look: only the next look time moves
        update public.biometric_event_state set next_check_at = public.biometric_hold_next_check(held_since)
         where raw_event_id = c.id;
        n := n + 1;
      end if;
    -- (b) hold ended after the automatic window: never projected automatically; needs a NEW individual acceptance
    elsif c.status = 'held' and c.punch_at < now() - make_interval(days => st.auto_project_max_age_days) then
      n := n + public.biometric_set_role(c.id, 'flagged', p_flag => 'late_backfill', p_late_release => true)::int;   -- one write
    -- (c) released late earlier: only an acceptance given AFTER that release counts
    elsif c.late_release_at is not null and not exists (
            select 1 from public.biometric_event_reviews v
             where v.raw_event_id = c.id and v.action = 'accept_time' and v.decided_at > c.late_release_at) then
      n := n + public.biometric_set_role(c.id, 'flagged', p_flag => 'late_backfill')::int;
    -- (d) soft checks, null-safe; an individual HR acceptance covers these and only these
    elsif c.decided is not true and c.source_auth is distinct from 'authenticated' then
      n := n + public.biometric_set_role(c.id, 'flagged', p_flag => 'unauthenticated_source')::int;
    elsif c.decided is not true and (coalesce(cardinality(c.time_flags), 0) > 0 or coalesce(cardinality(c.flag_reasons), 0) > 0) then
      n := n + public.biometric_set_role(c.id, 'flagged')::int;
    elsif c.decided is not true and c.punch_at < now() - make_interval(days => st.auto_project_max_age_days) then
      n := n + public.biometric_set_role(c.id, 'flagged', p_flag => 'late_backfill')::int;
    elsif c.decided is not true and (public.biometric_work_date_at(p_emp, c.punch_at, c.direction)).ambiguous is not false then
      n := n + public.biometric_set_role(c.id, 'flagged', p_flag => 'ambiguous_work_date')::int;
    -- (e) released within the window: back to 'stored' (awaiting a role), then the ordinary rules below
    elsif c.status = 'held' then
      n := n + public.biometric_set_role(c.id, 'stored')::int;
    end if;
  end loop;

  if locked then  -- a provisional out on a corrected day is no longer a candidate (§7.1 of the architecture)
    for c in select raw_event_id id from public.biometric_event_state
              where employee_id = p_emp and work_date = p_day
                and (status = 'correction_needed' or (status in ('provisional_out', 'extra', 'reconciled') and not decided))
              order by raw_event_id loop
      if n + 1 > lim - 1 then
        update public.biometric_event_state set processed_at = null where raw_event_id = c.id;   -- continuation mark (§6.9)
        return jsonb_build_object('ok', true, 'complete', false, 'written', n + 1, 'stopped_in', 'locked');
      end if;
      n := n + public.biometric_set_role(c.id, 'after_correction')::int;
    end loop;
    return jsonb_build_object('ok', true, 'complete', true, 'written', n, 'locked', true);
  end if;

  -- 2. candidates: gated punches plus the day's current roles (recomputed every run; decided extras stay as HR left them)
  select array_agg(distinct d.direction_mode) into modes
    from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
    join public.biometric_devices d on d.id = r.device_id
   where s.employee_id = p_emp and s.work_date = p_day and r.punch_at <= now()
     and (s.status in ('stored', 'projected', 'provisional_out') or (s.status in ('extra', 'reconciled') and not s.decided));
  if cardinality(modes) > 1
     or exists (select 1 from public.attendance_events where employee_id = p_emp and work_date = p_day and projection_slot is not null
                  and direction_basis <> case when modes[1] = 'device' then 'device' else 'inferred_first_last' end) then
    for c in select s.raw_event_id id, s.status from public.biometric_event_state s
              where s.employee_id = p_emp and s.work_date = p_day and s.status in ('stored', 'provisional_out')
              order by s.raw_event_id loop
      if n + 1 > lim - 1 then
        if c.status <> 'stored' then update public.biometric_event_state set processed_at = null where raw_event_id = c.id; n := n + 1; end if;
        return jsonb_build_object('ok', true, 'complete', false, 'written', n, 'stopped_in', 'mixed_modes');
      end if;
      n := n + public.biometric_set_role(c.id, 'correction_needed', p_flag => 'mixed_direction_modes')::int;
    end loop;
    return jsonb_build_object('ok', true, 'complete', true, 'written', n, 'flagged', 'mixed_direction_modes');
  end if;

  select * into app_in from public.attendance_events where employee_id = p_emp and work_date = p_day and superseded_by is null
     and kind = 'in' and source in ('web', 'correction') order by at, id limit 1;
  select * into app_out from public.attendance_events where employee_id = p_emp and work_date = p_day and superseded_by is null
     and kind = 'out' and source in ('web', 'correction') order by at desc, id desc limit 1;

  if modes[1] = 'device' then
    -- 3a. device direction (§6.5): one punch at a time in time order, each decided against the rows already counted.
    --     Stops when the budget is used; later punches stay stored (or are marked) and are taken next run, still in order.
    for c in select s.raw_event_id id, s.status, s.decided, r.punch_at, r.direction
               from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
              where s.employee_id = p_emp and s.work_date = p_day and r.punch_at <= now() and s.projected_event_id is null
                and (s.status = 'stored' or (s.status in ('extra', 'reconciled') and not s.decided))
              order by r.punch_at, s.raw_event_id loop
      if n + 2 > lim - 1 then                                         -- a device punch can cost 2 (slot + role)
        if c.status <> 'stored' then update public.biometric_event_state set processed_at = null where raw_event_id = c.id; n := n + 1; end if;
        return jsonb_build_object('ok', true, 'complete', false, 'written', n, 'stopped_in', 'device');
      end if;
      if c.direction is null then n := n + public.biometric_set_role(c.id, 'correction_needed', p_flag => 'no_direction')::int; continue; end if;
      if exists (select 1 from public.attendance_events e where e.employee_id = p_emp and e.work_date = p_day and e.superseded_by is null
                   and e.source = 'biometric' and e.kind = c.direction and abs(extract(epoch from e.at - c.punch_at)) <= st.double_press_s) then
        n := n + public.biometric_set_role(c.id, 'extra', p_flag => 'double_press')::int; continue;
      end if;
      ev_id := null;
      select e.id into ev_id from public.attendance_events e where e.employee_id = p_emp and e.work_date = p_day and e.superseded_by is null
         and e.kind = c.direction and e.source in ('web', 'correction') and abs(extract(epoch from e.at - c.punch_at)) <= st.reconcile_min * 60
       order by abs(extract(epoch from e.at - c.punch_at)) limit 1;
      if ev_id is not null then n := n + public.biometric_set_role(c.id, 'reconciled', p_reconciled => ev_id)::int; continue; end if;
      select max(at) into newest from public.attendance_events where employee_id = p_emp and work_date = p_day and superseded_by is null;
      if newest is not null and c.punch_at <= newest then
        n := n + public.biometric_set_role(c.id, 'correction_needed', p_flag => 'out_of_order')::int; continue;
      end if;
      select kind into last_kind from public.attendance_events where employee_id = p_emp and work_date = p_day and superseded_by is null
       order by at desc, id desc limit 1;
      select * into ss from public.session_state(p_emp);
      if c.direction = last_kind and newest is not null and c.punch_at - newest <= make_interval(mins => st.reconcile_min) then
        n := n + public.biometric_set_role(c.id, 'extra', p_flag => 'repeat_' || c.direction)::int; continue;
      end if;
      if (c.direction = 'in' and (last_kind in ('in', 'break_start', 'break_end')
             or (ss.state <> 'off' and ss.work_date <> p_day and now() < public.biometric_day_close_at(p_emp, ss.work_date))))
         or (c.direction = 'out' and coalesce(last_kind, 'out') in ('out', 'break_start')) then
        n := n + public.biometric_set_role(c.id, 'correction_needed', p_flag => 'impossible_transition')::int; continue;
      end if;
      -- session safety (HR acceptance does NOT bypass this): an IN on a finished day that would become the person's newest
      -- event is allowed only if the day's next pending punch is an OUT that will close it in this same call
      -- (implementation fix found in B3.4 testing: a delayed in-order IN+OUT pair must not be refused for its IN alone)
      if c.direction = 'in' and closed
         and c.punch_at > coalesce((select max(at) from public.attendance_events where employee_id = p_emp and superseded_by is null), '-infinity') then
        if coalesce((select r2.direction from public.biometric_event_state s2 join public.biometric_raw_events r2 on r2.id = s2.raw_event_id
                      where s2.employee_id = p_emp and s2.work_date = p_day and s2.status = 'stored' and r2.punch_at > c.punch_at and r2.punch_at <= now()
                      order by r2.punch_at, s2.raw_event_id limit 1), '') <> 'out' then
          n := n + public.biometric_set_role(c.id, 'correction_needed', p_flag => 'would_open_closed_day')::int; continue;
        end if;
        if n + 4 > lim - 1 then                                       -- IN and its closing OUT are written in the same call
          if c.status <> 'stored' then update public.biometric_event_state set processed_at = null where raw_event_id = c.id; n := n + 1; end if;
          return jsonb_build_object('ok', true, 'complete', false, 'written', n, 'stopped_in', 'device');
        end if;
      end if;
      ev_id := public.biometric_write_slot(p_emp, p_day, 'dev:' || c.id, c.direction, c.id, 'device');
      perform public.biometric_set_role(c.id, 'projected', ev_id, 'dev:' || c.id);
      n := n + 2;
    end loop;
    return jsonb_build_object('ok', true, 'complete', true, 'written', n, 'mode', 'device');
  end if;

  -- 3b. first-in / last-out (§6.4). Roles are DECIDED over the whole day in time order (in memory), then WRITTEN:
  --     slot rows with their own punches first (at most 5 writes), then the other role changes, existing roles before
  --     new punches, each group in time order, within the budget (§6.9).
  select * into in_row from public.attendance_events where employee_id = p_emp and work_date = p_day and projection_slot = 'in';
  select * into out_row from public.attendance_events where employee_id = p_emp and work_date = p_day and projection_slot = 'out';
  for c in select s.raw_event_id id, s.status, s.projected_event_id, r.punch_at
             from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
            where s.employee_id = p_emp and s.work_date = p_day and r.punch_at <= now()
              and (s.status in ('stored', 'projected', 'provisional_out') or (s.status in ('extra', 'reconciled') and not s.decided))
            order by r.punch_at, s.raw_event_id loop
    if prev_at is not null and c.punch_at < prev_at + make_interval(secs => st.double_press_s) and c.projected_event_id is null then
      plan := plan || jsonb_build_object('raw', c.id, 'status', 'extra', 'flag', 'double_press', 'pending', c.status = 'stored', 'at', c.punch_at);
      done := done || c.id; continue;
    end if;
    prev_at := c.punch_at;
    if c.projected_event_id is null and app_in.id is not null and abs(extract(epoch from c.punch_at - app_in.at)) <= st.reconcile_min * 60 then
      plan := plan || jsonb_build_object('raw', c.id, 'status', 'reconciled', 'rec', app_in.id, 'pending', c.status = 'stored', 'at', c.punch_at);
      done := done || c.id; continue;
    end if;
    if c.projected_event_id is null and app_out.id is not null and abs(extract(epoch from c.punch_at - app_out.at)) <= st.reconcile_min * 60 then
      plan := plan || jsonb_build_object('raw', c.id, 'status', 'reconciled', 'rec', app_out.id, 'pending', c.status = 'stored', 'at', c.punch_at);
      done := done || c.id; continue;
    end if;
    if app_in.id is not null and c.punch_at < app_in.at then
      plan := plan || jsonb_build_object('raw', c.id, 'status', 'correction_needed', 'flag', 'before_app_checkin', 'pending', c.status = 'stored', 'at', c.punch_at);
      done := done || c.id; continue;
    end if;
    r_ids := r_ids || c.id; r_at := r_at || c.punch_at; r_pending := r_pending || (c.status = 'stored');
  end loop;

  -- in slot
  if app_in.id is not null then
    base_in := app_in.at;
  elsif in_row.id is not null then
    in_raw := in_row.biometric_event_id; base_in := in_row.at;
    if cardinality(r_ids) > 0 and r_ids[1] <> in_raw and r_at[1] < in_row.at then
      if closed then
        plan := plan || jsonb_build_object('raw', r_ids[1], 'status', 'correction_needed', 'flag', 'after_day_close', 'pending', r_pending[1], 'at', r_at[1]);
        done := done || r_ids[1]; r_ids := r_ids[2:]; r_at := r_at[2:]; r_pending := r_pending[2:];
      else in_raw := r_ids[1]; base_in := r_at[1]; end if;
    end if;
  elsif cardinality(r_ids) > 0 then
    in_raw := r_ids[1]; base_in := r_at[1];
  end if;

  -- out candidate: latest remaining punch ≥ min session after the in, only if the app has not checked out
  if base_in is not null and app_out.id is null then
    for i in reverse coalesce(cardinality(r_ids), 0) .. 1 loop
      if r_ids[i] is distinct from in_raw and r_at[i] >= base_in + make_interval(mins => st.min_session_min) then out_raw := r_ids[i]; exit; end if;
    end loop;
  end if;
  if out_row.id is not null and out_raw is distinct from out_row.biometric_event_id then   -- a counted check-out never moves
    if out_raw is not null then
      plan := plan || jsonb_build_object('raw', out_raw, 'status', 'correction_needed', 'flag', 'after_day_close',
                                         'pending', (select status = 'stored' from public.biometric_event_state where raw_event_id = out_raw),
                                         'at', (select punch_at from public.biometric_raw_events where id = out_raw));
      done := done || out_raw;
    end if;
    out_raw := out_row.biometric_event_id;
  end if;

  -- session protection for a new in (§6.6) — not bypassed by any HR acceptance
  if in_raw is not null and in_row.id is null then
    select * into ss from public.session_state(p_emp);
    if (ss.state <> 'off' and ss.work_date <> p_day and now() < public.biometric_day_close_at(p_emp, ss.work_date))
       or (closed and out_raw is null
           and base_in > coalesce((select max(at) from public.attendance_events where employee_id = p_emp and superseded_by is null), '-infinity')) then
      plan := plan || jsonb_build_object('raw', in_raw, 'status', 'correction_needed', 'at', base_in,
                'pending', (select status = 'stored' from public.biometric_event_state where raw_event_id = in_raw),
                'flag', case when ss.state <> 'off' and ss.work_date <> p_day then 'open_session_other_day' else 'would_open_closed_day' end);
      done := done || in_raw;
      if ss.state <> 'off' and ss.work_date <> p_day then out_raw := null; end if;
      in_raw := null;
    end if;
  end if;

  -- write the slots together with their own punches' roles: one atomic step of at most 5 writes. If it does not fit,
  -- nothing of it is written; the day stays due (a stored punch, or one continuation mark) and continues next call.
  s_cost := case when in_raw is null then 0
                 else 2 + case when in_row.id is not null and in_row.biometric_event_id is distinct from in_raw then 1 else 0 end end
          + case when out_raw is null then 0 when out_row.id is null and closed then 2 else 1 end;
  if n + s_cost > lim - 1 then
    if not exists (select 1 from public.biometric_event_state where employee_id = p_emp and work_date = p_day and status = 'stored') then
      update public.biometric_event_state set processed_at = null
       where raw_event_id = (select min(raw_event_id) from public.biometric_event_state
                              where employee_id = p_emp and work_date = p_day
                                and (status in ('projected', 'provisional_out') or (status in ('extra', 'reconciled') and not decided)));
      n := n + 1;
    end if;
    return jsonb_build_object('ok', true, 'complete', false, 'written', n, 'stopped_in', 'before_slots');
  end if;
  if in_raw is not null then
    ev_id := public.biometric_write_slot(p_emp, p_day, 'in', 'in', in_raw, 'inferred_first_last');
    if in_row.id is not null and in_row.biometric_event_id <> in_raw then
      perform public.biometric_set_role(in_row.biometric_event_id, 'extra', p_flag => 'replaced_by_earlier_punch');
      done := done || in_row.biometric_event_id; n := n + 1;
    end if;
    perform public.biometric_set_role(in_raw, 'projected', ev_id, 'in',
      p_flag => case when closed and out_raw is null and app_out.id is null then 'incomplete' end);
    done := done || in_raw; n := n + 2;
  end if;
  if out_raw is not null then
    if out_row.id is not null then
      n := n + public.biometric_set_role(out_raw, 'projected', out_row.id, 'out')::int;
    elsif closed then
      ev_id := public.biometric_write_slot(p_emp, p_day, 'out', 'out', out_raw, 'inferred_first_last', 'biometric_finalise');
      perform public.biometric_set_role(out_raw, 'projected', ev_id, 'out');
      n := n + 2;
    else
      n := n + public.biometric_set_role(out_raw, 'provisional_out')::int;
    end if;
    done := done || out_raw;
  end if;
  -- everything else is an extra punch (kept, shown, never counted)
  for i in 1 .. coalesce(cardinality(r_ids), 0) loop
    if not (r_ids[i] = any (done)) then
      plan := plan || jsonb_build_object('raw', r_ids[i], 'status', 'extra', 'pending', r_pending[i], 'at', r_at[i]);
    end if;
  end loop;

  -- write the remaining decisions within the budget: existing roles first, then new punches, each in time order.
  -- If the budget runs out, the first unwritten punch is left (or marked) with processed_at = null so the queue
  -- returns to this day; the next call decides the same roles again (deterministic) and continues.
  for x in select * from jsonb_to_recordset(plan) as t(raw bigint, status text, rec bigint, flag text, pending boolean, at timestamptz)
            order by pending, at, raw loop
    if n + 1 > lim - 1 then
      if not x.pending then update public.biometric_event_state set processed_at = null where raw_event_id = x.raw; n := n + 1; end if;
      return jsonb_build_object('ok', true, 'complete', false, 'written', n, 'stopped_in', 'roles');
    end if;
    n := n + public.biometric_set_role(x.raw, x.status, null, null, x.rec, x.flag)::int;
  end loop;
  return jsonb_build_object('ok', true, 'complete', true, 'written', n, 'mode', 'first_last', 'closed', closed);
end $$;

-- ===== A5. Queue procedure, HR "process now", `day_events`
-- SECURITY INVOKER and no SET clause on purpose: PostgreSQL refuses COMMIT inside a SECURITY DEFINER procedure or
-- one with a SET clause. It runs as the job owner (postgres) only; every name is schema-qualified; it is revoked
-- from public/anon/authenticated, and everything it calls is SECURITY DEFINER with a pinned search_path.
create procedure public.biometric_run_projection(p_max int default 200, p_held_max int default 50,
                                                 p_write_budget int default 2000, p_held_write_budget int default 500,
                                                 p_day_limit int default 200)
language plpgsql as $$
declare
  k record;
  w int;
  left_current int := p_write_budget;
  left_held int := p_held_write_budget;
begin
  -- 0. work dates for newly attributed punches (frozen once set)
  update public.biometric_event_state s
     set work_date = (public.biometric_work_date_at(s.employee_id, r.punch_at, r.direction)).work_date
    from public.biometric_raw_events r
   where r.id = s.raw_event_id and s.work_date is null and s.employee_id is not null and s.status <> 'unmatched';
  commit;

  -- 1. current work: own day budget (p_max) and write budget (p_write_budget); newest work day first; each employee-day
  --    at most p_day_limit writes per call, so one huge day cannot use the whole run. Selected: punches awaiting
  --    processing (stored, or a continuation mark), days whose close time has passed, recent closed days without a check-out.
  for k in
    select distinct s.employee_id, s.work_date, s.company_id
      from public.biometric_event_state s
      join public.companies co on co.id = s.company_id and co.active
      left join public.biometric_settings b on b.company_id = s.company_id
     where s.work_date is not null and public.biometric_day_failures(s.employee_id, s.work_date) < 3
       and ((s.processed_at is null
             and (s.status in ('stored', 'projected', 'provisional_out', 'correction_needed')
                  or (s.status in ('extra', 'reconciled') and not s.decided)))
         or (s.status = 'provisional_out' and now() >= public.biometric_day_close_at(s.employee_id, s.work_date))
         or (s.status = 'projected' and s.projection_slot = 'in' and not ('incomplete' = any (s.flag_reasons))
             and s.work_date >= public.local_today(s.company_id) - 3                     -- company-local date, not current_date
             and now() >= public.biometric_day_close_at(s.employee_id, s.work_date)
             and not exists (select 1 from public.attendance_events e where e.employee_id = s.employee_id
                               and e.work_date = s.work_date and e.kind = 'out' and e.superseded_by is null)))
       and (coalesce(b.projection_enabled, false)                                     -- Q3: no new day while disabled
         or exists (select 1 from public.attendance_events e where e.employee_id = s.employee_id and e.work_date = s.work_date
                      and e.projection_slot is not null))                              --     but started days finish
     order by s.work_date desc, s.employee_id
     limit p_max
  loop
    exit when left_current < 6;          -- not enough for a safe step: the remaining days wait for the next run
    w := 0;
    call public.biometric_project_one(k.employee_id, k.work_date, k.company_id, least(p_day_limit, left_current), w);
    left_current := left_current - w;   -- w <= the limit passed, so the budget is never exceeded
    commit;
  end loop;

  -- 2. held punches: SEPARATE day and write budgets; only punches whose next_check_at has passed; any age; the
  --    longest-waiting first. project_day itself re-checks "due" under the lock, so a held punch that another run has
  --    just looked at is skipped, and not-due held punches of the same day are never touched.
  for k in
    select s.employee_id, s.work_date, s.company_id, min(s.next_check_at) due
      from public.biometric_event_state s
      join public.companies co on co.id = s.company_id and co.active
      left join public.biometric_settings b on b.company_id = s.company_id
     where s.status = 'held' and s.next_check_at <= now() and public.biometric_day_failures(s.employee_id, s.work_date) < 3
       and (coalesce(b.projection_enabled, false)
         or exists (select 1 from public.attendance_events e where e.employee_id = s.employee_id and e.work_date = s.work_date
                      and e.projection_slot is not null))
     group by s.employee_id, s.work_date, s.company_id
     order by due, s.work_date desc
     limit p_held_max
  loop
    exit when left_held < 6;
    w := 0;
    call public.biometric_project_one(k.employee_id, k.work_date, k.company_id, least(p_day_limit, left_held), w);
    left_held := left_held - w;
    commit;
  end loop;
end $$;

-- one employee-day with failure accounting; reports the writes it made (no COMMIT here; the caller commits).
-- A failed call is rolled back completely and costs exactly one write: its error record.
create procedure public.biometric_project_one(p_emp uuid, p_day date, p_company uuid, p_limit int, inout p_written int)
language plpgsql as $$
declare res jsonb;
begin
  res := public.biometric_project_day(p_emp, p_day, p_limit);
  p_written := coalesce((res ->> 'written')::int, 0);
exception
  when lock_not_available then p_written := 0;                           -- busy: retried next run, not a failure
  when others then
    p_written := 1;
    insert into public.biometric_event_errors (company_id, kind, detail)
      values (p_company, 'processing_failure', jsonb_build_object('employee_id', p_emp, 'work_date', p_day,
              'sqlstate', sqlstate, 'message', left(sqlerrm, 300)));
end $$;

create function public.biometric_project_now(p_emp uuid, p_day date) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.biometric_require(false);                                 -- HR or Admin of the caller's company
  if not public.hr_of(p_emp) then raise exception 'Not allowed' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_emp::text, 7));        -- lock first (re-entrant in project_day)
  update public.biometric_event_state s set work_date = (public.biometric_work_date_at(s.employee_id, r.punch_at, r.direction)).work_date
    from public.biometric_raw_events r where r.id = s.raw_event_id and s.employee_id = p_emp and s.work_date is null;
  return public.biometric_project_day(p_emp, p_day);
end $$;

create function public.day_events(p_emp uuid, p_day date)
returns table (at timestamptz, kind text, counted boolean, source text, label text, device text, role text,
               attendance_event_id bigint, raw_event_id bigint, replaced_by_correction bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_see(p_emp) then raise exception 'Not allowed' using errcode = '42501'; end if;
  return query
  select e.at, e.kind, e.superseded_by is null, e.source,
         case e.source when 'web' then 'App' when 'correction' then 'Correction' when 'import' then 'Imported'
                       else case e.direction_basis when 'device' then 'Biometric · device In/Out' else 'Biometric · inferred' end end,
         d.name, null::text, e.id, e.biometric_event_id, e.superseded_by
    from public.attendance_events e left join public.biometric_devices d on d.id = e.device_id
   where e.employee_id = p_emp and e.work_date = p_day
  union all
  select r.punch_at, null::text, false, case when r.import_batch_id is null then 'biometric' else 'import' end,
         case s.status when 'provisional_out' then 'Provisional Out' when 'extra' then 'Extra punch'
                       when 'possible_duplicate' then 'Possible duplicate' when 'reconciled' then 'Matched with app punch'
                       when 'after_correction' then 'After correction' when 'held' then 'Waiting for HR'
                       when 'flagged' then 'Needs review' when 'rejected' then 'Duplicate' when 'dismissed' then 'Dismissed'
                       else 'Waiting to be processed' end,
         d.name, s.status, s.reconciled_with, r.id, null::bigint
    from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
    left join public.biometric_devices d on d.id = r.device_id
   where s.employee_id = p_emp and s.work_date = p_day and s.status <> 'projected'
   order by 1, 3 desc;
end $$;

-- Pending biometric check-out for one person-day: drives the "provisional" display (§11.2). Read-only.
create function public.biometric_day_pending(p_emp uuid, p_day date,
  out pending_checkout boolean, out provisional_out_at timestamptz, out final_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_see(p_emp) then raise exception 'Not allowed' using errcode = '42501'; end if;
  select r.punch_at into provisional_out_at
    from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
   where s.employee_id = p_emp and s.work_date = p_day and s.status = 'provisional_out'
   order by r.punch_at desc limit 1;
  pending_checkout := provisional_out_at is not null;
  final_at := case when pending_checkout then public.biometric_day_close_at(p_emp, p_day) end;
end $$;

-- Per person-day sources of the counted events and pending check-outs, same scope and filters as report_days
-- (company, can_see, department, employee; at most 93 days). Used by the register/detail CSV "Source" column
-- and the register's "pending check-out" marker. report_days itself is not changed.
create function public.attendance_day_sources(p_from date, p_to date, p_department uuid default null, p_employee uuid default null)
returns table (employee_id uuid, work_date date, sources text[], pending_checkout boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare cid uuid := public.my_company();
begin
  if cid is null then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then raise exception 'Choose a range of up to 93 days'; end if;
  return query
  with people as (
    select e.id from public.employees e
     where e.company_id = cid and public.can_see(e.id)
       and (p_department is null or e.department_id = p_department) and (p_employee is null or e.id = p_employee)
  ), counted as (
    select ev.employee_id, ev.work_date, array_agg(distinct ev.source order by ev.source) srcs
      from public.attendance_events ev join people pp on pp.id = ev.employee_id
     where ev.work_date between p_from and p_to and ev.superseded_by is null and ev.kind in ('in', 'out')
     group by 1, 2
  ), pending as (
    select distinct s.employee_id, s.work_date from public.biometric_event_state s join people pp on pp.id = s.employee_id
     where s.work_date between p_from and p_to and s.status = 'provisional_out'
  )
  select coalesce(c.employee_id, p.employee_id), coalesce(c.work_date, p.work_date), coalesce(c.srcs, '{}'), p.employee_id is not null
    from counted c full join pending p on p.employee_id = c.employee_id and p.work_date = c.work_date;
end $$;

-- Q8: Admin warning only. People with an active biometric mapping whose next shift starts before the previous day
-- closes for projection. Read-only; changes no shift, roster or setting.
create function public.biometric_shift_gap_warnings(p_days int default 14)
returns table (employee_id uuid, full_name text, work_date date, day_closes_at timestamptz, next_shift_starts_at timestamptz, gap_min int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare cid uuid := public.biometric_require(true);
begin
  return query
  select e.id, e.full_name, g::date, public.biometric_day_close_at(e.id, g::date), nx.starts,
         floor(extract(epoch from nx.starts - public.biometric_day_close_at(e.id, g::date)) / 60)::int
    from public.employees e
    cross join generate_series(public.local_today(cid), public.local_today(cid) + least(greatest(p_days, 1), 31), interval '1 day') g
    cross join lateral (
      select public.at_local(cid, g::date + 1, sh.start_time) starts
        from public.shift_for(e.id, g::date + 1) f join public.shifts sh on sh.id = f.shift_id
       where (select p.work_mode from public.plan_for(e.id, g::date + 1) p) <> 'off') nx
   where e.company_id = cid and e.active
     and exists (select 1 from public.biometric_employee_mappings m where m.employee_id = e.id and m.valid_to is null)
     and (select p.work_mode from public.plan_for(e.id, g::date) p) <> 'off'
     and nx.starts < public.biometric_day_close_at(e.id, g::date)
   order by 3, 2;
end $$;

-- Admin: retry a day that failed three times (after the cause is fixed). Same lock and function as the queue.
create function public.biometric_retry_day(p_emp uuid, p_day date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true);
begin
  if public.emp_company(p_emp) is distinct from cid then raise exception 'Not allowed' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_emp::text, 7));
  update public.biometric_event_errors set resolved_at = now(), resolved_by = public.my_employee_id(), resolution = 'Retry requested by Admin'
   where kind = 'processing_failure' and resolved_at is null and company_id = cid
     and detail ->> 'employee_id' = p_emp::text and detail ->> 'work_date' = p_day::text;
  insert into public.audit_log (company_id, action, target, target_id, after)
    values (cid, 'biometric_retry_day', 'employees', p_emp::text, jsonb_build_object('work_date', p_day));
  return public.biometric_project_day(p_emp, p_day);
end $$;

-- ================================================================ A6. review changes
create or replace function public.biometric_review_event(p_raw bigint, p_action text, p_reason text, p_expected_version int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cid uuid := public.biometric_require(false);
  s public.biometric_event_state;
  next_status text;
  code text;
  after public.biometric_event_state;
begin
  select employee_device_code into code from public.biometric_raw_events where id = p_raw and company_id = cid;
  if code is null then raise exception 'Not allowed' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock_shared(public.biometric_code_lock_key(cid, code)); -- waits for a mapping change of this code
  select * into s from public.biometric_event_state where raw_event_id = p_raw and company_id = cid for update;
  if s.raw_event_id is null then raise exception 'Not allowed' using errcode = '42501'; end if;
  -- 0012: a correction_needed punch can only be dismissed (or resolved by an approved correction), even if it was
  -- accepted earlier for another reason; a punch released after the automatic window needs a NEW acceptance
  if s.status = 'correction_needed' then
    if p_action <> 'dismiss' then
      return jsonb_build_object('ok', false, 'message', format('This punch would affect the person''s check-in state. Ask the employee to request an attendance correction for %s.', s.work_date));
    end if;
  elsif s.decided and not (s.status = 'flagged' and p_action = 'accept_time' and s.late_release_at is not null and not exists (
          select 1 from public.biometric_event_reviews v where v.raw_event_id = p_raw and v.action = 'accept_time'
           and v.decided_at > s.late_release_at)) then
    return jsonb_build_object('ok', false, 'message', 'This punch has already been decided.');
  end if;
  if p_expected_version is distinct from s.version then
    return jsonb_build_object('ok', false, 'message', 'This item changed since you opened it. Reload and decide again.');
  end if;
  next_status := case
    when s.status = 'unmatched' and p_action = 'dismiss' then 'dismissed'
    when s.status = 'flagged' and p_action = 'accept_time' then 'stored'
    when s.status = 'flagged' and p_action = 'dismiss' then 'dismissed'
    when s.status = 'possible_duplicate' and p_action = 'confirm_duplicate' then 'rejected'
    when s.status = 'possible_duplicate' and p_action = 'not_duplicate' then 'stored'
    when s.status = 'extra' and p_action = 'keep_extra' then 'extra'
    when s.status = 'extra' and p_action = 'dismiss' then 'dismissed'
    when s.status = 'after_correction' and p_action = 'keep_correction' then 'after_correction'
    when s.status = 'after_correction' and p_action = 'dismiss' then 'dismissed'
    when s.status = 'correction_needed' and p_action = 'dismiss' then 'dismissed' end;
  if next_status is null then return jsonb_build_object('ok', false, 'message', 'That decision does not apply to this punch.'); end if;
  if p_action in ('accept_time', 'dismiss', 'not_duplicate') and length(trim(coalesce(p_reason, ''))) < 5 then
    return jsonb_build_object('ok', false, 'message', 'A reason is required (at least 5 characters).');
  end if;
  -- accepting the time of a punch that has no mapping yet leaves it waiting for a mapping (not decided)
  if next_status = 'stored' and s.mapping_id is null then next_status := 'unmatched'; end if;
  update public.biometric_event_state set status = next_status, decided = (next_status <> 'unmatched'),
         processed_at = case when next_status = 'stored' then null else processed_at end   -- 0012: picked up again by the queue
   where raw_event_id = p_raw returning * into after;
  insert into public.biometric_event_reviews (company_id, raw_event_id, action, reason, decided_by, decided_role, state_before, state_after)
    values (cid, p_raw, p_action, nullif(trim(coalesce(p_reason, '')), ''), public.my_employee_id(), public.my_role(), to_jsonb(s), to_jsonb(after));
  insert into public.audit_log (company_id, action, target, target_id, before, after)
    values (cid, 'review_' || p_action, 'biometric_event_state', p_raw::text, to_jsonb(s), to_jsonb(after));
  return jsonb_build_object('ok', true, 'status', next_status);
end $$;


-- ===== A7. Correction lock wrapper (as approved; identical to the proven proposal)
alter function public.decide_correction(bigint, boolean, text) rename to decide_correction_core;
create function public.decide_correction(p_id bigint, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare emp uuid;
begin
  select employee_id into emp from public.attendance_corrections where id = p_id;
  if emp is null or not public.in_my_company(emp) then raise exception 'Not allowed' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(emp::text, 7));
  return public.decide_correction_core(p_id, p_approve, p_note);
end $$;
revoke all on function public.decide_correction_core(bigint, boolean, text) from public, anon, authenticated;
revoke all on function public.decide_correction(bigint, boolean, text) from public, anon;
grant execute on function public.decide_correction(bigint, boolean, text) to authenticated;

-- ================================================================ A8. verification history labels biometric/imported rows
create or replace function public.verification_log(p_limit int default 100)
returns table (at timestamptz, employee text, kind text, outcome text, work_mode text, location text, distance_m int, accuracy_m int, reason text)
language plpgsql stable security definer set search_path = public as $$
declare cid uuid := public.my_company();
begin
  if not public.is_hr() then raise exception 'Not allowed' using errcode = '42501'; end if;
  return query
  select * from (
    select e.at, emp.full_name, e.kind,
           case when e.source = 'correction' then 'corrected' when e.source = 'biometric' then 'biometric'
                when e.source = 'import' then 'imported' when e.verified then 'verified' else 'not_required' end,
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

-- ===== A9. Grants, owner scripts, schedule
revoke all on function public.biometric_work_date_at(uuid, timestamptz, text), public.biometric_day_close_at(uuid, date),
  public.biometric_set_role(bigint, text, bigint, text, bigint, text, text, boolean),   -- returns boolean
  public.biometric_write_slot(uuid, date, text, text, bigint, text, text),
  public.biometric_project_day(uuid, date, int), public.attendance_external_guard() from public, anon, authenticated;
revoke all on procedure public.biometric_run_projection(int, int, int, int, int),
  public.biometric_project_one(uuid, date, uuid, int, int) from public, anon, authenticated;
revoke all on function public.biometric_hold_next_check(timestamptz), public.biometric_day_failures(uuid, date)
  from public, anon, authenticated;
revoke all on function public.biometric_project_now(uuid, date), public.day_events(uuid, date),
  public.biometric_day_pending(uuid, date), public.attendance_day_sources(date, date, uuid, uuid),
  public.biometric_shift_gap_warnings(int), public.biometric_retry_day(uuid, date) from public, anon;
grant execute on function public.biometric_project_now(uuid, date), public.day_events(uuid, date),
  public.biometric_day_pending(uuid, date), public.attendance_day_sources(date, date, uuid, uuid),
  public.biometric_shift_gap_warnings(int), public.biometric_retry_day(uuid, date) to authenticated;   -- each checks its own role/scope
-- NOT in 0012 (hosted, after approval of Q1):
--   select cron.schedule('attendos-biometric-projection', '* * * * *', 'call public.biometric_run_projection()');
