# Biometric B3.4 — attendance projection design (migration 0012)

Status: **design for review only — 20 Nov 2026.** Nothing in this document is implemented. Migration
`0012_biometric_projection.sql` has **not** been written; no existing attendance function has been altered; no SQL
was run against any hosted project; no extension installed; no hardware connected; no merge, no deployment.
Baseline: branch `feature/biometric-b1` @ `94ee495` (0010 and 0011 approved for local development). Every statement
about current behaviour below was checked by reading migrations 0001–0011 (line references are to those files).

Owner decisions applied (B3.3 authorisation): no voiding column · device time trusted only after validation ·
future tolerance 120 s · 31-day backfill · 5-minute drift flag · auto-projection only up to 2 days old · projection
off by default per company · device codes exact · device mapping beats company mapping · no templates or images ·
correction lock wrapper in B3.4 · Biometric/Imported display in B3.4 · anonymous access only for the two gateway
functions.

---

## 1. The design in one page

- **Where projection runs.** Not inside `biometric_ingest` (it stays as approved: no attendance writes). A new
  system procedure `biometric_run_projection()` is called every minute by Supabase Cron (`pg_cron`). It handles one
  **employee-day** per transaction and commits after each, so one person's catch-up never holds anyone else's punch.
- **Same lock as the app.** `biometric_project_day(emp, day)` takes `pg_advisory_xact_lock(hashtextextended(emp::text, 7))`
  — the lock `punch_core` already takes (0003:602). Correction approval takes it too, through the approved wrapper.
  App punch, correction approval and projection for one person therefore run one after another, never interleaved.
- **What gets written.** Only `attendance_events` rows with `source = 'biometric'` (later `'import'`), one stable row
  per **slot**: `in` and `out` in first-in/last-out mode, `dev:<raw id>` in device-direction mode. Every row points at
  its immutable raw punch (`biometric_event_id`, foreign key, unique) and its device. Nothing is ever deleted.
- **What never gets written.** Provisional check-outs, extra punches, duplicates, unmatched, flagged, held,
  unauthenticated or after-correction punches. They stay as roles on the raw punch and are shown through a new
  read function `day_events()`.
- **Existing engine untouched.** `punch`, `punch_core`, `session_state`, `day_for`, `day_for_core`, `my_today`,
  `work_date_for_checkin`, `report_days`, `attendance_register`, reports and exports keep their code. They see
  biometric rows exactly as they see app rows. Two existing functions change, both as approved: `decide_correction`
  gets the lock wrapper (rename-and-wrap), and `verification_log` gets a Biometric/Imported outcome.
- **No voiding.** A projected row is changed only (a) by projection, in place, while its day is still open and the slot
  is unlocked, or (b) by the existing HR correction workflow, which supersedes it. After day close, or once a
  correction touches the day, projection never changes that day's counted rows; later punches go to HR review.
- **Off by default.** `biometric_settings.projection_enabled` stays `false` until an Admin turns it on.

---

## 2. Facts about the current engine the design relies on

| # | Fact (verified) | Consequence for projection |
|---|---|---|
| E1 | `punch_core` takes advisory lock 7 per employee, then reads `session_state` (0003:602–605). | Projection takes the same lock first; the app then sees committed projected rows. |
| E2 | `session_state` = latest live event by `at desc, id desc` **across all days** (0002:147). | A row inserted with `at` later than every other live event changes the person's state. Projection must check this before inserting an `in` (§6.6). |
| E3 | `day_for_core` reads only live rows of `work_date = d` ordered by `at, id`; the day is *open* while the last kind is not `out`; open days accrue live time until `shift_end + 4 h`; early leaving and overtime are only computed when not open (0003:416–504). | A provisional check-out must not be a row (it would finalise hours). Finalisation must happen before `shift_end + 4 h`: `day_close_after_min` is limited to 30–239 by 0010:35. |
| E4 | `work_date_for_checkin`: yesterday if yesterday's shift is overnight, yesterday is a working day and now < today's shift-end time (0003:506). | `biometric_work_date_at` mirrors it exactly for check-ins (§7). |
| E5 | `decide_correction` supersedes the earliest live `in` / latest live `out` of the day (`superseded_by = correction id`) and inserts a `source = 'correction'` row; it takes **no** advisory lock (0003:742). | Wrapper adds lock 7. Any superseded slot or approved correction **locks** the day for projection. |
| E6 | `request_correction` is employee-only, last 31 days, one pending per day; no lock (0003:692). | A pending correction **holds** the day's new punches; a race with projection is harmless (§8.4). |
| E7 | `punch` refuses check-in on a full-day approved leave (0006:344); `punch_core` refuses check-in on a day that is `off` on the roster or a holiday (`day_off`). | Projection applies the same rules: such punches are **held** for HR, not projected. |
| E8 | `attendance_events.source` has no check; values today are `web` and `correction`. `verified` means "location verified". No audit trigger; only `company_refs` (0003:230). | New check `source in (web, correction, biometric, import)`; biometric rows always `verified = false`; projection writes its own audit entries. |
| E9 | `report_days` is the single source for register, reports and CSV export; it calls `day_for` per person-day (0006:471). | Reports change only through the rows; no report function changes. |
| E10 | `my_today_core` returns the day's live events with `source` and `verified` (0003:561). The Timeline shows "· location verified" / "· no location" from `verified` (src/components/AttendanceCard.tsx:221). | Without a UI change a biometric row would read "no location". The UI must label `source` first (§11.3). |
| E11 | `biometric_save_mapping` attaches waiting **unmatched** punches and sets them to `stored` with `processed_at = null` without re-checking their flags (0010:743–747). | **Finding:** `stored` is not proof that a punch is clean. Projection re-gates every new punch itself (§6.2). |
| E12 | `biometric_review_event` turns an accepted punch to `stored` but leaves `processed_at` unchanged (0010:815). | 0012 must reset `processed_at` on acceptance so the queue picks the punch up (§5, A6). |
| E13 | `delete_company.sql` deletes raw biometric events **before** `attendance_events`. | With the new foreign keys that order would fail; 0012 must reorder it (§5, A9). |

---

## 3. The twelve requirements — how each is met

| # | Requirement | How | Where |
|---|---|---|---|
| 1 | Web check-in/out keeps working unchanged | No change to `punch`, `punch_core`, `session_state`, `work_date_for_checkin`, geofence or GPS code. Projection only inserts rows the engine already understands, under the same lock, and refuses inserts that would open a finished day (§6.6). The existing regression suites must pass unchanged. | §6.6, §12.1 |
| 2 | Same employee advisory lock as punch | `biometric_project_day` takes `pg_advisory_xact_lock(hashtextextended(emp::text, 7))` before reading anything. | A4, §8 |
| 3 | Correction approval uses the approved wrapper | `decide_correction` → `decide_correction_core` (revoked from everyone); new `decide_correction` checks company, takes lock 7, calls the core. Same SQL as `tests/concurrency/proposed_correction_lock.sql`, already proven by `lock_proof.sh`. | A7 |
| 4 | Stable IDs and correction references | One row per slot, unique `(employee_id, work_date, projection_slot)`; ids never change; projection never deletes, never clears `superseded_by`, never touches `web`/`correction` rows or superseded rows. A guard trigger enforces this. | A1, A2, §6.5 |
| 5 | Inferred vs explicit direction distinguishable | `direction_basis = 'inferred_first_last'` (slots `in`/`out`) vs `'device'` (slot `dev:<raw id>`); a check ties basis to slot shape. `day_events` labels "Biometric · inferred" / "Biometric · device In/Out". | A1, A5 |
| 6 | Provisional checkout never finalises | It is the role `provisional_out` on the raw punch, never a row. The day stays open in `day_for_core`, so worked hours, overtime, early leaving and status are not final. Only at day close does projection insert the `out` row. | §6.4 |
| 7 | Duplicate, unmatched, flagged, unauthenticated events stay out | Only punches passing the gate (§6.2) can fill a slot: attributed, authenticated (or individually accepted by HR), no time or attribution flags, not a possible duplicate, ≤ 2 days old, not in the future. Everything else keeps its review status. | §6.2 |
| 8 | Older than the auto window → HR review | A not-yet-decided punch older than `auto_project_max_age_days` (2) when first processed becomes `flagged` + `late_backfill`. Enabling projection on a company with a backlog sends the backlog to review, not into the register. | §6.2 |
| 9 | Disabled by default | Unchanged default `projection_enabled = false`; the queue skips such companies. | §6.1 |
| 10 | Corrections, shifts, overnight, leave, holidays, weekly offs | Pending correction → `held`; approved correction or superseded slot → day locked, new punches `after_correction`; off day / holiday / full-day leave / before joining / after exit → `held`; overnight work date mirrors the app (§7). | §6.3, §7 |
| 11 | Displays say Biometric or Imported, never GPS-verified | Check constraint: biometric/import rows have `verified = false`, no distance, no accuracy. `verification_log` outcome `biometric` / `imported`; Timeline and Verification badges show "Biometric device" / "Imported". | A1, A8, §11.3 |
| 12 | Every projected event traceable | `biometric_event_id` → raw (FK, `on delete restrict`, unique); device id; state back-link `projected_event_id`; guard checks person, company, device, time and work day match the raw punch; every insert/move/role change is in `audit_log` with before/after. | A1, A3, §6.7 |

---

## 4. Data model changes (all additive)

**`attendance_events`** — new nullable columns `device_id`, `biometric_event_id`, `import_batch_id`,
`projection_slot`, `direction_basis`; check `source in ('web','correction','biometric','import')`; shape check (web
and correction rows must have all five null — true for every existing row; biometric/import rows must have them set,
`verified = false`, `distance_m`/`accuracy_m`/`correction_id` null, kind `in`/`out`); two partial unique indexes
(slot, raw punch); `company_refs` trigger re-created with the two new uuid references; new guard trigger
`attendance_external_guard` (A2).

**`biometric_event_state`** — new status `held` with `hold_reason` (resolved automatically when the cause goes away:
roster, leave, correction decision); `projection_failures` counter; `work_date` frozen once set (state guard).

**No new table.** Errors use the existing `biometric_event_errors.kind = 'processing_failure'`.

Lock and performance notes for the migration itself: adding nullable columns without defaults is a catalogue change;
the two new checks are added `not valid` and then validated (`SHARE UPDATE EXCLUSIVE`, does not block punches); the
two partial unique indexes cover no existing row, so they build in moments. The migration runs in one transaction;
any failure leaves 0011 exactly as it was.

---

## 5. Functions — new and changed

| Function | Kind | Who may call | Purpose |
|---|---|---|---|
| `biometric_work_date_at(emp, at, direction)` | new, stable | system only | Work date of a punch (mirrors `work_date_for_checkin`, §7) and an `ambiguous` flag. |
| `biometric_day_close_at(emp, day)` | new, stable | system only | Shift end (overnight-aware) + `day_close_after_min`; no shift → next local midnight + the same. |
| `biometric_set_role(...)` | new helper | system only | Changes a raw punch's role only if something differs; audits before/after. |
| `biometric_write_slot(...)` | new helper | system only | Inserts or moves one slot row; audits; refuses locked slots. |
| `biometric_project_day(emp, day)` | new | system only (and through `biometric_project_now`) | The projection for one employee-day (§6). Idempotent. |
| `biometric_run_projection(max)` | new **procedure** (security invoker — PostgreSQL forbids `COMMIT` in a definer procedure) | system only (pg_cron as `postgres`) | Assigns work dates, then projects due employee-days, one transaction each. |
| `biometric_project_now(emp, day)` | new | HR / Admin of that person | "Process now" after a review decision; same function, same lock. |
| `day_events(emp, day)` | new, stable | anyone who `can_see(emp)` | Counted rows plus the day's raw punches with roles, for My Attendance and the register drawer. No payloads, no flag details for employees. |
| `decide_correction` | **changed** (wrapper) | unchanged (HR, manager) | Lock 7 then `decide_correction_core`. |
| `decide_correction_core` | renamed original | nobody | Body unchanged. |
| `verification_log` | **changed** (one CASE) | unchanged (HR) | Outcome `biometric` / `imported` for those rows. |
| `biometric_review_event` | changed (biometric) | unchanged | Resets `processed_at` when a punch becomes `stored`. |
| `biometric_state_guard` | changed (biometric) | trigger | Freezes `work_date`; `held` needs a reason. |

Unchanged and verified to need no change: `punch`, `punch_core`, `session_state`, `day_for`, `day_for_core`,
`my_today`, `my_today_core`, `work_date_for_checkin`, `request_correction`, `cancel_correction`,
`attendance_history`, `report_days`, `attendance_register`, `report_people`, `report_trend`,
`dashboard_summary(_core)`, `biometric_ingest`, `biometric_heartbeat`, all mapping functions.

---

## 6. Projection rules

### 6.1 Which employee-days are processed
`biometric_run_projection` (every minute):
1. Gives every attributed punch without a work date its work date (`biometric_work_date_at`) — for all companies,
   so HR sees punches on the right day even while projection is off. Work date is frozen from then on.
2. Picks up to `max` employee-days (oldest first) of **active** companies where projection is enabled and any of:
   a punch is unprocessed (`stored`, `processed_at is null`); a `provisional_out` whose day-close time has passed;
   and every 15 minutes, `held` punches (so a roster, leave or correction fix is noticed) and recent closed days that
   still have only a check-in (to set the `incomplete` flag).
   For a company whose projection was switched **off**, only days that already have a projected slot are still
   finalised (so a started day is not left half-done) — owner question Q3.
3. For each: `biometric_project_day` inside its own sub-block; on error the day's punches get
   `projection_failures + 1` and one `processing_failure` error record; after 3 failures the day is skipped until an
   Admin resolves the error. A lock wait over 5 s (`lock_timeout`) is not a failure — the day is retried next run.
   `COMMIT` after every day.

### 6.2 The gate — what may count (requirements 7 and 8)
Evaluated once, when a punch is first processed (`stored` or `held`, not yet decided otherwise):

| Check | Result if it fails |
|---|---|
| Punch time not in the future (`punch_at <= now()`) | left `stored`; retried next minute |
| From a device, not an import batch (imports are 0013) | `held` · `import_not_enabled` |
| Day locked (approved correction, or a superseded slot) | `after_correction` (HR review) |
| Day-level hold (§6.3) | `held` · reason |
| `source_auth = 'authenticated'` | `flagged` · `unauthenticated_source` |
| No raw time flags and no state flags (drift, DST, offset mismatch, future-within-tolerance, late backfill, inactive, claim rejected…) | `flagged` (reasons kept) |
| Not older than `auto_project_max_age_days` (2) | `flagged` · `late_backfill` |
| Work date not ambiguous between an overnight shift and the next shift (§7) | `flagged` · `ambiguous_work_date` |

A punch HR has accepted (`accept_time` / `not_duplicate` → `stored`, `decided = true`) skips the three *soft* checks
(authentication, flags, age): that acceptance is the HR review the owner asked for. It never skips the future, import,
lock or day-level checks. `possible_duplicate`, `unmatched`, `flagged`, `rejected` and `dismissed` punches are never
read as candidates. This also closes finding E11: a punch attached by a later mapping is re-gated here.

### 6.3 Day-level holds (requirement 10)
Same rules the app applies, decided again on every run, so fixing the cause releases the punch automatically:
`employee_inactive` (deactivated, and the day is not before an exit date) · `after_exit` · `before_joining` ·
`non_working_day` (roster off or holiday — `plan_for`) · `on_leave` (approved full-day leave — `leave_on`;
half-day leave projects, as the app allows check-in) · `correction_pending`. A released punch that is by then older
than the auto window becomes `flagged · late_backfill` instead of projecting. Holds never touch rows already
projected for that day (no voiding); they apply to new punches.

### 6.4 First-in / last-out (default device mode)
Inputs: gated punches of the day (time order) + the day's live app/correction events + the two slot rows.
1. **Double press:** a punch within `double_press_s` (60 s) of the previous kept punch — any device — is `extra`.
2. **Reconcile:** a punch within `reconcile_min` (5 min) of the earliest live app/correction `in` or latest
   `out` is `reconciled` (`reconciled_with` = that event). The app event stays the counted one.
3. **In slot:** if the day has a live app/correction `in`, there is no biometric `in`; unreconciled punches before it
   are `flagged · before_app_checkin` (architecture rule 7 — never guessed). Otherwise the earliest remaining punch
   fills slot `in`. If a slot row exists and an earlier punch arrives **before day close**, the row is moved in place
   (`at`, `biometric_event_id`, device, location — same id) and the previous punch becomes `extra`; **after day close**
   the earlier punch is `flagged · after_day_close` and the row is not moved.
4. **Out candidate:** the latest remaining punch at least `min_session_min` (30) after the in, and only if the day has
   no live app/correction `out`. Punches after an app check-out are `extra`.
5. **Before day close** the candidate is `provisional_out` — **no row**. The person stays checked in (`working`) in
   `session_state`, `day_for` keeps the day open, nothing is final. The app check-out still works and wins (rule 2/4).
6. **At day close** (`now() >= biometric_day_close_at`, or any live event on a later work date) projection inserts the
   `out` row from the candidate (`biometric_finalise` in the audit log). From then on it is a normal counted check-out.
   A finalised `out` is never moved; a later punch is `flagged · after_day_close`.
7. **No candidate at day close** (single punch, or all within 30 min): no check-out is invented. The day becomes
   "missing check-out" under the existing rule; the `in` punch carries flag `incomplete` for HR.
8. Everything else is `extra` (kept, shown, never counted). Breaks are never inferred.

### 6.5 Device-direction mode
Each gated punch carries the device's `in`/`out`. Reconcile with an app event of the **same** kind within 5 min →
`reconciled`. Otherwise the punch must be later than every live event of that day (else `flagged · out_of_order`),
and must be a valid transition given the day's last live event (`in` while checked in, `out` while checked out or on
an app break → `flagged · impossible_transition`). Valid punches become slot `dev:<raw id>` at once (explicit
direction — no provisional stage). A day mixing devices of the two modes, or existing slots of the other basis, is
`flagged · mixed_direction_modes`; a device punch with no direction is `flagged · no_direction`.

### 6.6 Protecting the app's session state (requirement 1)
Because `session_state` reads the latest live event across all days (E2), before inserting an **in** row projection
checks:
- **Open session on another day.** If the person is still checked in on another work date whose day has not closed
  (e.g. an overnight shift running into this morning), the punch is `flagged · open_session_other_day`. A stale
  session on a day that has already closed does not block (the new `in` simply becomes the current session — the app
  user would otherwise be stuck on "already checked in").
- **Would open a finished day.** If the day is already closed, no check-out will be created, and the new `in` would
  become the person's latest live event, it would leave them "checked in" on a past day and block their next app
  check-in. Such a punch is `flagged · would_open_closed_day` unless HR has accepted it.
- **Future rows.** Rows are never inserted with `at > now()` (punches within the 120 s tolerance wait).
An `out` row is inserted only at day close or in device mode as a valid transition, so it cannot reopen anything.
Known, unchanged behaviour (owner question Q4): a person whose day ends with a counted `in` and no `out` — app or
biometric — is "checked in" until a correction, exactly as an app user who forgot to check out is today.

### 6.7 Traceability and audit (requirement 12)
Every insert (`biometric_project`), move (`biometric_slot_moved`), finalisation (`biometric_finalise`) and role change
(`biometric_role_<status>`) writes one `audit_log` row (company, before/after JSON, raw id). `actor` is null for the
scheduled job and the HR member for `biometric_project_now`. Re-running with the same inputs writes nothing.

---

## 7. Work date and day close

`biometric_work_date_at(emp, at, direction)` with `D` = the punch's local date in the company zone and `Y` = the
shift of `D − 1`:
- If `Y` is overnight, `D − 1` is a working day and `at < shift_end(Y)` → `D − 1` (identical to
  `work_date_for_checkin` with `now()` replaced by the punch time).
- If additionally `shift_end(Y) ≤ at < shift_end(Y) + day_close_after_min` and the punch is not an explicit device
  `in` → still `D − 1` (a night worker's departure after shift end belongs to the night), **unless** today's working
  shift starts before that boundary — then it is `ambiguous`: `flagged · ambiguous_work_date` for HR.
- Otherwise `D`.

`biometric_day_close_at(emp, day)` = the day's shift end (next day for overnight shifts) + `day_close_after_min`;
with no shift: next local midnight + `day_close_after_min`. Because `day_close_after_min ≤ 239` (0010) and the engine
keeps an open day live until `shift_end + 4 h`, the out is always written before the day would show
"missing check-out". Limitation (Q8): if the gap between two of a person's shifts is shorter than
`day_close_after_min`, the earlier day is closed by the next day's first punch instead.

---

## 8. Transactions and lock order

### 8.1 Global lock order (unchanged from B3.2/B3.3, now with projection)
```
 43  per agent batch            (biometric_ingest)
  ↓
 41  per device code            (mapping change: exclusive; ingest, review: shared)
  ↓
  7  per employee               (punch_core · decide_correction wrapper · biometric_project_day)
  ↓
 row locks: biometric_event_state (ascending raw id) → attendance_events slot rows → attendance_corrections
```
Projection takes **only 7** and then row locks. It never takes 41 or 43, so it can never wait on them while holding 7.
Every path that takes 7 takes exactly one 7 lock per transaction (one employee-day), so 7-vs-7 cycles are impossible.

### 8.2 Who takes what
```
 web punch           : 7 ─► read session_state ─► insert attendance_events
 correction approval : 7 ─► correction row FOR UPDATE ─► update superseded_by / insert correction row   (wrapper)
 projection (1 day)  : 7 ─► day's state rows FOR UPDATE (raw id order) ─► slot rows ─► audit
 HR review           : 41 shared ─► one state row FOR UPDATE            (never 7)
 mapping change      : 41 exclusive ─► unmatched state rows              (never 7; disjoint rows: unmatched have no employee)
 ingest batch        : 43 ─► 41 shared (sorted) ─► insert raw + state    (never 7, no attendance writes)
 queue: work dates   : state rows with work_date null only               (no advisory lock)
 HR "process now"   : 7 ─► that person's undated state rows ─► same as projection
```

### 8.3 Sequence — a punch from the machine to the register
```
 Agent ──POST──► biometric_ingest (tx A: 43 → 41s → raw + state 'stored'; COMMIT)
                                                    │  ≤ 1 min
 pg_cron ──CALL──► biometric_run_projection
        step 1 (tx B): work_date for new punches; COMMIT
        step 2, per employee-day (tx C1, C2, …):
           lock 7(emp) ─► gate ─► roles ─► insert/move slot rows ─► audit ─► COMMIT
 App ── punch() (tx P: lock 7(emp) waits for C, then sees its rows)
 Register / reports ── day_for() reads rows as today
```

### 8.4 Races, and why each is safe
| Race (same person) | Outcome |
|---|---|
| App check-in vs projection of the same morning | Serialised by 7. If projection commits first, the app sees "already checked in" (the machine check-in is counted, as it would be for a second app tap). If the app commits first, the machine punch reconciles (≤ 5 min) or is `flagged · before_app_checkin`. |
| App check-out vs provisional out | Serialised by 7. The app check-out is counted; the punch becomes `reconciled` or `extra` at the next run. |
| Correction approval vs projection | Serialised by 7 (wrapper). Approval first → day locked → punches `after_correction`. Projection first → the correction then supersedes the biometric row as it would an app row. |
| Correction request vs projection | No lock in `request_correction`. Either order leaves a consistent day: a request made just after a projection simply targets the projected row when approved. |
| HR review vs projection | Projection waits for the state row; review never needs 7 → no cycle. A newly accepted punch is projected at the next run. |
| Two queue runs overlapping (cron overlap) | Both wait on 7 per day; the second sees no changes (idempotent) and writes nothing. |
| Mapping attach vs projection | Disjoint rows; attached punches are re-gated at the next run. |
| Ingest of a new punch during projection | The new punch commits as `stored`; the next run reprojects the day. |

---

## 9. Failure and rollback scenarios

| Scenario | What happens | Recovery |
|---|---|---|
| Projection error for one day (bug, constraint) | That day's sub-transaction rolls back completely — no half-written slots. Failure counter + one error record; other days continue. | Admin sees it under Sync Activity errors; after a fix the counter is reset by resolving the error. |
| Lock wait > 5 s | Day skipped this run. | Next run. |
| pg_cron stops | Punches stay `stored`; open days are not finalised and turn "missing check-out" at shift end + 4 h. | When it resumes, days are finalised from their qualifying punches (the day was already accepted, so finalisation is not re-gated by age). |
| Agent offline for days | Late punches arrive flagged `late_backfill` (> 2 days) → HR review; ≤ 2 days project normally (out of order handled, §6.4). | HR accepts or dismisses each. |
| Migration 0012 fails part-way | One transaction: nothing applied. | Fix and re-run. |
| Projection behaves wrongly after go-live | Admin switches `projection_enabled` off: no new days are projected. Rows already counted stay (no voiding) and are fixed with corrections. | A later migration can drop the wrapper (rename back) and the new functions; the additive columns can stay. |
| Correction approved for a day with a projected row | Row superseded as for app rows; later punches `after_correction`; the slot never refills. | — |
| Device switched from first_last to device mode mid-day | `flagged · mixed_direction_modes` for that day. | HR decides; employee requests a correction if needed. |
| Clock jump on the device | Drift > 5 min is flagged at ingest; never auto-projected. | HR review. |
| Company deleted | Owner script deletes state → coords → attendance events → raw events (reordered, A9). | — |

---

## 10. Security and permission matrix

| Call / data | anon | Employee | Manager | HR | Admin | System (pg_cron / owner) |
|---|---|---|---|---|---|---|
| `biometric_ingest`, `biometric_heartbeat` | with agent key only (unchanged) | — | — | — | — | — |
| `punch` (web) | — | own | own | own | own | — |
| `biometric_project_day`, `biometric_run_projection`, helpers, `biometric_work_date_at`, `biometric_day_close_at` | **no** | **no** | **no** | **no** | **no** | yes (revoked from public, anon, authenticated) |
| `biometric_project_now` | no | no | no | own company, people in HR scope (`hr_of`) | yes | — |
| `day_events` | no | own days | team (`can_see`) | company scope | company | — |
| Raw payloads | no | no | no | no | via `biometric_raw_payload` (audited, unchanged) | — |
| `decide_correction` (wrapper) | no | no (own excluded, unchanged) | team, unchanged | scope, unchanged | yes | — |
| `decide_correction_core` | no | no | no | no | no | no (definer call only) |
| `verification_log` | no | no | no | yes (unchanged) | yes | — |
| Turn projection on/off (`biometric_save_settings`) | no | no | no | no | yes (unchanged, Admin only) | — |
| Read `attendance_events` incl. new columns | no | own (RLS `can_see`, unchanged) | team | scope | company | — |
| Insert / update `attendance_events` directly | no | no (no grant, unchanged) | no | no | no | only through definer functions; biometric rows only while `attendos.projection = on` (guard) |

Other security properties: every new function is `SECURITY DEFINER` with `search_path = public`; no new anonymous
entry point; no service-role key anywhere; cross-company references refused by `company_refs` (device, batch) and the
guard (raw punch); employees see role labels but not flag details, device addresses or payloads. The guard's
`attendos.projection` setting is defence in depth only — no client role can write the table at all.

---

## 11. Reports, exports and displays

### 11.1 Register, reports, analytics, CSV export
No function or column changes. `report_days` → `day_for` counts biometric rows like app rows: first in, last out,
worked, late, early, overtime and status come from them once they exist. Effects owners should expect:
- **Today, before day close:** a biometric-only person shows *working* with live minutes running until day close
  (provisional out not counted) — up to `day_close_after_min` (2 h) more than they actually stayed, until the out is
  written. Final figures are correct after close. (Q7)
- **Held / flagged punches** are not in reports: the person shows *absent* (or *on leave* / *off*) until HR resolves
  the review item. The review queue count is the signal.
- **Missing check-out** days from single punches show as today ("missing checkout") with the `incomplete` flag.
- **Corrections** behave exactly as now; `pending_correction` is unchanged.
- **Exports** keep their columns; they never include provisional, extra or raw punches. A "Source" column is not added
  in 0012 (owner question Q9).
- **Performance:** `day_for` does the same loop; two partial indexes add nothing to app rows. The scheduled job runs
  one small transaction per employee-day.

### 11.2 Verification history
`verification_log` outcome: `biometric` (source biometric) or `imported` (source import); app rows unchanged
(`verified`, `not_required`, `corrected`, `refused`). The location column shows the device's office.

### 11.3 UI (same commit as 0012, small)
- `src/lib/attendance.ts`: `source?: "web" | "correction" | "biometric" | "import"`.
- Timeline (`AttendanceCard.tsx:221`): source first — "· biometric device" / "· imported" — before the
  `verified` text, so a biometric row can never read "location verified" or "no location".
- Verification badges (`LocationsPanel.tsx`): "Biometric" and "Imported" tones.
- My Attendance and the register drawer read `day_events` for provisional/extra punches ("Provisional Out — becomes
  your check-out at day close").

---

## 12. Test plan (to run when 0012 is implemented)

### 12.1 Must stay green, unchanged
Full database suite (633 today), `lock_proof.sh` (21), `gateway_proof.sh` (6), gateway HTTP (18), company deletion
(4), app regression (29), app checks (53), clean migration 0001–0012. Existing attendance, refinement, tenancy,
verification, leave/report and security-matrix tests are **not edited**.

### 12.2 New `biometric_projection_test.sql` (database)
1. Projection off by default: nothing projected; enabling projects; disabling stops new days.
2. Single in → slot `in`, `direction_basis = inferred_first_last`, `verified = false`, device and raw linked.
3. In + out ≥ 30 min, before close → out is `provisional_out`, **no row**; `day_for` open (`working`), early 0, overtime 0.
4. At close → `out` row; `day_for` final hours/early/overtime equal an app day with the same times.
5. In + out < 30 min → no out; at close `missing_checkout` + `incomplete`.
6. Earlier punch arriving before close → same row id, `at` moved, audit before/after; after close → `after_day_close`.
7. Double press (60 s, across devices) → `extra`; possible duplicate never projected.
8. App in at 09:00, machine 09:03 → `reconciled`; machine 08:30 → `before_app_checkin`; app out then machine → `extra`.
9. Unauthenticated LAN punch → flagged; after HR `accept_time` → projected.
10. Late backfill (> 2 days) → flagged; ≤ 2 days → projected; future within 120 s → waits, then projects.
11. Holiday, weekly off, full-day leave → `held`; roster/leave fixed → released and projected; half-day leave projects.
12. Before joining / after exit / deactivated → `held`.
13. Pending correction → `held`; approved correction → day locked, slot superseded and never refilled, new punches `after_correction`.
14. Overnight shift 22:00–06:00: in 21:55 and out 06:20 on the same work date; ambiguous overlap → flagged.
15. Device mode: valid in/out → `dev:<id>` rows immediately; out without in, in while in, out of order → flagged; mixed modes → flagged.
16. Session protection: lone in on a closed day that would become the latest event → `would_open_closed_day`; open overnight session → `open_session_other_day`; after projection `punch('in')` behaves exactly as for an app user.
17. Idempotence: second run → no row change, no audit row, no version change.
18. Guard: direct insert of a biometric row without projection refused; changing person/day/slot/kind refused; moving a superseded slot refused; clearing `superseded_by` refused; raw/person/time mismatch refused; web row with biometric columns refused.
19. Constraints: source check, shape check, slot uniqueness, one row per raw punch.
20. Mapping attach of an old unmatched punch → re-gated (late_backfill / unauthenticated), not projected silently (finding E11).
21. Permissions: every system function refused to anon/authenticated; `biometric_project_now` HR-scope only, other company refused; `day_events` per `can_see`; no payload in `day_events`.
22. `verification_log` outcome `biometric`; never `verified`.
23. Company deletion with projected rows (reordered script) leaves other companies untouched.

### 12.3 Concurrency proofs (`concurrency/projection_proof.sh`, two real sessions each)
1. Web check-in and projection of the same person started together, 50 rounds: exactly one counted in, state consistent, no deadlock.
2. Correction approval vs projection (both orders, with `pg_sleep` inside to force overlap): approval-first locks the day; projection-first row is superseded; never both an extra slot and a correction row for the same in.
3. Web check-out vs day-close finalisation: never two counted outs.
4. Two `biometric_run_projection` calls at once: identical result, audit count = single run.
5. HR review vs projection of the same punch; mapping change vs projection; ingest vs projection.
6. Mixed load (ingest + review + mapping + punch + correction + projection, 5 rounds): no deadlock, invariants hold
   (every biometric row matches its raw punch; no slot duplicated; no superseded row changed).

### 12.4 End-to-end (local PostgREST)
Gateway ingest → `CALL biometric_run_projection()` → `my_today` and `day_events` over HTTP show the biometric check-in;
the app screen shows "biometric device" and never "location verified"; register and CSV show the same totals as the
database. pg_cron itself is not available on the local PostgreSQL (checked: only `btree_gist`, `pgcrypto`), so locally
the procedure is called directly; the schedule is verified only on hosted after approval.

---

## 13. Implemented vs proposed

| Item | State |
|---|---|
| Migrations 0010 (core) and 0011 (gateway) | **Implemented, locally tested, approved for local development.** Not hosted. |
| Correction lock wrapper | **Proposed**; SQL exists only as `tests/concurrency/proposed_correction_lock.sql`, applied to throwaway copies by `lock_proof.sh` (proven). Not in any migration. |
| `pg_cron` availability check | Implemented, read-only (`deploy/check_biometric_prereqs.sql` check 6). Nothing installed. |
| Everything in §4–§11 and Appendix A (columns, constraints, guard, functions, procedure, `day_events`, verification outcome, UI labels, script reorder) | **Proposed only.** Not written as a migration, not compiled, not executed. |
| Tests in §12.2–§12.4 | **Planned only.** Not written. |
| Real hardware, hosted project, deployment | Not done. |

---

## 14. Owner questions before implementation

| # | Question | Proposed default |
|---|---|---|
| Q1 | Install `pg_cron` on the hosted project (needed for day close and the queue). | Yes, when hosted is approved; until then local only. |
| Q2 | Unauthenticated LAN devices: HR accepts each punch (as now), or add a bulk "accept this device's punches from … to …" with one reason, recorded per punch? | Per punch in 0012; bulk only if you ask for it. |
| Q3 | When projection is switched off, finish days already started (default here) or stop everything at once? | Finish started days. |
| Q4 | A day ending with a counted in and no out leaves the person "checked in" until a correction — same as an app user who forgets. Change the engine later (separate decision), or keep? | Keep (no engine change in 0012). |
| Q5 | No voiding and no HR-raised corrections: a wrongly projected row can only be replaced by the employee's own correction request. Add HR-raised corrections in a later phase? | Later phase. |
| Q6 | `work_mode` of biometric rows: always `office` (devices are at an office), or the roster's mode? | `office`. |
| Q7 | Live minutes run until day close for biometric-only staff (up to 2 h too many on "today" screens). Acceptable, or show "Provisional" minutes separately in B6? | Acceptable; label in UI. |
| Q8 | Shifts closer together than `day_close_after_min`: earlier day closes at the next day's first punch. Acceptable? | Yes; warn in settings. |
| Q9 | Add a "Source" column to register/CSV exports? | Not in 0012. |
| Q10 | Imports (0013): project only after the batch is approved by HR, through the same gate? | Yes, designed in 0013. |

---

## Appendix A — proposed SQL for `0012_biometric_projection.sql` (NOT a migration; not compiled or run)

### A1. `attendance_events` — additive columns, checks, indexes
```sql
alter table public.attendance_events
  add column device_id uuid,
  add column biometric_event_id bigint,
  add column import_batch_id uuid,
  add column projection_slot text,
  add column direction_basis text;
alter table public.attendance_events
  add constraint attendance_events_device_fk foreign key (device_id) references public.biometric_devices (id),
  add constraint attendance_events_raw_fk foreign key (biometric_event_id) references public.biometric_raw_events (id) on delete restrict,
  add constraint attendance_events_batch_fk foreign key (import_batch_id) references public.biometric_import_batches (id),
  add constraint attendance_events_slot_check check (projection_slot is null or projection_slot ~ '^(in|out|dev:[0-9]{1,19})$'),
  add constraint attendance_events_basis_check check (direction_basis is null or direction_basis in ('device', 'inferred_first_last')),
  add constraint attendance_events_source_check check (source in ('web', 'correction', 'biometric', 'import')) not valid,
  add constraint attendance_events_external_shape check (
    case when source in ('biometric', 'import') then
           biometric_event_id is not null and projection_slot is not null and direction_basis is not null
       and kind in ('in', 'out') and not verified and distance_m is null and accuracy_m is null and correction_id is null
       and ((source = 'biometric') = (device_id is not null)) and ((source = 'import') = (import_batch_id is not null))
       and ((direction_basis = 'device') = (projection_slot like 'dev:%'))
    else num_nulls(device_id, biometric_event_id, import_batch_id, projection_slot, direction_basis) = 5 end) not valid;
alter table public.attendance_events validate constraint attendance_events_source_check;
alter table public.attendance_events validate constraint attendance_events_external_shape;
create unique index attendance_events_slot_key on public.attendance_events (employee_id, work_date, projection_slot)
  where projection_slot is not null;
create unique index attendance_events_raw_key on public.attendance_events (biometric_event_id)
  where biometric_event_id is not null;

drop trigger company_refs on public.attendance_events;
create trigger company_refs before insert or update on public.attendance_events
  for each row execute function public.check_company_refs('location_id:locations', 'device_id:biometric_devices',
                                                          'import_batch_id:biometric_import_batches');
```

### A2. Guard trigger on `attendance_events`
```sql
create function public.attendance_external_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  r public.biometric_raw_events;
  s public.biometric_event_state;
  projecting boolean := coalesce(current_setting('attendos.projection', true), '') = 'on';
begin
  if tg_op = 'UPDATE' and old.source in ('biometric', 'import') then
    if old.superseded_by is not null and new.superseded_by is distinct from old.superseded_by then
      raise exception 'A replaced attendance event stays replaced' using errcode = '42501';
    end if;
    if (new.employee_id, new.kind, new.work_date, new.source, new.projection_slot, new.direction_basis, new.work_mode,
        new.verified, new.correction_id, new.distance_m, new.accuracy_m)
       is distinct from
       (old.employee_id, old.kind, old.work_date, old.source, old.projection_slot, old.direction_basis, old.work_mode,
        old.verified, old.correction_id, old.distance_m, old.accuracy_m) then
      raise exception 'A projected attendance event keeps its person, day, slot and kind' using errcode = '42501';
    end if;
    if (new.at, new.biometric_event_id, new.device_id, new.import_batch_id, new.location_id)
       is distinct from (old.at, old.biometric_event_id, old.device_id, old.import_batch_id, old.location_id)
       and (not projecting or old.superseded_by is not null) then
      raise exception 'Only projection may move an unlocked projected slot' using errcode = '42501';
    end if;
  end if;
  if new.source in ('biometric', 'import')
     and (tg_op = 'INSERT' or new.biometric_event_id is distinct from old.biometric_event_id or new.at is distinct from old.at) then
    if tg_op = 'INSERT' and not projecting then
      raise exception 'Biometric attendance is written only by projection' using errcode = '42501';
    end if;
    select * into r from public.biometric_raw_events where id = new.biometric_event_id;
    select * into s from public.biometric_event_state where raw_event_id = new.biometric_event_id;
    if r.id is null or r.company_id is distinct from public.emp_company(new.employee_id)
       or s.employee_id is distinct from new.employee_id or s.work_date is distinct from new.work_date
       or r.punch_at is distinct from new.at or r.device_id is distinct from new.device_id
       or r.import_batch_id is distinct from new.import_batch_id then
      raise exception 'Projected attendance must match its raw punch (company, person, device, time, work day)' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
create trigger external_guard before insert or update on public.attendance_events
  for each row execute function public.attendance_external_guard();
```

### A3. Processing state — `held`, failure counter, frozen work date
```sql
alter table public.biometric_event_state
  add column hold_reason text check (hold_reason is null or hold_reason in ('employee_inactive', 'after_exit', 'before_joining',
    'non_working_day', 'on_leave', 'correction_pending', 'import_not_enabled')),
  add column projection_failures smallint not null default 0 check (projection_failures between 0 and 100);
-- status list gains 'held' (constraint names are read from pg_constraint in the migration; shown here by meaning)
alter table public.biometric_event_state drop constraint biometric_event_state_status_check;
alter table public.biometric_event_state add constraint biometric_event_state_status_check check (status in ('stored', 'unmatched',
  'flagged', 'projected', 'provisional_out', 'extra', 'possible_duplicate', 'reconciled', 'after_correction', 'rejected',
  'dismissed', 'held'));
alter table public.biometric_event_state add constraint biometric_event_state_hold check ((status = 'held') = (hold_reason is not null));
alter table public.biometric_event_state add constraint biometric_event_state_held_mapped check (status <> 'held' or mapping_id is not null);
create index biometric_event_state_due on public.biometric_event_state (company_id, work_date, employee_id)
  where status in ('stored', 'held', 'provisional_out');

-- biometric_state_guard (create or replace) gains, in the UPDATE branch:
--   if old.work_date is not null and new.work_date is distinct from old.work_date then
--     raise exception 'The work day of a punch is fixed once set' using errcode = '42501';
--   end if;
```

### A4. Work date, day close, helpers, projection
```sql
create function public.biometric_work_date_at(p_emp uuid, p_at timestamptz, p_direction text default null,
                                              out work_date date, out ambiguous boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  cid uuid := public.emp_company(p_emp);
  close_min int := (public.biometric_settings_for(cid)).day_close_after_min;
  d date := (p_at at time zone public.company_tz(cid))::date;
  y public.shifts; t public.shifts;
  y_end timestamptz; t_start timestamptz;
begin
  ambiguous := false; work_date := d;
  select sh.* into y from public.shift_for(p_emp, d - 1) f join public.shifts sh on sh.id = f.shift_id;
  if y.id is null or y.end_time > y.start_time or (select p.work_mode from public.plan_for(p_emp, d - 1) p) = 'off' then return; end if;
  y_end := public.at_local(cid, d, y.end_time);
  if p_at < y_end then work_date := d - 1; return; end if;                 -- identical to work_date_for_checkin
  if p_direction = 'in' or p_at >= y_end + make_interval(mins => close_min) then return; end if;
  select sh.* into t from public.shift_for(p_emp, d) f join public.shifts sh on sh.id = f.shift_id;
  if t.id is not null and (select p.work_mode from public.plan_for(p_emp, d) p) <> 'off' then
    t_start := public.at_local(cid, d, t.start_time);
    if t_start < y_end + make_interval(mins => close_min) then ambiguous := true; end if;
  end if;
  work_date := d - 1;                                                       -- a night worker's departure after shift end
end $$;

create function public.biometric_day_close_at(p_emp uuid, p_day date) returns timestamptz
language sql stable security definer set search_path = public as $$
  select coalesce(
           (select public.at_local(public.emp_company(p_emp), p_day + case when sh.end_time <= sh.start_time then 1 else 0 end, sh.end_time)
              from public.shift_for(p_emp, p_day) f join public.shifts sh on sh.id = f.shift_id
             where (select p.work_mode from public.plan_for(p_emp, p_day) p) <> 'off'),
           public.at_local(public.emp_company(p_emp), p_day + 1, '00:00'))
         + make_interval(mins => (public.biometric_settings_for(public.emp_company(p_emp))).day_close_after_min)
$$;

-- one role change for one raw punch; nothing written (no version bump, no audit) if nothing differs
create function public.biometric_set_role(p_raw bigint, p_status text, p_event bigint default null, p_slot text default null,
                                          p_reconciled bigint default null, p_flag text default null, p_hold text default null)
returns void language plpgsql security definer set search_path = public as $$
declare s public.biometric_event_state; a public.biometric_event_state;
begin
  select * into s from public.biometric_event_state where raw_event_id = p_raw;
  if s.status = p_status and s.projected_event_id is not distinct from p_event and s.projection_slot is not distinct from p_slot
     and s.reconciled_with is not distinct from p_reconciled and s.hold_reason is not distinct from p_hold
     and (p_flag is null or p_flag = any (s.flag_reasons)) and s.processed_at is not null then
    return;
  end if;
  update public.biometric_event_state
     set status = p_status, projected_event_id = p_event, projection_slot = p_slot, reconciled_with = p_reconciled,
         hold_reason = p_hold, processed_at = now(),
         flag_reasons = case when p_flag is null or p_flag = any (flag_reasons) then flag_reasons else array_append(flag_reasons, p_flag) end
   where raw_event_id = p_raw returning * into a;
  if (to_jsonb(s) - 'processed_at' - 'version' - 'updated_at') is distinct from (to_jsonb(a) - 'processed_at' - 'version' - 'updated_at') then
    insert into public.audit_log (company_id, action, target, target_id, before, after)
      values (s.company_id, 'biometric_role_' || p_status, 'biometric_event_state', p_raw::text, to_jsonb(s), to_jsonb(a));
  end if;
end $$;

-- insert or move one slot row (same id); never touches a superseded slot
create function public.biometric_write_slot(p_emp uuid, p_day date, p_slot text, p_kind text, p_raw bigint, p_basis text,
                                            p_action text default 'biometric_project')
returns bigint language plpgsql security definer set search_path = public as $$
declare
  r public.biometric_raw_events := (select x from public.biometric_raw_events x where x.id = p_raw);
  loc uuid := (select location_id from public.biometric_devices where id = r.device_id);
  cur public.attendance_events;
  ev public.attendance_events;
begin
  select * into cur from public.attendance_events where employee_id = p_emp and work_date = p_day and projection_slot = p_slot for update;
  if cur.id is null then
    insert into public.attendance_events (employee_id, kind, at, work_mode, location_id, verified, source, work_date,
                                          device_id, biometric_event_id, projection_slot, direction_basis)
      values (p_emp, p_kind, r.punch_at, 'office', loc, false, 'biometric', p_day, r.device_id, p_raw, p_slot, p_basis)
      returning * into ev;
    insert into public.audit_log (company_id, action, target, target_id, after)
      values (r.company_id, p_action, 'attendance_events', ev.id::text, to_jsonb(ev) || jsonb_build_object('raw_event_id', p_raw));
  elsif cur.superseded_by is not null then
    raise exception 'Slot % of % is locked by a correction', p_slot, p_day using errcode = '42501';
  elsif cur.biometric_event_id = p_raw then
    return cur.id;
  else
    update public.attendance_events set at = r.punch_at, biometric_event_id = p_raw, device_id = r.device_id, location_id = loc
     where id = cur.id returning * into ev;
    insert into public.audit_log (company_id, action, target, target_id, before, after)
      values (r.company_id, 'biometric_slot_moved', 'attendance_events', ev.id::text, to_jsonb(cur), to_jsonb(ev));
  end if;
  return ev.id;
end $$;

create function public.biometric_project_day(p_emp uuid, p_day date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cid uuid := public.emp_company(p_emp);
  st public.biometric_settings := public.biometric_settings_for(cid);
  emp public.employees;
  pl record;
  lv public.leave_requests;
  hold text;
  closed boolean;
  locked boolean;
  modes text[];
  c record;
  ss record;
  prev_at timestamptz;
  app_in public.attendance_events;
  app_out public.attendance_events;
  in_row public.attendance_events;
  out_row public.attendance_events;
  r_ids bigint[] := '{}';
  r_at timestamptz[] := '{}';
  in_raw bigint; base_in timestamptz; in_decided boolean;
  out_raw bigint;
  ev_id bigint;
  last_kind text;
  newest timestamptz;
  i int;
begin
  perform set_config('lock_timeout', '5s', true);
  perform pg_advisory_xact_lock(hashtextextended(p_emp::text, 7));        -- (E1) the lock punch_core and the wrapper take
  perform set_config('lock_timeout', '0', true);
  perform set_config('attendos.projection', 'on', true);

  if not coalesce((select active from public.companies where id = cid), false) then
    return jsonb_build_object('ok', false, 'reason', 'company_inactive');
  end if;
  if not st.projection_enabled and not exists (select 1 from public.attendance_events
       where employee_id = p_emp and work_date = p_day and projection_slot is not null) then
    return jsonb_build_object('ok', false, 'reason', 'projection_disabled');
  end if;
  -- row locks in one order only: this person-day's punches by raw id
  perform 1 from public.biometric_event_state where employee_id = p_emp and work_date = p_day order by raw_event_id for update;

  select * into emp from public.employees where id = p_emp;
  closed := now() >= public.biometric_day_close_at(p_emp, p_day)
         or exists (select 1 from public.attendance_events where employee_id = p_emp and work_date > p_day and superseded_by is null);
  locked := exists (select 1 from public.attendance_corrections where employee_id = p_emp and work_date = p_day and status = 'approved')
         or exists (select 1 from public.attendance_events where employee_id = p_emp and work_date = p_day
                     and projection_slot is not null and superseded_by is not null);
  select * into pl from public.plan_for(p_emp, p_day);
  lv := public.leave_on(p_emp, p_day);
  hold := case
    when emp.exit_date is not null and p_day > emp.exit_date then 'after_exit'
    when not emp.active and emp.exit_date is null then 'employee_inactive'
    when p_day < coalesce(emp.joining_date, (emp.created_at at time zone public.company_tz(cid))::date) then 'before_joining'
    when pl.work_mode = 'off' then 'non_working_day'
    when lv.id is not null and lv.half_day is null then 'on_leave'
    when exists (select 1 from public.attendance_corrections where employee_id = p_emp and work_date = p_day and status = 'pending')
      then 'correction_pending' end;

  -- 1. gate new punches (§6.2)
  for c in select s.raw_event_id id, s.decided, s.flag_reasons, r.punch_at, r.source_auth, r.time_flags, r.import_batch_id
             from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
            where s.employee_id = p_emp and s.work_date = p_day and s.status in ('stored', 'held')
            order by r.punch_at, s.raw_event_id loop
    if c.punch_at > now() then continue; end if;
    if c.import_batch_id is not null then perform public.biometric_set_role(c.id, 'held', p_hold => 'import_not_enabled');
    elsif locked then perform public.biometric_set_role(c.id, 'after_correction');
    elsif hold is not null then perform public.biometric_set_role(c.id, 'held', p_hold => hold);
    elsif not c.decided and c.source_auth <> 'authenticated' then perform public.biometric_set_role(c.id, 'flagged', p_flag => 'unauthenticated_source');
    elsif not c.decided and (cardinality(c.time_flags) > 0 or cardinality(c.flag_reasons) > 0) then perform public.biometric_set_role(c.id, 'flagged');
    elsif not c.decided and c.punch_at < now() - make_interval(days => st.auto_project_max_age_days) then
      perform public.biometric_set_role(c.id, 'flagged', p_flag => 'late_backfill');
    elsif (public.biometric_work_date_at(p_emp, c.punch_at, (select direction from public.biometric_raw_events where id = c.id))).ambiguous
          and not c.decided then
      perform public.biometric_set_role(c.id, 'flagged', p_flag => 'ambiguous_work_date');
    elsif (select status from public.biometric_event_state where raw_event_id = c.id) = 'held' then
      perform public.biometric_set_role(c.id, 'stored');                      -- hold released
    end if;
  end loop;
  if locked then  -- a provisional out on a corrected day is no longer a candidate (§7.1 of the architecture)
    for c in select raw_event_id id from public.biometric_event_state
              where employee_id = p_emp and work_date = p_day and status in ('provisional_out', 'extra', 'reconciled') and not decided loop
      perform public.biometric_set_role(c.id, 'after_correction');
    end loop;
    return jsonb_build_object('ok', true, 'locked', true);
  end if;

  -- 2. candidates: gated punches plus the day's current roles (recomputed every run; decided extras stay as HR left them)
  select array_agg(distinct d.direction_mode) into modes
    from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
    join public.biometric_devices d on d.id = r.device_id
   where s.employee_id = p_emp and s.work_date = p_day and r.punch_at <= now()
     and (s.status in ('stored', 'projected', 'provisional_out') or (s.status in ('extra', 'reconciled') and not s.decided));
  if cardinality(modes) > 1
     or exists (select 1 from public.attendance_events where employee_id = p_emp and work_date = p_day and projection_slot is not null
                  and direction_basis <> case when modes[1] = 'device' then 'device' else 'inferred_first_last' end) then
    for c in select s.raw_event_id id from public.biometric_event_state s
              where s.employee_id = p_emp and s.work_date = p_day and s.status in ('stored', 'provisional_out') loop
      perform public.biometric_set_role(c.id, 'flagged', p_flag => 'mixed_direction_modes');
    end loop;
    return jsonb_build_object('ok', true, 'flagged', 'mixed_direction_modes');
  end if;

  select * into app_in from public.attendance_events where employee_id = p_emp and work_date = p_day and superseded_by is null
     and kind = 'in' and source in ('web', 'correction') order by at, id limit 1;
  select * into app_out from public.attendance_events where employee_id = p_emp and work_date = p_day and superseded_by is null
     and kind = 'out' and source in ('web', 'correction') order by at desc, id desc limit 1;

  if modes[1] = 'device' then
    -- 3a. device direction (§6.5): punches not yet counted, in time order
    for c in select s.raw_event_id id, s.decided, r.punch_at, r.direction
               from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
              where s.employee_id = p_emp and s.work_date = p_day and r.punch_at <= now() and s.projected_event_id is null
                and (s.status = 'stored' or (s.status in ('extra', 'reconciled') and not s.decided))
              order by r.punch_at, s.raw_event_id loop
      if c.direction is null then perform public.biometric_set_role(c.id, 'flagged', p_flag => 'no_direction'); continue; end if;
      select e.id into ev_id from public.attendance_events e where e.employee_id = p_emp and e.work_date = p_day and e.superseded_by is null
         and e.kind = c.direction and e.source in ('web', 'correction') and abs(extract(epoch from e.at - c.punch_at)) <= st.reconcile_min * 60
       order by abs(extract(epoch from e.at - c.punch_at)) limit 1;
      if ev_id is not null then perform public.biometric_set_role(c.id, 'reconciled', p_reconciled => ev_id); continue; end if;
      select max(at) into newest from public.attendance_events where employee_id = p_emp and work_date = p_day and superseded_by is null;
      if newest is not null and c.punch_at <= newest then perform public.biometric_set_role(c.id, 'flagged', p_flag => 'out_of_order'); continue; end if;
      select kind into last_kind from public.attendance_events where employee_id = p_emp and work_date = p_day and superseded_by is null
       order by at desc, id desc limit 1;
      select * into ss from public.session_state(p_emp);
      if (c.direction = 'in' and (last_kind in ('in', 'break_start', 'break_end')
             or (ss.state <> 'off' and ss.work_date <> p_day and now() < public.biometric_day_close_at(p_emp, ss.work_date))))
         or (c.direction = 'out' and coalesce(last_kind, 'out') in ('out', 'break_start')) then
        perform public.biometric_set_role(c.id, 'flagged', p_flag => 'impossible_transition'); continue;
      end if;
      if c.direction = 'in' and closed and not c.decided
         and c.punch_at > coalesce((select max(at) from public.attendance_events where employee_id = p_emp and superseded_by is null), '-infinity') then
        perform public.biometric_set_role(c.id, 'flagged', p_flag => 'would_open_closed_day'); continue;
      end if;
      ev_id := public.biometric_write_slot(p_emp, p_day, 'dev:' || c.id, c.direction, c.id, 'device');
      perform public.biometric_set_role(c.id, 'projected', ev_id, 'dev:' || c.id);
    end loop;
    return jsonb_build_object('ok', true, 'mode', 'device');
  end if;

  -- 3b. first-in / last-out (§6.4)
  select * into in_row from public.attendance_events where employee_id = p_emp and work_date = p_day and projection_slot = 'in';
  select * into out_row from public.attendance_events where employee_id = p_emp and work_date = p_day and projection_slot = 'out';
  for c in select s.raw_event_id id, s.projected_event_id, r.punch_at
             from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
            where s.employee_id = p_emp and s.work_date = p_day and r.punch_at <= now()
              and (s.status in ('stored', 'projected', 'provisional_out') or (s.status in ('extra', 'reconciled') and not s.decided))
            order by r.punch_at, s.raw_event_id loop
    if prev_at is not null and c.punch_at < prev_at + make_interval(secs => st.double_press_s) and c.projected_event_id is null then
      perform public.biometric_set_role(c.id, 'extra', p_flag => 'double_press'); continue;
    end if;
    prev_at := c.punch_at;
    if c.projected_event_id is null and app_in.id is not null and abs(extract(epoch from c.punch_at - app_in.at)) <= st.reconcile_min * 60 then
      perform public.biometric_set_role(c.id, 'reconciled', p_reconciled => app_in.id); continue;
    end if;
    if c.projected_event_id is null and app_out.id is not null and abs(extract(epoch from c.punch_at - app_out.at)) <= st.reconcile_min * 60 then
      perform public.biometric_set_role(c.id, 'reconciled', p_reconciled => app_out.id); continue;
    end if;
    if app_in.id is not null and c.punch_at < app_in.at then
      perform public.biometric_set_role(c.id, 'flagged', p_flag => 'before_app_checkin'); continue;
    end if;
    r_ids := r_ids || c.id; r_at := r_at || c.punch_at;
  end loop;

  -- in slot
  if app_in.id is not null then
    base_in := app_in.at;
  elsif in_row.id is not null then
    in_raw := in_row.biometric_event_id; base_in := in_row.at;
    if cardinality(r_ids) > 0 and r_ids[1] <> in_raw and r_at[1] < in_row.at then
      if closed then perform public.biometric_set_role(r_ids[1], 'flagged', p_flag => 'after_day_close');
                     r_ids := r_ids[2:]; r_at := r_at[2:];
      else in_raw := r_ids[1]; base_in := r_at[1]; end if;
    end if;
  elsif cardinality(r_ids) > 0 then
    in_raw := r_ids[1]; base_in := r_at[1];
  end if;

  -- out candidate: latest remaining punch ≥ min session after the in, only if the app has not checked out
  if base_in is not null and app_out.id is null then
    for i in reverse cardinality(r_ids) .. 1 loop
      if r_ids[i] is distinct from in_raw and r_at[i] >= base_in + make_interval(mins => st.min_session_min) then out_raw := r_ids[i]; exit; end if;
    end loop;
  end if;
  if out_row.id is not null and out_raw is distinct from out_row.biometric_event_id then   -- a counted check-out never moves
    if out_raw is not null then perform public.biometric_set_role(out_raw, 'flagged', p_flag => 'after_day_close'); end if;
    out_raw := out_row.biometric_event_id;
  end if;

  -- session protection for a new in (§6.6)
  if in_raw is not null and in_row.id is null then
    select decided into in_decided from public.biometric_event_state where raw_event_id = in_raw;
    select * into ss from public.session_state(p_emp);
    if ss.state <> 'off' and ss.work_date <> p_day and now() < public.biometric_day_close_at(p_emp, ss.work_date) then
      perform public.biometric_set_role(in_raw, 'flagged', p_flag => 'open_session_other_day'); in_raw := null; out_raw := null;
    elsif closed and out_raw is null and not in_decided
          and base_in > coalesce((select max(at) from public.attendance_events where employee_id = p_emp and superseded_by is null), '-infinity') then
      perform public.biometric_set_role(in_raw, 'flagged', p_flag => 'would_open_closed_day'); in_raw := null;
    end if;
  end if;

  -- write: in, then out (provisional before close), then everything else is extra
  if in_raw is not null then
    ev_id := public.biometric_write_slot(p_emp, p_day, 'in', 'in', in_raw, 'inferred_first_last');
    if in_row.id is not null and in_row.biometric_event_id <> in_raw then
      perform public.biometric_set_role(in_row.biometric_event_id, 'extra', p_flag => 'replaced_by_earlier_punch');
    end if;
    perform public.biometric_set_role(in_raw, 'projected', ev_id, 'in',
      p_flag => case when closed and out_raw is null and app_out.id is null then 'incomplete' end);
  end if;
  if out_raw is not null then
    if out_row.id is not null then
      perform public.biometric_set_role(out_raw, 'projected', out_row.id, 'out');
    elsif closed then
      ev_id := public.biometric_write_slot(p_emp, p_day, 'out', 'out', out_raw, 'inferred_first_last', 'biometric_finalise');
      perform public.biometric_set_role(out_raw, 'projected', ev_id, 'out');
    else
      perform public.biometric_set_role(out_raw, 'provisional_out');
    end if;
  end if;
  for i in 1 .. coalesce(cardinality(r_ids), 0) loop
    if r_ids[i] is distinct from in_raw and r_ids[i] is distinct from out_raw
       and (select status from public.biometric_event_state where raw_event_id = r_ids[i]) <> 'flagged' then
      perform public.biometric_set_role(r_ids[i], 'extra');
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'mode', 'first_last', 'closed', closed);
end $$;
```

### A5. Queue procedure, HR "process now", `day_events`
```sql
-- SECURITY INVOKER and no SET clause on purpose: PostgreSQL refuses COMMIT inside a SECURITY DEFINER procedure or
-- one with a SET clause. It runs as the job owner (postgres) only; every name is schema-qualified; it is revoked
-- from public/anon/authenticated, and everything it calls is SECURITY DEFINER with a pinned search_path.
create procedure public.biometric_run_projection(p_max int default 200)
language plpgsql as $$
declare k record;
begin
  update public.biometric_event_state s
     set work_date = (public.biometric_work_date_at(s.employee_id, r.punch_at, r.direction)).work_date
    from public.biometric_raw_events r
   where r.id = s.raw_event_id and s.work_date is null and s.employee_id is not null and s.status <> 'unmatched';
  commit;
  for k in
    select distinct s.employee_id, s.work_date, s.company_id from public.biometric_event_state s
      join public.companies co on co.id = s.company_id and co.active
      left join public.biometric_settings b on b.company_id = s.company_id
     where s.work_date is not null and s.projection_failures < 3
       and ((s.processed_at is null and s.status = 'stored')
         or (s.status = 'provisional_out' and now() >= public.biometric_day_close_at(s.employee_id, s.work_date))
         -- every 15 minutes: holds (roster/leave/correction fixed?) and recent closed days still missing a check-out
         or (extract(minute from now())::int % 15 = 0 and s.work_date >= current_date - 3
             and (s.status = 'held'
               or (s.status = 'projected' and s.projection_slot = 'in' and not ('incomplete' = any (s.flag_reasons))
                   and now() >= public.biometric_day_close_at(s.employee_id, s.work_date)
                   and not exists (select 1 from public.attendance_events e where e.employee_id = s.employee_id
                                     and e.work_date = s.work_date and e.kind = 'out' and e.superseded_by is null)))))
       and (coalesce(b.projection_enabled, false)
         or exists (select 1 from public.attendance_events e where e.employee_id = s.employee_id and e.work_date = s.work_date
                      and e.projection_slot is not null))
     order by s.work_date, s.employee_id
     limit p_max
  loop
    begin
      perform public.biometric_project_day(k.employee_id, k.work_date);
    exception
      when lock_not_available then null;                                  -- busy: retried next run, not a failure
      when others then
        update public.biometric_event_state set projection_failures = projection_failures + 1
         where employee_id = k.employee_id and work_date = k.work_date and status in ('stored', 'held', 'provisional_out');
        insert into public.biometric_event_errors (company_id, kind, detail)
          values (k.company_id, 'processing_failure', jsonb_build_object('employee_id', k.employee_id, 'work_date', k.work_date,
                  'sqlstate', sqlstate, 'message', left(sqlerrm, 300)));
    end;
    commit;
  end loop;
end $$;

create function public.biometric_project_now(p_emp uuid, p_day date) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.biometric_require(false);                                 -- HR or Admin of the caller's company
  if not public.hr_of(p_emp) then raise exception 'Not allowed' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_emp::text, 7));        -- lock first (re-entrant in project_day)
  update public.biometric_event_state s set work_date = (public.biometric_work_date_at(s.employee_id, r.punch_at, r.direction)).work_date
    from public.biometric_raw_events r where r.id = s.raw_event_id and s.employee_id = p_emp and s.work_date is null;
  return public.biometric_project_day(p_emp, p_day);
end $$;

create function public.day_events(p_emp uuid, p_day date)
returns table (at timestamptz, kind text, counted boolean, source text, label text, device text, role text,
               attendance_event_id bigint, raw_event_id bigint, replaced_by_correction bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_see(p_emp) then raise exception 'Not allowed' using errcode = '42501'; end if;
  return query
  select e.at, e.kind, e.superseded_by is null, e.source,
         case e.source when 'web' then 'App' when 'correction' then 'Correction' when 'import' then 'Imported'
                       else case e.direction_basis when 'device' then 'Biometric · device In/Out' else 'Biometric · inferred' end end,
         d.name, null::text, e.id, e.biometric_event_id, e.superseded_by
    from public.attendance_events e left join public.biometric_devices d on d.id = e.device_id
   where e.employee_id = p_emp and e.work_date = p_day
  union all
  select r.punch_at, null::text, false, case when r.import_batch_id is null then 'biometric' else 'import' end,
         case s.status when 'provisional_out' then 'Provisional Out' when 'extra' then 'Extra punch'
                       when 'possible_duplicate' then 'Possible duplicate' when 'reconciled' then 'Matched with app punch'
                       when 'after_correction' then 'After correction' when 'held' then 'Waiting for HR'
                       when 'flagged' then 'Needs review' when 'rejected' then 'Duplicate' when 'dismissed' then 'Dismissed'
                       else 'Waiting to be processed' end,
         d.name, s.status, s.reconciled_with, r.id, null::bigint
    from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
    left join public.biometric_devices d on d.id = r.device_id
   where s.employee_id = p_emp and s.work_date = p_day and s.status <> 'projected'
   order by 1, 3 desc;
end $$;
```

### A6. Review: accepted punches are picked up again
```sql
-- biometric_review_event (create or replace): the UPDATE gains
--   processed_at = case when next_status = 'stored' then null else processed_at end
```

### A7. Correction lock wrapper (as approved; identical to the proven proposal)
```sql
alter function public.decide_correction(bigint, boolean, text) rename to decide_correction_core;
create function public.decide_correction(p_id bigint, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare emp uuid;
begin
  select employee_id into emp from public.attendance_corrections where id = p_id;
  if emp is null or not public.in_my_company(emp) then raise exception 'Not allowed' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(emp::text, 7));
  return public.decide_correction_core(p_id, p_approve, p_note);
end $$;
revoke all on function public.decide_correction_core(bigint, boolean, text) from public, anon, authenticated;
revoke all on function public.decide_correction(bigint, boolean, text) from public, anon;
grant execute on function public.decide_correction(bigint, boolean, text) to authenticated;
```

### A8. Verification history outcome (the only line that changes in `verification_log`)
```sql
case when e.source = 'correction' then 'corrected'
     when e.source = 'biometric' then 'biometric'
     when e.source = 'import' then 'imported'
     when e.verified then 'verified' else 'not_required' end
```

### A9. Grants, owner scripts, schedule
```sql
revoke all on function public.biometric_work_date_at(uuid, timestamptz, text), public.biometric_day_close_at(uuid, date),
  public.biometric_set_role(bigint, text, bigint, text, bigint, text, text),
  public.biometric_write_slot(uuid, date, text, text, bigint, text, text),
  public.biometric_project_day(uuid, date), public.attendance_external_guard() from public, anon, authenticated;
revoke all on procedure public.biometric_run_projection(int) from public, anon, authenticated;
revoke all on function public.biometric_project_now(uuid, date), public.day_events(uuid, date) from public, anon;
grant execute on function public.biometric_project_now(uuid, date), public.day_events(uuid, date) to authenticated;
-- NOT in 0012 (hosted, after approval of Q1):
--   select cron.schedule('attendos-biometric-projection', '* * * * *', 'call public.biometric_run_projection(200)');
```
- `deploy/delete_company.sql`: delete `biometric_event_state` → `attendance_coords` → `attendance_events` → the
  other biometric tables (raw events after attendance events).
- `deploy/verify_hosted.sql`: new checks — the new functions are not executable by anon/authenticated (except
  `day_events`, `biometric_project_now` for authenticated), `decide_correction_core` executable by nobody,
  both new triggers present, projection off for every company until enabled.
- `tests/run.sh`: add `biometric_projection_test.sql` after the gateway suite.
