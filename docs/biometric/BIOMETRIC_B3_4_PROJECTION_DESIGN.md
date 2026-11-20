# Biometric B3.4 — attendance projection design (migration 0012), revision 5

Status: **revision 5, design for final approval — 20 Nov 2026** (guard and budget corrections applied, §0.3;
revision 4 in §0.2, revision 3 in §0.1, revision 2 in §0). Design review only — not an implementation approval. Nothing in
this document is implemented. Migration
`0012_biometric_projection.sql` has **not** been written; no existing attendance function has been altered; no SQL
was run against any hosted project; no extension installed; no hardware connected; no merge, no deployment.
Baseline: branch `feature/biometric-b1` @ `b712b5d` (revision 4 of this design) (0010 and 0011 approved for local development). Every statement
about current behaviour below was checked by reading migrations 0001–0011 (line references are to those files).

Owner decisions applied (B3.3 authorisation): no voiding column · device time trusted only after validation ·
future tolerance 120 s · 31-day backfill · 5-minute drift flag · auto-projection only up to 2 days old · projection
off by default per company · device codes exact · device mapping beats company mapping · no templates or images ·
correction lock wrapper in B3.4 · Biometric/Imported display in B3.4 · anonymous access only for the two gateway
functions. Owner decisions Q1–Q10 from the B3.4 review: §14.

## 0. What changed in revision 2 (owner review, 20 Nov 2026)
| Review item | Change | Where |
|---|---|---|
| 1. HR acceptance must not bypass session safety | New status **`correction_needed`**. Session-safety and sequence problems are never projected, whatever HR accepted; the punch reaches the register only through an approved attendance correction (HR may dismiss it). `decided = true` bypasses only the soft flags. Regression tests prove an accepted historical punch cannot block a later web check-in. | §6.2, §6.6, A4, A6, §12.2 |
| 2. Source-value preflight | First statement of 0012 lists unexpected `source` values and stops the migration without changing anything; the same query becomes a read-only hosted pre-check. | §4, A0, §9 |
| 3. Provisional duration UI | Live time on a day with a pending biometric check-out is shown as **Provisional**, with the pending check-out time and when it becomes final; never as worked hours or overtime. New read function `biometric_day_pending`. | §11.2, A5 |
| 4. Device-direction transitions | Rules made explicit (repeats, double press across devices, out of order, mode switch) and a dedicated test list. | §6.5, §12.3 |
| 5. Owner decisions Q1–Q10 | Applied as given: pg_cron later (separate approval); per-punch HR acceptance; finish started days when disabled; forgotten check-out unchanged; no HR-created corrections; office mode + the device's registered office; provisional minutes separate; shift-gap warning for Admin; **Source column in CSV exports**; imports approved by HR first. | §14, §11.3, A5 |

---

## 0.1 What changed in revision 3 (final corrections, 20 Nov 2026)
| Correction | Change | Where |
|---|---|---|
| Held-punch retry window | The `current_date - 3` limit on held rechecks is removed. Held punches of **any age** are re-evaluated on a backoff schedule (15 min → 1 h → 6 h) in a **separate, bounded budget** (50 employee-days per run, longest-waiting first), so they can neither get stuck nor starve current work. New columns `held_since`, `next_check_at`, `late_release_at`. | §6.1, §6.8, A3, A4, A5 |
| Release rules | The hold condition is re-evaluated from scratch before any release. Fixed within the 2-day window → the ordinary gate. Fixed after the window → `flagged · late_backfill` and **a new individual HR acceptance is required** — an acceptance given before the release does not count. Punch time and work date never change. | §6.2, §6.8, A4, A6 |
| Company-local dates | The remaining date bound (recent days missing a check-out) uses `local_today(company)`, not the database `current_date`. The 2-day window is a duration (48 h before now), so it does not depend on any time zone. | A5, §6.8 |
| Null-safe authentication gate | `source_auth IS DISTINCT FROM 'authenticated'`; all soft checks use `decided IS NOT TRUE`, `coalesce(cardinality(...), 0)` and `ambiguous IS NOT FALSE`, so a null or unexpected value can only lead to review, never past it. | A4, §6.2 |
| Final checks | Six queue properties re-verified against the SQL. | §15 |
| Tests | Held-punch tests H1–H8 and authentication tests A1–A4 added. | §12.2 |

## 0.2 What changed in revision 4 (final SQL review, 20 Nov 2026)
| Correction | Change | Where |
|---|---|---|
| `next_check_at` enforced inside `biometric_project_day` | The day's row lock, the gate and every write read only `stored` punches and held punches with `next_check_at <= now()`. A held punch that is not due is not locked, read or written — its status, reason, `held_since`, `next_check_at` and version stay exactly as they were, even when another punch of the same day triggers the day. The per-day bulk backoff update is gone; a due held punch whose hold still applies gets its next time individually. | §6.8, A4 |
| Bounded work within an employee-day | Each call of `biometric_project_day` makes at most `p_limit` writes (default 200). The gate stops before the limit and leaves the rest untouched (still `stored` or still due). Roles are decided over the whole day in time order, then written in a fixed order within the limit; if the limit is reached, the first unwritten punch keeps or gets `processed_at = null` (continuation mark) so the queue returns to the day. Nothing is skipped or marked processed without being processed. | §6.9, A4 |
| Run-level write budgets | The queue now counts writes: current work 2,000 per run, held re-checks 500 per run, at most 200 per employee-day per call, in addition to the day budgets (200 / 50). | §6.1, A5 |
| `stored` always means "awaiting processing" | `biometric_set_role` sets `processed_at = null` for `stored` and `now()` otherwise; new check `status <> 'stored' or processed_at is null`. This is what lets the queue find unfinished days reliably. | A3, A4 |
| Tests | Q1–Q8 added (the six requested plus two). | §12.2 |

## 0.3 What changed in revision 5 (20 Nov 2026)
| Correction | Change | Sections changed |
|---|---|---|
| Guard validates the whole attribution tuple | `attendance_external_guard` now re-validates on INSERT and on **any** change of `at`, `biometric_event_id`, `device_id`, `import_batch_id` or `location_id`, against the immutable raw punch and its state: company (raw, state and employee), employee, work date, punch time, device, import batch, the device's **registered office** (`location_id` must equal it; imports must have none until 0013), and `dev:<raw id>` slot naming. Stable ids, supersession protection and the projection-only write rule are unchanged. | A2; §3 req. 12; §12.2 tests T1–T9 |
| Strict write budgets | No lower clamp on `p_limit`: a call never writes more than it is given. Every operation of cost *k* runs only if `n + k ≤ limit − 1`, keeping one write for a continuation mark; the slot step (≤ 5 writes) runs whole or not at all; a call given fewer than 6 writes defers the day and writes nothing; the queue stops a step when fewer than 6 writes remain and subtracts the writes actually made. | A4 (`biometric_project_day`), A5 (queue); §6.1, §6.9; §12.2 tests B1–B10 |
| One write per failure; late release in one write | A failed call is rolled back and costs exactly one write (its error record); failures are counted from unresolved `processing_failure` records (`biometric_day_failures`), replacing the per-punch counter; `biometric_retry_day` resolves them. The late-release mark and the `flagged` change are one `biometric_set_role` write. | A3, A4 (`biometric_set_role`), A5 (`biometric_project_one`, `biometric_retry_day`), A9; §4, §6.1, §9 F3 |
| Consistency pass | Every Appendix A function re-read against the others (§16). Two fixes found: the "pending" ordering key for two `correction_needed` decisions now reads the punch's real status; the mixed-mode stop no longer writes a needless mark on a `stored` punch. | A4; §16 |

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
- **Session safety is absolute.** A punch that would leave someone checked in on a finished day, clash with an open
  session, or break the in/out sequence is `correction_needed`: HR acceptance cannot push it into the register; only
  an approved attendance correction can (§6.6).
- **Provisional is labelled.** While a biometric check-out is pending, screens show the running time as
  *Provisional* and say when it becomes final; exports mark the day "pending check-out" in the new Source column.
- **Migration safety.** 0012 first checks the existing `source` values and stops, changing nothing, if any is
  unexpected.

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
| 1 | Web check-in/out keeps working unchanged | No change to `punch`, `punch_core`, `session_state`, `work_date_for_checkin`, geofence or GPS code. Projection only inserts rows the engine already understands, under the same lock, and never inserts a row that would open a finished day, clash with an open session or break the sequence — not even after HR acceptance (`correction_needed`, §6.6). The existing regression suites must pass unchanged. | §6.6, §12.1–12.2 |
| 2 | Same employee advisory lock as punch | `biometric_project_day` takes `pg_advisory_xact_lock(hashtextextended(emp::text, 7))` before reading anything. | A4, §8 |
| 3 | Correction approval uses the approved wrapper | `decide_correction` → `decide_correction_core` (revoked from everyone); new `decide_correction` checks company, takes lock 7, calls the core. Same SQL as `tests/concurrency/proposed_correction_lock.sql`, already proven by `lock_proof.sh`. | A7 |
| 4 | Stable IDs and correction references | One row per slot, unique `(employee_id, work_date, projection_slot)`; ids never change; projection never deletes, never clears `superseded_by`, never touches `web`/`correction` rows or superseded rows. A guard trigger enforces this. | A1, A2, §6.5 |
| 5 | Inferred vs explicit direction distinguishable | `direction_basis = 'inferred_first_last'` (slots `in`/`out`) vs `'device'` (slot `dev:<raw id>`); a check ties basis to slot shape. `day_events` labels "Biometric · inferred" / "Biometric · device In/Out". | A1, A5 |
| 6 | Provisional checkout never finalises | It is the role `provisional_out` on the raw punch, never a row. The day stays open in `day_for_core`, so worked hours, overtime, early leaving and status are not final. Only at day close does projection insert the `out` row. | §6.4 |
| 7 | Duplicate, unmatched, flagged, unauthenticated events stay out | Only punches passing the gate (§6.2) can fill a slot: attributed, authenticated (or individually accepted by HR), no time or attribution flags, not a possible duplicate, ≤ 2 days old, not in the future, from a device with a registered office. Sequence and session problems become `correction_needed`. Everything else keeps its review status. | §6.2, §6.6 |
| 8 | Older than the auto window → HR review | A not-yet-decided punch older than `auto_project_max_age_days` (2) when first processed becomes `flagged` + `late_backfill`. Enabling projection on a company with a backlog sends the backlog to review, not into the register. | §6.2 |
| 9 | Disabled by default | Unchanged default `projection_enabled = false`; the queue skips such companies. | §6.1 |
| 10 | Corrections, shifts, overnight, leave, holidays, weekly offs | Pending correction → `held`; approved correction or superseded slot → day locked, new punches `after_correction`; off day / holiday / full-day leave / before joining / after exit → `held`; overnight work date mirrors the app (§7). | §6.3, §7 |
| 11 | Displays say Biometric or Imported, never GPS-verified | Check constraint: biometric/import rows have `verified = false`, no distance, no accuracy. `verification_log` outcome `biometric` / `imported`; Timeline and Verification badges show "Biometric device" / "Imported"; CSV Source column "Web / Biometric / Imported / Correction". | A1, A8, §11 |
| 12 | Every projected event traceable | `biometric_event_id` → raw (FK, `on delete restrict`, unique); device id; state back-link `projected_event_id`; the guard re-validates company, person, work day, time, device, import batch and the device's registered office on insert and on any change of the attribution tuple; every insert/move/role change is in `audit_log` with before/after. | A1, A2, A3, §6.7 |

---

## 4. Data model changes (all additive)

**`attendance_events`** — new nullable columns `device_id`, `biometric_event_id`, `import_batch_id`,
`projection_slot`, `direction_basis`; check `source in ('web','correction','biometric','import')`; shape check (web
and correction rows must have all five null — true for every existing row; biometric/import rows must have them set,
`verified = false`, `distance_m`/`accuracy_m`/`correction_id` null, kind `in`/`out`); two partial unique indexes
(slot, raw punch); `company_refs` trigger re-created with the two new uuid references; new guard trigger
`attendance_external_guard` (A2).

**Preflight (first statement):** the distinct existing `attendance_events.source` values are read; anything other
than `web` or `correction` stops the migration before any change and reports the values and row counts (A0). History is
never rewritten or deleted to satisfy the new check.

**`biometric_event_state`** — new status `held` with `hold_reason` (resolved automatically when the cause goes away:
roster, leave, correction decision, device office registered); new status `correction_needed` (session-safety and
sequence problems — only an approved correction or HR dismissal ends it); `held_since`, `next_check_at`,
`late_release_at`; `work_date` frozen once set (state guard). Projection failures are counted from
`biometric_event_errors` (one record per failed call), not from a per-punch counter.

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
| `biometric_day_pending(emp, day)` | new, stable | anyone who `can_see(emp)` | Pending biometric check-out: provisional time of the last punch and when the day becomes final (provisional display, §11.2). |
| `attendance_day_sources(from, to, dept, emp)` | new, stable | same scope as `report_days` (company + `can_see`) | Per person-day: sources of the counted events and pending check-out, for the CSV Source column and register markers. `report_days` unchanged. |
| `biometric_shift_gap_warnings(days)` | new, stable | Admin | Q8: people whose next shift starts before the previous day closes for projection. Warning only; changes nothing. |
| `biometric_retry_day(emp, day)` | new | Admin | After a day failed three times and the cause is fixed: reset the counter (audited) and project under lock 7. |
| `biometric_review_event` | changed (biometric) | unchanged | Resets `processed_at` when a punch becomes `stored`; `correction_needed` can only be dismissed, and points HR to the correction workflow. |
| `biometric_state_guard` | changed (biometric) | trigger | Freezes `work_date`; `held` needs a reason. |

Unchanged and verified to need no change: `punch`, `punch_core`, `session_state`, `day_for`, `day_for_core`,
`my_today`, `my_today_core`, `work_date_for_checkin`, `request_correction`, `cancel_correction`,
`attendance_history`, `report_days`, `attendance_register`, `report_people`, `report_trend`,
`dashboard_summary(_core)`, `biometric_ingest`, `biometric_heartbeat`, all mapping functions.

---

## 6. Projection rules

### 6.1 Which employee-days are processed
`biometric_run_projection()` every minute, in three steps, each employee-day committed on its own:

| Step | Picks | Order | Budgets per run |
|---|---|---|---|
| 0 | attributed punches without a work date | — | one statement |
| 1 current work | days with a punch awaiting processing (`stored`, or a continuation mark `processed_at is null`); `provisional_out` days whose close time has passed; closed days within the last 3 **company-local** days that still have only a check-in | newest work day first | 200 employee-days **and** 2,000 writes |
| 2 held re-checks | days with a held punch whose `next_check_at` has passed, any age | longest-waiting first | 50 employee-days **and** 500 writes |

Every call is limited to `least(200, remaining step budget)` writes (§6.9); the budgets are never exceeded. Both steps only consider active companies where
projection is enabled, or days that already have a projected slot (Q3). Each employee-day runs through
`biometric_project_one` → `biometric_project_day` and is committed on its own. On error the day's punches that were
due get one `processing_failure` record (the call itself is rolled back); after 3 such records the day is skipped until an
Admin fixes the cause and calls `biometric_retry_day` (which resolves those records). A lock wait over 5 s is not a
failure — retried next run. A step stops when fewer than 6 writes of its run budget remain; the days it did not
reach stay due for the next run.

### 6.2 The gate — what may count (requirements 7 and 8)
Evaluated for every `stored` or `held` punch of the day each time the day is projected. Every comparison is null-safe
(`IS DISTINCT FROM`, `IS NOT TRUE`, `coalesce`): a missing or unexpected value leads to review, never past it.
Three kinds of outcome:

**Soft flags — HR may accept** (`flagged`; `accept_time` / `not_duplicate` sets `decided = true`, then the punch is
projected like any other, still subject to every rule below):

| Check | Result if it fails |
|---|---|
| `source_auth IS NOT DISTINCT FROM 'authenticated'` (the value is derived by the gateway from the Admin-set device authentication; the column is `NOT NULL` with a fixed list, and the gate is null-safe anyway) | `flagged` · `unauthenticated_source` (Q2: one acceptance per punch, no bulk) |
| No raw time flags or state flags (clock drift, DST, offset mismatch, future-within-tolerance, source claim rejected…) | `flagged` (reasons kept) |
| Not older than `auto_project_max_age_days` (2) | `flagged` · `late_backfill` |
| A hold ended after the window (`late_release_at` set) and no acceptance has been given **since** | `flagged` · `late_backfill` — earlier acceptances do not count (§6.8) |
| Work date not ambiguous between an overnight shift and the next shift (§7) | `flagged` · `ambiguous_work_date` (acceptance = use the rule's date) |

**Holds — released automatically when the cause is fixed** (`held`; not reviewable; never bypassed by acceptance):
punch time in the future (left `stored`, retried) · import batch (`import_not_enabled`, Q10) · device has no
registered office (`device_without_office`, Q6) · the day-level holds of §6.3.

**Session safety and sequence — never bypassed** (`correction_needed`, §6.6): would open a finished day · open
session on another unfinished day · impossible device transition · out of order · after day close · machine punch
before an app check-in · mixed direction modes · device punch without direction. `decided = true` does **not**
skip any of these. Approved correction for the day → `after_correction`.

`possible_duplicate`, `unmatched`, `flagged`, `correction_needed`, `rejected` and `dismissed` punches are never read
as candidates. A punch attached later by a new mapping is re-gated here (finding E11).

### 6.3 Day-level holds (requirement 10)
Same rules the app applies, decided again on every run, so fixing the cause releases the punch automatically:
`employee_inactive` (deactivated, and the day is not before an exit date) · `after_exit` · `before_joining` ·
`non_working_day` (roster off or holiday — `plan_for`) · `on_leave` (approved full-day leave — `leave_on`;
half-day leave projects, as the app allows check-in) · `correction_pending`. Per punch: `device_without_office`
(Q6 — biometric rows always carry the device's registered office and `work_mode = 'office'`). Release rules, retry schedule and the age
rule are in §6.8. Holds never touch rows already projected for that day (no voiding); they apply to new punches.

### 6.4 First-in / last-out (default device mode)
Inputs: gated punches of the day (time order) + the day's live app/correction events + the two slot rows.
1. **Double press:** a punch within `double_press_s` (60 s) of the previous kept punch — any device — is `extra`.
2. **Reconcile:** a punch within `reconcile_min` (5 min) of the earliest live app/correction `in` or latest
   `out` is `reconciled` (`reconciled_with` = that event). The app event stays the counted one.
3. **In slot:** if the day has a live app/correction `in`, there is no biometric `in`; unreconciled punches before it
   are `correction_needed · before_app_checkin` (architecture rule 7 — never guessed). Otherwise the earliest remaining punch
   fills slot `in`. If a slot row exists and an earlier punch arrives **before day close**, the row is moved in place
   (`at`, `biometric_event_id`, device, location — same id) and the previous punch becomes `extra`; **after day close**
   the earlier punch is `correction_needed · after_day_close` and the row is not moved.
4. **Out candidate:** the latest remaining punch at least `min_session_min` (30) after the in, and only if the day has
   no live app/correction `out`. Punches after an app check-out are `extra`.
5. **Before day close** the candidate is `provisional_out` — **no row**. The person stays checked in (`working`) in
   `session_state`, `day_for` keeps the day open, nothing is final. The app check-out still works and wins (rule 2/4).
   Screens show the running time as **Provisional · pending biometric check-out** (§11.2), never as worked hours.
6. **At day close** (`now() >= biometric_day_close_at`, or any live event on a later work date) projection inserts the
   `out` row from the candidate (`biometric_finalise` in the audit log). From then on it is a normal counted check-out.
   A finalised `out` is never moved; a later punch is `correction_needed · after_day_close`.
7. **No candidate at day close** (single punch, or all within 30 min): no check-out is invented. The day becomes
   "missing check-out" under the existing rule; the `in` punch carries flag `incomplete` for HR.
8. Everything else is `extra` (kept, shown, never counted). Breaks are never inferred.

### 6.5 Device-direction mode
Each gated punch carries the device's `in`/`out`. In time order, per punch:
1. **No direction** → `correction_needed · no_direction`.
2. **Double press / two devices:** a biometric row of the same direction within `double_press_s` (60 s), from any
   device → `extra · double_press`. Identical re-sends never reach here (the gateway stores them once);
   same-device presses within 60 s are already `possible_duplicate` from ingest and are not candidates.
3. **Reconcile:** an app/correction event of the same kind within 5 min → `reconciled`.
4. **Out of order:** not later than every live event of that day → `correction_needed · out_of_order` (a delayed
   punch is never slotted between counted events).
5. **Short repeat:** same direction as the day's last counted event within `reconcile_min` → `extra · repeat_in` /
   `repeat_out` (a person pressing IN twice).
6. **Impossible transition** → `correction_needed · impossible_transition`: IN while checked in (also on an app
   break) or while an unfinished session is open on another day; OUT with no earlier IN; OUT after an app check-out;
   OUT while on an app break.
7. **Would open a finished day** (IN, day closed, would become the newest event) → `correction_needed`.
8. Otherwise the punch becomes slot `dev:<raw id>` at once (explicit direction — no provisional stage).
A day mixing devices of the two modes, or having slots of the other basis (mode switched mid-day) →
`correction_needed · mixed_direction_modes` for the day's unprojected punches; existing rows stay as counted.

### 6.6 Session safety — never overridden (requirement 1, review item 1)
`session_state` reads the person's latest live event across all days (E2). A biometric row is therefore only written
if it cannot change what the app believes about the person's *current* session. The checks, made under lock 7 on
every run, apply **whether or not HR accepted the punch**:

| Condition | Why it matters | Outcome |
|---|---|---|
| **Would open a finished day:** the day is closed, no check-out will be created, and the new `in` would become the person's newest live event | They would be "checked in" on a past day; the next app check-in would say "already checked in" | `correction_needed · would_open_closed_day` |
| **Open session on another unfinished day** (e.g. an overnight shift still running) | Two sessions at once; the app's check-out would close the wrong one | `correction_needed · open_session_other_day` |
| Out of order / impossible transition / after day close / before an app check-in / mixed modes (§6.4–6.5) | The counted sequence would no longer be what happened | `correction_needed · <reason>` |
| Future punch (`at > now()`) | Would become "latest" ahead of real time | waits; projected once in the past |

What happens to a `correction_needed` punch:
- It is **never projected** — not by the queue, not by `biometric_project_now`, not after `accept_time` (the review
  function refuses acceptance and tells HR to ask the employee for a correction for that date; Q5 — no HR-created
  corrections in this phase).
- It stays visible: `day_events` shows "Needs a correction request"; the review queue lists it with the reason.
- When a correction for that day is approved, it becomes `after_correction` (informational). HR may also dismiss it
  with a reason. Either way the raw punch is kept.

A stale session on a day that has already **closed** does not block a new current `in` (the new `in` simply becomes
the current session — otherwise a biometric user who forgot to punch out would be stuck). Q4: the existing behaviour
for a person whose day ends with a counted `in` and no `out` (app or biometric) is unchanged.

Regression evidence required (§12.2 group S): an accepted historical punch never blocks a later web check-in.

### 6.7 Traceability and audit (requirement 12)
Every insert (`biometric_project`), move (`biometric_slot_moved`), finalisation (`biometric_finalise`) and role change
(`biometric_role_<status>`) writes one `audit_log` row (company, before/after JSON, raw id). `actor` is null for the
scheduled job and the HR member for `biometric_project_now`. Re-running with the same inputs writes nothing.

---

### 6.8 Held punches — retry and age behaviour
**When a held punch is looked at.** Entering `held` sets `held_since` (kept while the punch stays held, even if the
reason changes) and `next_check_at`. The queue's held step picks employee-days whose `next_check_at` has passed —
no age limit — longest-waiting first, at most 50 per run. After each look a still-held punch gets its next time from
the backoff: **15 minutes** while held for less than a day, **1 hour** up to 7 days, **6 hours** after that. So every
held punch is re-evaluated at least every 6 hours for as long as it is held; old holds cost little; HR "process
now" (`biometric_project_now`) re-evaluates a day immediately.

**Due is enforced where the work happens.** The queue chooses days by due held punches, but `biometric_project_day`
checks `next_check_at <= now()` again itself, under lock 7: its row lock, its gate and every write cover only `stored`
punches and **due** held punches. So when a new punch (or day close, or HR "process now") brings a day in, held
punches of that day that are not yet due are not read or changed: their status, hold reason, `held_since`,
`next_check_at` and version stay as they were. A due held punch whose hold still applies gets its own next time
(backoff); nothing else moves. Two runs reaching the same day one after the other: the second finds the punch no
longer due and leaves it alone.

**How a held punch is released** (under lock 7, `biometric_project_day`):
1. The hold is decided again from current data: import batch, device office, approved correction (→
   `after_correction`), employee active/exit/joining, roster (`plan_for`), full-day leave (`leave_on`), pending
   correction. If any hold applies — the same or a new one — the punch stays `held` (reason updated).
2. No hold applies and the punch time is **within** the automatic window (`punch_at ≥ now() − 2 days`): it goes
   through the ordinary gate (soft checks, then the day's sequence and session-safety rules). An earlier individual
   HR acceptance still covers the soft checks.
3. No hold applies and the punch is **older** than the window: `late_release_at = now()`, status `flagged ·
   late_backfill`. It is **never projected automatically**, even if HR had accepted it before it was held; it needs a
   new individual acceptance (A6). After that acceptance it is processed by the ordinary rules, and session safety
   still applies (§6.6).

**What never changes.** The raw punch time (immutable table) and the punch's work date (frozen by the state guard)
are the same before and after a hold. Only the processing state changes, and every role change is audited.

**Time zones.** The 2-day window is a duration measured from the server's `now()` (48 hours), the same measure the
ingest guard uses, so it is the same in every zone. Calendar bounds use the company's own date:
`local_today(company)`; `current_date` is not used.

**Projection disabled (Q3).** The held step skips employee-days of a disabled company unless the day already has a
projected slot. A punch whose cause is fixed while projection is off therefore stays `held`, untouched; when
projection is switched on again it is re-evaluated at its next check, and the age rule above applies then.

**Fairness.** Current work (step 1) and holds (step 2) have separate budgets, so any number of old holds cannot delay
today's punches, and current work cannot stop holds from being re-checked. Within step 2 the oldest `next_check_at`
goes first, and the backoff pushes long-standing holds back, so newer holds are not starved by old ones.

### 6.9 Bounded work inside one employee-day
A device fault or a long agent backlog could put thousands of punches on one employee-day. Reading them is cheap; the
cost is in writes (state updates, audit rows, slot rows). So each call of `biometric_project_day(emp, day, p_limit)`
counts its row writes and never exceeds `p_limit` (default 200, at most 1000, **never raised**):

0. **Budget rule** (revision 5). One *write* = one changed processing-state or attendance row (with the audit entry
   that accompanies it), or one error record. An operation of cost *k* — 1 for a role change or a held punch's next look, 2 for a
   device punch (slot + role), up to 5 for the first-in/last-out slot step (in row, its punch, a replaced punch, out
   row, its punch) — runs only if `n + k ≤ p_limit − 1`. The last write is reserved for a continuation mark, so a stop
   never exceeds the limit. The slot step is all-or-nothing. A call given **fewer than 6** writes (5 + the reserve)
   writes nothing and returns `deferred`; with 6 or more, the first operation always fits, so every call either
   finishes the day or writes at least one thing.

1. **Gate** — `stored` and due held punches, oldest first. If the limit is reached, the call returns
   `complete = false` **before** any role is decided. The punches it did not reach are untouched: still `stored`
   (always `processed_at = null`) or still due, so the queue returns to the day. No ungated punch is ever used for a
   slot, because roles are only decided after a gate pass that reached the end.
2. **Roles** — first-in/last-out roles are decided over the whole day in time order (in memory), so the result does
   not depend on how many calls it takes. They are then written: the slot rows together with their own punches' roles
   (at most 5 writes, so a slot and its back-link are never split), then the remaining role changes — existing roles
   first, new punches last, each in time order. If the limit is reached, the first unwritten punch keeps (if `stored`)
   or gets a **continuation mark** (`processed_at = null`), and the call returns `complete = false`. The next call
   decides the same roles again (deterministic), finds the already-written ones unchanged (no write, not counted) and
   continues. The mark is cleared by the normal role write.
3. **Device mode** decides and writes one punch at a time in time order; it stops at the limit the same way, so later
   punches are always decided after the earlier ones are counted.
4. **Locked days and mixed device modes** convert punches in raw-id order within the same limit and mark the next one.

Guarantees: every call makes progress (at least one write) until the day is complete; no punch is skipped or marked
processed without its role being written; chronological decisions, the employee lock, correction locks and
session-safety rules are unchanged; repeating a complete call writes nothing. The queue gives each call at most
`least(200, remaining run budget)` and subtracts the writes actually made, so the 2,000 / 500 run budgets are never
exceeded, one large day uses at most 200 writes per run, and days not reached because a budget ran low are picked up
first in the next run (their punches are still `stored`, due or marked).

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
"missing check-out". Q8: if the gap between two of a person's shifts is shorter than `day_close_after_min`, the
earlier day is closed by the next day's first punch instead. Admin is warned (`biometric_shift_gap_warnings`, shown on
the biometric settings screen and when the day-close period is changed); nothing is changed automatically.

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
| App check-in vs projection of the same morning | Serialised by 7. If projection commits first, the app sees "already checked in" (the machine check-in is counted, as it would be for a second app tap). If the app commits first, the machine punch reconciles (≤ 5 min) or is `correction_needed · before_app_checkin`. |
| App check-out vs provisional out | Serialised by 7. The app check-out is counted; the punch becomes `reconciled` or `extra` at the next run. |
| Correction approval vs projection | Serialised by 7 (wrapper). Approval first → day locked → punches `after_correction`. Projection first → the correction then supersedes the biometric row as it would an app row. |
| Correction request vs projection | No lock in `request_correction`. Either order leaves a consistent day: a request made just after a projection simply targets the projected row when approved. |
| HR review vs projection | Projection waits for the state row; review never needs 7 → no cycle. A newly accepted punch is projected at the next run. |
| HR acceptance vs a web check-in (session safety) | Acceptance only changes the punch's status; projection then runs under 7 and re-checks session safety against the live events, including a web check-in committed a moment earlier. An accepted punch that would open a finished day is `correction_needed`; the web check-in stands. |
| Two queue runs overlapping (cron overlap) | Both wait on 7 per day; the second sees no changes (idempotent) and writes nothing. |
| Mapping attach vs projection | Disjoint rows; attached punches are re-gated at the next run. |
| Ingest of a new punch during projection | The new punch commits as `stored`; the next run reprojects the day. |

---

## 9. Failure and recovery behaviour

| # | Scenario | Detected by | Effect on the register | Automatic recovery | Manual recovery |
|---|---|---|---|---|---|
| F1 | Unexpected `attendance_events.source` value at migration | Preflight A0 | None — migration stops before any change | — | Owner reviews the reported values; history is not edited to pass. Fix the cause, then a new decision. |
| F2 | 0012 fails part-way for any other reason | PostgreSQL error | None — one transaction | — | Fix, re-run. |
| F3 | One employee-day errors during projection | Sub-block in the queue | That day unchanged (full rollback of the day, no half slots); one error record written | Retried next minute until 3 unresolved error records exist | Admin sees the `processing_failure` record, fixes the cause, calls `biometric_retry_day` (audited). |
| F4 | Lock wait > 5 s (busy person) | `lock_timeout` | None | Retried next run; not counted as a failure | — |
| F5 | pg_cron not installed / stopped (Q1) | Punches stay `stored`; settings screen shows "last projection run" | New punches not counted; open days turn "missing check-out" at shift end + 4 h | When cron runs again, days are finalised from their qualifying punches (the day was already accepted, so finalisation is not age-gated) | Until hosted pg_cron is approved, keep projection **off** on hosted. HR "process now" covers single days but not day close. |
| F6 | Agent offline for days | `late_backfill` flags | Late days show absent until reviewed | ≤ 2 days old: projected normally (out-of-order handled) | HR accepts or dismisses each punch (Q2: per punch). |
| F7 | Session-safety or sequence problem | Projection (§6.6) | Punch not counted | — | Employee requests an attendance correction; HR approves (punch becomes `after_correction`) or dismisses it. HR acceptance cannot force it in. |
| F8 | Held punch (off day, leave, pending correction, no device office, import) | Projection | Not counted; person shows absent / on leave / off | Re-evaluated on the backoff schedule at any age (≤ 15 min / 1 h / 6 h); released into the ordinary gate if within 2 days | HR fixes the cause (or uses "process now"); a punch released after 2 days becomes `flagged · late_backfill` and needs a new individual acceptance. |
| F9 | Projection behaves wrongly after go-live | Owner / HR | Wrong rows possible | — | Admin turns `projection_enabled` off: no new days start; started days finish (Q3). Counted rows are fixed through corrections (no voiding). A later migration can remove the functions and the wrapper; the additive columns stay. |
| F10 | Correction approved for a day with projected rows | Wrapper + lock 7 | Correction row counts; biometric row superseded | Later punches of the day `after_correction`; slot never refilled | — |
| F11 | Device switched between first_last and device mode mid-day | Projection | Rows already counted stay | New punches of that day `correction_needed · mixed_direction_modes` | Correction if the day is wrong. |
| F12 | Device clock wrong | Drift flag at ingest | Not auto-counted | — | HR accepts (if the time is right) or dismisses. Rows already counted from a wrong clock are fixed with corrections. |
| F13 | Wrong employee mapping discovered after projection | Admin | Rows on the wrong person stay (attribution frozen) | — | Mapping fixed for the future; the affected person requests corrections; HR-created corrections are a later phase (Q5). |
| F14 | Two queue runs overlap | Lock 7 per day | None | Second run writes nothing (idempotent) | — |
| F15 | Database restored from backup | — | Rows as of the backup | Queue re-processes punches not yet marked processed; idempotent | Agent re-sends from its queue; the gateway de-duplicates. |
| F16 | UI deployed before/after 0012 | — | Unknown `source` values | UI shows unknown sources as "Other" rather than failing | Deploy UI and 0012 together. |
| F17 | Company deleted | Owner script | — | — | Script reordered: state → coords → attendance events → raw events and other biometric tables (A9). |
| F18 | Shift gap shorter than day-close period | `biometric_shift_gap_warnings` | Earlier day closes at the next day's first punch | — | Admin adjusts the setting or rosters if wanted (never automatic, Q8). |

## 10. Security and permission matrix

| Call / data | anon | Employee | Manager | HR | Admin | System (pg_cron / owner) |
|---|---|---|---|---|---|---|
| `biometric_ingest`, `biometric_heartbeat` | agent key only (unchanged) | — | — | — | — | — |
| `punch` (web) | — | own | own | own | own | — |
| `biometric_project_day`, `biometric_run_projection`, `biometric_project_one`, `biometric_set_role`, `biometric_write_slot`, `biometric_work_date_at`, `biometric_day_close_at`, `biometric_hold_next_check` | no | no | no | no | no | yes (revoked from public, anon, authenticated) |
| Re-accept a punch released after the window | no | no | no | own company, one punch at a time | yes | — |
| `biometric_project_now` | no | no | no | people in HR scope (`hr_of`) | yes | — |
| `biometric_retry_day` | no | no | no | no | own company | — |
| `biometric_review_event` (accept / dismiss…) | no | no | no | own company (unchanged) | yes | — |
| Accept a `correction_needed` punch | no | no | no | **refused** | **refused** | — |
| `day_events`, `biometric_day_pending` | no | own days | team (`can_see`) | scope | company | — |
| `attendance_day_sources` (Source column) | no | own rows (same scope as `report_days`) | team | scope | company | — |
| CSV export buttons (UI) | — | — | as today (`exportReports`) | as today | as today | — |
| `biometric_shift_gap_warnings` | no | no | no | no | yes | — |
| Raw payloads | no | no | no | no | `biometric_raw_payload` (audited, unchanged) | — |
| `decide_correction` (wrapper) | no | not own (unchanged) | team (unchanged) | scope (unchanged) | yes | — |
| `decide_correction_core` | no | no | no | no | no | definer call only |
| `verification_log` | no | no | no | yes (unchanged) | yes | — |
| Turn projection on/off | no | no | no | no | yes (unchanged, Admin only) | — |
| Read `attendance_events` incl. new columns | no | own (RLS unchanged) | team | scope | company | — |
| Write `attendance_events` | no | no grant (unchanged) | no | no | no | only definer functions; biometric rows only while `attendos.projection = on` (guard) |
| Install pg_cron, schedule the job | — | — | — | — | — | **not in 0012**; separate owner approval (Q1) |

Every new function is `SECURITY DEFINER` with `search_path = public`, except the queue procedure, which is
`SECURITY INVOKER` because PostgreSQL forbids `COMMIT` in a definer procedure; it is revoked from every client role and
runs only as the job owner. No new anonymous entry point; no service-role key; cross-company references refused by
`company_refs` (device, batch) and the guard (raw punch). Employees see role labels but not flag details, device
addresses or payloads. The `attendos.projection` setting is defence in depth — no client role can write the table.

## 11. Reports, exports and displays

### 11.1 Calculations
No calculation changes. `report_days` → `day_for` counts biometric rows like app rows. Overtime and early leaving are
computed by the engine **only for closed days** (E3), so a pending biometric check-out can never produce overtime or
early leaving. Held, flagged and `correction_needed` punches are not counted: the person shows absent / on leave /
off until resolved. Corrections and `pending_correction` behave exactly as now.

### 11.2 Provisional duration (review item 3, Q7)
A day is **pending** when it has a `provisional_out` punch (`biometric_day_pending`). Three things are shown apart:

| Shown as | When | Source |
|---|---|---|
| **Provisional time** — e.g. "Provisional 8 h 21 m · pending biometric check-out (last punch 18:02) · final at 20:00" | Day open with a pending biometric check-out | `day_for` live minutes + `biometric_day_pending` |
| **Worked (final)** — hours, late, early leaving, overtime | Day closed (biometric out written, app check-out, or correction) | `day_for` |
| **Pending biometric check-out** chip, with a one-line reason: "Your last punch becomes your check-out when the day closes at 20:00, unless you punch again or check out in the app." | Same as provisional | `biometric_day_pending` |

Rules: provisional minutes are never labelled "Worked", never summed into a total as final, and the overtime/early
badges are hidden while pending. My Attendance (Today card), the register row and drawer, and the person's history
use this. Report screens whose range includes a pending day show a note: "N days still open — their time is
provisional until the day closes." App-only open days keep today's display (no change).

### 11.3 CSV exports — Source column (Q9)
Per-day exports gain one column, **Source**, placed after Check-out; every existing column and calculation is kept:
Register CSV (`Register.tsx` `csvCols`) and the Late / Overtime detail CSVs (`ReportScreens.tsx`). Values from
`attendance_day_sources` (sources of the counted in/out events of that day):

| Counted events of the day | Source cell |
|---|---|
| app only | Web |
| biometric only | Biometric |
| import only | Imported |
| correction only | Correction |
| several | joined in this order with " + ", e.g. "Biometric + Correction" |
| no counted events | empty |
| pending biometric check-out | the above + " (pending check-out)" — the day's hours are provisional |

Aggregate exports (people summary, departments, daily trend, leave) have no per-day source and are unchanged.
Exports never contain raw, provisional, extra or duplicate punches. The CSV formula-safety in `src/lib/csv.ts` applies
to the new column too.

### 11.4 Other displays
- `verification_log` outcome `biometric` / `imported` (location column = the device's office); app rows unchanged.
- `src/lib/attendance.ts`: `source?: "web" | "correction" | "biometric" | "import"`.
- Timeline (`AttendanceCard.tsx:221`): source first — "· biometric device" / "· imported" — so a biometric row never
  reads "location verified" or "no location".
- Verification badges (`LocationsPanel.tsx`): "Biometric" and "Imported"; an unknown source shows as "Other" (never as verified).
- Review queue: `correction_needed` items say "Ask the employee to request a correction for <date>"; no Accept button.
- Biometric settings: shift-gap warnings (Admin), "projection last ran at …".
- `day_events` labels: Provisional Out · Extra punch · Possible duplicate · Matched with app punch · After correction ·
  Waiting for HR · Needs review · Needs a correction request · Duplicate · Dismissed.

### 11.5 Performance
`day_for` does the same work; the two partial indexes do not cover app rows. `attendance_day_sources` reads events by
`(employee_id, work_date)` (existing index). The job runs one small transaction per employee-day.

## 12. Test plan (to run when 0012 is implemented)

### 12.1 Must stay green, unchanged
Full database suite (633 today), `lock_proof.sh` (21), `gateway_proof.sh` (6), gateway HTTP (18), company deletion
(4), app regression (29), app checks (53), clean migration 0001–0012. Existing attendance, refinement, tenancy,
verification, leave/report and security-matrix tests are **not edited**.

### 12.2 New `biometric_projection_test.sql` (database)
**P — preflight and schema**

1. Preflight passes on `web`/`correction`; a throwaway copy with a row `source = 'kiosk'` stops 0012 with the value and
   count in the message, and the database is byte-for-byte unchanged (no new column, no constraint, the row intact).
2. Source check, shape check, slot uniqueness, one row per raw punch; web row with biometric columns refused.
3. Guard: direct biometric insert without projection refused; person/day/slot/kind change refused; moving a superseded
   slot refused; clearing `superseded_by` refused (attribution tuple: tests T1–T9).

**F — first-in / last-out**

4. Off by default; enabling projects; disabling: no new day starts, a started day is still finalised (Q3).
5. Single in → slot `in`, `inferred_first_last`, `verified = false`, `work_mode = 'office'`, `location_id` = device office.
6. In + out ≥ 30 min before close → `provisional_out`, **no row**; `day_for` open, early 0, overtime 0;
   `biometric_day_pending` = pending with the punch time and final time.
7. At close → `out` row; final hours, early leaving and overtime equal an app day with the same times; pending = false.
8. In + out < 30 min → no out; at close `missing_checkout` + `incomplete`.
9. Earlier punch before close → same row id moved, audited; after close → `correction_needed · after_day_close`.
10. Double press across devices → `extra`; possible duplicate never projected.
11. App in 09:00 + machine 09:03 → `reconciled`; machine 08:30 → `correction_needed · before_app_checkin`; app out then machine → `extra`.

**G — gate, holds, decisions**

12. Unauthenticated punch → flagged; one HR acceptance per punch → projected (no bulk path exists, Q2).
13. Late backfill (> 2 days) → flagged; ≤ 2 days → projected; future within 120 s waits then projects.
14. Holiday, weekly off, full-day leave, before joining, after exit, deactivated, device without office, import batch → `held`;
    fixing the cause releases it within the 15-minute recheck; half-day leave projects.
15. Pending correction → `held`; approved correction → day locked, slot superseded and never refilled, new punches and
    `correction_needed` punches → `after_correction`.
16. Overnight 22:00–06:00: in 21:55 and out 06:20 on one work date; overlap with the next shift → `ambiguous_work_date`.
17. Mapping attaches an old/unauthenticated unmatched punch → re-gated, not projected silently (E11).
18. Idempotence: second run → no row change, no audit row, no version change (a still-held punch only gets a new
    `next_check_at` when its check was due).

**H — held punches, retry and age (revision 3)**

H1. Held punch 5 days old, cause unresolved (weekly off still on the roster): re-evaluated at its due time at any age;
    stays `held`; `next_check_at` follows the backoff (6 h); punch time, work date and `held_since` unchanged.

H2. The same punch after the cause is fixed (roster changed): at its next check it becomes `flagged · late_backfill`
    with `late_release_at` set; **no row** is written; a test also gives it an earlier HR acceptance (unauthenticated
    accepted before the hold) and proves that acceptance does not count.

H3. Released within two days (leave cancelled the next morning): passes the ordinary gate and is projected; with an
    `unauthenticated_source` flag it is flagged unless it already carries an individual acceptance.

H4. Released after two days: `flagged · late_backfill`; a new `accept_time` (reason required) is allowed once, creates
    a second review row, and the punch is then projected by the ordinary rules; a historic lone in still ends as
    `correction_needed · would_open_closed_day` and a later web check-in succeeds.

H5. Cause fixed while projection is disabled: day with no projected slot → punch untouched (`held`, no version change);
    projection enabled again → re-evaluated at its next check and the age rule applies (old → `late_backfill`).
    Day that already has a projected slot → still processed (Q3: started days finish).

H6. Fairness: 2,000 old held employee-days and 30 new punches for today; one run projects all 30 new days (step 1) and
    re-checks exactly 50 held days (step 2), longest-waiting first; after enough runs every held day has been
    re-checked; no held day is re-checked twice before every due one has been checked once.

H7. Company-local dates: a company in `Pacific/Kiritimati` (+14) and one in `America/Adak` (−10) at the same instant —
    the "recent days missing a check-out" bound follows each company's own date; the 2-day window is identical.

H8. Concurrency: two runs at once over the same held days → each day evaluated once under lock 7 (the second sees
    nothing due); no duplicate audit rows.

**Q — due held punches and bounded days (revision 4)**

Q1. Held punch with `next_check_at` one hour ahead; a new stored punch triggers the same employee-day: the new punch
    is processed; the held punch's row is byte-identical afterwards (status, hold reason, `held_since`,
    `next_check_at`, `version`, `updated_at`), it is not locked by the call (a concurrent `SELECT … FOR UPDATE NOWAIT`
    on it succeeds), and no audit row mentions it.

Q2. The same punch once due: re-evaluated normally — still held → only `next_check_at` moves (per backoff); cause
    fixed within 2 days → ordinary gate; after 2 days → `flagged · late_backfill`.

Q3. Several held punches on one day, one due and two not due: only the due one changes; the two keep their original
    `next_check_at` and state (checked field by field).

Q4. Large backlog: one employee-day with 1,000 stored punches (first-in/last-out) and one with 1,000 device-mode
    punches, `p_limit = 200`: each call writes ≤ 200 + 5; repeated runs finish the day; afterwards every punch has
    exactly one final role, none is `stored`, no `processed_at` is null, the slots equal a single unbounded run on a
    copy (same rows, same raws, same `at`), and in device mode the counted rows alternate validly in time order.
    A gate made mostly of flags (900 unauthenticated punches) behaves the same way and never decides roles from
    ungated punches.

Q5. Concurrent queue runs: two `biometric_run_projection()` calls started together over 300 due held punches and 300
    stored punches: each due punch is evaluated exactly once (one `next_check_at` change / one role change and one
    audit row per punch), no deadlock, the second run's per-day calls return with nothing written for days the first
    finished.

Q6. Starvation: 5,000 held employee-days all due plus one day with 3,000 stored punches, plus 30 current days with
    one punch each: one run projects all 30 current days (step 1, newest first), the large day advances by at most 200
    writes, and held re-checks use only their own 500-write budget.

Q7. Continuation marks: a role-phase stop leaves exactly one mark; the next call clears it; a day never stays selected
    after it is complete (a third run writes nothing).

Q8. `stored` invariant: the new check refuses `stored` with `processed_at` set; HR acceptance and mapping attachment
    still produce `stored` with `processed_at = null`.

**T — guard on the attribution tuple (revision 5).** Each test starts from a valid projected row and runs with the
projection setting on (so only the attribution check can refuse), then once more with it off (projection-only rule).

T1. `at` changed alone (by one second) → refused: punch time does not match the raw punch.

T2. `biometric_event_id` changed alone to another raw punch of the same person and day with a different time → refused;
    to a raw punch of another person → refused; to one of another company → refused.

T3. `device_id` changed alone to another device of the same company → refused; to a device of another company →
    refused (by `company_refs` and the guard).

T4. `import_batch_id` set alone on a biometric row → refused (shape check and guard).

T5. `location_id` changed alone to another office of the company → refused; to null → refused; to an office of
    another company → refused.

T6. A valid in-place move (`at`, `biometric_event_id`, `device_id`, `location_id` all from a new raw punch of the same
    person and day) → accepted, same row id; the same move on a superseded slot → refused.

T7. Insert with a raw punch whose state has another work date, another employee, or no state row → refused.

T8. Device-mode row whose slot name is not `dev:<its raw id>` → refused.

T9. Device office changed by Admin after projection: existing rows are untouched (no update happens); the next in-place
    move must carry the new office, a move keeping the old office is refused.

**B — strict write budgets (revision 5)**

B1. `biometric_project_day(…, p_limit => 1)` on a day with a stored punch: returns `deferred`, writes nothing (no state,
    row, audit or error change; version unchanged); the punch stays `stored`.

B2. `p_limit => 5`: same as B1 — the slot step (5) plus the reserve does not fit, so nothing is written.

B3. `p_limit => 9`, closed first-in/last-out day needing slot creation (in row + its punch + out row + its punch =
    4 writes) and 10 extra punches: the slot step is written whole (rows and back-links together), then at most 4 role
    changes (`n + 1 ≤ 8`); the remaining extras stay `stored`; total ≤ 9; the next call continues; the final result
    equals an unbounded run on a copy. Variant with an earlier punch moving the in slot (5-write step): the step still
    fits only as a whole and never half-written.

B4. `p_limit => 10`: as B3 with at most 5 role changes and total ≤ 10.

B5. Held retries with `p_limit` 1, 5, 9, 10 on a day with 20 due held punches: 1 and 5 → deferred, nothing changes
    (the punches stay due, `next_check_at` unchanged); 9 → 8 punches looked at; 10 → 9; the rest stay due and are
    taken next run; none is skipped.

B6. Device mode with `p_limit` 9 and 10 on 10 valid punches: 4 punches counted per call (2 writes each, one reserved);
    order preserved across calls.

B7. Queue: `biometric_run_projection(p_write_budget => 1 | 5 | 9 | 10, p_held_write_budget => 1 | 5 | 9 | 10)`:
    1 and 5 → no call made, nothing written, all days stay due; 9 and 10 → the first call gets that limit, further
    calls only while at least 6 remain, each with the remainder; the run's row writes (counted from state versions,
    attendance rows, audit-free continuation marks and error records) never exceed the budget.

B8. Budget running low mid-run: write budget 2,000 and 15 days each needing 300 writes → calls continue while at least
    6 writes remain, the last one receives only the remainder, the total is ≤ 2,000; days not reached (or not
    finished) stay due and are taken in the next run; no punch skipped or marked without its role.

B9. A failing day costs exactly one write per call (its error record) and is skipped after 3 unresolved records;
    `biometric_retry_day` resolves them and the day is processed again.

B10. Late release counts as one write (`late_release_at` and `flagged · late_backfill` in one update, one audit row).

**A — authentication gate (revision 3)**

A1. `source_auth = 'unauthenticated_lan'` → `flagged · unauthenticated_source`; one individual acceptance → projected.

A2. The gate with `source_auth` null or an unexpected value (exercised by calling the gate logic on a scratch copy of
    the row, since the table's `NOT NULL` and check constraint refuse such rows): always `flagged`, never projected.

A3. `decided` null-safe: an undecided punch with an empty or missing flag array and an authenticated source passes; any
    unknown/null classification is flagged.

A4. Admin changes a device from `comm_key` to `none`: punches already accepted stay as decided; new punches from it are
    flagged per punch (no bulk acceptance, Q2).

**S — session safety (review item 1), each followed by a real `punch('in')` from the web path**

19. HR-accepted unauthenticated lone in from 3 days ago (day closed, no out) → `correction_needed · would_open_closed_day`;
    `session_state` stays `off`; the employee's web check-in today succeeds.
20. Same with a late-backfill flag and with a clock-drift flag accepted by HR → same result.
21. `accept_time` on a `correction_needed` punch is refused with the correction message; `dismiss` works; after an
    approved correction for that date it becomes `after_correction`; web check-in unaffected throughout.
22. Accepted historical in **with** a qualifying out → both rows projected, session `off`, web check-in succeeds.
23. Open overnight session + new in for the next day → `correction_needed · open_session_other_day`; the app check-out
    closes the overnight session as today.
24. Stale session on an already-closed day + new biometric in today → projected; the person is checked in today (not stuck).
25. `biometric_project_now` and `biometric_retry_day` obey the same rules (no bypass through the HR or Admin path).

**D — device-direction transitions (review item 4); nothing invalid may reach the register**

26. Repeated IN: second IN within 60 s → `extra · double_press`; between 60 s and 5 min → `extra · repeat_in`; after 5 min → `correction_needed · impossible_transition`.
27. OUT with no earlier IN that day → `correction_needed · impossible_transition`.
28. IN while already checked in (by device and by the app) → `correction_needed`.
29. OUT after an app check-out → `correction_needed`; OUT while on an app break → `correction_needed`.
30. Mode switched mid-day (first_last → device and back) → existing rows stay, new punches `correction_needed · mixed_direction_modes`.
31. Two device-mode devices, same person: IN on both within 60 s → one row + `extra · double_press`; IN on A, OUT on B → valid pair.
32. Duplicate events: identical re-send → one raw row (gateway); same device within 60 s → `possible_duplicate`, never projected.
33. Delayed and out-of-order: an OUT arriving after a later IN was counted → `correction_needed · out_of_order`;
    in-order late arrivals ≤ 2 days → projected.
34. Device punch with no direction → `correction_needed · no_direction`.
35. After every case in 26–34: invariant query — the day's live rows alternate in/out validly, every biometric row
    matches its raw punch, no slot twice.

**U — reads, exports, permissions**

36. `attendance_day_sources`: Web / Biometric / Imported / Correction / combined / pending; scope equals `report_days`
    (other company, other team refused or empty); 93-day limit.
37. `biometric_day_pending` per `can_see`; `day_events` never returns payloads or flag details to employees.
38. Every system function refused to anon and authenticated; `biometric_project_now` HR scope only;
    `biometric_retry_day` and `biometric_shift_gap_warnings` Admin only; nothing changed by the warnings function.
39. `verification_log` outcome `biometric`; never `verified`.
40. Company deletion with projected rows (reordered script) leaves other companies untouched.

### 12.3 Concurrency proofs (`concurrency/projection_proof.sh`, two real sessions each)
1. Web check-in vs projection of the same person, 50 rounds: one counted in, consistent state, no deadlock.
2. Correction approval vs projection (both orders, forced overlap): never an extra slot beside the correction row.
3. Web check-out vs day-close finalisation: never two counted outs.
4. Two queue runs at once: identical result; audit count equals one run.
5. HR acceptance vs projection; mapping change vs projection; ingest vs projection.
6. Accepted historical punch projected concurrently with a web check-in (S19 under load): the web check-in always succeeds.
7. Mixed load, 5 rounds: no deadlock; invariants hold.

### 12.4 Browser and end-to-end (local PostgREST)
Gateway ingest → `CALL biometric_run_projection()` → over HTTP and in the browser:
- Today card shows **Provisional** time, the pending chip and the final time; after day close shows **Worked (final)**;
  overtime badge never appears while pending.
- Register row and drawer show the pending marker; Register CSV and Late/Overtime CSV contain the Source column with
  the values of 12.2-36; all other columns identical to before (diffed against a pre-0012 export of the same data).
- Timeline says "biometric device", never "location verified"; review queue shows `correction_needed` with no Accept.
- Admin settings shows shift-gap warnings.
pg_cron is not available on the local PostgreSQL (only `btree_gist`, `pgcrypto`), so locally the procedure is called
directly; the schedule is verified on hosted only after separate approval (Q1).

---

## 13. Implemented vs proposed

| Item | State |
|---|---|
| Migrations 0010 (core) and 0011 (gateway) | **Implemented, locally tested, approved for local development.** Not hosted. |
| Correction lock wrapper | **Proposed**; SQL exists only as `tests/concurrency/proposed_correction_lock.sql`, proven on throwaway copies by `lock_proof.sh`. Not in any migration. |
| `pg_cron` availability check | Implemented, read-only (`deploy/check_biometric_prereqs.sql` check 6). Nothing installed (Q1). |
| Source-value preflight | **Proposed** (A0, plus a read-only pre-check). Not run anywhere. |
| Held-punch backoff, separate queue budget, late-release re-acceptance, null-safe gate (revision 3) | **Proposed only.** |
| Due check inside projection, per-call write limit, run write budgets, continuation marks, `stored` invariant (revision 4) | **Proposed only.** |
| Full attribution-tuple guard, strict budgets with deferral, one-write failures (revision 5) | **Proposed only.** |
| Everything else in §4–§11 and Appendix A (columns, constraints, guard, statuses, functions, procedure, `day_events`, `biometric_day_pending`, `attendance_day_sources`, warnings, retry, verification outcome, UI, CSV Source column, script reorder) | **Proposed only.** Not written as a migration or code, not compiled, not executed. |
| Tests in §12.2–§12.4 | **Planned only.** Not written. |
| Real hardware, hosted project, deployment | Not done. |

---

## 14. Owner decisions (B3.4 review, 20 Nov 2026)

| # | Decision | Applied in this design |
|---|---|---|
| Q1 | pg_cron is required for hosted automation. Not installed now; hosted availability verified later under a separate approval. | Schedule statement not in 0012 (A9); local tests call the procedure; hosted keeps projection off until approved (F5). |
| Q2 | Unauthenticated LAN devices: individual HR acceptance per punch; no bulk acceptance in this phase. | No bulk function; test 12.2-12. Acceptance never bypasses session safety. |
| Q3 | When projection is disabled: finish days that already have projected slots; start no new employee-day. | §6.1, test 12.2-4. |
| Q4 | Keep existing behaviour for forgotten check-outs; no engine change. | §6.6; engine untouched. |
| Q5 | HR-created corrections are a later phase; 0012 not expanded. | `correction_needed` routes to the employee's correction request. |
| Q6 | Biometric attendance uses office work mode and the registered device office/location. | `work_mode = 'office'`, `location_id` = device office; device without office → `held`. |
| Q7 | Provisional minutes shown separately with a pending-checkout label; never final hours. | §11.2. |
| Q8 | Warn Admin when shift gaps are shorter than the day-close period; never modify settings silently. | `biometric_shift_gap_warnings`; §7, F18. |
| Q9 | Source column in CSV attendance exports (Web, Biometric, Imported, Correction); other fields and calculations preserved. | §11.3, `attendance_day_sources`. |
| Q10 | Future CSV/Excel imports approved by HR before projection, same validation and correction rules. | Imports held (`import_not_enabled`) in 0012; 0013 releases only approved batches through the same gate. |

No open questions remain for 0012.

---

## 15. Final checks of the revised queue (revision 5)
Each property checked against the Appendix A SQL by reading; nothing was executed.

| Property | Holds because |
|---|---|
| No held punch can stay stuck solely because of age | Step 2 has no date bound; every held punch has `next_check_at` (check constraint) and is re-evaluated at most 6 h after it falls due; index `biometric_event_state_held_due`. Only a still-valid hold, 3 processing failures (Admin retry) or a disabled company (owner decision) keep it held. |
| Backoff cannot be bypassed by another punch of the same day | `biometric_project_day` locks, reads and writes held punches only when `next_check_at <= now()` (A4 lock statement and gate query); the per-day bulk update was removed (Q1, Q3). |
| Old punches still require individual HR acceptance | Gate (b) flags a late release `late_backfill` regardless of `decided`; gate (c) requires an `accept_time` dated after `late_release_at`; ordinary old punches are flagged by gate (d); no bulk path (Q2). |
| HR acceptance never bypasses session safety or sequence checks | `decided` is read only in gate (d). The `correction_needed` checks do not read it; `accept_time` on `correction_needed` is refused (A6). Tests S19–S25, H4. |
| Disabled companies start no new employee-day; started days finish | Both queue steps and `biometric_project_day` require `projection_enabled` or an existing projected slot. |
| Bounded — strictly | Per run: 200 + 50 employee-days and 2,000 + 500 row writes, never exceeded (each call is given at most the remaining budget and the queue subtracts what it wrote); per call: at most `p_limit` writes including the continuation mark; fewer than 6 → deferred, nothing written; the slot step is all-or-nothing; one transaction per employee-day; 5 s lock timeout. |
| Attribution of every biometric row matches its raw punch | Guard A2 validates the whole tuple on insert and on any change of it (T1–T9). |
| No punch lost or skipped | A stop always leaves the rest `stored`, due held, or carrying a continuation mark, and each of those is selected again by the queue (Q4, Q7). |
| Idempotent | `biometric_set_role` writes only on a change (or to clear a mark); slot writes are no-ops when unchanged; a complete day selected again writes nothing (Q7). |
| Safe under concurrent runs | Lock 7 serialises each employee-day; due-ness and roles are re-read after the lock; a punch handled by one run is not due / not pending for the next (Q5, H8). |

## 16. Consistency pass over Appendix A (revision 5)
Every proposed function was re-read against the others (reading only; nothing compiled or executed):

| Check | Result |
|---|---|
| Every `biometric_set_role` call matches its signature (8 parameters, returns boolean) and every write in `biometric_project_day` is counted | Yes. All writes go through `biometric_set_role`, `biometric_write_slot` or one-row updates (next look, continuation mark), each counted. |
| No operation can exceed the limit | Gate, held look, locked, mixed-mode and role-apply steps check `n + 1 ≤ lim − 1`; device step `n + 2`; slot step `n + s_cost` with `s_cost` computed from the same branches that write. Marks use the reserved write. |
| Continuation always leaves a trigger the queue selects | Gate stop: rest still `stored` / due. Other stops: a `stored` punch remains, or exactly one mark on a candidate the next call writes. Queue step 1 selects `processed_at is null` on exactly those statuses. |
| "Pending" ordering uses real status | Fixed: the two `correction_needed` decisions (`after_day_close` on the out candidate, session protection on the in) now read the punch's status instead of assuming `stored`. |
| Mixed-mode stop | Fixed: no mark is written on a `stored` punch (it is already pending). |
| Failure accounting | `biometric_project_one` writes one error record; `biometric_day_failures` and its partial index replace the removed counter; `biometric_retry_day` resolves records (the errors guard allows a single resolution). |
| Not-due held punches untouched | Lock statement, gate query and held-look update all require `next_check_at <= now()`. |
| Grants | New helper `biometric_day_failures` and changed signatures (`biometric_set_role` 8 args, `biometric_project_day` 3, procedures 5) revoked from public/anon/authenticated (A9). |
| Session safety, corrections, stable ids | Unchanged by revision 5; guard keeps the supersession and identity checks. |

---

## Appendix A — proposed SQL for `0012_biometric_projection.sql` (NOT a migration; not compiled or run)

### A0. Source-value preflight (first statement of 0012)
```sql
-- Stops the whole migration, changing nothing, if any existing attendance row has a source value 0012 does not know.
-- Historical rows are never rewritten or deleted to make the new check pass.
do $$
declare bad text;
begin
  select string_agg(format('%s (%s rows)', coalesce(quote_literal(source), 'NULL'), n), ', ' order by source)
    into bad
    from (select source, count(*) n from public.attendance_events
           where source is null or source not in ('web', 'correction') group by source) x;
  if bad is not null then
    raise exception 'Migration 0012 stopped before any change: unexpected attendance_events.source values: %', bad
      using errcode = 'P0001', hint = 'Report these values to the owner. Do not edit attendance history to pass this check.';
  end if;
end $$;
```
The same query, read-only, becomes a new check in `deploy/check_biometric_prereqs.sql` so the owner can run it on a
hosted project **before** approving 0012 (it lists the distinct values and their counts; it changes nothing).
`biometric` and `import` are deliberately *not* accepted by the preflight: before 0012 no such rows can exist, so
finding one means something wrote to the table outside the known code.

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
  office uuid;
  projecting boolean := coalesce(current_setting('attendos.projection', true), '') = 'on';
begin
  if tg_op = 'UPDATE' and old.source in ('biometric', 'import') then
    -- correction supersession: set once by decide_correction, never cleared or changed
    if old.superseded_by is not null and new.superseded_by is distinct from old.superseded_by then
      raise exception 'A replaced attendance event stays replaced' using errcode = '42501';
    end if;
    -- identity of the row (stable id, person, day, slot, kind, how it counts) never changes
    if (new.employee_id, new.kind, new.work_date, new.source, new.projection_slot, new.direction_basis, new.work_mode,
        new.verified, new.correction_id, new.distance_m, new.accuracy_m)
       is distinct from
       (old.employee_id, old.kind, old.work_date, old.source, old.projection_slot, old.direction_basis, old.work_mode,
        old.verified, old.correction_id, old.distance_m, old.accuracy_m) then
      raise exception 'A projected attendance event keeps its person, day, slot and kind' using errcode = '42501';
    end if;
    -- the attribution tuple may move only by projection, only on an unlocked slot
    if (new.at, new.biometric_event_id, new.device_id, new.import_batch_id, new.location_id)
       is distinct from (old.at, old.biometric_event_id, old.device_id, old.import_batch_id, old.location_id)
       and (not projecting or old.superseded_by is not null) then
      raise exception 'Only projection may move an unlocked projected slot' using errcode = '42501';
    end if;
  end if;

  -- full attribution check on INSERT and on ANY change of the attribution tuple (revision 5)
  if new.source in ('biometric', 'import')
     and (tg_op = 'INSERT'
          or (new.at, new.biometric_event_id, new.device_id, new.import_batch_id, new.location_id)
             is distinct from (old.at, old.biometric_event_id, old.device_id, old.import_batch_id, old.location_id)) then
    if tg_op = 'INSERT' and not projecting then
      raise exception 'Biometric attendance is written only by projection' using errcode = '42501';
    end if;
    select * into r from public.biometric_raw_events where id = new.biometric_event_id;
    select * into s from public.biometric_event_state where raw_event_id = new.biometric_event_id;
    office := case when r.device_id is not null then (select d.location_id from public.biometric_devices d where d.id = r.device_id) end;
    if r.id is null or s.raw_event_id is null                                            -- the raw punch and its state exist
       or r.company_id is distinct from public.emp_company(new.employee_id)              -- company
       or s.company_id is distinct from r.company_id
       or s.employee_id is distinct from new.employee_id                                  -- employee (frozen attribution)
       or s.work_date is distinct from new.work_date                                      -- work date (frozen)
       or r.punch_at is distinct from new.at                                              -- punch timestamp
       or r.device_id is distinct from new.device_id                                      -- device
       or r.import_batch_id is distinct from new.import_batch_id                          -- import batch
       or (new.source = 'biometric' and (office is null or new.location_id is distinct from office))   -- registered device office (Q6)
       or (new.source = 'import' and new.location_id is not null)                         -- imports: no office until 0013 defines one
       or (new.projection_slot like 'dev:%' and new.projection_slot is distinct from 'dev:' || new.biometric_event_id)
    then
      raise exception 'Projected attendance must match its raw punch (company, person, work day, time, device, batch, office)'
        using errcode = '23514';
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
    'non_working_day', 'on_leave', 'correction_pending', 'import_not_enabled', 'device_without_office')),
  add column held_since timestamptz,        -- when the punch entered 'held' (kept while it stays held)
  add column next_check_at timestamptz,     -- when the queue re-evaluates a held punch (backoff, §6.8)
  add column late_release_at timestamptz;   -- set when a hold ended after the automatic window: needs a NEW HR acceptance
alter table public.biometric_event_state add constraint biometric_event_state_held_timing
  check ((status = 'held') = (held_since is not null and next_check_at is not null));
-- 'stored' always means "awaiting processing" (no code before 0012 sets processed_at, so existing rows satisfy this)
alter table public.biometric_event_state add constraint biometric_event_state_stored_pending
  check (status <> 'stored' or processed_at is null) not valid;
alter table public.biometric_event_state validate constraint biometric_event_state_stored_pending;
create index biometric_event_state_pending on public.biometric_event_state (company_id, work_date, employee_id)
  where processed_at is null;
-- status list gains 'held' (constraint names are read from pg_constraint in the migration; shown here by meaning)
alter table public.biometric_event_state drop constraint biometric_event_state_status_check;
alter table public.biometric_event_state add constraint biometric_event_state_status_check check (status in ('stored', 'unmatched',
  'flagged', 'projected', 'provisional_out', 'extra', 'possible_duplicate', 'reconciled', 'after_correction', 'rejected',
  'dismissed', 'held', 'correction_needed'));
-- correction_needed: the punch can only reach the register through an approved attendance correction (session safety
-- and sequence problems, §6.6). HR acceptance cannot project it; HR may dismiss it; an approved correction for the day
-- turns it into after_correction.
alter table public.biometric_event_state add constraint biometric_event_state_hold check ((status = 'held') = (hold_reason is not null));
alter table public.biometric_event_state add constraint biometric_event_state_held_mapped check (status <> 'held' or mapping_id is not null);
create index biometric_event_state_due on public.biometric_event_state (company_id, work_date, employee_id)
  where status in ('stored', 'provisional_out');
create index biometric_event_state_held_due on public.biometric_event_state (next_check_at) where status = 'held';
-- revision 5: failures are counted from error records (one row per failed call) instead of a per-punch counter, so a
-- failure costs exactly one write
create index biometric_event_errors_day_failures on public.biometric_event_errors
  ((detail ->> 'employee_id'), (detail ->> 'work_date')) where kind = 'processing_failure' and resolved_at is null;
create function public.biometric_day_failures(p_emp uuid, p_day date) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.biometric_event_errors
   where kind = 'processing_failure' and resolved_at is null
     and detail ->> 'employee_id' = p_emp::text and detail ->> 'work_date' = p_day::text
$$;
-- biometric_event_reviews.action list is unchanged: 'dismiss' now also ends a correction_needed punch (A6).

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

-- when a still-held punch is looked at again: soon while the hold is fresh, rarely once it is old (§6.8)
create function public.biometric_hold_next_check(p_held_since timestamptz) returns timestamptz
language sql stable set search_path = public as $$
  select now() + case when p_held_since > now() - interval '1 day' then interval '15 minutes'
                      when p_held_since > now() - interval '7 days' then interval '1 hour'
                      else interval '6 hours' end
$$;

-- one role change for one raw punch; nothing written (no version bump, no audit) if nothing differs
create function public.biometric_set_role(p_raw bigint, p_status text, p_event bigint default null, p_slot text default null,
                                          p_reconciled bigint default null, p_flag text default null, p_hold text default null,
                                          p_late_release boolean default false)
returns boolean language plpgsql security definer set search_path = public as $$
-- returns true when it wrote: exactly one row write (used to count the per-call write budget, §6.9)
declare s public.biometric_event_state; a public.biometric_event_state;
begin
  select * into s from public.biometric_event_state where raw_event_id = p_raw;
  if s.status = p_status and s.projected_event_id is not distinct from p_event and s.projection_slot is not distinct from p_slot
     and s.reconciled_with is not distinct from p_reconciled and s.hold_reason is not distinct from p_hold
     and (p_flag is null or p_flag = any (s.flag_reasons))
     and (p_status = 'stored' or s.processed_at is not null)              -- nothing to change, no continuation mark to clear
     and not p_late_release then
    return false;
  end if;
  update public.biometric_event_state
     set status = p_status, projected_event_id = p_event, projection_slot = p_slot, reconciled_with = p_reconciled,
         hold_reason = p_hold,
         late_release_at = case when p_late_release then now() else late_release_at end,
         processed_at = case when p_status = 'stored' then null else now() end,   -- 'stored' always means "awaiting a role"
         held_since = case when p_status = 'held' then coalesce(case when s.status = 'held' then s.held_since end, now()) end,
         next_check_at = case when p_status = 'held'
                              then public.biometric_hold_next_check(coalesce(case when s.status = 'held' then s.held_since end, now())) end,
         flag_reasons = case when p_flag is null or p_flag = any (flag_reasons) then flag_reasons else array_append(flag_reasons, p_flag) end
   where raw_event_id = p_raw returning * into a;
  if (to_jsonb(s) - 'processed_at' - 'version' - 'updated_at' - 'next_check_at')
     is distinct from (to_jsonb(a) - 'processed_at' - 'version' - 'updated_at' - 'next_check_at') then
    insert into public.audit_log (company_id, action, target, target_id, before, after)
      values (s.company_id, 'biometric_role_' || p_status, 'biometric_event_state', p_raw::text, to_jsonb(s), to_jsonb(a));
  end if;
  return true;
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

create function public.biometric_project_day(p_emp uuid, p_day date, p_limit int default 200) returns jsonb
-- Budget rule (revision 5, §6.9): never more than p_limit row writes. Every operation of cost k runs only if
-- n + k <= lim - 1; the last write is reserved for a continuation mark. p_limit below 6 (largest atomic operation 5
-- + 1 reserved) defers the whole day: nothing is written.
language plpgsql security definer set search_path = public as $$
declare
  cid uuid := public.emp_company(p_emp);
  st public.biometric_settings := public.biometric_settings_for(cid);
  lim int := least(coalesce(p_limit, 200), 1000);                  -- row writes allowed in this call (§6.9), never raised
  s_cost int;                                                       -- writes of the atomic slot step
  n int := 0;                                                       -- writes made so far
  emp public.employees;
  pl record;
  lv public.leave_requests;
  hold text;
  want_hold text;
  closed boolean;
  locked boolean;
  modes text[];
  c record;
  x record;
  ss record;
  prev_at timestamptz;
  app_in public.attendance_events;
  app_out public.attendance_events;
  in_row public.attendance_events;
  out_row public.attendance_events;
  r_ids bigint[] := '{}';
  r_at timestamptz[] := '{}';
  r_pending boolean[] := '{}';
  done bigint[] := '{}';                                            -- punches already given a role in this call
  plan jsonb := '[]';                                               -- role decisions not yet written (§6.9)
  in_raw bigint; base_in timestamptz;
  out_raw bigint;
  ev_id bigint;
  last_kind text;
  newest timestamptz;
  i int;
begin
  if lim < 6 then                                                   -- not enough budget for a safe step: defer, write nothing
    return jsonb_build_object('ok', true, 'complete', false, 'written', 0, 'deferred', true);
  end if;
  perform set_config('lock_timeout', '5s', true);
  perform pg_advisory_xact_lock(hashtextextended(p_emp::text, 7));        -- (E1) the lock punch_core and the wrapper take
  perform set_config('lock_timeout', '0', true);
  perform set_config('attendos.projection', 'on', true);

  if not coalesce((select active from public.companies where id = cid), false) then
    return jsonb_build_object('ok', false, 'reason', 'company_inactive', 'complete', true, 'written', 0);
  end if;
  if not st.projection_enabled and not exists (select 1 from public.attendance_events
       where employee_id = p_emp and work_date = p_day and projection_slot is not null) then
    return jsonb_build_object('ok', false, 'reason', 'projection_disabled', 'complete', true, 'written', 0);
  end if;
  -- the rows this call may change, locked once in raw-id order (a review of one of them waits, then is re-read).
  -- Held punches that are not due are NOT locked, read or changed (§6.8).
  perform 1 from public.biometric_event_state
   where employee_id = p_emp and work_date = p_day
     and (status in ('stored', 'projected', 'provisional_out', 'extra', 'reconciled', 'correction_needed')
          or (status = 'held' and next_check_at <= now()))
   order by raw_event_id for update;

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

  -- 1. gate: stored punches and DUE held punches only, oldest first, within the budget rule (§6.2, §6.8, §6.9).
  --    If the budget runs out, the rest are untouched and still stored / still due, so the queue returns to this day.
  for c in select s.raw_event_id id, s.status, s.decided, s.flag_reasons, s.late_release_at,
                  r.punch_at, r.source_auth, r.time_flags, r.import_batch_id, r.direction,
                  (select d.location_id from public.biometric_devices d where d.id = r.device_id) device_office
             from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
            where s.employee_id = p_emp and s.work_date = p_day
              and (s.status = 'stored' or (s.status = 'held' and s.next_check_at <= now()))
            order by r.punch_at, s.raw_event_id loop
    -- no mark needed here: what is not reached is still stored or still due
    if n + 1 > lim - 1 then return jsonb_build_object('ok', true, 'complete', false, 'written', n, 'stopped_in', 'gate'); end if;
    if c.punch_at > now() then continue; end if;
    want_hold := case when c.import_batch_id is not null then 'import_not_enabled'
                      when locked then null
                      when c.device_office is null then 'device_without_office'          -- Q6
                      else hold end;
    if locked and c.import_batch_id is null then
      n := n + public.biometric_set_role(c.id, 'after_correction')::int;
    -- (a) a hold applies now (decided from current data on every look)
    elsif want_hold is not null then
      if public.biometric_set_role(c.id, 'held', p_hold => want_hold) then n := n + 1;
      elsif c.status = 'held' then                        -- same hold, due look: only the next look time moves
        update public.biometric_event_state set next_check_at = public.biometric_hold_next_check(held_since)
         where raw_event_id = c.id;
        n := n + 1;
      end if;
    -- (b) hold ended after the automatic window: never projected automatically; needs a NEW individual acceptance
    elsif c.status = 'held' and c.punch_at < now() - make_interval(days => st.auto_project_max_age_days) then
      n := n + public.biometric_set_role(c.id, 'flagged', p_flag => 'late_backfill', p_late_release => true)::int;   -- one write
    -- (c) released late earlier: only an acceptance given AFTER that release counts
    elsif c.late_release_at is not null and not exists (
            select 1 from public.biometric_event_reviews v
             where v.raw_event_id = c.id and v.action = 'accept_time' and v.decided_at > c.late_release_at) then
      n := n + public.biometric_set_role(c.id, 'flagged', p_flag => 'late_backfill')::int;
    -- (d) soft checks, null-safe; an individual HR acceptance covers these and only these
    elsif c.decided is not true and c.source_auth is distinct from 'authenticated' then
      n := n + public.biometric_set_role(c.id, 'flagged', p_flag => 'unauthenticated_source')::int;
    elsif c.decided is not true and (coalesce(cardinality(c.time_flags), 0) > 0 or coalesce(cardinality(c.flag_reasons), 0) > 0) then
      n := n + public.biometric_set_role(c.id, 'flagged')::int;
    elsif c.decided is not true and c.punch_at < now() - make_interval(days => st.auto_project_max_age_days) then
      n := n + public.biometric_set_role(c.id, 'flagged', p_flag => 'late_backfill')::int;
    elsif c.decided is not true and (public.biometric_work_date_at(p_emp, c.punch_at, c.direction)).ambiguous is not false then
      n := n + public.biometric_set_role(c.id, 'flagged', p_flag => 'ambiguous_work_date')::int;
    -- (e) released within the window: back to 'stored' (awaiting a role), then the ordinary rules below
    elsif c.status = 'held' then
      n := n + public.biometric_set_role(c.id, 'stored')::int;
    end if;
  end loop;

  if locked then  -- a provisional out on a corrected day is no longer a candidate (§7.1 of the architecture)
    for c in select raw_event_id id from public.biometric_event_state
              where employee_id = p_emp and work_date = p_day
                and (status = 'correction_needed' or (status in ('provisional_out', 'extra', 'reconciled') and not decided))
              order by raw_event_id loop
      if n + 1 > lim - 1 then
        update public.biometric_event_state set processed_at = null where raw_event_id = c.id;   -- continuation mark (§6.9)
        return jsonb_build_object('ok', true, 'complete', false, 'written', n + 1, 'stopped_in', 'locked');
      end if;
      n := n + public.biometric_set_role(c.id, 'after_correction')::int;
    end loop;
    return jsonb_build_object('ok', true, 'complete', true, 'written', n, 'locked', true);
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
    for c in select s.raw_event_id id, s.status from public.biometric_event_state s
              where s.employee_id = p_emp and s.work_date = p_day and s.status in ('stored', 'provisional_out')
              order by s.raw_event_id loop
      if n + 1 > lim - 1 then
        if c.status <> 'stored' then update public.biometric_event_state set processed_at = null where raw_event_id = c.id; n := n + 1; end if;
        return jsonb_build_object('ok', true, 'complete', false, 'written', n, 'stopped_in', 'mixed_modes');
      end if;
      n := n + public.biometric_set_role(c.id, 'correction_needed', p_flag => 'mixed_direction_modes')::int;
    end loop;
    return jsonb_build_object('ok', true, 'complete', true, 'written', n, 'flagged', 'mixed_direction_modes');
  end if;

  select * into app_in from public.attendance_events where employee_id = p_emp and work_date = p_day and superseded_by is null
     and kind = 'in' and source in ('web', 'correction') order by at, id limit 1;
  select * into app_out from public.attendance_events where employee_id = p_emp and work_date = p_day and superseded_by is null
     and kind = 'out' and source in ('web', 'correction') order by at desc, id desc limit 1;

  if modes[1] = 'device' then
    -- 3a. device direction (§6.5): one punch at a time in time order, each decided against the rows already counted.
    --     Stops when the budget is used; later punches stay stored (or are marked) and are taken next run, still in order.
    for c in select s.raw_event_id id, s.status, s.decided, r.punch_at, r.direction
               from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
              where s.employee_id = p_emp and s.work_date = p_day and r.punch_at <= now() and s.projected_event_id is null
                and (s.status = 'stored' or (s.status in ('extra', 'reconciled') and not s.decided))
              order by r.punch_at, s.raw_event_id loop
      if n + 2 > lim - 1 then                                         -- a device punch can cost 2 (slot + role)
        if c.status <> 'stored' then update public.biometric_event_state set processed_at = null where raw_event_id = c.id; n := n + 1; end if;
        return jsonb_build_object('ok', true, 'complete', false, 'written', n, 'stopped_in', 'device');
      end if;
      if c.direction is null then n := n + public.biometric_set_role(c.id, 'correction_needed', p_flag => 'no_direction')::int; continue; end if;
      if exists (select 1 from public.attendance_events e where e.employee_id = p_emp and e.work_date = p_day and e.superseded_by is null
                   and e.source = 'biometric' and e.kind = c.direction and abs(extract(epoch from e.at - c.punch_at)) <= st.double_press_s) then
        n := n + public.biometric_set_role(c.id, 'extra', p_flag => 'double_press')::int; continue;
      end if;
      ev_id := null;
      select e.id into ev_id from public.attendance_events e where e.employee_id = p_emp and e.work_date = p_day and e.superseded_by is null
         and e.kind = c.direction and e.source in ('web', 'correction') and abs(extract(epoch from e.at - c.punch_at)) <= st.reconcile_min * 60
       order by abs(extract(epoch from e.at - c.punch_at)) limit 1;
      if ev_id is not null then n := n + public.biometric_set_role(c.id, 'reconciled', p_reconciled => ev_id)::int; continue; end if;
      select max(at) into newest from public.attendance_events where employee_id = p_emp and work_date = p_day and superseded_by is null;
      if newest is not null and c.punch_at <= newest then
        n := n + public.biometric_set_role(c.id, 'correction_needed', p_flag => 'out_of_order')::int; continue;
      end if;
      select kind into last_kind from public.attendance_events where employee_id = p_emp and work_date = p_day and superseded_by is null
       order by at desc, id desc limit 1;
      select * into ss from public.session_state(p_emp);
      if c.direction = last_kind and newest is not null and c.punch_at - newest <= make_interval(mins => st.reconcile_min) then
        n := n + public.biometric_set_role(c.id, 'extra', p_flag => 'repeat_' || c.direction)::int; continue;
      end if;
      if (c.direction = 'in' and (last_kind in ('in', 'break_start', 'break_end')
             or (ss.state <> 'off' and ss.work_date <> p_day and now() < public.biometric_day_close_at(p_emp, ss.work_date))))
         or (c.direction = 'out' and coalesce(last_kind, 'out') in ('out', 'break_start')) then
        n := n + public.biometric_set_role(c.id, 'correction_needed', p_flag => 'impossible_transition')::int; continue;
      end if;
      if c.direction = 'in' and closed                              -- session safety: HR acceptance does NOT bypass this
         and c.punch_at > coalesce((select max(at) from public.attendance_events where employee_id = p_emp and superseded_by is null), '-infinity') then
        n := n + public.biometric_set_role(c.id, 'correction_needed', p_flag => 'would_open_closed_day')::int; continue;
      end if;
      ev_id := public.biometric_write_slot(p_emp, p_day, 'dev:' || c.id, c.direction, c.id, 'device');
      perform public.biometric_set_role(c.id, 'projected', ev_id, 'dev:' || c.id);
      n := n + 2;
    end loop;
    return jsonb_build_object('ok', true, 'complete', true, 'written', n, 'mode', 'device');
  end if;

  -- 3b. first-in / last-out (§6.4). Roles are DECIDED over the whole day in time order (in memory), then WRITTEN:
  --     slot rows with their own punches first (at most 5 writes), then the other role changes, existing roles before
  --     new punches, each group in time order, within the budget (§6.9).
  select * into in_row from public.attendance_events where employee_id = p_emp and work_date = p_day and projection_slot = 'in';
  select * into out_row from public.attendance_events where employee_id = p_emp and work_date = p_day and projection_slot = 'out';
  for c in select s.raw_event_id id, s.status, s.projected_event_id, r.punch_at
             from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
            where s.employee_id = p_emp and s.work_date = p_day and r.punch_at <= now()
              and (s.status in ('stored', 'projected', 'provisional_out') or (s.status in ('extra', 'reconciled') and not s.decided))
            order by r.punch_at, s.raw_event_id loop
    if prev_at is not null and c.punch_at < prev_at + make_interval(secs => st.double_press_s) and c.projected_event_id is null then
      plan := plan || jsonb_build_object('raw', c.id, 'status', 'extra', 'flag', 'double_press', 'pending', c.status = 'stored', 'at', c.punch_at);
      done := done || c.id; continue;
    end if;
    prev_at := c.punch_at;
    if c.projected_event_id is null and app_in.id is not null and abs(extract(epoch from c.punch_at - app_in.at)) <= st.reconcile_min * 60 then
      plan := plan || jsonb_build_object('raw', c.id, 'status', 'reconciled', 'rec', app_in.id, 'pending', c.status = 'stored', 'at', c.punch_at);
      done := done || c.id; continue;
    end if;
    if c.projected_event_id is null and app_out.id is not null and abs(extract(epoch from c.punch_at - app_out.at)) <= st.reconcile_min * 60 then
      plan := plan || jsonb_build_object('raw', c.id, 'status', 'reconciled', 'rec', app_out.id, 'pending', c.status = 'stored', 'at', c.punch_at);
      done := done || c.id; continue;
    end if;
    if app_in.id is not null and c.punch_at < app_in.at then
      plan := plan || jsonb_build_object('raw', c.id, 'status', 'correction_needed', 'flag', 'before_app_checkin', 'pending', c.status = 'stored', 'at', c.punch_at);
      done := done || c.id; continue;
    end if;
    r_ids := r_ids || c.id; r_at := r_at || c.punch_at; r_pending := r_pending || (c.status = 'stored');
  end loop;

  -- in slot
  if app_in.id is not null then
    base_in := app_in.at;
  elsif in_row.id is not null then
    in_raw := in_row.biometric_event_id; base_in := in_row.at;
    if cardinality(r_ids) > 0 and r_ids[1] <> in_raw and r_at[1] < in_row.at then
      if closed then
        plan := plan || jsonb_build_object('raw', r_ids[1], 'status', 'correction_needed', 'flag', 'after_day_close', 'pending', r_pending[1], 'at', r_at[1]);
        done := done || r_ids[1]; r_ids := r_ids[2:]; r_at := r_at[2:]; r_pending := r_pending[2:];
      else in_raw := r_ids[1]; base_in := r_at[1]; end if;
    end if;
  elsif cardinality(r_ids) > 0 then
    in_raw := r_ids[1]; base_in := r_at[1];
  end if;

  -- out candidate: latest remaining punch ≥ min session after the in, only if the app has not checked out
  if base_in is not null and app_out.id is null then
    for i in reverse coalesce(cardinality(r_ids), 0) .. 1 loop
      if r_ids[i] is distinct from in_raw and r_at[i] >= base_in + make_interval(mins => st.min_session_min) then out_raw := r_ids[i]; exit; end if;
    end loop;
  end if;
  if out_row.id is not null and out_raw is distinct from out_row.biometric_event_id then   -- a counted check-out never moves
    if out_raw is not null then
      plan := plan || jsonb_build_object('raw', out_raw, 'status', 'correction_needed', 'flag', 'after_day_close',
                                         'pending', (select status = 'stored' from public.biometric_event_state where raw_event_id = out_raw),
                                         'at', (select punch_at from public.biometric_raw_events where id = out_raw));
      done := done || out_raw;
    end if;
    out_raw := out_row.biometric_event_id;
  end if;

  -- session protection for a new in (§6.6) — not bypassed by any HR acceptance
  if in_raw is not null and in_row.id is null then
    select * into ss from public.session_state(p_emp);
    if (ss.state <> 'off' and ss.work_date <> p_day and now() < public.biometric_day_close_at(p_emp, ss.work_date))
       or (closed and out_raw is null
           and base_in > coalesce((select max(at) from public.attendance_events where employee_id = p_emp and superseded_by is null), '-infinity')) then
      plan := plan || jsonb_build_object('raw', in_raw, 'status', 'correction_needed', 'at', base_in,
                'pending', (select status = 'stored' from public.biometric_event_state where raw_event_id = in_raw),
                'flag', case when ss.state <> 'off' and ss.work_date <> p_day then 'open_session_other_day' else 'would_open_closed_day' end);
      done := done || in_raw;
      if ss.state <> 'off' and ss.work_date <> p_day then out_raw := null; end if;
      in_raw := null;
    end if;
  end if;

  -- write the slots together with their own punches' roles: one atomic step of at most 5 writes. If it does not fit,
  -- nothing of it is written; the day stays due (a stored punch, or one continuation mark) and continues next call.
  s_cost := case when in_raw is null then 0
                 else 2 + case when in_row.id is not null and in_row.biometric_event_id is distinct from in_raw then 1 else 0 end end
          + case when out_raw is null then 0 when out_row.id is null and closed then 2 else 1 end;
  if n + s_cost > lim - 1 then
    if not exists (select 1 from public.biometric_event_state where employee_id = p_emp and work_date = p_day and status = 'stored') then
      update public.biometric_event_state set processed_at = null
       where raw_event_id = (select min(raw_event_id) from public.biometric_event_state
                              where employee_id = p_emp and work_date = p_day
                                and (status in ('projected', 'provisional_out') or (status in ('extra', 'reconciled') and not decided)));
      n := n + 1;
    end if;
    return jsonb_build_object('ok', true, 'complete', false, 'written', n, 'stopped_in', 'before_slots');
  end if;
  if in_raw is not null then
    ev_id := public.biometric_write_slot(p_emp, p_day, 'in', 'in', in_raw, 'inferred_first_last');
    if in_row.id is not null and in_row.biometric_event_id <> in_raw then
      perform public.biometric_set_role(in_row.biometric_event_id, 'extra', p_flag => 'replaced_by_earlier_punch');
      done := done || in_row.biometric_event_id; n := n + 1;
    end if;
    perform public.biometric_set_role(in_raw, 'projected', ev_id, 'in',
      p_flag => case when closed and out_raw is null and app_out.id is null then 'incomplete' end);
    done := done || in_raw; n := n + 2;
  end if;
  if out_raw is not null then
    if out_row.id is not null then
      n := n + public.biometric_set_role(out_raw, 'projected', out_row.id, 'out')::int;
    elsif closed then
      ev_id := public.biometric_write_slot(p_emp, p_day, 'out', 'out', out_raw, 'inferred_first_last', 'biometric_finalise');
      perform public.biometric_set_role(out_raw, 'projected', ev_id, 'out');
      n := n + 2;
    else
      n := n + public.biometric_set_role(out_raw, 'provisional_out')::int;
    end if;
    done := done || out_raw;
  end if;
  -- everything else is an extra punch (kept, shown, never counted)
  for i in 1 .. coalesce(cardinality(r_ids), 0) loop
    if not (r_ids[i] = any (done)) then
      plan := plan || jsonb_build_object('raw', r_ids[i], 'status', 'extra', 'pending', r_pending[i], 'at', r_at[i]);
    end if;
  end loop;

  -- write the remaining decisions within the budget: existing roles first, then new punches, each in time order.
  -- If the budget runs out, the first unwritten punch is left (or marked) with processed_at = null so the queue
  -- returns to this day; the next call decides the same roles again (deterministic) and continues.
  for x in select * from jsonb_to_recordset(plan) as t(raw bigint, status text, rec bigint, flag text, pending boolean, at timestamptz)
            order by pending, at, raw loop
    if n + 1 > lim - 1 then
      if not x.pending then update public.biometric_event_state set processed_at = null where raw_event_id = x.raw; n := n + 1; end if;
      return jsonb_build_object('ok', true, 'complete', false, 'written', n, 'stopped_in', 'roles');
    end if;
    n := n + public.biometric_set_role(x.raw, x.status, null, null, x.rec, x.flag)::int;
  end loop;
  return jsonb_build_object('ok', true, 'complete', true, 'written', n, 'mode', 'first_last', 'closed', closed);
end $$;
```

### A5. Queue procedure, HR "process now", `day_events`
```sql
-- SECURITY INVOKER and no SET clause on purpose: PostgreSQL refuses COMMIT inside a SECURITY DEFINER procedure or
-- one with a SET clause. It runs as the job owner (postgres) only; every name is schema-qualified; it is revoked
-- from public/anon/authenticated, and everything it calls is SECURITY DEFINER with a pinned search_path.
create procedure public.biometric_run_projection(p_max int default 200, p_held_max int default 50,
                                                 p_write_budget int default 2000, p_held_write_budget int default 500,
                                                 p_day_limit int default 200)
language plpgsql as $$
declare
  k record;
  w int;
  left_current int := p_write_budget;
  left_held int := p_held_write_budget;
begin
  -- 0. work dates for newly attributed punches (frozen once set)
  update public.biometric_event_state s
     set work_date = (public.biometric_work_date_at(s.employee_id, r.punch_at, r.direction)).work_date
    from public.biometric_raw_events r
   where r.id = s.raw_event_id and s.work_date is null and s.employee_id is not null and s.status <> 'unmatched';
  commit;

  -- 1. current work: own day budget (p_max) and write budget (p_write_budget); newest work day first; each employee-day
  --    at most p_day_limit writes per call, so one huge day cannot use the whole run. Selected: punches awaiting
  --    processing (stored, or a continuation mark), days whose close time has passed, recent closed days without a check-out.
  for k in
    select distinct s.employee_id, s.work_date, s.company_id
      from public.biometric_event_state s
      join public.companies co on co.id = s.company_id and co.active
      left join public.biometric_settings b on b.company_id = s.company_id
     where s.work_date is not null and public.biometric_day_failures(s.employee_id, s.work_date) < 3
       and ((s.processed_at is null
             and (s.status in ('stored', 'projected', 'provisional_out', 'correction_needed')
                  or (s.status in ('extra', 'reconciled') and not s.decided)))
         or (s.status = 'provisional_out' and now() >= public.biometric_day_close_at(s.employee_id, s.work_date))
         or (s.status = 'projected' and s.projection_slot = 'in' and not ('incomplete' = any (s.flag_reasons))
             and s.work_date >= public.local_today(s.company_id) - 3                     -- company-local date, not current_date
             and now() >= public.biometric_day_close_at(s.employee_id, s.work_date)
             and not exists (select 1 from public.attendance_events e where e.employee_id = s.employee_id
                               and e.work_date = s.work_date and e.kind = 'out' and e.superseded_by is null)))
       and (coalesce(b.projection_enabled, false)                                     -- Q3: no new day while disabled
         or exists (select 1 from public.attendance_events e where e.employee_id = s.employee_id and e.work_date = s.work_date
                      and e.projection_slot is not null))                              --     but started days finish
     order by s.work_date desc, s.employee_id
     limit p_max
  loop
    exit when left_current < 6;          -- not enough for a safe step: the remaining days wait for the next run
    w := 0;
    call public.biometric_project_one(k.employee_id, k.work_date, k.company_id, least(p_day_limit, left_current), w);
    left_current := left_current - w;   -- w <= the limit passed, so the budget is never exceeded
    commit;
  end loop;

  -- 2. held punches: SEPARATE day and write budgets; only punches whose next_check_at has passed; any age; the
  --    longest-waiting first. project_day itself re-checks "due" under the lock, so a held punch that another run has
  --    just looked at is skipped, and not-due held punches of the same day are never touched.
  for k in
    select s.employee_id, s.work_date, s.company_id, min(s.next_check_at) due
      from public.biometric_event_state s
      join public.companies co on co.id = s.company_id and co.active
      left join public.biometric_settings b on b.company_id = s.company_id
     where s.status = 'held' and s.next_check_at <= now() and public.biometric_day_failures(s.employee_id, s.work_date) < 3
       and (coalesce(b.projection_enabled, false)
         or exists (select 1 from public.attendance_events e where e.employee_id = s.employee_id and e.work_date = s.work_date
                      and e.projection_slot is not null))
     group by s.employee_id, s.work_date, s.company_id
     order by due, s.work_date desc
     limit p_held_max
  loop
    exit when left_held < 6;
    w := 0;
    call public.biometric_project_one(k.employee_id, k.work_date, k.company_id, least(p_day_limit, left_held), w);
    left_held := left_held - w;
    commit;
  end loop;
end $$;

-- one employee-day with failure accounting; reports the writes it made (no COMMIT here; the caller commits).
-- A failed call is rolled back completely and costs exactly one write: its error record.
create procedure public.biometric_project_one(p_emp uuid, p_day date, p_company uuid, p_limit int, inout p_written int)
language plpgsql as $$
declare res jsonb;
begin
  res := public.biometric_project_day(p_emp, p_day, p_limit);
  p_written := coalesce((res ->> 'written')::int, 0);
exception
  when lock_not_available then p_written := 0;                           -- busy: retried next run, not a failure
  when others then
    p_written := 1;
    insert into public.biometric_event_errors (company_id, kind, detail)
      values (p_company, 'processing_failure', jsonb_build_object('employee_id', p_emp, 'work_date', p_day,
              'sqlstate', sqlstate, 'message', left(sqlerrm, 300)));
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

-- Pending biometric check-out for one person-day: drives the "provisional" display (§11.2). Read-only.
create function public.biometric_day_pending(p_emp uuid, p_day date,
  out pending_checkout boolean, out provisional_out_at timestamptz, out final_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_see(p_emp) then raise exception 'Not allowed' using errcode = '42501'; end if;
  select r.punch_at into provisional_out_at
    from public.biometric_event_state s join public.biometric_raw_events r on r.id = s.raw_event_id
   where s.employee_id = p_emp and s.work_date = p_day and s.status = 'provisional_out'
   order by r.punch_at desc limit 1;
  pending_checkout := provisional_out_at is not null;
  final_at := case when pending_checkout then public.biometric_day_close_at(p_emp, p_day) end;
end $$;

-- Per person-day sources of the counted events and pending check-outs, same scope and filters as report_days
-- (company, can_see, department, employee; at most 93 days). Used by the register/detail CSV "Source" column
-- and the register's "pending check-out" marker. report_days itself is not changed.
create function public.attendance_day_sources(p_from date, p_to date, p_department uuid default null, p_employee uuid default null)
returns table (employee_id uuid, work_date date, sources text[], pending_checkout boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare cid uuid := public.my_company();
begin
  if cid is null then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 92 then raise exception 'Choose a range of up to 93 days'; end if;
  return query
  with people as (
    select e.id from public.employees e
     where e.company_id = cid and public.can_see(e.id)
       and (p_department is null or e.department_id = p_department) and (p_employee is null or e.id = p_employee)
  ), counted as (
    select ev.employee_id, ev.work_date, array_agg(distinct ev.source order by ev.source) srcs
      from public.attendance_events ev join people pp on pp.id = ev.employee_id
     where ev.work_date between p_from and p_to and ev.superseded_by is null and ev.kind in ('in', 'out')
     group by 1, 2
  ), pending as (
    select distinct s.employee_id, s.work_date from public.biometric_event_state s join people pp on pp.id = s.employee_id
     where s.work_date between p_from and p_to and s.status = 'provisional_out'
  )
  select coalesce(c.employee_id, p.employee_id), coalesce(c.work_date, p.work_date), coalesce(c.srcs, '{}'), p.employee_id is not null
    from counted c full join pending p on p.employee_id = c.employee_id and p.work_date = c.work_date;
end $$;

-- Q8: Admin warning only. People with an active biometric mapping whose next shift starts before the previous day
-- closes for projection. Read-only; changes no shift, roster or setting.
create function public.biometric_shift_gap_warnings(p_days int default 14)
returns table (employee_id uuid, full_name text, work_date date, day_closes_at timestamptz, next_shift_starts_at timestamptz, gap_min int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare cid uuid := public.biometric_require(true);
begin
  return query
  select e.id, e.full_name, g::date, public.biometric_day_close_at(e.id, g::date), nx.starts,
         floor(extract(epoch from nx.starts - public.biometric_day_close_at(e.id, g::date)) / 60)::int
    from public.employees e
    cross join generate_series(public.local_today(cid), public.local_today(cid) + least(greatest(p_days, 1), 31), interval '1 day') g
    cross join lateral (
      select public.at_local(cid, g::date + 1, sh.start_time) starts
        from public.shift_for(e.id, g::date + 1) f join public.shifts sh on sh.id = f.shift_id
       where (select p.work_mode from public.plan_for(e.id, g::date + 1) p) <> 'off') nx
   where e.company_id = cid and e.active
     and exists (select 1 from public.biometric_employee_mappings m where m.employee_id = e.id and m.valid_to is null)
     and (select p.work_mode from public.plan_for(e.id, g::date) p) <> 'off'
     and nx.starts < public.biometric_day_close_at(e.id, g::date)
   order by 3, 2;
end $$;

-- Admin: retry a day that failed three times (after the cause is fixed). Same lock and function as the queue.
create function public.biometric_retry_day(p_emp uuid, p_day date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true);
begin
  if public.emp_company(p_emp) is distinct from cid then raise exception 'Not allowed' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_emp::text, 7));
  update public.biometric_event_errors set resolved_at = now(), resolved_by = public.my_employee_id(), resolution = 'Retry requested by Admin'
   where kind = 'processing_failure' and resolved_at is null and company_id = cid
     and detail ->> 'employee_id' = p_emp::text and detail ->> 'work_date' = p_day::text;
  insert into public.audit_log (company_id, action, target, target_id, after)
    values (cid, 'biometric_retry_day', 'employees', p_emp::text, jsonb_build_object('work_date', p_day));
  return public.biometric_project_day(p_emp, p_day);
end $$;
```

### A6. Review changes (`biometric_review_event`, create or replace — biometric function)
```sql
-- 1. a correction_needed punch can be dismissed (with a reason) even if HR had accepted it earlier for another
--    reason; nothing else can be done to it here — it reaches the register only through an approved correction:
--      if s.decided and s.status <> 'correction_needed' then return ... 'already been decided' ...
--      when s.status = 'correction_needed' and p_action = 'dismiss' then 'dismissed'
--      when s.status = 'correction_needed' then  -> message: 'This punch would affect the person's check-in state.
--           Ask the employee to request an attendance correction for <work date>.'
-- 2. accepted punches are picked up again by the queue:
--      processed_at = case when next_status = 'stored' then null else processed_at end
-- 3. 'accept_time' remains possible only on status 'flagged' (soft reasons, §6.2). A flagged punch that is already
--    decided can be accepted again only if it was released late (late_release_at set, no acceptance since):
--      if s.decided and not (s.status = 'flagged' and s.late_release_at is not null and not exists (
--            select 1 from biometric_event_reviews v where v.raw_event_id = p_raw and v.action = 'accept_time'
--             and v.decided_at > s.late_release_at)) and s.status <> 'correction_needed' then return 'already been decided';
--    Each acceptance is its own row in biometric_event_reviews (insert-only), so the history shows both decisions.
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
  public.biometric_set_role(bigint, text, bigint, text, bigint, text, text, boolean),   -- returns boolean
  public.biometric_write_slot(uuid, date, text, text, bigint, text, text),
  public.biometric_project_day(uuid, date, int), public.attendance_external_guard() from public, anon, authenticated;
revoke all on procedure public.biometric_run_projection(int, int, int, int, int),
  public.biometric_project_one(uuid, date, uuid, int, int) from public, anon, authenticated;
revoke all on function public.biometric_hold_next_check(timestamptz), public.biometric_day_failures(uuid, date)
  from public, anon, authenticated;
revoke all on function public.biometric_project_now(uuid, date), public.day_events(uuid, date),
  public.biometric_day_pending(uuid, date), public.attendance_day_sources(date, date, uuid, uuid),
  public.biometric_shift_gap_warnings(int), public.biometric_retry_day(uuid, date) from public, anon;
grant execute on function public.biometric_project_now(uuid, date), public.day_events(uuid, date),
  public.biometric_day_pending(uuid, date), public.attendance_day_sources(date, date, uuid, uuid),
  public.biometric_shift_gap_warnings(int), public.biometric_retry_day(uuid, date) to authenticated;   -- each checks its own role/scope
-- NOT in 0012 (hosted, after approval of Q1):
--   select cron.schedule('attendos-biometric-projection', '* * * * *', 'call public.biometric_run_projection()');
```
- `deploy/delete_company.sql`: delete `biometric_event_state` → `attendance_coords` → `attendance_events` → the
  other biometric tables (raw events after attendance events).
- `deploy/check_biometric_prereqs.sql`: new read-only check — distinct `attendance_events.source` values with counts;
  passes only for `web` / `correction` (the preflight of A0, run before approval).
- `deploy/verify_hosted.sql`: new checks — the new functions are not executable by anon/authenticated (except
  `day_events`, `biometric_project_now` for authenticated), `decide_correction_core` executable by nobody,
  both new triggers present, projection off for every company until enabled.
- `tests/run.sh`: add `biometric_projection_test.sql` after the gateway suite.
