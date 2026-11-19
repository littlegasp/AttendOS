# Biometric integration — implementation status

Branch `feature/biometric-b1` (from `phase-4-5` @ `0fcec08`). Updated 19 Nov 2026.
Labels: **Implemented · Locally tested · Mock tested · Tested with real hardware · Hosted verified · Not yet implemented.**

| Phase | Scope | Status |
|---|---|---|
| **B1** Architecture & database design | Audit, architecture, schema & migration plan, adapter contract, agent design, security, hardware research, test plan | **Documents written — awaiting owner review.** No migration, function, UI or agent code. |
| B2 Device management UI | Overview, devices, add-device steps, mapping, sync activity, review queue — on mock data | Not yet implemented |
| B3 Gateway | `biometric_ingest`, heartbeat, keys, normalisation, idempotency, errors | Not yet implemented |
| B4 Sync Agent | Service, queue, uploader, heartbeat, mock adapter | Not yet implemented |
| B5 First real adapter | On the hardware chosen in D9 | Not yet implemented — needs hardware |
| B6 Attendance projection | `rebuild_biometric_day`, reconciliation, register drawer, review queue processing | Not yet implemented |
| B7 Other manufacturers | eSSL / Matrix / others | Not yet implemented |
| B8 Readiness review | Security, isolation, reliability, retention, performance, hosting | Not yet implemented |

| Item | Implemented | Locally tested | Mock tested | Real hardware | Hosted |
|---|---|---|---|---|---|
| Any biometric feature | No | No | No | No | No |

Unchanged by B1: application commit `6d47386`, all migrations 0001–0009, the Pilot 01 pack. Nothing deployed,
no hosted migration, no tag, no merge.

Open owner decisions: D1–D9 (BIOMETRIC_SYSTEM_ARCHITECTURE.md §10).
