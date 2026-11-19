# Biometric integration — proposed database schema and migration plan (Phase B1)

Status: **proposal. No SQL written or run.** Every table follows the existing rules: `company_id … default
public.my_company()` (or reached through `employee_id`), RLS on, `revoke all … from anon`, policies through
`my_company()` / `is_hr()` / `hr_of()`, `check_company_refs` on each foreign key to company data, `freeze_company_id`,
`audit()` trigger where HR/Admin change it. Writes only through checked functions.

## 1. New tables
### biometric_devices
`id uuid pk` · `company_id` · `location_id → locations` (office) · `name` · `manufacturer` (zkteco | essl | matrix |
other | mock) · `model` · `serial_number` · `firmware_version` · `integration_method` (sdk_pull | local_push |
vendor_software | file_import) · `adapter_type` (e.g. `zkteco.standalone_sdk`, `zkteco.adms`, `matrix.cosec_push`,
`mock`) · `agent_id → biometric_agents` (null for file import) · `timezone` (default company zone, `valid_timezone`)
· `direction_mode` (first_last | device) · `connection jsonb` (non-secret settings: IP, port, push path) ·
`status` (active | disabled) · `last_seen_at` · `last_successful_sync_at` · `clock_drift_s` · `cursor text` ·
`created_at` · `updated_at`.
Unique `(company_id, manufacturer, serial_number)`. Device secrets (comm keys, passwords) are **not** stored here —
they live only in the agent's local encrypted config (BIOMETRIC_SECURITY.md).

### biometric_agents
`id` · `company_id` · `name` · `agent_identifier` (random, shown in UI) · `key_hash` (SHA-256 of the key) ·
`key_prefix` (first 8 chars, for recognition) · `version` · `status` (active | revoked) · `last_heartbeat_at` ·
`last_ip` · `created_by` · `revoked_at` · `revoked_by` · `created_at` · `updated_at`. The plain key is shown once on
creation and never stored. Unique `key_hash`.

### biometric_employee_mappings
`id` · `company_id` · `device_id` (null = same code on all this company's devices) · `employee_id → employees`
(same company, checked) · `employee_device_code` · `status` (active | disabled) · `created_by` · `created_at` ·
`updated_at`. Partial unique index: one **active** mapping per `(company_id, coalesce(device_id), code)`; one active
per `(device_id, employee_id)`. History through `audit_log`. Mapping an inactive/exited person is refused.

### biometric_sync_runs
`id` · `company_id` · `agent_id` · `device_id` · `batch_id uuid` (unique per agent, replay detection) · `started_at`
· `completed_at` · `status` (ok | partial | failed) · `records_received` · `records_stored` · `duplicates` ·
`records_rejected` · `error_summary` · `agent_version`.

### biometric_raw_events
`id bigint` · `company_id` · `device_id` · `agent_id` · `sync_run_id` · `import_batch_id` · `external_event_id` ·
`employee_device_code` · `device_local_time text` · `device_utc_offset` · `punch_at timestamptz` · `direction` ·
`verification_method` · `raw_payload jsonb` (attendance record only; size-capped; template/photo fields stripped by
the gateway) · `payload_hash` · `received_at` · `employee_id` (after mapping) · `work_date` · `processing_status`
(stored | unmatched | flagged | projected | extra | reconciled | rejected | ignored) · `flag_reason` ·
`reconciled_with bigint` · `processed_at`.
Idempotency: unique `(device_id, external_event_id)` where not null; otherwise unique `(device_id,
employee_device_code, device_local_time, direction)`; `payload_hash` stored for audit. Indexes `(company_id,
processing_status)`, `(employee_id, work_date)`, `(device_id, received_at desc)`.

### biometric_event_errors
`id` · `company_id` · `raw_event_id` (null for batch-level errors) · `agent_id` · `device_id` · `kind`
(unmatched_employee | unknown_device | invalid_time | future_time | too_old | clock_drift | unsupported_format |
auth_failure | processing_failure | inactive_employee | leave_or_day_off) · `detail` · `attempts` · `last_attempt_at`
· `resolved_at` · `resolved_by` · `resolution`.
Auth failures with no valid key have no company and are only counted (rate limiter), not stored per company.

### biometric_import_batches (0013)
`id` · `company_id` · `file_name` · `file_sha256` · `rows` · `accepted` · `rejected` · `uploaded_by` · `approved_by`
· `status` (draft | approved | rejected) · timestamps. Rows land in `biometric_raw_events` with `import_batch_id`,
projected as `source = 'import'` only after approval.

## 2. Changes to existing tables (additive)
`attendance_events`: add `device_id uuid null → biometric_devices`, `biometric_event_id bigint null →
biometric_raw_events`, `inferred boolean not null default false`; add check `source in ('web','correction',
'biometric','import')` (all current rows comply). No existing column, value or function changes.
`companies`: add `biometric_reconcile_min int default 5`, `biometric_backfill_days int default 31`.

## 3. New functions (proposal)
| Function | Caller | Purpose |
|---|---|---|
| `register_agent(name)` → key once | Admin | Create agent key (hash stored) |
| `revoke_agent(id)` / `rotate_agent_key(id)` | Admin | Revoke / new key |
| `save_device(…)` / `disable_device(id)` | HR/Admin | Device directory |
| `map_device_code(device, code, employee)` / `disable_mapping(id)` | HR/Admin | Mapping; triggers reprocessing of that code's unmatched events |
| `biometric_ingest(p_key, p_batch jsonb)` | anon (agent) | Key → company; device check; store raw idempotently; normalise; map; validate; queue; per-event outcome |
| `biometric_heartbeat(p_key, p_status jsonb)` | anon (agent) | Agent + device health, clock drift |
| `work_date_at(emp, ts)` | internal | Overnight-aware work date for any time |
| `rebuild_biometric_day(emp, d)` | internal | Projection (architecture §5–7) |
| `process_biometric_queue(limit)` | scheduled (Supabase Cron) | Backlog processing |
| `reprocess_biometric_event(id)` / `dismiss_biometric_event(id, reason)` | HR/Admin | Review queue |
| `day_events(emp, d)` | can_see | Punch list with source/device for the register |
| `biometric_overview()` | HR/Admin | Overview counters |

## 4. Migration plan
| # | Content | Depends on |
|---|---|---|
| 0010_biometric_core | tables §1 (except import), indexes, RLS, guards, audit triggers | 0009 |
| 0011_biometric_ingest | agent key functions, `biometric_ingest`, `biometric_heartbeat`, rate/size limits, grants to anon for these two only | 0010 |
| 0012_biometric_projection | `attendance_events` additions, `work_date_at`, `rebuild_biometric_day`, reconciliation, review functions, `day_events`, cron job | 0011 |
| 0013_biometric_import | import batches + approval | 0012 |
Each migration: tested with `npm run test:db` (new suites + existing 360 checks must still pass), added to
`verify_hosted.sql`, `delete_company.sql`, the security matrix and 07-DATA-RETENTION.md in the same commit.

## 5. Rollback considerations
- Migrations are forward-only. All changes are additive; existing app punching does not depend on them.
- **Switch off without schema changes:** revoke all agent keys and disable devices → no new biometric events.
- **Remove biometric attendance from results:** delete projected rows `source = 'biometric'` for a company/date range
  in an approved, audited script (raw events kept) → days recalculate from app/correction events only.
- **Remove the module:** a later migration drops the functions and tables after the above; the extra
  `attendance_events` columns are nullable and can stay.
- Database restore rules (05-ROLLBACK.md) apply unchanged; after a restore agents re-upload from their queue and
  idempotency removes duplicates.
