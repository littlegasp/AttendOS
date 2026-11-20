# Biometric integration — test plan (Phase B1)

Status: **plan (revision 2). No tests written yet.** Every result is labelled **[DB]** database test, **[APP]** app/unit test,
**[E2E]** browser, **[MOCK]** mock adapter / agent simulator, **[HW]** real hardware, **[HOSTED]** hosted project.
Mock results are never reported as hardware results. Existing suites (360 DB, 35 app, 36 + 26 Auth, 29 browser)
must stay green after every phase.

## A. Core
| Test | Kind | Phase |
|---|---|---|
| Register device, assign office, disable | DB, E2E | B2/B3 |
| Map code → employee; refuse inactive/exited/other-company employee | DB | B2/B3 |
| Ingest one punch → raw stored → normalised → projected → `day_for` shows in/out, late, overtime | DB, MOCK | B3/B6 |
| Register drawer shows source "Biometric" and device | E2E | B6 |
| Existing app punching unchanged (whole existing suite) | DB, E2E | every phase |

## B. Offline and sync
Device offline; agent offline; internet down then restored (queue drains, original times kept); same batch sent 3×
(no duplicates); delayed punches from 3 days ago (day rebuilt, totals right); partial batch failure (good rows kept,
bad rows to review); agent restart mid-upload; retry after gateway error; backlog of 50,000 punches (batches,
cron processing, app punches unaffected). Kind: MOCK + DB; repeat key cases on HW in B5.

## C. Mapping
Valid mapping; unmapped code → review → map → reprocessed with original time; duplicate code on one device refused;
same code on two devices; employee deactivated (new punches to review, old ones kept); transferred office (device
office vs roster office noted); mapping changed (rule: a new mapping reprocesses only unmatched events; days already
projected are rebuilt only when HR asks, and that rebuild is audited); employee of another company refused.

## D. Attendance logic (each compared with the same day punched through the app)
Regular shift; overnight shift (punch after midnight → previous work date); multiple punches (extras kept, not
counted); missing check-out; breaks (device-direction mode); late; early; overtime; mixed app + biometric within and
outside the 5-minute window; HR correction on a biometric day survives a rebuild; leave/holiday punch flagged.

## D2. Projection stability and corrections (new in revision 2)
| Test | Kind |
|---|---|
| Project a day twice → same rows, same ids, no audit entry the second time | DB |
| Later "last out" arrives → the out slot row is updated in place (same id), audit shows before/after | DB, MOCK |
| Delayed earlier punch arrives → in slot updated, original punches all kept | DB, MOCK |
| HR approves a correction of the check-in, then an earlier biometric punch arrives → slot stays superseded, punch = `after_correction` in review, correction result unchanged | DB |
| Correction approved on a projected out; re-projection after a new mapping → correction intact | DB |
| Punch dismissed by HR → slot voided (not deleted), day recalculates; with D7a declined → HR correction path instead | DB |
| Single punch → no inferred check-out, day `incomplete` | DB |
| Two punches 10 min apart (< minimum session) → no inferred check-out, flagged | DB |
| Provisional out before day close becomes final after close | DB |
| Device-direction mode: out without in → flagged, not projected | DB |
| `attendance_events.at` equals the device punch time, never receipt/processing time, for punches synced 1 h and 3 days late | DB |
| Every existing DB/app/browser check unchanged (including with the D7a engine condition) | DB, APP, E2E |

## D3. Duplicates (new in revision 2)
Same event ID twice; same record sequence twice; fallback fingerprint with occurrence 1 and 2 (two genuine identical
punches both kept, re-read keeps two); same key + different payload → conflict logged, original kept; replayed
`batch_id` → stored response, nothing processed; agent restart re-sending unconfirmed rows; possible duplicate
within 60 s → one projected, HR can confirm. Kind: DB, MOCK.

## D4. Mapping precedence and validity
Device-specific beats company-wide; code reused after an exit maps old punches to the old person and new punches to
the new person; overlapping validity refused. Kind: DB.

## E. Security
Unauthenticated call; wrong key; revoked key; key of company A + device of company B; replayed `batch_id`; duplicate
event; oversized batch; rate limit; template/photo fields stripped; HR of A reading B's biometric tables; anon reading
any biometric table; employee/manager cannot see devices or raw payloads; HR cannot read raw payload; nobody can
update raw events; build scan finds no secret; anon EXECUTE list = 3 functions.

## F. Hardware (B5, B7)
Per model/firmware: connection test; pull or push of 100+ real punches; times vs. device screen; duplicates on
re-sync; agent off for a day then recovery; device clock moved ±10 min (drift flag); capacity/overwrite behaviour
as documented by the vendor. Recorded in BIOMETRIC_HARDWARE_COMPATIBILITY.md.

## G. Performance
Ingest 500-event batch < 2 s locally; 50,000-event backlog processed without blocking `punch` (p95 app punch
latency unchanged); register/report timings unchanged within noise (docs/PERFORMANCE.md method). No timeout changes.
