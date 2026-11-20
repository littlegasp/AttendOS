-- AttendOS 0010: biometric core (Phase B3.2). Design: docs/biometric/BIOMETRIC_B3_1_DB_DESIGN.md.
-- Tables, constraints, row level security, grants, guards, audit, agent credentials and the Admin/HR functions.
-- Nothing here is callable anonymously, nothing writes attendance, and no existing table or function changes.
-- The device gateway (0011), attendance projection (0012) and file import (0013) come later.
-- Requires the btree_gist extension (exclusion constraints for mapping validity). Check first with
-- supabase/deploy/check_biometric_prereqs.sql (read-only).

create schema if not exists extensions;
create extension if not exists btree_gist with schema extensions;

-- ================================================================ helpers (internal; no grants)
-- Refuses known biometric-template / image keys anywhere in a JSON object, and caps the size. Used in checks.
create function public.biometric_payload_ok(p jsonb, max_bytes int default 4096) returns boolean
language sql immutable set search_path = public as $$
  select p is null or (
    jsonb_typeof(p) = 'object' and octet_length(p::text) <= max_bytes
    and not jsonb_path_exists(p,
      'lax $.** ? (@.type() == "object").keyvalue() ? (@.key like_regex "(template|finger|face|photo|image|picture|palm|iris|vein|biodata)" flag "i")',
      '{}', true))
$$;

-- Any change refused (used for raw events, reviews and the no-delete rules).
create function public.biometric_refuse_change() returns trigger
language plpgsql set search_path = public as $$
begin
  raise exception '% cannot be changed or deleted (%).', tg_table_name, lower(tg_op) using errcode = '42501';
end $$;

-- ================================================================ 1. settings (one row per company; defaults when absent)
create table public.biometric_settings (
  company_id uuid primary key default public.my_company() references public.companies (id),
  reconcile_min int not null default 5 check (reconcile_min between 0 and 30),
  backfill_days int not null default 31 check (backfill_days between 1 and 92),
  double_press_s int not null default 60 check (double_press_s between 0 and 600),
  min_session_min int not null default 30 check (min_session_min between 5 and 240),
  day_close_after_min int not null default 120 check (day_close_after_min between 30 and 239),
  projection_enabled boolean not null default false,
  auto_project_max_age_days int not null default 2 check (auto_project_max_age_days between 0 and 31),
  future_tolerance_s int not null default 120 check (future_tolerance_s between 0 and 600),
  drift_flag_s int not null default 300 check (drift_flag_s between 30 and 3600),
  updated_by uuid references public.employees (id),
  updated_at timestamptz not null default now(),
  check (auto_project_max_age_days <= backfill_days)
);

create function public.biometric_settings_for(c uuid) returns public.biometric_settings
language plpgsql stable security definer set search_path = public as $$
declare s public.biometric_settings;
begin
  select * into s from public.biometric_settings where company_id = c;
  if not found then -- the column defaults above (a test checks the two stay equal)
    s.company_id := c; s.reconcile_min := 5; s.backfill_days := 31; s.double_press_s := 60; s.min_session_min := 30;
    s.day_close_after_min := 120; s.projection_enabled := false; s.auto_project_max_age_days := 2; s.future_tolerance_s := 120;
    s.drift_flag_s := 300;
  end if;
  return s;
end $$;

-- ================================================================ 2. agents and their credentials
create table public.biometric_agents (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null default public.my_company() references public.companies (id),
  name text not null check (length(trim(name)) between 2 and 80),
  agent_identifier text not null check (agent_identifier ~ '^[A-Za-z0-9._-]{3,64}$'),
  version text check (version is null or length(version) <= 40),
  status text not null default 'active' check (status in ('active', 'revoked')),
  last_heartbeat_at timestamptz,
  last_ip inet,
  created_by uuid references public.employees (id),
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid references public.employees (id),
  revoke_reason text,
  updated_at timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, agent_identifier),
  check ((status = 'revoked') = (revoked_at is not null))
);

-- Key material lives only here: no policy, no grant, no generic audit (the audit log is readable by HR).
-- key_hash = SHA-256 of the whole key; the key itself is shown once and never stored.
create table public.biometric_agent_credentials (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id),
  agent_id uuid not null,
  key_prefix text not null unique check (key_prefix ~ '^[0-9a-f]{12}$'),
  key_hash bytea not null unique check (octet_length(key_hash) = 32),
  created_at timestamptz not null default now(),
  created_by uuid references public.employees (id),
  expires_at timestamptz,
  revoked_at timestamptz,
  foreign key (company_id, agent_id) references public.biometric_agents (company_id, id) on delete cascade
);
create index on public.biometric_agent_credentials (agent_id);

-- ================================================================ 3. devices
create table public.biometric_devices (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null default public.my_company() references public.companies (id),
  location_id uuid references public.locations (id),
  name text not null check (length(trim(name)) between 1 and 60),
  manufacturer text not null check (manufacturer in ('zkteco', 'essl', 'matrix', 'other', 'mock')),
  model text not null check (length(trim(model)) between 1 and 60),
  serial_number text not null check (serial_number ~ '^[A-Za-z0-9._-]{3,64}$'),
  firmware_version text check (firmware_version is null or length(firmware_version) <= 60),
  integration_method text not null check (integration_method in ('sdk_pull', 'local_push', 'vendor_software', 'file_import')),
  adapter_type text check (adapter_type is null or adapter_type ~ '^[a-z0-9_.-]{1,40}$'),
  agent_id uuid,
  timezone text not null default 'Asia/Kolkata' check (public.valid_timezone(timezone)),
  direction_mode text not null default 'first_last' check (direction_mode in ('first_last', 'device')),
  -- non-secret connection details only (address, port, path); secrets are refused
  connection jsonb not null default '{}' check (jsonb_typeof(connection) = 'object' and octet_length(connection::text) <= 2048
    and not jsonb_path_exists(connection, 'lax $.** ? (@.type() == "object").keyvalue() ? (@.key like_regex "(pass|secret|key|token|comm)" flag "i")', '{}', true)),
  status text not null default 'active' check (status in ('active', 'disabled')),
  last_seen_at timestamptz,
  last_successful_sync_at timestamptz,
  clock_drift_s int,
  created_by uuid references public.employees (id),
  updated_by uuid references public.employees (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, id),
  foreign key (company_id, agent_id) references public.biometric_agents (company_id, id),
  check (integration_method = 'file_import' or agent_id is not null)
);
create unique index biometric_devices_serial_key on public.biometric_devices (company_id, manufacturer, upper(serial_number));

-- ================================================================ 4. employee code mappings (effective-dated history)
create table public.biometric_employee_mappings (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null default public.my_company() references public.companies (id),
  device_id uuid, -- null = company-wide (an explicit Admin decision)
  employee_id uuid not null references public.employees (id),
  employee_device_code text not null check (employee_device_code ~ '^[A-Za-z0-9_-]{1,32}$'), -- exactly as the device reports it
  valid_from timestamptz not null,
  valid_to timestamptz,
  end_reason text,
  created_by uuid references public.employees (id),
  ended_by uuid references public.employees (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, id),
  foreign key (company_id, device_id) references public.biometric_devices (company_id, id),
  check (valid_to is null or valid_to > valid_from),
  check ((valid_to is null) = (end_reason is null) and (valid_to is null) = (ended_by is null)),
  check (end_reason is null or length(trim(end_reason)) >= 5),
  -- the database, not the screen, refuses overlapping validity (also under concurrent edits)
  constraint bm_device_code_no_overlap exclude using gist
    (device_id with =, employee_device_code with =, tstzrange(valid_from, valid_to, '[)') with &&) where (device_id is not null),
  constraint bm_company_code_no_overlap exclude using gist
    (company_id with =, employee_device_code with =, tstzrange(valid_from, valid_to, '[)') with &&) where (device_id is null),
  constraint bm_device_person_one_code exclude using gist
    (device_id with =, employee_id with =, tstzrange(valid_from, valid_to, '[)') with &&) where (device_id is not null),
  constraint bm_company_person_one_code exclude using gist
    (company_id with =, employee_id with =, tstzrange(valid_from, valid_to, '[)') with &&) where (device_id is null)
);
create index on public.biometric_employee_mappings (company_id, employee_device_code, valid_from);
create index on public.biometric_employee_mappings (employee_id);

-- ================================================================ 5. import batches (used from 0013)
create table public.biometric_import_batches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null default public.my_company() references public.companies (id),
  file_name text not null check (length(file_name) between 1 and 200),
  file_sha256 bytea not null check (octet_length(file_sha256) = 32),
  rows int not null default 0 check (rows >= 0),
  accepted int not null default 0 check (accepted >= 0),
  rejected int not null default 0 check (rejected >= 0),
  status text not null default 'draft' check (status in ('draft', 'approved', 'rejected')),
  uploaded_by uuid references public.employees (id),
  approved_by uuid references public.employees (id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, id),
  unique (company_id, file_sha256)
);

-- ================================================================ 6. sync runs (the agents' audit trail; replay = same batch_id)
create table public.biometric_sync_runs (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies (id),
  agent_id uuid not null,
  batch_id uuid not null,
  device_id uuid,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  status text not null default 'ok' check (status in ('running', 'ok', 'partial', 'failed', 'replay')),
  received int not null default 0 check (received >= 0),
  stored int not null default 0 check (stored >= 0),
  confirmed_duplicates int not null default 0 check (confirmed_duplicates >= 0),
  possible_duplicates int not null default 0 check (possible_duplicates >= 0),
  conflicts int not null default 0 check (conflicts >= 0),
  rejected int not null default 0 check (rejected >= 0),
  error_summary text check (error_summary is null or length(error_summary) <= 2000),
  agent_version text check (agent_version is null or length(agent_version) <= 40),
  client_ip inet,
  response jsonb check (response is null or octet_length(response::text) <= 65536),
  unique (company_id, id),
  unique (agent_id, batch_id),
  foreign key (company_id, agent_id) references public.biometric_agents (company_id, id),
  foreign key (company_id, device_id) references public.biometric_devices (company_id, id)
);
create index on public.biometric_sync_runs (company_id, started_at desc);

-- ================================================================ 7. raw events (immutable evidence)
create table public.biometric_raw_events (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies (id),
  device_id uuid,
  import_batch_id uuid,
  agent_id uuid,
  sync_run_id bigint,
  external_event_id text check (external_event_id is null or length(external_event_id) <= 128),
  record_seq bigint,
  occurrence int not null default 1 check (occurrence >= 1),
  employee_device_code text not null check (employee_device_code ~ '^[A-Za-z0-9_-]{1,32}$'),
  -- time: the original device reading is kept as sent, next to its zone/offset, the normalised instant and server receipt
  device_local_time text not null check (device_local_time ~ '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(:\d{2}(\.\d{1,6})?)?$'),
  device_utc_offset text check (device_utc_offset is null or device_utc_offset ~ '^[+-](0\d|1[0-4]):[0-5]\d$'),
  device_timezone text not null check (public.valid_timezone(device_timezone)),
  punch_at timestamptz not null,
  received_at timestamptz not null default now(),
  clock_drift_s int check (clock_drift_s is null or abs(clock_drift_s) <= 31536000),
  time_flags text[] not null default '{}' check (time_flags <@ array['clock_drift', 'dst_ambiguous', 'offset_tz_mismatch', 'future_within_tolerance', 'late_backfill']),
  direction text check (direction is null or direction in ('in', 'out')),
  direction_source text not null default 'none' check (direction_source in ('device', 'none')),
  verification_method text check (verification_method is null or verification_method ~ '^[a-z_]{1,32}$'),
  source_auth text not null check (source_auth in ('authenticated', 'unauthenticated_lan', 'import')),
  raw_payload jsonb check (public.biometric_payload_ok(raw_payload)),
  payload_hash bytea check (payload_hash is null or octet_length(payload_hash) = 32),
  dedupe_key text not null check (dedupe_key ~ '^(event_id|seq|fp):.{1,190}$'),
  dedupe_basis text not null check (dedupe_basis in ('event_id', 'record_seq', 'fingerprint')),
  unique (company_id, id),
  foreign key (company_id, device_id) references public.biometric_devices (company_id, id),
  foreign key (company_id, import_batch_id) references public.biometric_import_batches (company_id, id),
  foreign key (company_id, agent_id) references public.biometric_agents (company_id, id),
  foreign key (company_id, sync_run_id) references public.biometric_sync_runs (company_id, id),
  check (num_nonnulls(device_id, import_batch_id) = 1),
  check ((import_batch_id is not null) = (source_auth = 'import')),
  check (device_id is null or agent_id is not null),
  check (split_part(dedupe_key, ':', 1) = case dedupe_basis when 'record_seq' then 'seq' when 'fingerprint' then 'fp' else 'event_id' end),
  check ((direction is null) = (direction_source = 'none'))
);
create unique index biometric_raw_events_dedupe_key on public.biometric_raw_events (company_id, device_id, import_batch_id, dedupe_key) nulls not distinct;
create index on public.biometric_raw_events (company_id, received_at desc);
create index on public.biometric_raw_events (device_id, punch_at);
create index on public.biometric_raw_events (company_id, employee_device_code, punch_at);

-- Insert guard: server receipt time is set here; the normalised instant must match the original device reading;
-- rejection and review rules from the company's settings; device ownership by the sending agent.
create function public.biometric_raw_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  s public.biometric_settings := public.biometric_settings_for(new.company_id);
  lt timestamp := new.device_local_time::timestamp;
  expected timestamptz;
  by_zone timestamptz := lt at time zone new.device_timezone;
  off_before interval := (lt - interval '3 hours') - ((lt - interval '3 hours') at time zone new.device_timezone at time zone 'UTC');
  off_after interval := (lt + interval '3 hours') - ((lt + interval '3 hours') at time zone new.device_timezone at time zone 'UTC');
  flags text[] := new.time_flags;
begin
  new.received_at := now(); -- never supplied by the caller, never used as the punch time
  expected := case when new.device_utc_offset is not null then (lt - new.device_utc_offset::interval) at time zone 'UTC' else by_zone end;
  if new.punch_at is distinct from expected then
    raise exception 'punch_at must equal the device-local time in its zone/offset (expected %, got %)', expected, new.punch_at using errcode = '23514';
  end if;
  if new.punch_at > new.received_at + make_interval(secs => s.future_tolerance_s) then
    raise exception 'Punch time is later than the allowed future tolerance' using errcode = '23514';
  end if;
  if new.punch_at < new.received_at - make_interval(days => s.backfill_days) then
    raise exception 'Punch time is older than the backfill limit' using errcode = '23514';
  end if;
  if new.punch_at > new.received_at then flags := array_append(flags, 'future_within_tolerance'); end if;
  if new.punch_at < new.received_at - make_interval(days => s.auto_project_max_age_days) then flags := array_append(flags, 'late_backfill'); end if;
  if new.clock_drift_s is not null and abs(new.clock_drift_s) > s.drift_flag_s then flags := array_append(flags, 'clock_drift'); end if;
  if new.device_utc_offset is not null and expected is distinct from by_zone then flags := array_append(flags, 'offset_tz_mismatch'); end if;
  if new.device_utc_offset is null and off_before is distinct from off_after then flags := array_append(flags, 'dst_ambiguous'); end if;
  new.time_flags := array(select distinct f from unnest(flags) f order by 1);

  if new.device_id is not null then
    if not exists (select 1 from public.biometric_devices d where d.id = new.device_id and d.agent_id = new.agent_id and d.status = 'active') then
      raise exception 'The device does not belong to the sending agent or is disabled' using errcode = '42501';
    end if;
    if new.sync_run_id is not null and not exists (select 1 from public.biometric_sync_runs r where r.id = new.sync_run_id and r.agent_id = new.agent_id) then
      raise exception 'The sync run belongs to another agent' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger raw_guard before insert on public.biometric_raw_events for each row execute function public.biometric_raw_guard();
create trigger raw_immutable before update or delete on public.biometric_raw_events for each row execute function public.biometric_refuse_change();
create trigger raw_no_truncate before truncate on public.biometric_raw_events for each statement execute function public.biometric_refuse_change();

-- ================================================================ 8. processing state (1:1 with a raw event)
create table public.biometric_event_state (
  raw_event_id bigint primary key,
  company_id uuid not null references public.companies (id),
  employee_id uuid references public.employees (id),
  mapping_id uuid,
  work_date date,
  status text not null default 'stored' check (status in ('stored', 'unmatched', 'flagged', 'projected', 'provisional_out', 'extra',
    'possible_duplicate', 'reconciled', 'after_correction', 'rejected', 'dismissed')),
  flag_reasons text[] not null default '{}',
  projected_event_id bigint references public.attendance_events (id),
  projection_slot text,
  reconciled_with bigint references public.attendance_events (id),
  duplicate_of bigint,
  decided boolean not null default false,
  processed_at timestamptz,
  version int not null default 1,
  updated_at timestamptz not null default now(),
  foreign key (company_id, raw_event_id) references public.biometric_raw_events (company_id, id),
  foreign key (company_id, mapping_id) references public.biometric_employee_mappings (company_id, id),
  foreign key (company_id, duplicate_of) references public.biometric_raw_events (company_id, id),
  check ((employee_id is null) = (mapping_id is null)),
  check (status <> 'unmatched' or mapping_id is null),
  check (status not in ('stored', 'projected', 'provisional_out', 'reconciled') or mapping_id is not null)
);
create index on public.biometric_event_state (company_id, status) where not decided;
create index on public.biometric_event_state (employee_id, work_date);

-- Attribution is frozen once set: the mapping/person an event was processed with never changes silently.
create function public.biometric_state_guard() returns trigger
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
create trigger state_guard before insert or update on public.biometric_event_state for each row execute function public.biometric_state_guard();
create trigger state_no_delete before delete on public.biometric_event_state for each row execute function public.biometric_refuse_change();

-- ================================================================ 9. review decisions (insert-only)
create table public.biometric_event_reviews (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies (id),
  raw_event_id bigint not null,
  action text not null check (action in ('map', 'accept_time', 'dismiss', 'confirm_duplicate', 'not_duplicate', 'keep_extra', 'keep_correction', 'reprocess')),
  reason text check (reason is null or length(reason) <= 1000),
  decided_by uuid not null references public.employees (id),
  decided_role text not null check (decided_role in ('admin', 'hr')),
  decided_at timestamptz not null default now(),
  state_before jsonb not null,
  state_after jsonb not null,
  foreign key (company_id, raw_event_id) references public.biometric_raw_events (company_id, id),
  check (action not in ('accept_time', 'dismiss', 'not_duplicate') or length(trim(coalesce(reason, ''))) >= 5)
);
create index on public.biometric_event_reviews (raw_event_id);
create trigger reviews_append_only before update or delete on public.biometric_event_reviews for each row execute function public.biometric_refuse_change();
create trigger reviews_no_truncate before truncate on public.biometric_event_reviews for each statement execute function public.biometric_refuse_change();

-- ================================================================ 10. errors
create table public.biometric_event_errors (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies (id),
  raw_event_id bigint,
  agent_id uuid,
  device_id uuid,
  kind text not null check (kind in ('unmatched_employee', 'unknown_device', 'invalid_time', 'future_time', 'too_old', 'clock_drift', 'tz_ambiguous',
    'unsupported_format', 'processing_failure', 'inactive_employee', 'leave_or_day_off', 'conflict')),
  detail jsonb not null default '{}' check (public.biometric_payload_ok(detail) and not (detail ? 'raw_payload') and not (detail ? 'payload')),
  payload jsonb check (public.biometric_payload_ok(payload)), -- e.g. the second payload of a conflict; Admin-only function access
  attempts int not null default 1 check (attempts >= 1),
  created_at timestamptz not null default now(),
  last_attempt_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references public.employees (id),
  resolution text check (resolution is null or length(resolution) <= 1000),
  foreign key (company_id, raw_event_id) references public.biometric_raw_events (company_id, id),
  foreign key (company_id, agent_id) references public.biometric_agents (company_id, id),
  foreign key (company_id, device_id) references public.biometric_devices (company_id, id)
);
create index on public.biometric_event_errors (company_id, created_at desc) where resolved_at is null;

create function public.biometric_error_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.company_id <> old.company_id or new.kind <> old.kind or new.raw_event_id is distinct from old.raw_event_id
     or new.detail <> old.detail or new.payload is distinct from old.payload or new.created_at <> old.created_at then
    raise exception 'Only the attempt count and the resolution of an error can change' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger error_guard before update on public.biometric_event_errors for each row execute function public.biometric_error_guard();
create trigger error_no_delete before delete on public.biometric_event_errors for each row execute function public.biometric_refuse_change();

-- ================================================================ guards on configuration
create function public.biometric_mapping_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not coalesce((select active from public.employees where id = new.employee_id), false) then
      raise exception 'That employee is switched off. Map codes to active employees only.' using errcode = '23514';
    end if;
    if new.device_id is not null and (select status from public.biometric_devices where id = new.device_id) <> 'active' then
      raise exception 'That device is disabled.' using errcode = '23514';
    end if;
    return new;
  end if;
  -- update: only ending an open mapping is allowed; history is never rewritten
  if old.valid_to is not null then raise exception 'This mapping has already ended' using errcode = '42501'; end if;
  if (new.id, new.company_id, new.device_id, new.employee_id, new.employee_device_code, new.valid_from, new.created_by, new.created_at)
     is distinct from (old.id, old.company_id, old.device_id, old.employee_id, old.employee_device_code, old.valid_from, old.created_by, old.created_at) then
    raise exception 'A mapping cannot be edited; end it and add a new one' using errcode = '42501';
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger mapping_guard before insert or update on public.biometric_employee_mappings for each row execute function public.biometric_mapping_guard();
create trigger mapping_no_delete before delete on public.biometric_employee_mappings for each row execute function public.biometric_refuse_change();

create function public.biometric_device_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.location_id is not null and (tg_op = 'INSERT' or new.location_id is distinct from old.location_id)
     and not coalesce((select active from public.locations where id = new.location_id), false) then
    raise exception 'That office is not in use. Choose an office that is in use.' using errcode = '23514';
  end if;
  if new.agent_id is not null and (tg_op = 'INSERT' or new.agent_id is distinct from old.agent_id)
     and (select status from public.biometric_agents where id = new.agent_id) <> 'active' then
    raise exception 'That Sync Agent is revoked.' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and (new.manufacturer, upper(new.serial_number)) is distinct from (old.manufacturer, upper(old.serial_number))
     and exists (select 1 from public.biometric_raw_events r where r.device_id = old.id) then
    raise exception 'The device has punches; its manufacturer and serial number cannot change. Add a new device instead.' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger device_guard before insert or update on public.biometric_devices for each row execute function public.biometric_device_guard();
create trigger device_no_delete before delete on public.biometric_devices for each row execute function public.biometric_refuse_change();
create trigger agent_no_delete before delete on public.biometric_agents for each row execute function public.biometric_refuse_change();

-- same-company references to existing tables
create trigger company_refs before insert or update on public.biometric_devices
  for each row execute function public.check_company_refs('location_id:locations', 'created_by:employees', 'updated_by:employees');
create trigger company_refs before insert or update on public.biometric_employee_mappings
  for each row execute function public.check_company_refs('employee_id:employees', 'created_by:employees', 'ended_by:employees');
create trigger company_refs before insert or update on public.biometric_event_state
  for each row execute function public.check_company_refs('employee_id:employees');
create trigger company_refs before insert on public.biometric_event_reviews
  for each row execute function public.check_company_refs('decided_by:employees');
create trigger company_refs before insert or update on public.biometric_agents
  for each row execute function public.check_company_refs('created_by:employees', 'revoked_by:employees');
create trigger company_refs before insert or update on public.biometric_settings
  for each row execute function public.check_company_refs('updated_by:employees');
create trigger company_refs before insert or update on public.biometric_import_batches
  for each row execute function public.check_company_refs('uploaded_by:employees', 'approved_by:employees');
create trigger company_refs before insert or update on public.biometric_event_errors
  for each row execute function public.check_company_refs('resolved_by:employees');

-- company_id never moves
create trigger freeze_company before update on public.biometric_settings for each row execute function public.freeze_company_id();
create trigger freeze_company before update on public.biometric_agents for each row execute function public.freeze_company_id();
create trigger freeze_company before update on public.biometric_agent_credentials for each row execute function public.freeze_company_id();
create trigger freeze_company before update on public.biometric_devices for each row execute function public.freeze_company_id();
create trigger freeze_company before update on public.biometric_employee_mappings for each row execute function public.freeze_company_id();
create trigger freeze_company before update on public.biometric_import_batches for each row execute function public.freeze_company_id();
create trigger freeze_company before update on public.biometric_sync_runs for each row execute function public.freeze_company_id();
create trigger freeze_company before update on public.biometric_event_errors for each row execute function public.freeze_company_id();

-- audit (configuration only; none of these tables holds a secret)
create trigger audit_biometric_settings after insert or update on public.biometric_settings for each row execute function public.audit();
create trigger audit_biometric_agents after insert or update on public.biometric_agents for each row execute function public.audit();
create trigger audit_biometric_devices after insert or update on public.biometric_devices for each row execute function public.audit();
create trigger audit_biometric_mappings after insert or update on public.biometric_employee_mappings for each row execute function public.audit();

-- ================================================================ safe view of raw events (no payload, no hash)
create view public.biometric_raw_events_safe with (security_invoker = true, security_barrier = true) as
  select r.id, r.company_id, r.device_id, r.import_batch_id, r.agent_id, r.sync_run_id, r.external_event_id, r.record_seq, r.occurrence,
         r.employee_device_code, r.device_local_time, r.device_utc_offset, r.device_timezone, r.punch_at, r.received_at,
         r.clock_drift_s, r.time_flags, r.direction, r.direction_source, r.verification_method, r.source_auth, r.dedupe_basis
    from public.biometric_raw_events r;

-- ================================================================ internal functions for the gateway (0011) — no grants
create function public.biometric_new_key(out key_prefix text, out agent_key text, out key_hash bytea)
language plpgsql volatile set search_path = public as $$
begin
  -- gen_random_uuid() draws on the server's strong random source: two v4 UUIDs = 244 random bits.
  key_prefix := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
  agent_key := 'bak_' || key_prefix || '_' ||
    translate(encode(sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text, 'UTF8')), 'base64'), '+/=', '-_');
  key_hash := sha256(convert_to(agent_key, 'UTF8'));
end $$;

-- Returns the agent for a valid key, otherwise null — the same null for every kind of failure (no oracle),
-- and the key is never written anywhere or included in an error.
create function public.biometric_check_agent_key(p_key text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare c record;
begin
  if p_key is null or length(p_key) <> 60 or p_key !~ '^bak_[0-9a-f]{12}_[A-Za-z0-9_-]{43}$' then return null; end if;
  select cr.agent_id, cr.key_hash into c
    from public.biometric_agent_credentials cr
    join public.biometric_agents a on a.id = cr.agent_id and a.company_id = cr.company_id
    join public.companies co on co.id = cr.company_id
   where cr.key_prefix = substr(p_key, 5, 12) and cr.revoked_at is null and (cr.expires_at is null or cr.expires_at > now())
     and a.status = 'active' and co.active;
  if c.agent_id is null or c.key_hash <> sha256(convert_to(p_key, 'UTF8')) then return null; end if;
  return c.agent_id;
end $$;

-- The device (by manufacturer + serial) only if it is active and assigned to this agent.
create function public.biometric_device_for_agent(p_agent uuid, p_manufacturer text, p_serial text) returns uuid
language sql stable security definer set search_path = public as $$
  select d.id from public.biometric_devices d
   where d.agent_id = p_agent and d.status = 'active' and d.manufacturer = p_manufacturer and upper(d.serial_number) = upper(p_serial)
$$;

-- Mapping in force for a punch: the device's own mapping first, then a company-wide one, else none.
create function public.biometric_resolve_mapping(p_company uuid, p_device uuid, p_code text, p_at timestamptz) returns uuid
language sql stable security definer set search_path = public as $$
  select id from (
    select m.id, 0 as rank from public.biometric_employee_mappings m
     where p_device is not null and m.company_id = p_company and m.device_id = p_device and m.employee_device_code = p_code
       and m.valid_from <= p_at and (m.valid_to is null or m.valid_to > p_at)
    union all
    select m.id, 1 from public.biometric_employee_mappings m
     where m.company_id = p_company and m.device_id is null and m.employee_device_code = p_code
       and m.valid_from <= p_at and (m.valid_to is null or m.valid_to > p_at)
  ) x order by rank limit 1
$$;

-- Processed punches (attributed or decided) whose mapping would differ from the current one. Used after a change.
create function public.biometric_reassigned_count(p_company uuid, p_code text, out n int, out latest text)
language sql stable security definer set search_path = public as $$
  select count(*)::int, max(r.device_local_time)
    from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
   where s.company_id = p_company and r.employee_device_code = p_code and (s.status <> 'unmatched' or s.decided)
     and s.mapping_id is distinct from public.biometric_resolve_mapping(p_company, r.device_id, r.employee_device_code, r.punch_at)
$$;

-- ================================================================ Admin / HR functions
create function public.biometric_require(p_admin boolean) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare cid uuid := public.my_company();
begin
  if cid is null or not public.is_hr() or (p_admin and not public.is_admin()) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return cid;
end $$;

create function public.biometric_save_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); s public.biometric_settings := public.biometric_settings_for(cid);
begin
  s := jsonb_populate_record(s, p - 'company_id' - 'updated_by' - 'updated_at');
  s.updated_by := public.my_employee_id(); s.updated_at := now();
  insert into public.biometric_settings values (s.*)
  on conflict (company_id) do update set reconcile_min = excluded.reconcile_min, backfill_days = excluded.backfill_days,
    double_press_s = excluded.double_press_s, min_session_min = excluded.min_session_min, day_close_after_min = excluded.day_close_after_min,
    projection_enabled = excluded.projection_enabled, auto_project_max_age_days = excluded.auto_project_max_age_days,
    future_tolerance_s = excluded.future_tolerance_s, drift_flag_s = excluded.drift_flag_s,
    updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  return jsonb_build_object('ok', true);
end $$;

create function public.biometric_register_agent(p_name text, p_identifier text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); aid uuid; k record;
begin
  insert into public.biometric_agents (company_id, name, agent_identifier, created_by)
    values (cid, trim(p_name), trim(p_identifier), public.my_employee_id()) returning id into aid;
  select * into k from public.biometric_new_key();
  insert into public.biometric_agent_credentials (company_id, agent_id, key_prefix, key_hash, created_by)
    values (cid, aid, k.key_prefix, k.key_hash, public.my_employee_id());
  insert into public.audit_log (company_id, action, target, target_id, after)
    values (cid, 'issue_key', 'biometric_agents', aid::text, jsonb_build_object('key_prefix', k.key_prefix));
  return jsonb_build_object('ok', true, 'agent_id', aid, 'key_prefix', k.key_prefix, 'agent_key', k.agent_key,
                            'message', 'Copy this key now. It is shown only once and cannot be recovered.');
end $$;

-- New key; the previous live keys keep working for 24 hours so the agent can switch without a gap.
create function public.biometric_rotate_agent_key(p_agent uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); k record;
begin
  if not exists (select 1 from public.biometric_agents where id = p_agent and company_id = cid and status = 'active') then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  update public.biometric_agent_credentials set expires_at = least(coalesce(expires_at, 'infinity'), now() + interval '24 hours')
   where agent_id = p_agent and revoked_at is null;
  select * into k from public.biometric_new_key();
  insert into public.biometric_agent_credentials (company_id, agent_id, key_prefix, key_hash, created_by)
    values (cid, p_agent, k.key_prefix, k.key_hash, public.my_employee_id());
  insert into public.audit_log (company_id, action, target, target_id, after)
    values (cid, 'rotate_key', 'biometric_agents', p_agent::text, jsonb_build_object('key_prefix', k.key_prefix, 'previous_keys_expire_at', now() + interval '24 hours'));
  return jsonb_build_object('ok', true, 'key_prefix', k.key_prefix, 'agent_key', k.agent_key,
                            'message', 'Copy this key now. The previous key keeps working for 24 hours.');
end $$;

create function public.biometric_revoke_agent(p_agent uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true);
begin
  if length(trim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'message', 'Give a reason (at least 5 characters).'); end if;
  update public.biometric_agents set status = 'revoked', revoked_at = now(), revoked_by = public.my_employee_id(), revoke_reason = trim(p_reason), updated_at = now()
   where id = p_agent and company_id = cid and status = 'active';
  if not found then raise exception 'Not allowed' using errcode = '42501'; end if;
  update public.biometric_agent_credentials set revoked_at = now() where agent_id = p_agent and revoked_at is null;
  return jsonb_build_object('ok', true);
end $$;

create function public.biometric_save_device(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); did uuid;
begin
  if p_id is null then
    insert into public.biometric_devices (company_id, location_id, name, manufacturer, model, serial_number, firmware_version, integration_method,
                                          adapter_type, agent_id, timezone, direction_mode, connection, created_by, updated_by)
    values (cid, (p ->> 'location_id')::uuid, trim(p ->> 'name'), p ->> 'manufacturer', trim(p ->> 'model'), trim(p ->> 'serial_number'),
            nullif(trim(p ->> 'firmware_version'), ''), p ->> 'integration_method', nullif(p ->> 'adapter_type', ''), (p ->> 'agent_id')::uuid,
            coalesce(p ->> 'timezone', public.company_tz(cid)), coalesce(p ->> 'direction_mode', 'first_last'), coalesce(p -> 'connection', '{}'),
            public.my_employee_id(), public.my_employee_id())
    returning id into did;
  else
    update public.biometric_devices set
      location_id = coalesce((p ->> 'location_id')::uuid, location_id), name = coalesce(trim(p ->> 'name'), name),
      manufacturer = coalesce(p ->> 'manufacturer', manufacturer), model = coalesce(trim(p ->> 'model'), model),
      serial_number = coalesce(trim(p ->> 'serial_number'), serial_number), firmware_version = coalesce(p ->> 'firmware_version', firmware_version),
      integration_method = coalesce(p ->> 'integration_method', integration_method), adapter_type = coalesce(p ->> 'adapter_type', adapter_type),
      agent_id = case when p ? 'agent_id' then (p ->> 'agent_id')::uuid else agent_id end, timezone = coalesce(p ->> 'timezone', timezone),
      connection = coalesce(p -> 'connection', connection), updated_by = public.my_employee_id(), updated_at = now()
     where id = p_id and company_id = cid returning id into did;
    if did is null then raise exception 'Not allowed' using errcode = '42501'; end if;
  end if;
  return jsonb_build_object('ok', true, 'device_id', did);
end $$;

create function public.biometric_set_device_status(p_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true);
begin
  update public.biometric_devices set status = p_status, updated_by = public.my_employee_id(), updated_at = now() where id = p_id and company_id = cid;
  if not found then raise exception 'Not allowed' using errcode = '42501'; end if;
  return jsonb_build_object('ok', true);
end $$;

create function public.biometric_set_direction_mode(p_id uuid, p_mode text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true);
begin
  update public.biometric_devices set direction_mode = p_mode, updated_by = public.my_employee_id(), updated_at = now() where id = p_id and company_id = cid;
  if not found then raise exception 'Not allowed' using errcode = '42501'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Map a device code. Device-specific by default; company-wide only for Admin with explicit confirmation.
-- Refuses any change that would move an already processed punch to another person (whole call rolled back);
-- attributes waiting unmatched punches it covers, each at its own punch time.
create function public.biometric_save_mapping(p_code text, p_device uuid, p_employee uuid, p_valid_from timestamptz,
                                               p_confirm_company_wide boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cid uuid := public.biometric_require(false);
  code text := trim(coalesce(p_code, ''));
  mid uuid;
  moved record;
  n int;
begin
  if p_device is null and not public.is_admin() then
    raise exception 'Company-wide mappings are an Admin decision.' using errcode = '42501';
  end if;
  if p_device is null and not coalesce(p_confirm_company_wide, false) then
    return jsonb_build_object('ok', false, 'message', 'Confirm that this code means the same person on every device without its own mapping.');
  end if;
  if code !~ '^[A-Za-z0-9_-]{1,32}$' then return jsonb_build_object('ok', false, 'message', 'Use letters, digits, - or _ (up to 32), exactly as the device shows it.'); end if;
  if p_valid_from is null then return jsonb_build_object('ok', false, 'message', 'Choose when the mapping takes effect.'); end if;
  if not public.hr_of(p_employee) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_device is not null and not exists (select 1 from public.biometric_devices where id = p_device and company_id = cid) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(cid::text || ':' || code, 41));

  if exists (select 1 from public.biometric_employee_mappings m where m.company_id = cid and m.employee_device_code = code
               and m.device_id is not distinct from p_device and tstzrange(m.valid_from, m.valid_to, '[)') && tstzrange(p_valid_from, null, '[)')) then
    return jsonb_build_object('ok', false, 'message', format('Code %s is already mapped on this %s in that period. End that mapping first.', code,
                              case when p_device is null then 'company-wide scope' else 'device' end));
  end if;
  if exists (select 1 from public.biometric_employee_mappings m where m.company_id = cid and m.employee_id = p_employee
               and m.device_id is not distinct from p_device and tstzrange(m.valid_from, m.valid_to, '[)') && tstzrange(p_valid_from, null, '[)')) then
    return jsonb_build_object('ok', false, 'message', 'This person already has a different code here in that period.');
  end if;

  begin
    insert into public.biometric_employee_mappings (company_id, device_id, employee_id, employee_device_code, valid_from, created_by)
      values (cid, p_device, p_employee, code, p_valid_from, public.my_employee_id()) returning id into mid;
    select * into moved from public.biometric_reassigned_count(cid, code);
    if moved.n > 0 then
      raise exception using errcode = 'BIO01', message = format('This would move %s already processed punch%s to a different person (latest: device time %s). '
        'Choose an effective time after it; processed punches keep the mapping they were processed with.', moved.n, case when moved.n = 1 then '' else 'es' end, moved.latest);
    end if;
  exception
    when sqlstate 'BIO01' then return jsonb_build_object('ok', false, 'message', sqlerrm);
    when exclusion_violation then return jsonb_build_object('ok', false, 'message', 'This mapping overlaps another one for the same code or person.');
  end;

  update public.biometric_event_state s set employee_id = (select employee_id from public.biometric_employee_mappings where id = mid),
         mapping_id = mid, status = 'stored', processed_at = null
    from public.biometric_raw_events r
   where r.id = s.raw_event_id and s.company_id = cid and s.status = 'unmatched' and not s.decided and r.employee_device_code = code
     and public.biometric_resolve_mapping(cid, r.device_id, code, r.punch_at) = mid;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'mapping_id', mid, 'attributed', n);
end $$;

create function public.biometric_end_mapping(p_id uuid, p_at timestamptz, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(false); m public.biometric_employee_mappings; moved record;
begin
  select * into m from public.biometric_employee_mappings where id = p_id and company_id = cid;
  if m.id is null then raise exception 'Not allowed' using errcode = '42501'; end if;
  if m.device_id is null and not public.is_admin() then raise exception 'Company-wide mappings are an Admin decision.' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(cid::text || ':' || m.employee_device_code, 41));
  select * into m from public.biometric_employee_mappings where id = p_id;
  if m.valid_to is not null then return jsonb_build_object('ok', false, 'message', 'This mapping has already ended.'); end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then return jsonb_build_object('ok', false, 'message', 'Give a reason (at least 5 characters).'); end if;
  if p_at is null or p_at <= m.valid_from then return jsonb_build_object('ok', false, 'message', 'The end must be after the mapping started.'); end if;
  begin
    update public.biometric_employee_mappings set valid_to = p_at, end_reason = trim(p_reason), ended_by = public.my_employee_id() where id = p_id;
    select * into moved from public.biometric_reassigned_count(cid, m.employee_device_code);
    if moved.n > 0 then
      raise exception using errcode = 'BIO01', message = format('This would move %s already processed punch%s to a different person (latest: device time %s). '
        'Choose an end after it.', moved.n, case when moved.n = 1 then '' else 'es' end, moved.latest);
    end if;
  exception when sqlstate 'BIO01' then return jsonb_build_object('ok', false, 'message', sqlerrm);
  end;
  return jsonb_build_object('ok', true);
end $$;

-- One decision per punch (row lock + decided flag + version check). Effects on attendance come with 0012.
create function public.biometric_review_event(p_raw bigint, p_action text, p_reason text, p_expected_version int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cid uuid := public.biometric_require(false);
  s public.biometric_event_state;
  next_status text;
  after public.biometric_event_state;
begin
  select * into s from public.biometric_event_state where raw_event_id = p_raw and company_id = cid for update;
  if s.raw_event_id is null then raise exception 'Not allowed' using errcode = '42501'; end if;
  if s.decided then return jsonb_build_object('ok', false, 'message', 'This punch has already been decided.'); end if;
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
    when s.status = 'after_correction' and p_action = 'dismiss' then 'dismissed' end;
  if next_status is null then return jsonb_build_object('ok', false, 'message', 'That decision does not apply to this punch.'); end if;
  if p_action in ('accept_time', 'dismiss', 'not_duplicate') and length(trim(coalesce(p_reason, ''))) < 5 then
    return jsonb_build_object('ok', false, 'message', 'A reason is required (at least 5 characters).');
  end if;
  -- accepting the time of a punch that has no mapping yet leaves it waiting for a mapping (not decided)
  if next_status = 'stored' and s.mapping_id is null then next_status := 'unmatched'; end if;
  update public.biometric_event_state set status = next_status, decided = (next_status <> 'unmatched') where raw_event_id = p_raw returning * into after;
  insert into public.biometric_event_reviews (company_id, raw_event_id, action, reason, decided_by, decided_role, state_before, state_after)
    values (cid, p_raw, p_action, nullif(trim(coalesce(p_reason, '')), ''), public.my_employee_id(), public.my_role(), to_jsonb(s), to_jsonb(after));
  insert into public.audit_log (company_id, action, target, target_id, before, after)
    values (cid, 'review_' || p_action, 'biometric_event_state', p_raw::text, to_jsonb(s), to_jsonb(after));
  return jsonb_build_object('ok', true, 'status', next_status);
end $$;

-- Raw payloads: Admin of the same company only; every read is written to the audit log.
create function public.biometric_raw_payload(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); p jsonb;
begin
  select raw_payload into p from public.biometric_raw_events where id = p_id and company_id = cid;
  if not found then raise exception 'Not allowed' using errcode = '42501'; end if;
  insert into public.audit_log (company_id, action, target, target_id) values (cid, 'view_raw_payload', 'biometric_raw_events', p_id::text);
  return p;
end $$;

create function public.biometric_error_payload(p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); p jsonb;
begin
  select payload into p from public.biometric_event_errors where id = p_id and company_id = cid;
  if not found then raise exception 'Not allowed' using errcode = '42501'; end if;
  insert into public.audit_log (company_id, action, target, target_id) values (cid, 'view_error_payload', 'biometric_event_errors', p_id::text);
  return p;
end $$;

-- ================================================================ row level security and grants
do $$
declare t text;
begin
  foreach t in array array['biometric_settings', 'biometric_agents', 'biometric_agent_credentials', 'biometric_devices', 'biometric_employee_mappings',
                           'biometric_import_batches', 'biometric_sync_runs', 'biometric_raw_events', 'biometric_event_state',
                           'biometric_event_reviews', 'biometric_event_errors'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
    if t <> 'biometric_agent_credentials' then
      execute format('create policy bio_read on public.%I for select to authenticated using (company_id = public.my_company() and public.is_hr())', t);
    end if;
  end loop;
end $$;
revoke all on table public.biometric_raw_events_safe from public, anon, authenticated;
revoke all on sequence public.biometric_sync_runs_id_seq, public.biometric_raw_events_id_seq, public.biometric_event_reviews_id_seq,
  public.biometric_event_errors_id_seq from public, anon, authenticated;

-- Admin/HR read (row level security limits rows to their own company). Raw payloads and conflict payloads are
-- excluded by column: a direct select of them is refused; the safe view is the normal path.
grant select on public.biometric_settings, public.biometric_agents, public.biometric_devices, public.biometric_employee_mappings,
  public.biometric_import_batches, public.biometric_sync_runs, public.biometric_event_state, public.biometric_event_reviews to authenticated;
grant select (id, company_id, device_id, import_batch_id, agent_id, sync_run_id, external_event_id, record_seq, occurrence, employee_device_code,
  device_local_time, device_utc_offset, device_timezone, punch_at, received_at, clock_drift_s, time_flags, direction, direction_source,
  verification_method, source_auth, dedupe_basis) on public.biometric_raw_events to authenticated;
grant select (id, company_id, raw_event_id, agent_id, device_id, kind, detail, attempts, created_at, last_attempt_at, resolved_at, resolved_by, resolution)
  on public.biometric_event_errors to authenticated;
grant select on public.biometric_raw_events_safe to authenticated;

-- Functions: nothing for PUBLIC or anon; signed-in users only the checked Admin/HR functions.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'biometric\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
grant execute on function public.biometric_save_settings(jsonb), public.biometric_register_agent(text, text), public.biometric_rotate_agent_key(uuid),
  public.biometric_revoke_agent(uuid, text), public.biometric_save_device(uuid, jsonb), public.biometric_set_device_status(uuid, text),
  public.biometric_set_direction_mode(uuid, text), public.biometric_save_mapping(text, uuid, uuid, timestamptz, boolean),
  public.biometric_end_mapping(uuid, timestamptz, text), public.biometric_review_event(bigint, text, text, int),
  public.biometric_raw_payload(bigint), public.biometric_error_payload(bigint) to authenticated;
