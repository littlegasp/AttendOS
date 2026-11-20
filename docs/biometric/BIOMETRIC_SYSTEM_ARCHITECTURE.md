# Biometric integration — system architecture (Phase B1, revision 2)

Status: **design for review. Not implemented.** Revision 2 applies the owner's B1 review (20 Nov 2026): runtime,
direction rules, stable projection, duplicate rules, timestamps, integrity. Final decisions and open questions: §11.

## 1. Layers
```
 Layer A  Biometric machines (ZKTeco, eSSL, Matrix, …) — verify the finger/face/card ON the machine
            │  LAN only (never exposed to the internet)
 Layer B  AttendOS Sync Agent (.NET 10 LTS Windows service; legacy SDKs in an isolated adapter host)
            │  adapters: SDK pull · local push receiver · vendor software    CSV/Excel import (HR, in the app,
            │  encrypted queue · retry · heartbeat                            labelled "Approved import")
            │  HTTPS, outbound only, agent key
 Layer C  Gateway = database functions in Supabase (Mumbai)
            biometric_ingest · biometric_heartbeat — key → company → device → store raw (idempotent)
            → normalise → map employee → validate time → queue for projection → outcome per event
 Layer D  Existing AttendOS engine
            project_biometric_day → attendance_events (source = biometric, stable rows) → day_for_core → register, reports
```
Direct device-to-cloud push is not in the initial implementation (D6).

## 2. Integration methods
| Method | When | Path |
|---|---|---|
| Agent – SDK pull | Device has a documented pull SDK (e.g. ZKTeco Standalone SDK) | Agent (adapter host) reads new logs from a cursor over the LAN |
| Agent – local push receiver | Device can push to a configured server (e.g. ZKTeco/eSSL ADMS, Matrix COSEC device push) | Device pushes to the agent's LAN address; agent forwards |
| Agent – vendor software | Company runs vendor software (eTimeTrackLite, COSEC CENTRA) with a documented API/export | Agent reads it |
| CSV / Excel import | Anything else, or a backlog | HR uploads; rows become `import` events after approval; never shown as device sync |

## 3. The three records and how they relate
```
 biometric_raw_events  (one row per punch received; content immutable, kept per retention policy)
     │ projection decides a ROLE for each raw punch: in · out · break_start · break_end · extra ·
     │ possible_duplicate · reconciled · after_correction · flagged · unmatched · rejected
     │ raw.projected_event_id ──► the stable projected row it currently fills (or null)
     ▼
 attendance_events (source = 'biometric')   ONE STABLE ROW PER SLOT, never deleted, never re-created
     │ slot key: (employee_id, work_date, projection_slot)  e.g. 'in', 'out', 'dev:<raw id>'
     │ biometric_event_id ──► the raw punch currently filling the slot; device_id; direction_basis
     │ superseded_by = <correction id>   (set only by decide_correction, never by projection)
     ▼
 attendance_corrections (HR)  ─► inserts its own event (source = 'correction', correction_id) and supersedes
                                  the replaced event; originals stay
```
Rules that follow from this:
- A projected row's **id never changes**. If a better punch fills the slot (e.g. a later "last out" arrives), the row
  is **updated in place** (`at`, `biometric_event_id`) and the change is written to `audit_log` (before/after).
- A slot that is **superseded by an HR correction is locked**: projection never updates it, never fills that slot
  with another punch, and never clears `superseded_by`. Punches for that slot arriving afterwards get the role
  `after_correction` and go to the HR review queue. (Needed because `decide_correction` supersedes "the earliest in /
  latest out at approval time"; a delayed earlier punch must not silently override that decision.)
- A slot that is no longer justified (its punch dismissed by HR, mapping withdrawn, device switched to another
  direction mode) is **voided**, not deleted: `voided_at`, `void_reason` (D7a — needs the engine's event filter to
  ignore voided rows; see §7).
- Repeated syncs change nothing: same raw punch → same key → no new raw row → projection result identical → no
  update, no audit entry.

## 4. Standard normalised event (agent → gateway)
```json
{ "external_event_id": "…or null", "record_seq": "…or null", "occurrence": 1,
  "device_serial": "ABC1234", "employee_device_code": "104",
  "device_local_time": "2026-11-19 09:02:14", "device_utc_offset": null,
  "direction": "unknown | in | out | break_start | break_end", "direction_source": "device_key | device_fixed | none",
  "verification_method": "fingerprint | face | card | pin | other | unknown",
  "raw": { …manufacturer attendance record as received, without templates/photos… } }
```
The gateway adds `company_id` (from the key only), `device_id`, `received_at`, `punch_at`, `clock_drift_s`,
`time_flags`, `payload_hash`, `dedupe_key`, `processing_status`.

## 5. Time rules
| Value | Where | Rule |
|---|---|---|
| Original device time | `raw.device_local_time` (text, exactly as sent) + `device_utc_offset` if sent | never changed |
| Device time zone | `biometric_devices.timezone` (default company zone), copied onto the raw row at receipt | |
| Normalised time | `raw.punch_at` (timestamptz) | offset if sent; else local time in the device zone. If ambiguous (DST overlap/gap in zones that have it) or the sent offset disagrees with the zone → flag `tz_ambiguous` / `tz_mismatch`, not projected until HR accepts |
| Received time | `raw.received_at` | server time of receipt |
| Clock drift | `raw.clock_drift_s` (device clock − agent clock at that sync, from heartbeat) and `biometric_devices.clock_drift_s` | **recorded, never applied** to the punch |
| Flags | `raw.time_flags[]` | `missing_time`, `unparseable`, `future` (> 10 min after received), `too_old` (older than backfill window or before device registration), `drift` (> 5 min), `tz_ambiguous`, `tz_mismatch` |
| Projected time | `attendance_events.at = raw.punch_at` | **always the original punch time**, never receipt or processing time; delayed sync cannot change it |
Work date: `work_date_at(emp, punch_at)` — the existing overnight rule (`work_date_for_checkin`) applied to the punch
time instead of `now()`. Existing functions are not changed.

## 6. Punch direction (D3)
Per device, `direction_mode`:
- **`device`** — use the direction the device sends. Chosen by HR only after confirming staff use the In/Out/Break
  keys; the UI shows the share of punches that carried an explicit direction to help that decision. Each punch is
  still checked against the day's state (same transitions as the app); an impossible one (out without in, in while
  in) is `flagged`, not projected. Projected rows: `direction_basis = 'device'`, slot `dev:<raw id>` (1:1).
- **`first_last`** (default when direction is not reliable) — controlled inference over the whole work day, every
  time the day is projected, so arrival order does not matter:
  1. Punches by the same person on the same device within the **double-press window** (default 60 s) are one
     punch; the others get role `possible_duplicate` (kept, shown).
  2. App and correction events are fixed facts. A biometric punch within the **reconciliation window** (default
     5 min) of an app event of the compatible direction is `reconciled` with it (§8).
  3. `in` slot: if the day has no live `in` from the app or a correction, the earliest remaining punch fills it.
  4. `out` slot: filled by the latest remaining punch only if it is **at least the minimum session length after the
     in** (default 30 min) **and** the day is closed (shift end + 2 h has passed, or a punch exists on the next work
     date). Before the day is closed the latest punch is shown as a **provisional out** (projected with
     `provisional = true`, labelled in the register) so live dashboards stay useful; it becomes final at day close.
  5. A single punch, or punches too close together to tell in from out, give **no inferred check-out**: the day stays
     "missing check-out" and is flagged `incomplete` for HR.
  6. Remaining punches get role `extra` — kept, shown in the register with time and device, never counted.
  7. Mixed days where the app already supplied an `in` and the machine supplies punches that do not reconcile and
     do not fit rule 4 are flagged `ambiguous` for HR instead of guessed.
  Projected rows: `direction_basis = 'inferred_first_last'`.
- Break inference is never done in `first_last`; breaks come from the app or from `device` mode.
The register labels every punch: **Device: In/Out** (device-confirmed), **Inferred In/Out**, **Provisional out**,
**Extra punch**, **Possible duplicate**, **Matched with app punch**, **Needs review**.

## 7. Projection — `project_biometric_day(emp, work_date)` (D7)
1. Takes the employee's advisory lock (the same one `punch_core` uses), so app punches and projection never
   interleave; runs per employee-day, so it never holds other people up.
2. Reads that day's raw punches (mapped, not rejected), app and correction events, and approved corrections.
3. Computes the role of every raw punch and the wanted content of every slot (§6).
4. **Upserts** slot rows by `(employee_id, work_date, projection_slot)`: insert if missing; update in place if the
   filling punch or time changed and the slot is not locked; void (never delete) if no longer justified; leave
   locked slots untouched.
5. Writes roles back to the raw rows; every slot insert/update/void goes to `audit_log` (`source = 'system'`,
   before/after, reason).
6. Is idempotent: a second run with the same inputs makes no change and no audit entry.
Triggered after each ingest batch for the affected days; a scheduled job (Supabase Cron) handles backlogs in small
chunks so a large catch-up never slows app punches.

**Engine touch point (D7a).** Voiding needs `day_for_core`, `session_state`, `decide_correction`, `my_today_core`
and the new `day_events` to skip rows with `voided_at is not null`, alongside the existing `superseded_by is null`.
This is the only change to existing attendance functions the design needs; it is a new migration that
re-creates those functions with one extra condition, and the full existing test suite must pass unchanged. The
alternative (no voiding; a dismissed punch is fixed only through an HR correction) avoids touching the engine but
leaves HR more manual work.

## 8. Mixed app and biometric punches (D5)
Both records are kept. A biometric punch and an app event of the compatible direction within the reconciliation
window (default 5 min, per company) are the same arrival/departure: the app event stays the counted one, the raw
punch gets role `reconciled` with `reconciled_with = <event id>` (so no projected row is created and nothing is
counted twice). Outside the window, rule §6.7 applies. Decisions are visible in the register and audited.

## 9. Offline behaviour
| Failure | Still works | On recovery | Limit |
|---|---|---|---|
| AttendOS / internet down | Machine records; agent keeps pulling into its encrypted queue | Upload oldest-first; gateway de-duplicates; affected days re-projected | Agent disk cap (alert at 80 %) |
| Agent PC off | Machine stores punches in its own memory | Agent resumes from its cursor (or device re-pushes unsent logs, if the model does) | **Device log capacity and overwrite behaviour, per model — to be measured** |
| Machine off | App (GPS) | — | — |
| Unmapped code | Raw punch stored as `unmatched` | HR maps → punch projected with its original time | — |
| Database restored to an earlier point | — | Agent re-sends confirmed punches it still holds (kept 14 days, §BIOMETRIC_SYNC_AGENT) — de-duplicated | Punches older than the agent's retention must come from the device |
No claim of unlimited storage or zero data loss is made until measured per model.

## 10. Risks (remaining after revision 2)
| Risk | Mitigation | Residual |
|---|---|---|
| Wrong direction inference | Device mode where reliable; conservative first-last; no checkout without evidence; HR flags | HR review effort on sites with messy punching |
| Engine filter change for voided rows (D7a) | One condition, full regression suite | Touches reviewed code — owner decision |
| Delayed punches after an approved correction | Locked slots, `after_correction` review | HR must review those |
| Device clocks | Drift recorded/flagged, NTP guidance | Wrong clocks need HR correction |
| Identical genuine punches | Occurrence ordinal in fallback key (schema §3) | Depends on the device returning logs in stable order — verify per model |
| Anon-callable gateway | Hashed 256-bit keys, revocation, rate/size limits, company from key | Supabase-level rate limiting to be confirmed on hosted |
| Legacy 32-bit COM SDKs | Isolated adapter host process | Vendor SDK quality outside our control |
| Hardware claims | Separate mock / hardware-verified labels | Nothing hardware-verified yet |
| Report performance | No new per-day cost | Daily summary table still required for large companies |

## 11. Final decisions (approved 20 Nov 2026) and open questions
| # | Decision |
|---|---|
| D1 | Baseline: `feature/biometric-b1` from the reviewed `phase-4-5` baseline (`0fcec08`). |
| D2 | Agent: **.NET 10 LTS** (supported to 14 Nov 2028); legacy/COM SDKs isolated in a separate adapter host process where needed. |
| D3 | Direction: explicit device direction where reliably supported; otherwise controlled first-in/last-out (§6). |
| D4 | Punch on leave / holiday / day off: recorded and flagged for HR review. |
| D5 | Reconciliation window: 5 minutes default, configurable per company. |
| D6 | Direct device-to-cloud push: not in the initial implementation. |
| D7 | Projection: stable, auditable, correction-preserving (§3, §7). |
| D8 | Backfill window: 31 days default, configurable. |
| D9 | First physical device: **open** until the owner confirms model and firmware. |

Open questions for the owner:
1. **D7a** — approve the voided-row filter in the engine (recommended), or no voiding (HR corrections only)?
2. Default **minimum session length** for an inferred check-out (proposed 30 min) and **day close** (shift end + 2 h).
3. Show **provisional check-outs** on live screens (proposed yes, clearly labelled)?
4. **Raw-event retention** inside a company's data (proposed: as long as the company's attendance is kept; removed only
   by company deletion or an approved purge).
5. Add a **foreign key on `attendance_events.superseded_by`** → `attendance_corrections(id)` as hardening (data checked
   first)? Proposed yes, in the projection migration.
6. Which **physical device** for B5 (D9).
