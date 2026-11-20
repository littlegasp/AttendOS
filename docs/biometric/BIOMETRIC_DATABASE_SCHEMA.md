# Biometric integration — database schema and migration plan (Phase B1, revision 2)

Status: **design. No SQL written or run.** Every table follows the existing rules: `company_id … default
public.my_company()` (or reached through `employee_id`), RLS on, `revoke all … from anon`, policies through
`my_company()` / `is_hr()` / `is_admin()` / `hr_of()`, `check_company_refs` on every foreign key to company data,
`freeze_company_id`, `audit()` triggers on HR/Admin-changed tables. Writes only through checked functions.

## 1. Tables
### biometric_devices
`id uuid pk` · `company_id` · `location_id → locations` · `name` · `manufacturer` (zkteco | essl | matrix | other |
mock) · `model` · `serial_number` · `firmware_version` · `integration_method` (sdk_pull | local_push |
vendor_software | file_import) · `adapter_type` · `agent_id → biometric_agents` · `timezone` (`valid_timezone`,
default company zone) · `direction_mode` (first_last | device) · `connection jsonb` (non-secret: IP, port, path) ·
`status` (active | disabled) · `last_seen_at` · `last_successful_sync_at` · `clock_drift_s` · `agent_cursor text`
(informational; the agent owns the real cursor) · `created_at` · `updated_at`.
Unique `(company_id, manufacturer, serial_number)`. Device secrets are never stored here.

### biometric_agents
`id` · `company_id` · `name` · `agent_identifier` · `key_hash` (SHA-256) · `key_prefix` · `version` · `status`
(active | revoked) · `last_heartbeat_at` · `last_ip` · `created_by` · `revoked_at` · `revoked_by` · timestamps.
Unique `key_hash`. The key is shown once and never stored.

### biometric_employee_mappings
`id` · `company_id` · `device_id` (**null = company-wide mapping**) · `employee_id → employees` ·
`employee_device_code` · `valid_from timestamptz` · `valid_to timestamptz null` · `status` (active | disabled) ·
`created_by` · timestamps.
- **Precedence:** a device-specific mapping valid at the punch time wins over a company-wide one; otherwise the
  company-wide one; otherwise `unmatched`. Never a name or approximate match.
- **Validity:** a punch maps by its own `punch_at` within `[valid_from, valid_to)`, so a code reused after someone
  leaves never re-assigns the earlier person's history.
- Constraints (exclusion/partial unique, active rows only): no overlapping validity for the same
  `(company_id, code)` company-wide; no overlapping validity for the same `(device_id, code)`; one company-wide code
  per employee at a time; one code per `(device_id, employee)` at a time. Mapping to an inactive/exited employee or
  another company's employee is refused (`check_company_refs`, `check_active_refs`).
- Changing a mapping = close the old row (`valid_to`) and add a new one; history stays (and in `audit_log`).

### biometric_import_batches
`id` · `company_id` · `file_name` · `file_sha256` · `rows` · `accepted` · `rejected` · `uploaded_by` ·
`approved_by` · `approved_at` · `status` (draft | approved | rejected) · timestamps.

### biometric_sync_runs
`id` · `company_id` · `agent_id` · `batch_id uuid` · `device_id null` · `started_at` · `completed_at` · `status`
(ok | partial | failed | replay) · `records_received` · `stored` · `confirmed_duplicates` · `possible_duplicates` ·
`rejected` · `error_summary` · `agent_version` · `response jsonb` (stored outcomes, for replay).
Unique `(agent_id, batch_id)`: a replayed batch returns the stored response and processes nothing.

### biometric_raw_events
Content (immutable after insert — a trigger refuses updates to these columns):
`id bigint` · `company_id` · `device_id` (null only for imports) · `agent_id` · `sync_run_id` · `import_batch_id` ·
`external_event_id` · `record_seq` · `occurrence int` · `employee_device_code` · `device_local_time text` ·
`device_utc_offset text` · `device_timezone` · `punch_at timestamptz` · `direction` · `direction_source` ·
`verification_method` · `raw_payload jsonb` (attendance record only; size-capped; template/photo keys stripped) ·
`payload_hash` · `dedupe_key` · `dedupe_basis` (event_id | record_seq | fingerprint) · `received_at` ·
`clock_drift_s` · `time_flags text[]`.
Processing (updated only by the projection/review functions, every change audited):
`employee_id` · `mapping_id` · `work_date` · `processing_status` (stored | unmatched | flagged | projected | extra |
possible_duplicate | reconciled | after_correction | rejected | dismissed) · `flag_reasons text[]` ·
`projected_event_id → attendance_events` · `reconciled_with → attendance_events` · `duplicate_of → biometric_raw_events`
· `processed_at`.
Check: exactly one of `device_id` / `import_batch_id` is set.

### biometric_event_reviews (HR decisions, insert-only)
`id` · `company_id` · `raw_event_id` · `action` (map | accept_flag | dismiss | reprocess | confirm_duplicate |
not_duplicate) · `note` (required for dismiss) · `decided_by` · `decided_at`. The raw event is never edited; its
processing state follows from these decisions.

### biometric_event_errors
`id` · `company_id` · `raw_event_id null` · `agent_id` · `device_id` · `kind` (unmatched_employee | unknown_device
| invalid_time | future_time | too_old | clock_drift | tz_ambiguous | unsupported_format | processing_failure |
inactive_employee | leave_or_day_off | conflict) · `detail` · `attempts` · `last_attempt_at` · `resolved_at` ·
`resolved_by` · `resolution`. Failed key checks have no company and are only counted.

## 2. Changes to existing tables (additive)
`attendance_events`:
- new nullable columns: `device_id → biometric_devices`, `biometric_event_id → biometric_raw_events` (on delete
  restrict), `import_batch_id → biometric_import_batches`, `projection_slot text`, `direction_basis` (device |
  inferred_first_last), `provisional boolean default false`, `voided_at`, `void_reason` (D7a);
- check `source in ('web','correction','biometric','import')` (all existing rows comply);
- check (required references):
  `source = 'biometric'` ⇒ `device_id`, `biometric_event_id`, `projection_slot` not null;
  `source = 'import'` ⇒ `import_batch_id`, `biometric_event_id`, `projection_slot` not null;
  `source in ('web','correction')` ⇒ all four null;
- unique `(employee_id, work_date, projection_slot)` where `projection_slot is not null` — the **stable slot identity**;
- unique `(biometric_event_id)` where not voided — a raw punch fills at most one live slot.
- open question 5: FK `superseded_by → attendance_corrections(id)` (validated against existing data first).
`companies`: `biometric_reconcile_min int default 5`, `biometric_backfill_days int default 31`,
`biometric_double_press_s int default 60`, `biometric_min_session_min int default 30`.
No existing column, value or row is changed.

## 3. Duplicate and replay protection
Order of preference for an event's identity (`dedupe_key`, unique per `device_id`):
1. **Manufacturer event ID** — `event_id:<external_event_id>` when the adapter declares the ID unique and stable.
2. **Stable record sequence / record identifier** — `seq:<record_seq>` when the adapter declares the device's log
   index (or vendor sequence number) stable across reads and not reused after a log clear.
3. **Fallback fingerprint** — `fp:` + SHA-256 of `employee_device_code | device_local_time | direction |
   verification_method | occurrence`, where `occurrence` is the 1-based position of that exact record among
   identical records in the device's log order, assigned by the adapter. Two genuine punches with identical
   attributes therefore get occurrence 1 and 2 and are both kept; reading the same log again assigns the same
   numbers, so nothing duplicates.
Outcomes:
| Case | Result |
|---|---|
| Same `dedupe_key`, same `payload_hash` | **Confirmed duplicate** — not stored again; counted in the sync run |
| Same `dedupe_key`, different `payload_hash` | **Conflict** — the original is kept; the new payload is logged in `biometric_event_errors` (`conflict`) for review; nothing overwritten |
| Different key, same person and device within the double-press window | **Possible duplicate** — stored; projection uses one; HR can confirm or reject |
| Replayed `batch_id` | Stored response returned; nothing processed |
| Agent restart, re-send of unconfirmed rows | Same keys → confirmed duplicates |
Time-window rules are used only to mark possible duplicates, never to discard data.

## 4. Functions
| Function | Caller | Purpose |
|---|---|---|
| `register_agent(name)` → key once; `revoke_agent`; `rotate_agent_key` | Admin | Agent credentials |
| `save_device(…)`, `disable_device(id)`, `set_direction_mode(id, mode)` | HR/Admin | Devices |
| `save_mapping(…)`, `end_mapping(id, at)` | HR/Admin | Mapping with validity; reprocesses that code's unmatched punches |
| `biometric_ingest(p_key, p_batch jsonb)` | anon (agent) | Key → company → device → normalise → dedupe → store → map → validate → queue days → outcomes |
| `biometric_heartbeat(p_key, p_status jsonb)` | anon (agent) | Health, drift, cursors |
| `work_date_at(emp, ts)` | internal | Overnight-aware work date for any time |
| `project_biometric_day(emp, d)` | internal | Stable projection (architecture §7) |
| `process_biometric_queue(limit)` | Supabase Cron | Backlog in small chunks |
| `review_biometric_event(id, action, note)` | HR/Admin | Review queue → `biometric_event_reviews` → re-projection |
| `day_events(emp, d)` | `can_see` | Every punch of a day with source, device, role, basis, flags |
| `biometric_overview()` | HR/Admin | Overview counters |
| `biometric_raw_payload(id)` | Admin | Raw payload (the only way to read it) |

## 5. Access
| Data | Admin | HR | Manager | Employee |
|---|---|---|---|---|
| Devices, agents (no key hash), sync runs, errors | read | read | — | — |
| Mappings | read/write | read/write (own scope) | — | — |
| Raw events — normalised fields | read | read (own scope) | — | — |
| Raw payload (`raw_payload`) | via `biometric_raw_payload` only | — | — | — |
| Punch list with source (`day_events`) | as register scope | as register scope | team | self |
No one updates raw content; anon reads nothing.

## 6. Retention, deletion, restore
- **Retention:** raw events are the evidence for projected attendance, so they are kept as long as the company's
  attendance data is kept (07-DATA-RETENTION.md); removed only by company deletion or an approved purge that first
  handles the projected rows that reference them (foreign key `restrict` prevents accidental removal).
- **Company deletion:** `delete_company.sql` gains the new tables in dependency order (first clear the two-way links
  `projected_event_id` / `reconciled_with` / `duplicate_of`; biometric `attendance_events` rows are deleted with the
  company's other events; then reviews, errors, raw events, sync runs, mappings,
  devices, import batches, agents) and keeps its other-companies-unchanged check; the 21-table count becomes 29.
- **Restore:** a whole-database restore brings back raw and projected rows together. Agents then re-send what they
  hold (confirmed punches kept 14 days); de-duplication drops what the restored database already has. A
  `public`-only repair must keep raw ↔ projected links (`biometric_event_id`, `projected_event_id`) consistent; a
  consistency check is added to `check_auth_links.sql`'s companion `check_biometric_links.sql` (read-only).

## 7. Migration plan
| # | Content |
|---|---|
| 0010_biometric_core | Tables §1, constraints, indexes, RLS, guards, audit triggers, raw-content immutability trigger |
| 0011_biometric_ingest | Agent keys, `biometric_ingest`, `biometric_heartbeat`, dedupe, limits; anon EXECUTE on these two only |
| 0012_biometric_projection | `attendance_events` additions (§2), `work_date_at`, `project_biometric_day`, reconciliation, review functions, `day_events`, cron; if D7a approved, the voided-row condition in the engine functions; optional `superseded_by` FK |
| 0013_biometric_import | Import batches, upload/approve |
Each: new DB test suites + the existing 360 checks; `verify_hosted.sql`, `delete_company.sql`, security matrix and
data-retention document updated in the same commit.

## 8. Rollback
Forward-only migrations, all additive. Switch off: revoke agent keys, disable devices. Remove biometric attendance
from results: void (or, in an approved script, delete) `source = 'biometric'` rows for a company/date range — raw
events kept. Remove the module: a later migration drops functions and tables after that; the new nullable columns
on `attendance_events` can stay. Restore rules in 05-ROLLBACK.md apply unchanged.
