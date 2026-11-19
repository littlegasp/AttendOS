# Biometric integration — security and privacy assessment (Phase B1)

Status: **assessment of the proposed design. Nothing implemented.**

## 1. Biometric privacy
- AttendOS stores **no** fingerprint or face templates, raw fingerprint or face images, or enrolment photos. The
  machine verifies the person; AttendOS receives the device user code, punch time, direction if any, verification
  method and device metadata.
- Adapters drop template/image fields; the gateway rejects payloads above a size cap and strips known template/photo
  keys again (defence in depth); a test asserts this.
- The device user code is personal data (it identifies an employee) and follows 07-DATA-RETENTION.md.

## 2. Trust boundaries
| From → to | Credential | Checked where |
|---|---|---|
| HR/Admin browser → AttendOS | Person's Supabase session | RLS + definer functions (unchanged) |
| Agent → gateway | **Agent key** (256-bit random, base64url) in the request body over HTTPS; PostgREST called with the public publishable key | `biometric_ingest` / `biometric_heartbeat`: hash lookup, status active, company from the agent row |
| Machine → agent | LAN only; vendor comm key where the model supports one; push listener allow-lists device IPs | Agent |
| Owner → database | Database password, dashboard MFA | Supabase (unchanged) |

## 3. Gateway rules (to be tested in B3)
1. Company is taken **only** from the agent key; any `company_id` in the payload is ignored.
2. Device must be registered to that company, active, and assigned to that agent (serial + manufacturer match).
3. Employee mapping only within the same company (`check_company_refs`); mapping to inactive/exited people refused.
4. Idempotency keys (schema §1) + unique `batch_id` per agent → replayed batches create nothing new.
5. Limits: ≤ 500 events and ≤ 1 MB per call; per-agent rate limit (e.g. 30 calls/min) enforced in the function;
   over the limit → `retry_after`.
6. Responses contain only per-event outcome codes — never employee names or other data.
7. Failed key checks are counted per source IP (Supabase logs) and never reveal whether a key exists.
8. `verify_hosted.sql` updated: anon may execute only `company_brand`, `biometric_ingest`, `biometric_heartbeat`.

## 4. Credentials
- Agent keys: shown once, stored as SHA-256 hash + 8-char prefix; revoke and rotate by Admin; every action audited.
- Device secrets (comm key, device admin password): only in the agent's encrypted local config. Not in AttendOS, the
  repo, the front end, Cloudflare or chat.
- No secret/service-role key is introduced by this module.

## 5. Who can do what (new capability "Biometric devices")
| Action | Admin | HR | Manager | Employee |
|---|---|---|---|---|
| View overview, devices, sync activity | ✓ | ✓ | — | — |
| Add/edit/disable devices, test/sync now | ✓ | ✓ | — | — |
| Create/revoke/rotate agent keys | ✓ | — | — | — |
| Map device codes, resolve review queue | ✓ | ✓ (own scope) | — | — |
| View raw payload | ✓ | — | — | — |
| See punch source in register | per existing register scope | | | |
Raw payloads are never editable by anyone; resolution creates new records, it does not change the raw event.

## 6. Audit
Device created/changed/disabled, agent created/revoked/rotated, mapping created/disabled, import uploaded/approved,
event reprocessed/dismissed, failed syncs (summary), projection rebuilds (system) — all in `audit_log`, append-only
in normal operation, removed only by the approved company-deletion procedure.

## 7. Multi-company tests required (B3)
Agent key of company A submitting a device serial of company B; mapping a B employee from A; HR of A reading B's
devices/events; anon reading any biometric table; replay of a batch; revoked key; oversized batch; template field in
payload; SQL/JSON injection in codes and times.

## 8. Network
Machines stay on the private LAN, no port forwarding. Agent: outbound HTTPS only (443) to the Supabase project
domain. Direct device-to-cloud push is excluded until decided (D6), because many machines identify themselves only
by serial number in that mode and some firmware sends plain HTTP — to be verified per model before any use.
