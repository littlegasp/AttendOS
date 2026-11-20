# Biometric integration — security and privacy assessment (Phase B1)

Status: **assessment of the proposed design (revision 3). Nothing implemented.**

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
| Machine → agent | LAN only; strongest authentication the model supports (§8); IP allow-list is an extra check, never the only one | Agent |
| Agent service → adapter host | Local named pipe, ACL limited to the agent's service account; no network listener | Agent |
| Owner → database | Database password, dashboard MFA | Supabase (unchanged) |

## 3. Gateway rules (to be tested in B3)
1. Company is taken **only** from the agent key; any `company_id` in the payload is ignored.
2. Device must be registered to that company, active, and assigned to that agent (serial + manufacturer match).
3. Employee mapping only within the same company (`check_company_refs`); mapping to inactive/exited people refused.
4. Idempotency: dedupe key per device (event ID → record sequence → fingerprint with occurrence, schema §3) +
   unique `batch_id` per agent → replayed batches and agent restarts create nothing new; same key with a different
   payload is a logged conflict, never an overwrite.
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
| View overview, devices, sync activity (`biometric`) | ✓ | ✓ | — | — |
| Add devices, enable/disable, change punch direction (`manageBiometricDevices`) | ✓ | — | — | — |
| Test connection / sync now / retry failed syncs (`retryBiometricSync`, later phases) | ✓ | ✓ | — | — |
| Create/revoke/rotate agent keys | ✓ | — | — | — |
| Map and end **device-specific** codes (`mapBiometricCodes`) | ✓ | ✓ (own company) | — | — |
| Map and end **company-wide** codes (`mapBiometricCompanyWide`) | ✓ | — | — | — |
| Resolve review queue (`reviewBiometric`) | ✓ | ✓ (own company) | — | — |
| Read raw payloads (`biometric_raw_payload`, audited) | ✓ | — | — | — |
| View raw payload (only through `biometric_raw_payload`, each view audited) | ✓ | — | — | — |
| See punch source in register | per existing register scope | | | |
Revised 20 Nov 2026 (B2 review corrections; B3.2 implements this matrix in 0010 — see BIOMETRIC_B3_1_DB_DESIGN.md §3, §11): device configuration and company-wide codes are Admin-only. The B2
reducer enforces this matrix itself (`assertAllowed`), and B3+ database functions must enforce the same capabilities.
Raw event content is immutable (trigger); HR decisions are separate insert-only review records; projected rows are
never deleted or voided (proposed default: wrong ones are superseded through the correction flow), and slots corrected by HR are locked against projection.

## 6. Audit
Device created/changed/disabled, agent created/revoked/rotated, mapping created/disabled, import uploaded/approved,
event reprocessed/dismissed, failed syncs (summary), projection rebuilds (system) — all in `audit_log`, append-only
in normal operation, removed only by the approved company-deletion procedure.

## 7. Multi-company tests required (B3)
Agent key of company A submitting a device serial of company B; mapping a B employee from A; HR of A reading B's
devices/events; anon reading any biometric table; replay of a batch; revoked key; oversized batch; template field in
payload; SQL/JSON injection in codes and times.

## 8. Local push receiver (revision 3)
The receiver lets a machine push punches to the agent on the office network. No direct device-to-cloud push (D6).

**Binding and exposure**
- Listens on **one configured LAN address** (never `0.0.0.0`, never a public address), on a fixed port; Windows
  Firewall rule created by the installer allows that port **only from the device subnet/IPs**; startup refuses to
  run if the address is public or not on a local interface.
- No port forwarding, no UPnP, no public listener, no remote shell or management endpoint, no inbound connections
  from the internet. The agent's only internet traffic is outbound HTTPS to the Supabase project.

**Authentication — strongest the hardware supports, per device**
| Level | Mechanism (only where the model documents it) | Status |
|---|---|---|
| 1 | Mutual TLS or a per-device secret/signature in each request (HMAC, token, HTTP auth) | Use when the model supports it — **to verify per model**; none confirmed yet for ADMS |
| 2 | **Pull instead of push**: the agent connects to the device and authenticates with the device communication key | Preferred when push cannot authenticate. Note: ZKTeco's Comm Key is a number up to 6 digits and has been shown to be brute-forceable, so it raises the bar but does not replace network isolation |
| 3 | Unauthenticated push (identity = serial number + source IP) | Allowed only if the owner allows it (open question 8) and the company Admin explicitly accepts it per device |

**When a device cannot authenticate its requests (level 3)** the receiver does not trust any one identifier:
- the request must match **all** of: expected source IP, expected serial number, expected manufacturer protocol
  and path, registered device status `active`, and the device's expected agent;
- the company is asked to put devices on a **separate device VLAN/subnet** with static IP–MAC binding / port
  security on the switch; the Admin acknowledges this in the device setup;
- a known serial from a new IP, or a new serial from a known IP, is **quarantined** (punches held, device flagged
  "Suspect" in AttendOS) until HR/Admin confirms;
- every punch is stored with `source_auth = 'unauthenticated_lan'` and the register can filter on it;
- anomaly flags: punches for unmapped codes in bursts, times far from the device clock, sudden volume spikes.

**Request validation**
- Only the documented protocol paths and methods of the configured adapter; anything else → 404 and logged.
- Body ≤ 256 KB, ≤ 500 records per request, header and line length limits, request timeout 10 s, at most
  20 requests/min per device (configurable); over-limit → rejected and logged.
- Strict parser: unknown record types, template or photo uploads, and malformed lines are dropped and logged; the
  receiver never stores biometric templates or images.
- The receiver answers only the minimal protocol acknowledgements; it **never sends management commands** to devices
  (no user enrolment, deletion, template download, door control or firmware actions).

**Rejection logging**
Every rejected request: time, source IP, claimed serial, reason, size — in the agent's structured log (no payload
content), counted in the heartbeat, and summarised in AttendOS (`biometric_event_errors`, `auth_failure` /
`unsupported_format`). Repeated rejections mark the device "Suspect" and alert HR/Admin.

## 9. Runtime
The main agent service runs on a supported runtime only (.NET 10 LTS, support to 14 Nov 2028) and takes monthly
servicing updates. Vendor DLLs run in the isolated adapter host so a vulnerable or unstable vendor component cannot
reach the queue, the agent key or the network beyond its device.

## 10. Sync Agent queue and secrets
The local queue is encrypted with SQLCipher (official build); the queue key, the agent key and device credentials are
separate DPAPI blobs in the user scope of the agent's dedicated service account (not machine scope). Rotation,
recovery and crypto-shredding on removal: BIOMETRIC_SYNC_AGENT.md §7.

## 11. Network
Machines stay on the private LAN, no port forwarding. Agent: outbound HTTPS only (443) to the Supabase project
domain. Direct device-to-cloud push is excluded until decided (D6), because many machines identify themselves only
by serial number in that mode and some firmware sends plain HTTP — to be verified per model before any use.
