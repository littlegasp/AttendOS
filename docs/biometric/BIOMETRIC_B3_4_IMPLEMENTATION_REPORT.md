# Biometric B3.4 — implementation and test report (migration 0012, local only)

Date: 20 Nov 2026; final review addendum 21 Nov 2026 (§11); pair-selection addendum 21 Nov 2026 (§12). Branch `feature/biometric-b1` (commit in §1). Authorisation: "B3.4 Revision 6 — Design Approved /
Local Implementation Authorization". Design: BIOMETRIC_B3_4_PROJECTION_DESIGN.md revision 6.
**Local only.** Nothing ran against hosted Supabase, staging or production; pg_cron was not installed or scheduled; no
hardware was connected; projection was not enabled for any real company; nothing merged, tagged or deployed.

## 1. Branch, commit, files

Branch `feature/biometric-b1`; the commit that adds this report (see the completion message for the hash).
Migration: `supabase/migrations/0012_biometric_projection.sql` (1,068 lines after the §12 fix; md5 `fe3d7599a90a8bd480c234a3887dacfb`;
after §11 it was 1,058 lines, md5 `2ae9515cef774482d9cdc273b0fd5bc0`;
first version in commit 9d25d12 was 1,006 lines, md5 `2e48dbf08cf0e7c389cac22142f41f1b`).

| File | Change |
|---|---|
| `supabase/migrations/0012_biometric_projection.sql` | **new** — the approved revision 6 SQL (A0–A9) plus the fixes in §7 |
| `supabase/tests/biometric_projection_test.sql` | **new** — 239 checks, groups P F G S H T V A D B Q U R RP (R added in §11, RP in §12) |
| `supabase/tests/preflight_test.sh` | **new** — design test P1 on a clean database at 0011 |
| `supabase/tests/concurrency/projection_proof.sh` | **new** — 17 two-session proofs (§12.3, H8, Q1, Q5; 9a/9b added in §11, 9c in §12) |
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
| R (§11) | delayed device-mode IN + OUT pairs: reconciled, rejected/flagged, lone, several, mixed app/biometric, re-presses, reversed, ambiguous, idempotence, budget | 16 | pass |
| RP (§12) | the punch after a delayed IN is judged in raw time order: flagged / held / possible-duplicate / correction_needed / no-direction OUT, later IN, flagged re-press, dismissed / rejected, late arrival inside a counted pair, idempotence | 13 | pass |
| **SQL total** | `biometric_projection_test.sql` | **239** | **pass** |
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
| **Full database run** | **872 checks (633 + 239), exit status 0** (after §12; 859 after §11; 843 first) |

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
- ~~Device mode: an IN on a closed day followed by an OUT that is reconciled could remain open~~ — **reproduced and
  fixed in §11** (it was a real defect; the earlier "not observed" was because no test covered it).
- See §11.6 for the risks that remain after the fix.

## 10. Confirmation

No hosted Supabase SQL, no staging/production migration, no pg_cron install or schedule, no hardware connection, no
projection enabled for a real company, no credential or permission change outside local databases, no merge, tag or
deployment. Local databases used: `attendos_test` (throwaway), copies for proofs, `attendos_demo` (local demo).

## 11. Final review addendum (21 Nov 2026): delayed IN + reconciled OUT

Request: "AttendOS B3.4 — Targeted Final Review: Delayed IN + Reconciled OUT". Local only; nothing hosted, no
pg_cron, no hardware, projection not enabled for any real company, no merge, tag or deployment.

### 11.1 Root cause and exact code path

`biometric_project_day`, device branch (step 3a), session-safety rule for an IN on a finished (`closed`) day that
would become the person's newest event. The first version looked only at the **direction of the next stored punch**:
if it was an OUT, the IN was written and the OUT was left to its own later iteration. That OUT then met its own
rules — reconciliation with an app/correction check-out within 5 minutes, double press, out of order, flagged or
duplicate (so not even a candidate) — and could end up **not counted**. The IN stayed counted with nothing after it:
`session_state` showed the person *working* on a past day. **Reproduced** by test R2 before the fix (IN projected, OUT
reconciled with the web check-out, `session_state` = working on the earlier day).

### 11.2 The change and why it is safe

1. **Atomic pair.** The IN is counted only together with the OUT that closes it, decided in the same step by the same
   rules the OUT would meet once the IN is counted: the first real punch after the IN must be an OUT that is a
   candidate (stored, or undecided extra/reconciled), is not a double press of a counted biometric OUT, does not
   reconcile with an app/correction OUT, and has no counted event between it and the IN. Re-presses of the IN within
   the reconciliation window between the two are recorded `extra` (`double_press` within 60 s, else `repeat_in`) in
   the same step. Otherwise the IN is **correction_needed** (`would_open_closed_day`) and the OUT is left to its own
   rules. No checkout is ever created and both punches are never accepted blindly.
2. **Ambiguous tail.** If an earlier punch of that day, after everything counted, is already correction_needed, no
   later pair is guessed from it (the IN goes to correction_needed), so a second run cannot invent a different day.
3. **Budget.** The pair costs 4 writes plus one per re-press and is written whole or not at all, under the same rule
   (n + k ≤ limit − 1; the last write stays reserved for the continuation mark).
4. **Re-press check moved (idempotence).** A same-direction punch within the reconciliation window of the counted
   event **immediately before it** is `extra` (`repeat_in`/`repeat_out`). It used to be compared only with the day's
   newest event and ran after the out-of-order check, so a re-press recorded inside a pair turned into
   correction_needed (out_of_order) on the next run (found by R7). Effect elsewhere: a late re-press of a counted
   punch is now `extra` instead of `correction_needed` — it is still never counted and stays visible for review.

Unchanged: the closed-day protection, `open_session_other_day`, impossible transitions, the guard, holds, HR
acceptance never bypassing session safety, first-in/last-out mode, the engine functions (none redefined).

### 11.3 New tests (executed; output from `npm run test:db`)

```
ok - R1 delayed IN + OUT: both counted (dev slots), session off, rows match their raw punches
ok - R1 engine: a closed 8-hour day (late: shift starts 08:00), not open; the person can check in on the web today
ok - R2 the OUT reconciles with the app check-out, so the IN cannot be closed: IN correction_needed, OUT reconciled, only the app rows count
ok - R2 no open session, the app rows keep their ids and are not duplicated; web check-in today works
ok - R3 OUT a possible duplicate / unauthenticated (flagged) / without direction: the IN is correction_needed, the OUT keeps its own review status; nothing counted, no open session
ok - R4 lone delayed IN that would be the newest event: correction_needed, no open session, web check-in works
ok - R4 lone delayed IN that is NOT the newest event (later app day): counted, the day shows missing check-out (engine rule), the current session is untouched
ok - R5 two delayed pairs: four rows, session off
ok - R5 app morning + delayed biometric afternoon pair: both sessions counted, nothing duplicated
ok - R5 a delayed pair inside an app session (12:00–13:00 within 08:00–17:00) is never slotted between counted events: both correction_needed
ok - R6 IN pressed again (30 s, other device) and after 3 min, OUT pressed twice: one pair counted, the extra presses are extra
ok - R6 reversed order (OUT 09:00, IN 17:00): both correction_needed, nothing counted
ok - R6 IN, a second IN 10 min later, OUT: the pair is ambiguous, so nothing is guessed (all correction_needed), no open session
ok - R7 projecting R1–R6 twice more changes no row, state, version or audit
ok - R budget: limit 6 cannot hold the pair (4) + 2 skipped presses + reserve: nothing of it is written, all four stay stored
ok - R budget: limit 9 writes the pair and both skipped presses in one call (6 writes)
```

Every R case also runs the invariant helper: each biometric row matches its raw punch (time, person, work date), every
projected state points to its row, nothing left `stored`, `processed_at` set. Stable ids: R2 checks the app rows keep
their ids; T/V/F9/G15 (unchanged) cover slot ids and correction references.

Concurrency (`projection_proof.sh`, two real sessions):

```
   round 1: web -> true; day-1: in:biometric,out:biometric; punches: projected,projected; now: working:true; invariant violations 0; rerun changed: no
   round 2: web -> true; day-1: none; punches: correction_needed:impossible_transition,correction_needed:impossible_transition; now: working:true; invariant violations 0; rerun changed: no
   (rounds 3–6 alternate the same two outcomes)
ok - 9a. delayed IN+OUT pair projected while the person checks in on the web (6 rounds, both orders): web check-in always succeeds; the pair is either written whole or sent whole to HR, never half; yesterday is never left open; a rerun changes nothing
ok - 9b. delayed pair vs correction approval (approval_first): only the correction's in/out count, both punches are accounted for (after_correction,after_correction, then after_correction), yesterday is closed, a rerun changes nothing
ok - 9b. delayed pair vs correction approval (projection_first): only the correction's in/out count, both punches are accounted for (held,held, then after_correction), yesterday is closed, a rerun changes nothing
```

### 11.4 Results after the fix (all executed 21 Nov 2026, exit status 0 unless stated)

| Suite | Result |
|---|---|
| `biometric_projection_test.sql` | **226/226** (210 earlier + 16 R) |
| Full database run (`npm run test:db`) | **859** checks (633 + 226), exit 0 |
| `projection_proof.sh` | **15/15** (12 earlier + 9a + 9b ×2) |
| `lock_proof.sh` / `gateway_proof.sh` | 21/21, 6/6 |
| `preflight_test.sh` / `delete_company_test.sh` | 5/5, 6/6 |
| `biometric_projection_http.py` / `biometric_gateway_http.py` | 17/17, 18/18 (demo rebuilt with the new 0012) |
| `e2e/regression.py` (browser) | 29/29, including 208 screen loads |
| `npm run check` / `npm run build` | 53/53; build ok (`src/` unchanged) |

Write budgets: B1–B10 and Q4 unchanged and passing (1,000-punch days, budgets 1/5/9/10, run budgets); the pair step
is covered by "R budget" (limit 6 writes nothing of the pair and leaves all four punches stored; limit 9 writes 6).

### 11.5 Test fixes made along the way (no product change)

- `biometric_core_test.sql` (0010 suite): the "secret part of the key appears nowhere" check took the secret with
  `split_part(key, '_', 3)`; the secret's alphabet includes `_`, so about half of all keys gave a short fragment that
  could match unrelated text (one run failed this way). It now takes everything after `bak_<12 hex>_`
  (`substr(key, 18)`). Same meaning, no longer random.
- `projection_proof.sh` scenario 8: the "no biometric check-in beside an app one" count now covers only the proof's
  own people; the R fixtures include a legitimate split day (app morning, biometric afternoon) that the whole-database
  count wrongly reported.

### 11.6 Risks after the fix

- **Order-dependent outcome (safe either way).** A delayed pair for yesterday that is projected *after* the person
  has checked in on the web today goes to HR as `impossible_transition` (both punches); projected *before* it, the
  pair is counted. Neither leaves a session open or half a pair. Counting the pair in both orders would mean relaxing
  the cross-day "IN while a session is open" check for complete past pairs — **owner decision; not done**.
- **Held during a pending correction.** If a pair is projected while a correction for that day is pending, both
  punches are held and become `after_correction` only at their next due look (shown in 9b); until then they show as
  "Waiting for HR".
- **Pairs are conservative.** An IN with a second IN more than the reconciliation window later, an OUT pressed twice
  far apart, or any correction_needed punch earlier in the uncounted tail sends the IN to HR rather than guessing.
- Everything in §9 still applies (UI phase before enabling, pg_cron, hosted limits untested, no hardware).

## 12. Pair-selection addendum (21 Nov 2026): can the pair jump over an intervening punch?

Request: "AttendOS B3.4 — Final Pair-Selection Edge-Case Review". Local only (same boundaries as §11).

### 12.1 Finding confirmed: root cause

In the §11 pair block, the search for the OUT that closes a delayed IN read **only projection candidates** (stored, or
undecided extra/reconciled, no projected row, same work date) and took the first one. A raw punch between the IN and
the OUT in any **other** state was invisible to it, so the IN was paired with a later OUT across it. Reproduced
against the §11 migration (output of the new tests run on it, 12.3): IN 09:00 → flagged / held / possible-duplicate /
correction_needed OUT 12:00 → OUT 17:00 all counted **09:00–17:00**, and so did a flagged IN re-press at 09:02. If HR
later accepted the 12:00 punch, the day would already be stretched over it. Cases that were already safe: an
intervening OUT without direction and a later stored IN (both are candidates, so the search stopped on them).

### 12.2 The change (`biometric_project_day`, device pair block only)

The search now reads **every raw punch of the person after the IN, in time order, in every state** (work dates p_day−1
to p_day+1; no write is made by the search):
- punches HR has already resolved as not attendance — `dismissed`, `rejected` (confirmed duplicate), or an
  extra/reconciled role HR decided — are passed over (the gateway's own duplicate check treats them the same way);
- the first other punch decides: it closes the IN only if it is a usable candidate OUT on the same work date passing
  the §11 checks; a usable IN re-press within the reconciliation window is recorded extra as before;
- anything else (flagged, held, possible duplicate, correction_needed, unmatched-then-mapped later, other work date,
  already counted, no direction, a later IN) stops the search: the IN is **correction_needed** (`would_open_closed_day`)
  and that punch is left in its own state for its own rules.

Unchanged: atomic pair writes and the pair budget (4 + re-presses, last write reserved), slot ids, correction
references, lock 7, the guard and source rules, first-in/last-out mode, engine functions. Full diff in the evidence
ZIP (`13-migration-diff.patch`: §11 + §12 against commit 9d25d12; `14-pair-selection.patch`: §12 alone).

### 12.3 New tests (group RP)

Run against the **§11 migration** (before the fix; assertions reported instead of stopping):
```
FAILED (before fix) - RP1 IN, flagged OUT, valid OUT: the flagged OUT is not jumped over; IN correction_needed, the flagged OUT stays flagged, nothing counted, no open session
FAILED (before fix) - RP2 IN, held OUT, valid OUT: IN correction_needed, the held OUT stays held with its reason, nothing counted
FAILED (before fix) - RP3 IN, possible-duplicate OUT, valid OUT: IN correction_needed, the duplicate stays for review, nothing counted
FAILED (before fix) - RP4 IN, correction_needed OUT, valid OUT: IN correction_needed, nothing counted
ok - RP5 IN, OUT without direction, valid OUT: IN correction_needed, the 12:00 punch correction_needed (no_direction), nothing counted
ok - RP6 IN, a later IN, OUT: nothing is paired across the second IN; all three to HR, nothing counted
FAILED (before fix) - RP6 IN, a flagged re-press 2 min later, OUT: a flagged press is not treated as a harmless re-press; IN correction_needed
ok - RP7 a punch HR already dismissed / confirmed as a duplicate does not block the pair: 09:00–17:00 counted, the reviewed punch keeps its state
ok - RP8 a punch arriving after the pair was counted (flagged OUT / later IN / re-press): flagged / correction_needed (out_of_order) / extra; the counted rows keep their ids and times
ok - RP8 HR accepts the late flagged 12:00 OUT
ok - RP8 the accepted 12:00 OUT inside the counted pair is out of order: correction_needed, the 09:00–17:00 interval is not cut or extended
ok - RP9 projecting RP1–RP8 twice more changes no row, state, version or audit
FAILED (before fix) - RP10 the held OUT is looked at again: the IN stays correction_needed for HR, no row is written, no open session
```
After the fix (from `npm run test:db`):
```
ok - RP1 IN, flagged OUT, valid OUT: the flagged OUT is not jumped over; IN correction_needed, the flagged OUT stays flagged, nothing counted, no open session
ok - RP2 IN, held OUT, valid OUT: IN correction_needed, the held OUT stays held with its reason, nothing counted
ok - RP3 IN, possible-duplicate OUT, valid OUT: IN correction_needed, the duplicate stays for review, nothing counted
ok - RP4 IN, correction_needed OUT, valid OUT: IN correction_needed, nothing counted
ok - RP5 IN, OUT without direction, valid OUT: IN correction_needed, the 12:00 punch correction_needed (no_direction), nothing counted
ok - RP6 IN, a later IN, OUT: nothing is paired across the second IN; all three to HR, nothing counted
ok - RP6 IN, a flagged re-press 2 min later, OUT: a flagged press is not treated as a harmless re-press; IN correction_needed
ok - RP7 a punch HR already dismissed / confirmed as a duplicate does not block the pair: 09:00–17:00 counted, the reviewed punch keeps its state
ok - RP8 a punch arriving after the pair was counted (flagged OUT / later IN / re-press): flagged / correction_needed (out_of_order) / extra; the counted rows keep their ids and times
ok - RP8 HR accepts the late flagged 12:00 OUT
ok - RP8 the accepted 12:00 OUT inside the counted pair is out of order: correction_needed, the 09:00–17:00 interval is not cut or extended
ok - RP9 projecting RP1–RP8 twice more changes no row, state, version or audit
ok - RP10 the held OUT is looked at again: the IN stays correction_needed for HR, no row is written, no open session
```
RP8 covers "the intervening punch arrives after the pair was counted": the counted rows keep their ids and times, the
late punch is flagged / correction_needed (out_of_order) / extra, and an HR-accepted late 12:00 OUT inside the pair is
correction_needed — the interval is never cut or stretched. RP10: when the held punch is looked at again, the IN stays
with HR; it is never paired on its own afterwards. Every RP case checks: rows match raw punches, nothing left stored,
session off, no row for the blocked people.

Concurrency, new proof 9c (a flagged 12:00 punch ingested while the pair is decided, both orders):
```
   [ingest_uncommitted] counted: in:09:00,out:17:00; punches: 09:00=projected,12:00=flagged,17:00=projected; invariant violations 0; rerun changed: no
ok - 9c. flagged punch between IN and OUT ingested during the pair decision (ingest_uncommitted): pair to HR if the punch was visible, otherwise counted with the punch still flagged; never half a pair; rerun stable
   [projection_first] counted: in:09:00,out:17:00; punches: 09:00=projected,12:00=flagged,17:00=projected; invariant violations 0; rerun changed: no
ok - 9c. flagged punch between IN and OUT ingested during the pair decision (projection_first): pair to HR if the punch was visible, otherwise counted with the punch still flagged; never half a pair; rerun stable
```
Ingest does not take lock 7, so an uncommitted punch is not visible to the projection in either order; the pair is
counted and the punch, arriving inside a counted pair, stays flagged (the RP8 rules then apply). A punch committed
before the run is the RP1 case.

### 12.4 Results after the fix (all executed 21 Nov 2026, exit status 0)

| Suite | Result |
|---|---|
| `biometric_projection_test.sql` | **239/239** (226 + 13 RP) |
| Full database run (`npm run test:db`) | **872** checks (633 + 239) |
| `projection_proof.sh` | **17/17** (15 + 9c ×2) |
| `lock_proof.sh` / `gateway_proof.sh` / `preflight_test.sh` / `delete_company_test.sh` | 21, 6, 5, 6 — all pass |
| HTTP projection / gateway | 17/17, 18/18 (demo rebuilt with this 0012) |
| Browser regression | 29/29 |
| `npm run check` / `npm run build` | 53/53; build ok (`src/` unchanged) |

Write budgets: B1–B10, Q4 and the R budget checks pass unchanged; the wider search reads rows but writes nothing.

### 12.5 Decision taken, open to the owner

Passing over **HR-resolved** punches (dismissed, rejected, HR-decided extra/reconciled) is a choice: HR has already
said they are not attendance, so treating them as blocking would send clean days to HR for no new reason (RP7). If the
owner prefers every punch to block, it is a one-line change (`continue` → `exit`) and RP7 flips.

### 12.6 Risks

- More delayed INs go to HR: any unresolved punch after the IN now blocks the pair. This is intended (no guessing).
- Once blocked, the IN is not re-paired automatically when the blocking punch is resolved later (RP10); HR decides it.
- §11.6 and §9 still apply.
