\set ON_ERROR_STOP on
-- 0010 biometric core. Runs after 0010 (and the Supabase default-privilege stub). Company A = 'company', B = 'beta'.
reset role; select pg_temp.as_user('');

-- ---------------------------------------------------------------- helpers
-- run SQL as the current role and expect it to fail with a message matching a pattern
create function pg_temp.fails(q text, pattern text, what text) returns void language plpgsql as $$
begin
  begin execute q; exception when others then
    if sqlerrm ~* pattern then raise notice 'ok - %', what; return; end if;
    raise exception 'FAILED: % (got: %)', what, sqlerrm;
  end;
  raise exception 'FAILED: % (no error)', what;
end $$;
create function pg_temp.j(q text) returns jsonb language plpgsql as $$ declare r jsonb; begin execute q into r; return r; end $$;
create function pg_temp.uid(r text) returns text language sql as $$
  select case r when 'A admin' then '00000000-0000-0000-0000-00000000000a' when 'A hr' then '00000000-0000-0000-0000-00000000000b'
    when 'A manager' then '00000000-0000-0000-0000-00000000000c' when 'A employee' then '00000000-0000-0000-0000-00000000000d'
    when 'B admin' then '00000000-0000-0000-0000-0000000000b0' when 'B hr' then '00000000-0000-0000-0000-0000000000b2'
    when 'B employee' then '00000000-0000-0000-0000-0000000000b1' end $$;
create function pg_temp.act(r text) returns void language plpgsql as $$
begin
  if r = 'owner' then reset role; perform set_config('request.jwt.claim.sub', '', false);
  else set role authenticated; perform set_config('request.jwt.claim.sub', pg_temp.uid(r), false); end if;
end $$;
-- local device time text for an instant, in Asia/Kolkata
create function pg_temp.lt(ts timestamptz) returns text language sql as $$ select to_char(ts at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS') $$;
-- insert a raw event as the (future) gateway would; returns its id
create function pg_temp.raw(dev uuid, agt uuid, run bigint, code text, ts timestamptz, seq bigint, extra jsonb default '{}') returns bigint language plpgsql as $$
declare t timestamptz := date_trunc('second', ts); rid bigint;
begin
  insert into public.biometric_raw_events (company_id, device_id, agent_id, sync_run_id, employee_device_code, device_local_time, device_timezone,
    punch_at, source_auth, dedupe_key, dedupe_basis, record_seq, raw_payload, payload_hash, clock_drift_s, device_utc_offset)
  values ((select company_id from public.biometric_devices where id = dev), dev, agt, run, code, coalesce(extra ->> 'local', pg_temp.lt(t)),
    'Asia/Kolkata', coalesce((extra ->> 'punch_at')::timestamptz, t), 'authenticated', 'seq:' || seq, 'record_seq', seq,
    coalesce(extra -> 'payload', jsonb_build_object('uid', code, 'state', 0)), sha256(convert_to(seq::text, 'UTF8')),
    (extra ->> 'drift')::int, extra ->> 'offset')
  returning id into rid;
  return rid;
end $$;

-- ---------------------------------------------------------------- people and context
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000b2', 'hrb@beta.co');
insert into employees (company_id, full_name, email, role)
  select company_id, 'Hari Beta HR', 'hrb@beta.co', 'hr' from employees where email = 'owner@beta.co';
select set_config('t.ca', (select company_id::text from employees where id = '00000000-0000-0000-0000-00000000000a'), false);
select set_config('t.cb', (select company_id::text from employees where email = 'owner@beta.co'), false);
select set_config('t.cg', (select id::text from companies where slug = 'gamma'), false);
select set_config('t.locb', (select id::text from locations where name = 'Beta HQ'), false);
select set_config('t.locold', (select id::text from locations where name = 'Old Depot'), false);
select set_config('t.ea1', '00000000-0000-0000-0000-00000000000d', false);          -- A employee
select set_config('t.ea2', (select id::text from employees where email = 'gita@acme.in'), false);
select set_config('t.ea3', (select id::text from employees where email = 'isha@acme.in'), false);
select pg_temp.expect((select bool_and(active) from employees where id in (current_setting('t.ea1')::uuid, current_setting('t.ea2')::uuid, current_setting('t.ea3')::uuid)), 'three active A employees for mapping');
select set_config('t.ea4', (select id::text from employees where email = 'readback@acme.in'), false);
select set_config('t.ea5', (select id::text from employees where email = 'second@acme.in'), false);
select set_config('t.eb1', (select id::text from employees where email = 'ben@beta.co'), false);

-- ================================================================ 1. catalog rules after 0010 (Supabase defaults were on)
select pg_temp.expect(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity), 'row level security is on for every table (incl. 11 biometric)');
select pg_temp.expect(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'v', 'S') and c.relname like 'biometric%'
    and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('anon', c.oid, 'insert') or has_table_privilege('anon', c.oid, 'update')
         or has_table_privilege('anon', c.oid, 'delete') or (c.relkind = 'S' and has_sequence_privilege('anon', c.oid, 'usage')))),
  'anon has no privilege on any biometric table, view or sequence despite Supabase default grants');
select pg_temp.expect(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'biometric%'
    and (has_table_privilege('authenticated', c.oid, 'insert') or has_table_privilege('authenticated', c.oid, 'update')
         or has_table_privilege('authenticated', c.oid, 'delete') or has_table_privilege('authenticated', c.oid, 'truncate'))),
  'signed-in users cannot insert, update, delete or truncate any biometric table (functions only)');
select pg_temp.expect(not has_table_privilege('authenticated', 'public.biometric_agent_credentials', 'select'), 'agent credentials are not readable by any signed-in user');
select pg_temp.expect((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')) = array['company_brand'], 'anon still calls only company_brand (no biometric function)');
select pg_temp.expect(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0))), 'no function is callable by PUBLIC');
select pg_temp.expect(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef and not exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%')),
  'every SECURITY DEFINER function pins its search_path');
select pg_temp.expect((select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'biometric\_%' and has_function_privilege('authenticated', p.oid, 'execute'))
  = array['biometric_end_mapping', 'biometric_error_payload', 'biometric_raw_payload', 'biometric_register_agent', 'biometric_review_event',
          'biometric_revoke_agent', 'biometric_rotate_agent_key', 'biometric_save_device', 'biometric_save_mapping', 'biometric_save_settings',
          'biometric_set_device_status', 'biometric_set_direction_mode'],
  'signed-in users can call only the 12 checked Admin/HR functions; key checks, mapping resolution and guards are internal');
select pg_temp.expect(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosrc ilike '%raw_payload%' and p.proname not in ('biometric_raw_payload')
    and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))),
  'no other callable function mentions raw_payload');
select pg_temp.expect(not exists (select 1 from pg_views where schemaname = 'public' and definition ilike '%raw_payload%'), 'no view exposes raw_payload');
select pg_temp.expect(not has_column_privilege('authenticated', 'public.biometric_raw_events', 'raw_payload', 'select')
  and not has_column_privilege('authenticated', 'public.biometric_raw_events', 'payload_hash', 'select')
  and not has_column_privilege('authenticated', 'public.biometric_raw_events', 'dedupe_key', 'select')
  and not has_column_privilege('authenticated', 'public.biometric_event_errors', 'payload', 'select'),
  'column grants: raw_payload, payload_hash, dedupe_key and conflict payload are not selectable');
select pg_temp.expect((select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
  where table_schema = 'public' and table_name = 'biometric_raw_events_safe') !~ 'raw_payload|payload_hash', 'the safe view has no payload columns');

-- ================================================================ 2. settings defaults
insert into biometric_settings (company_id) values (current_setting('t.cg')::uuid);
select pg_temp.expect((select to_jsonb(s) - 'company_id' - 'updated_at' - 'updated_by' from biometric_settings s where company_id = current_setting('t.cg')::uuid)
  = to_jsonb(biometric_settings_for(current_setting('t.cb')::uuid)) - 'company_id' - 'updated_at' - 'updated_by',
  'built-in defaults equal the table defaults (projection off, 120 s, 31 d, 300 s, 2 d)');
select pg_temp.expect((select not projection_enabled and future_tolerance_s = 120 and backfill_days = 31 and drift_flag_s = 300 and auto_project_max_age_days = 2
  from biometric_settings_for(current_setting('t.ca')::uuid)), 'proposed operating defaults');
delete from biometric_settings where company_id = current_setting('t.cg')::uuid;
select pg_temp.act('A hr');
select pg_temp.fails($$ select biometric_save_settings('{"drift_flag_s": 200}') $$, 'Not allowed', 'HR cannot change biometric settings');
select pg_temp.act('A admin');
select pg_temp.expect(biometric_save_settings('{"drift_flag_s": 200}') ->> 'ok' = 'true', 'Admin changes a setting');
select pg_temp.fails($$ select biometric_save_settings('{"future_tolerance_s": 5000}') $$, 'check constraint', 'settings outside their limits are refused');
select pg_temp.expect((select drift_flag_s = 200 and future_tolerance_s = 120 from biometric_settings), 'settings: one row, own company, unchanged others');
select pg_temp.expect(biometric_save_settings('{"drift_flag_s": 300}') ->> 'ok' = 'true', 'setting restored');

-- ================================================================ 3. agents and credentials
select pg_temp.act('A admin');
select set_config('t.reg', biometric_register_agent('Main office PC', 'office-pc-01')::text, false);
select set_config('t.agent', current_setting('t.reg')::jsonb ->> 'agent_id', false);
select set_config('t.key', current_setting('t.reg')::jsonb ->> 'agent_key', false);
select pg_temp.expect(current_setting('t.key') ~ '^bak_[0-9a-f]{12}_[A-Za-z0-9_-]{43}$', 'key format bak_<prefix>_<43 chars>, shown once');
select set_config('t.reg2', biometric_register_agent('Plant PC', 'plant-pc-01')::text, false);
select set_config('t.agent2', current_setting('t.reg2')::jsonb ->> 'agent_id', false);
select pg_temp.fails($$ select count(*) from biometric_agent_credentials $$, 'permission denied', 'even Admin cannot read the credentials table');
select pg_temp.expect((select count(*) from biometric_agents) = 2, 'Admin sees the agents (no key columns exist on them)');
select pg_temp.act('owner');
select pg_temp.expect((select key_hash = sha256(convert_to(current_setting('t.key'), 'UTF8')) from biometric_agent_credentials where agent_id = current_setting('t.agent')::uuid),
  'only the SHA-256 of the key is stored');
select pg_temp.expect(not exists (select 1 from audit_log where (coalesce(before::text, '') || coalesce(after::text, '')) like '%' || split_part(current_setting('t.key'), '_', 3) || '%')
  and not exists (select 1 from biometric_agents a where to_jsonb(a)::text like '%' || split_part(current_setting('t.key'), '_', 3) || '%')
  and not exists (select 1 from biometric_agent_credentials c where to_jsonb(c)::text like '%' || split_part(current_setting('t.key'), '_', 3) || '%'),
  'the secret part of the key appears in no table and no audit entry');
select pg_temp.expect((select count(*) from audit_log where action = 'issue_key' and after ? 'key_prefix' and not after ? 'key_hash') = 2, 'key issue audited with prefix only');
select pg_temp.expect(biometric_check_agent_key(current_setting('t.key')) = current_setting('t.agent')::uuid, 'a valid key identifies its agent');
select pg_temp.expect(biometric_check_agent_key(left(current_setting('t.key'), 59) || case when right(current_setting('t.key'), 1) = 'A' then 'B' else 'A' end) is null
  and biometric_check_agent_key('bak_000000000000_' || repeat('A', 43)) is null
  and biometric_check_agent_key('') is null and biometric_check_agent_key(null) is null
  and biometric_check_agent_key(current_setting('t.key') || 'x') is null
  and biometric_check_agent_key($q$bak_'; drop table employees; --$q$) is null,
  'wrong secret, unknown prefix, empty, null, too long and injected keys all give the same generic null (no error, no oracle)');
-- rotation: old key keeps working for 24 h, then expires
select pg_temp.act('A admin');
select set_config('t.key_new', biometric_rotate_agent_key(current_setting('t.agent')::uuid) ->> 'agent_key', false);
select pg_temp.act('owner');
select pg_temp.expect(biometric_check_agent_key(current_setting('t.key')) is not null and biometric_check_agent_key(current_setting('t.key_new')) is not null,
  'after rotation both keys work (24-hour overlap)');
update biometric_agent_credentials set expires_at = now() - interval '1 second' where key_prefix = substr(current_setting('t.key'), 5, 12);
select pg_temp.expect(biometric_check_agent_key(current_setting('t.key')) is null and biometric_check_agent_key(current_setting('t.key_new')) is not null,
  'an expired key is refused; the new one still works');
-- revocation and inactive company
begin;
  update companies set active = false where id = current_setting('t.ca')::uuid;
  select pg_temp.expect(biometric_check_agent_key(current_setting('t.key_new')) is null, 'keys of an inactive company are refused');
rollback;
select pg_temp.act('A hr');
select pg_temp.fails($$ select biometric_register_agent('x', 'hr-agent') $$, 'Not allowed', 'HR cannot register agents');
select pg_temp.fails(format($$ select biometric_rotate_agent_key(%L) $$, current_setting('t.agent')), 'Not allowed', 'HR cannot rotate keys');
select pg_temp.act('A manager');
select pg_temp.fails($$ select biometric_register_agent('x', 'mgr-agent') $$, 'Not allowed', 'Manager cannot register agents');
select pg_temp.act('A employee');
select pg_temp.fails($$ select biometric_register_agent('x', 'emp-agent') $$, 'Not allowed', 'Employee cannot register agents');
select pg_temp.fails($$ select biometric_check_agent_key('bak_x') $$, 'permission denied', 'nobody signed in can call the internal key check');
select pg_temp.act('B admin');
select pg_temp.fails(format($$ select biometric_rotate_agent_key(%L) $$, current_setting('t.agent')), 'Not allowed', 'another company''s Admin cannot rotate A''s key');
select pg_temp.fails(format($$ select biometric_revoke_agent(%L, 'Not my agent') $$, current_setting('t.agent')), 'Not allowed', 'another company''s Admin cannot revoke A''s agent');
select pg_temp.expect((select count(*) from biometric_agents) = 0, 'B sees none of A''s agents');
select set_config('t.agentb', biometric_register_agent('Beta PC', 'beta-pc')::jsonb ->> 'agent_id', false);

-- ================================================================ 4. devices
select pg_temp.act('A admin');
select set_config('t.dev1', biometric_save_device(null, jsonb_build_object('name', 'Main entrance', 'location_id', '11111111-1111-1111-1111-111111111111',
  'manufacturer', 'zkteco', 'model', 'MB160', 'serial_number', 'ZK001', 'integration_method', 'sdk_pull', 'agent_id', current_setting('t.agent'),
  'connection', '{"host":"192.168.1.20","port":4370}'::jsonb)) ->> 'device_id', false);
select set_config('t.dev2', biometric_save_device(null, jsonb_build_object('name', 'Plant floor', 'location_id', '22222222-2222-2222-2222-222222222222',
  'manufacturer', 'essl', 'model', 'X990', 'serial_number', 'ES002', 'integration_method', 'sdk_pull', 'agent_id', current_setting('t.agent2'))) ->> 'device_id', false);
select pg_temp.fails($$ select biometric_save_device(null, '{"name":"Dup","manufacturer":"zkteco","model":"m","serial_number":"zk001","integration_method":"sdk_pull","agent_id":"$$ || current_setting('t.agent') || $$"}') $$,
  'duplicate key', 'the same manufacturer + serial cannot be registered twice in a company (case-insensitive)');
select pg_temp.fails($$ select biometric_save_device(null, '{"name":"Sec","manufacturer":"zkteco","model":"m","serial_number":"ZK009","integration_method":"sdk_pull","agent_id":"$$ || current_setting('t.agent') || $$","connection":{"host":"x","comm_password":"1234"}}') $$,
  'check constraint', 'device secrets are refused in connection details');
select pg_temp.fails($$ select biometric_save_device(null, '{"name":"Far","location_id":"$$ || current_setting('t.locb') || $$","manufacturer":"zkteco","model":"m","serial_number":"ZK010","integration_method":"sdk_pull","agent_id":"$$ || current_setting('t.agent') || $$"}') $$,
  'Cross-company', 'a device cannot be placed in another company''s office');
select pg_temp.fails($$ select biometric_save_device(null, '{"name":"Old","location_id":"$$ || current_setting('t.locold') || $$","manufacturer":"zkteco","model":"m","serial_number":"ZK011","integration_method":"sdk_pull","agent_id":"$$ || current_setting('t.agent') || $$"}') $$,
  'not in use', 'a device cannot be placed in an office that is not in use');
select pg_temp.fails($$ select biometric_save_device(null, '{"name":"Agentless","manufacturer":"zkteco","model":"m","serial_number":"ZK012","integration_method":"sdk_pull"}') $$,
  'check constraint', 'a pulled/pushed device needs a Sync Agent');
select pg_temp.act('B admin');
select pg_temp.fails($$ select biometric_save_device(null, '{"name":"Steal","manufacturer":"zkteco","model":"m","serial_number":"ZK020","integration_method":"sdk_pull","agent_id":"$$ || current_setting('t.agent') || $$"}') $$,
  'foreign key', 'a device cannot use another company''s agent (composite foreign key)');
select pg_temp.fails(format($$ select biometric_set_device_status(%L, 'disabled') $$, current_setting('t.dev1')), 'Not allowed', 'B Admin cannot disable A''s device');
select set_config('t.devb', biometric_save_device(null, jsonb_build_object('name', 'Beta door', 'manufacturer', 'zkteco', 'model', 'MB160', 'serial_number', 'ZK001',
  'integration_method', 'sdk_pull', 'agent_id', current_setting('t.agentb'))) ->> 'device_id', false);
select pg_temp.expect(current_setting('t.devb') <> '', 'the same serial can exist in another company (no cross-company disclosure)');
select pg_temp.act('A hr');
select pg_temp.fails(format($$ select biometric_set_device_status(%L, 'disabled') $$, current_setting('t.dev1')), 'Not allowed', 'HR cannot disable devices');
select pg_temp.fails(format($$ select biometric_set_direction_mode(%L, 'device') $$, current_setting('t.dev1')), 'Not allowed', 'HR cannot change punch direction');
select pg_temp.fails($$ select biometric_save_device(null, '{}') $$, 'Not allowed', 'HR cannot add devices');
select pg_temp.expect((select count(*) from biometric_devices) = 2, 'HR can view A''s two devices only');
select pg_temp.act('owner');
select pg_temp.expect(biometric_device_for_agent(current_setting('t.agent')::uuid, 'zkteco', 'zk001') = current_setting('t.dev1')::uuid
  and biometric_device_for_agent(current_setting('t.agent2')::uuid, 'zkteco', 'ZK001') is null
  and biometric_device_for_agent(current_setting('t.agentb')::uuid, 'zkteco', 'ZK001') = current_setting('t.devb')::uuid,
  'agent-to-device ownership: an agent only resolves its own devices');

-- ================================================================ 5. raw events: time integrity, payload rules, ownership, immutability
select pg_temp.act('owner');
insert into biometric_sync_runs (company_id, agent_id, batch_id) values (current_setting('t.ca')::uuid, current_setting('t.agent')::uuid, '00000000-0000-0000-0000-00000000aaa1');
select set_config('t.run', (select id::text from biometric_sync_runs where batch_id = '00000000-0000-0000-0000-00000000aaa1'), false);
select pg_temp.fails($$ insert into biometric_sync_runs (company_id, agent_id, batch_id) values ('$$ || current_setting('t.ca') || $$', '$$ || current_setting('t.agent') || $$', '00000000-0000-0000-0000-00000000aaa1') $$,
  'duplicate key', 'replaying a batch id for the same agent is refused (idempotency key)');
select set_config('t.r1', pg_temp.raw(current_setting('t.dev1')::uuid, current_setting('t.agent')::uuid, current_setting('t.run')::bigint, '0101', now() - interval '10 minutes', 1)::text, false);
select pg_temp.expect((select received_at between now() - interval '1 minute' and now() and received_at - punch_at between interval '9 minutes' and interval '11 minutes'
  and punch_at = device_local_time::timestamp at time zone 'Asia/Kolkata' and device_local_time = pg_temp.lt(punch_at)
  and device_timezone = 'Asia/Kolkata' and time_flags = '{}' from biometric_raw_events where id = current_setting('t.r1')::bigint),
  'original local time, zone, normalised instant and server receipt are all kept separately');
insert into biometric_raw_events (company_id, device_id, agent_id, employee_device_code, device_local_time, device_timezone, punch_at, received_at, source_auth, dedupe_key, dedupe_basis)
  values (current_setting('t.ca')::uuid, current_setting('t.dev1')::uuid, current_setting('t.agent')::uuid, '0101', pg_temp.lt(date_trunc('second', now()) - interval '1 hour'),
          'Asia/Kolkata', date_trunc('second', now()) - interval '1 hour', '2020-01-01', 'authenticated', 'seq:2', 'record_seq');
select pg_temp.expect((select received_at > now() - interval '1 minute' from biometric_raw_events where dedupe_key = 'seq:2'), 'a supplied received_at is ignored (server time)');
select pg_temp.fails($$ select pg_temp.raw('$$ || current_setting('t.dev1') || $$', '$$ || current_setting('t.agent') || $$', null, '0101', now() - interval '2 hours', 3, jsonb_build_object('punch_at', now())) $$,
  'must equal the device-local time', 'received/server time can never replace the original punch time');
select pg_temp.fails($$ select pg_temp.raw('$$ || current_setting('t.dev1') || $$', '$$ || current_setting('t.agent') || $$', null, '0101', now() + interval '5 minutes', 4) $$,
  'future tolerance', 'a punch more than 120 s in the future is rejected');
select pg_temp.fails($$ select pg_temp.raw('$$ || current_setting('t.dev1') || $$', '$$ || current_setting('t.agent') || $$', null, '0101', now() - interval '32 days', 5) $$,
  'backfill limit', 'a punch older than 31 days is rejected');
select set_config('t.tmp', pg_temp.raw(current_setting('t.dev1')::uuid, current_setting('t.agent')::uuid, null, '0101', now() + interval '60 seconds', 6)::text, false);
select pg_temp.expect((select time_flags = '{future_within_tolerance}' from biometric_raw_events where id = current_setting('t.tmp')::bigint),
  'a punch up to 120 s ahead is kept and flagged');
select set_config('t.tmp', pg_temp.raw(current_setting('t.dev1')::uuid, current_setting('t.agent')::uuid, null, '0101', now() - interval '3 days', 7)::text, false);
select pg_temp.expect((select time_flags = '{late_backfill}' from biometric_raw_events where id = current_setting('t.tmp')::bigint),
  'a punch older than 2 days is kept and flagged for review (late_backfill)');
select set_config('t.tmp', pg_temp.raw(current_setting('t.dev1')::uuid, current_setting('t.agent')::uuid, null, '0101', now() - interval '20 minutes', 8, '{"drift": 420}')::text, false);
select pg_temp.expect((select time_flags = '{clock_drift}' from biometric_raw_events where id = current_setting('t.tmp')::bigint),
  'device clock drift over 5 minutes is flagged');
select set_config('t.tmp', pg_temp.raw(current_setting('t.dev1')::uuid, current_setting('t.agent')::uuid, null, '0101', now() - interval '30 minutes', 9,
    jsonb_build_object('offset', '+05:00', 'punch_at', (pg_temp.lt(date_trunc('second', now()) - interval '30 minutes')::timestamp - interval '5 hours') at time zone 'UTC'))::text, false);
select pg_temp.expect((select time_flags = '{offset_tz_mismatch}' and punch_at = (device_local_time::timestamp - interval '5 hours') at time zone 'UTC'
  from biometric_raw_events where id = current_setting('t.tmp')::bigint),
  'an explicit UTC offset is honoured and a mismatch with the zone is flagged');
select pg_temp.fails($$ select pg_temp.raw('$$ || current_setting('t.dev1') || $$', '$$ || current_setting('t.agent') || $$', null, '0101', now() - interval '1 minute', 10, '{"payload": {"uid": "0101", "FingerTemplate": "AAAA"}}') $$,
  'check constraint', 'payloads carrying fingerprint templates are refused');
select pg_temp.fails($$ select pg_temp.raw('$$ || current_setting('t.dev1') || $$', '$$ || current_setting('t.agent') || $$', null, '0101', now() - interval '1 minute', 11, jsonb_build_object('payload', jsonb_build_object('x', repeat('a', 5000)))) $$,
  'check constraint', 'payloads over 4 KB are refused');
select pg_temp.fails($$ select pg_temp.raw('$$ || current_setting('t.dev1') || $$', '$$ || current_setting('t.agent2') || $$', null, '0101', now() - interval '1 minute', 12) $$,
  'does not belong to the sending agent', 'an agent cannot submit punches for a device assigned to another agent');
select pg_temp.fails($$ select pg_temp.raw('$$ || current_setting('t.dev1') || $$', '$$ || current_setting('t.agentb') || $$', null, '0101', now() - interval '1 minute', 13) $$,
  'foreign key|does not belong', 'another company''s agent cannot submit punches for this device (ownership guard; composite foreign key behind it)');
select pg_temp.fails($$ select pg_temp.raw('$$ || current_setting('t.dev1') || $$', '$$ || current_setting('t.agent') || $$', null, '0101', now() - interval '10 minutes', 1) $$,
  'duplicate key', 'the same dedupe key on the same device is stored once');
select pg_temp.fails($$ update biometric_raw_events set punch_at = punch_at + interval '1 minute' where id = $$ || current_setting('t.r1'),
  'cannot be changed', 'raw events cannot be updated — not even by the database owner');
select pg_temp.fails($$ delete from biometric_raw_events where id = $$ || current_setting('t.r1'), 'cannot be changed', 'raw events cannot be deleted');
select pg_temp.fails($$ truncate biometric_raw_events cascade $$, 'cannot be changed', 'raw events cannot be truncated');

-- ================================================================ 6. raw payload access
select pg_temp.act('A hr');
select pg_temp.fails($$ select raw_payload from biometric_raw_events $$, 'permission denied', 'HR: selecting raw_payload directly is refused');
select pg_temp.fails($$ select * from biometric_raw_events $$, 'permission denied', 'HR: select * on the raw table is refused (payload column not granted)');
select pg_temp.fails($$ select r.id from biometric_raw_events r where r.raw_payload ? 'uid' $$, 'permission denied', 'HR: filtering on raw_payload is refused too');
select pg_temp.fails($$ select payload_hash from biometric_raw_events $$, 'permission denied', 'HR: payload hash is not readable');
select pg_temp.expect((select count(*) from biometric_raw_events_safe) >= 6 and (select count(*) from biometric_raw_events_safe where company_id <> current_setting('t.ca')::uuid) = 0,
  'HR reads the approved fields through the safe view, own company only');
select pg_temp.expect((select count(*) from (select id, punch_at, device_local_time from biometric_raw_events) x) >= 6, 'HR can still select the approved columns directly');
select pg_temp.fails(format($$ select biometric_raw_payload(%s) $$, current_setting('t.r1')), 'Not allowed', 'HR cannot read raw payloads (Admin only)');
select pg_temp.act('A admin');
select pg_temp.fails($$ select raw_payload from biometric_raw_events $$, 'permission denied', 'Admin: direct select of raw_payload is refused too');
select pg_temp.expect(biometric_raw_payload(current_setting('t.r1')::bigint) = '{"uid": "0101", "state": 0}', 'Admin reads a payload through the checked function');
select pg_temp.act('owner');
select pg_temp.expect((select count(*) from audit_log where action = 'view_raw_payload' and target_id = current_setting('t.r1')) = 1, 'every payload read is in the audit log');
select pg_temp.act('B admin');
select pg_temp.fails(format($$ select biometric_raw_payload(%s) $$, current_setting('t.r1')), 'Not allowed', 'another company''s Admin cannot read the payload');
select pg_temp.expect((select count(*) from biometric_raw_events_safe) = 0, 'B sees none of A''s raw events');
select pg_temp.act('A manager');
select pg_temp.fails(format($$ select biometric_raw_payload(%s) $$, current_setting('t.r1')), 'Not allowed', 'Manager cannot read payloads');
select pg_temp.expect((select count(*) from biometric_raw_events_safe) = 0, 'Manager sees no raw events');
select pg_temp.act('A employee');
select pg_temp.fails(format($$ select biometric_raw_payload(%s) $$, current_setting('t.r1')), 'Not allowed', 'Employee cannot read payloads');
reset role;
set role anon;
select pg_temp.fails(format($$ select biometric_raw_payload(%s) $$, current_setting('t.r1')), 'permission denied', 'anon cannot call the payload function');
select pg_temp.fails($$ select id from biometric_raw_events_safe $$, 'permission denied', 'anon cannot read the safe view');
select pg_temp.act('owner');
insert into biometric_event_errors (company_id, device_id, agent_id, kind, detail, payload)
  values (current_setting('t.ca')::uuid, current_setting('t.dev1')::uuid, current_setting('t.agent')::uuid, 'conflict', '{"dedupe_key_basis":"record_seq"}', '{"uid":"0101","state":1}');
select pg_temp.fails($$ insert into biometric_event_errors (company_id, kind, detail) values ('$$ || current_setting('t.ca') || $$', 'conflict', '{"raw_payload": {"a": 1}}') $$,
  'check constraint', 'error details cannot carry a raw payload');
select pg_temp.act('A hr');
select pg_temp.fails($$ select payload from biometric_event_errors $$, 'permission denied', 'HR cannot read conflict payloads from errors');
select pg_temp.expect((select count(*) from (select id, kind, detail from biometric_event_errors) x) = 1, 'HR sees the error itself');
select pg_temp.act('A admin');
select pg_temp.expect(biometric_error_payload((select max(id) from biometric_event_errors)) ->> 'state' = '1', 'Admin reads the conflict payload through its checked function');

-- ================================================================ 7. mappings: scope, conflicts, effective dates, history
select pg_temp.act('A hr');
select set_config('t.m1', biometric_save_mapping('0101', current_setting('t.dev1')::uuid, current_setting('t.ea1')::uuid, now() - interval '20 days') ->> 'mapping_id', false);
select pg_temp.expect(current_setting('t.m1') <> '', 'HR maps device code 0101 on Main entrance');
select pg_temp.expect((select employee_device_code from biometric_employee_mappings where id = current_setting('t.m1')::uuid) = '0101', 'leading zeros are kept');
select pg_temp.act('owner');
select pg_temp.expect(biometric_resolve_mapping(current_setting('t.ca')::uuid, current_setting('t.dev1')::uuid, '101', now()) is null
  and biometric_resolve_mapping(current_setting('t.ca')::uuid, current_setting('t.dev1')::uuid, '0101', now()) = current_setting('t.m1')::uuid,
  '"101" and "0101" are different codes');
select pg_temp.act('A hr');
select pg_temp.expect(biometric_save_mapping('0101', current_setting('t.dev1')::uuid, current_setting('t.ea2')::uuid, now() - interval '1 day') ->> 'message' ~ 'already mapped',
  'conflict: the same code on the same device in an overlapping period is refused with a reason');
select pg_temp.expect(biometric_save_mapping('0202', current_setting('t.dev1')::uuid, current_setting('t.ea1')::uuid, now()) ->> 'message' ~ 'different code',
  'conflict: one person cannot have two codes on the same device at once');
select pg_temp.expect(biometric_save_mapping('0101', current_setting('t.dev2')::uuid, current_setting('t.ea2')::uuid, now() - interval '20 days') ->> 'ok' = 'true',
  'the same code on another device can be another person');
select pg_temp.fails(format($$ select biometric_save_mapping('C55', null, %L, now()) $$, current_setting('t.ea3')), 'Admin decision', 'HR cannot create company-wide mappings');
select pg_temp.fails(format($$ select biometric_save_mapping('C56', %L, %L, now()) $$, current_setting('t.dev1'), current_setting('t.eb1')), 'Not allowed', 'a code cannot be mapped to another company''s employee');
select pg_temp.fails(format($$ select biometric_save_mapping('C57', %L, %L, now()) $$, current_setting('t.devb'), current_setting('t.ea3')), 'Not allowed', 'a code cannot be mapped on another company''s device');
select pg_temp.act('A admin');
select pg_temp.expect(biometric_save_mapping('C55', null, current_setting('t.ea3')::uuid, now() - interval '20 days') ->> 'message' ~ 'Confirm',
  'company-wide needs explicit confirmation even for Admin');
select set_config('t.mcw', biometric_save_mapping('C55', null, current_setting('t.ea3')::uuid, now() - interval '20 days', true) ->> 'mapping_id', false);
select pg_temp.expect(current_setting('t.mcw') <> '', 'Admin creates a company-wide mapping after confirming');
select set_config('t.mdev', biometric_save_mapping('C55', current_setting('t.dev1')::uuid, current_setting('t.ea2')::uuid, now() - interval '5 days') ->> 'mapping_id', false);
select pg_temp.act('owner');
select pg_temp.expect(biometric_resolve_mapping(current_setting('t.ca')::uuid, current_setting('t.dev1')::uuid, 'C55', now()) = current_setting('t.mdev')::uuid
  and biometric_resolve_mapping(current_setting('t.ca')::uuid, current_setting('t.dev2')::uuid, 'C55', now()) = current_setting('t.mcw')::uuid
  and biometric_resolve_mapping(current_setting('t.ca')::uuid, current_setting('t.dev1')::uuid, 'C55', now() - interval '10 days') = current_setting('t.mcw')::uuid,
  'precedence: a device mapping beats company-wide from its effective time; company-wide applies elsewhere and before');
-- the database itself refuses overlaps, whoever writes
select pg_temp.fails($$ insert into biometric_employee_mappings (company_id, device_id, employee_id, employee_device_code, valid_from)
  values ('$$ || current_setting('t.ca') || $$', '$$ || current_setting('t.dev1') || $$', '$$ || current_setting('t.ea2') || $$', '0101', now()) $$,
  'exclusion constraint', 'an overlapping mapping is refused by an exclusion constraint even when written directly');
select pg_temp.fails($$ insert into biometric_employee_mappings (company_id, device_id, employee_id, employee_device_code, valid_from)
  values ('$$ || current_setting('t.ca') || $$', null, '$$ || current_setting('t.ea2') || $$', 'C55', now()) $$,
  'exclusion constraint', 'an overlapping company-wide code is refused by the database');
select pg_temp.fails($$ update biometric_employee_mappings set employee_id = '$$ || current_setting('t.ea2') || $$' where id = '$$ || current_setting('t.m1') || $$' $$,
  'cannot be edited', 'a mapping''s person/code/device/start cannot be edited (end it and add a new one)');
select pg_temp.fails($$ delete from biometric_employee_mappings where id = '$$ || current_setting('t.m1') || $$' $$, 'cannot be changed', 'mappings are never deleted');
-- inactive employee
select set_config('t.eoff2', (select id::text from employees where company_id = current_setting('t.ca')::uuid and not active limit 1), false);
select pg_temp.act('A hr');
select pg_temp.fails(format($$ select biometric_save_mapping('0909', %L, %L, now()) $$, current_setting('t.dev2'), current_setting('t.eoff2')), 'switched off', 'codes map to active employees only');
select pg_temp.act('A manager');
select pg_temp.fails(format($$ select biometric_save_mapping('0303', %L, %L, now()) $$, current_setting('t.dev1'), current_setting('t.ea3')), 'Not allowed', 'Manager cannot map codes');
select pg_temp.act('A employee');
select pg_temp.fails(format($$ select biometric_save_mapping('0303', %L, %L, now()) $$, current_setting('t.dev1'), current_setting('t.ea3')), 'Not allowed', 'Employee cannot map codes');

-- historical attribution: code 0707 belonged to ea1 (the "leaver" role here), then is re-used for ea3
select pg_temp.act('A hr');
select set_config('t.m7', biometric_save_mapping('0707', current_setting('t.dev2')::uuid, current_setting('t.ea3')::uuid, now() - interval '25 days') ->> 'mapping_id', false);
select pg_temp.act('owner');
insert into biometric_sync_runs (company_id, agent_id, batch_id) values (current_setting('t.ca')::uuid, current_setting('t.agent2')::uuid, '00000000-0000-0000-0000-00000000aaa2');
select set_config('t.r7', pg_temp.raw(current_setting('t.dev2')::uuid, current_setting('t.agent2')::uuid, null, '0707', now() - interval '6 days', 101)::text, false);
insert into biometric_event_state (raw_event_id, company_id, employee_id, mapping_id, status)
  values (current_setting('t.r7')::bigint, current_setting('t.ca')::uuid, current_setting('t.ea3')::uuid, current_setting('t.m7')::uuid, 'stored');
select pg_temp.fails($$ insert into biometric_event_state (raw_event_id, company_id, employee_id, mapping_id, status)
  values ($$ || pg_temp.raw(current_setting('t.dev2')::uuid, current_setting('t.agent2')::uuid, null, '0707', now() - interval '26 days', 102) || $$, '$$ || current_setting('t.ca') || $$', '$$ || current_setting('t.ea3') || $$', '$$ || current_setting('t.m7') || $$', 'stored') $$,
  'does not cover this punch', 'a punch before a mapping''s effective time cannot be attributed to it');
select pg_temp.act('A hr');
select pg_temp.expect(biometric_end_mapping(current_setting('t.m7')::uuid, now() - interval '7 days', 'Moved to another site') ->> 'message' ~ 'already processed punch',
  'ending a mapping before a processed punch is refused (no silent reassignment)');
select pg_temp.expect(biometric_end_mapping(current_setting('t.m7')::uuid, now() - interval '2 days', 'no') ->> 'message' ~ 'reason', 'ending needs a reason');
select pg_temp.expect(biometric_end_mapping(current_setting('t.m7')::uuid, now() - interval '2 days', 'Left the company') ->> 'ok' = 'true', 'ending after the processed punch is allowed');
select pg_temp.expect(biometric_save_mapping('0707', current_setting('t.dev2')::uuid, current_setting('t.ea1')::uuid, now() - interval '8 days') ->> 'message' ~ 'already mapped|already processed',
  'a back-dated re-use overlapping the old period is refused');
select set_config('t.m7b', biometric_save_mapping('0707', current_setting('t.dev2')::uuid, current_setting('t.ea1')::uuid, now() - interval '1 day') ->> 'mapping_id', false);
select pg_temp.act('owner');
select pg_temp.expect((select employee_id = current_setting('t.ea3')::uuid and mapping_id = current_setting('t.m7')::uuid from biometric_event_state where raw_event_id = current_setting('t.r7')::bigint)
  and biometric_resolve_mapping(current_setting('t.ca')::uuid, current_setting('t.dev2')::uuid, '0707', now() - interval '6 days') = current_setting('t.m7')::uuid
  and biometric_resolve_mapping(current_setting('t.ca')::uuid, current_setting('t.dev2')::uuid, '0707', now()) = current_setting('t.m7b')::uuid,
  'historical punch stays with the earlier person; the re-used code means the new person only from its effective time');
select pg_temp.fails($$ update biometric_event_state set mapping_id = '$$ || current_setting('t.m7b') || $$', employee_id = '$$ || current_setting('t.ea1') || $$' where raw_event_id = $$ || current_setting('t.r7'),
  'already attributed', 'an attributed punch cannot be re-pointed to another mapping — not even by the owner');
select pg_temp.expect((select count(*) from audit_log where target = 'biometric_employee_mappings' and target_id = current_setting('t.m7')) = 2, 'mapping creation and end are in the audit log');

-- unmatched punches: attributed only when covered, at their own time
select set_config('t.ru', pg_temp.raw(current_setting('t.dev1')::uuid, current_setting('t.agent')::uuid, null, '0777', now() - interval '2 hours', 201)::text, false);
insert into biometric_event_state (raw_event_id, company_id, status) values (current_setting('t.ru')::bigint, current_setting('t.ca')::uuid, 'unmatched');
select set_config('t.rd', pg_temp.raw(current_setting('t.dev1')::uuid, current_setting('t.agent')::uuid, null, '0888', now() - interval '3 hours', 202)::text, false);
insert into biometric_event_state (raw_event_id, company_id, status) values (current_setting('t.rd')::bigint, current_setting('t.ca')::uuid, 'unmatched');
select pg_temp.act('A hr');
select pg_temp.expect(biometric_save_mapping('0777', current_setting('t.dev1')::uuid, current_setting('t.ea4')::uuid, now() - interval '1 hour') ->> 'attributed' = '0',
  'a mapping effective after a waiting punch does not pick it up');
select pg_temp.expect(biometric_save_mapping('0888', current_setting('t.dev1')::uuid, current_setting('t.ea3')::uuid, now() - interval '4 hours') ->> 'attributed' = '1',
  'a mapping covering a waiting unmatched punch attributes it (at its own punch time)');
select pg_temp.act('owner');
select pg_temp.expect((select status = 'stored' and employee_id = current_setting('t.ea3')::uuid from biometric_event_state where raw_event_id = current_setting('t.rd')::bigint)
  and (select status = 'unmatched' from biometric_event_state where raw_event_id = current_setting('t.ru')::bigint), 'only the covered punch was attributed');
-- a dismissed unmatched punch is processed: a back-dated mapping may not pick it up
select set_config('t.rx', pg_temp.raw(current_setting('t.dev1')::uuid, current_setting('t.agent')::uuid, null, '0999', now() - interval '5 hours', 203)::text, false);
insert into biometric_event_state (raw_event_id, company_id, status) values (current_setting('t.rx')::bigint, current_setting('t.ca')::uuid, 'unmatched');
select pg_temp.act('A hr');
select pg_temp.expect(biometric_review_event(current_setting('t.rx')::bigint, 'dismiss', 'Visitor test punch', 1) ->> 'ok' = 'true', 'HR dismisses an unmatched punch with a reason');
select pg_temp.expect(biometric_save_mapping('0999', current_setting('t.dev1')::uuid, current_setting('t.ea5')::uuid, now() - interval '6 hours') ->> 'message' ~ 'already processed punch',
  'a back-dated mapping over a dismissed punch is refused');
select pg_temp.expect(biometric_save_mapping('0999', current_setting('t.dev1')::uuid, current_setting('t.ea5')::uuid, now() - interval '4 hours') ->> 'ok' = 'true',
  'the same mapping from after that punch is allowed');
select pg_temp.act('owner');
select pg_temp.expect((select status = 'dismissed' and mapping_id is null from biometric_event_state where raw_event_id = current_setting('t.rx')::bigint), 'the dismissed punch stays dismissed and unattributed');

-- ================================================================ 8. review decisions: permissions, audit, one decision, immutability of evidence
select set_config('t.rf', pg_temp.raw(current_setting('t.dev1')::uuid, current_setting('t.agent')::uuid, null, '0101', now() - interval '40 minutes', 301)::text, false);
insert into biometric_event_state (raw_event_id, company_id, employee_id, mapping_id, status, flag_reasons)
  values (current_setting('t.rf')::bigint, current_setting('t.ca')::uuid, current_setting('t.ea1')::uuid, current_setting('t.m1')::uuid, 'flagged', '{invalid_time}');
select set_config('t.rp', pg_temp.raw(current_setting('t.dev1')::uuid, current_setting('t.agent')::uuid, null, '0101', now() - interval '39 minutes', 302)::text, false);
insert into biometric_event_state (raw_event_id, company_id, employee_id, mapping_id, status, duplicate_of)
  values (current_setting('t.rp')::bigint, current_setting('t.ca')::uuid, current_setting('t.ea1')::uuid, current_setting('t.m1')::uuid, 'possible_duplicate', current_setting('t.rf')::bigint);
create temp table raw_before as select * from biometric_raw_events;
grant select on raw_before to authenticated;
select pg_temp.act('A manager');
select pg_temp.fails(format($$ select biometric_review_event(%s, 'accept_time', 'Looks right to me', 1) $$, current_setting('t.rf')), 'Not allowed', 'Manager cannot decide');
select pg_temp.act('A employee');
select pg_temp.fails(format($$ select biometric_review_event(%s, 'accept_time', 'Looks right to me', 1) $$, current_setting('t.rf')), 'Not allowed', 'Employee cannot decide');
select pg_temp.act('B hr');
select pg_temp.fails(format($$ select biometric_review_event(%s, 'accept_time', 'Looks right to me', 1) $$, current_setting('t.rf')), 'Not allowed', 'another company''s HR cannot decide');
select pg_temp.act('A hr');
select pg_temp.expect(biometric_review_event(current_setting('t.rf')::bigint, 'confirm_duplicate', null, 1) ->> 'message' ~ 'does not apply', 'a decision must fit the item type');
select pg_temp.expect(biometric_review_event(current_setting('t.rf')::bigint, 'accept_time', 'ok', 1) ->> 'message' ~ 'reason is required', 'accepting a flagged time needs a reason');
select pg_temp.expect(biometric_review_event(current_setting('t.rf')::bigint, 'accept_time', 'Gate clock checked by admin', 2) ->> 'message' ~ 'changed since', 'a stale screen (old version) cannot decide');
select pg_temp.expect(biometric_review_event(current_setting('t.rf')::bigint, 'accept_time', 'Gate clock checked by admin', 1) ->> 'ok' = 'true', 'HR accepts the time');
select pg_temp.expect(biometric_review_event(current_setting('t.rf')::bigint, 'dismiss', 'Second thoughts here', 2) ->> 'message' ~ 'already been decided', 'a decided punch cannot be decided again');
select pg_temp.expect(biometric_review_event(current_setting('t.rp')::bigint, 'confirm_duplicate', null, 1) ->> 'ok' = 'true', 'confirming a duplicate needs no reason');
select pg_temp.act('A admin');
select pg_temp.expect(biometric_review_event(current_setting('t.rp')::bigint, 'not_duplicate', 'Two genuine punches', 2) ->> 'message' ~ 'already been decided', 'Admin cannot overturn silently either');
select pg_temp.act('owner');
select pg_temp.expect((select decided_by = '00000000-0000-0000-0000-00000000000b'::uuid and decided_role = 'hr' and reason = 'Gate clock checked by admin' and action = 'accept_time'
  and decided_at > now() - interval '1 minute' and state_before ->> 'status' = 'flagged' and state_after ->> 'status' = 'stored'
  from biometric_event_reviews where raw_event_id = current_setting('t.rf')::bigint),
  'review record: actor (employee id), role, time, reason, before and after');
select pg_temp.expect((select count(*) from biometric_event_reviews where raw_event_id in (current_setting('t.rf')::bigint, current_setting('t.rp')::bigint)) = 2, 'exactly one decision per punch');
select pg_temp.expect((select count(*) from audit_log where action like 'review_%' and actor = '00000000-0000-0000-0000-00000000000b') >= 3, 'decisions are also in the audit log with the signed-in actor');
select pg_temp.expect((select count(*) from biometric_raw_events r join raw_before b using (id) where to_jsonb(r) = to_jsonb(b)) = (select count(*) from raw_before),
  'every raw event is byte-for-byte unchanged after the decisions');
select pg_temp.fails($$ update biometric_event_reviews set reason = 'edited later' where raw_event_id = $$ || current_setting('t.rf'), 'cannot be changed', 'review records cannot be edited (owner included)');
select pg_temp.fails($$ delete from biometric_event_reviews $$, 'cannot be changed', 'review records cannot be deleted');
select pg_temp.fails($$ update biometric_event_state set decided = false where raw_event_id = $$ || current_setting('t.rf'), 'cannot be undone', 'a decision cannot be undone');
select pg_temp.fails($$ delete from biometric_event_state where raw_event_id = $$ || current_setting('t.rf'), 'cannot be changed', 'processing state cannot be deleted');
select pg_temp.fails($$ insert into biometric_event_reviews (company_id, raw_event_id, action, decided_by, decided_role, state_before, state_after)
  values ('$$ || current_setting('t.ca') || $$', $$ || current_setting('t.rf') || $$, 'dismiss', '00000000-0000-0000-0000-00000000000b', 'hr', '{}', '{}') $$,
  'check constraint', 'a dismissal without a reason is refused by the table itself');

-- ================================================================ 9. company isolation and role matrix
-- B gets one row in every table so A can be shown not to see it (and the other way round)
select set_config('t.mb', (select biometric_save_mapping('0101', current_setting('t.devb')::uuid, current_setting('t.eb1')::uuid, now() - interval '1 day')
  from (select pg_temp.act('B hr')) x) ->> 'mapping_id', false);
select pg_temp.act('B admin');
select biometric_save_settings('{"reconcile_min": 3}');
select pg_temp.act('owner');
insert into biometric_sync_runs (company_id, agent_id, batch_id) values (current_setting('t.cb')::uuid, current_setting('t.agentb')::uuid, '00000000-0000-0000-0000-00000000bbb1');
select set_config('t.rb', pg_temp.raw(current_setting('t.devb')::uuid, current_setting('t.agentb')::uuid, null, '0101', now() - interval '5 minutes', 1)::text, false);
insert into biometric_event_state (raw_event_id, company_id, employee_id, mapping_id, status)
  values (current_setting('t.rb')::bigint, current_setting('t.cb')::uuid, current_setting('t.eb1')::uuid, current_setting('t.mb')::uuid, 'flagged');
insert into biometric_event_errors (company_id, kind) values (current_setting('t.cb')::uuid, 'unknown_device');
insert into biometric_import_batches (company_id, file_name, file_sha256) values (current_setting('t.cb')::uuid, 'b.csv', sha256('b'::bytea)),
                                                                               (current_setting('t.ca')::uuid, 'a.csv', sha256('a'::bytea));
select pg_temp.act('B hr');
select biometric_review_event(current_setting('t.rb')::bigint, 'accept_time', 'Checked with the guard', 1);
-- cross-company references are refused at the database level
select pg_temp.act('owner');
select set_config('t.rb2', pg_temp.raw(current_setting('t.devb')::uuid, current_setting('t.agentb')::uuid, null, '0101', now() - interval '4 minutes', 2)::text, false);
select pg_temp.fails($$ insert into biometric_event_state (raw_event_id, company_id, status) values ($$ || current_setting('t.rb2') || $$, '$$ || current_setting('t.ca') || $$', 'unmatched') $$,
  'foreign key', 'state cannot point at another company''s raw event (composite key)');
select pg_temp.fails($$ insert into biometric_event_reviews (company_id, raw_event_id, action, reason, decided_by, decided_role, state_before, state_after)
  values ('$$ || current_setting('t.ca') || $$', $$ || current_setting('t.rb') || $$, 'dismiss', 'cross company', '00000000-0000-0000-0000-00000000000b', 'hr', '{}', '{}') $$,
  'foreign key', 'a review cannot point at another company''s raw event');
select pg_temp.fails($$ insert into biometric_raw_events (company_id, device_id, agent_id, employee_device_code, device_local_time, device_timezone, punch_at, source_auth, dedupe_key, dedupe_basis)
  values ('$$ || current_setting('t.ca') || $$', '$$ || current_setting('t.devb') || $$', '$$ || current_setting('t.agentb') || $$', '1', pg_temp.lt(date_trunc('second', now())), 'Asia/Kolkata',
          date_trunc('second', now()), 'authenticated', 'seq:9', 'record_seq') $$,
  'foreign key', 'a raw event cannot be filed under another company than its device''s');
select pg_temp.fails($$ insert into biometric_event_state (raw_event_id, company_id, employee_id, mapping_id, status) values ($$ ||
  pg_temp.raw(current_setting('t.dev1')::uuid, current_setting('t.agent')::uuid, null, '0101', now() - interval '3 minutes', 401) || $$, '$$ || current_setting('t.ca') || $$', '$$ ||
  current_setting('t.eb1') || $$', '$$ || current_setting('t.m1') || $$', 'stored') $$,
  'Cross-company|does not cover', 'a punch cannot be attributed to another company''s employee');

create temp table iso (who text, tbl text, own bigint, other bigint, writes text);
grant all on iso to authenticated;
do $$
declare
  who text; t text; own bigint; oth bigint; w text; cid uuid;
  tables text[] := array['biometric_settings', 'biometric_agents', 'biometric_agent_credentials', 'biometric_devices', 'biometric_employee_mappings',
    'biometric_import_batches', 'biometric_sync_runs', 'biometric_raw_events_safe', 'biometric_event_state', 'biometric_event_reviews', 'biometric_event_errors'];
begin
  foreach who in array array['A admin', 'A hr', 'A manager', 'A employee', 'B admin', 'B hr', 'B employee'] loop
    perform pg_temp.act(who);
    cid := (select company_id from public.employees where user_id = pg_temp.uid(who)::uuid);
    foreach t in array tables loop
      begin
        if t = 'biometric_event_errors' then
          execute format('select count(*) filter (where company_id = $1), count(*) filter (where company_id <> $1) from (select id, company_id from public.%I) x', t) into own, oth using cid;
        else
          execute format('select count(*) filter (where company_id = $1), count(*) filter (where company_id <> $1) from public.%I', t) into own, oth using cid;
        end if;
      exception when insufficient_privilege then own := null; oth := null;
      end;
      w := 'refused';
      begin
        execute format('delete from public.%I where false', t); w := 'DELETE ALLOWED';
      exception when insufficient_privilege or feature_not_supported or object_not_in_prerequisite_state then null;
      end;
      begin
        execute format('update public.%I set company_id = company_id where false', t); w := 'UPDATE ALLOWED';
      exception when insufficient_privilege or feature_not_supported or object_not_in_prerequisite_state then null;
      end;
      insert into iso values (who, t, own, oth, w);
    end loop;
  end loop;
  perform pg_temp.act('owner');
end $$;
select pg_temp.expect(not exists (select 1 from iso where other > 0), 'nobody sees another company''s rows in any biometric table or view');
select pg_temp.expect(not exists (select 1 from iso where writes <> 'refused'), 'no signed-in role can update or delete any biometric table directly');
select pg_temp.expect(not exists (select 1 from iso where who ~ 'manager|employee' and coalesce(own, 0) > 0), 'Managers and Employees see no biometric rows at all');
select pg_temp.expect(not exists (select 1 from iso where who ~ 'admin|hr' and tbl <> 'biometric_agent_credentials' and coalesce(own, 0) = 0),
  'Admin and HR see their own company''s rows in every readable table');
select pg_temp.expect(not exists (select 1 from iso where tbl = 'biometric_agent_credentials' and own is not null), 'credentials are unreadable for every role');
do $$ declare r record; begin
  for r in select who, string_agg(replace(tbl, 'biometric_', '') || '=' || coalesce(own::text, 'denied') || '/' || coalesce(other::text, '-'), ' ' order by tbl) m from iso group by who order by who loop
    raise notice 'matrix % : %', rpad(r.who, 10), r.m;
  end loop; end $$;

select 'ALL BIOMETRIC CORE TESTS PASSED';
