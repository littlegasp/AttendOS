# Biometric integration — implementation status

Branch `feature/biometric-b1` (from `phase-4-5` @ `0fcec08`). Updated 20 Nov 2026 (B1 revision 3).
Labels: **Implemented · Locally tested · Mock tested · Tested with real hardware · Hosted verified · Not yet implemented.**

| Phase | Scope | Status |
|---|---|---|
| **B1** Architecture & database design | Audit, architecture, schema & migration plan, adapter contract, agent design, security, hardware research, test plan | **Revision 3 written (owner clarifications applied) — awaiting final B1 approval.** No migration, function, UI or agent code. |
| B2 Device management UI | Overview, devices, add-device steps, mapping, sync activity, review queue — on mock data | Not yet implemented |
| B3 Gateway | `biometric_ingest`, heartbeat, keys, normalisation, idempotency, errors | Not yet implemented |
| B4 Sync Agent | Service, queue, uploader, heartbeat, mock adapter | Not yet implemented |
| B5 First real adapter | On the hardware chosen in D9 | Not yet implemented — needs hardware |
| B6 Attendance projection | `project_biometric_day` (stable slots), reconciliation, register drawer, review queue processing | Not yet implemented |
| B7 Other manufacturers | eSSL / Matrix / others | Not yet implemented |
| B8 Readiness review | Security, isolation, reliability, retention, performance, hosting | Not yet implemented |

| Item | Implemented | Locally tested | Mock tested | Real hardware | Hosted |
|---|---|---|---|---|---|
| Any biometric feature | No | No | No | No | No |

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
