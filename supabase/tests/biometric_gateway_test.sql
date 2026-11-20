\set ON_ERROR_STOP on
-- 0011 biometric gateway. Runs after biometric_core_test.sql in the same session (reuses its people, agents, devices).
reset role; select pg_temp.as_user('');
create or replace function pg_temp.act(r text) returns void language plpgsql as $$
begin
  if r = 'owner' then reset role; perform set_config('request.jwt.claim.sub', '', false);
  elsif r = 'anon' then reset role; set role anon; perform set_config('request.jwt.claim.sub', '', false);
  else reset role; set role authenticated; perform set_config('request.jwt.claim.sub', pg_temp.uid(r), false); end if;
end $$;
-- one event; extra keys override
create function pg_temp.ev(serial text, code text, ts timestamptz, extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('manufacturer', case when serial = 'ES002' then 'essl' else 'zkteco' end, 'serial', serial, 'employee_code', code,
           'local_time', to_char(ts at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS')) || extra $$;
create function pg_temp.b(events jsonb, extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('batch_id', gen_random_uuid(), 'agent_version', '1.0.0', 'events', events) || extra $$;
create function pg_temp.na() returns jsonb language sql as $$ select '{"ok": false, "code": "not_accepted", "message": "Not accepted."}'::jsonb $$;
create function pg_temp.counts() returns text language sql as $$
  select (select count(*) from biometric_raw_events) || '/' || (select count(*) from biometric_event_state) || '/' || (select count(*) from biometric_sync_runs)
         || '/' || (select count(*) from biometric_event_errors) || '/' || (select count(*) from attendance_events) || '/' || (select count(*) from audit_log) $$;

-- ================================================================ 1. catalog: anon may call exactly the two gateway functions
select pg_temp.expect((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')) = array['biometric_heartbeat', 'biometric_ingest', 'company_brand'],
  'anon can call only biometric_heartbeat, biometric_ingest and company_brand');
select pg_temp.expect((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'biometric\_%' and has_function_privilege('authenticated', p.oid, 'execute'))
  = array['biometric_end_mapping', 'biometric_error_payload', 'biometric_raw_payload', 'biometric_register_agent', 'biometric_review_event',
          'biometric_revoke_agent', 'biometric_rotate_agent_key', 'biometric_save_device', 'biometric_save_mapping', 'biometric_save_settings',
          'biometric_set_device_status', 'biometric_set_direction_mode'],
  'signed-in users still call only the 12 Admin/HR functions (not the gateway, not its helpers)');
select pg_temp.expect(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0))), 'no function is callable by PUBLIC');
select pg_temp.expect(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef and not exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%')),
  'every SECURITY DEFINER function pins its search_path');
select pg_temp.expect(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r', 'v')
  and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('anon', c.oid, 'insert') or has_table_privilege('anon', c.oid, 'update')
       or has_table_privilege('anon', c.oid, 'delete'))), 'anon still has no table or view access');
select pg_temp.expect((select prosrc from pg_proc where proname = 'biometric_ingest') ~ 'pg_advisory_xact_lock_shared' and
  position('biometric_check_agent_key' in (select prosrc from pg_proc where proname = 'biometric_ingest')) <
  position('pg_advisory_xact_lock(hashtextextended(aid' in (select prosrc from pg_proc where proname = 'biometric_ingest')),
  'ingest verifies the key before taking any lock, and takes the shared code locks (B3.2 protocol)');

-- ================================================================ 2. keys: 256-bit generation, generic refusal, nothing done before verification
select pg_temp.act('A admin');
select set_config('g.k1', biometric_rotate_agent_key(current_setting('t.agent')::uuid) ->> 'agent_key', false);
select set_config('g.k2', biometric_rotate_agent_key(current_setting('t.agent2')::uuid) ->> 'agent_key', false);
select set_config('g.reg3', biometric_register_agent('Spare PC', 'spare-pc-01')::text, false);
select pg_temp.act('B admin');
select set_config('g.kb', biometric_rotate_agent_key(current_setting('t.agentb')::uuid) ->> 'agent_key', false);
select pg_temp.act('owner');
select pg_temp.expect((select prosrc from pg_proc where proname = 'biometric_new_key') ~ 'gen_random_uuid\(\)::text \|\| gen_random_uuid\(\)::text \|\| gen_random_uuid\(\)::text',
  'new keys draw on three v4 UUIDs (366 random bits) before SHA-256, so the secret carries the full 256 bits');
select pg_temp.expect((select count(distinct k) from (select (biometric_new_key()).agent_key k from generate_series(1, 2000)) x) = 2000, '2000 generated keys are all different');
select set_config('g.before', pg_temp.counts(), false);
select pg_temp.act('A admin');
select biometric_revoke_agent((current_setting('g.reg3')::jsonb ->> 'agent_id')::uuid, 'Retired spare PC');
select pg_temp.act('owner');
select set_config('g.before', pg_temp.counts(), false);
update biometric_agent_credentials set expires_at = now() - interval '1 second' where key_prefix = substr(current_setting('t.key_new'), 5, 12);
select pg_temp.act('anon');
select pg_temp.expect(
  biometric_ingest('bak_x', pg_temp.b('[]')) = pg_temp.na()
  and biometric_ingest(left(current_setting('g.k1'), 59) || case when right(current_setting('g.k1'), 1) = 'A' then 'B' else 'A' end, pg_temp.b('[]')) = pg_temp.na()
  and biometric_ingest('bak_000000000000_' || repeat('A', 43), pg_temp.b('[]')) = pg_temp.na()
  and biometric_ingest(current_setting('t.key_new'), pg_temp.b('[]')) = pg_temp.na()
  and biometric_ingest(current_setting('g.reg3')::jsonb ->> 'agent_key', pg_temp.b('[]')) = pg_temp.na()
  and biometric_ingest(current_setting('g.k1') || 'xxxxx', pg_temp.b('[]')) = pg_temp.na()
  and biometric_ingest(null, pg_temp.b('[]')) = pg_temp.na()
  and biometric_heartbeat('bak_x', '{}') = pg_temp.na()
  and biometric_heartbeat(current_setting('t.key_new'), '{}') = pg_temp.na(),
  'malformed, wrong, unknown, expired, revoked-agent, overlong and missing keys all get the identical answer {ok:false, code:not_accepted, "Not accepted."}');
select pg_temp.act('owner');
select pg_temp.expect(pg_temp.counts() = current_setting('g.before'), 'a refused key changes nothing: no sync run, no error record, no audit entry');
begin;
  update companies set active = false where id = current_setting('t.ca')::uuid;
  set local role anon;
  select pg_temp.expect(biometric_ingest(current_setting('g.k1'), pg_temp.b('[]')) = pg_temp.na(), 'keys of an inactive company get the same answer');
rollback;
select pg_temp.act('anon');
select pg_temp.expect(biometric_ingest('bak_x', jsonb_build_object('batch_id', gen_random_uuid(), 'events', '[]'::jsonb, 'pad', repeat('x', 270000))) ->> 'code' = 'too_large'
  and biometric_ingest(current_setting('g.k1'), pg_temp.b((select jsonb_agg(pg_temp.ev('ZK001', '0101', now())) from generate_series(1, 201)))) ->> 'code' = 'too_large'
  and biometric_ingest(current_setting('g.k1'), '{"batch_id":"x","events":{}}') ->> 'code' = 'too_large'
  and biometric_heartbeat(current_setting('g.k1'), jsonb_build_object('pad', repeat('x', 17000))) ->> 'code' = 'too_large',
  'size caps: > 256 KB, > 200 events, events not a list, heartbeat > 16 KB are refused before any work');
select pg_temp.expect(biometric_ingest(current_setting('g.k1'), '{"batch_id":"not-a-uuid","events":[]}') ->> 'code' = 'bad_request', 'a batch needs a UUID batch_id');
select set_config('request.method', 'GET', false);
select pg_temp.expect(biometric_ingest(current_setting('g.k1'), pg_temp.b('[]')) ->> 'code' = 'use_post' and biometric_heartbeat(current_setting('g.k1'), '{}') ->> 'code' = 'use_post',
  'a GET call (key in the URL) is refused before the key is even checked');
select set_config('request.method', '', false);
select pg_temp.act('owner');
select pg_temp.expect(pg_temp.counts() = current_setting('g.before'), 'refused requests stored nothing');
select pg_temp.act('A admin');
select pg_temp.fails($$ select biometric_ingest('bak_x', '{}') $$, 'permission denied', 'signed-in users cannot call the gateway (agents use it anonymously with their key)');

-- ================================================================ 3. a normal batch: stored, attributed at punch time, nothing in attendance
select pg_temp.act('owner');
select set_config('g.att', (select count(*)::text from attendance_events), false);
select set_config('g.t30', (now() - interval '30 minutes')::text, false), set_config('g.t10', (now() - interval '10 minutes')::text, false);
select set_config('g.b1', pg_temp.b(jsonb_build_array(
  pg_temp.ev('ZK001', '0101', current_setting('g.t30')::timestamptz, jsonb_build_object('record_seq', 50001, 'direction', 'in', 'verification', 'fingerprint', 'payload', jsonb_build_object('uid', '0101', 'verify', 1))),
  pg_temp.ev('ZK001', '4242', current_setting('g.t30')::timestamptz + interval '1 minute', jsonb_build_object('record_seq', 50002)),
  pg_temp.ev('ZK001', '0101', now() - interval '20 minutes', jsonb_build_object('event_id', 'EVT-77')),
  pg_temp.ev('ZK001', '0101', current_setting('g.t10')::timestamptz),
  pg_temp.ev('ZK001', '0101', current_setting('g.t10')::timestamptz, '{"occurrence": 2}')),
  jsonb_build_object('devices', jsonb_build_array(jsonb_build_object('manufacturer', 'zkteco', 'serial', 'ZK001', 'clock_drift_s', 12))))::text, false);
select pg_temp.act('anon');
select set_config('g.r1', biometric_ingest(current_setting('g.k1'), current_setting('g.b1')::jsonb)::text, false);
select pg_temp.act('owner');
select pg_temp.expect((current_setting('g.r1')::jsonb ->> 'ok')::boolean and (current_setting('g.r1')::jsonb ->> 'stored')::int = 5
  and (current_setting('g.r1')::jsonb ->> 'rejected')::int = 0, 'five events stored');
select set_config('g.e1', current_setting('g.r1')::jsonb -> 'outcomes' -> 0 ->> 'raw_event_id', false);
select pg_temp.expect((select r.device_local_time = to_char(r.punch_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS') and r.device_timezone = 'Asia/Kolkata'
  and r.received_at - r.punch_at between interval '29 minutes' and interval '31 minutes' and r.clock_drift_s = 12 and r.direction = 'in' and r.direction_source = 'device'
  and r.verification_method = 'fingerprint' and r.dedupe_key = 'seq:50001' and r.dedupe_basis = 'record_seq' and r.agent_id = current_setting('t.agent')::uuid
  and r.payload_hash is not null and r.source_auth = 'authenticated'
  from biometric_raw_events r where r.id = current_setting('g.e1')::bigint),
  'stored with the original device-local time, zone, normalised instant, server receipt, drift, direction, method, dedupe key and payload hash');
select pg_temp.expect((select s.status = 'stored' and s.mapping_id = current_setting('t.m1')::uuid and s.employee_id = current_setting('t.ea1')::uuid and not s.decided
  from biometric_event_state s where s.raw_event_id = current_setting('g.e1')::bigint), 'a mapped code is attributed to the mapping in force at the punch time');
select pg_temp.expect((current_setting('g.r1')::jsonb -> 'outcomes' -> 1 ->> 'status') = 'unmatched', 'an unknown code waits as unmatched');
select pg_temp.expect((select string_agg(dedupe_basis, ',' order by id) from biometric_raw_events where sync_run_id = (current_setting('g.r1')::jsonb ->> 'sync_run_id')::bigint)
  = 'record_seq,record_seq,event_id,fingerprint,fingerprint', 'dedupe identity: event id, then record sequence, then fingerprint with occurrence');
select pg_temp.expect((select count(distinct dedupe_key) = 2 from biometric_raw_events where sync_run_id = (current_setting('g.r1')::jsonb ->> 'sync_run_id')::bigint and dedupe_basis = 'fingerprint'),
  'two identical punches with occurrence 1 and 2 are both kept');
select pg_temp.expect((select status = 'ok' and received = 5 and stored = 5 and completed_at is not null and response = current_setting('g.r1')::jsonb
  from biometric_sync_runs where id = (current_setting('g.r1')::jsonb ->> 'sync_run_id')::bigint), 'the sync run records counts and the exact response');
select pg_temp.expect((select last_seen_at is not null and last_successful_sync_at is not null and clock_drift_s = 12 from biometric_devices where id = current_setting('t.dev1')::uuid)
  and (select last_ingest_at is not null and version = '1.0.0' from biometric_agents where id = current_setting('t.agent')::uuid), 'device and agent telemetry updated');
select pg_temp.expect((select count(*)::text from attendance_events) = current_setting('g.att'), 'nothing is written to attendance (projection is 0012)');
select pg_temp.expect(not exists (select 1 from audit_log where target in ('biometric_agents', 'biometric_devices') and at >= now() - interval '1 minute' and action = 'update'
  and before ->> 'id' in (current_setting('t.agent'), current_setting('t.dev1'))), 'telemetry updates are not written to the audit log');
select pg_temp.expect(not exists (select 1 from audit_log a where a.after::text like '%' || split_part(current_setting('g.k1'), '_', 3) || '%')
  and not exists (select 1 from biometric_sync_runs r where r.response::text like '%' || split_part(current_setting('g.k1'), '_', 3) || '%')
  and not exists (select 1 from biometric_event_errors e where e.detail::text like '%' || split_part(current_setting('g.k1'), '_', 3) || '%'),
  'the key appears in no audit entry, sync run response or error record');

-- ================================================================ 4. replay, duplicates, conflicts, possible duplicates
select set_config('g.before', pg_temp.counts(), false);
select pg_temp.act('anon');
select set_config('g.r1b', biometric_ingest(current_setting('g.k1'), current_setting('g.b1')::jsonb)::text, false);
select pg_temp.act('owner');
select pg_temp.expect(current_setting('g.r1b')::jsonb = current_setting('g.r1')::jsonb || '{"replay": true}' and pg_temp.counts() = current_setting('g.before'),
  'replaying a batch id returns the stored response (replay: true) and stores nothing');
select pg_temp.act('anon');
select set_config('g.r2', biometric_ingest(current_setting('g.k1'), pg_temp.b(jsonb_build_array(
  pg_temp.ev('ZK001', '0101', current_setting('g.t30')::timestamptz, jsonb_build_object('record_seq', 50001, 'direction', 'in', 'verification', 'fingerprint', 'payload', jsonb_build_object('uid', '0101', 'verify', 1))),
  pg_temp.ev('ZK001', '4242', current_setting('g.t30')::timestamptz + interval '1 minute', jsonb_build_object('record_seq', 50002, 'payload', jsonb_build_object('uid', '0101', 'edited', true))),
  pg_temp.ev('ZK001', '0101', current_setting('g.t10')::timestamptz),
  pg_temp.ev('ZK001', '0101', current_setting('g.t30')::timestamptz + interval '30 seconds', jsonb_build_object('record_seq', 50003)))))::text, false);
select pg_temp.act('owner');
select pg_temp.expect((select string_agg(o ->> 'outcome', ',' order by (o ->> 'index')::int) from jsonb_array_elements(current_setting('g.r2')::jsonb -> 'outcomes') o)
  = 'duplicate,conflict,duplicate,stored', 'same key + same payload = duplicate; same key + different payload = conflict; new key stored');
select pg_temp.expect((select raw_payload is null and count(*) over () = 1 from biometric_raw_events where dedupe_key = 'seq:50002' and device_id = current_setting('t.dev1')::uuid),
  'a conflict never overwrites the original (still one row, original content)');
select pg_temp.expect((select payload_hash = biometric_content_hash(employee_device_code, device_local_time, device_utc_offset, direction, verification_method, raw_payload)
  from biometric_raw_events where id = current_setting('g.e1')::bigint), 'the stored hash covers the whole record: code, local time, offset, direction, method and payload');
select pg_temp.expect((select kind = 'conflict' and payload ->> 'edited' = 'true' and not (detail ? 'payload') and raw_event_id is not null
  from biometric_event_errors where kind = 'conflict' order by id desc limit 1), 'the conflicting payload is kept in the error record (Admin-only column), not in its readable detail');
select pg_temp.expect((current_setting('g.r2')::jsonb -> 'outcomes' -> 3 ->> 'status') = 'possible_duplicate'
  and (select duplicate_of = current_setting('g.e1')::bigint from biometric_event_state where raw_event_id = (current_setting('g.r2')::jsonb -> 'outcomes' -> 3 ->> 'raw_event_id')::bigint),
  'a second punch of the same person within 60 s is stored as a possible duplicate of the first');
select pg_temp.expect((select status = 'partial' and conflicts = 1 and confirmed_duplicates = 2 from biometric_sync_runs where id = (current_setting('g.r2')::jsonb ->> 'sync_run_id')::bigint),
  'the sync run counts duplicates and conflicts');

-- ================================================================ 5. timestamps: validation, flags, rejections
select pg_temp.act('anon');
select set_config('g.r3', biometric_ingest(current_setting('g.k1'), pg_temp.b(jsonb_build_array(
  pg_temp.ev('ZK001', '0101', now() + interval '5 minutes', '{"record_seq": 51001}'),
  pg_temp.ev('ZK001', '0101', now() + interval '60 seconds', '{"record_seq": 51002}'),
  pg_temp.ev('ZK001', '0101', now() - interval '32 days', '{"record_seq": 51003}'),
  pg_temp.ev('ZK001', '0101', now() - interval '3 days', '{"record_seq": 51004}'),
  jsonb_build_object('manufacturer', 'zkteco', 'serial', 'ZK001', 'employee_code', '0101', 'local_time', '2026-02-30 10:00:00', 'record_seq', 51005),
  jsonb_build_object('manufacturer', 'zkteco', 'serial', 'ZK001', 'employee_code', '0101', 'local_time', to_char(now() at time zone 'UTC' + interval '14 hours 1 minute' - interval '2 hours', 'YYYY-MM-DD HH24:MI:SS'), 'utc_offset', '+14:01', 'record_seq', 51006),
  jsonb_build_object('manufacturer', 'zkteco', 'serial', 'ZK001', 'employee_code', '0101', 'local_time', to_char(now() at time zone 'UTC' + interval '14 hours' - interval '2 hours', 'YYYY-MM-DD HH24:MI:SS'), 'utc_offset', '+14:00', 'record_seq', 51007),
  jsonb_build_object('manufacturer', 'zkteco', 'serial', 'ZK001', 'employee_code', '0101', 'local_time', 'yesterday 9am', 'record_seq', 51008),
  pg_temp.ev('ZK001', '0101', now() - interval '3 hours', '{"record_seq": 51009}')),
  jsonb_build_object('devices', '[]'::jsonb)))::text, false);
select pg_temp.act('owner');
select pg_temp.expect((select string_agg(coalesce(o ->> 'reason', o ->> 'status'), ',' order by (o ->> 'index')::int) from jsonb_array_elements(current_setting('g.r3')::jsonb -> 'outcomes') o)
  = 'future_time,flagged,too_old,flagged,invalid_time,invalid_time,flagged,invalid_time,stored',
  'beyond +120 s rejected; within flagged; > 31 days rejected; > 2 days flagged for review; impossible dates, offsets beyond ±14:00 and free text rejected');
select pg_temp.expect((select string_agg(array_to_string(s.flag_reasons, '+'), ',' order by r.record_seq) from biometric_raw_events r join biometric_event_state s on s.raw_event_id = r.id
  where r.record_seq in (51002, 51004, 51007)) = 'future_within_tolerance,late_backfill,offset_tz_mismatch', 'review reasons are recorded on the punch');
select pg_temp.expect((select count(*) from biometric_event_errors where kind in ('future_time', 'too_old', 'invalid_time') and detail ->> 'batch_id' = current_setting('g.r3')::jsonb ->> 'batch_id') = 5,
  'every rejected punch leaves an error record (batch, index, code, local time — no payload)');
select pg_temp.expect((select punch_at = (device_local_time::timestamp - interval '14 hours') at time zone 'UTC' from biometric_raw_events where record_seq = 51007),
  'an explicit +14:00 offset is applied exactly');
select pg_temp.act('anon');
select set_config('g.r4', biometric_ingest(current_setting('g.k1'), pg_temp.b(jsonb_build_array(pg_temp.ev('ZK001', '0101', now() - interval '2 hours', '{"record_seq": 51010}')),
  jsonb_build_object('devices', jsonb_build_array(jsonb_build_object('manufacturer', 'zkteco', 'serial', 'ZK001', 'clock_drift_s', 420)))))::text, false);
select pg_temp.act('owner');
select pg_temp.expect((current_setting('g.r4')::jsonb -> 'outcomes' -> 0 ->> 'status') = 'flagged'
  and (select 'clock_drift' = any(time_flags) and clock_drift_s = 420 from biometric_raw_events where record_seq = 51010), 'device clock drift over 5 minutes is flagged');

-- ================================================================ 6. ownership, formats, special cases
select pg_temp.act('anon');
select set_config('g.r5', biometric_ingest(current_setting('g.k2'), pg_temp.b(jsonb_build_array(
  pg_temp.ev('ZK001', '0101', now() - interval '5 minutes', '{"record_seq": 52001}'),
  pg_temp.ev('ES002', '0101', now() - interval '5 minutes', '{"record_seq": 52002}'))))::text, false);
-- B's device is in Europe/London (its company's zone): an India-time reading would be 5½ h in the future and is refused
select set_config('g.r6x', biometric_ingest(current_setting('g.kb'), pg_temp.b(jsonb_build_array(pg_temp.ev('ZK001', '0101', now() - interval '5 minutes', '{"record_seq": 52099}'))))::text, false);
select set_config('g.r6', biometric_ingest(current_setting('g.kb'), pg_temp.b(jsonb_build_array(pg_temp.ev('ZK001', '0101', now() - interval '5 minutes',
  jsonb_build_object('record_seq', 52003, 'local_time', to_char(now() at time zone 'Europe/London' - interval '5 minutes', 'YYYY-MM-DD HH24:MI:SS'))))))::text, false);
select pg_temp.act('owner');
select pg_temp.expect((current_setting('g.r5')::jsonb -> 'outcomes' -> 0 ->> 'reason') = 'unknown_device' and (current_setting('g.r5')::jsonb -> 'outcomes' -> 1 ->> 'outcome') = 'stored',
  'an agent can submit only its own devices (Main entrance belongs to the other agent)');
select pg_temp.expect((current_setting('g.r6x')::jsonb -> 'outcomes' -> 0 ->> 'reason') = 'future_time', 'device-local time is read in the device''s own zone (London device, India-time reading refused)');
select pg_temp.expect((select company_id = current_setting('t.cb')::uuid and device_id = current_setting('t.devb')::uuid from biometric_raw_events where record_seq = 52003),
  'company B''s agent sending serial ZK001 reaches B''s own device ZK001 — never A''s');
select pg_temp.act('A admin');
select biometric_set_device_status(current_setting('t.dev2')::uuid, 'disabled');
select pg_temp.act('anon');
select pg_temp.expect(biometric_ingest(current_setting('g.k2'), pg_temp.b(jsonb_build_array(pg_temp.ev('ES002', '0101', now() - interval '4 minutes', '{"record_seq": 52004}')))) -> 'outcomes' -> 0 ->> 'reason' = 'unknown_device',
  'a disabled device''s punches are refused');
select pg_temp.act('A admin');
select biometric_set_device_status(current_setting('t.dev2')::uuid, 'active');
select pg_temp.act('anon');
select set_config('g.r7', biometric_ingest(current_setting('g.k1'), pg_temp.b(jsonb_build_array(
  pg_temp.ev('ZK001', '01 01', now() - interval '3 minutes'),
  pg_temp.ev('ZK001', '0101', now() - interval '3 minutes', '{"direction": "sideways"}'),
  pg_temp.ev('ZK001', '0101', now() - interval '3 minutes', '{"payload": {"uid": "0101", "fp_template": "AAAA"}}'),
  pg_temp.ev('ZK001', '0101', now() - interval '3 minutes', '{"payload": {"FaceImage": "..."}}'),
  pg_temp.ev('ZK001', '0101', now() - interval '3 minutes', '{"record_seq": "12a"}'),
  pg_temp.ev('ZK001', '0101', now() - interval '3 minutes', '{"occurrence": 0}'),
  '"not an object"'::jsonb,
  pg_temp.ev('ZK001', '0101', now() - interval '3 minutes', '{"record_seq": 52010, "source_auth": "unauthenticated_lan"}'))))::text, false);
select pg_temp.act('owner');
select pg_temp.expect((select string_agg(coalesce(o ->> 'reason', o ->> 'status'), ',' order by (o ->> 'index')::int) from jsonb_array_elements(current_setting('g.r7')::jsonb -> 'outcomes') o)
  = 'unsupported_format,unsupported_format,unsupported_format,unsupported_format,unsupported_format,unsupported_format,unsupported_format,flagged',
  'bad codes, directions, sequences, occurrences, non-objects and payloads with fingerprint templates or face images are refused; unauthenticated LAN punches are flagged');
select pg_temp.expect(not exists (select 1 from biometric_raw_events where raw_payload::text ~* 'template|faceimage')
  and not exists (select 1 from biometric_event_errors where coalesce(detail::text, '') ~* 'template|faceimage|AAAA'),
  'no template or image data is stored anywhere — not in raw events, not in error details');
select pg_temp.expect((select 'unauthenticated_source' = any(flag_reasons) from biometric_event_state s join biometric_raw_events r on r.id = s.raw_event_id where r.record_seq = 52010),
  'review reason unauthenticated_source recorded');
-- inactive employee: the mapping stays (history), the punch goes to review
update employees set active = false where id = current_setting('t.ea4')::uuid;
select pg_temp.act('anon');
select set_config('g.r8', biometric_ingest(current_setting('g.k1'), pg_temp.b(jsonb_build_array(pg_temp.ev('ZK001', '0777', now() - interval '2 minutes', '{"record_seq": 52011}'))))::text, false);
select pg_temp.act('owner');
update employees set active = true where id = current_setting('t.ea4')::uuid;
select pg_temp.expect((current_setting('g.r8')::jsonb -> 'outcomes' -> 0 ->> 'status') = 'flagged'
  and (select 'inactive_employee' = any(flag_reasons) and employee_id = current_setting('t.ea4')::uuid from biometric_event_state s join biometric_raw_events r on r.id = s.raw_event_id where r.record_seq = 52011),
  'a punch for a switched-off person keeps its attribution and is flagged for review');

-- ================================================================ 7. throttle and heartbeat
update biometric_agents set ingest_window_start = null, ingest_window_count = 0 where id = current_setting('t.agent2')::uuid; -- fresh window for the count
select pg_temp.act('anon');
do $$ declare i int; r jsonb; begin
  for i in 1..30 loop
    r := biometric_ingest(current_setting('g.k2'), pg_temp.b('[]'));
    if not (r ->> 'ok')::boolean then raise exception 'FAILED: batch % of 30 refused: %', i, r; end if;
  end loop; end $$;
select set_config('g.thr', biometric_ingest(current_setting('g.k2'), pg_temp.b('[]'))::text, false);
select pg_temp.act('owner');
select pg_temp.expect((current_setting('g.thr')::jsonb ->> 'code') = 'throttled' and (current_setting('g.thr')::jsonb ->> 'retry_after_s')::int between 1 and 60,
  'more than 30 batches per agent per minute are throttled with a retry time (no sync run stored)');
select pg_temp.expect((select ingest_window_count from biometric_agents where id = current_setting('t.agent2')::uuid) = 30, 'the window counts only accepted batches');
update biometric_agents set ingest_window_start = now() - interval '61 seconds' where id = current_setting('t.agent2')::uuid;
select pg_temp.act('anon');
select pg_temp.expect((biometric_ingest(current_setting('g.k2'), pg_temp.b('[]')) ->> 'ok')::boolean, 'a new window accepts batches again');
select pg_temp.act('owner');
select pg_temp.expect((select ingest_window_count from biometric_agents where id = current_setting('t.agent2')::uuid) = 1, 'the window restarted');
select pg_temp.expect((select count(*) from biometric_agents where id = current_setting('t.agent2')::uuid and ingest_window_count = 1) = 1, 'throttle state is per agent');
select pg_temp.act('anon');
select set_config('g.hb', biometric_heartbeat(current_setting('g.k1'), '{"agent_version":"1.0.1","devices":[{"manufacturer":"zkteco","serial":"ZK001","reachable":true,"clock_drift_s":7},{"manufacturer":"zkteco","serial":"ZK001X","reachable":true,"clock_drift_s":99}]}')::text, false);
select pg_temp.act('owner');
select pg_temp.expect((current_setting('g.hb')::jsonb ->> 'ok')::boolean and jsonb_array_length(current_setting('g.hb')::jsonb -> 'devices') = 1
  and (current_setting('g.hb')::jsonb -> 'devices' -> 0 ->> 'serial') = 'ZK001' and (current_setting('g.hb')::jsonb -> 'devices' -> 0) ? 'connection',
  'heartbeat returns the agent''s own active devices with their non-secret connection details');
select pg_temp.expect((select clock_drift_s = 7 from biometric_devices where id = current_setting('t.dev1')::uuid)
  and (select last_heartbeat_at is not null and version = '1.0.1' from biometric_agents where id = current_setting('t.agent')::uuid),
  'heartbeat records drift and agent version; unknown serials are ignored');
select pg_temp.act('anon');
select pg_temp.expect(biometric_heartbeat(current_setting('g.k1'), '{}') ->> 'code' = 'throttled', 'heartbeats more often than every 30 s are throttled');
select pg_temp.act('owner');
update biometric_agents set last_heartbeat_at = now() - interval '31 seconds' where id = current_setting('t.agent')::uuid;
select pg_temp.act('anon');
select pg_temp.expect((biometric_heartbeat(current_setting('g.k1'), '{}') ->> 'ok')::boolean, 'after 30 s the next heartbeat is accepted');

-- ================================================================ 8. failure handling, size and time budget, immutability
select pg_temp.act('owner');
begin;
  alter table biometric_raw_events add constraint tmp_force_failure check (employee_device_code <> 'BOOM');
  set local role anon;
  select set_config('g.pf', biometric_ingest(current_setting('g.k1'), pg_temp.b(jsonb_build_array(pg_temp.ev('ZK001', 'BOOM', now() - interval '1 minute', '{"record_seq": 53001}'))))::text, true);
  reset role;
  select pg_temp.expect((current_setting('g.pf')::jsonb ->> 'code') = 'processing_failure' and current_setting('g.pf') !~ 'tmp_force_failure|BOOM|bak_',
    'an unexpected database failure returns a plain answer with no internals and no key');
  select pg_temp.expect((select detail ->> 'sqlstate' = '23514' and detail ->> 'constraint' = 'tmp_force_failure' and not (detail ? 'payload')
    from biometric_event_errors where kind = 'processing_failure' order by id desc limit 1)
    and not exists (select 1 from biometric_sync_runs where batch_id::text = current_setting('g.pf')::jsonb ->> 'batch_id')
    and not exists (select 1 from biometric_raw_events where employee_device_code = 'BOOM'),
    'the failure is recorded (state and constraint only), the batch is rolled back, and the agent can resend it');
rollback;
select pg_temp.act('owner');
update biometric_agents set ingest_window_start = null, ingest_window_count = 0 where id = current_setting('t.agent')::uuid;
select set_config('g.big', pg_temp.b((select jsonb_agg(pg_temp.ev('ZK001', case when g % 3 = 0 then '4242' else '0101' end, now() - make_interval(mins => 300 + g), jsonb_build_object('record_seq', 60000 + g,
  'payload', jsonb_build_object('uid', 'x', 'n', g)))) from generate_series(1, 200) g))::text, false);
select pg_temp.act('anon');
set statement_timeout = '3s';
select set_config('g.t0', clock_timestamp()::text, false);
select set_config('g.rbig', biometric_ingest(current_setting('g.k1'), current_setting('g.big')::jsonb)::text, false);
select set_config('g.ms', round(extract(epoch from clock_timestamp() - current_setting('g.t0')::timestamptz) * 1000)::text, false);
reset statement_timeout;
select pg_temp.act('owner');
select pg_temp.expect((current_setting('g.rbig')::jsonb ->> 'stored')::int = 200, 'a full 200-event batch is stored under a 3-second statement timeout (as Supabase applies to anon)');
do $$ begin raise notice 'ok - timing: 200-event batch took % ms (limit 3000 ms)', current_setting('g.ms'); end $$;
select pg_temp.expect(current_setting('g.ms')::int < 3000, '200-event batch well inside the anon timeout');
select pg_temp.expect((select octet_length(response::text) < 65536 from biometric_sync_runs where id = (current_setting('g.rbig')::jsonb ->> 'sync_run_id')::bigint), 'the stored response stays under 64 KB');
select pg_temp.fails($$ insert into biometric_raw_events (company_id, device_id, agent_id, employee_device_code, device_local_time, device_timezone, punch_at, source_auth, dedupe_key, dedupe_basis)
  values ('$$ || current_setting('t.ca') || $$', '$$ || current_setting('t.dev1') || $$', '$$ || current_setting('t.agent') || $$', '0101', to_char(now() at time zone 'Europe/London', 'YYYY-MM-DD HH24:MI:SS'),
          'Europe/London', date_trunc('second', now()), 'authenticated', 'seq:99999', 'record_seq') $$,
  'device''s time zone', 'a raw event must carry its device''s own time zone (replaces the per-row zone scan)');
select pg_temp.fails($$ update biometric_raw_events set punch_at = punch_at where sync_run_id = $$ || (current_setting('g.rbig')::jsonb ->> 'sync_run_id'), 'cannot be changed', 'gateway-stored raw events are immutable');
select pg_temp.expect((select count(*)::text from attendance_events) = current_setting('g.att'), 'after every batch, attendance is still untouched');
select pg_temp.act('A hr');
select pg_temp.expect((select count(*) from biometric_raw_events_safe where record_seq = 52003) = 0 and (select count(*) from biometric_raw_events_safe where record_seq = 52002) = 1,
  'HR of A sees A''s gateway punches and none of B''s');
select pg_temp.act('B hr');
select pg_temp.expect((select count(*) from biometric_raw_events_safe where record_seq = 52003) = 1 and (select count(*) from biometric_raw_events_safe where company_id <> current_setting('t.cb')::uuid) = 0,
  'HR of B sees B''s gateway punch only');
select pg_temp.act('owner');
select 'ALL BIOMETRIC GATEWAY TESTS PASSED';
