# Biometric integration — proposed system architecture (Phase B1)

Status: **proposal for review. Not implemented.** Owner decisions are marked **D1–D9** (§10).

## 1. Layers
```
 Layer A  Biometric machines (ZKTeco, eSSL, Matrix, …) — verify the finger/face/card ON the machine
            │  LAN only (never exposed to the internet)
 Layer B  AttendOS Sync Agent (company PC / server)            CSV / Excel import (HR, in the app)
            │  adapters: SDK pull · local push receiver        │  clearly labelled "Approved import"
            │  encrypted queue · retry · heartbeat              │
            │  HTTPS, outbound only, agent key                  │
 Layer C  Gateway = database functions in Supabase (Mumbai)
            biometric_ingest · biometric_heartbeat — key check → company → device → store raw (idempotent)
            → normalise → map employee → validate time → queue for projection → outcome per event
 Layer D  Existing AttendOS engine (unchanged)
            rebuild_biometric_day → attendance_events (source = biometric) → day_for_core → register, reports
```
Direct manufacturer cloud push (device → internet → AttendOS) is **not** in the first design (D6).

## 2. Integration methods
| Method | When | Path |
|---|---|---|
| **Agent – SDK pull** | Device has a manufacturer pull SDK (e.g. ZKTeco Standalone SDK, TCP 4370) | Agent connects to device on LAN, reads new logs from a cursor |
| **Agent – local push receiver** | Device can push to a configured server (e.g. ZKTeco/eSSL ADMS, Matrix COSEC device push) | Device pushes to the agent's LAN address; agent forwards |
| **Agent – vendor software/database** | Company already runs vendor software (eTimeTrackLite, COSEC CENTRA) | Agent reads that software's documented export/API/DB table |
| **CSV / Excel import** | Anything else, or a backlog | HR uploads a file; each row is an `import` event with the file as evidence; never shown as device sync |

## 3. Standard AttendOS event (normalised)
```json
{ "external_event_id": "…or null", "device_serial": "ABC1234", "employee_device_code": "104",
  "device_local_time": "2026-11-19 09:02:14", "device_utc_offset": null,
  "direction": "unknown | in | out | break_start | break_end", "verification_method": "fingerprint | face | card | pin | other | unknown",
  "raw": { …manufacturer record as received… } }
```
The gateway adds `company_id` (from the key), `device_id` (from serial + company), `received_at`,
`punch_at` (timestamptz, computed), `payload_hash`, `processing_status`. It never accepts a `company_id` from the
caller.

## 4. Time rules
- Keep **as received**: `device_local_time` (text exactly as the device sent it) and any offset it sent.
- `punch_at` = `device_local_time` interpreted in the **device's configured time zone** (default: company time zone;
  India has no daylight saving, other zones are handled by Postgres zone rules).
- `received_at` = server time of receipt. **Sync time never replaces punch time.**
- Each heartbeat reports device clock vs agent clock; drift is stored on the device row.
- Flags (event kept, sent to review, not projected until HR accepts): no/unparseable time; more than 10 minutes in
  the future of `received_at`; before the device was registered or older than the configured backfill window
  (default 31 days, D8); device drift above 5 minutes at the time of sync.
- Overnight shifts: `work_date_at(emp, punch_at)` uses the same rule as app check-in (a punch before yesterday's
  overnight shift end counts for yesterday).

## 5. Punch direction (D3)
Default rule **"first in, last out"**, applied per employee per work date over the whole day, every time the day is
rebuilt (so arrival order of syncs does not matter):
1. App and correction events are fixed facts.
2. If the day has no non-superseded `in`, the **earliest** biometric punch becomes `in`.
3. If, after the last `in`, there is no `out`, the **latest** biometric punch at least 2 minutes after that `in`
   becomes `out`.
4. Every other biometric punch is kept as an **extra punch** (visible in the register with its time and device), not
   projected, so it cannot create breaks or double counts.
5. Per device, HR may switch to **"use the device's direction"** when staff actually press In/Out/Break keys
   (device sends an explicit state). Then the device direction is used as given, with the same state checks as the
   app (an `out` without an `in` goes to review).
Every projected event stores `inferred = true/false` and the rule used; the raw punch is never altered.

## 6. Mixed app and biometric punches (D5)
Both records are kept. A biometric punch and an app event of the same direction within **5 minutes** (configurable)
are treated as the **same punch**: the earlier `in` (or later `out`) is used and the other is marked
`reconciled_with = <event>`. The decision is stored on the punch and in the Activity log; nothing is deleted.

## 7. Projection (D7)
`rebuild_biometric_day(emp, work_date)`:
- takes the same per-employee lock as `punch_core` (so app punches and rebuilds never interleave);
- removes only the **derived** rows it created earlier for that day (`source = 'biometric'`) and recreates them from
  the stored punches; raw and normalised punches are never deleted; the change is audited as a system change;
- re-applies approved corrections (a corrected first-in / last-out stays superseded);
- runs after each ingest batch for the affected days (small batches), and from a scheduled job for backlogs, so a
  large catch-up sync never holds up app punches.

## 8. Offline behaviour
| Failure | What still works | What happens on recovery | Limit |
|---|---|---|---|
| AttendOS / internet down | Machine records; agent keeps pulling over LAN into its encrypted queue | Agent uploads queue oldest-first; gateway de-duplicates; projection rebuilds affected days | Agent disk (configurable cap, alert at 80 %) |
| Agent PC off | Machine records in its own memory | Agent restarts, pulls from its last cursor (or device re-pushes unsent logs, if the model supports it) | **Device log capacity and overwrite behaviour, per model — to be measured on hardware** |
| Machine off | Staff use the app (GPS) | — | — |
| Employee not mapped | Raw event stored, "unmatched" in review queue | HR maps → event reprocessed with its original time | — |
No claim of unlimited storage or zero data loss is made until measured per device model.

## 9. Risks and mitigations
| Risk | Mitigation |
|---|---|
| Wrong punch direction | Default first-in/last-out over the full day; device-direction mode per device; extra punches visible; HR correction flow unchanged |
| Device clock wrong | Drift reported each heartbeat; flags; HR review; instruction to keep NTP on the device |
| Double counting app + machine | Reconciliation rule §6, both kept |
| Duplicate syncs | Unique keys per device (§ schema), batch IDs, idempotent upserts; tested by replay |
| Anon-callable gateway abused | 256-bit keys stored only as hashes, revocable; per-agent rate and size limits; company from key only; no data returned beyond outcomes |
| Agent PC compromised | Key is scoped to one company and can only submit punches for its registered devices; revoke + rotate; no database password or secret key on the agent |
| Re-projection undoing corrections | Corrections re-applied in rebuild; tested |
| Hardware claims | Separate labels: mock-tested vs hardware-verified (BIOMETRIC_HARDWARE_COMPATIBILITY.md) |
| Report performance | No new per-day cost; daily summary table remains the scaling requirement |
| Personal data growth | Raw payload limited to the attendance record (no templates/photos); retention and company deletion cover new tables |

## 10. Decisions needed from the owner
- **D1 Baseline:** feature branch `feature/biometric-b1` from `phase-4-5` @ `0fcec08`. OK?
- **D2 Agent technology:** recommended **.NET 8 Windows service** (official ZKTeco SDK is a Windows COM/.NET DLL;
  Windows first; Linux build without COM adapters). Alternative: Node.js/TypeScript (same language as the app, but
  COM SDKs need fragile bridges).
- **D3 Direction rule default:** first-in/last-out (recommended) vs. device direction.
- **D4 Punch on leave / holiday / day off:** record and flag for HR (recommended) vs. reject to review.
- **D5 Reconciliation window:** 5 minutes (recommended), per company setting.
- **D6 Direct device-to-cloud push** (adds Worker code to the static site, weaker device authentication): not now
  (recommended) vs. later phase.
- **D7 Projection by rebuild of derived rows** (recommended) vs. supersede-only (needs changes to `day_for_core`).
- **D8 Backfill window** for old punches: 31 days (recommended).
- **D9 First hardware for B5:** which machine can you get for testing (model + firmware)? eSSL/ZKTeco ADMS-capable
  models are the most common in India.
