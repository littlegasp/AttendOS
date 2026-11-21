# Biometric integration — implementation status

Branch `feature/biometric-b1` (from `phase-4-5` @ `0fcec08`). Updated 20 Nov 2026 (B1 revision 3; B2 UI; B2 review corrections; B3.1 database audit; B3.2 migration 0010 local, approved for local development; B3.3 migration 0011 gateway local, approved for local development; B3.4 migration 0012 implemented locally; 21 Nov 2026: B4 UI local, B5 agent design written).
Labels: **Implemented · Locally tested · Mock tested · Tested with real hardware · Hosted verified · Not yet implemented.**

| Phase | Scope | Status |
|---|---|---|
| **B1** Architecture & database design | Audit, architecture, schema & migration plan, adapter contract, agent design, security, hardware research, test plan | **Revision 3 written (owner clarifications applied) — awaiting final B1 approval.** No migration, function, UI or agent code. |
| B2 Device management UI | Overview, devices, add-device wizard, device detail, mapping, sync activity, review queue — on mock data | **Implemented; review corrections and final verification done; locally tested with mock data** (BIOMETRIC_B2_DEVICE_UI.md). No backend, no hardware. Awaiting owner review. |
| B3 Database + gateway | 0010 core tables, 0011 `biometric_ingest`, heartbeat, keys, normalisation, idempotency, errors | **Implemented and locally tested; approved for local development** (BIOMETRIC_B3_1_DB_DESIGN.md r5.1). Not hosted. |
| B3.4 Attendance projection (0012) | Projection under the punch lock, slots, provisional out, gate, holds, correction wrapper, `day_events`, labels | **Implemented and locally tested** (migration 0012; BIOMETRIC_B3_4_IMPLEMENTATION_REPORT.md). Not hosted; pg_cron not installed; UI items not built; projection off for real companies. |
| B4 Application UI | Source labels, timeline, provisional out, CSV Source, live device screens | **Implemented and locally tested** (BIOMETRIC_B4_UI_REPORT.md). Not deployed. |
| B5 Sync Agent | Windows Service, encrypted queue, uploader, heartbeat, mock adapters, push receiver, installer | **Design written — awaiting owner review** (revision 1: BIOMETRIC_B5_SYNC_AGENT_DESIGN.md; revision 2, eSSL first: BIOMETRIC_B5_ESSL_FIRST_DESIGN.md; revision 3, X2008 + DAT import: BIOMETRIC_B5_REV3_DESIGN.md, milestones M0–M13). Not yet implemented. |
| B5 M1–M2 Offline DAT import (`essl.dat_import`) | X2008 USB export → import staging; no projection | Designed (rev 3); implementation-ready specification (rev 4, BIOMETRIC_B5_REV4_DAT_IMPORT.md) awaiting owner review. DAT format pending inspection of an original file. Migration 0013 not written. |
| B5 M10–M13 First network adapter + pilot | eSSL X2008 reference machine (firmware 8.0.4.2-20180530) | Not yet implemented — every communication capability unverified |
| B6 Register drawer and review processing UI | Screens on top of the 0012 projection | Not yet implemented |
| B7 Other manufacturers | eSSL / Matrix / others | Not yet implemented |
| B8 Readiness review | Security, isolation, reliability, retention, performance, hosting | Not yet implemented |

| Item | Implemented | Locally tested | Mock tested | Real hardware | Hosted |
|---|---|---|---|---|---|
| B2 screens (demonstration data) | Yes | Yes (52 app, 101 + 56 sign-off browser, 360 DB, 29 regression) | Yes — UI only, mock state | No | No |
| Migrations 0010, 0011 (database, gateway) | Yes | Yes (633 DB, 21 + 6 concurrency, 18 HTTP) | Mock agent only | No | No |
| Projection 0012 | Yes (database; pair-selection policy approved by the owner 21 Nov 2026) | Yes (239 SQL + 17 concurrency + 17 HTTP; full run 872) | Mock agent / direct inserts only | No | No |
| Projection UI (labels, provisional display, CSV Source) and live biometric screens (B4) | Yes | Yes (B4 browser 60, app 64, regression 29) | Local demo data through the real gateway | No | No |
| Agent, adapters | No | No | No | No | No |

Unchanged by B1: application commit `6d47386`, all migrations 0001–0009, the Pilot 01 pack. Nothing deployed,
no hosted migration, no tag, no merge.

## Decisions
**Recommended defaults accepted for architecture planning; final owner sign-off pending:** D1 baseline · D2 .NET 10 LTS + isolated legacy SDK host · D3 device direction where reliable,
else controlled first-in/last-out · D4 record + flag leave/holiday punches · D5 5-minute reconciliation, configurable ·
D6 no direct device-to-cloud initially · D7 stable, auditable, correction-preserving projection · D8 31-day backfill,
configurable.
Open: D9 first physical device (model + firmware); D7a voided-row condition in the engine; minimum inferred session
duration and day-close rule; provisional check-out behaviour (architecture §7.1); raw-event retention period;
`superseded_by` foreign key; queue encryption library licence; whether unauthenticated push devices are allowed.
Details: BIOMETRIC_SYSTEM_ARCHITECTURE.md §11.
