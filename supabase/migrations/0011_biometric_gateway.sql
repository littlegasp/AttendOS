-- AttendOS 0011: biometric device gateway (Phase B3.3). Design: docs/biometric/BIOMETRIC_B3_1_DB_DESIGN.md §4, §11.2,
-- §11.7 and §13. Two functions are callable anonymously — biometric_ingest and biometric_heartbeat — and both refuse
-- everything until a valid agent key is presented. Punches are stored as immutable raw events with a processing state;
-- NOTHING is written to attendance here (projection is 0012).
--
-- Order inside biometric_ingest (cheap checks first, nothing expensive before the key is verified):
--   0. POST only (a GET would put the key in a URL) → 1. key length and request size caps → 2. key check (one indexed lookup + one SHA-256; same answer for every
--   failure) → 3. per-agent lock (43) → 4. batch replay → 5. per-agent throttle → 6. validate every event →
--   7. shared code locks (41, ascending) → 8. store raw + state, resolve mappings at punch time → 9. sync run, response.
-- Trust: the agent key proves WHICH AGENT sent a batch. It does not prove that a device produced a punch. Each punch's
-- source_auth is therefore decided here from Admin-controlled device configuration (device_auth), never from the JSON;
-- anything not provably pulled from a device that demands a communication key is 'unauthenticated_lan' and flagged.
-- The client address (X-Forwarded-For) is informational telemetry only — never used to accept or refuse anything.
-- Limits (also in the design document): key ≤ 64 chars; request ≤ 256 KB; ≤ 200 events per batch; ≤ 30 batches per
-- agent per rolling minute; heartbeat at most every 30 s; heartbeat body ≤ 16 KB.

-- ================================================================ key entropy: 256 bits from now on
-- 0010 derived each secret from two v4 UUIDs (244 random bits). Three v4 UUIDs give 366 random bits, so the 256-bit
-- SHA-256 output now carries the full 256 bits. Keys issued before this migration keep their 244 bits (still far
-- beyond guessing) until rotated.
create or replace function public.biometric_new_key(out key_prefix text, out agent_key text, out key_hash bytea)
language plpgsql volatile set search_path = public as $$
begin
  key_prefix := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
  agent_key := 'bak_' || key_prefix || '_' ||
    translate(encode(sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text || gen_random_uuid()::text, 'UTF8')), 'base64'), '+/=', '-_');
  key_hash := sha256(convert_to(agent_key, 'UTF8'));
end $$;

-- ================================================================ runtime columns (telemetry; not audited)
alter table public.biometric_agents add column ingest_window_start timestamptz;
alter table public.biometric_agents add column ingest_window_count int not null default 0 check (ingest_window_count >= 0);
alter table public.biometric_agents add column last_ingest_at timestamptz;

-- How a device authenticates to its agent — Admin configuration, the ONLY basis for source_auth = 'authenticated':
--   none     — the device demands nothing (open LAN pull, push, vendor software): its punches are 'unauthenticated_lan'.
--   comm_key — an SDK-pull device that refuses connections without its communication key; the agent holds that key
--              locally (never sent to AttendOS). A record pulled from it implies the agent passed the device's check.
alter table public.biometric_devices add column device_auth text not null default 'none' check (device_auth in ('none', 'comm_key'));
alter table public.biometric_devices add constraint biometric_devices_device_auth_method check (device_auth = 'none' or integration_method = 'sdk_pull');

-- Telemetry (heartbeats, sync times, drift, throttle counters) changes on every call; the audit log keeps
-- configuration changes only, so the audit triggers now fire only when a configuration column changes.
drop trigger audit_biometric_agents on public.biometric_agents;
create trigger audit_biometric_agents after insert on public.biometric_agents for each row execute function public.audit();
create trigger audit_biometric_agents_config after update on public.biometric_agents for each row
  when ((old.name, old.agent_identifier, old.status, old.revoked_at, old.revoked_by, old.revoke_reason)
        is distinct from (new.name, new.agent_identifier, new.status, new.revoked_at, new.revoked_by, new.revoke_reason))
  execute function public.audit();
drop trigger audit_biometric_devices on public.biometric_devices;
create trigger audit_biometric_devices after insert on public.biometric_devices for each row execute function public.audit();
create trigger audit_biometric_devices_config after update on public.biometric_devices for each row
  when ((old.location_id, old.name, old.manufacturer, old.model, old.serial_number, old.firmware_version, old.integration_method,
         old.adapter_type, old.agent_id, old.timezone, old.direction_mode, old.connection, old.status, old.device_auth)
        is distinct from (new.location_id, new.name, new.manufacturer, new.model, new.serial_number, new.firmware_version, new.integration_method,
         new.adapter_type, new.agent_id, new.timezone, new.direction_mode, new.connection, new.status, new.device_auth))
  execute function public.audit();

-- ================================================================ device zone check without a per-row zone scan
-- valid_timezone() scans the zone catalogue; as a per-row check on raw events it cost ~6 ms a row (≈1.2 s of a
-- 200-event batch). A device's zone is already validated on the device, so a raw event from a device must simply carry
-- that zone (a stronger rule); rows without a device (file import, 0013) still get the full check.
alter table public.biometric_raw_events drop constraint biometric_raw_events_device_timezone_check;
create function public.biometric_raw_zone_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.device_id is not null then
    if new.device_timezone is distinct from (select timezone from public.biometric_devices where id = new.device_id) then
      raise exception 'A raw event must carry its device''s time zone' using errcode = '23514';
    end if;
  elsif not public.valid_timezone(new.device_timezone) then
    raise exception 'Unknown time zone' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger raw_zone_guard before insert on public.biometric_raw_events for each row execute function public.biometric_raw_zone_guard();

-- ================================================================ helpers (internal; no grants)
-- Device-local time text → timestamp, or null when it is not a real calendar time. No exceptions (no subtransactions).
create function public.biometric_parse_local(t text) returns timestamp
language plpgsql immutable set search_path = public as $$
declare y int; mo int; d int; h int; mi int; s numeric;
begin
  if t is null or t !~ '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?$' then return null; end if;
  y := substr(t, 1, 4)::int; mo := substr(t, 6, 2)::int; d := substr(t, 9, 2)::int; h := substr(t, 12, 2)::int; mi := substr(t, 15, 2)::int;
  s := coalesce(nullif(substr(t, 18), ''), '0')::numeric;
  if y < 2000 or y > 2100 or mo not between 1 and 12 or h > 23 or mi > 59 or s >= 60 then return null; end if;
  if d < 1 or d > extract(day from (make_date(y, mo, 1) + interval '1 month - 1 day')) then return null; end if;
  return make_timestamp(y, mo, d, h, mi, s::double precision);
end $$;

-- First address in X-Forwarded-For (as PostgREST passes request headers), or null. Never raises.
-- INFORMATIONAL TELEMETRY ONLY: a caller can put any value in this header, and proxies may append rather than overwrite
-- it. It is stored for diagnosis (sync runs, agent last address) and is never used for authentication, device
-- authorisation or any accept/refuse decision. It becomes a network identity only if a trusted proxy in front of the
-- API is configured to overwrite the header — not the case today.
create function public.biometric_client_ip() returns inet
language plpgsql stable set search_path = public as $$
declare v text := trim(split_part(coalesce(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', ''), ',', 1));
begin
  if v ~ '^(\d{1,3}\.){3}\d{1,3}$' and (select bool_and(p::int <= 255) from unnest(string_to_array(v, '.')) p) then return v::inet; end if;
  if v ~ '^[0-9a-fA-F:]{2,39}$' and v like '%:%' then
    begin return v::inet; exception when others then return null; end;
  end if;
  return null;
exception when others then return null;
end $$;

-- Hash of everything the device said about a punch (code, local time, offset, direction, method, payload): equal
-- hashes under the same dedupe key = the same record sent again; different = a conflict to review.
create function public.biometric_content_hash(p_code text, p_local text, p_offset text, p_direction text, p_method text, p_payload jsonb) returns bytea
language sql immutable set search_path = public as $$
  select sha256(convert_to(jsonb_build_object('code', p_code, 'local_time', p_local, 'utc_offset', p_offset, 'direction', p_direction,
                                              'verification', p_method, 'payload', p_payload)::text, 'UTF8'))
$$;

create function public.biometric_not_accepted() returns jsonb
language sql immutable set search_path = public as $$
  select jsonb_build_object('ok', false, 'code', 'not_accepted', 'message', 'Not accepted.')
$$;

-- ================================================================ ingest
create function public.biometric_ingest(p_key text, p_batch jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  agent public.biometric_agents;
  aid uuid;
  cid uuid;
  st public.biometric_settings;
  batch uuid;
  prior jsonb;
  run_id bigint;
  ev jsonb;
  i int := 0;
  n int;
  drift jsonb := '{}';
  vals jsonb := '[]';      -- validated events
  outcomes jsonb := '[]';
  e record;
  dev public.biometric_devices;
  lt timestamp;
  pat timestamptz;
  off text;
  code text;
  dir text;
  ver text;
  pay jsonb;
  dkey text;
  basis text;
  occ int;
  reason text;
  rid bigint;
  existing record;
  new_hash bytea;
  mid uuid;
  emp public.employees;
  dup bigint;
  flags text[];
  v_status text;
  err_state text;
  err_constraint text;
  c_stored int := 0; c_dup int := 0; c_pdup int := 0; c_conf int := 0; c_rej int := 0;
  devs uuid[] := '{}';
  resp jsonb;
  elapsed numeric;
begin
  -- 0. POST only: a GET would carry the key in the URL, where proxies and API logs record it
  if coalesce(nullif(current_setting('request.method', true), ''), 'POST') <> 'POST' then
    return jsonb_build_object('ok', false, 'code', 'use_post', 'message', 'Use POST with the key in the request body; never put a key in a URL.');
  end if;
  -- 1. caps (constant time; reveal nothing about keys)
  if p_key is null or length(p_key) > 64 then return public.biometric_not_accepted(); end if;
  if p_batch is null or jsonb_typeof(p_batch) <> 'object' or octet_length(p_batch::text) > 262144 then
    return jsonb_build_object('ok', false, 'code', 'too_large', 'message', 'The request must be a JSON object of at most 256 KB.');
  end if;
  if jsonb_typeof(p_batch -> 'events') is distinct from 'array' then
    return jsonb_build_object('ok', false, 'code', 'bad_request', 'message', 'events must be a list (it may be empty).');
  end if;
  if jsonb_array_length(p_batch -> 'events') > 200 then
    return jsonb_build_object('ok', false, 'code', 'too_large', 'message', 'Send at most 200 events per batch.');
  end if;

  -- 2. key
  aid := public.biometric_check_agent_key(p_key);
  if aid is null then return public.biometric_not_accepted(); end if;

  -- 3. one batch at a time per agent
  perform pg_advisory_xact_lock(hashtextextended(aid::text, 43));
  select * into agent from public.biometric_agents where id = aid;
  cid := agent.company_id;

  -- 4. replay: the same batch id returns the stored answer and processes nothing
  if coalesce(p_batch ->> 'batch_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return jsonb_build_object('ok', false, 'code', 'bad_request', 'message', 'batch_id (a UUID chosen by the agent) is required.');
  end if;
  batch := (p_batch ->> 'batch_id')::uuid;
  select response into prior from public.biometric_sync_runs where agent_id = aid and batch_id = batch;
  if found then return coalesce(prior, '{}'::jsonb) || jsonb_build_object('replay', true); end if;

  -- 5. throttle: at most 30 batches per agent per rolling minute window
  if agent.ingest_window_start is not null and now() - agent.ingest_window_start < interval '60 seconds' and agent.ingest_window_count >= 30 then
    elapsed := extract(epoch from now() - agent.ingest_window_start);
    return jsonb_build_object('ok', false, 'code', 'throttled', 'message', 'Too many batches; wait and send again.',
                              'retry_after_s', greatest(1, ceil(60 - elapsed)));
  end if;
  update public.biometric_agents set
    ingest_window_start = case when ingest_window_start is null or now() - ingest_window_start >= interval '60 seconds' then now() else ingest_window_start end,
    ingest_window_count = case when ingest_window_start is null or now() - ingest_window_start >= interval '60 seconds' then 1 else ingest_window_count + 1 end,
    last_ingest_at = now(), last_ip = coalesce(public.biometric_client_ip(), last_ip),
    version = coalesce(left(p_batch ->> 'agent_version', 40), version)
   where id = aid;

  -- Steps 6–9 run in one protected block: an unexpected failure rolls the batch back, is recorded without any request
  -- content, and the agent gets a plain answer (it keeps the batch and retries). The key is never part of any message.
  begin
  st := public.biometric_settings_for(cid);
  if jsonb_typeof(p_batch -> 'devices') = 'array' then
    select coalesce(jsonb_object_agg(lower(d ->> 'manufacturer') || '|' || upper(d ->> 'serial'), d -> 'clock_drift_s'), '{}') into drift
      from jsonb_array_elements(p_batch -> 'devices') d
     where jsonb_typeof(d) = 'object' and coalesce(d ->> 'clock_drift_s', '') ~ '^-?\d{1,8}$';
  end if;

  insert into public.biometric_sync_runs (company_id, agent_id, batch_id, status, received, agent_version, client_ip)
    values (cid, aid, batch, 'running', jsonb_array_length(p_batch -> 'events'), left(p_batch ->> 'agent_version', 40), public.biometric_client_ip())
    returning id into run_id;

  -- 6. validate every event (no exceptions: each problem becomes a rejected outcome and an error record)
  for ev in select x from jsonb_array_elements(p_batch -> 'events') x loop
    i := i + 1;
    reason := null; dev := null; lt := null; pat := null;
    code := ev ->> 'employee_code'; off := ev ->> 'utc_offset'; dir := ev ->> 'direction'; ver := ev ->> 'verification';
    pay := case when ev ? 'payload' then ev -> 'payload' else null end;
    occ := case when coalesce(ev ->> 'occurrence', '1') ~ '^[1-9]\d{0,5}$' then coalesce(ev ->> 'occurrence', '1')::int else null end;
    if jsonb_typeof(ev) <> 'object' then reason := 'unsupported_format';
    elsif ev ->> 'manufacturer' is null or ev ->> 'serial' is null then reason := 'unsupported_format';
    else
      select * into dev from public.biometric_devices where id = public.biometric_device_for_agent(aid, ev ->> 'manufacturer', ev ->> 'serial');
      if dev.id is null then reason := 'unknown_device'; end if;
    end if;
    if reason is null and (code is null or code !~ '^[A-Za-z0-9_-]{1,32}$') then reason := 'unsupported_format'; end if;
    if reason is null and (dir is not null and dir not in ('in', 'out')) then reason := 'unsupported_format'; end if;
    if reason is null and (ver is not null and ver !~ '^[a-z_]{1,32}$') then reason := 'unsupported_format'; end if;
    if reason is null and occ is null then reason := 'unsupported_format'; end if;
    if reason is null and (ev ->> 'source_auth') is not null and ev ->> 'source_auth' not in ('authenticated', 'unauthenticated_lan') then reason := 'unsupported_format'; end if;
    if reason is null and (ev ? 'event_id') and coalesce(ev ->> 'event_id', '') !~ '^[A-Za-z0-9._:-]{1,128}$' then reason := 'unsupported_format'; end if;
    if reason is null and (ev ? 'record_seq') and coalesce(ev ->> 'record_seq', '') !~ '^\d{1,18}$' then reason := 'unsupported_format'; end if;
    if reason is null and not public.biometric_payload_ok(pay) then reason := 'unsupported_format'; end if;
    if reason is null then
      lt := public.biometric_parse_local(ev ->> 'local_time');
      if lt is null or (off is not null and off !~ '^[+-]((0\d|1[0-3]):[0-5]\d|14:00)$') then reason := 'invalid_time';
      else
        pat := case when off is not null then (lt - off::interval) at time zone 'UTC' else lt at time zone dev.timezone end;
        if pat > now() + make_interval(secs => st.future_tolerance_s) then reason := 'future_time';
        elsif pat < now() - make_interval(days => st.backfill_days) then reason := 'too_old';
        end if;
      end if;
    end if;

    if reason is not null then
      c_rej := c_rej + 1;
      insert into public.biometric_event_errors (company_id, agent_id, device_id, kind, detail)
        values (cid, aid, dev.id, reason, jsonb_strip_nulls(jsonb_build_object('batch_id', batch, 'index', i,
                  'manufacturer', left(ev ->> 'manufacturer', 40), 'serial', left(ev ->> 'serial', 64), 'employee_code', left(code, 32),
                  'local_time', left(ev ->> 'local_time', 40))));
      outcomes := outcomes || jsonb_build_object('index', i, 'outcome', 'rejected', 'reason', reason);
    else
      if ev ? 'event_id' then basis := 'event_id'; dkey := 'event_id:' || (ev ->> 'event_id');
      elsif ev ? 'record_seq' then basis := 'record_seq'; dkey := 'seq:' || (ev ->> 'record_seq');
      else basis := 'fingerprint';
           dkey := 'fp:' || encode(sha256(convert_to(concat_ws('|', code, ev ->> 'local_time', coalesce(dir, ''), coalesce(ver, ''), occ), 'UTF8')), 'hex');
      end if;
      vals := vals || jsonb_build_object('index', i, 'device', dev.id, 'code', code, 'local', ev ->> 'local_time', 'offset', off, 'tz', dev.timezone,
                'punch_at', pat, 'direction', dir, 'verification', ver, 'payload', pay, 'dedupe_key', dkey, 'basis', basis,
                'event_id', ev ->> 'event_id', 'record_seq', ev ->> 'record_seq', 'occurrence', occ,
                -- decided from the device's Admin configuration; the event's own claim can only lower it
                'source_auth', case when dev.device_auth = 'comm_key' and dev.integration_method = 'sdk_pull'
                                     and coalesce(ev ->> 'source_auth', 'authenticated') = 'authenticated' then 'authenticated' else 'unauthenticated_lan' end,
                'claim_rejected', (ev ->> 'source_auth') = 'authenticated' and not (dev.device_auth = 'comm_key' and dev.integration_method = 'sdk_pull'),
                'drift', drift -> (lower(dev.manufacturer) || '|' || upper(dev.serial_number)));
      if not dev.id = any(devs) then devs := devs || dev.id; end if;
    end if;
  end loop;

  -- 7. shared code locks, ascending key order (waits for any mapping change of these codes; see §11.7)
  perform pg_advisory_xact_lock_shared(k)
     from (select distinct public.biometric_code_lock_key(cid, v ->> 'code') k from jsonb_array_elements(vals) v order by 1) z;

  -- 8. store
  for e in select v ->> 'index' as idx, (v ->> 'device')::uuid as device, v ->> 'code' as code, v ->> 'local' as local, v ->> 'offset' as off,
                  v ->> 'tz' as tz, (v ->> 'punch_at')::timestamptz as punch_at, v ->> 'direction' as direction, v ->> 'verification' as verification,
                  v -> 'payload' as payload, v ->> 'dedupe_key' as dkey, v ->> 'basis' as basis, v ->> 'event_id' as event_id,
                  (v ->> 'record_seq')::bigint as record_seq, (v ->> 'occurrence')::int as occurrence, v ->> 'source_auth' as source_auth,
                  coalesce((v ->> 'claim_rejected')::boolean, false) as claim_rejected,
                  (v ->> 'drift')::int as drift
             from jsonb_array_elements(vals) v loop
    pay := case when jsonb_typeof(e.payload) = 'object' then e.payload else null end;
    rid := null;
    insert into public.biometric_raw_events (company_id, device_id, agent_id, sync_run_id, external_event_id, record_seq, occurrence, employee_device_code,
      device_local_time, device_utc_offset, device_timezone, punch_at, clock_drift_s, direction, direction_source, verification_method, source_auth,
      raw_payload, payload_hash, dedupe_key, dedupe_basis)
    values (cid, e.device, aid, run_id, e.event_id, e.record_seq, e.occurrence, e.code, e.local, e.off, e.tz, e.punch_at, e.drift,
      e.direction, case when e.direction is null then 'none' else 'device' end, e.verification, e.source_auth,
      pay, public.biometric_content_hash(e.code, e.local, e.off, e.direction, e.verification, pay), e.dkey, e.basis)
    on conflict (company_id, device_id, import_batch_id, dedupe_key) do nothing
    returning id into rid;

    if rid is null then
      select r.id, r.payload_hash into existing from public.biometric_raw_events r
       where r.company_id = cid and r.device_id = e.device and r.import_batch_id is null and r.dedupe_key = e.dkey;
      new_hash := public.biometric_content_hash(e.code, e.local, e.off, e.direction, e.verification, pay);
      if existing.payload_hash is not distinct from new_hash then
        c_dup := c_dup + 1;
        outcomes := outcomes || jsonb_build_object('index', e.idx::int, 'outcome', 'duplicate', 'raw_event_id', existing.id);
      else
        c_conf := c_conf + 1;
        insert into public.biometric_event_errors (company_id, raw_event_id, agent_id, device_id, kind, detail, payload)
          values (cid, existing.id, aid, e.device, 'conflict', jsonb_build_object('batch_id', batch, 'index', e.idx::int, 'dedupe_basis', e.basis), pay);
        outcomes := outcomes || jsonb_build_object('index', e.idx::int, 'outcome', 'conflict', 'raw_event_id', existing.id);
      end if;
      continue;
    end if;

    -- processing state: attribution at the punch's own time, frozen from here on
    mid := public.biometric_resolve_mapping(cid, e.device, e.code, e.punch_at);
    select * into emp from public.employees where id = (select employee_id from public.biometric_employee_mappings where id = mid);
    select array(select unnest(time_flags)) into flags from public.biometric_raw_events where id = rid;
    if e.source_auth = 'unauthenticated_lan' then flags := array_append(flags, 'unauthenticated_source'); end if;
    if e.claim_rejected then flags := array_append(flags, 'source_auth_claim_rejected'); end if;
    dup := null;
    if mid is not null then
      select r2.id into dup from public.biometric_raw_events r2 join public.biometric_event_state s2 on s2.raw_event_id = r2.id
       where r2.device_id = e.device and r2.employee_device_code = e.code and r2.id <> rid
         and r2.punch_at between e.punch_at - make_interval(secs => st.double_press_s) and e.punch_at + make_interval(secs => st.double_press_s)
         and s2.status not in ('rejected', 'dismissed')
       order by abs(extract(epoch from r2.punch_at - e.punch_at)), r2.id limit 1;
    end if;
    v_status := case
      when mid is null then 'unmatched'
      when not emp.active then 'flagged'
      when cardinality(flags) > 0 then 'flagged'
      when dup is not null then 'possible_duplicate'
      else 'stored' end;
    if mid is not null and not emp.active then flags := array_append(flags, 'inactive_employee'); end if;
    insert into public.biometric_event_state (raw_event_id, company_id, employee_id, mapping_id, status, flag_reasons, duplicate_of)
      values (rid, cid, emp.id, mid, v_status, flags, case when v_status = 'possible_duplicate' then dup end);
    c_stored := c_stored + 1;
    if v_status = 'possible_duplicate' then c_pdup := c_pdup + 1; end if;
    outcomes := outcomes || jsonb_build_object('index', e.idx::int, 'outcome', 'stored', 'raw_event_id', rid, 'status', v_status);
  end loop;

  -- 9. sync run, device telemetry, response
  resp := jsonb_build_object('ok', true, 'batch_id', batch, 'sync_run_id', run_id, 'received', jsonb_array_length(p_batch -> 'events'),
    'stored', c_stored, 'confirmed_duplicates', c_dup, 'possible_duplicates', c_pdup, 'conflicts', c_conf, 'rejected', c_rej,
    'outcomes', (select coalesce(jsonb_agg(o order by (o ->> 'index')::int), '[]') from jsonb_array_elements(outcomes) o));
  update public.biometric_sync_runs set completed_at = clock_timestamp(),
    status = case when c_rej + c_conf > 0 then 'partial' else 'ok' end,
    stored = c_stored, confirmed_duplicates = c_dup, possible_duplicates = c_pdup, conflicts = c_conf, rejected = c_rej,
    device_id = case when cardinality(devs) = 1 then devs[1] end, response = resp
   where id = run_id;
  update public.biometric_devices d set last_seen_at = now(), last_successful_sync_at = now(),
         clock_drift_s = coalesce((drift ->> (lower(d.manufacturer) || '|' || upper(d.serial_number)))::int, d.clock_drift_s)
   where d.id = any(devs);
  return resp;
  exception when others then
    get stacked diagnostics err_state = returned_sqlstate, err_constraint = constraint_name;
    insert into public.biometric_event_errors (company_id, agent_id, kind, detail)
      values (cid, aid, 'processing_failure', jsonb_strip_nulls(jsonb_build_object('batch_id', batch, 'sqlstate', err_state, 'constraint', nullif(err_constraint, ''))));
    return jsonb_build_object('ok', false, 'code', 'processing_failure', 'message', 'The batch could not be stored. Keep it and send it again.',
                              'batch_id', batch);
  end;
end $$;

-- ================================================================ heartbeat
create function public.biometric_heartbeat(p_key text, p_status jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare aid uuid; a public.biometric_agents; d jsonb;
begin
  -- 0. POST only: a GET would carry the key in the URL, where proxies and API logs record it
  if coalesce(nullif(current_setting('request.method', true), ''), 'POST') <> 'POST' then
    return jsonb_build_object('ok', false, 'code', 'use_post', 'message', 'Use POST with the key in the request body; never put a key in a URL.');
  end if;
  if p_key is null or length(p_key) > 64 then return public.biometric_not_accepted(); end if;
  if p_status is null or jsonb_typeof(p_status) <> 'object' or octet_length(p_status::text) > 16384 then
    return jsonb_build_object('ok', false, 'code', 'too_large', 'message', 'The status must be a JSON object of at most 16 KB.');
  end if;
  aid := public.biometric_check_agent_key(p_key);
  if aid is null then return public.biometric_not_accepted(); end if;
  select * into a from public.biometric_agents where id = aid for update;
  if a.last_heartbeat_at is not null and now() - a.last_heartbeat_at < interval '30 seconds' then
    return jsonb_build_object('ok', false, 'code', 'throttled', 'message', 'Heartbeats are accepted at most every 30 seconds.',
                              'retry_after_s', greatest(1, ceil(30 - extract(epoch from now() - a.last_heartbeat_at))));
  end if;
  update public.biometric_agents set last_heartbeat_at = now(), last_ip = coalesce(public.biometric_client_ip(), last_ip),
         version = coalesce(left(p_status ->> 'agent_version', 40), version) where id = aid;
  if jsonb_typeof(p_status -> 'devices') = 'array' then
    for d in select x from jsonb_array_elements(p_status -> 'devices') x where jsonb_typeof(x) = 'object' limit 200 loop
      update public.biometric_devices set
        last_seen_at = case when (d ->> 'reachable') = 'true' then now() else last_seen_at end,
        clock_drift_s = case when coalesce(d ->> 'clock_drift_s', '') ~ '^-?\d{1,8}$' then (d ->> 'clock_drift_s')::int else clock_drift_s end
       where id = public.biometric_device_for_agent(aid, d ->> 'manufacturer', d ->> 'serial');
    end loop;
  end if;
  -- the agent's work list: its active devices and their non-secret connection details
  return jsonb_build_object('ok', true, 'server_time', now(), 'devices', (
    select coalesce(jsonb_agg(jsonb_build_object('manufacturer', manufacturer, 'serial', serial_number, 'model', model,
             'integration_method', integration_method, 'adapter_type', adapter_type, 'timezone', timezone, 'direction_mode', direction_mode,
             'device_auth', device_auth,
             'connection', connection) order by serial_number), '[]')
      from public.biometric_devices where agent_id = aid and status = 'active'));
end $$;

-- ================================================================ Admin: declare how a device authenticates its agent
create function public.biometric_set_device_auth(p_id uuid, p_auth text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); d public.biometric_devices;
begin
  select * into d from public.biometric_devices where id = p_id and company_id = cid;
  if d.id is null then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_auth = 'comm_key' and d.integration_method <> 'sdk_pull' then
    return jsonb_build_object('ok', false, 'message', 'Only a device the agent pulls from (SDK pull) can require a communication key.');
  end if;
  update public.biometric_devices set device_auth = p_auth, updated_by = public.my_employee_id(), updated_at = now() where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ grants: anon may call exactly these two
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'biometric\_%' loop
    execute format('revoke all on function %s from public, anon', f.sig);
    -- signed-in users keep only the checked Admin/HR functions (12 from 0010 + set_device_auth)
    if f.sig::text !~ '^(public\.)?biometric_(save_settings|register_agent|rotate_agent_key|revoke_agent|save_device|set_device_status|set_direction_mode|set_device_auth|save_mapping|end_mapping|review_event|raw_payload|error_payload)\(' then
      execute format('revoke all on function %s from authenticated', f.sig);
    end if;
  end loop;
end $$;
grant execute on function public.biometric_ingest(text, jsonb), public.biometric_heartbeat(text, jsonb) to anon;
grant execute on function public.biometric_set_device_auth(uuid, text) to authenticated;
