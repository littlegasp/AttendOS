# Biometric integration — Phase B1 architecture audit

Status: **audit only** (revision 2, 20 Nov 2026 — see the note at the end). No migration, function, screen or agent code has been written. Prepared on branch
`feature/biometric-b1`, created from `phase-4-5` at `0fcec08` (application commit `6d47386` + the final Pilot 01
pack). Audited on 19 Nov 2026 by reading the repository and the database built from migrations 0001–0009.

## 1. What exists today (verified, not assumed)

| Area | Finding |
|---|---|
| Branches | `main` = Phase 3 merge `95a64f6`. `phase-4-5` = reviewed baseline (Phases 4–6, stabilisation, pilot pack). Biometric work branches from `phase-4-5`. |
| Front end | Next.js 15 **static export** (`output: "export"`), React 19, TypeScript. Served by Cloudflare as **static assets only** — `wrangler.jsonc` has no Worker code. **There are no API routes or server code in the app.** |
| Back end | Supabase: Postgres + PostgREST + Auth. All trusted logic is in **SECURITY DEFINER database functions** called through PostgREST with the signed-in person's session. No secret/service-role key is used anywhere. |
| Migrations | `supabase/migrations/0001…0009`, forward-only, never edited once run. **Next free number: 0010.** |
| Tenancy | One project, many companies. `company_id` on company-level tables (default `my_company()`), employee-level tables reach it through `employee_id`. Helpers: `my_company()`, `my_employee_id()`, `can_see(emp)`, `hr_of(emp)`, `manages(emp)`, `in_my_company(emp)`, `is_hr()`, `is_admin()`. Triggers: `check_company_refs` (no cross-company foreign keys), `freeze_company_id`, `check_active_refs`. |
| Auth | Logins link to employee records by confirmed work e-mail (`handle_new_user`, `link_existing_login`, hook `hook_before_user_created`). Data is keyed on `my_employee_id()`, never on `auth.uid()` directly. |
| Audit | `audit_log` (actor, actor_employee, company_id, action, target, before/after, `source` ∈ app/system/seed). Append-only in normal operation (`audit_append_only`, `audit_no_truncate`); `audit()` trigger on configuration tables. |
| Tests | `npm run check` (tsc, eslint, 35 app tests), `npm run test:db` (9 SQL suites, 360 checks incl. the 21-table security matrix), `supabase/authcheck` (real Supabase Auth: 36 flow checks + 26 invitation edge cases), `e2e/regression.py` (29 browser checks). |
| Deploy | `npm run build` → `out/` → Cloudflare static assets. `public/_headers` (geolocation self only, no framing). |
| UI conventions | App shell (`AppShell`, `AppSidebar`, `nav.ts` groups Workspace / Management / Insights / Configuration), capability matrix in `permissions.ts`, `Tabs`, `SectionCard`, `ModulePage`, semantic `--color-*` tokens, dark/light via `data-theme`. |

## 2. Lifecycle of a GPS punch today
1. **Employee** presses Check In on My Attendance (`AttendanceCard` → `use-attendance.ts`).
2. **Browser** reads one GPS position (`getCurrentPosition`) and calls RPC `punch(p_kind, p_lat, p_lng, p_accuracy)` with the person's session.
3. **`punch`** refuses a check-in on full-day approved leave, then calls **`punch_core`**.
4. **`punch_core`**: finds the employee (`my_employee_id()`), takes a per-employee advisory lock, checks company active,
   reads `session_state` (off / working / on_break) and refuses impossible transitions; for `in` picks the work date
   with `work_date_for_checkin` (overnight shifts) and the plan with `plan_for` (roster day → holiday → remote
   exception → weekly pattern → company default); refuses day off; validates accuracy and **distance to the planned
   office on the server** (`distance_m`); writes refusals to `attendance_attempts`; on success inserts
   **`attendance_events`** (`kind` in/out/break_start/break_end, `at` = server `now()`, `work_date`, `work_mode`,
   `location_id`, `distance_m`, `accuracy_m`, `verified`, `source = 'web'`) and coordinates in `attendance_coords`.
5. **Days are not stored.** `day_for(emp, d)` → `day_for_core` reads that day's non-superseded events in time order
   and computes first in, last out, worked and break minutes, late (shift start + grace), early leaving, overtime
   (worked − (shift length − break allowance)), open/missing check-out and status, from `plan_for` and `shift_for`.
6. **Register / reports / dashboard** (`attendance_register`, `report_days`, `report_people`, `report_trend`,
   `dashboard_summary`, `attendance_history`) all call `day_for` per person-day. My Attendance (`my_today`) also
   lists the day's events with their `source`.
7. **Corrections**: `request_correction` → `decide_correction` marks the replaced first-in / last-out event
   `superseded_by = <correction id>` and inserts a new event with `source = 'correction'`, `correction_id`; the
   original stays.

## 3. What can be reused

| Need in the spec | Existing piece | Reuse |
|---|---|---|
| Punch store with source | `attendance_events` already has `source` (values in use: `web`, `correction`), `work_date`, `correction_id`, `superseded_by` | **Extend, don't duplicate**: add `source` values `biometric` and `import`, plus nullable `biometric_event_id` and `device_id`. Existing values stay as they are (labels: `web` → "AttendOS App", `correction` → "HR Correction"). |
| Attendance rules (shift, grace, break, overnight, late, early, overtime, status) | `day_for_core`, `plan_for`, `shift_for` | **Unchanged.** Biometric punches become ordinary `attendance_events` rows, so every calculation applies automatically. |
| Overnight work-date | `work_date_for_checkin(emp)` (uses `now()`) | New sibling `work_date_at(emp, ts)` with the same rule for an arbitrary punch time; the existing function is left alone. |
| Corrections | `attendance_corrections`, `decide_correction` | Unchanged; works on biometric punches the same way. |
| Offices | `locations` | Device → office assignment (`biometric_devices.location_id`). |
| Tenancy and safety | helpers + `check_company_refs`, `freeze_company_id`, `audit()` | Applied to every new table. |
| Activity log | `audit_log` | Device, mapping, agent and reprocessing changes audited the same way. |
| Register | `attendance_register` (per day) | Add a per-day **punch list** function (`day_events`) with source and device; register drawer + source/device filters. |

## 4. Security boundaries found
- No anonymous table access; anon may execute only `company_brand` (verify_hosted check 4).
- All writes to attendance go through definer functions; there is **no insert policy** on `attendance_events`.
- No service-role key anywhere; the deployment pack forbids one in the front end or Cloudflare.
- An unattended device or Sync Agent has **no user session**, so it cannot use the existing path. It needs its own,
  narrower credential (agent key) checked inside a database function — see BIOMETRIC_SECURITY.md.

## 5. Recommended integration points
1. **Gateway = database functions** (same pattern as the rest of AttendOS): `biometric_ingest(p_key, p_batch)` callable
   by the anon role, which accepts only a valid, unrevoked agent key, derives the company from the key (never from the
   request), stores raw events idempotently and returns per-event outcomes. No new server, no secret key.
2. **Sync Agent on the company LAN** talks to devices (manufacturer SDK pull, or acting as the devices' local push
   server) and uploads to the gateway over HTTPS.
3. **Projection** `project_biometric_day(emp, work_date)` keeps one **stable** `attendance_events` row per slot and
   updates it in place, so late or repeated syncs always give the same result and correction links never break.
4. **Register drawer** shows each punch with its source.

## 6. Conflicts and things that must change elsewhere
| Item | Impact |
|---|---|
| `delete_company.sql`, `verify_hosted.sql` (21 tables), security matrix test | Must include the new tables (counts, deletion order, RLS checks). |
| verify_hosted check 4 ("anon can execute only `company_brand`") | Becomes `company_brand` + `biometric_ingest` (+ `biometric_heartbeat`). |
| `punch_core` state machine vs. late-arriving biometric punches | App check-in after an unsynced biometric punch is accepted ("already in" is not detected until sync); handled by the reconciliation rule, not by blocking the app. |
| `decide_correction` supersedes "the earliest in / latest out" **at approval time**; `superseded_by` holds the correction id **without a foreign key** | A biometric punch synced later with an earlier time would silently override the HR decision. Projection therefore locks corrected slots and sends later punches to review (`after_correction`); FK hardening proposed (open question 5). |
| Events are filtered by `superseded_by is null` only | Voiding a projected row without deleting it needs one extra condition in the engine functions (D7a). |
| Leave and day-off checks are in `punch`/`punch_core` | A machine cannot refuse a finger. Biometric punches on leave/holiday days are recorded and flagged for HR (owner decision D4). |
| `attendance_events.source` has no check constraint | Add one (`web`, `correction`, `biometric`, `import`) — all existing rows already comply. |
| Static-export app has no server | Any direct device-to-cloud push (ZKTeco/eSSL ADMS) would need Worker code; recommended only through the agent (decision D6). |
| Data retention / company deletion / backups | New personal data (device codes, punch payloads) joins 07-DATA-RETENTION.md and the deletion script. |

## 7. Required new migrations (proposal — not written)
`0010_biometric_core` (devices, agents, mappings, sync runs, raw events, errors, import batches; RLS, audit, company
guards) → `0011_biometric_ingest` (agent keys, `biometric_ingest`, `biometric_heartbeat`, normalization, idempotency)
→ `0012_biometric_projection` (`attendance_events` columns + source check, `work_date_at`, `project_biometric_day`,
reconciliation, `day_events`, review-queue functions) → `0013_biometric_import` (CSV/Excel import batches).
Details: BIOMETRIC_DATABASE_SCHEMA.md.

## 8. Main risks
1. **Punch direction** — many machines send only "a punch"; wrong inference gives wrong late/overtime.
2. **Clock and timezone** — device clocks drift and record local time without a zone.
3. **Mixed sources** — the same arrival recorded by app and machine must not count twice.
4. **Unverified hardware claims** — nothing here has been tested on a real device yet.
5. **Anon-callable gateway** — must be strictly key-checked, rate-limited and size-limited.
6. **Re-projection** must never undo HR corrections.
7. **Performance** — reports already compute every person-day on request (docs/PERFORMANCE.md); biometric adds rows
   but no new per-day cost; the daily summary table remains the scaling fix.
Full list with mitigations: BIOMETRIC_SYSTEM_ARCHITECTURE.md §9.

## 9. Proposed sequence
B1 (this) → owner review → B2 device management UI on mock data → B3 gateway → B4 Sync Agent → B5 first real
adapter on real hardware → B6 attendance projection + register → B7 other manufacturers → B8 readiness review.
Each phase stops for review. Details: BIOMETRIC_IMPLEMENTATION_STATUS.md.

## 10. Revision 2 (owner review, 20 Nov 2026)
Runtime changed to .NET 10 LTS (.NET 8 support ended 10 Nov 2026); direction rules refined (device direction first,
controlled first-in/last-out, no checkout without evidence, provisional outs, flags); projection changed from
delete-and-recreate to stable slot rows updated in place, with corrected slots locked; duplicate identity ordered
event ID → record sequence → fingerprint with an occurrence ordinal; time fields and flags spelled out;
mapping precedence and validity, required references, import references, retention and restore added.
Final decisions D1–D9 and open questions: BIOMETRIC_SYSTEM_ARCHITECTURE.md §11.

