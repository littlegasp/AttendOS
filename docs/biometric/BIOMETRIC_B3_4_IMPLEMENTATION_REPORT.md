# Biometric B3.4 — implementation and test report (migration 0012, local only)

Date: 20 Nov 2026. Branch `feature/biometric-b1` (commit in §1). Authorisation: "B3.4 Revision 6 — Design Approved /
Local Implementation Authorization". Design: BIOMETRIC_B3_4_PROJECTION_DESIGN.md revision 6.
**Local only.** Nothing ran against hosted Supabase, staging or production; pg_cron was not installed or scheduled; no
hardware was connected; projection was not enabled for any real company; nothing merged, tagged or deployed.

## 1. Branch, commit, files

Branch `feature/biometric-b1`; the commit that adds this report (see the completion message for the hash).
Migration: `supabase/migrations/0012_biometric_projection.sql` (1,006 lines; md5 `2e48dbf08cf0e7c389cac22142f41f1b`).

| File | Change |
|---|---|
| `supabase/migrations/0012_biometric_projection.sql` | **new** — the approved revision 6 SQL (A0–A9) plus the fixes in §7 |
| `supabase/tests/biometric_projection_test.sql` | **new** — 210 checks, groups P F G S H T V A D B Q U |
| `supabase/tests/preflight_test.sh` | **new** — design test P1 on a clean database at 0011 |
| `supabase/tests/concurrency/projection_proof.sh` | **new** — 12 two-session proofs (§12.3, H8, Q1, Q5) |
| `e2e/biometric_projection_http.py` | **new** — 17 checks over real HTTP (PostgREST) |
| `supabase/tests/run.sh` | adds 0012 and its suite after the gateway suite |
| `supabase/tests/concurrency/lock_proof.sh` | scenarios 3–6 now test the migrated wrapper (control removes its lock line); stand-in projection writes a plain row |
| `supabase/tests/concurrency/proposed_correction_lock.sql` | header: superseded by 0012 (not applied any more) |
| `supabase/tests/delete_company_test.sh` | strict checks (fail loudly); measured trigger count; new scenario: company with projected rows |
| `supabase/deploy/delete_company.sql` | attendance rows deleted before raw punches (new foreign keys) |
| `supabase/deploy/verify_hosted.sql` | check 13 counts 12/13/17 functions by installed migration; new check 14 (0012) — read-only |
| `supabase/deploy/check_biometric_prereqs.sql` | new check 12: existing `source` values (the preflight, read-only) |
| `supabase/demo/rebuild.sh` | local demo database includes 0012 (projection stays off) |
| docs | this report; design §13 status; PROJECT.md; IMPLEMENTATION_STATUS.md; B3.3 §13.7 correction (§8) |

Application code (`src/`) is **unchanged** (`git diff d8146c9 HEAD -- src` is empty).

## 2. Migration compile and execution (local PostgreSQL 16)

| Run | Result |
|---|---|
| Full chain 0001–0012 inside `run.sh` (with Supabase default-privilege stub) | applied, exit status 0 |
| Clean database 0001–0012, no stub, no data | 0 errors; anon can execute only `biometric_heartbeat`, `biometric_ingest`, `company_brand`; projection enabled for no company; `verify_hosted.sql` checks 13–14 true |
| 0012 on a copy of the populated 0011 test database, `--single-transaction` | applied; constraints validated against existing rows |
| Preflight (P1): clean 0011 database with a row `source = 'kiosk'` | stopped with exit status 3 and "unexpected attendance_events.source values: 'kiosk' (1 rows)"; rows, columns and functions unchanged; after the owner corrects the row it applies |

## 3. New test groups (all executed; evidence files in the ZIP)

| Group | What | Checks | Result |
|---|---|---|---|
| P | schema, checks, defaults (SQL); P1 preflight is the separate script below | 5 | pass |
| F | first-in/last-out, provisional out, day close, slot moves, double press, reconciliation | 16 | pass |
| G | gate, holds (off day, leave, joining, exit, inactive, no office, import), corrections, overnight, mapping re-gate, idempotence | 27 | pass |
| S | session safety; every case ends with a real `punch('in')` | 13 | pass |
| H | held punches: backoff, late release + new acceptance, release within 2 days, disabled company, local dates; fairness H6 | 22 | pass |
| T1–T9 | guard on the attribution tuple (each field alone; valid move; superseded slot; inserts; dev slot; office change) | 22 | pass |
| V1–V8 | source transitions, each with the projection setting off and on | 27 | pass |
| A1–A4 | authentication gate (A2 with constraints lifted in a rolled-back block) | 4 | pass |
| D | device-direction transitions (repeats, out without in, in while in, out after app out / on break, mode switch, two devices, duplicates, out of order, no direction, invariants) | 13 | pass |
| B1–B10 | strict budgets 1/5/9/10 per call and per run, slot step whole, held retries, device mode, queue, low budget mid-run, one-write failures, one-write late release | 23 | pass |
| Q | due-only held punches (Q1–Q3), 1,000-punch days (Q4), continuation marks (Q7), stored invariant (Q8) | 11 | pass |
| U | sources (CSV), pending, day_events, permissions, shift-gap warning, verification history, no template/image columns | 26 | pass |
| fixture | local noon check | 1 | pass |
| **SQL total** | `biometric_projection_test.sql` | **210** | **pass** |
| Concurrency | `projection_proof.sh`: web check-in vs projection (20 rounds), correction vs projection (both orders), web check-out vs finalisation, two queue runs = one run, acceptance/review/mapping/ingest vs projection, accepted historic punch vs web check-in, not-due held punch not locked, mixed load ×5 | **12** | **pass**, 0 deadlocks |
| Preflight | `preflight_test.sh` (P1) | **5** | **pass** |
| HTTP | `biometric_projection_http.py` | **17** | **pass** |

Selected numbers from the evidence: 1,000-punch first-in/last-out day finished in 6 calls (max 199 writes each);
1,000-punch device day in 11 calls (max 196); 900 unauthenticated punches gated in 5 calls (max 199); queue budget 150
→ 149 writes; budgets 1 and 5 → 0 writes; budget 9 → 4, budget 10 → 2 (the next day's step did not fit); a failing day
costs exactly 1 write (its error record) and stops after 3; two concurrent queue runs: audit +60 / versions +60, the
same as one run.

## 4. Existing regression suites

| Suite | Result |
|---|---|
| Existing database suites (attendance … gateway), 633 checks | 633 pass (exit status 0) — they run before 0012 in the chain, at their own migration points |
| `lock_proof.sh` | 21 pass (scenarios 3–6 now against the migrated wrapper) |
| `gateway_proof.sh` | 6 pass with 0012 installed |
| `delete_company_test.sh` | 6 pass (beta; and proj with 1,110 projected rows); control: the old script fails on the new foreign key |
| `biometric_gateway_http.py` | 18/18 on a demo database with 0012 (projection off: "nothing reached attendance" still holds) |
| `e2e/regression.py` (browser) | 29/29 on a demo database with 0012 — GPS cases, check-in/out, corrections, leave, exports, print, 208 screen loads |
| `npm run check` / `npm run build` | 53/53; build ok (no app change) |
| **Full database run** | **843 checks (633 + 210), exit status 0** |

## 5. Security and permission verification (executed)

- Anonymous: still only `biometric_ingest`, `biometric_heartbeat`, `company_brand` (U38, clean migration, HTTP).
- Signed-in users can call only `attendance_day_sources`, `biometric_day_pending`, `biometric_project_now`,
  `biometric_retry_day`, `biometric_shift_gap_warnings`, `day_events` and the `decide_correction` wrapper among the
  0012 objects; each checks its own scope. Projection internals and `decide_correction_core` are callable by no
  client role (U38; HTTP: 403 for employee and HR, 401 anonymous).
- No function is executable by PUBLIC; every SECURITY DEFINER function pins `search_path`; the queue procedure is
  SECURITY INVOKER (PostgreSQL forbids COMMIT in a definer procedure) and not granted to any client role.
- HR of another company and managers cannot process days; shift-gap warnings and retries are Admin only.
- `attendance_events`: no client write grant (U38); biometric rows only through projection (T*, V4); attribution
  validated against the raw punch on any change (T1–T9); `source` never changes (V1–V6).
- No raw payload in any new read (`day_events`, `biometric_day_pending`, sources); no template/image columns (U).
- Projection off by default; enabled only for the throwaway test company and the local demo E2E company.

## 6. Requirements from the authorisation

| Requirement | Evidence |
|---|---|
| Existing attendance engine behaviour preserved | engine functions not redefined (only the `decide_correction` wrapper and `verification_log` label, as approved); 633 existing checks; browser regression 29/29 and HTTP 18/18 with 0012; S-group web punches; lock_proof scenario 6 |
| Revision 6 source-transition guard | V1–V8 |
| Stable ids and correction references | F9, G15, T6, V8 |
| Same employee advisory lock | projection_proof 1–3, lock_proof 3–5 |
| HR acceptance never bypasses session safety | S19–S25, H4, projection_proof 6 |
| Provisional checkout never final | F6, HTTP (working, no overtime/early) |
| No raw payloads to ordinary HR/Admin reads | U37, HTTP day_events |
| Projection disabled by default | P, HTTP 1, clean migration |
| Per-day, per-call, per-run budgets | B1–B10, Q4 |
| No templates or facial images | U (catalog) |

## 7. Deviations from revision 6, with reasons

1. **Device mode — IN on a finished day followed by its OUT (defect found by test D33).** The design refused such an
   IN as `would_open_closed_day` before seeing the OUT that closes it, so a delayed in-order IN+OUT pair from
   yesterday would never be counted. 0012 allows the IN only if the day's next pending punch is an OUT, and then writes
   both in the same call (budget reserves 4 writes). Session safety is unchanged otherwise.
2. **Design test 12.2-8 (F8) contradicted §6.6.** A lone check-in on a closed day that is the person's newest event is
   `correction_needed` (§6.6), not "missing check-out + incomplete". The test now gives the person a later app day so
   the `incomplete` path is exercised; the session-safety path is tested in S19/S20.
3. **Test scale.** H6 uses 84 held employee-days and 20 current days (design text: 2,000/30), proving the same
   property (separate budgets, 50 longest-waiting first, all current days done). H7 is checked through the catalogue
   (no `current_date` in code; `local_today(company)` used) and zone dates, not with two extra companies.
4. **lock_proof.sh** now tests the migrated wrapper; its stand-in projection writes a plain row, because the 0012 guard
   (correctly) refuses biometric rows outside projection. The real projection is covered by projection_proof.sh.
5. **Migration transaction.** Like 0001–0011, the file has no BEGIN/COMMIT; it must be applied as one transaction
   (Supabase CLI does; locally `psql --single-transaction`), which the preflight relies on — proven in P1.
6. **UI changes not implemented (design §11.2–11.4).** The authorisation covered the migration, functions, scripts and
   database tests; the Timeline label, verification badge, provisional display and CSV Source column are app code.
   Until they are built, the current app would show a biometric row as "· no location" and an unknown verification
   outcome. **Projection must stay off for any real company until the UI phase is done.**
7. Not done by design: pg_cron install/schedule (Q1); HR-created corrections (Q5); imports (0013).

## 8. Correction to an earlier report

The B3.3 report (r5.1 §13.7) listed "company deletion 4". The B3.3 evidence file shows **3** "ok" lines: the fourth
check (raw-event triggers switched back on) compared against a hard-coded 3 triggers and had silently not printed
since 0011 added a fourth trigger. Found while extending the test in B3.4; the test now measures the trigger count
before and after and fails loudly on any mismatch (6 checks pass).

## 9. Remaining risks and open items

- **UI phase** (§7.6) is required before projection is enabled for anyone.
- **pg_cron** (Q1): without it nothing is projected automatically and open days are not finalised; hosted availability
  must be verified and approved separately. HR "process now" covers single days only.
- **Engine regression after 0012:** the original SQL suites are sequence-bound (each runs right after its own
  migration) and cannot be replayed after 0012; post-0012 engine behaviour is covered by the browser regression, the
  HTTP tests, the S-group web punches and the wrapper regression, not by re-running those SQL files.
- **Forgotten check-outs (Q4)** behave as today for app and biometric users alike.
- **Hosted** limits (statement timeout, connection limits, cron worker) and performance at company scale are untested;
  local runs: 1,000-punch days in a few seconds.
- **Short shift gaps (Q8):** warned, not prevented.
- Device mode accepts an IN on a closed day only with a following OUT; if that OUT is later reconciled with an app
  event in the same call the IN could remain open — not observed in tests, noted for B6 review.

## 10. Confirmation

No hosted Supabase SQL, no staging/production migration, no pg_cron install or schedule, no hardware connection, no
projection enabled for a real company, no credential or permission change outside local databases, no merge, tag or
deployment. Local databases used: `attendos_test` (throwaway), copies for proofs, `attendos_demo` (local demo).
