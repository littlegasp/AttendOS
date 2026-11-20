# Biometric integration — implementation status

Branch `feature/biometric-b1` (from `phase-4-5` @ `0fcec08`). Updated 20 Nov 2026 (B1 revision 3; B2 UI; B2 review corrections; B3.1 database audit; B3.2 migration 0010 local, approved for local development; B3.3 migration 0011 gateway local, approved for local development; B3.4 projection design written, not implemented).
Labels: **Implemented · Locally tested · Mock tested · Tested with real hardware · Hosted verified · Not yet implemented.**

| Phase | Scope | Status |
|---|---|---|
| **B1** Architecture & database design | Audit, architecture, schema & migration plan, adapter contract, agent design, security, hardware research, test plan | **Revision 3 written (owner clarifications applied) — awaiting final B1 approval.** No migration, function, UI or agent code. |
| B2 Device management UI | Overview, devices, add-device wizard, device detail, mapping, sync activity, review queue — on mock data | **Implemented; review corrections and final verification done; locally tested with mock data** (BIOMETRIC_B2_DEVICE_UI.md). No backend, no hardware. Awaiting owner review. |
| B3 Database + gateway | 0010 core tables, 0011 `biometric_ingest`, heartbeat, keys, normalisation, idempotency, errors | **Implemented and locally tested; approved for local development** (BIOMETRIC_B3_1_DB_DESIGN.md r5.1). Not hosted. |
| B3.4 Attendance projection (0012) | Projection under the punch lock, slots, provisional out, gate, holds, correction wrapper, `day_events`, labels | **Design written — awaiting review** (BIOMETRIC_B3_4_PROJECTION_DESIGN.md). Not implemented. |
| B4 Sync Agent | Service, queue, uploader, heartbeat, mock adapter | Not yet implemented |
| B5 First real adapter | On the hardware chosen in D9 | Not yet implemented — needs hardware |
| B6 Register drawer and review processing UI | Screens on top of the 0012 projection | Not yet implemented |
| B7 Other manufacturers | eSSL / Matrix / others | Not yet implemented |
| B8 Readiness review | Security, isolation, reliability, retention, performance, hosting | Not yet implemented |

| Item | Implemented | Locally tested | Mock tested | Real hardware | Hosted |
|---|---|---|---|---|---|
| B2 screens (demonstration data) | Yes | Yes (52 app, 101 + 56 sign-off browser, 360 DB, 29 regression) | Yes — UI only, mock state | No | No |
| Migrations 0010, 0011 (database, gateway) | Yes | Yes (633 DB, 21 + 6 concurrency, 18 HTTP) | Mock agent only | No | No |
| Projection 0012 | No (design only) | No | No | No | No |
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
