# Biometric B3.1 — database foundation audit and design

Status: **revision 5.1 (20 Nov 2026)** — B3.3 approved for local development; §13.7 test figures corrected to match the revision 5 evidence ZIP (633 / 79 / 18), no code changed. Revision 5 — B3.3 review corrections (§13.8). Revision 4 — B3.2 approved for local development; **B3.3 gateway implemented locally (§13)**. Earlier: B3.1 owner corrections (§11), SQL review corrections (§11.7–11.8) and **B3.2 implemented locally**:
`supabase/migrations/0010_biometric_core.sql` (§12). No SQL has been run against any Supabase project; no application
code changed; no extension installed on any hosted project. Baseline: branch `feature/biometric-b1`, commit `d8146c9` (B2 approved). Starting point:
BIOMETRIC_DATABASE_SCHEMA.md (B1 r2/r3). Every finding below was checked against the migrations 0001–0009, the test
harness (`supabase/tests`) and the owner scripts (`supabase/deploy`); line references are to those files.

Legend: **[verified]** read in the repository · **[assumed]** not verifiable without the hosted project (to be
checked read-only before B3.2) · **[change]** departs from the B1 design, with the reason.

---

## 1. Findings — the existing database

### 1.1 Tenancy
- One project serves every company. `companies` (uuid id, `timezone`, `active`). Company-owned tables carry
  `company_id not null default public.my_company()`; `attendance_events`, `attendance_corrections`,
  `attendance_attempts`, roster/shift rows reach their company **through `employee_id`** (0003:55–74). [verified]
- Helpers (all `security definer`, pinned `search_path`): `my_employee_id()`, `my_company()`, `my_role()`,
  `is_hr()` (admin or hr), `is_admin()`, `emp_company(emp)`, `in_my_company(emp)`, `manages(emp)`, `can_see(emp)`,
  `hr_of(emp)` (0003:114–169, 0005:21–33). [verified]
- **HR scope is the whole company.** There is no department- or location-limited HR scope; B1's "HR (own scope)"
  therefore means "own company". [verified]
- `check_company_refs(...)` (0003:188) takes `column:table` pairs and compares `company_id` of the referenced row —
  it **casts the referenced id to uuid**, so it cannot guard references to `bigint` ids. [verified]
- `freeze_company_id()` (0003:245) refuses moving a row to another company **only when `auth.uid()` is not null**
  (owner scripts and Auth are exempt). [verified]
- `company_tz()` answers only for the caller's own company when someone is signed in (0008). [verified]

### 1.2 Attendance engine
- `attendance_events` (0001:161, 0002:110–117): `bigint` identity id, `employee_id`, `kind` (in/out/break_start/
  break_end), `at timestamptz default now()` — commented **"server time is the only time that counts"** —
  `work_mode` (office/remote, not null), `location_id`, `distance_m`, `accuracy_m`, `verified boolean not null`,
  `source text default 'web'` (no check constraint; values today: `web`, `correction`), `work_date date not null`,
  `correction_id → attendance_corrections`, `superseded_by bigint` (**no foreign key**). No `company_id`. [verified]
- Writes only through `punch()` and `decide_correction()` (security definer). Authenticated users have SELECT only;
  the security-matrix test asserts that. [verified]
- **Every engine reader filters `superseded_by is null`**: 20 occurrences (0002 ×9, 0003 ×7, 0006 ×4) in
  `day_for(_core)`, `session_state`, `my_today(_core)`, `dashboard_summary_core`, leave checks, register/report
  functions. Any new "hidden row" concept would have to be added to all of them. [verified]
- `session_state(emp)` takes the **latest non-superseded event across all time** (0002:147). A row with a future
  `at` would make the person look "working" until then and block web check-in. [verified]
- `day_for` pairs events in time order; a single `in` with no `out` makes the day `working` / `missing_checkout`.
  [verified]
- Work date: `work_date_for_checkin(emp)` decides yesterday-vs-today for overnight shifts **using `now()` only**
  (0003:506). There is no "work date for an arbitrary time" function. [verified]
- Locking: `punch()` serialises per person with `pg_advisory_xact_lock(hashtextextended(emp::text, 7))`;
  `decide_correction()` uses `select … for update` on the correction row and **does not take lock 7**. Other lock
  keys in use: 11 (last admin), 21 (leave), 31 (invitations). [verified]
- Corrections: approval marks the earliest `in` / latest `out` of that day `superseded_by = correction id` and
  inserts `source = 'correction'` rows; `attendance_corrections.decided_by = auth.uid()` (older convention — the
  project rule is now `my_employee_id()`). [verified]
- `verification_log()` labels events `corrected` / `verified` / `not_required` from `source` and `verified`
  (0003:799). A biometric row would currently be shown as GPS-verified or "not required". [verified]

### 1.3 Audit
- `audit_log` (company_id, actor, actor_employee, action, target, target_id, before, after, at, source). Append-only
  (trigger refuses update/delete/truncate; no grants). `audit_stamp()` sets actor from `auth.uid()`; with no signed-in
  user the source is `system` and the actor is null. [verified]
- Generic `audit()` trigger stores **`to_jsonb(new)` — every column of the row** — and HR can read the audit log
  (`audit_read`, own company). A secret stored in an audited table would therefore leak to HR. [verified]

### 1.4 Permissions and tests
- Pattern: functions revoked from `public, anon, authenticated` then granted explicitly; tables have no anon grants;
  RLS on every table. [verified]
- `security_matrix_test.sql` asserts from the catalog: RLS on every table; anon has no table privilege; **anon can
  execute only `company_brand`**; no function executable by PUBLIC; every definer pins `search_path`; then a
  role × company matrix for every table and callable function. Catalog checks apply automatically to new tables. [verified]
- Test harness: throwaway local Postgres, `auth_stub.sql` (roles `anon`/`authenticated`, `auth.uid()` from a setting),
  migrations and suites interleaved in `run.sh` (360 checks). It **does not emulate Supabase's default privileges**
  and loads **no extensions**. [verified]
- Supabase API roles have short default statement timeouts (anon ≈ 3 s, authenticated ≈ 8 s) [assumed — Supabase
  defaults; to be read on the project]. The owner's rule stands: the timeout is not raised.
- The new hosted project was created with **"Grant API access to new tables automatically" off** and **RLS on new
  tables on** (owner's screenshot, 20 Nov 2026). Migrations grant explicitly, so they work either way. [verified from
  screenshot + migrations]

### 1.5 Retention and deletion
- `deploy/delete_company.sql`: one transaction, dry run then `DELETE <slug>`, fixed list of **21 tables**, `disable
  trigger user` on each (needed to remove append-only audit rows), other-companies-unchanged guard. Foreign-key
  triggers are system triggers and stay active, so **deletion order must respect foreign keys**. [verified]

### 1.6 B1 statements corrected by this audit
| B1 statement | Reality | Effect on the design |
|---|---|---|
| `check_company_refs` on every reference | uuid only | composite foreign keys for biometric↔biometric references (§2.2) |
| `check_active_refs` reusable | employees-specific | new `biometric_mapping_guard()` / `biometric_device_guard()` |
| HR "own scope" | company-wide only | policies use `is_hr()` + same company |
| `audit()` on agents | would copy the key hash into the audit log | secrets moved to a separate, unaudited, unreadable table (§2.1) |
| Voided-row filter is a small change (D7a) | 20 engine filters in ~10 functions | recommendation changed: no voiding column in B3 (§7, Q1) |
| Cron-based projection optional | anon timeout makes in-request projection unsafe | queue + scheduled processing kept, required (§4.4) |

---

## 2. Proposed schema

### 2.1 Tables (11) — B1's 8 plus three [correction: revision 1 said 10; the settings, credentials and state tables make 11]
All: RLS on, `revoke all … from public, anon, authenticated`, `company_id uuid not null default public.my_company()
references companies(id)`, `freeze_company_id` trigger, `unique (company_id, id)` (target of composite FKs),
`created_at`/`updated_at`. "Refs" = `check_company_refs` arguments for references to existing tables.

**biometric_settings** [change — B1 put four columns on `companies`]
`company_id pk` · `reconcile_min int 5 (0–30)` · `backfill_days int 31 (1–92)` · `double_press_s int 60 (0–600)` ·
`min_session_min int 30` · `day_close_after_min int 120` · `projection_enabled boolean default false` ·
`auto_project_max_age_days int 2` · `future_tolerance_s int 120` · `drift_flag_s int 300`.
Why: the `co_admin` policy lets an Admin update any `companies` column directly from the app; a separate table keeps
these rules behind checked functions, leaves `companies` untouched and makes the module removable.
`projection_enabled` is the per-company switch for staged roll-out (store first, project later).

**biometric_agents**
`id uuid` · `name (2–80)` · `agent_identifier` (unique per company) · `version` · `status active|revoked` ·
`last_heartbeat_at` · `last_ip inet` · `created_by → employees` · `revoked_at` · `revoked_by → employees`.
No key material. Audited (generic `audit()` is safe here).

**biometric_agent_credentials** [change — B1 kept `key_hash` on the agent row]
`id uuid` · `company_id` · `agent_id` (composite FK) · `key_prefix text unique` (12 chars, public, for lookup and
display) · `key_hash bytea not null` (SHA-256 of the full key) · `created_at` · `created_by` · `expires_at null` ·
`revoked_at`. **No policy for any role, no grant, no generic audit trigger.** Register/rotate/revoke write explicit
audit entries that name the prefix only.
Why: keeps the hash out of `audit_log` and out of every readable row; allows two live keys during a rotation
(old key gets `expires_at = now() + 24 h`).

**biometric_devices**
`id uuid` · `location_id → locations` (Refs, active check) · `name (1–60)` · `manufacturer zkteco|essl|matrix|other|mock`
· `model` · `serial_number` · `firmware_version` · `integration_method sdk_pull|local_push|vendor_software|file_import`
· `adapter_type` · `agent_id` (composite FK, null for file_import) · `timezone` (`valid_timezone`, default company
zone) · `direction_mode first_last|device` · `connection jsonb` (non-secret; size ≤ 2 KB; keys allow-listed) ·
`status active|disabled` · `last_seen_at` · `last_successful_sync_at` · `clock_drift_s` · `created_by` / `updated_by`.
Unique `(company_id, manufacturer, upper(serial_number))`. Per company, not global: a global constraint would
reveal to one company that another owns a serial; identity is proven by the agent key, not the serial.

**biometric_employee_mappings**
`id uuid` · `device_id null` (composite FK; null = company-wide) · `employee_id → employees` (Refs + active check on
insert) · `employee_device_code text` check `^[A-Za-z0-9_-]{1,32}$`, stored exactly as the device reports it (leading
zeros kept) · `valid_from timestamptz` · `valid_to timestamptz null` · `end_reason` · `created_by` · `ended_by`
(employee ids). **No `status` column** [change — B1 had active|disabled; B2 removed "disabled" because it is
ambiguous; a mapping ends by `valid_to`]. Immutable except `valid_to`/`end_reason`/`ended_by`, set once (trigger).
No delete (no grant; trigger refuses). Constraints in §2.3.

**biometric_import_batches** — as B1: `file_name`, `file_sha256` (unique per company), `rows`, `accepted`,
`rejected`, `uploaded_by`, `approved_by`, `approved_at`, `status draft|approved|rejected`. Built in B3.5.

**biometric_sync_runs**
`id bigint identity` · `agent_id` (composite FK) · `batch_id uuid` · `device_id null` (composite FK) · `started_at` ·
`completed_at` · `status ok|partial|failed|replay` · counters (`received`, `stored`, `confirmed_duplicates`,
`possible_duplicates`, `conflicts`, `rejected`) · `error_summary` · `agent_version` · `client_ip inet` ·
`response jsonb` (≤ 64 KB, for replay). Unique `(agent_id, batch_id)`. This table is the agent's audit trail.

**biometric_raw_events** — immutable evidence [change — split from processing state]
`id bigint identity` · `company_id` · `device_id null` / `import_batch_id null` (exactly one; composite FKs) ·
`agent_id null` · `sync_run_id null` · `external_event_id` · `record_seq` · `occurrence int` · `employee_device_code`
· `device_local_time text` · `device_utc_offset text` · `device_timezone` · `punch_at timestamptz` · `direction
in|out|null` · `direction_source device|none` · `verification_method` · `source_auth authenticated|
unauthenticated_lan|import` · `raw_payload jsonb` (≤ 4 KB; template, photo and face/finger data keys stripped by the
adapter **and** refused by a check) · `payload_hash bytea` · `dedupe_key text` · `dedupe_basis
event_id|record_seq|fingerprint` · `received_at default now()` · `clock_drift_s` · `time_flags text[]`.
Unique `nulls not distinct (company_id, device_id, import_batch_id, dedupe_key)`.
**Every UPDATE and DELETE is refused by a trigger**, TRUNCATE too; no grants. Only company deletion (owner
script, triggers disabled) removes rows.
Why the split: B1 mixed immutable content with mutable processing columns and protected the content with a
column-list trigger. A table with *no* permitted update is simpler to prove and cannot silently lose protection when
a column is added later.

**biometric_event_state** — processing, 1:1 with a raw event [change — new]
`raw_event_id bigint pk` (composite FK `(company_id, raw_event_id)`) · `company_id` · `employee_id null` ·
`mapping_id null` (composite FK, `on delete restrict`) · `work_date` · `status stored|unmatched|flagged|projected|
provisional_out|extra|possible_duplicate|reconciled|after_correction|rejected|dismissed` · `flag_reasons text[]` ·
`projected_event_id → attendance_events` · `projection_slot text` · `reconciled_with → attendance_events` ·
`duplicate_of` (composite FK to raw) · `decided boolean default false` · `processed_at` · `version int` (optimistic
check for reviews). Written only by gateway/projection/review functions.
`mapping_id` **freezes the attribution at processing time**: later mapping changes cannot move it (see §2.3).

**biometric_event_reviews** — insert-only decisions
`id bigint identity` · `company_id` · `raw_event_id` (composite FK) · `action map|accept_time|dismiss|
confirm_duplicate|not_duplicate|keep_extra|keep_correction|reprocess` · `reason text` (≥ 5 chars, required for
`accept_time`, `dismiss`, `not_duplicate`; check constraint) · `decided_by → employees` · `decided_role text` (snapshot)
· `decided_at default now()` · `state_before jsonb` · `state_after jsonb`. Update/delete refused by trigger.
[change: B1 actions aligned with the B2-approved decision set; role snapshot added; `decided_by` is an employee id,
following the project rule rather than the older `auth.uid()` convention.]

**biometric_event_errors**
`id bigint identity` · `company_id` · `raw_event_id null` · `agent_id null` · `device_id null` · `kind` (B1 list) ·
`detail jsonb` (≤ 4 KB) · `attempts` · `last_attempt_at` · `resolved_at` · `resolved_by` · `resolution`.
Failed key checks are **not** stored (no company to own them; Supabase API logs record the calls) [change: B1
counted them — there is no company-safe place to keep them].

### 2.2 Relationships
```
companies 1─* biometric_agents 1─* biometric_agent_credentials
companies 1─1 biometric_settings
biometric_agents 1─* biometric_devices *─1 locations
biometric_devices 1─* biometric_employee_mappings (device_id null = company-wide) *─1 employees
biometric_agents 1─* biometric_sync_runs *─0..1 biometric_devices
biometric_devices / biometric_import_batches 1─* biometric_raw_events 1─1 biometric_event_state
biometric_raw_events 1─* biometric_event_reviews ; 1─* biometric_event_errors
biometric_event_state *─0..1 biometric_employee_mappings ; *─0..1 attendance_events (projected / reconciled)
attendance_events *─0..1 biometric_devices ; 0..1─1 biometric_raw_events (biometric_event_id)
```
- **Composite foreign keys** `(company_id, x_id) → parent (company_id, id)` for every reference between biometric
  tables [change]. They are declarative, cover bigint ids, are checked on every write including security-definer
  functions and the high-volume ingest path, and stay active when owner scripts disable *user* triggers.
- References to existing tables use `check_company_refs('employee_id:employees','location_id:locations')`.
- `attendance_events` has no `company_id`, so its new references are guarded differently (§2.4).
- Deletes: `restrict` everywhere except credentials and settings (`cascade` from their parent). Nothing in the app can
  delete; only the owner deletion script does.

### 2.3 Mapping integrity and effective dates
Exclusion constraints (extension **btree_gist**), `tstzrange(valid_from, valid_to, '[)')`:
1. `(device_id =, employee_device_code =, range &&)` where `device_id is not null`;
2. `(company_id =, employee_device_code =, range &&)` where `device_id is null`;
3. `(device_id =, employee_id =, range &&)` where `device_id is not null` — one code per person per device;
4. `(company_id =, employee_id =, range &&)` where `device_id is null` — one company-wide code per person.
Check `valid_to is null or valid_to > valid_from`. Race-free under concurrent HR edits (the database, not the app,
decides).
Rules in `save_mapping` / `end_mapping` (security definer, `pg_advisory_xact_lock(hashtextextended(company||code, 41))`):
- device-specific by default; company-wide needs `is_admin()` **and** `p_confirm_company_wide = true`;
- employee must be active and in the company; device must be active and in the company;
- **no silent reassignment** (B2 sign-off rule): refuse if any raw event already processed (`decided` or status not in
  `unmatched`) whose resolved mapping at its `punch_at` would change; the message names the count and the latest
  device time;
- a new mapping attributes only `unmatched` events it covers, at their own `punch_at`;
- precedence at punch time: device mapping, else company-wide, else unmatched (function `resolve_mapping(device,
  code, at)`, stable, internal).
History: rows are never deleted or rewritten; `audit()` records insert and end; `biometric_event_state.mapping_id`
keeps the mapping each event was processed with.

### 2.4 Additions to `attendance_events` (additive, in the projection migration)
New nullable columns `device_id`, `biometric_event_id` (FK to raw, `restrict`), `import_batch_id`, `projection_slot`,
`direction_basis device|inferred_first_last`. Checks: `source in ('web','correction','biometric','import')` (all
existing rows comply); required-reference check per source; unique `(employee_id, work_date, projection_slot)` where
slot not null; unique `(biometric_event_id)` where not null.
Company guard: the existing `company_refs` trigger is re-created with `'device_id:biometric_devices'` added
(uuid — works); for `biometric_event_id` (bigint) a new trigger checks that the raw event's state row has the same
`employee_id` (stronger than same-company).
**No `voided_at` column** — see Q1.

---

## 3. RLS and permissions

### 3.1 Table access (all via RLS; writes only through functions)
| Table | Admin | HR | Manager / Employee | anon |
|---|---|---|---|---|
| settings, agents, devices, sync runs, errors | read | read | — | — |
| agent credentials | — (functions only) | — | — | — |
| mappings | read | read | — | — |
| raw events — approved columns (column grant) and `biometric_raw_events_safe` | read | read | — | — |
| `raw_payload`, `payload_hash`, `dedupe_key`; errors `payload` | `biometric_raw_payload(id)` / `biometric_error_payload(id)` only | — | — | — |
| event state, reviews | read | read | — | — |
Policies: `company_id = my_company() and is_hr()` (Admin ⊂ HR). No INSERT/UPDATE/DELETE grant on any biometric table.
The security-matrix assertion "attendance … change only through checked functions" is extended to all 11 tables (§11.1 for the payload).

### 3.2 Functions
| Function | Who | Check inside |
|---|---|---|
| `biometric_register_agent`, `_rotate_agent_key`, `_revoke_agent` | Admin | `is_admin()`; key shown once |
| `biometric_save_device`, `_set_device_status`, `_set_direction_mode`, `_save_settings` | Admin | `is_admin()` (B2 matrix: device configuration Admin-only) |
| `biometric_save_mapping`, `_end_mapping` | HR/Admin; company-wide Admin | as §2.3 |
| `biometric_review_event(raw_id, action, reason, expected_version)` | HR/Admin | lock state row `for update`; refuse if `decided` or version differs; valid action per status; reason rule |
| `biometric_retry_errors(ids)` | HR/Admin | marks for reprocessing only |
| `biometric_overview()`, `biometric_raw_payload(id)` | HR / Admin | read helpers |
| `biometric_ingest(p_key, p_batch)`, `biometric_heartbeat(p_key, p_status)` | **anon** | key check first; nothing else readable |
| `biometric_resolve_mapping`, `biometric_work_date_at`, `biometric_project_day`, `biometric_process_queue`, guards | **nobody** (owner / scheduler) | revoked from public, anon, authenticated |
All `security definer`, pinned `search_path = public`, never take a `company_id` parameter (company comes from
`my_company()` or from the agent key), revoked from `public, anon, authenticated` before the explicit grant.

### 3.3 Agent keys
- Format `bak_<12-hex prefix>_<43-char secret>`; secret = SHA-256 of core `gen_random_uuid()` values from the
  server's strong random source — **no pgcrypto needed** [change in revision 2]. Entropy, stated exactly: 0010 used two
  UUIDs = **244 random bits**; from 0011 three UUIDs (366 bits) are hashed, so new secrets carry the full **256 bits**
  (§13.6). Stored as SHA-256 of the whole key. A plain
  hash is correct for high-entropy random secrets (no password stretching needed; avoids a CPU cost an attacker could
  trigger through the public endpoint).
- Validation: look up by prefix (unique index), compare hashes, refuse revoked/expired keys, revoked agents, inactive
  companies and disabled devices; one generic error for every failure (no oracle).
- The agent may only send events for devices whose `agent_id` is that agent (checked per device; the composite FK
  keeps agent and device in one company).

---

## 4. Gateway, duplicates, time

### 4.1 Ingest flow (`biometric_ingest`, anon, must finish well inside the anon timeout)
key → agent → company → replay check `(agent_id, batch_id)` → per event: device belongs to agent and is active →
validate and normalise time → dedupe key → insert raw (on conflict do nothing) → classify duplicate/conflict →
resolve mapping at `punch_at` → insert state (`stored` / `unmatched` / `flagged`) → enqueue `(employee, work_date)`
→ store response in the sync run → return per-event outcomes. **No projection inside the request.** Batch cap 200
events, payload cap 256 KB. Lock: `pg_advisory_xact_lock(hashtextextended(agent_id, 43))` per batch.

### 4.2 Duplicates — as B1 §3, unchanged
event ID → record sequence → fingerprint with occurrence; same key + same hash = confirmed duplicate (not stored);
same key + different hash = conflict (original kept, new payload in `biometric_event_errors`); double-press window →
possible duplicate (stored, not projected until reviewed); replayed batch = stored response.

### 4.3 Time
`punch_at` from device local time + device zone/offset. Refused: unparseable, before `now() - backfill_days`, after
`now() + future_tolerance_s` (protects `session_state`, §1.2). Flagged: drift beyond `drift_flag_s`, DST-ambiguous
local times. This is a **principle change** for biometric rows only (Q2).

### 4.4 Projection (B3.4)
A queue table is not needed: `biometric_event_state` rows in `stored` with `processed_at is null` are the queue,
indexed. `biometric_process_queue(limit)` runs from **pg_cron** every minute as the owner (not subject to the anon
timeout) in small chunks; each `(employee, work_date)` is projected under **lock 7** — the same per-person lock as
`punch()` — so web punches and projection never interleave. Days older than `auto_project_max_age_days`, days with
an approved or pending correction, and punches on leave/holiday/day off go to review instead of changing attendance
automatically. `projection_enabled = false` stores and maps but projects nothing.

---

## 5. Audit design
| What | Where | Actor |
|---|---|---|
| Settings, agents, devices, mappings changes | generic `audit()` → `audit_log` | signed-in person (`audit_stamp`) |
| Key register / rotate / revoke | explicit `audit_log` entry, prefix only | Admin |
| Review decisions | `biometric_event_reviews` (insert-only, before/after state, role snapshot) + `audit_log` entry | HR/Admin |
| Agent uploads | `biometric_sync_runs` (agent, IP, batch, counts, outcomes) — not `audit_log` (volume; `audit_stamp` cannot name an agent) | agent |
| Raw evidence | `biometric_raw_events` (immutable) | agent / import |
| Automatic processing | `biometric_event_state.processed_at`, `projection_slot`, links | system |

---

## 6. Migration plan and rollback
| # | Content | Anon exposure |
|---|---|---|
| 0010_biometric_core | extension `btree_gist`; 11 tables, composite keys, exclusion constraints, checks, RLS, read policies, immutability/active/company guards, audit triggers; Admin/HR config, mapping and key functions; settings row created for each company | none |
| 0011_biometric_gateway | `biometric_ingest`, `biometric_heartbeat`, dedupe, time validation, mapping resolution; anon EXECUTE on these two only | 2 functions |
| 0012_biometric_projection | `attendance_events` additions (§2.4), `biometric_work_date_at`, `biometric_project_day`, reconciliation, review re-projection, pg_cron job; decisions Q1/Q3/Q4 applied | — |
| 0013_biometric_import | import batches upload/approve | — |
Each migration ships with: a new test suite appended to `run.sh` after it, the security-matrix expectations updated
in the same commit (anon list becomes `biometric_heartbeat, biometric_ingest, company_brand` in 0011),
`verify_hosted.sql` checks, `delete_company.sql` (table list 21 → 32 incl. `attendance_events` handling, FK-safe
order: state → reviews → errors → raw → runs → mappings → devices → credentials → agents → batches → settings), docs.
Rollback: forward-only. Off switches without SQL: revoke keys / disable devices / `projection_enabled = false`.
0011 can be neutralised by one statement (revoke anon EXECUTE). 0010 before any data: a prepared drop script in
reverse dependency order (reviewed, not run). After data exists: no drop — retention rules apply (Q9).

---

## 7. Security risks and mitigations
| Risk | Mitigation |
|---|---|
| Cross-company access | `company_id not null` everywhere; RLS `my_company()`; composite FKs; Refs triggers; functions never accept a company id; matrix tests A↔B for every table/function |
| Mapping conflicts | four exclusion constraints; advisory lock per code; conflicts explained before saving (B2 UI) |
| Silent reassignment of history | `mapping_id` frozen on processing; save/end refuse changes that move processed events |
| Raw tampering | insert-only table, trigger refuses update/delete/truncate, no grants; payload hash |
| Agent key theft / guessing | 256-bit keys, hash only, prefix lookup, generic errors, revoke/rotate with overlap, device-to-agent binding |
| Direct calls to internal functions | revoked from public/anon/authenticated; catalog test "no function callable by PUBLIC" + anon allow-list |
| Supabase default grants | explicit revokes; test harness gains an emulation of Supabase default privileges so missing revokes fail locally |
| Public endpoint abuse / DoS | batch and payload caps, early key rejection, no work before key check; anon timeout respected (never raised) |
| Future-dated punch blocking web check-in | refused beyond `future_tolerance_s` |
| Duplicates / replays | dedupe key unique; batch replay returns stored response |
| Race with corrections | projection under lock 7; wrapper so `decide_correction` takes lock 7 too (Q3) |
| Audit attribution | person-based audit via `audit_stamp`; agent actions in sync runs; reviews with role snapshot |
| Biometric templates (DPDP) | never stored: adapter strips; database check refuses known template/photo keys; payload size cap |
| Company deletion | script extended with FK-safe order; other-companies guard unchanged |
| Restore | raw ↔ projected links checked by a new read-only `check_biometric_links.sql` |

---

## 8. Conflicts with the existing attendance architecture
1. **"Server time is the only time that counts"** — biometric rows carry device time (validated). Needs owner approval (Q2).
2. **Voiding projected rows** would touch 20 engine filters → recommendation changed to *no voiding* (Q1).
3. `decide_correction` does not take the per-person lock used by `punch()` (Q3).
4. `superseded_by` has no foreign key (Q4).
5. `session_state` reads across all time → future-dated rows must be refused (§4.3).
6. `verification_log` would show biometric rows as GPS-verified — needs a small display change in B3.4 (Q5).
7. Security-matrix assertion "anon calls only `company_brand`" changes deliberately in 0011 (Q8).
8. `check_company_refs` cannot guard bigint ids → composite foreign keys.
9. Generic `audit()` copies every column → secrets in a separate unaudited table.
10. Work date for an arbitrary time does not exist → new `biometric_work_date_at`, tested equal to
    `work_date_for_checkin` at `now()` so the two cannot drift apart.
11. Test harness has no Supabase default privileges and no extensions → both added for the biometric suites.
12. Older `decided_by = auth.uid()` in corrections vs project rule `my_employee_id()` → new tables use employee ids;
    existing table unchanged.

---

## 9. Questions for owner approval
1. **D7a revised:** no voiding column; a projected punch found wrong after projection is removed through the existing
   correction flow (supersede) — *recommended* — instead of adding a voided filter to ~10 engine functions.
2. **Device time** is trusted for biometric rows within the validation rules of §4.3 (future tolerance 120 s, backfill
   31 days, drift flag 5 min).
3. **Lock wrapper on `decide_correction`** (rename-and-wrap pattern already used in 0006/0008) so approvals and
   projection cannot interleave.
4. **Foreign key on `attendance_events.superseded_by`** (added `not valid`, validated after a data check).
5. `verification_log` shows `biometric` / `imported` for those sources.
6. **Structural changes from B1:** settings table, credentials table, raw/state split, no mapping `status`, composite
   foreign keys, failed key checks not stored.
7. **Extensions** on the project: `btree_gist` (0010) and `pg_cron` (0012); `pgcrypto` no longer needed (§11.5).
8. **Security-matrix change:** anon may call `biometric_ingest` and `biometric_heartbeat` in addition to `company_brand`.
9. **Retention** of raw events: as long as the company's attendance (B1 Q4); payload ≤ 4 KB, never templates or photos.
10. **Device codes** kept exactly as the device reports them (leading zeros significant).
11. **Auto-projection age:** only punches up to 2 days old change attendance automatically; older ones go to review
    (B1 implied 31 days automatic).
12. **Projection off by default** per company until the first device is verified.
13. Final sign-off of D1–D8; D9 (first physical device) still open.

---

## 10. Recommended B3.2 implementation plan
Scope **0010_biometric_core only**, local only:
1. Confirm extensions available in the hosted project (read-only, with the owner) and in the local test Postgres.
2. Write 0010 (tables, constraints, RLS, guards, audit, Admin/HR functions; no anon grants; no projection; no change
   to existing tables or engine functions).
3. Tests (new `biometric_core_test.sql`, appended after 0010 in `run.sh`): catalog rules; Supabase default-privilege
   emulation; role × company matrix for all 10 tables and new functions; immutability (update/delete/truncate refused
   even for the owner without disabling triggers); exclusion constraints incl. two concurrent sessions; company-wide
   Admin + confirmation; no silent reassignment; review concurrency (two sessions, one wins); key register/rotate/
   revoke never exposing hash; deletion script dry run + delete of one company with the other unchanged.
4. Update `verify_hosted.sql`, `delete_company.sql`, security-matrix expectations, BIOMETRIC_SECURITY.md,
   BIOMETRIC_DATABASE_SCHEMA.md, PROJECT.md; existing 360 checks + 29 regression must still pass.
5. Stop for review. Gateway (0011) is B3.3, projection (0012) B3.4 after Q1–Q5, imports B3.5.

---

## 11. Revision 2 — owner corrections (B3.1 review, 20 Nov 2026)

### 11.1 Raw payload column security (implemented and tested)
Access paths, exactly:
| Path | Admin | HR | Manager / Employee | anon |
|---|---|---|---|---|
| `select … from biometric_raw_events` naming approved columns | ✓ own company (RLS) | ✓ own company | 0 rows | refused |
| `select raw_payload` / `payload_hash` / `dedupe_key`, `select *`, or a `where` on them | **refused** (`permission denied` — column not granted) | refused | refused | refused |
| `biometric_raw_events_safe` (view, `security_invoker`, `security_barrier`; approved columns only) | ✓ own company | ✓ own company | 0 rows | refused |
| `biometric_raw_payload(id)` | ✓ own company only; every read written to the audit log | `Not allowed` | `Not allowed` | no EXECUTE |
| `biometric_event_errors.payload` (second payload of a conflict) | via `biometric_error_payload(id)` | refused | refused | refused |
Grants: `revoke all` on the table from `public, anon, authenticated`, then `grant select (<22 approved columns>)` to
`authenticated`. The function is `security definer`, pinned `search_path`, takes only an id, derives the company from
`my_company()` and requires `is_admin()`. Error `detail` may not contain `raw_payload`/`payload` keys (check).
Catalog tests prove that no view definition and no other function callable by `authenticated` or `anon` mentions
`raw_payload`.

### 11.2 Agent ingestion security (specification; 0010 part implemented and tested)
| Requirement | Design | Where | Proven in 0010 tests |
|---|---|---|---|
| Keys never in logs / errors | key only in the POST body of the RPC (never a URL); no function raises with the key; only its SHA-256 and 12-char prefix stored; audit entries carry the prefix only | 0010, 0011 | secret absent from every table and the audit log; checker never raises |
| Generic failures | `biometric_check_agent_key` returns the same `null` for malformed, unknown, wrong, expired, revoked, revoked-agent and inactive-company keys; the gateway maps every `null` to one message "Not accepted" | 0010 / 0011 | 7 failure kinds → null |
| Key check before expensive work | gateway order: (1) argument length caps (key ≤ 60 chars, body ≤ 256 KB, ≤ 200 events) — constant time, (2) key check — one indexed lookup + one SHA-256, (3) everything else | 0011 | (0011) |
| Size limits | batch ≤ 200 events, request ≤ 256 KB; per event payload ≤ 4 KB, no template/photo keys; sync-run response ≤ 64 KB; error detail ≤ 4 KB | 0010 checks + 0011 | payload size and template keys refused |
| Rate limiting | the database cannot rate-limit unauthenticated callers. Mitigations: per-agent throttle in 0011 (minimum interval between batches, stored on the agent row; heartbeats ≤ 1/min); cheap rejection path; anon statement timeout (≈ 3 s, not raised) bounds each call. **Gateway-level option** if abuse is seen: route agents through a Cloudflare Worker with rate limiting in front of the RPC (owner decision; documented, not built) | 0011 / ops | (0011) |
| Revoked / expired keys | `revoked_at`, `expires_at`, agent `status`, company `active` all checked | 0010 | tested |
| Agent-to-device ownership | `biometric_device_for_agent` resolves only the agent's own active devices; raw-event insert guard refuses a device not assigned to the sending agent; composite FK keeps agent, device and run in one company | 0010 | tested (own, other agent, other company) |
| Batch replay idempotency | `unique (agent_id, batch_id)` on sync runs; gateway returns the stored `response` for a repeat; event-level `unique (company, device, batch, dedupe_key)` | 0010 + 0011 | duplicate batch and duplicate event refused |

### 11.3 Timestamp integrity (implemented and tested)
Kept separately on every raw event: `device_local_time` (the device's reading as sent, text), `device_timezone`,
`device_utc_offset` (if the device sends one), `punch_at` (normalised instant), `received_at` (server time, set by the
insert guard — a supplied value is ignored), `clock_drift_s`, `time_flags`. The insert guard **requires**
`punch_at` = local time interpreted in the offset (if given) or the zone, so `received_at` can never stand in for the
punch time. Rules (from the company's settings):
| Condition | Outcome |
|---|---|
| unparseable local time / bad offset / unknown zone | rejected (check) |
| `punch_at` ≠ local time in its zone/offset | rejected |
| more than `future_tolerance_s` (120 s) ahead of receipt | rejected |
| older than `backfill_days` (31) | rejected |
| ahead of receipt within tolerance | stored, flag `future_within_tolerance` → review |
| older than `auto_project_max_age_days` (2) | stored, flag `late_backfill` → HR review, never auto-projected (0012) |
| `abs(clock_drift_s)` > `drift_flag_s` (300) | stored, flag `clock_drift` → review |
| offset given and differs from the zone's offset | stored, flag `offset_tz_mismatch` → review |
| zone changes offset within ±3 h (DST) and no offset sent | stored, flag `dst_ambiguous` → review |
Rejections in 0011 become `biometric_event_errors` rows (`invalid_time` / `future_time` / `too_old`) instead of
exceptions; the trigger stays as the backstop.

### 11.4 Correction locking — exact wrapper (proposal for 0012) and proof
SQL: `supabase/tests/concurrency/proposed_correction_lock.sql` — `decide_correction` is renamed to
`decide_correction_core`; a new `decide_correction` (same signature, `security definer`) reads the correction's
employee, refuses other companies, takes `pg_advisory_xact_lock(hashtextextended(employee, 7))` — the lock `punch()`
already takes — and calls the core. The core is revoked from everyone. Lock order on every path: lock 7 first, then
row locks, so the three paths cannot deadlock. Projection (0012) takes the same lock per employee-day.
Proof (`supabase/tests/concurrency/lock_proof.sh`, throwaway copies, two real sessions, 2-second held transactions):
| Scenario | Without wrapper | With wrapper |
|---|---|---|
| Correction approval vs projection (same day) | projection did not wait → **2 live check-ins (wrong)** | projection waited ≈1.5 s, saw the corrected check-in, added nothing → 1 |
| Web punch vs correction approval | punch did not wait | punch waited ≈1.5 s |
| Web punch vs projection (both lock 7) | serialised → 1 check-in | same |
| Control: projection without lock 7 | 2 check-ins — so 0012 must take it | — |
| Existing correction rules with the wrapper | — | own request refused, other company refused, reject needs reason, approval + audit unchanged, decided once, core not callable |
The wrapper is **not** in 0010 (the attendance engine is unchanged); it ships with 0012 after approval.

### 11.5 Extensions and hosted verification
`supabase/deploy/check_biometric_prereqs.sql` — read-only (no `create`, no `set`). Reports: PostgreSQL ≥ 15,
`btree_gist` availability / installed schema, `extensions` schema, `pgcrypto` (informational — no longer needed),
`pg_cron` availability and preload (0012), the Supabase extension allow-list if visible, the role's CREATE right, API
role timeouts (read only) and default privileges in `public`.
Permissions: run as `postgres` in the SQL editor. Installing `btree_gist` needs `postgres` (allowed by Supabase's
supautils allow-list) or Dashboard → Database → Extensions; `pg_cron` is enabled from the Dashboard (it creates the
`cron` schema; jobs run as the role that schedules them). **Nothing is installed until you approve running 0010.**
`verify_hosted.sql` now accepts 21 or 32 tables and has check 13 for 0010.

### 11.6 Operating defaults — PROPOSED, pending explicit owner confirmation
Implemented as the defaults in `biometric_settings` (Admin-adjustable within limits) and in the design:
no voiding column · device time trusted only after validation · 120 s future tolerance · 31-day backfill limit ·
5-minute drift warning · 2-day automatic projection age · older punches to HR review · projection disabled by default ·
device-specific mapping precedence · leading zeros preserved · raw events retained under the company's attendance
retention. **These are proposed defaults. They become owner-approved only when you confirm them explicitly.**

### 11.7 Mapping concurrency — the protocol 0011 and 0012 must follow (revision 3)
One advisory lock key per (company, device code): `biometric_code_lock_key(company, code)` (namespace 41).
| Path | Lock on the code key | Then |
|---|---|---|
| `biometric_save_mapping` / `biometric_end_mapping` (0010) | **exclusive** | insert/end the mapping, re-check processed punches, attribute waiting ones |
| `biometric_review_event` (0010) | **shared** (by the punch's code) | lock the state row `for update`, check `decided` and `version` |
| Ingestion (0011) | **shared**, for every distinct code of the batch, in ascending key order, before resolving any mapping | resolve the mapping at each `punch_at`, insert raw + state, commit |
| Projection / reprocessing (0012) | **shared** for any punch whose attribution it reads or sets | then lock 7 per person |
Why this is enough:
- *No partially changed mapping:* a mapping change holds the key exclusively until it commits, so ingestion or a review
  of that code either finishes before the change starts (and the change then sees and protects those punches) or
  starts after it commits (and reads the committed mapping). READ COMMITTED gives each statement a new snapshot after
  the lock is granted.
- *No silent re-attribution:* attribution is frozen on the state row (trigger), the state guard refuses a mapping that
  does not cover the punch, and the mapping functions refuse changes that would move a processed punch — and with the
  lock they always see every punch that is processed or being processed.
- *Lock order (no deadlocks):* agent batch (43) → code keys (41, ascending) → person (7) → row locks. No path takes a
  code key after lock 7 or after a row lock; each mapping change takes a single code key.
Proof (`lock_proof.sh` §7–9, real concurrent sessions): ingestion vs ending a mapping (end waits, then refuses —
consistent); review-first vs back-dated mapping (mapping waits, then refuses); mapping-first vs review (review waits,
then refuses a stale decision); controls without the ingestion or review lock produce violations; 5 rounds of
ingestion + mapping + review in parallel: no deadlock, invariant holds.

### 11.8 Revision 3 corrections (SQL review, 20 Nov 2026)
1. `device_utc_offset` limited to ±14:00 (`^[+-]((0\d|1[0-3]):[0-5]\d|14:00)$`), checked by the insert guard (clear
   message) **and** by the column check (proven with the guard switched off).
2. `biometric_error_guard` protects id, company, raw event, agent, device, kind, detail, payload and creation time;
   only `attempts`/`last_attempt_at` (forward only) and a one-time resolution (`resolved_at`, `resolved_by`,
   `resolution`) may change.
3. Review actions: `map` and `reprocess` removed from the table's allowed values. The table now accepts exactly the six
   decisions `biometric_review_event` performs, and a test compares the two. Mapping a waiting punch is a mapping
   action: `biometric_save_mapping` writes one `attribute_unmatched` audit entry listing the punch ids. `reprocess`
   arrives with 0012. The B2 screen's decisions are the same six (app test compares them with the migration).
4. Mapping concurrency: §11.7; `biometric_review_event` now takes the shared code lock (the controls show why).

## 12. B3.2 — what was built (local only)
- `supabase/migrations/0010_biometric_core.sql`: extension `btree_gist`; 11 tables; composite foreign keys; four
  exclusion constraints; checks for codes, times, payload size/content, secrets in connection details; RLS + read
  policies; column-limited grants; safe view; insert-only/immutable guards (raw events, reviews, mapping history,
  processing attribution); company/active guards; audit triggers; key generation and check; mapping resolution;
  12 Admin/HR functions. No anon grant; no change to any existing table, function or policy.
- Tests: `supabase/tests/biometric_core_test.sql` (193 checks) after `supabase_defaults_stub.sql` (Supabase default
  grants on); `supabase/tests/concurrency/lock_proof.sh` (21); `supabase/tests/delete_company_test.sh` (4).
- Owner scripts: `delete_company.sql` (32 tables, works with or without 0010), `verify_hosted.sql` (check 13),
  `check_biometric_prereqs.sql` (new, read-only). Demo database rebuild includes 0010.

## 13. B3.3 — device gateway (migration 0011, local only)
Status: implemented and tested locally; **not run on any hosted project**. No attendance is written (projection is 0012).

### 13.1 Endpoints (PostgREST RPC, anonymous role, key in the JSON body)
| Call | Body | Answer |
|---|---|---|
| `POST /rest/v1/rpc/biometric_ingest` | `{"p_key": "bak_…", "p_batch": {"batch_id": "<uuid chosen by the agent>", "agent_version": "…", "devices": [{"manufacturer", "serial", "clock_drift_s"}], "events": [ … ]}}` | `{"ok": true, "batch_id", "sync_run_id", "received", "stored", "confirmed_duplicates", "possible_duplicates", "conflicts", "rejected", "outcomes": [{"index", "outcome": stored/duplicate/conflict/rejected, "status" or "reason", "raw_event_id"}]}` |
| `POST /rest/v1/rpc/biometric_heartbeat` | `{"p_key": "bak_…", "p_status": {"agent_version", "devices": [{"manufacturer", "serial", "reachable", "clock_drift_s"}]}}` | `{"ok": true, "server_time", "devices": [the agent's active devices with their non-secret connection details]}` |
Event fields: `manufacturer`, `serial`, `employee_code` (exactly as the device shows it), `local_time` (device clock,
`YYYY-MM-DD HH:MM[:SS]`), optional `utc_offset` (±HH:MM ≤ ±14:00), `direction` (in/out), `verification`, `event_id`,
`record_seq`, `occurrence` (≥ 1, for identical records), `payload` (attendance record only, ≤ 4 KB, no templates or
images), optional `source_auth` — a **claim that can only lower** the classification (§13.8). The device's zone is
the one configured on the device.
Other answers: `{"ok": false, "code": …}` — `not_accepted` (every key problem, identical), `use_post` (GET refused
before the key is checked — a key must never be in a URL), `too_large`, `bad_request` (events missing, null or not a
list — checked null-safely with `IS DISTINCT FROM 'array'`; batch_id missing),
`throttled` (+ `retry_after_s`), `processing_failure` (batch rolled back; resend it).

### 13.2 Order of work and limits
0. POST only → 1. key ≤ 64 chars, request ≤ 256 KB, ≤ 200 events (constant-time, before the key) → 2. key check (one
indexed lookup + one SHA-256; one answer for malformed, unknown, wrong, expired, revoked-agent and inactive-company
keys; nothing is written for a refused key) → 3. per-agent lock 43 (one batch at a time per agent) → 4. replay:
same `batch_id` returns the stored answer with `"replay": true` → 5. throttle: ≤ 30 accepted batches per agent per
60-second window, exact under concurrency → 6. validate every event without exceptions → 7. shared code locks
(41, ascending) → 8. store raw + state, resolve each mapping at its own punch time → 9. sync run, device and agent
telemetry, answer (≤ 64 KB, stored for replay). Heartbeats: ≤ 1 per 30 s, body ≤ 16 KB.
Measured: a 200-event batch takes ≈ 170 ms locally under a 3-second statement timeout (Supabase's anon default).
Finding fixed during B3.3: the per-row `valid_timezone()` check on raw events cost ≈ 6 ms a row (1.2 s a batch); it is
replaced by a stronger, cheap rule — a raw event from a device must carry that device's zone.

### 13.3 Processing state assigned at ingestion
`unmatched` (no mapping at the punch time) · `flagged` (any time flag, `unauthenticated_source`, or the mapped person
is switched off — `inactive_employee`; attribution kept) · `possible_duplicate` (same person and device within
`double_press_s`, with `duplicate_of`) · `stored` (clean). Dedupe identity: event ID → record sequence →
fingerprint with occurrence. `payload_hash` now hashes the **whole record** (code, local time, offset, direction,
method, payload), so a re-sent record with any changed field is a *conflict* (original kept; the new payload goes to
the Admin-only error payload), never a silent duplicate.

### 13.4 Rejections (each leaves an error record with batch, index, device, code and local time — never a payload)
`unknown_device` (not this agent's, unknown or disabled) · `unsupported_format` (bad code/direction/method/sequence/
occurrence/source, non-object, template or image keys) · `invalid_time` (not a real time, offset beyond ±14:00) ·
`future_time` (> 120 s ahead) · `too_old` (> 31 days). Unexpected database failures: the batch is rolled back, one
`processing_failure` record keeps the SQL state and constraint name only, and the agent gets a plain answer.

### 13.5 Rate limiting
Per agent (valid key): 30 batches/min and 1 heartbeat/30 s in the database, exact under concurrency. Invalid keys
cannot be rate-limited in the database without storing attacker input; they are cheap to refuse (size caps first,
one index lookup, nothing written) and bounded by the anon statement timeout. If abuse is ever seen, the documented
gateway-level option is a Cloudflare Worker with rate limiting in front of the two RPCs (an owner decision; not built).

### 13.6 Other changes in 0011
- `biometric_new_key()` now hashes **three** v4 UUIDs (366 random bits) so a new secret carries the full **256 bits**.
  Keys issued by 0010's version carry **244 bits** until rotated (rotation is available to Admin).
- Audit triggers on agents and devices fire only when a configuration column changes (heartbeats and sync telemetry no
  longer flood the audit log); configuration changes are still audited.
- `verify_hosted.sql` check 4 accepts the two gateway functions once 0011 is installed.

### 13.7 Tests (all executed locally; figures as in the revision 5 evidence ZIP, commit 83e390a)
Full database suite **633** checks (existing 360 + Supabase-defaults setup 1 + biometric core 193 + gateway 79) ·
`biometric_gateway_test.sql` **79** checks · `concurrency/gateway_proof.sh` **6** (concurrent replay, overlapping
batches, batch vs end-mapping, batch vs back-dated mapping, 40 parallel batches → exactly 30 accepted, 5 deadlock
rounds) · `concurrency/lock_proof.sh` **21** (B3.2 proofs re-run) · `e2e/biometric_gateway_http.py` **18** over real
HTTP (PostgREST 12.2.3): anon ingest, X-Forwarded-For telemetry and spoofing, replay, generic refusals, size cap,
null-safe malformed events, device-derived source_auth, GET refused, heartbeat and throttle, anonymous grants, the
key absent from the PostgREST log, the Postgres server log, audit log, sync-run answers and error records · company
deletion **4** · app regression **29** · app checks **53** · clean migration 0001–0011 without errors.
(Revision 4 of this section listed the earlier counts 67 gateway / 13 HTTP / 621 database; corrected here.)
**Correction (B3.4, 20 Nov 2026):** "company deletion **4**" above is wrong — the r5 evidence file shows **3** ok
lines. The fourth check (raw-event triggers re-enabled) compared against a hard-coded 3 and had silently not printed
since 0011 added a fourth trigger. The test was made strict in B3.4 (see BIOMETRIC_B3_4_IMPLEMENTATION_REPORT.md §8).

### 13.8 Revision 5 — what the gateway can and cannot prove (B3.3 review, 20 Nov 2026)
| Fact | Proven? | How |
|---|---|---|
| Which **agent** sent a batch | **Yes** | agent key (256-bit; hash only; revocable) — unchanged |
| That the agent may speak for the **device** named | **Yes** | device assigned to that agent by Admin; serial looked up only among the agent's own active devices |
| That a punch was really produced by that **device** | **Only indirectly, and only for key-protected SDK-pull devices** | Admin sets `device_auth = comm_key` when the device refuses connections without its communication key (kept by the agent, never sent to AttendOS). A record the agent pulled from it implies the agent passed the device's own check. This is an Admin attestation plus the agent key — not a cryptographic signature on each punch. |
| Anything about devices that push, open LAN pulls, vendor software | **No** | classified `unauthenticated_lan`, flagged `unauthenticated_source` for HR review |
| Where the request came from (client IP) | **No** | `X-Forwarded-For` is caller-supplied (proxies may append, not overwrite). Stored as informational telemetry only (sync run `client_ip`, agent `last_ip`); never used for authentication, device authorisation or any accept/refuse decision. It could become a network identity only if a trusted proxy is configured to overwrite the header — not the case today. |
Rules implemented in 0011:
- `source_auth` is **computed**: `authenticated` only when the device is `sdk_pull` **and** `device_auth = comm_key`;
  otherwise `unauthenticated_lan`. The event's JSON claim can only **lower** it: a forged `"authenticated"` from an
  open/push device is ignored, the punch is `unauthenticated_lan`, flagged, and also marked
  `source_auth_claim_rejected`; an `"unauthenticated_lan"` claim from a key-protected device is honoured (weaker);
  any other value is refused (`unsupported_format`).
- `device_auth` is set only by Admin (`biometric_set_device_auth`, the 13th signed-in function), audited, and refused
  for non-pull devices by the function and by a table check.
- The heartbeat tells the agent each device's `device_auth`, so the agent knows which devices need their key.
Operational effect: until a device is declared key-protected, all of its punches go to HR review (the conservative
default you set). Owner decision for B3.4/B5: whether HR may bulk-confirm a device's punches, or whether projection
waits for `comm_key` devices only.
