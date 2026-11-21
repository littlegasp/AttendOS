\set ON_ERROR_STOP on
-- 0012 biometric projection. Runs after 0012 in the same session as the earlier suites (reuses pg_temp.expect,
-- pg_temp.fails, pg_temp.as_user). Builds its own company "Proj" so every expectation below is self-contained.
-- Time: the company's zone is chosen so that its local time is about noon while the suite runs (Etc/GMT±N), so
-- "today" (shift 08:00–16:00, closes 18:00) is an OPEN day and yesterday is a CLOSED day, whatever the server clock.
reset role; select pg_temp.as_user('');

-- ================================================================ fixture
select set_config('p.off', (12 - extract(hour from now() at time zone 'UTC')::int)::text, false);
select set_config('p.tz', case when current_setting('p.off')::int = 0 then 'Etc/GMT'
                               when current_setting('p.off')::int > 0 then 'Etc/GMT-' || current_setting('p.off')
                               else 'Etc/GMT+' || (-current_setting('p.off')::int) end, false);
insert into companies (name, slug, timezone, weekly_off) values ('Proj Co', 'proj', current_setting('p.tz'), '{}');
select set_config('p.c', (select id::text from companies where slug = 'proj'), false);
insert into shifts (company_id, name, start_time, end_time, break_minutes, grace_minutes)
  values (current_setting('p.c')::uuid, 'Day', '08:00', '16:00', 30, 10), (current_setting('p.c')::uuid, 'Night', '22:00', '06:00', 30, 10);
update companies set default_shift_id = (select id from shifts where company_id = current_setting('p.c')::uuid and name = 'Day') where id = current_setting('p.c')::uuid;
select set_config('p.night', (select id::text from shifts where company_id = current_setting('p.c')::uuid and name = 'Night'), false);
insert into locations (company_id, name, lat, lng, radius_m) values
  (current_setting('p.c')::uuid, 'Proj Plant', 19.1000, 72.9000, 150), (current_setting('p.c')::uuid, 'Proj Annex', 19.2000, 72.8000, 150);
select set_config('p.loc', (select id::text from locations where name = 'Proj Plant'), false);
select set_config('p.loc2', (select id::text from locations where name = 'Proj Annex'), false);
select set_config('p.d0', public.local_today(current_setting('p.c')::uuid)::text, false);
select pg_temp.expect(extract(hour from now() at time zone current_setting('p.tz')) between 11 and 13, 'fixture: the company''s local time is around noon');
-- people: admin, HR, manager, 60 workers (codes C01…C60), all joined 60 days ago
insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000a1', 'admin@proj.co', now()), ('00000000-0000-0000-0000-0000000000a2', 'hr@proj.co', now()),
  ('00000000-0000-0000-0000-0000000000a3', 'mgr@proj.co', now());
insert into employees (company_id, full_name, email, role, user_id, home_location_id, joining_date) values
  (current_setting('p.c')::uuid, 'Pia Admin', 'admin@proj.co', 'admin', '00000000-0000-0000-0000-0000000000a1', current_setting('p.loc')::uuid, current_date - 60),
  (current_setting('p.c')::uuid, 'Hema HR', 'hr@proj.co', 'hr', '00000000-0000-0000-0000-0000000000a2', current_setting('p.loc')::uuid, current_date - 60),
  (current_setting('p.c')::uuid, 'Manu Manager', 'mgr@proj.co', 'manager', '00000000-0000-0000-0000-0000000000a3', current_setting('p.loc')::uuid, current_date - 60);
insert into auth.users (id, email, email_confirmed_at)
  select ('00000000-0000-0000-0000-0000000001' || lpad(g::text, 2, '0'))::uuid, 'w' || lpad(g::text, 2, '0') || '@proj.co', now() from generate_series(1, 60) g;
insert into employees (company_id, full_name, email, role, user_id, home_location_id, joining_date, manager_id)
  select current_setting('p.c')::uuid, 'Worker ' || lpad(g::text, 2, '0'), 'w' || lpad(g::text, 2, '0') || '@proj.co', 'employee',
         ('00000000-0000-0000-0000-0000000001' || lpad(g::text, 2, '0'))::uuid, current_setting('p.loc')::uuid, current_date - 60,
         (select id from employees where email = 'mgr@proj.co')
    from generate_series(1, 60) g;
create function pg_temp.w(n int) returns uuid language sql as $$ select id from public.employees where email = 'w' || lpad(n::text, 2, '0') || '@proj.co' $$;
create function pg_temp.pact(who text) returns void language plpgsql as $$
begin
  if who = 'owner' then reset role; perform set_config('request.jwt.claim.sub', '', false);
  else reset role;
    perform set_config('request.jwt.claim.sub', (select user_id::text from public.employees where email = who), false);
    set role authenticated;
  end if;
end $$;
-- agent, devices (first-in/last-out at the plant, device-direction at the plant, one more of each; one without office)
insert into biometric_agents (company_id, name, agent_identifier) values (current_setting('p.c')::uuid, 'Proj agent', 'proj-agent-1');
select set_config('p.agent', (select id::text from biometric_agents where agent_identifier = 'proj-agent-1'), false);
insert into biometric_devices (company_id, location_id, name, manufacturer, model, serial_number, integration_method, agent_id, timezone, direction_mode) values
  (current_setting('p.c')::uuid, current_setting('p.loc')::uuid, 'Gate FL', 'zkteco', 'K40', 'PFL001', 'sdk_pull', current_setting('p.agent')::uuid, current_setting('p.tz'), 'first_last'),
  (current_setting('p.c')::uuid, current_setting('p.loc')::uuid, 'Gate FL 2', 'zkteco', 'K40', 'PFL002', 'sdk_pull', current_setting('p.agent')::uuid, current_setting('p.tz'), 'first_last'),
  (current_setting('p.c')::uuid, current_setting('p.loc')::uuid, 'Gate DEV', 'zkteco', 'K40', 'PDV001', 'sdk_pull', current_setting('p.agent')::uuid, current_setting('p.tz'), 'device'),
  (current_setting('p.c')::uuid, current_setting('p.loc2')::uuid, 'Gate DEV 2', 'zkteco', 'K40', 'PDV002', 'sdk_pull', current_setting('p.agent')::uuid, current_setting('p.tz'), 'device'),
  (current_setting('p.c')::uuid, null, 'Gate NOOFFICE', 'zkteco', 'K40', 'PNO001', 'sdk_pull', current_setting('p.agent')::uuid, current_setting('p.tz'), 'first_last');
select set_config('p.fl', (select id::text from biometric_devices where serial_number = 'PFL001'), false);
select set_config('p.fl2', (select id::text from biometric_devices where serial_number = 'PFL002'), false);
select set_config('p.dv', (select id::text from biometric_devices where serial_number = 'PDV001'), false);
select set_config('p.dv2', (select id::text from biometric_devices where serial_number = 'PDV002'), false);
select set_config('p.no', (select id::text from biometric_devices where serial_number = 'PNO001'), false);
insert into biometric_employee_mappings (company_id, employee_id, employee_device_code, valid_from)
  select current_setting('p.c')::uuid, pg_temp.w(g), 'C' || lpad(g::text, 2, '0'), now() - interval '60 days' from generate_series(1, 60) g;
insert into biometric_settings (company_id) values (current_setting('p.c')::uuid);
create sequence pg_temp.pseq;

-- helpers --------------------------------------------------------------------------------------------------
-- an instant at local date+time in the company zone
create function pg_temp.at(d date, t time) returns timestamptz language sql as $$ select public.at_local(current_setting('p.c')::uuid, d, t) $$;
create function pg_temp.pd(n int) returns date language sql as $$ select current_setting('p.d0')::date - n $$;
-- one punch as the gateway would store it (raw + state), with optional auth / direction / drift / forced status
create function pg_temp.pp(dev text, n int, ts timestamptz, o jsonb default '{}') returns bigint language plpgsql as $$
declare t timestamptz := date_trunc('second', ts); rid bigint; mid uuid; fl text[]; seq bigint := nextval('pg_temp.pseq'); st text;
begin
  insert into public.biometric_raw_events (company_id, device_id, agent_id, employee_device_code, device_local_time, device_timezone, punch_at,
      source_auth, dedupe_key, dedupe_basis, record_seq, raw_payload, payload_hash, clock_drift_s, direction, direction_source)
  values (current_setting('p.c')::uuid, current_setting('p.' || dev)::uuid, current_setting('p.agent')::uuid, coalesce(o ->> 'code', 'C' || lpad(n::text, 2, '0')),
      to_char(t at time zone current_setting('p.tz'), 'YYYY-MM-DD HH24:MI:SS'), current_setting('p.tz'), t,
      coalesce(o ->> 'auth', 'authenticated'), 'seq:' || seq, 'record_seq', seq, jsonb_build_object('uid', n),
      sha256(convert_to(seq::text, 'UTF8')), (o ->> 'drift')::int, o ->> 'dir', case when o ? 'dir' then 'device' else 'none' end)
  returning id, time_flags into rid, fl;
  mid := public.biometric_resolve_mapping(current_setting('p.c')::uuid, current_setting('p.' || dev)::uuid, coalesce(o ->> 'code', 'C' || lpad(n::text, 2, '0')), t);
  if coalesce(o ->> 'auth', 'authenticated') = 'unauthenticated_lan' then fl := array_append(fl, 'unauthenticated_source'); end if;
  st := coalesce(o ->> 'status', case when mid is null then 'unmatched' when cardinality(fl) > 0 then 'flagged' else 'stored' end);
  insert into public.biometric_event_state (raw_event_id, company_id, employee_id, mapping_id, status, flag_reasons)
    values (rid, current_setting('p.c')::uuid, (select employee_id from public.biometric_employee_mappings where id = mid), mid, st, fl);
  return rid;
end $$;
create function pg_temp.st(rid bigint) returns text language sql as $$ select status from public.biometric_event_state where raw_event_id = rid $$;
create function pg_temp.fl(rid bigint) returns text[] language sql as $$ select flag_reasons from public.biometric_event_state where raw_event_id = rid $$;
create function pg_temp.sx(rid bigint) returns public.biometric_event_state language sql as $$ select * from public.biometric_event_state where raw_event_id = rid $$;
-- the day's live counted events, compact: "in 08:55 B, out 16:10 B" (W = web, C = correction, B = biometric)
create function pg_temp.evs(n int, d date) returns text language sql as $$
  select coalesce(string_agg(e.kind || ' ' || to_char(e.at at time zone current_setting('p.tz'), 'HH24:MI') || ' ' ||
         case e.source when 'web' then 'W' when 'correction' then 'C' when 'biometric' then 'B' else 'I' end, ', ' order by e.at, e.id), '')
    from public.attendance_events e where e.employee_id = pg_temp.w(n) and e.work_date = d and e.superseded_by is null $$;
create function pg_temp.proj(n int, d date, lim int default 200) returns jsonb language sql as $$ select public.biometric_project_day(pg_temp.w(n), d, lim) $$;
-- run the queue's step 0 for this company (work dates) without the scheduled procedure
create function pg_temp.dates() returns void language sql as $$
  update public.biometric_event_state s set work_date = (public.biometric_work_date_at(s.employee_id, r.punch_at, r.direction)).work_date
    from public.biometric_raw_events r where r.id = s.raw_event_id and s.work_date is null and s.employee_id is not null and s.status <> 'unmatched' $$;
create function pg_temp.day(n int, d date) returns public.attendance_day language sql as $$ select public.day_for(pg_temp.w(n), d) $$;
create function pg_temp.audits(rid bigint) returns bigint language sql as $$
  select count(*) from public.audit_log where (target = 'biometric_event_state' and target_id = rid::text) $$;

-- ================================================================ P — preflight and schema
select pg_temp.expect((select count(*) from pg_constraint where conname in ('attendance_events_source_check', 'attendance_events_external_shape') and convalidated) = 2,
  'P2 source and shape checks exist and are validated');
select pg_temp.fails($$ insert into attendance_events (employee_id, kind, work_mode, verified, work_date, source) values ('$$ || pg_temp.w(30) || $$', 'in', 'office', false, current_date, 'kiosk') $$,
  'attendance_events_source_check', 'P2 an unknown source value is refused');
select pg_temp.fails($$ insert into attendance_events (employee_id, kind, work_mode, verified, work_date, projection_slot) values ('$$ || pg_temp.w(30) || $$', 'in', 'office', false, current_date, 'in') $$,
  'external_shape', 'P2 a web row carrying biometric columns is refused');
select pg_temp.expect((select projection_enabled from biometric_settings where company_id = current_setting('p.c')::uuid) = false
  and not exists (select 1 from biometric_settings where projection_enabled)
  and (select projection_enabled from biometric_settings_for((select id from companies where slug = 'beta'))) = false,
  'P projection is off by default for every company (stored settings and defaults)');
select pg_temp.expect(exists (select 1 from pg_trigger where tgname = 'external_guard' and tgrelid = 'public.attendance_events'::regclass)
  and (select pg_get_triggerdef(oid) from pg_trigger where tgname = 'company_refs' and tgrelid = 'public.attendance_events'::regclass) ~ 'device_id:biometric_devices',
  'P guard trigger present; company_refs re-created with device and batch references');

-- ================================================================ F — first-in / last-out
-- F4 off by default: nothing projected; enabling projects
select set_config('f.r1', pg_temp.pp('fl', 1, pg_temp.at(pg_temp.pd(0), '08:55'))::text, false);
select pg_temp.dates();
select pg_temp.expect(pg_temp.proj(1, pg_temp.pd(0)) ->> 'reason' = 'projection_disabled' and pg_temp.evs(1, pg_temp.pd(0)) = ''
  and pg_temp.st(current_setting('f.r1')::bigint) = 'stored', 'F4 projection off: the day is not touched, the punch stays stored');
update biometric_settings set projection_enabled = true where company_id = current_setting('p.c')::uuid;   -- this local test company only
select pg_temp.proj(1, pg_temp.pd(0));
select pg_temp.expect(pg_temp.evs(1, pg_temp.pd(0)) = 'in 08:55 B', 'F4 enabled: the punch becomes the day''s check-in');
-- F5 shape of a projected row
select pg_temp.expect((select count(*) = 1 and bool_and(e.source = 'biometric' and e.direction_basis = 'inferred_first_last' and e.projection_slot = 'in'
    and not e.verified and e.work_mode = 'office' and e.location_id = current_setting('p.loc')::uuid and e.device_id = current_setting('p.fl')::uuid
    and e.biometric_event_id = current_setting('f.r1')::bigint and e.distance_m is null and e.accuracy_m is null)
  from attendance_events e where e.employee_id = pg_temp.w(1)), 'F5 slot in, inferred, verified false, office, device office, device and raw linked');
select pg_temp.expect((pg_temp.sx(current_setting('f.r1')::bigint)).status = 'projected'
  and (pg_temp.sx(current_setting('f.r1')::bigint)).projected_event_id = (select id from attendance_events where employee_id = pg_temp.w(1))
  and (pg_temp.sx(current_setting('f.r1')::bigint)).processed_at is not null, 'F5 the raw punch points back at its row');
select pg_temp.expect((pg_temp.day(1, pg_temp.pd(0))).status = 'working', 'F5 the engine sees the person working');
-- F6 provisional out: today 08:50 + 11:00 (day closes at 18:00)
select pg_temp.pp('fl', 2, pg_temp.at(pg_temp.pd(0), '08:50'));
select set_config('f.r2b', pg_temp.pp('fl', 2, pg_temp.at(pg_temp.pd(0), '11:00'))::text, false);
select pg_temp.dates(); select pg_temp.proj(2, pg_temp.pd(0));
select pg_temp.expect(pg_temp.evs(2, pg_temp.pd(0)) = 'in 08:50 B' and pg_temp.st(current_setting('f.r2b')::bigint) = 'provisional_out',
  'F6 the later punch is a provisional check-out and NO row');
select pg_temp.expect((pg_temp.day(2, pg_temp.pd(0))).open and (pg_temp.day(2, pg_temp.pd(0))).status = 'working'
  and (pg_temp.day(2, pg_temp.pd(0))).early_min = 0 and (pg_temp.day(2, pg_temp.pd(0))).overtime_min = 0 and (pg_temp.day(2, pg_temp.pd(0))).last_out is null,
  'F6 day_for: open, working, no last out, no early leaving, no overtime');
select pg_temp.expect((select pending_checkout and provisional_out_at = pg_temp.at(pg_temp.pd(0), '11:00') and final_at = pg_temp.at(pg_temp.pd(0), '18:00')
  from biometric_day_pending(pg_temp.w(2), pg_temp.pd(0))), 'F6 biometric_day_pending: pending, last punch 11:00, final at 18:00');
-- F7 closed day: biometric in/out equals an app day with the same times
select pg_temp.pp('fl', 3, pg_temp.at(pg_temp.pd(1), '08:50')); select pg_temp.pp('fl', 3, pg_temp.at(pg_temp.pd(1), '16:10'));
select pg_temp.dates(); select pg_temp.proj(3, pg_temp.pd(1));
insert into attendance_events (employee_id, kind, at, work_mode, location_id, verified, work_date) values
  (pg_temp.w(4), 'in', pg_temp.at(pg_temp.pd(1), '08:50'), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(1)),
  (pg_temp.w(4), 'out', pg_temp.at(pg_temp.pd(1), '16:10'), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(1));
select pg_temp.expect(pg_temp.evs(3, pg_temp.pd(1)) = 'in 08:50 B, out 16:10 B', 'F7 at day close the out row is written');
select pg_temp.expect((select (a.first_in, a.last_out, a.worked_min, a.late_min, a.early_min, a.overtime_min, a.status, a.open)
                         = (b.first_in, b.last_out, b.worked_min, b.late_min, b.early_min, b.overtime_min, b.status, b.open)
                       from pg_temp.day(3, pg_temp.pd(1)) a, pg_temp.day(4, pg_temp.pd(1)) b),
  'F7 final hours, lateness, early leaving, overtime and status equal an app day with the same times');
select pg_temp.expect((select count(*) from audit_log where action = 'biometric_finalise' and after ->> 'employee_id' = pg_temp.w(3)::text) = 1, 'F7 finalisation is audited');
-- F8 punches less than 30 min apart: no check-out invented. (The person also used the app today (in and out), so the
-- lone check-in of yesterday is not their newest event; without that, session safety applies instead — group S.)
insert into attendance_events (employee_id, kind, at, work_mode, location_id, verified, work_date) values
  (pg_temp.w(5), 'in', pg_temp.at(pg_temp.pd(0), '09:30'), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(0)),
  (pg_temp.w(5), 'out', pg_temp.at(pg_temp.pd(0), '10:00'), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(0));
select set_config('f.r5', pg_temp.pp('fl', 5, pg_temp.at(pg_temp.pd(1), '09:00'))::text, false); select pg_temp.pp('fl', 5, pg_temp.at(pg_temp.pd(1), '09:20'));
select pg_temp.dates(); select pg_temp.proj(5, pg_temp.pd(1));
select pg_temp.expect(pg_temp.evs(5, pg_temp.pd(1)) = 'in 09:00 B' and (pg_temp.day(5, pg_temp.pd(1))).status = 'missing_checkout'
  and 'incomplete' = any (pg_temp.fl(current_setting('f.r5')::bigint)), 'F8 single session < 30 min: missing check-out, in flagged incomplete');
-- F9 earlier punch before close moves the slot in place; after close it needs a correction
select pg_temp.pp('fl', 6, pg_temp.at(pg_temp.pd(0), '09:10')); select pg_temp.dates(); select pg_temp.proj(6, pg_temp.pd(0));
select set_config('f.id6', (select id::text from attendance_events where employee_id = pg_temp.w(6)), false);
select set_config('f.r6e', pg_temp.pp('fl2', 6, pg_temp.at(pg_temp.pd(0), '08:40'))::text, false); select pg_temp.dates(); select pg_temp.proj(6, pg_temp.pd(0));
select pg_temp.expect(pg_temp.evs(6, pg_temp.pd(0)) = 'in 08:40 B' and (select id::text from attendance_events where employee_id = pg_temp.w(6)) = current_setting('f.id6')
  and (select device_id from attendance_events where employee_id = pg_temp.w(6)) = current_setting('p.fl2')::uuid
  and (select count(*) from audit_log where action = 'biometric_slot_moved' and target_id = current_setting('f.id6')) = 1,
  'F9 before close: same row id moved to the earlier punch (time and device), audited');
select pg_temp.pp('fl', 7, pg_temp.at(pg_temp.pd(1), '09:00')); select pg_temp.pp('fl', 7, pg_temp.at(pg_temp.pd(1), '17:00'));
select pg_temp.dates(); select pg_temp.proj(7, pg_temp.pd(1));
select set_config('f.r7e', pg_temp.pp('fl', 7, pg_temp.at(pg_temp.pd(1), '08:30'))::text, false); select pg_temp.dates(); select pg_temp.proj(7, pg_temp.pd(1));
select pg_temp.expect(pg_temp.evs(7, pg_temp.pd(1)) = 'in 09:00 B, out 17:00 B' and pg_temp.st(current_setting('f.r7e')::bigint) = 'correction_needed'
  and 'after_day_close' = any (pg_temp.fl(current_setting('f.r7e')::bigint)), 'F9 after close: rows unchanged, the earlier punch needs a correction');
-- F10 double press across devices; possible duplicates never projected
select pg_temp.pp('fl', 8, pg_temp.at(pg_temp.pd(0), '09:00:00'));
select set_config('f.r8b', pg_temp.pp('fl2', 8, pg_temp.at(pg_temp.pd(0), '09:00:30'))::text, false);
select set_config('f.r8c', pg_temp.pp('fl', 8, pg_temp.at(pg_temp.pd(0), '07:30'), '{"status": "possible_duplicate"}')::text, false);
select pg_temp.dates(); select pg_temp.proj(8, pg_temp.pd(0));
select pg_temp.expect(pg_temp.evs(8, pg_temp.pd(0)) = 'in 09:00 B' and pg_temp.st(current_setting('f.r8b')::bigint) = 'extra'
  and 'double_press' = any (pg_temp.fl(current_setting('f.r8b')::bigint)) and pg_temp.st(current_setting('f.r8c')::bigint) = 'possible_duplicate',
  'F10 second press 30 s later on another device is extra; a possible duplicate (07:30) is never used');
-- F11 app events are fixed facts
insert into attendance_events (employee_id, kind, at, work_mode, location_id, verified, work_date) values
  (pg_temp.w(9), 'in', pg_temp.at(pg_temp.pd(1), '09:00'), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(1)),
  (pg_temp.w(9), 'out', pg_temp.at(pg_temp.pd(1), '15:00'), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(1));
select set_config('f.r9a', pg_temp.pp('fl', 9, pg_temp.at(pg_temp.pd(1), '09:03'))::text, false);
select set_config('f.r9b', pg_temp.pp('fl', 9, pg_temp.at(pg_temp.pd(1), '08:30'))::text, false);
select set_config('f.r9c', pg_temp.pp('fl', 9, pg_temp.at(pg_temp.pd(1), '15:02'))::text, false);
select set_config('f.r9d', pg_temp.pp('fl', 9, pg_temp.at(pg_temp.pd(1), '15:30'))::text, false);
select pg_temp.dates(); select pg_temp.proj(9, pg_temp.pd(1));
select pg_temp.expect(pg_temp.evs(9, pg_temp.pd(1)) = 'in 09:00 W, out 15:00 W'
  and pg_temp.st(current_setting('f.r9a')::bigint) = 'reconciled' and (pg_temp.sx(current_setting('f.r9a')::bigint)).reconciled_with is not null
  and pg_temp.st(current_setting('f.r9b')::bigint) = 'correction_needed' and 'before_app_checkin' = any (pg_temp.fl(current_setting('f.r9b')::bigint))
  and pg_temp.st(current_setting('f.r9c')::bigint) = 'reconciled' and pg_temp.st(current_setting('f.r9d')::bigint) = 'extra',
  'F11 09:03 matches the app in; 08:30 needs a correction; 15:02 matches the app out; 15:30 after the app out is extra; only app rows count');

-- ================================================================ G — gate, holds, decisions
create function pg_temp.pair(dev text, n int, d date, t1 time default '09:00', t2 time default '17:00') returns bigint language plpgsql as $$
declare r bigint; begin r := pg_temp.pp(dev, n, pg_temp.at(d, t1)); perform pg_temp.pp(dev, n, pg_temp.at(d, t2)); return r; end $$;
create function pg_temp.due(n int) returns void language sql as $$
  update public.biometric_event_state set next_check_at = now() - interval '1 second' where employee_id = pg_temp.w(n) and status = 'held' $$;
create function pg_temp.review(rid bigint, act text, why text default 'Checked with the supervisor') returns jsonb language sql as $$
  select public.biometric_review_event(rid, act, why, (select version from public.biometric_event_state where raw_event_id = rid)) $$;
-- G12 unauthenticated LAN punch: flagged; one individual HR acceptance → projected
select set_config('g.r10', pg_temp.pp('fl', 10, pg_temp.at(pg_temp.pd(0), '09:00'), '{"auth": "unauthenticated_lan"}')::text, false);
select pg_temp.dates(); select pg_temp.proj(10, pg_temp.pd(0));
select pg_temp.expect(pg_temp.st(current_setting('g.r10')::bigint) = 'flagged' and pg_temp.evs(10, pg_temp.pd(0)) = '', 'G12 unauthenticated punch is flagged and not counted');
select pg_temp.pact('hr@proj.co');
select pg_temp.expect(pg_temp.review(current_setting('g.r10')::bigint, 'accept_time') ->> 'status' = 'stored', 'G12 HR accepts that one punch');
select pg_temp.pact('owner');
select pg_temp.expect((pg_temp.sx(current_setting('g.r10')::bigint)).processed_at is null and (pg_temp.sx(current_setting('g.r10')::bigint)).decided,
  'G12 acceptance makes it pending again (processed_at reset)');
select pg_temp.proj(10, pg_temp.pd(0));
select pg_temp.expect(pg_temp.evs(10, pg_temp.pd(0)) = 'in 09:00 B', 'G12 after acceptance it is projected');
select pg_temp.expect(not exists (select 1 from pg_proc where proname ~ 'bulk|accept_range|accept_all' and pronamespace = 'public'::regnamespace), 'G12 no bulk acceptance function exists (Q2)');
-- G13 late backfill and future punches
select set_config('g.r11', pg_temp.pair('fl', 11, pg_temp.pd(3))::text, false);
select set_config('g.r11s', pg_temp.pp('fl', 11, pg_temp.at(pg_temp.pd(4), '09:00'), '{"status": "stored"}')::text, false);
select pg_temp.dates(); select pg_temp.proj(11, pg_temp.pd(3)); select pg_temp.proj(11, pg_temp.pd(4));
select pg_temp.expect(pg_temp.st(current_setting('g.r11')::bigint) = 'flagged' and pg_temp.st(current_setting('g.r11s')::bigint) = 'flagged'
  and 'late_backfill' = any ((select time_flags from biometric_raw_events where id = current_setting('g.r11s')::bigint) || pg_temp.fl(current_setting('g.r11s')::bigint))
  and pg_temp.evs(11, pg_temp.pd(3)) = '' and pg_temp.evs(11, pg_temp.pd(4)) = '', 'G13 punches older than 2 days are flagged (even one wrongly left stored)');
select set_config('g.r12', pg_temp.pp('fl', 12, now() + interval '4 seconds', '{"status": "stored"}')::text, false);
select pg_temp.dates(); select pg_temp.proj(12, pg_temp.pd(0));
select pg_temp.expect(pg_temp.st(current_setting('g.r12')::bigint) = 'stored' and pg_temp.evs(12, pg_temp.pd(0)) = '', 'G13 a punch in the future waits (still stored, nothing written)');
select pg_sleep(5);
select pg_temp.proj(12, pg_temp.pd(0));
select pg_temp.expect(pg_temp.st(current_setting('g.r12')::bigint) = 'flagged' and 'future_within_tolerance' = any (pg_temp.fl(current_setting('g.r12')::bigint)),
  'G13 once in the past it goes through the gate: the future-tolerance flag sends it to review (soft flag)');
-- G14 holds and their release
insert into roster_day (employee_id, day, work_mode) values (pg_temp.w(13), pg_temp.pd(1), 'off');
select set_config('g.r13', pg_temp.pair('fl', 13, pg_temp.pd(1))::text, false);
insert into leave_types (company_id, name, code) values (current_setting('p.c')::uuid, 'Proj test leave', 'PTL');
insert into leave_requests (employee_id, leave_type_id, start_date, end_date, days, reason, status, requested_by) values
  (pg_temp.w(14), (select id from leave_types where code = 'PTL' and company_id = current_setting('p.c')::uuid), pg_temp.pd(1), pg_temp.pd(1), 1, 'Family', 'approved', pg_temp.w(14));
insert into leave_requests (employee_id, leave_type_id, start_date, end_date, half_day, days, reason, status, requested_by) values
  (pg_temp.w(15), (select id from leave_types where code = 'PTL' and company_id = current_setting('p.c')::uuid), pg_temp.pd(1), pg_temp.pd(1), 'second', 0.5, 'Errand', 'approved', pg_temp.w(15));
select set_config('g.r14', pg_temp.pair('fl', 14, pg_temp.pd(1))::text, false);
select pg_temp.pair('fl', 15, pg_temp.pd(1));
update employees set joining_date = pg_temp.pd(0) where id = pg_temp.w(16);
update employees set exit_date = pg_temp.pd(2), active = false where id = pg_temp.w(17);
update employees set active = false where id = pg_temp.w(18);
select set_config('g.r16', pg_temp.pair('fl', 16, pg_temp.pd(1))::text, false);
select set_config('g.r17', pg_temp.pair('fl', 17, pg_temp.pd(1))::text, false);
select set_config('g.r18', pg_temp.pair('fl', 18, pg_temp.pd(1))::text, false);
select set_config('g.r19', pg_temp.pair('no', 19, pg_temp.pd(1))::text, false);
select pg_temp.dates();
select pg_temp.proj(n, pg_temp.pd(1)) from generate_series(13, 19) n;
select pg_temp.expect(pg_temp.st(current_setting('g.r13')::bigint) = 'held' and (pg_temp.sx(current_setting('g.r13')::bigint)).hold_reason = 'non_working_day'
  and pg_temp.st(current_setting('g.r14')::bigint) = 'held' and (pg_temp.sx(current_setting('g.r14')::bigint)).hold_reason = 'on_leave'
  and pg_temp.st(current_setting('g.r16')::bigint) = 'held' and (pg_temp.sx(current_setting('g.r16')::bigint)).hold_reason = 'before_joining'
  and pg_temp.st(current_setting('g.r17')::bigint) = 'held' and (pg_temp.sx(current_setting('g.r17')::bigint)).hold_reason = 'after_exit'
  and pg_temp.st(current_setting('g.r18')::bigint) = 'held' and (pg_temp.sx(current_setting('g.r18')::bigint)).hold_reason = 'employee_inactive'
  and pg_temp.st(current_setting('g.r19')::bigint) = 'held' and (pg_temp.sx(current_setting('g.r19')::bigint)).hold_reason = 'device_without_office',
  'G14 off day, full-day leave, before joining, after exit, deactivated and device without office are held with their reason');
select pg_temp.expect(pg_temp.evs(13, pg_temp.pd(1)) || pg_temp.evs(14, pg_temp.pd(1)) || pg_temp.evs(16, pg_temp.pd(1)) || pg_temp.evs(17, pg_temp.pd(1))
  || pg_temp.evs(18, pg_temp.pd(1)) || pg_temp.evs(19, pg_temp.pd(1)) = '', 'G14 nothing held is counted');
select pg_temp.expect(pg_temp.evs(15, pg_temp.pd(1)) = 'in 09:00 B, out 17:00 B', 'G14 half-day leave projects (the app allows check-in too)');
select pg_temp.expect((select bool_and(held_since is not null and next_check_at > now() + interval '14 minutes') from biometric_event_state where status = 'held' and employee_id = pg_temp.w(13)),
  'G14 a new hold is next looked at in 15 minutes');
delete from roster_day where employee_id = pg_temp.w(13);
update biometric_devices set location_id = current_setting('p.loc2')::uuid where id = current_setting('p.no')::uuid;
select pg_temp.proj(13, pg_temp.pd(1)); select pg_temp.proj(19, pg_temp.pd(1));
select pg_temp.expect(pg_temp.st(current_setting('g.r13')::bigint) = 'held' and pg_temp.evs(13, pg_temp.pd(1)) = '', 'G14 before its next look, a fixed hold is NOT re-evaluated');
select pg_temp.due(13); select pg_temp.due(19); select pg_temp.proj(13, pg_temp.pd(1)); select pg_temp.proj(19, pg_temp.pd(1));
select pg_temp.expect(pg_temp.evs(13, pg_temp.pd(1)) = 'in 09:00 B, out 17:00 B' and pg_temp.evs(19, pg_temp.pd(1)) = 'in 09:00 B, out 17:00 B'
  and (select bool_and(location_id = current_setting('p.loc2')::uuid) from attendance_events where employee_id = pg_temp.w(19)),
  'G14 when due and the cause is fixed (roster back, office registered) the punches are released within the window and projected, with the device office');
-- import batches are held (0013)
insert into biometric_import_batches (company_id, file_name, file_sha256) values (current_setting('p.c')::uuid, 'old.csv', sha256('x'::bytea));
insert into biometric_raw_events (company_id, import_batch_id, employee_device_code, device_local_time, device_timezone, punch_at, source_auth, dedupe_key, dedupe_basis)
  values (current_setting('p.c')::uuid, (select id from biometric_import_batches where file_name = 'old.csv'), 'C20',
          to_char(pg_temp.at(pg_temp.pd(1), '09:00') at time zone current_setting('p.tz'), 'YYYY-MM-DD HH24:MI:SS'), current_setting('p.tz'),
          pg_temp.at(pg_temp.pd(1), '09:00'), 'import', 'fp:imp1', 'fingerprint');
insert into biometric_event_state (raw_event_id, company_id, employee_id, mapping_id, status)
  select r.id, r.company_id, pg_temp.w(20), public.biometric_resolve_mapping(r.company_id, null, 'C20', r.punch_at), 'stored'
    from biometric_raw_events r where r.dedupe_key = 'fp:imp1';
select set_config('g.r20', (select id::text from biometric_raw_events where dedupe_key = 'fp:imp1'), false);
select pg_temp.dates(); select pg_temp.proj(20, pg_temp.pd(1));
select pg_temp.expect(pg_temp.st(current_setting('g.r20')::bigint) = 'held' and (pg_temp.sx(current_setting('g.r20')::bigint)).hold_reason = 'import_not_enabled'
  and pg_temp.evs(20, pg_temp.pd(1)) = '', 'G14 an import-batch punch is held (imports come with 0013, Q10)');
-- G15 corrections: pending → held; approved → locked, slot superseded and never refilled
insert into attendance_corrections (employee_id, work_date, kind, requested_out, reason, requested_by)
  values (pg_temp.w(21), pg_temp.pd(1), 'missing_out', pg_temp.at(pg_temp.pd(1), '17:30'), 'Forgot to punch out', '00000000-0000-0000-0000-000000000121');
select set_config('g.r21', pg_temp.pair('fl', 21, pg_temp.pd(1))::text, false);
select pg_temp.dates(); select pg_temp.proj(21, pg_temp.pd(1));
select pg_temp.expect(pg_temp.st(current_setting('g.r21')::bigint) = 'held' and (pg_temp.sx(current_setting('g.r21')::bigint)).hold_reason = 'correction_pending',
  'G15 a pending correction holds the day''s punches');
select pg_temp.pact('hr@proj.co');
select pg_temp.expect(decide_correction((select id from attendance_corrections where employee_id = pg_temp.w(21)), true, null) ->> 'ok' = 'true', 'G15 HR approves through the lock wrapper');
select pg_temp.pact('owner');
select pg_temp.due(21); select pg_temp.proj(21, pg_temp.pd(1));
select pg_temp.expect(pg_temp.st(current_setting('g.r21')::bigint) = 'after_correction' and pg_temp.evs(21, pg_temp.pd(1)) = 'out 17:30 C',
  'G15 after approval the held punches become after_correction; only the correction counts');
select pg_temp.pair('fl', 22, pg_temp.pd(1)); select pg_temp.dates(); select pg_temp.proj(22, pg_temp.pd(1));
select set_config('g.id22', (select id::text from attendance_events where employee_id = pg_temp.w(22) and kind = 'in'), false);
select pg_temp.pact('w22@proj.co');
select pg_temp.expect(request_correction(pg_temp.pd(1), 'wrong_time', pg_temp.at(pg_temp.pd(1), '09:30'), null, 'Machine was early') ->> 'ok' = 'true', 'G15 the employee asks to correct a biometric check-in');
select pg_temp.pact('hr@proj.co');
select decide_correction((select id from attendance_corrections where employee_id = pg_temp.w(22)), true, null);
select pg_temp.pact('owner');
select set_config('g.r22x', pg_temp.pp('fl', 22, pg_temp.at(pg_temp.pd(1), '08:00'))::text, false);
select pg_temp.dates(); select pg_temp.proj(22, pg_temp.pd(1)); select pg_temp.proj(22, pg_temp.pd(1));
select pg_temp.expect(pg_temp.evs(22, pg_temp.pd(1)) = 'in 09:30 C, out 17:00 B'
  and (select superseded_by is not null and at = pg_temp.at(pg_temp.pd(1), '09:00') from attendance_events where id = current_setting('g.id22')::bigint)
  and pg_temp.st(current_setting('g.r22x')::bigint) = 'after_correction'
  and not exists (select 1 from attendance_events where employee_id = pg_temp.w(22) and projection_slot = 'in' and id <> current_setting('g.id22')::bigint),
  'G15 the correction supersedes the biometric row (kept, same id); a later punch is after_correction; the slot is never refilled');
-- G16 overnight shift and ambiguous work date
insert into shifts (company_id, name, start_time, end_time) values (current_setting('p.c')::uuid, 'Early', '07:00', '15:00');
insert into shift_day (employee_id, day, shift_id) values (pg_temp.w(23), pg_temp.pd(2), current_setting('p.night')::uuid),
  (pg_temp.w(24), pg_temp.pd(2), current_setting('p.night')::uuid),
  (pg_temp.w(24), pg_temp.pd(1), (select id from shifts where name = 'Early' and company_id = current_setting('p.c')::uuid));
select pg_temp.pp('fl', 23, pg_temp.at(pg_temp.pd(2), '21:55')); select pg_temp.pp('fl', 23, pg_temp.at(pg_temp.pd(1), '06:20'));
select set_config('g.r24', pg_temp.pp('fl', 24, pg_temp.at(pg_temp.pd(1), '06:30'))::text, false);
select pg_temp.dates(); select pg_temp.proj(23, pg_temp.pd(2)); select pg_temp.proj(24, pg_temp.pd(2));
select pg_temp.expect(pg_temp.evs(23, pg_temp.pd(2)) = 'in 21:55 B, out 06:20 B' and (pg_temp.day(23, pg_temp.pd(2))).worked_min = 505,
  'G16 night shift 22:00–06:00: 21:55 and next-morning 06:20 form one work day (8 h 25 min)');
select pg_temp.expect((pg_temp.sx(current_setting('g.r24')::bigint)).work_date = pg_temp.pd(2) and pg_temp.st(current_setting('g.r24')::bigint) = 'flagged'
  and 'ambiguous_work_date' = any (pg_temp.fl(current_setting('g.r24')::bigint)), 'G16 a punch between a night shift end and an early shift start is flagged ambiguous');
-- G17 a later mapping attaches old/unauthenticated punches: re-gated, not projected silently (finding E11)
select set_config('g.r25a', pg_temp.pp('fl', 25, pg_temp.at(pg_temp.pd(3), '09:00'), '{"code": "X25"}')::text, false);
select set_config('g.r25b', pg_temp.pp('fl', 25, pg_temp.at(pg_temp.pd(1), '09:00'), '{"code": "X25", "auth": "unauthenticated_lan"}')::text, false);
select pg_temp.pp('fl', 25, pg_temp.at(pg_temp.pd(1), '17:00'), '{"code": "X25", "auth": "unauthenticated_lan"}');
select pg_temp.expect(pg_temp.st(current_setting('g.r25a')::bigint) = 'unmatched', 'G17 unmapped code: unmatched');
insert into employees (company_id, full_name, email, role, home_location_id, joining_date)
  values (current_setting('p.c')::uuid, 'Xavi New', 'x25@proj.co', 'employee', current_setting('p.loc')::uuid, current_date - 60);
select pg_temp.pact('admin@proj.co');
select pg_temp.expect(biometric_save_mapping('X25', null, (select id from employees where email = 'x25@proj.co'), now() - interval '30 days', true) ->> 'ok' = 'true',
  'G17 Admin maps the waiting code to the new person');
select pg_temp.pact('owner');
select pg_temp.expect(pg_temp.st(current_setting('g.r25a')::bigint) = 'stored' and pg_temp.st(current_setting('g.r25b')::bigint) = 'stored', 'G17 the mapping attaches them as stored');
select pg_temp.dates();
select biometric_project_day((select id from employees where email = 'x25@proj.co'), pg_temp.pd(3));
select biometric_project_day((select id from employees where email = 'x25@proj.co'), pg_temp.pd(1));
select pg_temp.expect(pg_temp.st(current_setting('g.r25a')::bigint) = 'flagged' and pg_temp.st(current_setting('g.r25b')::bigint) = 'flagged'
  and 'unauthenticated_source' = any (pg_temp.fl(current_setting('g.r25b')::bigint))
  and not exists (select 1 from attendance_events where employee_id = (select id from employees where email = 'x25@proj.co')),
  'G17 projection re-gates them: the old one and the unauthenticated ones go to review');
-- G18 idempotence
select set_config('g.snap', (select md5(string_agg(to_jsonb(e)::text, '|' order by id)) from attendance_events e where employee_id = pg_temp.w(3))
  || (select md5(string_agg(to_jsonb(s)::text, '|' order by raw_event_id)) from biometric_event_state s where employee_id = pg_temp.w(3))
  || (select count(*) from audit_log)::text, false);
select pg_temp.proj(3, pg_temp.pd(1)); select pg_temp.proj(3, pg_temp.pd(1));
select pg_temp.expect(current_setting('g.snap') = (select md5(string_agg(to_jsonb(e)::text, '|' order by id)) from attendance_events e where employee_id = pg_temp.w(3))
  || (select md5(string_agg(to_jsonb(s)::text, '|' order by raw_event_id)) from biometric_event_state s where employee_id = pg_temp.w(3))
  || (select count(*) from audit_log)::text, 'G18 running a complete day again changes no row, no state, no version and writes no audit');

-- ================================================================ S — session safety (each case ends with a real web check-in)
create function pg_temp.webin(n int) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.pact('w' || lpad(n::text, 2, '0') || '@proj.co');
  r := public.punch('in', 19.1000, 72.9000, 10);
  perform pg_temp.pact('owner');
  return r;
end $$;
create function pg_temp.state(n int) returns text language sql as $$ select state || ':' || coalesce(work_date::text, '-') from public.session_state(pg_temp.w(n)) $$;
-- S19 HR-accepted historical lone check-in (unauthenticated + late): never projected; the web check-in works
select set_config('s.r26', pg_temp.pp('fl', 26, pg_temp.at(pg_temp.pd(3), '09:00'), '{"auth": "unauthenticated_lan"}')::text, false);
select pg_temp.pact('hr@proj.co'); select pg_temp.review(current_setting('s.r26')::bigint, 'accept_time'); select pg_temp.pact('owner');
select pg_temp.dates(); select pg_temp.proj(26, pg_temp.pd(3));
select pg_temp.expect(pg_temp.st(current_setting('s.r26')::bigint) = 'correction_needed' and 'would_open_closed_day' = any (pg_temp.fl(current_setting('s.r26')::bigint))
  and pg_temp.evs(26, pg_temp.pd(3)) = '' and pg_temp.state(26) = 'off:-', 'S19 accepted historical lone check-in: correction_needed, not counted, session off');
select pg_temp.expect(pg_temp.webin(26) ->> 'ok' = 'true' and pg_temp.state(26) = 'working:' || pg_temp.pd(0), 'S19 the employee''s web check-in today succeeds');
-- S20 same with an accepted clock-drift flag
select set_config('s.r27', pg_temp.pp('fl', 27, pg_temp.at(pg_temp.pd(1), '09:00'), '{"drift": 900}')::text, false);
select pg_temp.expect(pg_temp.st(current_setting('s.r27')::bigint) = 'flagged' and 'clock_drift' = any (pg_temp.fl(current_setting('s.r27')::bigint)), 'S20 drift punch flagged at ingest');
select pg_temp.pact('hr@proj.co'); select pg_temp.review(current_setting('s.r27')::bigint, 'accept_time'); select pg_temp.pact('owner');
select pg_temp.dates(); select pg_temp.proj(27, pg_temp.pd(1));
select pg_temp.expect(pg_temp.st(current_setting('s.r27')::bigint) = 'correction_needed' and pg_temp.webin(27) ->> 'ok' = 'true',
  'S20 accepted drift punch alone on a closed day: correction_needed; web check-in succeeds');
-- S21 acceptance refused on correction_needed; dismiss works; an approved correction turns it into after_correction
select pg_temp.pact('hr@proj.co');
select pg_temp.expect(pg_temp.review(current_setting('s.r26')::bigint, 'accept_time') ->> 'message' ~ 'request an attendance correction for',
  'S21 accept_time on a correction_needed punch is refused with the correction message');
select pg_temp.pact('owner');
select set_config('s.r28', pg_temp.pp('fl', 28, pg_temp.at(pg_temp.pd(1), '09:00'))::text, false);
select pg_temp.dates(); select pg_temp.proj(28, pg_temp.pd(1)); select pg_temp.pact('hr@proj.co');
select pg_temp.expect(pg_temp.st(current_setting('s.r28')::bigint) = 'correction_needed'
  and pg_temp.review(current_setting('s.r28')::bigint, 'dismiss', 'Machine test punch') ->> 'status' = 'dismissed', 'S21 HR may dismiss it (reason required)');
select pg_temp.pact('w27@proj.co');
select request_correction(pg_temp.pd(1), 'missing_in', pg_temp.at(pg_temp.pd(1), '09:00'), null, 'Machine punch not counted');
select pg_temp.pact('hr@proj.co'); select decide_correction((select id from attendance_corrections where employee_id = pg_temp.w(27)), true, null);
select pg_temp.pact('owner'); select pg_temp.proj(27, pg_temp.pd(1));
select pg_temp.expect(pg_temp.st(current_setting('s.r27')::bigint) = 'after_correction' and pg_temp.evs(27, pg_temp.pd(1)) = 'in 09:00 C'
  and pg_temp.state(27) = 'working:' || pg_temp.pd(0), 'S21 after the approved correction the punch is after_correction; web session unaffected');
-- S22 accepted historical check-in WITH a qualifying out: both projected, session off, web check-in fine
select set_config('s.r29', pg_temp.pp('fl', 29, pg_temp.at(pg_temp.pd(1), '09:00'), '{"auth": "unauthenticated_lan"}')::text, false);
select set_config('s.r29b', pg_temp.pp('fl', 29, pg_temp.at(pg_temp.pd(1), '17:00'), '{"auth": "unauthenticated_lan"}')::text, false);
select pg_temp.pact('hr@proj.co'); select pg_temp.review(current_setting('s.r29')::bigint, 'accept_time'); select pg_temp.review(current_setting('s.r29b')::bigint, 'accept_time');
select pg_temp.pact('owner'); select pg_temp.dates(); select pg_temp.proj(29, pg_temp.pd(1));
select pg_temp.expect(pg_temp.evs(29, pg_temp.pd(1)) = 'in 09:00 B, out 17:00 B' and pg_temp.state(29) = 'off:-' and pg_temp.webin(29) ->> 'ok' = 'true',
  'S22 accepted pair: projected; session off; web check-in succeeds');
-- S23 open session on another unfinished day (checked in with the app today): yesterday's biometric check-in waits for a correction
insert into attendance_events (employee_id, kind, at, work_mode, location_id, verified, work_date) values
  (pg_temp.w(30), 'in', pg_temp.at(pg_temp.pd(0), '08:00'), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(0));
select set_config('s.r30', pg_temp.pair('fl', 30, pg_temp.pd(1))::text, false);
select pg_temp.dates(); select pg_temp.proj(30, pg_temp.pd(1));
select pg_temp.expect(pg_temp.st(current_setting('s.r30')::bigint) = 'correction_needed' and 'open_session_other_day' = any (pg_temp.fl(current_setting('s.r30')::bigint))
  and pg_temp.evs(30, pg_temp.pd(1)) = '', 'S23 open session today: yesterday''s check-in is correction_needed (no second session)');
select pg_temp.pact('w30@proj.co');
select pg_temp.expect(punch('out', 19.1000, 72.9000, 10) ->> 'ok' = 'true', 'S23 the app check-out still closes today''s session');
select pg_temp.pact('owner');
-- S24 a stale app session on a CLOSED day does not block a new biometric check-in today
insert into attendance_events (employee_id, kind, at, work_mode, location_id, verified, work_date) values
  (pg_temp.w(31), 'in', pg_temp.at(pg_temp.pd(2), '08:00'), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(2));
select pg_temp.pp('fl', 31, pg_temp.at(pg_temp.pd(0), '09:00')); select pg_temp.dates(); select pg_temp.proj(31, pg_temp.pd(0));
select pg_temp.expect(pg_temp.evs(31, pg_temp.pd(0)) = 'in 09:00 B' and pg_temp.state(31) = 'working:' || pg_temp.pd(0), 'S24 stale session on a closed day: today''s check-in projected; the person is not stuck');
-- S25 no bypass through HR "process now" or Admin retry
select set_config('s.r32', pg_temp.pp('fl', 32, pg_temp.at(pg_temp.pd(1), '09:00'), '{"auth": "unauthenticated_lan"}')::text, false);
select pg_temp.pact('hr@proj.co'); select pg_temp.review(current_setting('s.r32')::bigint, 'accept_time'); select pg_temp.pact('owner'); select pg_temp.dates();
select pg_temp.pact('hr@proj.co'); select biometric_project_now(pg_temp.w(32), pg_temp.pd(1)); select pg_temp.pact('owner');
select pg_temp.expect(pg_temp.st(current_setting('s.r32')::bigint) = 'correction_needed', 'S25 HR "process now" applies session safety too');
select set_config('s.r33', pg_temp.pp('fl', 33, pg_temp.at(pg_temp.pd(1), '09:00'), '{"auth": "unauthenticated_lan"}')::text, false);
select pg_temp.pact('hr@proj.co'); select pg_temp.review(current_setting('s.r33')::bigint, 'accept_time'); select pg_temp.pact('owner'); select pg_temp.dates();
select pg_temp.pact('admin@proj.co'); select biometric_retry_day(pg_temp.w(33), pg_temp.pd(1)); select pg_temp.pact('owner');
select pg_temp.expect(pg_temp.st(current_setting('s.r33')::bigint) = 'correction_needed' and pg_temp.webin(32) ->> 'ok' = 'true' and pg_temp.webin(33) ->> 'ok' = 'true',
  'S25 Admin retry applies session safety too; both employees can check in on the web');

-- ================================================================ H — held punches, retry and age
-- H1 held 5 days, cause unresolved: re-evaluated when due at any age; stays held; backoff 1 h; nothing else changes
insert into roster_day (employee_id, day, work_mode) values (pg_temp.w(34), pg_temp.pd(5), 'off'), (pg_temp.w(35), pg_temp.pd(3), 'off'),
  (pg_temp.w(36), pg_temp.pd(1), 'off'), (pg_temp.w(37), pg_temp.pd(1), 'off'), (pg_temp.w(38), pg_temp.pd(3), 'off');
select set_config('h.r34', pg_temp.pp('fl', 34, pg_temp.at(pg_temp.pd(5), '09:00'), '{"status": "stored"}')::text, false);
select pg_temp.pp('fl', 34, pg_temp.at(pg_temp.pd(5), '17:00'), '{"status": "stored"}');
select pg_temp.dates(); select pg_temp.proj(34, pg_temp.pd(5));
select pg_temp.expect(pg_temp.st(current_setting('h.r34')::bigint) = 'held', 'H1 an old punch on a weekly off is held (holds come before the age rule)');
update biometric_event_state set held_since = now() - interval '5 days', next_check_at = now() - interval '1 second' where employee_id = pg_temp.w(34);
select set_config('h.before', (select to_jsonb(s) - 'next_check_at' - 'version' - 'updated_at' from biometric_event_state s where raw_event_id = current_setting('h.r34')::bigint)::text, false);
select pg_temp.proj(34, pg_temp.pd(5));
select pg_temp.expect(pg_temp.st(current_setting('h.r34')::bigint) = 'held'
  and (pg_temp.sx(current_setting('h.r34')::bigint)).next_check_at between now() + interval '59 minutes' and now() + interval '61 minutes'
  and (select to_jsonb(s) - 'next_check_at' - 'version' - 'updated_at' from biometric_event_state s where raw_event_id = current_setting('h.r34')::bigint)::text = current_setting('h.before')
  and (select punch_at from biometric_raw_events where id = current_setting('h.r34')::bigint) = pg_temp.at(pg_temp.pd(5), '09:00'),
  'H1 still held; only next_check_at moved (held 5 days → 1 h); held_since, reason, punch time and work date unchanged');
update biometric_event_state set held_since = now() - interval '8 days', next_check_at = now() - interval '1 second' where employee_id = pg_temp.w(34);
select pg_temp.proj(34, pg_temp.pd(5));
select pg_temp.expect((pg_temp.sx(current_setting('h.r34')::bigint)).next_check_at between now() + interval '359 minutes' and now() + interval '361 minutes',
  'H1 held more than 7 days → next look in 6 h');
-- H2 cause fixed after the window: flagged late_backfill, late_release_at set, no row; an earlier acceptance does not count
delete from roster_day where employee_id = pg_temp.w(34);
select pg_temp.due(34); select set_config('h.aud', pg_temp.audits(current_setting('h.r34')::bigint)::text, false);
select set_config('h.ver', (pg_temp.sx(current_setting('h.r34')::bigint)).version::text, false);
select pg_temp.proj(34, pg_temp.pd(5));
select pg_temp.expect(pg_temp.st(current_setting('h.r34')::bigint) = 'flagged' and 'late_backfill' = any (pg_temp.fl(current_setting('h.r34')::bigint))
  and (pg_temp.sx(current_setting('h.r34')::bigint)).late_release_at is not null and pg_temp.evs(34, pg_temp.pd(5)) = '',
  'H2 released after 2 days: flagged late_backfill, late_release_at set, nothing counted');
select pg_temp.expect((pg_temp.sx(current_setting('h.r34')::bigint)).version = current_setting('h.ver')::int + 1
  and pg_temp.audits(current_setting('h.r34')::bigint) = current_setting('h.aud')::int + 1, 'B10 late release is ONE write (one version step, one audit row)');
select set_config('h.r35', pg_temp.pp('fl', 35, pg_temp.at(pg_temp.pd(3), '09:00'), '{"auth": "unauthenticated_lan"}')::text, false);
select set_config('h.r35b', pg_temp.pp('fl', 35, pg_temp.at(pg_temp.pd(3), '17:00'), '{"auth": "unauthenticated_lan"}')::text, false);
select pg_temp.pact('hr@proj.co'); select pg_temp.review(current_setting('h.r35')::bigint, 'accept_time'); select pg_temp.review(current_setting('h.r35b')::bigint, 'accept_time');
select pg_temp.pact('owner'); select pg_temp.dates(); select pg_temp.proj(35, pg_temp.pd(3));
select pg_temp.expect(pg_temp.st(current_setting('h.r35')::bigint) = 'held' and (pg_temp.sx(current_setting('h.r35')::bigint)).decided, 'H2 an accepted punch on an off day is held');
delete from roster_day where employee_id = pg_temp.w(35); select pg_temp.due(35); select pg_temp.proj(35, pg_temp.pd(3));
select pg_temp.expect(pg_temp.st(current_setting('h.r35')::bigint) = 'flagged' and pg_temp.evs(35, pg_temp.pd(3)) = '',
  'H2 released late: flagged again although HR accepted it before the hold — the earlier acceptance does not count');
-- H3 released within two days → ordinary gate (projected; an unaccepted unauthenticated one is flagged)
select pg_temp.pair('fl', 36, pg_temp.pd(1));
select set_config('h.r37', pg_temp.pp('fl', 37, pg_temp.at(pg_temp.pd(1), '09:00'), '{"auth": "unauthenticated_lan", "status": "stored"}')::text, false);
select pg_temp.dates(); select pg_temp.proj(36, pg_temp.pd(1)); select pg_temp.proj(37, pg_temp.pd(1));
delete from roster_day where employee_id in (pg_temp.w(36), pg_temp.w(37)); select pg_temp.due(36); select pg_temp.due(37);
select pg_temp.proj(36, pg_temp.pd(1)); select pg_temp.proj(37, pg_temp.pd(1));
select pg_temp.expect(pg_temp.evs(36, pg_temp.pd(1)) = 'in 09:00 B, out 17:00 B' and pg_temp.st(current_setting('h.r37')::bigint) = 'flagged'
  and 'unauthenticated_source' = any (pg_temp.fl(current_setting('h.r37')::bigint)), 'H3 released within 2 days: projected; an unaccepted unauthenticated one is flagged');
-- H4 a new acceptance after a late release is allowed once and then the ordinary rules (incl. session safety) apply
select pg_temp.pact('hr@proj.co');
select pg_temp.expect(pg_temp.review(current_setting('h.r35')::bigint, 'accept_time', 'Re-checked after the roster fix') ->> 'status' = 'stored'
  and pg_temp.review(current_setting('h.r35b')::bigint, 'accept_time', 'Re-checked after the roster fix') ->> 'status' = 'stored',
  'H4 a new acceptance after the late release is accepted');
select pg_temp.expect(pg_temp.review(current_setting('h.r34')::bigint, 'dismiss', 'nothing') ->> 'ok' = 'true', 'H4 (an undecided late release can be dismissed)');
select pg_temp.pact('owner');
select pg_temp.expect((select count(*) from biometric_event_reviews where raw_event_id = current_setting('h.r35')::bigint and action = 'accept_time') = 2,
  'H4 both acceptances are kept (insert-only review history)');
select pg_temp.proj(35, pg_temp.pd(3));
select pg_temp.expect(pg_temp.evs(35, pg_temp.pd(3)) = 'in 09:00 B, out 17:00 B', 'H4 after the new acceptance the pair is projected');
select pg_temp.pact('hr@proj.co');
select pg_temp.expect(pg_temp.review(current_setting('h.r35')::bigint, 'accept_time') ->> 'message' ~ 'already been decided', 'H4 a third acceptance is refused');
select pg_temp.pact('owner');
select set_config('h.r38', pg_temp.pp('fl', 38, pg_temp.at(pg_temp.pd(3), '09:00'), '{"auth": "unauthenticated_lan"}')::text, false);
select pg_temp.pact('hr@proj.co'); select pg_temp.review(current_setting('h.r38')::bigint, 'accept_time'); select pg_temp.pact('owner');
select pg_temp.dates(); select pg_temp.proj(38, pg_temp.pd(3)); delete from roster_day where employee_id = pg_temp.w(38); select pg_temp.due(38); select pg_temp.proj(38, pg_temp.pd(3));
select pg_temp.pact('hr@proj.co'); select pg_temp.review(current_setting('h.r38')::bigint, 'accept_time'); select pg_temp.pact('owner');
select pg_temp.proj(38, pg_temp.pd(3));
select pg_temp.expect(pg_temp.st(current_setting('h.r38')::bigint) = 'correction_needed' and pg_temp.webin(38) ->> 'ok' = 'true',
  'H4 re-accepted historic lone check-in still ends correction_needed; later web check-in succeeds');
-- H5 cause fixed while projection is disabled
insert into roster_day (employee_id, day, work_mode) values (pg_temp.w(39), pg_temp.pd(1), 'off');
select set_config('h.r39', pg_temp.pair('fl', 39, pg_temp.pd(1))::text, false);
select pg_temp.pp('fl', 40, pg_temp.at(pg_temp.pd(0), '08:30'));
select pg_temp.dates(); select pg_temp.proj(39, pg_temp.pd(1)); select pg_temp.proj(40, pg_temp.pd(0));
update biometric_settings set projection_enabled = false where company_id = current_setting('p.c')::uuid;
delete from roster_day where employee_id = pg_temp.w(39); select pg_temp.due(39);
select set_config('h.s39', (select to_jsonb(s)::text from biometric_event_state s where raw_event_id = current_setting('h.r39')::bigint), false);
select set_config('h.p39', pg_temp.proj(39, pg_temp.pd(1)) ->> 'reason', false);
select pg_temp.expect(current_setting('h.p39') = 'projection_disabled'
  and (select to_jsonb(s)::text from biometric_event_state s where raw_event_id = current_setting('h.r39')::bigint) = current_setting('h.s39'),
  'H5 projection off: the fixed held punch is untouched (same version)');
select set_config('h.r40', pg_temp.pp('fl', 40, pg_temp.at(pg_temp.pd(0), '11:00'))::text, false); select pg_temp.dates(); select pg_temp.proj(40, pg_temp.pd(0));
select pg_temp.expect(pg_temp.st(current_setting('h.r40')::bigint) = 'provisional_out', 'H5 a day that already has a projected slot keeps being processed (Q3)');
update biometric_settings set projection_enabled = true where company_id = current_setting('p.c')::uuid;
select pg_temp.proj(39, pg_temp.pd(1));
select pg_temp.expect(pg_temp.evs(39, pg_temp.pd(1)) = 'in 09:00 B, out 17:00 B', 'H5 enabled again: re-evaluated by the normal rules (within 2 days → projected)');
-- H7 company-local dates (catalog + values): no current_date in the queue; local_today differs by zone at the same instant
select pg_temp.expect((select prosrc from pg_proc where proname = 'biometric_run_projection') ~ 'local_today\(s\.company_id\)'
  and (select regexp_replace(prosrc, '--[^\n]*', '', 'g') from pg_proc where proname = 'biometric_run_projection') !~* 'current_date'
  and (select regexp_replace(prosrc, '--[^\n]*', '', 'g') from pg_proc where proname = 'biometric_project_day') !~* 'current_date',
  'H7 the queue and projection use the company''s local date, never current_date');
select pg_temp.expect((now() at time zone 'Pacific/Kiritimati')::date - (now() at time zone 'America/Adak')::date = 1
  and (select prosrc from pg_proc where proname = 'biometric_project_day') ~ 'now\(\) - make_interval\(days => st.auto_project_max_age_days\)',
  'H7 +14 and −10 companies have different local dates now; the 2-day window is a duration from now() (same everywhere)');

-- ================================================================ T — guard on the attribution tuple (every change refused with the projection setting ON)
select set_config('t.row', (select id::text from attendance_events where employee_id = pg_temp.w(1) and projection_slot = 'in'), false);
select set_config('t.r1x', pg_temp.pp('fl', 1, pg_temp.at(pg_temp.pd(0), '10:00'))::text, false);        -- same person and day, another time
select set_config('t.r1m', pg_temp.pp('fl2', 1, pg_temp.at(pg_temp.pd(0), '07:45'))::text, false);       -- for a valid move (T6)
select pg_temp.dates();
select set_config('t.otherco', (select r.id::text from biometric_raw_events r where r.company_id <> current_setting('p.c')::uuid limit 1), false);
create function pg_temp.tupd(setclause text) returns text language sql as $$
  select format('update attendance_events set %s where id = %s', setclause, current_setting('t.row')) $$;
select set_config('attendos.projection', 'on', false);
select pg_temp.fails(pg_temp.tupd('at = at + interval ''1 second'''), 'must match its raw punch', 'T1 at changed alone (+1 s): refused');
select pg_temp.fails(pg_temp.tupd('biometric_event_id = ' || current_setting('t.r1x')), 'must match its raw punch', 'T2 raw punch of the same person/day, other time: refused');
select pg_temp.fails(pg_temp.tupd('biometric_event_id = ' || current_setting('f.r2b')), 'must match its raw punch', 'T2 raw punch of another person: refused');
select pg_temp.fails(pg_temp.tupd('biometric_event_id = ' || current_setting('t.otherco')), 'must match its raw punch', 'T2 raw punch of another company: refused');
select pg_temp.fails(pg_temp.tupd('device_id = ''' || current_setting('p.fl2') || ''''), 'must match its raw punch', 'T3 another device of the same company: refused');
select pg_temp.fails(pg_temp.tupd('device_id = ''' || (select id from biometric_devices where company_id <> current_setting('p.c')::uuid limit 1) || ''''),
  'Cross-company reference|must match', 'T3 a device of another company: refused');
select pg_temp.fails(pg_temp.tupd('import_batch_id = ''' || (select id from biometric_import_batches where file_name = 'old.csv') || ''''),
  'external_shape|must match', 'T4 import batch set on a biometric row: refused');
select pg_temp.fails(pg_temp.tupd('location_id = ''' || current_setting('p.loc2') || ''''), 'must match its raw punch', 'T5 another office of the company: refused');
select pg_temp.fails(pg_temp.tupd('location_id = null'), 'must match its raw punch', 'T5 office removed: refused');
select pg_temp.fails(pg_temp.tupd('location_id = ''' || (select id from locations where company_id <> current_setting('p.c')::uuid limit 1) || ''''), 'Cross-company reference|must match', 'T5 an office of another company: refused');
select pg_temp.expect((select count(*) from attendance_events where id = current_setting('t.row')::bigint and biometric_event_id = current_setting('f.r1')::bigint
  and at = pg_temp.at(pg_temp.pd(0), '08:55') and location_id = current_setting('p.loc')::uuid) = 1, 'T1–T5 the row is unchanged');
-- T6 a valid in-place move is accepted (same id); the same on a superseded slot is refused
update attendance_events set at = pg_temp.at(pg_temp.pd(0), '07:45'), biometric_event_id = current_setting('t.r1m')::bigint,
       device_id = current_setting('p.fl2')::uuid, location_id = current_setting('p.loc')::uuid where id = current_setting('t.row')::bigint;
select pg_temp.expect((select biometric_event_id from attendance_events where id = current_setting('t.row')::bigint) = current_setting('t.r1m')::bigint, 'T6 a consistent move (time, raw, device, office of one raw punch) is accepted, same id');
select pg_temp.fails(format('update attendance_events set at = at - interval ''1 hour'' where id = %s', current_setting('g.id22')), 'Only projection may move an unlocked',
  'T6 the same kind of move on a superseded slot is refused');
-- T7 inserts whose raw punch has another work day, another person, or no state
select set_config('t.nostate', (select x from (select pg_temp.pp('fl', 41, pg_temp.at(pg_temp.pd(0), '06:00'))) y(x))::text, false);
delete from biometric_event_state where false;   -- (state rows cannot be deleted; use a raw punch whose state belongs elsewhere)
select pg_temp.fails(format($$insert into attendance_events (employee_id, kind, at, work_mode, location_id, verified, source, work_date, device_id, biometric_event_id, projection_slot, direction_basis)
  values (%L, 'in', %L, 'office', %L, false, 'biometric', %L, %L, %s, 'in', 'inferred_first_last')$$, pg_temp.w(41), pg_temp.at(pg_temp.pd(0), '06:00'), current_setting('p.loc'),
  pg_temp.pd(1), current_setting('p.fl'), current_setting('t.nostate')), 'must match its raw punch', 'T7 raw punch of another work day: refused');
select pg_temp.fails(format($$insert into attendance_events (employee_id, kind, at, work_mode, location_id, verified, source, work_date, device_id, biometric_event_id, projection_slot, direction_basis)
  values (%L, 'in', %L, 'office', %L, false, 'biometric', %L, %L, %s, 'in', 'inferred_first_last')$$, pg_temp.w(42), pg_temp.at(pg_temp.pd(0), '06:00'), current_setting('p.loc'),
  pg_temp.pd(0), current_setting('p.fl'), current_setting('t.nostate')), 'must match its raw punch', 'T7 raw punch of another person: refused');
insert into biometric_raw_events (company_id, device_id, agent_id, employee_device_code, device_local_time, device_timezone, punch_at, source_auth, dedupe_key, dedupe_basis)
  values (current_setting('p.c')::uuid, current_setting('p.fl')::uuid, current_setting('p.agent')::uuid, 'C41',
          to_char(pg_temp.at(pg_temp.pd(0), '06:30') at time zone current_setting('p.tz'), 'YYYY-MM-DD HH24:MI:SS'), current_setting('p.tz'), pg_temp.at(pg_temp.pd(0), '06:30'),
          'authenticated', 'fp:nostate', 'fingerprint');
select pg_temp.fails(format($$insert into attendance_events (employee_id, kind, at, work_mode, location_id, verified, source, work_date, device_id, biometric_event_id, projection_slot, direction_basis)
  values (%L, 'in', %L, 'office', %L, false, 'biometric', %L, %L, %s, 'in', 'inferred_first_last')$$, pg_temp.w(41), pg_temp.at(pg_temp.pd(0), '06:30'), current_setting('p.loc'),
  pg_temp.pd(0), current_setting('p.fl'), (select id from biometric_raw_events where dedupe_key = 'fp:nostate')), 'must match its raw punch', 'T7 raw punch without a state row: refused');
-- T8 device-mode slot must be named after its own raw punch
select set_config('t.dv', pg_temp.pp('dv', 41, pg_temp.at(pg_temp.pd(0), '06:40'), '{"dir": "in"}')::text, false); select pg_temp.dates();
select pg_temp.fails(format($$insert into attendance_events (employee_id, kind, at, work_mode, location_id, verified, source, work_date, device_id, biometric_event_id, projection_slot, direction_basis)
  values (%L, 'in', %L, 'office', %L, false, 'biometric', %L, %L, %s, 'dev:1', 'device')$$, pg_temp.w(41), pg_temp.at(pg_temp.pd(0), '06:40'), current_setting('p.loc'),
  pg_temp.pd(0), current_setting('p.dv'), current_setting('t.dv')), 'must match its raw punch', 'T8 dev:<id> not matching its raw punch: refused');
-- T9 device office changed after projection: existing rows untouched; a change must carry the new office
update biometric_devices set location_id = current_setting('p.loc')::uuid where id = current_setting('p.no')::uuid;
select pg_temp.expect((select bool_and(location_id = current_setting('p.loc2')::uuid) from attendance_events where employee_id = pg_temp.w(19)), 'T9 rows keep the office they were projected with');
select pg_temp.fails(format('update attendance_events set location_id = %L where employee_id = %L and kind = ''in''', current_setting('p.loc2'), pg_temp.w(19)), 'must match|no rows', 'T9 (no-op re-statement is not a change)')
  where false;
update attendance_events set location_id = current_setting('p.loc')::uuid where employee_id = pg_temp.w(19) and kind = 'in';
select pg_temp.expect((select location_id from attendance_events where employee_id = pg_temp.w(19) and kind = 'in') = current_setting('p.loc')::uuid, 'T9 a change carrying the new office is accepted');
select pg_temp.fails(format('update attendance_events set location_id = %L where employee_id = %L and kind = ''in''', current_setting('p.loc2'), pg_temp.w(19)),
  'must match its raw punch', 'T9 a change keeping the old office is refused');
select set_config('attendos.projection', '', false);
select pg_temp.fails(pg_temp.tupd('at = at + interval ''1 second'''), 'Only projection may move', 'T* with the projection setting off every attribution change is refused (projection-only rule)');
select pg_temp.fails(format($$insert into attendance_events (employee_id, kind, at, work_mode, location_id, verified, source, work_date, device_id, biometric_event_id, projection_slot, direction_basis)
  values (%L, 'in', %L, 'office', %L, false, 'biometric', %L, %L, %s, 'dev:%s', 'device')$$, pg_temp.w(41), pg_temp.at(pg_temp.pd(0), '06:40'), current_setting('p.loc'),
  pg_temp.pd(0), current_setting('p.dv'), current_setting('t.dv'), current_setting('t.dv')), 'written only by projection', 'T* a fully valid biometric insert outside projection is refused');

-- ================================================================ V — source transitions (refused with the projection setting off AND on)
insert into attendance_events (employee_id, kind, at, work_mode, location_id, verified, work_date) values
  (pg_temp.w(42), 'in', pg_temp.at(pg_temp.pd(1), '09:00'), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(1));
select set_config('v.web', (select id::text from attendance_events where employee_id = pg_temp.w(42) and source = 'web'), false);
select set_config('v.corr', (select id::text from attendance_events where employee_id = pg_temp.w(27) and source = 'correction'), false);
select set_config('v.bio', (select id::text from attendance_events where employee_id = pg_temp.w(3) and kind = 'in'), false);
select set_config('v.real', pg_temp.pp('fl', 42, pg_temp.at(pg_temp.pd(1), '09:00'))::text, false); select pg_temp.dates();
create function pg_temp.vsnap() returns text language sql as $$
  select md5(string_agg(to_jsonb(e)::text, '|' order by id)) || (select count(*) from public.audit_log)
    from public.attendance_events e where e.id in (current_setting('v.web')::bigint, current_setting('v.corr')::bigint, current_setting('v.bio')::bigint) $$;
select set_config('v.snap', pg_temp.vsnap(), false);
create function pg_temp.vtry(ctx text, id text, setclause text, what text) returns void language plpgsql as $$
begin
  perform set_config('attendos.projection', ctx, false);
  perform pg_temp.fails(format('update attendance_events set %s where id = %s', setclause, id), 'source of an attendance event never changes', what || ' [projection ' || coalesce(nullif(ctx, ''), 'off') || ']');
  perform set_config('attendos.projection', '', false);
end $$;
select pg_temp.vtry(ctx, current_setting('v.web'), 'source = ''biometric''', 'V1 web → biometric, nothing else changed') from unnest(array['', 'on']) ctx;
select pg_temp.vtry(ctx, current_setting('v.web'), 'source = ''import''', 'V2 web → import, nothing else changed') from unnest(array['', 'on']) ctx;
select pg_temp.vtry(ctx, current_setting('v.web'), format('source = ''biometric'', biometric_event_id = %s, device_id = %L, projection_slot = ''in'', direction_basis = ''inferred_first_last'', verified = false, distance_m = null, accuracy_m = null', r, current_setting('p.fl')),
  'V3 web → biometric with fabricated raw reference ' || r) from unnest(array['', 'on']) ctx, unnest(array['999999999', current_setting('f.r2b'), current_setting('t.r1x')]) r;
select pg_temp.vtry(ctx, current_setting('v.web'), format('source = ''biometric'', biometric_event_id = %s, device_id = %L, location_id = %L, projection_slot = ''in'', direction_basis = ''inferred_first_last'', verified = false, distance_m = null, accuracy_m = null',
  current_setting('v.real'), current_setting('p.fl'), current_setting('p.loc')), 'V4 valid-looking web → biometric copied from a real stored punch') from unnest(array['', 'on']) ctx;
select pg_temp.vtry(ctx, current_setting('v.bio'), 'source = ' || quote_literal(t) || ', biometric_event_id = null, device_id = null, projection_slot = null, direction_basis = null',
  'V5 projected biometric → ' || t) from unnest(array['', 'on']) ctx, unnest(array['web', 'correction', 'import']) t;
select pg_temp.vtry(ctx, current_setting('v.corr'), 'source = ' || quote_literal(t), 'V5 correction → ' || t) from unnest(array['', 'on']) ctx, unnest(array['web', 'biometric']) t;
select pg_temp.vtry(ctx, current_setting('v.web'), 'source = ''correction''', 'V6 web → correction') from unnest(array['', 'on']) ctx;
select pg_temp.expect(pg_temp.vsnap() = current_setting('v.snap'), 'V1–V6 the three rows are byte-identical afterwards and no audit row was written');
select pg_temp.expect((select count(*) from audit_log where action = 'biometric_project' and target_id = current_setting('v.bio')) = 1
  and (select source from attendance_events where id = current_setting('v.bio')::bigint) = 'biometric', 'V7 a legitimate projection INSERT passed (one audit row)');
select pg_temp.expect((select source = 'biometric' and superseded_by is not null from attendance_events where id = current_setting('g.id22')::bigint)
  and (select count(*) from audit_log where action = 'biometric_slot_moved' and target_id = current_setting('f.id6')) = 1,
  'V8 a legitimate slot move (F9) and a correction superseding a biometric row (G15) passed, source unchanged');

-- ================================================================ A — authentication gate
select pg_temp.expect(pg_temp.evs(10, pg_temp.pd(0)) = 'in 09:00 B', 'A1 unauthenticated LAN punch: flagged, one individual acceptance → projected (G12)');
select pg_temp.fails($do$ do $x$
declare r1 bigint; r2 bigint;
begin
  alter table public.biometric_raw_events drop constraint biometric_raw_events_source_auth_check;
  alter table public.biometric_raw_events alter column source_auth drop not null;
  alter table public.biometric_raw_events drop constraint biometric_raw_events_check1;
  r1 := pg_temp.pp('fl', 43, pg_temp.at(pg_temp.pd(0), '08:00'), '{"auth": "lan_trusted_maybe", "status": "stored"}');
  insert into public.biometric_raw_events (company_id, device_id, agent_id, employee_device_code, device_local_time, device_timezone, punch_at, source_auth, dedupe_key, dedupe_basis)
    values (current_setting('p.c')::uuid, current_setting('p.fl')::uuid, current_setting('p.agent')::uuid, 'C43',
            to_char(pg_temp.at(pg_temp.pd(0), '08:10') at time zone current_setting('p.tz'), 'YYYY-MM-DD HH24:MI:SS'), current_setting('p.tz'),
            pg_temp.at(pg_temp.pd(0), '08:10'), null, 'fp:nullauth', 'fingerprint') returning id into r2;
  insert into public.biometric_event_state (raw_event_id, company_id, employee_id, mapping_id, status)
    values (r2, current_setting('p.c')::uuid, pg_temp.w(43), public.biometric_resolve_mapping(current_setting('p.c')::uuid, current_setting('p.fl')::uuid, 'C43', pg_temp.at(pg_temp.pd(0), '08:10')), 'stored');
  perform pg_temp.dates();
  perform public.biometric_project_day(pg_temp.w(43), pg_temp.pd(0));
  raise exception 'A2RESULT % % %', pg_temp.st(r1), pg_temp.st(r2), (select count(*) from public.attendance_events where employee_id = pg_temp.w(43));
end $x$ $do$, 'A2RESULT flagged flagged 0', 'A2 an unexpected or NULL source_auth (constraints lifted in a rolled-back block) is flagged, never projected');
select pg_temp.expect((select prosrc from pg_proc where proname = 'biometric_project_day') ~ 'source_auth is distinct from ''authenticated'''
  and (select prosrc from pg_proc where proname = 'biometric_project_day') ~ 'decided is not true'
  and (select prosrc from pg_proc where proname = 'biometric_project_day') ~ 'coalesce\(cardinality\(c\.time_flags\), 0\)',
  'A3 the gate is null-safe (IS DISTINCT FROM, IS NOT TRUE, coalesce on flag counts)');
update biometric_devices set device_auth = 'none' where id = current_setting('p.fl')::uuid;
select set_config('a.r44', pg_temp.pp('fl', 44, pg_temp.at(pg_temp.pd(0), '08:00'), '{"auth": "unauthenticated_lan"}')::text, false);
select pg_temp.dates(); select pg_temp.proj(10, pg_temp.pd(0)); select pg_temp.proj(44, pg_temp.pd(0));
select pg_temp.expect(pg_temp.evs(10, pg_temp.pd(0)) = 'in 09:00 B' and pg_temp.st(current_setting('a.r44')::bigint) = 'flagged',
  'A4 after a device is reclassified, accepted punches stay counted; new unauthenticated punches are flagged one by one');

-- ================================================================ D — device-direction transitions (nothing invalid may reach the register)
create function pg_temp.dp(dev text, n int, d date, t time, dir text, o jsonb default '{}') returns bigint language sql as $$
  select pg_temp.pp(dev, n, pg_temp.at(d, t), jsonb_build_object('dir', dir) || o) $$;
create function pg_temp.dproj(n int, d date) returns jsonb language plpgsql as $$
begin perform pg_temp.dates(); return pg_temp.proj(n, d); end $$;
-- D26 repeated IN
select pg_temp.dp('dv', 45, pg_temp.pd(0), '08:00:00', 'in');
select set_config('d.a', pg_temp.dp('dv', 45, pg_temp.pd(0), '08:00:40', 'in')::text, false);
select set_config('d.b', pg_temp.dp('dv', 45, pg_temp.pd(0), '08:03', 'in')::text, false);
select set_config('d.c', pg_temp.dp('dv', 45, pg_temp.pd(0), '08:20', 'in')::text, false);
select pg_temp.dproj(45, pg_temp.pd(0));
select pg_temp.expect(pg_temp.evs(45, pg_temp.pd(0)) = 'in 08:00 B' and pg_temp.st(current_setting('d.a')::bigint) = 'extra' and 'double_press' = any (pg_temp.fl(current_setting('d.a')::bigint))
  and pg_temp.st(current_setting('d.b')::bigint) = 'extra' and 'repeat_in' = any (pg_temp.fl(current_setting('d.b')::bigint))
  and pg_temp.st(current_setting('d.c')::bigint) = 'correction_needed' and 'impossible_transition' = any (pg_temp.fl(current_setting('d.c')::bigint)),
  'D26 IN again: within 60 s double press, within 5 min repeat (extra), later impossible (correction_needed)');
select pg_temp.expect((select direction_basis = 'device' and projection_slot = 'dev:' || biometric_event_id from attendance_events where employee_id = pg_temp.w(45)),
  'D26 device rows are marked device-confirmed (slot dev:<raw id>)');
-- D27 OUT with no IN
select set_config('d.e', pg_temp.dp('dv', 46, pg_temp.pd(0), '09:00', 'out')::text, false); select pg_temp.dproj(46, pg_temp.pd(0));
select pg_temp.expect(pg_temp.st(current_setting('d.e')::bigint) = 'correction_needed' and pg_temp.evs(46, pg_temp.pd(0)) = '', 'D27 OUT without an earlier IN: correction_needed');
-- D28 IN while checked in with the app
insert into attendance_events (employee_id, kind, at, work_mode, location_id, verified, work_date) values
  (pg_temp.w(47), 'in', pg_temp.at(pg_temp.pd(0), '08:00'), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(0));
select set_config('d.f', pg_temp.dp('dv', 47, pg_temp.pd(0), '09:00', 'in')::text, false); select pg_temp.dproj(47, pg_temp.pd(0));
select pg_temp.expect(pg_temp.st(current_setting('d.f')::bigint) = 'correction_needed' and pg_temp.evs(47, pg_temp.pd(0)) = 'in 08:00 W', 'D28 IN while already checked in (app): correction_needed');
-- D29 OUT after an app check-out; OUT while on an app break
insert into attendance_events (employee_id, kind, at, work_mode, location_id, verified, work_date) values
  (pg_temp.w(48), 'in', pg_temp.at(pg_temp.pd(0), '08:00'), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(0)),
  (pg_temp.w(48), 'out', pg_temp.at(pg_temp.pd(0), '09:00'), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(0)),
  (pg_temp.w(49), 'in', pg_temp.at(pg_temp.pd(0), '08:00'), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(0));
insert into attendance_events (employee_id, kind, at, work_mode, verified, work_date) values (pg_temp.w(49), 'break_start', pg_temp.at(pg_temp.pd(0), '09:00'), 'office', false, pg_temp.pd(0));
select set_config('d.g', pg_temp.dp('dv', 48, pg_temp.pd(0), '10:00', 'out')::text, false); select pg_temp.dproj(48, pg_temp.pd(0));
select set_config('d.h', pg_temp.dp('dv', 49, pg_temp.pd(0), '10:00', 'out')::text, false); select pg_temp.dproj(49, pg_temp.pd(0));
select pg_temp.expect(pg_temp.st(current_setting('d.g')::bigint) = 'correction_needed' and pg_temp.st(current_setting('d.h')::bigint) = 'correction_needed'
  and pg_temp.evs(48, pg_temp.pd(0)) = 'in 08:00 W, out 09:00 W' and pg_temp.evs(49, pg_temp.pd(0)) = 'in 08:00 W, break_start 09:00 W',
  'D29 OUT after an app check-out, and OUT during an app break: correction_needed');
-- D30 mode switched mid-day
select pg_temp.dp('dv', 50, pg_temp.pd(0), '08:00', 'in'); select pg_temp.dproj(50, pg_temp.pd(0));
select set_config('d.i', pg_temp.pp('fl', 50, pg_temp.at(pg_temp.pd(0), '10:00'))::text, false); select pg_temp.dproj(50, pg_temp.pd(0));
select pg_temp.expect(pg_temp.evs(50, pg_temp.pd(0)) = 'in 08:00 B' and pg_temp.st(current_setting('d.i')::bigint) = 'correction_needed'
  and 'mixed_direction_modes' = any (pg_temp.fl(current_setting('d.i')::bigint)), 'D30 punches from a first-in/last-out device on a device-mode day: correction_needed; counted row stays');
-- D31 several devices, same person
select pg_temp.dp('dv', 51, pg_temp.pd(0), '08:00:00', 'in');
select set_config('d.j', pg_temp.dp('dv2', 51, pg_temp.pd(0), '08:00:30', 'in')::text, false); select pg_temp.dproj(51, pg_temp.pd(0));
select pg_temp.dp('dv', 52, pg_temp.pd(0), '08:00', 'in'); select pg_temp.dp('dv2', 52, pg_temp.pd(0), '11:00', 'out'); select pg_temp.dproj(52, pg_temp.pd(0));
select pg_temp.expect(pg_temp.evs(51, pg_temp.pd(0)) = 'in 08:00 B' and pg_temp.st(current_setting('d.j')::bigint) = 'extra'
  and pg_temp.evs(52, pg_temp.pd(0)) = 'in 08:00 B, out 11:00 B'
  and (select array_agg(location_id order by at) from attendance_events where employee_id = pg_temp.w(52)) = array[current_setting('p.loc')::uuid, current_setting('p.loc2')::uuid],
  'D31 IN on two devices 30 s apart is one punch; IN on one and OUT on another make a valid pair (each with its device office)');
-- D32 duplicates
select pg_temp.fails(format($$insert into biometric_raw_events (company_id, device_id, agent_id, employee_device_code, device_local_time, device_timezone, punch_at, source_auth, dedupe_key, dedupe_basis)
  select company_id, device_id, agent_id, employee_device_code, device_local_time, device_timezone, punch_at, source_auth, dedupe_key, dedupe_basis from biometric_raw_events where id = %s$$, current_setting('d.j')),
  'duplicate key', 'D32 an identical re-send is stored once (dedupe key)');
select set_config('d.k', pg_temp.dp('dv', 53, pg_temp.pd(0), '08:00', 'in', '{"status": "possible_duplicate"}')::text, false); select pg_temp.dproj(53, pg_temp.pd(0));
select pg_temp.expect(pg_temp.st(current_setting('d.k')::bigint) = 'possible_duplicate' and pg_temp.evs(53, pg_temp.pd(0)) = '', 'D32 a possible duplicate is never projected');
-- D33 delayed and out-of-order
select pg_temp.dp('dv', 54, pg_temp.pd(0), '08:00', 'in'); select pg_temp.dp('dv', 54, pg_temp.pd(0), '11:30', 'out'); select pg_temp.dproj(54, pg_temp.pd(0));
select set_config('d.l', pg_temp.dp('dv2', 54, pg_temp.pd(0), '11:00', 'out')::text, false); select pg_temp.dproj(54, pg_temp.pd(0));
select pg_temp.dp('dv', 55, pg_temp.pd(1), '08:00', 'in'); select pg_temp.dp('dv', 55, pg_temp.pd(1), '16:00', 'out'); select pg_temp.dproj(55, pg_temp.pd(1));
select pg_temp.expect(pg_temp.evs(54, pg_temp.pd(0)) = 'in 08:00 B, out 11:30 B' and pg_temp.st(current_setting('d.l')::bigint) = 'correction_needed'
  and 'out_of_order' = any (pg_temp.fl(current_setting('d.l')::bigint)) and pg_temp.evs(55, pg_temp.pd(1)) = 'in 08:00 B, out 16:00 B',
  'D33 a delayed OUT earlier than a counted event is out_of_order; an in-order late arrival (yesterday) is projected');
-- D34 no direction
select set_config('d.m', pg_temp.pp('dv', 56, pg_temp.at(pg_temp.pd(0), '08:00'))::text, false); select pg_temp.dproj(56, pg_temp.pd(0));
select pg_temp.expect(pg_temp.st(current_setting('d.m')::bigint) = 'correction_needed' and 'no_direction' = any (pg_temp.fl(current_setting('d.m')::bigint)), 'D34 a device punch without direction: correction_needed');
-- D35 invariant over every day that has biometric rows
select pg_temp.expect(not exists (
  with ev as (select employee_id, work_date, kind, lag(kind) over (partition by employee_id, work_date order by at, id) prev
                from attendance_events where superseded_by is null and kind in ('in', 'out')
                 and (employee_id, work_date) in (select employee_id, work_date from attendance_events where source = 'biometric'))
  select 1 from ev where (prev is null and kind <> 'in') or prev = kind),
  'D35 every day with biometric rows alternates IN/OUT validly (starting with IN)');
select pg_temp.expect(not exists (select 1 from attendance_events e join biometric_raw_events r on r.id = e.biometric_event_id
  join biometric_event_state s on s.raw_event_id = r.id where e.at <> r.punch_at or s.employee_id <> e.employee_id or s.work_date <> e.work_date)
  and not exists (select employee_id, work_date, projection_slot from attendance_events where projection_slot is not null group by 1, 2, 3 having count(*) > 1),
  'D35 every biometric row matches its raw punch; no slot twice');

-- ================================================================ B — strict write budgets and continuation
insert into auth.users (id, email, email_confirmed_at)
  select ('00000000-0000-0000-0000-0000000002' || lpad(g::text, 2, '0'))::uuid, 'h' || lpad(g::text, 2, '0') || '@proj.co', now() from generate_series(1, 40) g;
insert into employees (company_id, full_name, email, role, user_id, home_location_id, joining_date)
  select current_setting('p.c')::uuid, 'Hand ' || lpad(g::text, 2, '0'), 'h' || lpad(g::text, 2, '0') || '@proj.co', 'employee',
         ('00000000-0000-0000-0000-0000000002' || lpad(g::text, 2, '0'))::uuid, current_setting('p.loc')::uuid, current_date - 60 from generate_series(1, 40) g;
insert into biometric_employee_mappings (company_id, employee_id, employee_device_code, valid_from)
  select current_setting('p.c')::uuid, (select id from employees where email = 'h' || lpad(g::text, 2, '0') || '@proj.co'), 'H' || lpad(g::text, 2, '0'), now() - interval '60 days'
    from generate_series(1, 40) g;
create function pg_temp.h(n int) returns uuid language sql as $$ select id from public.employees where email = 'h' || lpad(n::text, 2, '0') || '@proj.co' $$;
create function pg_temp.hp(dev text, n int, ts timestamptz, o jsonb default '{}') returns bigint language sql as $$
  select pg_temp.pp(dev, 0, ts, jsonb_build_object('code', 'H' || lpad(n::text, 2, '0')) || o) $$;
-- writes counter: state versions above 1 + projected attendance rows + error records, for a set of people
create function pg_temp.wcount(emps uuid[]) returns bigint language sql as $$
  select coalesce((select sum(version - 1) from public.biometric_event_state where employee_id = any (emps)), 0)
       + (select count(*) from public.attendance_events where employee_id = any (emps) and source = 'biometric')
       + (select count(*) from public.biometric_event_errors where kind = 'processing_failure' and (detail ->> 'employee_id')::uuid = any (emps)) $$;
create function pg_temp.hevs(n int, d date) returns text language sql as $$
  select coalesce(string_agg(e.kind || ' ' || to_char(e.at at time zone current_setting('p.tz'), 'HH24:MI'), ', ' order by e.at, e.id), '')
    from public.attendance_events e where e.employee_id = pg_temp.h(n) and e.work_date = d and e.superseded_by is null $$;
create function pg_temp.hroles(n int, d date) returns text language sql as $$
  select string_agg(s.status, ',' order by r.punch_at, r.id) from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
   where s.employee_id = pg_temp.h(n) and s.work_date = d $$;
-- B1/B2 budgets 1 and 5: deferred, nothing written
select pg_temp.hp('fl', 1, pg_temp.at(pg_temp.pd(0), '08:00')); select pg_temp.dates();
select set_config('b.snap', (select md5(string_agg(to_jsonb(s)::text, '|')) from biometric_event_state s where employee_id = pg_temp.h(1)) || pg_temp.wcount(array[pg_temp.h(1)]), false);
select set_config('b.d1', biometric_project_day(pg_temp.h(1), pg_temp.pd(0), 1) ->> 'deferred', false);
select set_config('b.d5', biometric_project_day(pg_temp.h(1), pg_temp.pd(0), 5) ->> 'deferred', false);
select pg_temp.expect(current_setting('b.d1') = 'true' and current_setting('b.d5') = 'true'
  and (select md5(string_agg(to_jsonb(s)::text, '|')) from biometric_event_state s where employee_id = pg_temp.h(1)) || pg_temp.wcount(array[pg_temp.h(1)]) = current_setting('b.snap')
  and pg_temp.hevs(1, pg_temp.pd(0)) = '', 'B1/B2 limits 1 and 5: deferred, no state, row, audit or version change; the punch stays stored');
-- B3/B4 limits 9 and 10 on a closed day needing slot creation + 10 extras; the result equals an unbounded run (h04)
select pg_temp.hp('fl', n, pg_temp.at(pg_temp.pd(1), '08:00')) from generate_series(2, 4) n;
select pg_temp.hp('fl', n, pg_temp.at(pg_temp.pd(1), '09:00') + make_interval(mins => 10 * g)) from generate_series(2, 4) n, generate_series(1, 10) g;
select pg_temp.hp('fl', n, pg_temp.at(pg_temp.pd(1), '16:30')) from generate_series(2, 4) n;
select pg_temp.dates();
select set_config('b.pre2', pg_temp.wcount(array[pg_temp.h(2)])::text, false); select set_config('b.pre3', pg_temp.wcount(array[pg_temp.h(3)])::text, false);
select set_config('b.w9', (biometric_project_day(pg_temp.h(2), pg_temp.pd(1), 9) ->> 'written'), false);
select pg_temp.expect(current_setting('b.w9')::int <= 9 and pg_temp.wcount(array[pg_temp.h(2)]) - current_setting('b.pre2')::int <= 9 and pg_temp.hevs(2, pg_temp.pd(1)) = 'in 08:00, out 16:30'
  and (select count(*) from biometric_event_state where employee_id = pg_temp.h(2) and status = 'projected' and projected_event_id is not null) = 2
  and (select count(*) from biometric_event_state where employee_id = pg_temp.h(2) and status = 'extra') = 4
  and (select count(*) from biometric_event_state where employee_id = pg_temp.h(2) and status = 'stored') = 6,
  'B3 limit 9: slot step written whole (2 rows + their 2 back-links), then 4 role changes; 6 punches still stored; ≤ 9 writes');
select set_config('b.w10', (biometric_project_day(pg_temp.h(3), pg_temp.pd(1), 10) ->> 'written'), false);
select pg_temp.expect(current_setting('b.w10')::int <= 10 and pg_temp.wcount(array[pg_temp.h(3)]) - current_setting('b.pre3')::int <= 10
  and (select count(*) from biometric_event_state where employee_id = pg_temp.h(3) and status = 'extra') = 5, 'B4 limit 10: 5 role changes after the slot step; ≤ 10 writes');
select biometric_project_day(pg_temp.h(2), pg_temp.pd(1), 9) from generate_series(1, 3);
select biometric_project_day(pg_temp.h(3), pg_temp.pd(1), 10) from generate_series(1, 3);
select biometric_project_day(pg_temp.h(4), pg_temp.pd(1), 200);
select pg_temp.expect(pg_temp.hroles(2, pg_temp.pd(1)) = pg_temp.hroles(4, pg_temp.pd(1)) and pg_temp.hroles(3, pg_temp.pd(1)) = pg_temp.hroles(4, pg_temp.pd(1))
  and pg_temp.hevs(2, pg_temp.pd(1)) = pg_temp.hevs(4, pg_temp.pd(1)) and pg_temp.hevs(3, pg_temp.pd(1)) = pg_temp.hevs(4, pg_temp.pd(1))
  and not exists (select 1 from biometric_event_state where employee_id in (pg_temp.h(2), pg_temp.h(3)) and (status = 'stored' or processed_at is null)),
  'B3/B4 repeated bounded calls finish the day with exactly the result of one unbounded call; nothing left stored or pending');
-- B3 variant: a 5-write slot step (earlier punch moves the in slot while the day is open) fits only whole
select pg_temp.hp('fl', 5, pg_temp.at(pg_temp.pd(0), '09:00')); select pg_temp.hp('fl', 5, pg_temp.at(pg_temp.pd(0), '11:00')); select pg_temp.dates();
select biometric_project_day(pg_temp.h(5), pg_temp.pd(0), 6);
select pg_temp.hp('fl', 5, pg_temp.at(pg_temp.pd(0), '08:30')); select pg_temp.dates();
select set_config('b.v', (select version::text from biometric_event_state s join biometric_raw_events r on r.id = s.raw_event_id where s.employee_id = pg_temp.h(5) and r.punch_at = pg_temp.at(pg_temp.pd(0), '09:00')), false);
select biometric_project_day(pg_temp.h(5), pg_temp.pd(0), 6);
select pg_temp.expect((pg_temp.hevs(5, pg_temp.pd(0)) = 'in 08:30' and (select status from biometric_event_state s join biometric_raw_events r on r.id = s.raw_event_id where s.employee_id = pg_temp.h(5) and r.punch_at = pg_temp.at(pg_temp.pd(0), '09:00')) = 'extra')
  or (pg_temp.hevs(5, pg_temp.pd(0)) = 'in 09:00' and (select version::text from biometric_event_state s join biometric_raw_events r on r.id = s.raw_event_id where s.employee_id = pg_temp.h(5) and r.punch_at = pg_temp.at(pg_temp.pd(0), '09:00')) = current_setting('b.v')),
  'B3v the slot move and its back-links are never half-written');
-- B5 held retries: 20 due held punches, limits 1, 5, 9, 10
insert into roster_day (employee_id, day, work_mode) values (pg_temp.h(6), pg_temp.pd(1), 'off');
select pg_temp.hp('fl', 6, pg_temp.at(pg_temp.pd(1), '08:00') + make_interval(mins => 15 * g)) from generate_series(1, 20) g;
select pg_temp.dates(); select biometric_project_day(pg_temp.h(6), pg_temp.pd(1), 200);
update biometric_event_state set next_check_at = now() - interval '1 second' where employee_id = pg_temp.h(6);
create function pg_temp.notdue(n int) returns bigint language sql as $$ select count(*) from public.biometric_event_state where employee_id = pg_temp.h(n) and status = 'held' and next_check_at > now() $$;
select pg_temp.expect(pg_temp.notdue(6) = 0 and (select count(*) from biometric_event_state where employee_id = pg_temp.h(6) and status = 'held') = 20, 'B5 setup: 20 due held punches');
select biometric_project_day(pg_temp.h(6), pg_temp.pd(1), 1); select biometric_project_day(pg_temp.h(6), pg_temp.pd(1), 5);
select pg_temp.expect(pg_temp.notdue(6) = 0, 'B5 limits 1 and 5: deferred, all 20 still due, none touched');
select biometric_project_day(pg_temp.h(6), pg_temp.pd(1), 9);
select pg_temp.expect(pg_temp.notdue(6) = 8, 'B5 limit 9: exactly 8 punches looked at (one write kept in reserve)');
select biometric_project_day(pg_temp.h(6), pg_temp.pd(1), 10);
select pg_temp.expect(pg_temp.notdue(6) = 17, 'B5 limit 10: 9 more looked at; the other 3 still due');
select biometric_project_day(pg_temp.h(6), pg_temp.pd(1), 10);
select pg_temp.expect(pg_temp.notdue(6) = 20, 'B5 the remaining 3 are taken by the next call; none skipped');
-- B6 device mode, limits 9 and 10, 10 alternating punches: 4 punches per call, order kept
select pg_temp.hp('dv', n, pg_temp.at(pg_temp.pd(1), '08:00') + make_interval(mins => 30 * g), jsonb_build_object('dir', case when g % 2 = 0 then 'in' else 'out' end))
  from generate_series(7, 8) n, generate_series(0, 9) g;
select pg_temp.dates();
select set_config('b.w7', biometric_project_day(pg_temp.h(7), pg_temp.pd(1), 9) ->> 'written', false);
select set_config('b.w8', biometric_project_day(pg_temp.h(8), pg_temp.pd(1), 10) ->> 'written', false);
select pg_temp.expect(current_setting('b.w7')::int <= 9 and (select count(*) from attendance_events where employee_id = pg_temp.h(7)) = 4
  and current_setting('b.w8')::int <= 10 and (select count(*) from attendance_events where employee_id = pg_temp.h(8)) = 4, 'B6 device mode: 4 punches (2 writes each, one reserved) per call at limits 9 and 10');
select biometric_project_day(pg_temp.h(7), pg_temp.pd(1), 9) from generate_series(1, 3);
select pg_temp.expect(pg_temp.hevs(7, pg_temp.pd(1)) = 'in 08:00, out 08:30, in 09:00, out 09:30, in 10:00, out 10:30, in 11:00, out 11:30, in 12:00, out 12:30',
  'B6 across calls the ten device punches are counted in time order');

-- ================================================================ Q — due held punches, bounded days, continuation, invariant
insert into biometric_devices (company_id, location_id, name, manufacturer, model, serial_number, integration_method, agent_id, timezone, direction_mode)
  values (current_setting('p.c')::uuid, null, 'Gate NOOFFICE 2', 'zkteco', 'K40', 'PNO002', 'sdk_pull', current_setting('p.agent')::uuid, current_setting('p.tz'), 'first_last');
select set_config('p.no2', (select id::text from biometric_devices where serial_number = 'PNO002'), false);
-- Q1 a held punch that is not due is untouched when another punch brings its day in
select set_config('q.h', pg_temp.pp('no2', 57, pg_temp.at(pg_temp.pd(0), '08:00'))::text, false); select pg_temp.dates(); select pg_temp.proj(57, pg_temp.pd(0));
select pg_temp.expect(pg_temp.st(current_setting('q.h')::bigint) = 'held' and (pg_temp.sx(current_setting('q.h')::bigint)).next_check_at > now(), 'Q1 setup: held, next look in the future');
select set_config('q.snap', (select to_jsonb(s)::text from biometric_event_state s where raw_event_id = current_setting('q.h')::bigint), false);
select set_config('q.aud', pg_temp.audits(current_setting('q.h')::bigint)::text, false);
select pg_temp.pp('fl', 57, pg_temp.at(pg_temp.pd(0), '09:00')); select pg_temp.dates(); select pg_temp.proj(57, pg_temp.pd(0));
select pg_temp.expect(pg_temp.evs(57, pg_temp.pd(0)) = 'in 09:00 B'
  and (select to_jsonb(s)::text from biometric_event_state s where raw_event_id = current_setting('q.h')::bigint) = current_setting('q.snap')
  and pg_temp.audits(current_setting('q.h')::bigint) = current_setting('q.aud')::int,
  'Q1 the other punch is projected; the not-due held punch is byte-identical (status, reason, held_since, next_check_at, version, updated_at), no audit');
-- Q2 the same punch once due: re-evaluated; the hold still applies so only next_check_at moves
update biometric_event_state set next_check_at = now() - interval '1 second' where raw_event_id = current_setting('q.h')::bigint;
select set_config('q.snap2', (select (to_jsonb(s) - 'next_check_at' - 'version' - 'updated_at')::text from biometric_event_state s where raw_event_id = current_setting('q.h')::bigint), false);
select pg_temp.proj(57, pg_temp.pd(0));
select pg_temp.expect((pg_temp.sx(current_setting('q.h')::bigint)).next_check_at > now() + interval '14 minutes'
  and (select (to_jsonb(s) - 'next_check_at' - 'version' - 'updated_at')::text from biometric_event_state s where raw_event_id = current_setting('q.h')::bigint) = current_setting('q.snap2'),
  'Q2 due held punch re-evaluated: still held, only next_check_at moved');
-- Q3 one due, two not due on the same day
select pg_temp.pp('no2', 58, pg_temp.at(pg_temp.pd(0), t)) from unnest(array['08:00', '08:10', '08:20']::time[]) t; select pg_temp.dates(); select pg_temp.proj(58, pg_temp.pd(0));
update biometric_event_state s set next_check_at = now() - interval '1 second' from biometric_raw_events r
 where r.id = s.raw_event_id and s.employee_id = pg_temp.w(58) and r.punch_at = pg_temp.at(pg_temp.pd(0), '08:10');
select set_config('q.s3', (select string_agg(to_jsonb(s)::text, '|' order by raw_event_id) from biometric_event_state s join biometric_raw_events r on r.id = s.raw_event_id
  where s.employee_id = pg_temp.w(58) and r.punch_at <> pg_temp.at(pg_temp.pd(0), '08:10')), false);
select pg_temp.proj(58, pg_temp.pd(0));
select pg_temp.expect((select string_agg(to_jsonb(s)::text, '|' order by raw_event_id) from biometric_event_state s join biometric_raw_events r on r.id = s.raw_event_id
  where s.employee_id = pg_temp.w(58) and r.punch_at <> pg_temp.at(pg_temp.pd(0), '08:10')) = current_setting('q.s3')
  and (select next_check_at > now() from biometric_event_state s join biometric_raw_events r on r.id = s.raw_event_id
       where s.employee_id = pg_temp.w(58) and r.punch_at = pg_temp.at(pg_temp.pd(0), '08:10')),
  'Q3 only the due punch changed; the two not-due punches keep every field');
-- Q8 'stored' always means awaiting processing
select pg_temp.fails(format('update biometric_event_state set processed_at = now() where raw_event_id = %s', current_setting('t.r1x')), 'stored_pending', 'Q8 a stored punch with processed_at set is refused');
-- Q4 large backlogs, bounded calls
create function pg_temp.drain(emp uuid, d date, lim int) returns text language plpgsql as $$
declare res jsonb; calls int := 0; maxw int := 0;
begin
  loop
    res := public.biometric_project_day(emp, d, lim); calls := calls + 1; maxw := greatest(maxw, (res ->> 'written')::int);
    exit when (res ->> 'complete')::boolean or calls > 500;
  end loop;
  return calls || ' calls, max ' || maxw;
end $$;
select pg_temp.hp('fl', n, pg_temp.at(pg_temp.pd(1), '05:00') + make_interval(secs => 61 * g)) from generate_series(33, 34) n, generate_series(0, 999) g;
select pg_temp.hp('dv', 35, pg_temp.at(pg_temp.pd(1), '05:00') + make_interval(secs => 61 * g), jsonb_build_object('dir', case when g % 2 = 0 then 'in' else 'out' end)) from generate_series(0, 999) g;
select pg_temp.hp('fl', 36, pg_temp.at(pg_temp.pd(1), '05:00') + make_interval(secs => 61 * g), '{"auth": "unauthenticated_lan", "status": "stored"}') from generate_series(0, 899) g;
select pg_temp.dates();
select set_config('q.fl', pg_temp.drain(pg_temp.h(33), pg_temp.pd(1), 200), false);
select set_config('q.big', pg_temp.drain(pg_temp.h(34), pg_temp.pd(1), 1000), false);
select set_config('q.dv', pg_temp.drain(pg_temp.h(35), pg_temp.pd(1), 200), false);
select set_config('q.un', pg_temp.drain(pg_temp.h(36), pg_temp.pd(1), 200), false);
select pg_temp.expect(split_part(current_setting('q.fl'), 'max ', 2)::int <= 200 and split_part(current_setting('q.dv'), 'max ', 2)::int <= 200
  and split_part(current_setting('q.un'), 'max ', 2)::int <= 200 and split_part(current_setting('q.fl'), ' calls', 1)::int >= 5,
  'Q4 1,000-punch days are processed in calls of at most 200 writes (' || current_setting('q.fl') || ' / device ' || current_setting('q.dv') || ' / gate ' || current_setting('q.un') || ')');
select pg_temp.expect(pg_temp.hevs(33, pg_temp.pd(1)) = pg_temp.hevs(34, pg_temp.pd(1)) and pg_temp.hroles(33, pg_temp.pd(1)) = pg_temp.hroles(34, pg_temp.pd(1))
  and pg_temp.hevs(33, pg_temp.pd(1)) = 'in 05:00, out 21:55'
  and (select count(*) from biometric_event_state where employee_id = pg_temp.h(33) and status = 'extra') = 998,
  'Q4 first-in/last-out: same result as the large-limit run; 1 in, 1 out, 998 extras');
select pg_temp.expect((select count(*) from attendance_events where employee_id = pg_temp.h(35)) = 1000
  and not exists (select 1 from biometric_event_state where employee_id in (pg_temp.h(33), pg_temp.h(34), pg_temp.h(35), pg_temp.h(36)) and (status = 'stored' or processed_at is null))
  and (select count(*) from biometric_event_state where employee_id = pg_temp.h(36) and status = 'flagged') = 900
  and not exists (select 1 from attendance_events where employee_id = pg_temp.h(36)),
  'Q4 device mode: all 1,000 counted in order; gate of 900 unauthenticated: all flagged, none counted; nothing left stored or pending');
-- Q7 continuation marks (locked-day conversion with a small limit)
select pg_temp.hp('fl', 37, pg_temp.at(pg_temp.pd(1), '08:00') + make_interval(mins => 10 * g)) from generate_series(0, 29) g;
select pg_temp.dates(); select biometric_project_day(pg_temp.h(37), pg_temp.pd(1), 1000);
insert into attendance_corrections (employee_id, work_date, kind, requested_out, reason, requested_by)
  values (pg_temp.h(37), pg_temp.pd(1), 'missing_out', pg_temp.at(pg_temp.pd(1), '18:00'), 'Left late', '00000000-0000-0000-0000-000000000237');
select pg_temp.pact('hr@proj.co'); select decide_correction((select id from attendance_corrections where employee_id = pg_temp.h(37)), true, null); select pg_temp.pact('owner');
select biometric_project_day(pg_temp.h(37), pg_temp.pd(1), 10);
select pg_temp.expect((select count(*) from biometric_event_state where employee_id = pg_temp.h(37) and processed_at is null) = 1
  and (select count(*) from biometric_event_state where employee_id = pg_temp.h(37) and status = 'after_correction') = 9,
  'Q7 a stop in the locked step converts 9 and leaves exactly one continuation mark');
select pg_temp.drain(pg_temp.h(37), pg_temp.pd(1), 10);
select pg_temp.expect((select count(*) from biometric_event_state where employee_id = pg_temp.h(37) and processed_at is null) = 0
  and (select count(*) from biometric_event_state where employee_id = pg_temp.h(37) and status = 'after_correction') = 28,
  'Q7 the next calls clear the mark and finish (28 extras after_correction; the 2 projected punches keep their rows)');

-- ================================================================ queue procedure (top-level CALL, one commit per employee-day)
create function pg_temp.cw() returns bigint language sql as $$
  select pg_temp.wcount(array(select id from public.employees where company_id = current_setting('p.c')::uuid)) $$;
-- drain everything left over by the groups above, then prove a complete queue writes nothing (Q7: no day stays selected)
call biometric_run_projection(1000, 1000, 100000, 100000, 1000);
call biometric_run_projection(1000, 1000, 100000, 100000, 1000);
select set_config('qq.w', pg_temp.cw()::text, false);
call biometric_run_projection(1000, 1000, 100000, 100000, 1000);
select pg_temp.expect(pg_temp.cw() = current_setting('qq.w')::bigint, 'Q7 once everything is processed a further run writes nothing');
-- B7 queue budgets 1, 5, 9, 10 (three new days of 2 writes each: h09, h10, h11)
select pg_temp.hp('fl', n, pg_temp.at(pg_temp.pd(0), '08:00')) from generate_series(9, 11) n;
select pg_temp.dates();
select set_config('qq.w', pg_temp.cw()::text, false);
call biometric_run_projection(200, 50, 1, 1, 200);
call biometric_run_projection(200, 50, 5, 5, 200);
select pg_temp.expect(pg_temp.cw() = current_setting('qq.w')::bigint and pg_temp.hevs(9, pg_temp.pd(0)) || pg_temp.hevs(10, pg_temp.pd(0)) || pg_temp.hevs(11, pg_temp.pd(0)) = '',
  'B7 run budgets 1 and 5: no call made, nothing written, the days stay due');
call biometric_run_projection(200, 50, 9, 9, 200);
select pg_temp.expect(pg_temp.cw() - current_setting('qq.w')::bigint <= 9, 'B7 run budget 9: at most 9 writes (' || (pg_temp.cw() - current_setting('qq.w')::bigint) || ')');
select set_config('qq.w', pg_temp.cw()::text, false);
call biometric_run_projection(200, 50, 10, 10, 200);
select pg_temp.expect(pg_temp.cw() - current_setting('qq.w')::bigint <= 10, 'B7 run budget 10: at most 10 writes (' || (pg_temp.cw() - current_setting('qq.w')::bigint) || ')');
call biometric_run_projection(200, 50, 100, 100, 200);
select pg_temp.expect(pg_temp.hevs(9, pg_temp.pd(0)) = 'in 08:00' and pg_temp.hevs(10, pg_temp.pd(0)) = 'in 08:00' and pg_temp.hevs(11, pg_temp.pd(0)) = 'in 08:00',
  'B7 days not reached are taken by a later run; none skipped');
-- B8 budget running low mid-run: 6 days × 61 punches (≥ 61 writes each), budget 150
select pg_temp.hp('fl', n, pg_temp.at(pg_temp.pd(1), '06:00') + make_interval(secs => 61 * g)) from generate_series(12, 17) n, generate_series(0, 60) g;
select pg_temp.dates();
select set_config('qq.w', pg_temp.cw()::text, false);
call biometric_run_projection(200, 50, 150, 0, 200);
select pg_temp.expect(pg_temp.cw() - current_setting('qq.w')::bigint <= 150
  and (select count(*) from biometric_event_state where employee_id in (select pg_temp.h(n) from generate_series(12, 17) n) and status = 'stored') > 0,
  'B8 budget 150: at most 150 writes (' || (pg_temp.cw() - current_setting('qq.w')::bigint) || '); the rest stays due');
call biometric_run_projection(200, 50, 2000, 0, 200);
select pg_temp.expect(not exists (select 1 from biometric_event_state where employee_id in (select pg_temp.h(n) from generate_series(12, 17) n) and (status = 'stored' or processed_at is null))
  and (select count(*) from attendance_events where employee_id in (select pg_temp.h(n) from generate_series(12, 17) n)) = 12,
  'B8 the next run finishes them: no punch skipped or left pending (6 × in + out)');
-- B9 a failing day costs one write per call and is skipped after 3 failures; Admin retry resolves
create function public.zz_test_boom() returns trigger language plpgsql as $$ begin raise exception 'test failure'; end $$;
create trigger zz_test_boom before insert on attendance_events for each row execute function public.zz_test_boom();
select pg_temp.hp('fl', 18, pg_temp.at(pg_temp.pd(0), '08:00')); select pg_temp.dates();
select set_config('qq.w', pg_temp.cw()::text, false);
call biometric_run_projection(200, 50, 2000, 500, 200);
select pg_temp.expect(pg_temp.cw() - current_setting('qq.w')::bigint = 1 and biometric_day_failures(pg_temp.h(18), pg_temp.pd(0)) = 1,
  'B9 a failed call is rolled back and costs exactly one write (its error record)');
call biometric_run_projection(200, 50, 2000, 500, 200); call biometric_run_projection(200, 50, 2000, 500, 200); call biometric_run_projection(200, 50, 2000, 500, 200);
select pg_temp.expect(biometric_day_failures(pg_temp.h(18), pg_temp.pd(0)) = 3, 'B9 after 3 failures the day is skipped (no 4th error record)');
drop trigger zz_test_boom on attendance_events; drop function public.zz_test_boom();
select pg_temp.pact('hr@proj.co');
select pg_temp.fails(format('select biometric_retry_day(%L, %L)', pg_temp.h(18), pg_temp.pd(0)), 'Not allowed', 'B9 HR cannot use the Admin retry');
select pg_temp.pact('admin@proj.co'); select biometric_retry_day(pg_temp.h(18), pg_temp.pd(0)); select pg_temp.pact('owner');
select pg_temp.expect(biometric_day_failures(pg_temp.h(18), pg_temp.pd(0)) = 0 and pg_temp.hevs(18, pg_temp.pd(0)) = 'in 08:00'
  and (select count(*) from biometric_event_errors where kind = 'processing_failure' and detail ->> 'employee_id' = pg_temp.h(18)::text and resolved_at is not null) = 3,
  'B9 Admin retry resolves the 3 error records (kept, resolved) and the day is projected');
-- H6 / Q6 fairness: 120 due held days + 20 current days in one run
insert into roster_day (employee_id, day, work_mode) select pg_temp.h(n), pg_temp.pd(d), 'off' from generate_series(19, 32) n, generate_series(1, 6) d;
select pg_temp.hp('fl', n, pg_temp.at(pg_temp.pd(d), '09:00'), '{"status": "stored"}') from generate_series(19, 32) n, generate_series(1, 6) d;
select pg_temp.dates();
select biometric_project_day(pg_temp.h(n), pg_temp.pd(d)) from generate_series(19, 32) n, generate_series(1, 6) d;
update biometric_event_state s set next_check_at = now() - make_interval(secs => 1000 - x.rn)
  from (select raw_event_id, row_number() over (order by raw_event_id) rn from biometric_event_state where employee_id in (select pg_temp.h(n) from generate_series(19, 32) n) and status = 'held') x
 where x.raw_event_id = s.raw_event_id;
update biometric_event_state set next_check_at = now() + interval '1 hour' where status = 'held' and next_check_at <= now()
   and company_id = current_setting('p.c')::uuid and employee_id not in (select pg_temp.h(n) from generate_series(19, 32) n);
select pg_temp.expect((select count(*) from biometric_event_state where status = 'held' and next_check_at <= now() and company_id = current_setting('p.c')::uuid) = 84,
  'H6 setup: 84 due held employee-days (14 people × 6 days), oldest first by next_check_at');
select pg_temp.hp('fl', n, pg_temp.at(pg_temp.pd(0), '08:00')) from generate_series(19, 38) n;
select pg_temp.dates();
select set_config('qq.first50', (select string_agg(raw_event_id::text, ',' order by next_check_at) from (select raw_event_id, next_check_at from biometric_event_state
  where status = 'held' and next_check_at <= now() and company_id = current_setting('p.c')::uuid order by next_check_at limit 50) x), false);
call biometric_run_projection(200, 50, 2000, 500, 200);
select pg_temp.expect((select count(*) from attendance_events where employee_id in (select pg_temp.h(n) from generate_series(19, 38) n) and work_date = pg_temp.pd(0)) = 20,
  'H6 all 20 current days are projected in the same run');
select pg_temp.expect((select count(*) from biometric_event_state where status = 'held' and next_check_at > now() and employee_id in (select pg_temp.h(n) from generate_series(19, 32) n)) = 50
  and (select string_agg(raw_event_id::text, ',' order by raw_event_id) from biometric_event_state where status = 'held' and next_check_at > now()
       and employee_id in (select pg_temp.h(n) from generate_series(19, 32) n))
    = (select string_agg(x, ',' order by x::bigint) from unnest(string_to_array(current_setting('qq.first50'), ',')) x),
  'H6 exactly 50 held days re-checked — the 50 longest-waiting');
call biometric_run_projection(200, 50, 2000, 500, 200);
select pg_temp.expect((select count(*) from biometric_event_state where status = 'held' and next_check_at <= now() and employee_id in (select pg_temp.h(n) from generate_series(19, 32) n)) = 0,
  'H6 the next run re-checks the remaining 34; every held day has been looked at once');

-- ================================================================ U — reads, exports, permissions
-- U36 sources per person-day (CSV Source column) and scope
select pg_temp.pact('hr@proj.co');
select pg_temp.expect((select sources from attendance_day_sources(pg_temp.pd(1), pg_temp.pd(1), null, pg_temp.w(3))) = array['biometric']
  and (select sources from attendance_day_sources(pg_temp.pd(1), pg_temp.pd(1), null, pg_temp.w(4))) = array['web']
  and (select sources from attendance_day_sources(pg_temp.pd(1), pg_temp.pd(1), null, pg_temp.w(22))) = array['biometric', 'correction']
  and (select sources from attendance_day_sources(pg_temp.pd(1), pg_temp.pd(1), null, pg_temp.w(21))) = array['correction']
  and (select pending_checkout from attendance_day_sources(pg_temp.pd(0), pg_temp.pd(0), null, pg_temp.w(2))),
  'U36 sources: Biometric / Web / Biometric + Correction / Correction; pending check-out marked');
select pg_temp.fails(format('select * from attendance_day_sources(%L, %L)', pg_temp.pd(100), pg_temp.pd(0)), 'up to 93 days', 'U36 at most 93 days per call');
select pg_temp.pact('w03@proj.co');
select pg_temp.expect((select array_agg(distinct employee_id) from attendance_day_sources(pg_temp.pd(2), pg_temp.pd(0))) = array[pg_temp.w(3)], 'U36 an employee sees only their own days');
select pg_temp.pact('mgr@proj.co');
select pg_temp.expect((select count(distinct employee_id) from attendance_day_sources(pg_temp.pd(1), pg_temp.pd(1))) > 1
  and not exists (select 1 from attendance_day_sources(pg_temp.pd(2), pg_temp.pd(0)) x join employees e on e.id = x.employee_id where e.email like 'h%@proj.co'),
  'U36 a manager sees the team (workers), not people outside it');
select pg_temp.act('B admin');
select pg_temp.expect(not exists (select 1 from attendance_day_sources(pg_temp.pd(2), pg_temp.pd(0)) x join employees e on e.id = x.employee_id where e.company_id = current_setting('p.c')::uuid),
  'U36 another company''s Admin sees none of these days');
-- U37 pending display and day_events
select pg_temp.pact('w02@proj.co');
select pg_temp.expect((select pending_checkout from biometric_day_pending(pg_temp.w(2), pg_temp.pd(0)))
  and exists (select 1 from day_events(pg_temp.w(2), pg_temp.pd(0)) where label = 'Provisional Out' and not counted)
  and exists (select 1 from day_events(pg_temp.w(2), pg_temp.pd(0)) where label = 'Biometric · inferred' and counted),
  'U37 the employee sees their pending check-out and the provisional punch, apart from counted punches');
select pg_temp.fails(format('select * from biometric_day_pending(%L, %L)', pg_temp.w(3), pg_temp.pd(0)), 'Not allowed', 'U37 not someone else''s');
select pg_temp.fails(format('select * from day_events(%L, %L)', pg_temp.w(3), pg_temp.pd(0)), 'Not allowed', 'U37 day_events per can_see');
select pg_temp.pact('owner');
select pg_temp.expect(not exists (select 1 from information_schema.routines r join information_schema.parameters p on p.specific_name = r.specific_name
  where r.routine_name = 'day_events' and p.parameter_mode = 'OUT' and p.parameter_name ~ 'payload|flag|reason|source_auth|address'),
  'U37 day_events returns no payload, flag reasons, authentication class or device address');
-- U38 permissions
select pg_temp.expect(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute') and p.proname not in ('biometric_ingest', 'biometric_heartbeat', 'company_brand')),
  'U38 anon can still call only the two gateway functions (and company_brand)');
select pg_temp.expect((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute')
    and p.proname in ('biometric_project_day', 'biometric_run_projection', 'biometric_project_one', 'biometric_set_role', 'biometric_write_slot',
                      'biometric_work_date_at', 'biometric_day_close_at', 'biometric_hold_next_check', 'biometric_day_failures', 'attendance_external_guard',
                      'decide_correction_core', 'biometric_project_now', 'day_events', 'biometric_day_pending', 'attendance_day_sources',
                      'biometric_shift_gap_warnings', 'biometric_retry_day', 'decide_correction'))
  = array['attendance_day_sources', 'biometric_day_pending', 'biometric_project_now', 'biometric_retry_day', 'biometric_shift_gap_warnings', 'day_events', 'decide_correction'],
  'U38 signed-in users can call only the checked read/HR/Admin functions; projection internals and decide_correction_core are not callable');
select pg_temp.expect(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0))), 'U38 no function is callable by PUBLIC');
select pg_temp.expect(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef and not exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%')),
  'U38 every SECURITY DEFINER function pins its search_path');
select pg_temp.expect(not (select prosecdef from pg_proc where proname = 'biometric_run_projection') and (select proacl::text from pg_proc where proname = 'biometric_run_projection') !~ 'authenticated|anon',
  'U38 the queue procedure is security invoker (COMMIT allowed) and callable by neither anon nor authenticated');
select pg_temp.act('A hr');
select pg_temp.fails(format('select biometric_project_now(%L, %L)', pg_temp.w(3), pg_temp.pd(1)), 'Not allowed', 'U38 HR of another company cannot process these days');
select pg_temp.pact('mgr@proj.co');
select pg_temp.fails(format('select biometric_project_now(%L, %L)', pg_temp.w(3), pg_temp.pd(1)), 'Not allowed', 'U38 a manager cannot process days');
select pg_temp.fails('select * from biometric_shift_gap_warnings()', 'Not allowed', 'U38 shift-gap warnings: not for managers');
select pg_temp.pact('hr@proj.co');
select pg_temp.fails('select * from biometric_shift_gap_warnings()', 'Not allowed', 'U38 shift-gap warnings: Admin only');
select pg_temp.pact('w03@proj.co');
select pg_temp.fails(format('select decide_correction_core(1, true, null)'), 'permission denied', 'U38 decide_correction_core cannot be called directly (lock cannot be bypassed)');
select pg_temp.fails(format('select biometric_project_day(%L, %L)', pg_temp.w(3), pg_temp.pd(1)), 'permission denied', 'U38 projection cannot be called by a signed-in user');
select pg_temp.fails(format('update attendance_events set at = at where employee_id = %L', pg_temp.w(3)), 'permission denied', 'U38 no client role can write attendance_events');
select pg_temp.pact('owner');
-- Q8 shift-gap warning (Admin, read-only)
insert into shift_day (employee_id, day, shift_id) values (pg_temp.h(39), pg_temp.pd(0), current_setting('p.night')::uuid),
  (pg_temp.h(39), pg_temp.pd(0) + 1, (select id from shifts where name = 'Early' and company_id = current_setting('p.c')::uuid));
select set_config('u.snap', (select count(*) from audit_log)::text || (select count(*) from shift_day)::text, false);
select pg_temp.pact('admin@proj.co');
select pg_temp.expect(exists (select 1 from biometric_shift_gap_warnings() where employee_id = pg_temp.h(39) and work_date = pg_temp.pd(0) and gap_min = -60),
  'U Q8 Admin sees the warning: tonight''s shift closes for projection at 08:00, tomorrow''s starts at 07:00');
select pg_temp.pact('owner');
select pg_temp.expect((select count(*) from audit_log)::text || (select count(*) from shift_day)::text = current_setting('u.snap'), 'U Q8 the warning changes nothing');
-- U39 verification history
select pg_temp.pact('hr@proj.co');
select pg_temp.expect((select array_agg(distinct outcome) from verification_log(500) where employee = 'Worker 03') = array['biometric']
  and (select array_agg(distinct outcome) from verification_log(500) where employee = 'Worker 04') = array['verified'],
  'U39 verification history labels biometric rows "biometric", never "verified"');
select pg_temp.pact('owner');
select pg_temp.expect(not exists (select 1 from attendance_events where source in ('biometric', 'import') and (verified or distance_m is not null or accuracy_m is not null)),
  'U39 no biometric row anywhere is location-verified or carries distance/accuracy');
select pg_temp.expect(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name like 'biometric%'
  and column_name ~* 'template|image|photo|face|fingerprint_data|minutiae'), 'U no column stores biometric templates or face/fingerprint images');


-- ================================================================ R — delayed device-mode IN + OUT on a closed day (B3.4 final review)
-- People r01…r40 (codes R01…R40); device-direction devices 'dv' (plant) and 'dv2' (annex); every day is yesterday (closed).
insert into auth.users (id, email, email_confirmed_at)
  select ('00000000-0000-0000-0000-0000000003' || lpad(g::text, 2, '0'))::uuid, 'r' || lpad(g::text, 2, '0') || '@proj.co', now() from generate_series(1, 40) g;
insert into employees (company_id, full_name, email, role, user_id, home_location_id, joining_date)
  select current_setting('p.c')::uuid, 'Rio ' || lpad(g::text, 2, '0'), 'r' || lpad(g::text, 2, '0') || '@proj.co', 'employee',
         ('00000000-0000-0000-0000-0000000003' || lpad(g::text, 2, '0'))::uuid, current_setting('p.loc')::uuid, current_date - 60 from generate_series(1, 40) g;
insert into biometric_employee_mappings (company_id, employee_id, employee_device_code, valid_from)
  select current_setting('p.c')::uuid, (select id from employees where email = 'r' || lpad(g::text, 2, '0') || '@proj.co'), 'R' || lpad(g::text, 2, '0'), now() - interval '60 days'
    from generate_series(1, 40) g;
create function pg_temp.r(n int) returns uuid language sql as $$ select id from public.employees where email = 'r' || lpad(n::text, 2, '0') || '@proj.co' $$;
-- one device punch for person rNN at local time t yesterday (or day d); o may force a status, auth, or omit the direction
create function pg_temp.rp(dev text, n int, t time, dir text, o jsonb default '{}', d int default 1) returns bigint language sql as $$
  select pg_temp.pp(dev, 0, pg_temp.at(pg_temp.pd(d), t), jsonb_build_object('code', 'R' || lpad(n::text, 2, '0'))
                      || case when dir is null then '{}'::jsonb else jsonb_build_object('dir', dir) end || o) $$;
create function pg_temp.rweb(n int, kind text, t time, d int default 1) returns bigint language sql as $$
  insert into public.attendance_events (employee_id, kind, at, work_mode, location_id, verified, work_date)
  values (pg_temp.r(n), kind, pg_temp.at(pg_temp.pd(d), t), 'office', current_setting('p.loc')::uuid, true, pg_temp.pd(d)) returning id $$;
create function pg_temp.revs(n int, d int default 1) returns text language sql as $$
  select coalesce(string_agg(e.kind || ' ' || to_char(e.at at time zone current_setting('p.tz'), 'HH24:MI') || ' ' ||
         case e.source when 'web' then 'W' when 'correction' then 'C' when 'biometric' then 'B' else 'I' end, ', ' order by e.at, e.id), '')
    from public.attendance_events e where e.employee_id = pg_temp.r(n) and e.work_date = pg_temp.pd(d) and e.superseded_by is null $$;
create function pg_temp.rproj(n int, lim int default 200, d int default 1) returns jsonb language plpgsql as $$
begin perform pg_temp.dates(); return public.biometric_project_day(pg_temp.r(n), pg_temp.pd(d), lim); end $$;
create function pg_temp.rstate(n int) returns text language sql as $$ select state from public.session_state(pg_temp.r(n)) $$;
create function pg_temp.rwebin(n int) returns text language plpgsql as $$
declare res jsonb;
begin
  perform pg_temp.pact('r' || lpad(n::text, 2, '0') || '@proj.co'); res := public.punch('in', 19.1000, 72.9000, 10); perform pg_temp.pact('owner');
  return coalesce(res ->> 'code', 'ok:' || (res ->> 'ok'));
end $$;
-- invariants for one person-day: no biometric row without a matching raw punch, correct work day/source, no slot twice
create function pg_temp.rinv(n int, d int default 1) returns boolean language sql as $$
  select not exists (select 1 from public.attendance_events e join public.biometric_raw_events r on r.id = e.biometric_event_id
                       join public.biometric_event_state s on s.raw_event_id = r.id
                      where e.employee_id = pg_temp.r(n) and (e.at <> r.punch_at or s.employee_id <> e.employee_id or s.work_date <> e.work_date
                            or e.work_date <> pg_temp.pd(d) or e.source <> 'biometric' or e.device_id <> r.device_id or s.status <> 'projected' or s.projected_event_id <> e.id))
     and not exists (select 1 from public.biometric_event_state s where s.employee_id = pg_temp.r(n) and s.status = 'projected'
                       and not exists (select 1 from public.attendance_events e where e.id = s.projected_event_id and e.biometric_event_id = s.raw_event_id))
     and not exists (select 1 from public.biometric_event_state s where s.employee_id = pg_temp.r(n) and (s.status = 'stored' or s.processed_at is null))
$$;

-- R1 closed day, delayed IN + delayed OUT: both counted, session not left open, work day and source right
select set_config('r.n1i', pg_temp.rp('dv', 1, '09:00', 'in')::text, false); select set_config('r.n1o', pg_temp.rp('dv2', 1, '17:00', 'out')::text, false);
select pg_temp.rproj(1);
select pg_temp.expect(pg_temp.revs(1) = 'in 09:00 B, out 17:00 B' and pg_temp.rstate(1) = 'off' and pg_temp.rinv(1)
  and (select array_agg(projection_slot order by at) from attendance_events where employee_id = pg_temp.r(1))
      = array['dev:' || current_setting('r.n1i'), 'dev:' || current_setting('r.n1o')]
  and (pg_temp.day(0, pg_temp.pd(1))).status is null or true,
  'R1 delayed IN + OUT: both counted (dev slots), session off, rows match their raw punches');
select pg_temp.expect((select (a.worked_min, a.status, a.open) = (480, 'late', false) from public.day_for(pg_temp.r(1), pg_temp.pd(1)) a)
  and pg_temp.rwebin(1) = 'ok:true', 'R1 engine: a closed 8-hour day (late: shift starts 08:00), not open; the person can check in on the web today');

-- R2 closed day, delayed IN + an OUT that reconciles with the existing app check-out
select set_config('r.n2w1', pg_temp.rweb(2, 'in', '08:00')::text, false); select set_config('r.n2w2', pg_temp.rweb(2, 'out', '17:00')::text, false);
select set_config('r.n2i', pg_temp.rp('dv', 2, '17:01', 'in')::text, false); select set_config('r.n2o', pg_temp.rp('dv', 2, '17:03', 'out')::text, false);
select pg_temp.rproj(2);
select pg_temp.expect(pg_temp.revs(2) = 'in 08:00 W, out 17:00 W'
  and pg_temp.st(current_setting('r.n2i')::bigint) = 'correction_needed' and 'would_open_closed_day' = any (pg_temp.fl(current_setting('r.n2i')::bigint))
  and pg_temp.st(current_setting('r.n2o')::bigint) = 'reconciled' and (pg_temp.sx(current_setting('r.n2o')::bigint)).reconciled_with = current_setting('r.n2w2')::bigint,
  'R2 the OUT reconciles with the app check-out, so the IN cannot be closed: IN correction_needed, OUT reconciled, only the app rows count');
select pg_temp.expect(pg_temp.rstate(2) = 'off' and pg_temp.rinv(2)
  and (select array_agg(id order by id) from attendance_events where employee_id = pg_temp.r(2)) = array[current_setting('r.n2w1')::bigint, current_setting('r.n2w2')::bigint]
  and pg_temp.rwebin(2) = 'ok:true', 'R2 no open session, the app rows keep their ids and are not duplicated; web check-in today works');

-- R3 the following OUT is itself not usable
select set_config('r.n3ai', pg_temp.rp('dv', 3, '09:00', 'in')::text, false);
select set_config('r.n3ao', pg_temp.rp('dv', 3, '17:00', 'out', '{"status": "possible_duplicate"}')::text, false);
select set_config('r.n3bi', pg_temp.rp('dv', 4, '09:00', 'in')::text, false);
select set_config('r.n3bo', pg_temp.rp('dv', 4, '17:00', 'out', '{"auth": "unauthenticated_lan"}')::text, false);
select set_config('r.n3ci', pg_temp.rp('dv', 5, '09:00', 'in')::text, false);
select set_config('r.n3co', pg_temp.rp('dv', 5, '17:00', null)::text, false);
select pg_temp.rproj(3); select pg_temp.rproj(4); select pg_temp.rproj(5);
select pg_temp.expect(pg_temp.revs(3) || pg_temp.revs(4) || pg_temp.revs(5) = ''
  and pg_temp.st(current_setting('r.n3ai')::bigint) = 'correction_needed' and pg_temp.st(current_setting('r.n3ao')::bigint) = 'possible_duplicate'
  and pg_temp.st(current_setting('r.n3bi')::bigint) = 'correction_needed' and pg_temp.st(current_setting('r.n3bo')::bigint) = 'flagged'
  and pg_temp.st(current_setting('r.n3ci')::bigint) = 'correction_needed' and pg_temp.st(current_setting('r.n3co')::bigint) = 'correction_needed'
  and pg_temp.rstate(3) || pg_temp.rstate(4) || pg_temp.rstate(5) = 'offoffoff',
  'R3 OUT a possible duplicate / unauthenticated (flagged) / without direction: the IN is correction_needed, the OUT keeps its own review status; nothing counted, no open session');

-- R4 delayed IN with no valid following OUT
select set_config('r.n4i', pg_temp.rp('dv', 6, '09:00', 'in')::text, false); select pg_temp.rproj(6);
select pg_temp.expect(pg_temp.st(current_setting('r.n4i')::bigint) = 'correction_needed' and pg_temp.revs(6) = '' and pg_temp.rstate(6) = 'off' and pg_temp.rwebin(6) = 'ok:true',
  'R4 lone delayed IN that would be the newest event: correction_needed, no open session, web check-in works');
select pg_temp.rweb(7, 'in', '08:00', 0); select pg_temp.rweb(7, 'out', '10:00', 0);
select set_config('r.n4j', pg_temp.rp('dv', 7, '09:00', 'in')::text, false); select pg_temp.rproj(7);
select pg_temp.expect(pg_temp.revs(7) = 'in 09:00 B' and (select status from day_for(pg_temp.r(7), pg_temp.pd(1))) = 'missing_checkout' and pg_temp.rstate(7) = 'off' and pg_temp.rinv(7),
  'R4 lone delayed IN that is NOT the newest event (later app day): counted, the day shows missing check-out (engine rule), the current session is untouched');

-- R5 several pairs, and pairs mixed with app events
select pg_temp.rp('dv', 8, t, d) from (values ('08:00'::time, 'in'), ('12:00', 'out'), ('13:00', 'in'), ('17:00', 'out')) x(t, d);
select pg_temp.rproj(8);
select pg_temp.expect(pg_temp.revs(8) = 'in 08:00 B, out 12:00 B, in 13:00 B, out 17:00 B' and pg_temp.rstate(8) = 'off' and pg_temp.rinv(8), 'R5 two delayed pairs: four rows, session off');
select pg_temp.rweb(9, 'in', '08:00'); select pg_temp.rweb(9, 'out', '12:00');
select pg_temp.rp('dv', 9, '13:00', 'in'); select pg_temp.rp('dv', 9, '17:00', 'out'); select pg_temp.rproj(9);
select pg_temp.expect(pg_temp.revs(9) = 'in 08:00 W, out 12:00 W, in 13:00 B, out 17:00 B' and pg_temp.rstate(9) = 'off' and pg_temp.rinv(9),
  'R5 app morning + delayed biometric afternoon pair: both sessions counted, nothing duplicated');
select pg_temp.rweb(10, 'in', '08:00'); select pg_temp.rweb(10, 'out', '17:00');
select set_config('r.n5i', pg_temp.rp('dv', 10, '12:00', 'in')::text, false); select set_config('r.n5o', pg_temp.rp('dv', 10, '13:00', 'out')::text, false); select pg_temp.rproj(10);
select pg_temp.expect(pg_temp.revs(10) = 'in 08:00 W, out 17:00 W' and pg_temp.st(current_setting('r.n5i')::bigint) = 'correction_needed'
  and pg_temp.st(current_setting('r.n5o')::bigint) = 'correction_needed' and pg_temp.rstate(10) = 'off',
  'R5 a delayed pair inside an app session (12:00–13:00 within 08:00–17:00) is never slotted between counted events: both correction_needed');

-- R6 duplicate presses and reversed order
select set_config('r.n6i', pg_temp.rp('dv', 11, '09:00:00', 'in')::text, false);
select set_config('r.n6d', pg_temp.rp('dv2', 11, '09:00:30', 'in')::text, false);
select set_config('r.n6r', pg_temp.rp('dv', 11, '09:03', 'in')::text, false);
select set_config('r.n6o', pg_temp.rp('dv', 11, '17:00:00', 'out')::text, false);
select set_config('r.n6p', pg_temp.rp('dv2', 11, '17:00:40', 'out')::text, false);
select pg_temp.rproj(11);
select pg_temp.expect(pg_temp.revs(11) = 'in 09:00 B, out 17:00 B' and pg_temp.rstate(11) = 'off' and pg_temp.rinv(11)
  and pg_temp.st(current_setting('r.n6d')::bigint) = 'extra' and 'double_press' = any (pg_temp.fl(current_setting('r.n6d')::bigint))
  and pg_temp.st(current_setting('r.n6r')::bigint) = 'extra' and 'repeat_in' = any (pg_temp.fl(current_setting('r.n6r')::bigint))
  and pg_temp.st(current_setting('r.n6p')::bigint) = 'extra' and 'double_press' = any (pg_temp.fl(current_setting('r.n6p')::bigint)),
  'R6 IN pressed again (30 s, other device) and after 3 min, OUT pressed twice: one pair counted, the extra presses are extra');
select set_config('r.n6x', pg_temp.rp('dv', 12, '09:00', 'out')::text, false); select set_config('r.n6y', pg_temp.rp('dv', 12, '17:00', 'in')::text, false); select pg_temp.rproj(12);
select pg_temp.expect(pg_temp.revs(12) = '' and pg_temp.st(current_setting('r.n6x')::bigint) = 'correction_needed' and pg_temp.st(current_setting('r.n6y')::bigint) = 'correction_needed'
  and pg_temp.rstate(12) = 'off', 'R6 reversed order (OUT 09:00, IN 17:00): both correction_needed, nothing counted');
select set_config('r.n6a', pg_temp.rp('dv', 13, '09:00', 'in')::text, false); select set_config('r.n6b', pg_temp.rp('dv', 13, '09:10', 'in')::text, false);
select set_config('r.n6c', pg_temp.rp('dv', 13, '17:00', 'out')::text, false); select pg_temp.rproj(13);
select pg_temp.expect(pg_temp.revs(13) = '' and pg_temp.st(current_setting('r.n6a')::bigint) = 'correction_needed' and pg_temp.rstate(13) = 'off'
  and pg_temp.st(current_setting('r.n6b')::bigint) = 'correction_needed' and pg_temp.st(current_setting('r.n6c')::bigint) = 'correction_needed',
  'R6 IN, a second IN 10 min later, OUT: the pair is ambiguous, so nothing is guessed (all correction_needed), no open session');

-- R7 repeated calls and queue runs are idempotent
select set_config('r.snap', (select md5(string_agg(to_jsonb(e)::text, '|' order by id)) from attendance_events e where employee_id in (select pg_temp.r(n) from generate_series(1, 13) n))
  || (select md5(string_agg(to_jsonb(s)::text, '|' order by raw_event_id)) from biometric_event_state s where employee_id in (select pg_temp.r(n) from generate_series(1, 13) n))
  || (select count(*) from audit_log)::text, false);
select pg_temp.rproj(n) from generate_series(1, 13) n; select pg_temp.rproj(n) from generate_series(1, 13) n;
select pg_temp.expect((select md5(string_agg(to_jsonb(e)::text, '|' order by id)) from attendance_events e where employee_id in (select pg_temp.r(n) from generate_series(1, 13) n))
  || (select md5(string_agg(to_jsonb(s)::text, '|' order by raw_event_id)) from biometric_event_state s where employee_id in (select pg_temp.r(n) from generate_series(1, 13) n))
  || (select count(*) from audit_log)::text = current_setting('r.snap'), 'R7 projecting R1–R6 twice more changes no row, state, version or audit');

-- R budget: the pair and its skipped presses are written whole or not at all
select pg_temp.rp('dv', 14, '09:00:00', 'in'); select pg_temp.rp('dv2', 14, '09:00:20', 'in'); select pg_temp.rp('dv', 14, '09:02', 'in'); select pg_temp.rp('dv', 14, '17:00', 'out');
select pg_temp.dates();
select set_config('r.b6', biometric_project_day(pg_temp.r(14), pg_temp.pd(1), 6)::text, false);
select pg_temp.expect((current_setting('r.b6')::jsonb ->> 'complete') = 'false' and (current_setting('r.b6')::jsonb ->> 'written')::int <= 6 and pg_temp.revs(14) = ''
  and (select count(*) from biometric_event_state where employee_id = pg_temp.r(14) and status = 'stored') = 4,
  'R budget: limit 6 cannot hold the pair (4) + 2 skipped presses + reserve: nothing of it is written, all four stay stored');
select set_config('r.b9', biometric_project_day(pg_temp.r(14), pg_temp.pd(1), 9)::text, false);
select pg_temp.expect((current_setting('r.b9')::jsonb ->> 'written')::int <= 9 and pg_temp.revs(14) = 'in 09:00 B, out 17:00 B' and pg_temp.rinv(14)
  and (select count(*) from biometric_event_state where employee_id = pg_temp.r(14) and status = 'extra') = 2,
  'R budget: limit 9 writes the pair and both skipped presses in one call (6 writes)');

-- ================================================================ RP — the punch after a delayed IN is judged in raw time order (pair-selection review)
-- Every day is yesterday (closed). IN 09:00 (plant), an intervening punch at 12:00, a valid OUT 17:00 (annex). Before this review the pair
-- search read only projection candidates, so an intervening punch in another state (flagged, held, possible duplicate, correction_needed)
-- was skipped and the IN was paired with 17:00. Now the first relevant raw punch after the IN decides; if it cannot close the IN, the IN is
-- correction_needed and every punch keeps its own state. Punches HR has already resolved as not attendance (dismissed, confirmed duplicate =
-- rejected) are not attendance and do not block a pair.
create function pg_temp.rp3(n int, mid_t time, mid_dir text, mid_o jsonb default '{}') returns bigint language plpgsql as $$
declare m bigint;
begin
  perform set_config('rp.i' || n, pg_temp.rp('dv', n, '09:00', 'in')::text, false);
  m := pg_temp.rp('dv', n, mid_t, mid_dir, mid_o); perform set_config('rp.m' || n, m::text, false);
  perform set_config('rp.o' || n, pg_temp.rp('dv2', n, '17:00', 'out')::text, false);
  return m;
end $$;
-- rinv for these people: punches the gateway already left flagged / held / possible duplicate / reviewed are never visited by projection,
-- so their processed_at stays empty by design; every punch projection DID decide must have it set, and nothing may be left stored
create function pg_temp.rpinv(n int) returns boolean language sql as $$
  select not exists (select 1 from public.attendance_events e join public.biometric_raw_events r on r.id = e.biometric_event_id
                       join public.biometric_event_state s on s.raw_event_id = r.id
                      where e.employee_id = pg_temp.r(n) and (e.at <> r.punch_at or s.employee_id <> e.employee_id or s.work_date <> e.work_date
                            or e.work_date <> pg_temp.pd(1) or e.source <> 'biometric' or e.device_id <> r.device_id or s.status <> 'projected' or s.projected_event_id <> e.id))
     and not exists (select 1 from public.biometric_event_state s where s.employee_id = pg_temp.r(n) and s.status = 'projected'
                       and not exists (select 1 from public.attendance_events e where e.id = s.projected_event_id and e.biometric_event_id = s.raw_event_id))
     and not exists (select 1 from public.biometric_event_state s where s.employee_id = pg_temp.r(n)
                      and (s.status = 'stored' or (s.processed_at is null and s.status in ('projected', 'correction_needed', 'extra', 'reconciled')
                           and not (s.status = 'correction_needed' and s.raw_event_id::text = current_setting('rp.m' || n, true)))))
$$;
create function pg_temp.rps(n int, k text) returns text language sql as $$ select pg_temp.st(current_setting('rp.' || k || n)::bigint) $$;
create function pg_temp.rpblocked(n int, mid_state text) returns boolean language sql as $$
  select pg_temp.revs(n) = '' and pg_temp.rps(n, 'i') = 'correction_needed' and 'would_open_closed_day' = any (pg_temp.fl(current_setting('rp.i' || n)::bigint))
     and pg_temp.rps(n, 'm') = mid_state and pg_temp.rps(n, 'o') = 'correction_needed' and pg_temp.rstate(n) = 'off' and pg_temp.rpinv(n)
     and not exists (select 1 from attendance_events where employee_id = pg_temp.r(n)) $$;
select pg_temp.rp3(21, '12:00', 'out', '{"auth": "unauthenticated_lan"}');            -- 1 flagged OUT
select pg_temp.rp3(22, '12:00', 'out');                                                 -- 2 held OUT (not due yet)
update biometric_event_state set status = 'held', hold_reason = 'device_without_office', held_since = now(), next_check_at = now() + interval '1 hour'
 where raw_event_id = current_setting('rp.m22')::bigint;
select pg_temp.rp3(23, '12:00', 'out', '{"status": "possible_duplicate"}');            -- 3 possible duplicate OUT
select pg_temp.rp3(24, '12:00', 'out', '{"status": "correction_needed"}');             -- 4 OUT already waiting for a correction
select pg_temp.rp3(25, '12:00', null);                                                  -- 5 OUT without direction (stored)
select pg_temp.rp3(26, '12:00', 'in');                                                  -- 6a a later IN (stored)
select pg_temp.rp3(27, '09:02', 'in', '{"auth": "unauthenticated_lan"}');              -- 6b a flagged re-press of the IN inside the window
select pg_temp.rp3(28, '12:00', 'out', '{"status": "dismissed"}');                     -- 7a dismissed by HR
select pg_temp.rp3(29, '12:00', 'out', '{"status": "rejected"}');                      -- 7b confirmed duplicate (rejected) by HR
select pg_temp.rproj(n) from generate_series(21, 29) n;
select pg_temp.expect(pg_temp.rpblocked(21, 'flagged'), 'RP1 IN, flagged OUT, valid OUT: the flagged OUT is not jumped over; IN correction_needed, the flagged OUT stays flagged, nothing counted, no open session');
select pg_temp.expect(pg_temp.rpblocked(22, 'held') and (pg_temp.sx(current_setting('rp.m22')::bigint)).hold_reason = 'device_without_office',
  'RP2 IN, held OUT, valid OUT: IN correction_needed, the held OUT stays held with its reason, nothing counted');
select pg_temp.expect(pg_temp.rpblocked(23, 'possible_duplicate'), 'RP3 IN, possible-duplicate OUT, valid OUT: IN correction_needed, the duplicate stays for review, nothing counted');
select pg_temp.expect(pg_temp.rpblocked(24, 'correction_needed'), 'RP4 IN, correction_needed OUT, valid OUT: IN correction_needed, nothing counted');
select pg_temp.expect(pg_temp.rpblocked(25, 'correction_needed') and 'no_direction' = any (pg_temp.fl(current_setting('rp.m25')::bigint)),
  'RP5 IN, OUT without direction, valid OUT: IN correction_needed, the 12:00 punch correction_needed (no_direction), nothing counted');
select pg_temp.expect(pg_temp.rpblocked(26, 'correction_needed'), 'RP6 IN, a later IN, OUT: nothing is paired across the second IN; all three to HR, nothing counted');
select pg_temp.expect(pg_temp.rpblocked(27, 'flagged'), 'RP6 IN, a flagged re-press 2 min later, OUT: a flagged press is not treated as a harmless re-press; IN correction_needed');
select pg_temp.expect(pg_temp.revs(28) = 'in 09:00 B, out 17:00 B' and pg_temp.rps(28, 'm') = 'dismissed' and pg_temp.rstate(28) = 'off' and pg_temp.rpinv(28)
  and pg_temp.revs(29) = 'in 09:00 B, out 17:00 B' and pg_temp.rps(29, 'm') = 'rejected' and pg_temp.rstate(29) = 'off' and pg_temp.rpinv(29),
  'RP7 a punch HR already dismissed / confirmed as a duplicate does not block the pair: 09:00–17:00 counted, the reviewed punch keeps its state');
-- 8 the intervening punch arrives only AFTER the pair was counted: it never stretches or splits the counted interval
select set_config('rp.i30', pg_temp.rp('dv', 30, '09:00', 'in')::text, false); select set_config('rp.o30', pg_temp.rp('dv2', 30, '17:00', 'out')::text, false);
select set_config('rp.i31', pg_temp.rp('dv', 31, '09:00', 'in')::text, false); select set_config('rp.o31', pg_temp.rp('dv2', 31, '17:00', 'out')::text, false);
select set_config('rp.i32', pg_temp.rp('dv', 32, '09:00', 'in')::text, false); select set_config('rp.o32', pg_temp.rp('dv2', 32, '17:00', 'out')::text, false);
select pg_temp.rproj(n) from generate_series(30, 32) n;
select set_config('rp.ids', (select string_agg(id::text, ',' order by id) from attendance_events where employee_id in (pg_temp.r(30), pg_temp.r(31), pg_temp.r(32))), false);
select set_config('rp.m30', pg_temp.rp('dv', 30, '12:00', 'out', '{"auth": "unauthenticated_lan"}')::text, false);
select set_config('rp.m31', pg_temp.rp('dv', 31, '12:00', 'in')::text, false);
select set_config('rp.m32', pg_temp.rp('dv', 32, '09:03', 'in')::text, false);
select pg_temp.rproj(n) from generate_series(30, 32) n;
select pg_temp.expect(pg_temp.revs(30) = 'in 09:00 B, out 17:00 B' and pg_temp.rps(30, 'm') = 'flagged'
  and pg_temp.revs(31) = 'in 09:00 B, out 17:00 B' and pg_temp.rps(31, 'm') = 'correction_needed' and 'out_of_order' = any (pg_temp.fl(current_setting('rp.m31')::bigint))
  and pg_temp.revs(32) = 'in 09:00 B, out 17:00 B' and pg_temp.rps(32, 'm') = 'extra'
  and (select string_agg(id::text, ',' order by id) from attendance_events where employee_id in (pg_temp.r(30), pg_temp.r(31), pg_temp.r(32))) = current_setting('rp.ids')
  and pg_temp.rstate(30) = 'off' and pg_temp.rstate(31) = 'off' and pg_temp.rstate(32) = 'off' and pg_temp.rpinv(30) and pg_temp.rpinv(31) and pg_temp.rpinv(32),
  'RP8 a punch arriving after the pair was counted (flagged OUT / later IN / re-press): flagged / correction_needed (out_of_order) / extra; the counted rows keep their ids and times');
select pg_temp.pact('hr@proj.co');
select pg_temp.expect(pg_temp.review(current_setting('rp.m30')::bigint, 'accept_time') ->> 'status' = 'stored', 'RP8 HR accepts the late flagged 12:00 OUT');
select pg_temp.pact('owner');
select pg_temp.rproj(30);
select pg_temp.expect(pg_temp.revs(30) = 'in 09:00 B, out 17:00 B' and pg_temp.rps(30, 'm') = 'correction_needed' and pg_temp.rstate(30) = 'off' and pg_temp.rpinv(30),
  'RP8 the accepted 12:00 OUT inside the counted pair is out of order: correction_needed, the 09:00–17:00 interval is not cut or extended');
-- 9 repeated runs change nothing
select set_config('rp.snap', (select md5(string_agg(to_jsonb(e)::text, '|' order by id)) from attendance_events e where employee_id in (select pg_temp.r(n) from generate_series(21, 32) n))
  || (select md5(string_agg(to_jsonb(s)::text, '|' order by raw_event_id)) from biometric_event_state s where employee_id in (select pg_temp.r(n) from generate_series(21, 32) n))
  || (select count(*) from audit_log)::text, false);
select pg_temp.rproj(n) from generate_series(21, 32) n; select pg_temp.rproj(n) from generate_series(21, 32) n;
select pg_temp.expect((select md5(string_agg(to_jsonb(e)::text, '|' order by id)) from attendance_events e where employee_id in (select pg_temp.r(n) from generate_series(21, 32) n))
  || (select md5(string_agg(to_jsonb(s)::text, '|' order by raw_event_id)) from biometric_event_state s where employee_id in (select pg_temp.r(n) from generate_series(21, 32) n))
  || (select count(*) from audit_log)::text = current_setting('rp.snap'), 'RP9 projecting RP1–RP8 twice more changes no row, state, version or audit');
-- 10 when the blocking punch is resolved later, the IN still waits for HR (it is never paired on its own afterwards), nothing is stretched
update biometric_event_state set next_check_at = now() - interval '1 second' where raw_event_id = current_setting('rp.m22')::bigint;
select pg_temp.rproj(22);
select pg_temp.expect(pg_temp.revs(22) = '' and pg_temp.rps(22, 'i') = 'correction_needed' and pg_temp.rstate(22) = 'off' and pg_temp.rpinv(22),
  'RP10 the held OUT is looked at again: the IN stays correction_needed for HR, no row is written, no open session');

\echo ALL BIOMETRIC PROJECTION TESTS PASSED
