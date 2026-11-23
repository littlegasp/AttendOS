-- LOCAL DEMO ONLY (B4): sample biometric records for Acme Industries in the local demo database, so the B4 screens
-- can be reviewed and tested against real database functions. Never run against a hosted project.
-- Punches enter through the real gateway function (biometric_ingest with an agent key), are projected by the real
-- queue procedure with projection switched on for the demo company for this script only, and switched off again.
-- Every punch is at least 90 minutes old so the gateway HTTP test ("nothing reached attendance in the last hour") holds.
select set_config('attendos.source', 'seed', false);

-- three plant/office workers who use the biometric devices (sample people); logins link by confirmed e-mail
insert into employees (id, company_id, full_name, email, role, department_id, home_location_id, emp_code, designation_id, joining_date, employment_status, default_shift_id)
select x.id::uuid, 'cccccccc-0000-0000-0000-00000000000a', x.n, x.e, 'employee', 'dddddddd-0000-0000-0000-000000000002', x.loc::uuid, x.code,
       (select id from designations where company_id = 'cccccccc-0000-0000-0000-00000000000a' and name = 'Machine Operator'), '2024-01-15', 'confirmed', x.shift::uuid
  from (values ('00000000-0000-0000-0000-0000000000a4', 'Suresh Pawar', 'suresh@acme.in', '22222222-2222-2222-2222-222222222222', 'E0120', 'aaaaaaaa-0000-0000-0000-000000000003'),
               ('00000000-0000-0000-0000-0000000000b6', 'Anita Kale', 'anita@acme.in', '22222222-2222-2222-2222-222222222222', 'E0121', 'aaaaaaaa-0000-0000-0000-000000000003'),
               ('00000000-0000-0000-0000-0000000000c7', 'Deepak More', 'deepak@acme.in', '11111111-1111-1111-1111-111111111111', 'E0122', 'aaaaaaaa-0000-0000-0000-000000000001')) x(id, n, e, loc, code, shift);
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a4', 'suresh@acme.in'), ('00000000-0000-0000-0000-0000000000b6', 'anita@acme.in'), ('00000000-0000-0000-0000-0000000000c7', 'deepak@acme.in');

-- demo company settings: punches up to 7 days old may be projected automatically (default 2), projection still off
insert into biometric_settings (company_id, auto_project_max_age_days) values ('cccccccc-0000-0000-0000-00000000000a', 7);

create temp table demo_key (agent uuid, k text);
do $$
declare
  cid uuid := 'cccccccc-0000-0000-0000-00000000000a';
  tz text := 'Asia/Kolkata';
  k record; aid uuid; aid2 uuid;
  d_main uuid; d_plant uuid; d_ware uuid; d_old uuid;
  t date := public.local_today('cccccccc-0000-0000-0000-00000000000a');
  hr uuid := '00000000-0000-0000-0000-0000000000b2'; adm uuid := '00000000-0000-0000-0000-0000000000a1';
begin
  select * into k from public.biometric_new_key();
  insert into public.biometric_agents (company_id, name, agent_identifier, version, created_by, last_heartbeat_at)
    values (cid, 'Pune Plant reception PC', 'pune-rcp-01', '0.1.0-demo', adm, now() - interval '3 minutes') returning id into aid;
  insert into public.biometric_agent_credentials (company_id, agent_id, key_prefix, key_hash) values (cid, aid, k.key_prefix, k.key_hash);
  insert into demo_key values (aid, k.agent_key);
  insert into public.biometric_agents (company_id, name, agent_identifier, version, created_by, last_heartbeat_at)
    values (cid, 'Andheri HQ server', 'ho-srv-01', '0.1.0-demo', adm, now() - interval '5 hours') returning id into aid2;

  insert into public.biometric_devices (company_id, location_id, name, manufacturer, model, serial_number, firmware_version, integration_method, agent_id, timezone, direction_mode, connection, device_auth, created_by, last_seen_at, last_successful_sync_at, clock_drift_s)
  values (cid, '22222222-2222-2222-2222-222222222222', 'Plant gate (In/Out keys)', 'essl', 'AiFace Mars', 'AF8K2311000457', 'Ver 8.0.4.3', 'sdk_pull', aid, tz, 'device', '{"deviceIp": "10.20.0.21", "port": "4370"}', 'comm_key', adm, now() - interval '4 minutes', now() - interval '95 minutes', 6)
  returning id into d_plant;
  insert into public.biometric_devices (company_id, location_id, name, manufacturer, model, serial_number, firmware_version, integration_method, agent_id, timezone, direction_mode, connection, device_auth, created_by, last_seen_at, last_successful_sync_at, clock_drift_s)
  values (cid, '11111111-1111-1111-1111-111111111111', 'HQ main entrance', 'zkteco', 'SpeedFace-V5L', 'CKUH201960123', 'ZAM180-NF 6.4.1', 'sdk_pull', aid, tz, 'first_last', '{"deviceIp": "10.20.0.40", "port": "4370"}', 'comm_key', adm, now() - interval '6 minutes', now() - interval '95 minutes', -12)
  returning id into d_main;
  insert into public.biometric_devices (company_id, location_id, name, manufacturer, model, serial_number, integration_method, agent_id, timezone, direction_mode, connection, created_by, last_seen_at, last_successful_sync_at)
  values (cid, '22222222-2222-2222-2222-222222222222', 'Warehouse reader', 'matrix', 'COSEC ARGO FACE', 'ARGO-FA-0091337', 'local_push', aid, tz, 'first_last', '{"deviceIp": "10.20.0.31", "receiverPort": "8082", "pushAuth": "unauthenticated_lan"}', adm, now() - interval '3 hours', now() - interval '3 hours')
  returning id into d_ware;
  insert into public.biometric_devices (company_id, location_id, name, manufacturer, model, serial_number, integration_method, agent_id, timezone, direction_mode, connection, status, created_by)
  values (cid, '11111111-1111-1111-1111-111111111111', 'Old canteen terminal', 'zkteco', 'K40', 'OIN7030057012', 'sdk_pull', aid2, tz, 'first_last', '{"deviceIp": "10.20.0.50", "port": "4370"}', 'disabled', adm)
  returning id into d_old;

  -- device-specific codes (the same code 201 is a different person on another device), set up by HR / Admin
  insert into public.biometric_employee_mappings (company_id, device_id, employee_id, employee_device_code, valid_from, created_by) values
    (cid, d_plant, '00000000-0000-0000-0000-0000000000a4', '201', now() - interval '40 days', hr),
    (cid, d_plant, '00000000-0000-0000-0000-0000000000b6', '202', now() - interval '40 days', hr),
    (cid, d_plant, '00000000-0000-0000-0000-0000000000e2', '203', now() - interval '40 days', hr),
    (cid, d_main, '00000000-0000-0000-0000-0000000000c7', '201', now() - interval '40 days', hr),
    (cid, d_main, '00000000-0000-0000-0000-0000000000e5', '105', now() - interval '40 days', hr),
    (cid, d_ware, '00000000-0000-0000-0000-0000000000b6', '7002', now() - interval '20 days', hr);
  -- one company-wide code (an explicit Admin decision): Anita's employee code, used in imported files
  insert into public.biometric_employee_mappings (company_id, device_id, employee_id, employee_device_code, valid_from, created_by)
    values (cid, null, '00000000-0000-0000-0000-0000000000b6', 'E0121', now() - interval '40 days', adm);
  -- a code re-assigned: ended with a reason (earlier punches stay with the earlier person)
  insert into public.biometric_employee_mappings (company_id, device_id, employee_id, employee_device_code, valid_from, valid_to, end_reason, created_by, ended_by)
    values (cid, d_main, '00000000-0000-0000-0000-0000000000b8', '107', now() - interval '200 days', now() - interval '25 days', 'Moved to remote work; code can be re-used', hr, hr);
end $$;

-- Punches go through the real gateway (as the Sync Agent sends them), oldest days first, and the real queue projects
-- each delivery, with projection switched on for the demo company only while this script runs.
update biometric_settings set projection_enabled = true where company_id = 'cccccccc-0000-0000-0000-00000000000a';

-- 4–2 days ago: an unauthenticated warehouse push (needs HR), Farhan's day with a pending correction (held), Anita pressing
-- the wrong keys (OUT in the morning, IN in the afternoon → correction needed), Deepak's day at HQ (HR corrects it below)
do $$
declare key text := (select k from demo_key); t date := public.local_today('cccccccc-0000-0000-0000-00000000000a'); r jsonb;
begin
  r := public.biometric_ingest(key, jsonb_build_object('batch_id', gen_random_uuid(), 'agent_version', '0.1.0-demo', 'events', jsonb_build_array(
    jsonb_build_object('manufacturer', 'matrix', 'serial', 'ARGO-FA-0091337', 'employee_code', '7002', 'local_time', (t - 4) || ' 11:30:00', 'record_seq', 3001),
    jsonb_build_object('manufacturer', 'matrix', 'serial', 'ARGO-FA-0091337', 'employee_code', '7002', 'local_time', (t - 4) || ' 11:30:30', 'record_seq', 3002),
    jsonb_build_object('manufacturer', 'essl', 'serial', 'AF8K2311000457', 'employee_code', '203', 'local_time', (t - 3) || ' 07:08:00', 'record_seq', 1008, 'direction', 'in'),
    jsonb_build_object('manufacturer', 'essl', 'serial', 'AF8K2311000457', 'employee_code', '203', 'local_time', (t - 3) || ' 16:01:00', 'record_seq', 1009, 'direction', 'out'),
    jsonb_build_object('manufacturer', 'essl', 'serial', 'AF8K2311000457', 'employee_code', '202', 'local_time', (t - 2) || ' 07:01:00', 'record_seq', 1006, 'direction', 'out', 'verification', 'fingerprint'),
    jsonb_build_object('manufacturer', 'essl', 'serial', 'AF8K2311000457', 'employee_code', '202', 'local_time', (t - 2) || ' 16:02:00', 'record_seq', 1007, 'direction', 'in', 'verification', 'fingerprint'),
    jsonb_build_object('manufacturer', 'zkteco', 'serial', 'CKUH201960123', 'employee_code', '201', 'local_time', (t - 2) || ' 09:41:00', 'record_seq', 2005),
    jsonb_build_object('manufacturer', 'zkteco', 'serial', 'CKUH201960123', 'employee_code', '201', 'local_time', (t - 2) || ' 18:32:00', 'record_seq', 2006))));
  raise notice 'older days: %', r - 'outcomes';
end $$;
call biometric_run_projection();

-- HR corrects Deepak's check-in two days ago (through the real request + decision functions, as the people involved)
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c7', false);
select request_correction(local_today(my_company()) - 2, 'wrong_time', at_local(my_company(), local_today(my_company()) - 2, '09:28'), null, 'Queue at the entrance machine; I was at my desk at 9:28');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b2', false);
select decide_correction((select id from attendance_corrections where employee_id = '00000000-0000-0000-0000-0000000000c7' and status = 'pending'), true, 'Confirmed with the floor supervisor');
reset role;
call biometric_run_projection();

-- yesterday: device In/Out keys at the plant (Anita presses IN twice), first-in/last-out at HQ (a lunch punch and a double
-- press), a punch matched with Rahul's web check-in, a code nobody is mapped to, a code whose mapping has ended
do $$
declare key text := (select k from demo_key); t date := public.local_today('cccccccc-0000-0000-0000-00000000000a'); r jsonb;
begin
  r := public.biometric_ingest(key, jsonb_build_object('batch_id', gen_random_uuid(), 'agent_version', '0.1.0-demo', 'events', jsonb_build_array(
    jsonb_build_object('manufacturer', 'essl', 'serial', 'AF8K2311000457', 'employee_code', '201', 'local_time', (t - 1) || ' 07:02:10', 'record_seq', 1001, 'direction', 'in', 'verification', 'face'),
    jsonb_build_object('manufacturer', 'essl', 'serial', 'AF8K2311000457', 'employee_code', '201', 'local_time', (t - 1) || ' 16:05:40', 'record_seq', 1002, 'direction', 'out', 'verification', 'face'),
    jsonb_build_object('manufacturer', 'essl', 'serial', 'AF8K2311000457', 'employee_code', '202', 'local_time', (t - 1) || ' 06:58:00', 'record_seq', 1003, 'direction', 'in', 'verification', 'fingerprint'),
    jsonb_build_object('manufacturer', 'essl', 'serial', 'AF8K2311000457', 'employee_code', '202', 'local_time', (t - 1) || ' 06:59:50', 'record_seq', 1004, 'direction', 'in', 'verification', 'fingerprint'),
    jsonb_build_object('manufacturer', 'essl', 'serial', 'AF8K2311000457', 'employee_code', '202', 'local_time', (t - 1) || ' 16:10:05', 'record_seq', 1005, 'direction', 'out', 'verification', 'fingerprint'),
    jsonb_build_object('manufacturer', 'essl', 'serial', 'AF8K2311000457', 'employee_code', '299', 'local_time', (t - 1) || ' 08:15:00', 'record_seq', 1010, 'direction', 'in'),
    jsonb_build_object('manufacturer', 'zkteco', 'serial', 'CKUH201960123', 'employee_code', '201', 'local_time', (t - 1) || ' 09:24:00', 'record_seq', 2001),
    jsonb_build_object('manufacturer', 'zkteco', 'serial', 'CKUH201960123', 'employee_code', '201', 'local_time', (t - 1) || ' 13:02:00', 'record_seq', 2002),
    jsonb_build_object('manufacturer', 'zkteco', 'serial', 'CKUH201960123', 'employee_code', '201', 'local_time', (t - 1) || ' 13:02:20', 'record_seq', 2003),
    jsonb_build_object('manufacturer', 'zkteco', 'serial', 'CKUH201960123', 'employee_code', '201', 'local_time', (t - 1) || ' 18:41:00', 'record_seq', 2004),
    jsonb_build_object('manufacturer', 'zkteco', 'serial', 'CKUH201960123', 'employee_code', '105', 'local_time', to_char((select at from public.attendance_events where employee_id = '00000000-0000-0000-0000-0000000000e5' and work_date = t - 1 and kind = 'in' and superseded_by is null order by at limit 1) at time zone 'Asia/Kolkata' + interval '2 minutes', 'YYYY-MM-DD HH24:MI:SS'), 'record_seq', 2007),
    jsonb_build_object('manufacturer', 'zkteco', 'serial', 'CKUH201960123', 'employee_code', '107', 'local_time', (t - 1) || ' 10:05:00', 'record_seq', 2010))));
  raise notice 'yesterday: %', r - 'outcomes';
end $$;
call biometric_run_projection();

-- today: Suresh in since the morning; Deepak in, with a later punch that is only a provisional check-out until the day closes
do $$
declare key text := (select k from demo_key); t date := public.local_today('cccccccc-0000-0000-0000-00000000000a'); r jsonb;
begin
  r := public.biometric_ingest(key, jsonb_build_object('batch_id', gen_random_uuid(), 'agent_version', '0.1.0-demo', 'events', jsonb_build_array(
    jsonb_build_object('manufacturer', 'essl', 'serial', 'AF8K2311000457', 'employee_code', '201', 'local_time', to_char(least(public.at_local('cccccccc-0000-0000-0000-00000000000a', t, '07:00'), now() - interval '100 minutes') at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS'), 'record_seq', 1011, 'direction', 'in', 'verification', 'face'),
    jsonb_build_object('manufacturer', 'zkteco', 'serial', 'CKUH201960123', 'employee_code', '201', 'local_time', to_char(least(public.at_local('cccccccc-0000-0000-0000-00000000000a', t, '09:20'), now() - interval '4 hours') at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS'), 'record_seq', 2008),
    jsonb_build_object('manufacturer', 'zkteco', 'serial', 'CKUH201960123', 'employee_code', '201', 'local_time', to_char(now() - interval '95 minutes', 'YYYY-MM-DD HH24:MI:SS'), 'record_seq', 2009))));
  raise notice 'today: %', r - 'outcomes';
end $$;
call biometric_run_projection();

-- an imported file (imports are stored but not counted automatically yet: "Imported" shows in the timeline as waiting)
do $$
declare cid uuid := 'cccccccc-0000-0000-0000-00000000000a'; b uuid; rid bigint; t date := public.local_today('cccccccc-0000-0000-0000-00000000000a');
begin
  insert into public.biometric_import_batches (company_id, file_name, file_sha256, rows, accepted, status, uploaded_by)
    values (cid, 'plant-gate-backup.csv', sha256(convert_to('demo-import', 'UTF8')), 1, 1, 'approved', '00000000-0000-0000-0000-0000000000b2') returning id into b;
  insert into public.biometric_raw_events (company_id, import_batch_id, employee_device_code, device_local_time, device_timezone, punch_at, source_auth, dedupe_key, dedupe_basis, raw_payload, payload_hash, direction, direction_source)
    values (cid, b, 'E0121', (t - 5) || ' 07:04:00', 'Asia/Kolkata', public.at_local(cid, t - 5, '07:04'), 'import', 'event_id:import-demo-1', 'event_id',
            '{"row": 1}', sha256(convert_to('import:demo:1', 'UTF8')), 'in', 'device') returning id into rid;
  insert into public.biometric_event_state (raw_event_id, company_id, employee_id, mapping_id, status, work_date)
    values (rid, cid, '00000000-0000-0000-0000-0000000000b6', (select id from public.biometric_employee_mappings where company_id = cid and device_id is null and employee_device_code = 'E0121'), 'stored', t - 5);
end $$;

call biometric_run_projection();
update biometric_settings set projection_enabled = false where company_id = 'cccccccc-0000-0000-0000-00000000000a';
drop table demo_key;

-- B5 DAT import (LOCAL DEMO ONLY): the eSSL X2008 as a file-import device (no agent, never contacted) and a demo
-- employee with the AttendOS code WR198. The mapping 10 → WR198 is NOT seeded: it is created in the app by an
-- authorised user, as in real use. The serial below is a placeholder, not the real device's.
insert into employees (id, company_id, full_name, email, role, department_id, home_location_id, emp_code, joining_date, employment_status)
values ('00000000-0000-0000-0000-0000000000e8', 'cccccccc-0000-0000-0000-00000000000a', 'Amol Jadhav', 'wr198@acme.in', 'employee',
        'dddddddd-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'WR198', '2024-06-01', 'confirmed');
insert into biometric_devices (company_id, location_id, name, manufacturer, model, serial_number, firmware_version, integration_method, timezone, direction_mode, created_by)
values ('cccccccc-0000-0000-0000-00000000000a', '11111111-1111-1111-1111-111111111111', 'Andheri HQ X2008 (USB export)', 'essl', 'X2008', 'DEMO-X2008-0001',
        '8.0.4.2-20180530', 'file_import', 'Asia/Kolkata', 'first_last', '00000000-0000-0000-0000-0000000000a1');
