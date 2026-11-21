# AttendOS Biometric B5 (revision 2) — eSSL-first Sync Agent architecture

Status: **DESIGN ONLY — for owner review.** No code, migration, hosted SQL, eSSL software install or device
connection. Date 21 Nov 2026. Branch `feature/biometric-b1` (design documents only).

**Revision 3 (X2008 + DAT import): BIOMETRIC_B5_REV3_DESIGN.md takes precedence where the two differ.**

**Owner decision recorded:** eSSL is the first hardware manufacturer. Model and firmware are not known yet.

This revision builds on BIOMETRIC_B5_SYNC_AGENT_DESIGN.md (revision 1, commit `a1b4773`). Revision 1 still holds
for the generic agent parts it describes: Windows Service lifecycle, folders, upgrade and rollback, logging,
multi-company isolation, and the API contract. Where the two differ, **this document wins**. The new findings are:

- the eSSL research;
- a payload rule that the gateway's conflict check forces on us (§4.3);
- the eSSL adapter specification and test plan;
- a reordered roadmap.

**Evidence labels used throughout:**
- **official** — eSSL's own site or documents.
- **ZK-official** — ZKTeco documents. eSSL devices are widely reported to run ZKTeco firmware, but that is a
  third-party claim for any given eSSL model.
- **third-party** — integrators, resellers, community.
- **unverified** — not yet tested on hardware.

Nothing in this document is hardware-verified.

---

## 0. What the code fixes for an eSSL adapter (inspected at `a1b4773`)

| Fact in code | Where | Effect on the eSSL design |
|---|---|---|
| `manufacturer` allows `essl`; `integration_method` is one of `sdk_pull`, `local_push`, `vendor_software`, `file_import`; `adapter_type` is free text `^[a-z0-9_.-]{1,40}$` | 0010 `biometric_devices` | eSSL devices are registered as `essl` with `adapter_type` `essl.sdk_pull` or `essl.adms_push`; no migration needed |
| `model` and `firmware_version` live on the **device row** (Admin-entered); the heartbeat stores only `reachable` and `clock_drift_s` | 0010, 0011 | per-event model is derived through `device_id`; the agent can't report firmware today → it compares and alerts locally ([E6]) |
| `employee_device_code` is **text** `^[A-Za-z0-9_-]{1,32}$` | 0010 raw events + mappings | leading zeros survive if the adapter never converts the code to a number (§4.2) |
| `device_local_time` is stored as the exact string sent, beside `device_timezone`, `punch_at` and server `received_at` | 0010 | the original device timestamp is never lost |
| fingerprint dedupe = SHA-256 of `code|local_time|direction|verification|occurrence` — **payload is not part of the key** | 0011 l.270 | re-reads are recognised whatever the payload holds |
| duplicate vs conflict = `biometric_content_hash(code, local, offset, direction, verification, payload)` — **payload is part of the hash** | 0011 l.110–115, 307–318 | **anything in `payload` that is not identical on every re-read turns duplicates into conflicts** (§4.3) |
| `agent_version` (≤ 40 chars) is stored per sync run, i.e. per batch | 0011 l.210, 223 | adapter version reaches AttendOS only through the batch's `agent_version` today ([E5]) |
| `source_auth = authenticated` only for `sdk_pull` + `device_auth = comm_key` | 0011 l.276 | **eSSL ADMS push punches are always `unauthenticated_lan` → flagged → individual HR acceptance** |
| every per-event rejection is written to `biometric_event_errors` with code, serial and local time | 0011 l.259–265 | rejected punches are visible to the Admin in AttendOS, not only in the agent |
| mappings are per device or company-wide, with validity dates, no overlaps | 0010 mappings, `biometric_resolve_mapping` | device replacement needs either company-wide mappings or re-created per-device mappings (§5.10) |
| ingest accepts only **active devices assigned to the calling agent**; heartbeat lists only those | 0011 | a replaced or disabled device's unsent events come back `unknown_device` → held locally (§5.10) |

---

## 1. eSSL compatibility investigation

### 1A. eSSL SDK / LAN pull

| Question | Finding | Evidence |
|---|---|---|
| Official SDK | eSSL's software page offers "Device Communication" and "Device Communication dll" downloads under SDK. No version, no bitness, no documentation, no licence text | official (esslsecurity.com/software) |
| What it is | community and integrator material shows eSSL devices driven with the ZKTeco COM library `zkemkeeper.dll` (e.g. eSSL MB160), registered with `regsvr32` into System32/SysWOW64 | third-party |
| C#/.NET | COM interop from C#/.NET is the usual route; eSSL also lists "eSSL 9000 Sdk (c-sharp)" (a different product family, not T&A terminals) | third-party / official listing |
| Device families | not published per model by eSSL. K30 Pro and X990 brochures mention an "SDK for desktop applications" or "Compatible Software & SDK" without naming it | official brochures |
| TCP/IP | client connects to the device on TCP (older models UDP) port 4370. Pull needs a route to the device's private IP (LAN or VPN) | third-party (integrator guide) |
| Comm Key | some firmwares answer the connect with "unauthorised" even with key 0, and need an explicit auth step; few simultaneous connections are allowed, so other software holding the connection blocks reads | third-party |
| Reading without deleting | in the ZKTeco SDK model, reading the log and clearing it are separate calls. The adapter reads only and **never** calls a clear, delete, user, enrol or template function. The same library also offers template download (`GetEnrollData`), which the adapter must never call | ZK-official SDK manuals (via document-sharing copies); unverified for the eSSL package |
| Transaction IDs / sequence | the classic log read returns code, time, status and verify mode, with **no stable record number**. Time-range reads exist in newer firmware but must be confirmed per model | ZK SDK manuals; unverified |
| Pagination | the SDK reads the whole log into memory, then the client iterates. There is no server-side paging, so 100,000 records means a full read each time unless time-range reads work | ZK SDK manuals; unverified |
| Offline devices / history | the device keeps its log up to capacity: K30 Pro 1,00,000 transactions (eSSL sheet; one reseller says 200,000); X990 1,00,000 (eSSL sheet) | official; third-party conflict noted |
| Windows dependencies | 32-bit COM registration, admin rights to install; companion DLLs | third-party; ZKTeco's public package is labelled 32-bit |
| Licensing / redistribution | **no terms published.** Redistributing `zkemkeeper.dll` inside the AttendOS installer needs written permission from eSSL (or ZKTeco) | official page has no licence text → [E3] |

**Assessment:** feasible and the only route the gateway can treat as `authenticated` today. Unknowns per model:
- which SDK build works;
- whether a stable record number or time-range read exists;
- Comm Key behaviour;
- licence terms.

### 1B. eSSL ADMS / push

| Question | Finding | Evidence |
|---|---|---|
| Which families | K30 Pro: "Push Data: Yes". X990: push data plus a "Web based Device Manager / e-Push server". Integrators configure X990 and eSSL AI Face terminals with ADMS. The AI Face range is described as eSSL's badge on the ZKTeco SpeedFace platform | official (K30 Pro, X990 sheets); third-party (ClockIt, Okfit) |
| Customer-controlled endpoint | yes: the device menu (Comm → ADMS / Cloud Server Setting) takes a server address or domain, a port and a proxy setting | third-party; ZK-official F18 manual |
| HTTP paths | `/iclock/cdata` (handshake and uploads), `/iclock/getrequest` (device asks for commands), `/iclock/devicecmd` (command results); many eSSL firmwares use `.aspx` variants | third-party |
| Methods / format | handshake is a GET to `cdata`; attendance (`ATTLOG`) is uploaded in batches of text lines; the server confirms each batch with `OK: <lines>`; each line has user PIN, time, status, verify mode, work code. Status is often `0`, so IN/OUT is often not available | third-party; full protocol document still needed from eSSL/ZKTeco |
| Authentication | ZKTeco lists "equipment access authentication mechanism" without describing it; in practice the device identifies itself by serial number only | ZK-official feature list; third-party |
| HTTPS | ZKTeco's push protocol lists "Support HTTPS"; a ZK-OEM ADMS menu shows "Enable Https". An integrator reports eSSL machines using plain HTTP and not following redirects to HTTPS | ZK-official; third-party (TimeMoto, Prism) → **per firmware, unverified** |
| LAN-only receiver | possible in principle: the device only needs a reachable address. Integrators sell "local, no-internet" ADMS engines | third-party |
| Retry behaviour | the device keeps an upload pointer (`ATTLOGStamp`), advances it only when the server answers `OK`, and sends the backlog in date order. A missing or malformed answer makes it resend the same batch, which can loop. An observed rate was 128 punches per request every 3 s. The server can ask for a full re-upload. **No documented backoff or outage behaviour** | third-party |
| Device configuration | Comm → ADMS: domain on/off, server address, port, proxy off; correct gateway and DNS; restart after changes; device clock must be right | third-party |
| Storage overflow | ZKTeco push devices can "automatically delete the oldest data" when the log or photo storage overflows (amount configurable) | ZK-official feature list → **risk of silent loss on the device itself** (§5.9) |
| Commands | `getrequest` is how a server sends commands to the device (in ePushServer: clear logs, change IP, upload users and templates). **The AttendOS receiver never sends a command** | third-party; ePushServer manual |

**Assessment:** feasible for collection, with three costs:
1. Plain HTTP on the LAN unless the firmware does HTTPS.
2. Serial-number-only identity, so every punch is flagged under the current gateway ([D5]).
3. Device-side overflow deletion must be checked and disabled where possible.

### 1C. eSSL ePushServer and vendor software

| Question | Finding | Evidence |
|---|---|---|
| What it is | eSSL's own push server: a Java 1.8 web application on Tomcat with MS SQL Server, MySQL, Oracle or PostgreSQL; x64/x86 one-click installers; default login root/root | official download page; ePushServer user manual (document-sharing copy) |
| Required for some models? | **no evidence that any model requires it.** The X990 sheet lists it as one option; third parties point X990 devices directly at their own ADMS servers | official + third-party |
| Documented integration interface | **none found.** The manual says it "can integrate easily" but documents no API; logs go to a table per month and year | manual |
| Biometric data | it uploads fingerprint templates and attendance photos from devices into its database, and can send clear-log and enrolment commands | manual |
| Licensing | not stated on the download page; resellers quote "custom" licences | official page; third-party |
| eTimeTrackLite | eSSL's T&A software (desktop: MS Access / SQL Server Express; web: SQL Server). Integrators read its database or a "parallel database" copy. Resellers quote ₹15,000–35,000 a year for the web licence | official product page; third-party |

**Assessment: AttendOS integrates directly; no eSSL server software is needed or recommended.** ePushServer would add:
- a second database holding templates and photos (against the AttendOS rule);
- default credentials;
- an undocumented schema;
- an old Java/Tomcat stack;
- a second party sending commands to the devices.

An `essl.etimetracklite` read-only adapter stays a fallback for a site that already runs eTimeTrackLite and won't
change ([E4]). An ePushServer adapter is not planned.

---

## 2. eSSL compatibility matrix (research examples — not customer hardware)

| Attribute | **K30 Pro** | **X990** | eSSL AI Face series (Mars, Jupiter …) | Any eSSL model behind eTimeTrackLite |
|---|---|---|---|---|
| Model | fingerprint + card; 2,000 users; 1,00,000 transactions | fingerprint + card; 10,000 templates; 1,00,000 transactions; sold in variants (+ID, Wi-Fi, A) | face terminals | any |
| Firmware requirements | not published ("Algorithm Ver 10" is not firmware) | not published | not published | — |
| Communication method | TCP/IP, USB-host (official) | TCP/IP, USB; Wi-Fi/GPRS optional (official) | TCP/IP, Wi-Fi (third-party) | vendor database |
| SDK availability | "Compatible Software & SDK" named, SDK not named (official) | "SDK for desktop applications" (official) | unknown | — |
| Push support | "Push Data: Yes" (official); ADMS by name: third-party | push data + "e-Push server" (official); ADMS set-up: third-party | ADMS (third-party) | — |
| LAN pull support | via SDK, TCP 4370 (third-party) | via SDK (third-party) | unknown | — |
| Agent requirements | x86 adapter host + SDK (pull) or LAN receiver (push) | same | LAN receiver | `essl.etimetracklite` (not planned) |
| Network requirements | static IP; device VLAN; agent PC on the same LAN | same | same | DB access on the eTTL server |
| Licensing | SDK terms unknown | SDK terms unknown | — | eTTL licence |
| Known limitations | Wi-Fi not listed; meaning of status/direction unknown; log record number unknown | confirm the exact variant; same unknowns as K30 Pro | the agent must never request photos | depends on eSSL software |
| Evidence / source | eSSL K30 Pro sheet; resellers | eSSL X990 sheet; ClockIt; Okfit | ClockIt | integrators |
| Verification status | **documented (partial) — unverified** | **documented (partial) — unverified** | third-party claim | not planned |

Cells are filled only from the evidence cited. A blank or "unknown" means no evidence was found. **Status becomes
"hardware-verified" only for the exact model + firmware tested in M9.**

---

## 3. Agent architecture (baseline retained)

Unchanged from revision 1:
- .NET 10 LTS Windows Service (virtual account);
- SQLCipher queue with a DPAPI-protected key;
- outbound HTTPS 443 only, anon RPC with the agent key in the POST body;
- no service-role key, no database password;
- manufacturer adapters behind one interface; mock adapters first;
- heartbeat, backoff, diagnostics, signed MSI.

### 3.1 Network and security diagram (eSSL)

```
                       Device VLAN / subnet (e.g. 10.20.30.0/24), no internet route
 ┌──────────────┐                                         ┌────────────────────────────────────────────────┐
 │ eSSL device  │  pull: agent → device TCP 4370          │ Agent PC (Windows, on the device VLAN or routed)│
 │ (SDK mode)   │◄────────────────────────────────────────│                                                │
 └──────────────┘   Comm Key required (device_auth)      │  AttendOS.Agent.Service (x64)                  │
                                                          │   ├─ queue (SQLCipher, DPAPI key)              │
 ┌──────────────┐  push: device → agent                   │   ├─ ADMS receiver: http(s)://10.20.30.5:8081  │
 │ eSSL device  │────────────────────────────────────────►│   │   bound to ONE LAN IP, firewall scope =    │
 │ (ADMS mode)  │   /iclock/cdata, /getrequest only       │   │   registered device IPs; never 0.0.0.0     │
 └──────────────┘   serial + source IP checked            │   └─ uploader / heartbeat ──────────────┐      │
                                                          │  AttendOS.Agent.AdapterHost (x86)       │      │
   Switch: port security / MAC binding for device ports   │   └─ zkemkeeper COM (no internet egress)│      │
                                                          └─────────────────────────────────────────┼──────┘
                                                                                                    │ HTTPS 443
                                        Office firewall: outbound 443 to <project>.supabase.co only │ (outbound)
                                        No inbound rule. No port forwarding. No UPnP.               ▼
                                                                         ┌───────────────────────────────┐
                                                                         │ Supabase (Mumbai) PostgREST   │
                                                                         │ rpc/biometric_heartbeat       │
                                                                         │ rpc/biometric_ingest          │
                                                                         └───────────────────────────────┘
```

**Rules for the eSSL receiver:**
1. **LAN-restricted.** It listens on one private address. The installer refuses public or unknown addresses. A
   firewall rule is scoped to the registered device IPs. The device ports (4370, the receiver port) are never
   exposed to the internet.
2. **Identity checks on every request:** source IP, the `SN` parameter and the path must all match an active
   `essl` device of this agent that is set up for push. Anything else is quarantined.
3. **Optional per-device secret:** only if the firmware supports HTTPS or the documented device authentication
   mechanism; to verify on hardware ([E7]).
4. **Data only, never commands.**
   - The receiver answers `getrequest` with `OK` and no command, ever.
   - The handshake asks the device to send attendance logs only, never users, templates (`OPERLOG`/`BIODATA`)
     or photos. The exact option names come from the official protocol document, which M5 requires.
   - Records of any other table type are dropped before they reach the queue.
5. **Protocol exactness:** the receiver answers each `ATTLOG` batch with `OK: <n>` **only after** the batch is
   committed to the queue. A malformed batch gets an error. The device then keeps its pointer and resends, so
   nothing is lost; the receiver tracks repeats to detect loops.
6. **Limits:**
   - 256 KB per request, 20 requests per minute per device, 10 s read timeout;
   - HTTP 503 when the queue is at its cap, so the device keeps the records.

### 3.2 Component additions for eSSL

| Component | Process | Responsibility |
|---|---|---|
| `EsslSdkAdapter` (`essl.sdk_pull`) | x86 adapter host | connect with Comm Key; read device info and clock; read attendance log (full or time-range); return records as strings; never write |
| `EsslAdmsAdapter` (`essl.adms_push`) | main service | parse `cdata` requests from the receiver; `ATTLOG` lines → `DeviceRecord`; remember each device's last handshake and its options |
| `EsslModelProfile` | data file shipped with the agent | per model + firmware: SDK or ADMS, state-code → in/out table (off by default), verify-code → method names, stable-sequence flag, log capacity, overflow behaviour — every entry with its evidence and status |

---

## 4. Event normalization specification

### 4.1 Common event (agent queue) and where each field goes

| Field | Meaning | eSSL source | Agent queue | Sent to gateway as | Stored in AttendOS |
|---|---|---|---|---|---|
| Manufacturer | `essl` | device registry | `manufacturer` | `manufacturer` | `biometric_devices.manufacturer` via `device_id` |
| Model | e.g. `K30 Pro` | registry (Admin); device-reported model compared locally | `model_reported` | not sent per event | `biometric_devices.model` via `device_id` |
| Device serial | device `SN` | SDK serial read / ADMS `SN` | `serial` | `serial` | device row |
| Device user code | PIN exactly as the device prints it, **leading zeros kept** | SDK string API / ADMS line field 1 | `employee_code` (text) | `employee_code` | `employee_device_code` (text) |
| Device event ID / sequence | only if the model profile marks it stable | SDK record index if verified | `external_event_id`, `record_seq` | `event_id` / `record_seq` (else omitted) | same columns |
| Occurrence | 1, 2 … for identical records, in device order | Normalizer | `occurrence` | `occurrence` | `occurrence` |
| Original device timestamp | `YYYY-MM-DD HH:MM:SS` as the device printed it | SDK fields formatted without conversion / ADMS line field 2 verbatim | `local_time` | `local_time` | `device_local_time` (never altered) |
| Device time zone | IANA zone of the device | registry `timezone`; an offset is sent only if the device itself states one | `timezone` (from work list) | `utc_offset` only when stated | `device_timezone`, `device_utc_offset` |
| Punch direction | `in`/`out` only when reliable | status code mapped **only** if the device's `direction_mode = device` **and** the model profile's mapping is verified | `direction` | `direction` or omitted | `direction`, `direction_source` |
| Original vendor event type | raw status, verify and work codes as strings | SDK / ADMS fields 3–5 | `vendor_status`, `vendor_verify`, `vendor_workcode` | `payload.essl` (§4.3) | `raw_payload` |
| Verification | normalised method | verify code → `fingerprint`, `card`, `password`, `face` … by the model profile; unknown → omitted | `verification` | `verification` | `verification_method` |
| Received timestamp | when the agent captured the record (agent UTC, server-corrected) | agent clock | `captured_at`, `agent_clock_skew_ms` | **not sent per event** (§4.3) | server `received_at` per event; sync run time |
| Adapter version | e.g. `essl.adms_push/1.0.0` | adapter | `adapter_id`, `adapter_version` | batch `agent_version`, e.g. `1.0.0 essl.adms/1.0.0` (≤ 40 chars) | `biometric_sync_runs.agent_version` |
| Trust classification | agent's view: `pull_comm_key`, `pull_no_key`, `push_verified_sender`, `quarantined` | agent | `trust_class` | `source_auth: unauthenticated_lan` for anything not pulled with Comm Key | `source_auth` (gateway decides) |

### 4.2 Rules

1. **The device user code is a string from capture to storage.**
   - Never parse it to an integer: `"0042"` stays `"0042"`.
   - SDK functions with integer enrolment numbers are not used.
   - A code outside `[A-Za-z0-9_-]{1,32}` is never changed. It is sent as read, so the gateway rejects it
     (`unsupported_format`) and **records the rejection in AttendOS** (`biometric_event_errors`, with code, serial and
     time). The agent keeps it as `rejected` (90 days, exportable) and raises an alert. This replaces revision 1's
     "hold locally" proposal for [D9b], because a server-side record is visible to the Admin.
2. **A device user code is not an AttendOS employee.** It becomes a person only through an Admin mapping valid at
   the punch time. An unmapped code is stored as `unmatched` and goes to the review queue. The agent knows no names.
3. **The original timestamp is never discarded or rewritten.**
   - No time-zone conversion, rounding or drift correction.
   - Drift is reported separately (`clock_drift_s`).
4. **Direction is never guessed.** `status = 0` and unknown codes → no direction. The raw status is still kept in
   the payload.
5. **No biometric data.**
   - The adapters never call template, photo or user-download functions.
   - The receiver never asks for them, and drops any such record.
   - The gateway rejects payload keys matching `template|finger|face|photo|image|picture|palm|iris|vein|biodata`.
   - Payload keys are therefore named `status`, `verify` and `workcode` — not `finger…`.

### 4.3 Payload rule forced by the gateway (new finding)

The gateway's duplicate test hashes the payload (0011 `biometric_content_hash`). The dedupe key itself does not use
the payload. So if a re-read of the same punch carries a payload that differs in any way, the gateway records a
**conflict** instead of a duplicate. Therefore:

- `payload` holds **only values the device itself produced**, as strings, in a fixed schema:
  `{"essl": {"v": 1, "status": "0", "verify": "1", "workcode": "0"}}` (keys present only when the device sent them).
- **Never in `payload`:**
  - capture or receive time;
  - adapter or agent version;
  - batch numbers, agent ids;
  - "pull" vs "push";
  - anything else from the agent.

  These go to the local queue and the batch `agent_version`.
- The schema is frozen as `essl/1`. Changing it is a contract change with its own approval. Old and new records of the
  same punch would otherwise conflict.
- **SDK and ADMS must produce the identical payload for the same punch.** If a device is moved from pull to push, a
  re-delivered punch must still be a duplicate. This is verified in M9 (pilot test P2.6). If the two routes report
  verify codes differently, the model profile normalises both to the device's ADMS form.

---

## 5. Offline and recovery design (eSSL)

| # | Case | SDK pull device | ADMS push device | Guarantee |
|---|---|---|---|---|
| 5.1 | **24–72 h without internet** | reading continues into the queue (device log + local queue = two copies) | receiver keeps accepting and answering `OK` after commit; the device's pointer advances | queue holds about 18k events / 72 h for 1,000 staff (≈ 18 MB); drains oldest first at ≤ 6,000/min after reconnection; alert after 24 h offline because events older than 2 days need HR acceptance (`late_backfill`); 31-day hard limit → `expired`, kept and exportable |
| 5.2 | **Device disconnection** | worker backs off (1 s → 5 min), reports `reachable=false`; on return reads from the last confirmed position minus overlap | the device can't reach the receiver; it keeps records and resends from its pointer when back | the device log is the buffer; gap alert if the device was unreachable longer than its log can hold (§5.9) |
| 5.3 | **Agent restart** | re-read from the confirmed cursor with overlap; dedupe absorbs repeats | during the restart the device gets no answer → keeps its pointer → resends | `OK` is sent only after commit, so no acknowledged record can be lost |
| 5.4 | **Windows restart** | as 5.3; the service starts automatically (delayed) | as 5.3 | `synchronous=FULL` + WAL; in-flight batches resent with the same `batch_id` |
| 5.5 | **Partial batch upload** | per-event outcomes: stored, duplicate, conflict, rejected-with-reason → local terminal states | same | every event ends terminal **with a reason**; nothing is re-sent blindly |
| 5.6 | **Duplicate events** | local unique key; overlap re-reads; gateway fingerprint dedupe; possible-duplicate review for double presses (60 s) | device re-sends on missing `OK`; receiver dedupes on the local key and still answers `OK`; loop detector alerts after 5 identical resends | duplicates never create a second punch |
| 5.7 | **Repeated historical downloads** | full or time-range re-reads land on existing rows (local unique key) → nothing new is queued | a full re-upload (pointer reset) behaves the same; the agent never asks for one except via the support command `resend-since` | idempotent at every layer |
| 5.8 | **Device clock drift** | device clock read every 15 min; drift reported per device; > 300 s flagged by the gateway; **the agent never sets the device clock** (that is a write; site staff fix it) [E9] | drift estimated from punch time vs receive time for fresh punches (median of the last 20 within 2 min of capture) | times stay as recorded; fast clocks beyond 120 s are held until valid (D8), never dropped |
| 5.9 | **Device storage approaching capacity** | log count vs capacity from the device or model profile; warning at 80 %, alert at 95 %; a falling count or a missing older range = wrap or clear → `suspected_gap_from` | capacity not readable over ADMS → model-profile capacity and a daily punch-rate estimate; **installer checks and turns off "delete oldest on overflow" where the firmware allows** (hardware checklist) | loss on the device itself is detected and reported, never hidden; the agent can't recover what the device has already deleted |
| 5.10 | **Device replacement** | new device = new serial = new device row; keep the **old device active** until its queue drains (status shows "0 waiting"), then the Admin disables it; mappings: company-wide mappings carry over, per-device mappings must be re-created for the new device with `valid_from` = install time | same; the new device's ADMS settings point to the same receiver | events of a disabled device come back `unknown_device` → held locally, released if re-enabled, or exported/discarded by an Admin with a reason |
| 5.11 | **Credential rotation** | **agent key:** Admin rotates, the old key works 24 h, `set-key` tests before switching; expired → Blocked, collection continues. **Comm Key change on the device:** `auth_failed`, records stay on the device, `set-device-secret` resumes from the cursor | agent key as for pull; push devices have no secret today (per-device secret only if the firmware supports it, [E7]) | nothing is read without valid credentials, and nothing collected is deleted |

---

## 6. eSSL adapter interface specification

Both eSSL adapters implement revision 1's `IBiometricAdapter`, with these eSSL-specific contracts:

```csharp
// essl.sdk_pull — runs in the x86 adapter host; called over the named pipe
interface IEsslSdkSession : IAsyncDisposable
{
    Task<ConnectResult> ConnectAsync(string ip, int port /*4370*/, int? commKey, TimeSpan timeout, CancellationToken ct);
    Task<EsslDeviceInfo> ReadInfoAsync(CancellationToken ct);       // serial, model text, firmware text, device clock text, log count, capacity if exposed
    IAsyncEnumerable<EsslLogRecord> ReadLogAsync(EsslReadMode mode, // Full | TimeRange(from,to) if the profile says supported
                                                 CancellationToken ct);
    // No other device operations exist on this interface: no clear, delete, set time, user, enrol, template, photo, door.
}

public sealed record EsslLogRecord(string Pin, string Time, string Status, string Verify, string? WorkCode,
                                   long? DeviceIndex); // DeviceIndex only when the profile marks it stable

// essl.adms_push — runs in the main service, fed by the LAN receiver
interface IEsslAdmsParser
{
    HandshakeAnswer Handshake(AdmsRequest req);   // returns ONLY the attendance-log options; never user/template/photo upload
    ParseResult ParseAttlog(AdmsRequest req);     // lines → EsslLogRecord list, or a typed error (no partial acceptance of a batch)
    string AnswerGetRequest();                    // always "OK" — no commands, ever
}
```

**Cursor:**
- **SDK:** the cursor is the highest `(time, occurrence)` confirmed terminal. Each poll re-reads an overlap: the last
  50 records or 10 minutes, whichever is larger. Time-range reads are used only where verified; otherwise a full read
  plus local dedupe, limited to once every 5 min on large logs.
- **ADMS:** the device owns the pointer; the agent stores the last accepted batch per device for loop detection.

**Errors:** `unreachable`, `auth_failed` (Comm Key), `busy` (another program connected), `timeout`, `protocol_error`,
`unsupported_model`, `log_wrapped`, `sdk_crash` (host restarted), `quarantine`.

**Polling:** 60 s default per device (30 s–15 min). One connection at a time per device, released after each read,
so eSSL's own tools still work when a technician needs them.

---

## 7. Local encrypted queue specification

Revision 1 §8 applies (SQLCipher, WAL, `synchronous=FULL`, immutable batches, retention, 2 GB cap, corruption
handling). eSSL changes to the `event` table:

```sql
-- added columns (schema v1, nothing existing changes)
model_reported   text,                 -- what the device said, for the mismatch alert
adapter_id       text not null,        -- 'essl.sdk_pull' | 'essl.adms_push' | 'mock.essl_*'
adapter_version  text not null,
vendor_status    text, vendor_verify text, vendor_workcode text,   -- raw strings; also the payload source
trust_class      text not null check (trust_class in ('pull_comm_key','pull_no_key','push_verified_sender','quarantined')),
received_via     text not null check (received_via in ('sdk_read','adms_push'))
-- local unique key stays (device_key, content_hash, occurrence); content_hash covers code, local_time, direction,
-- verification and the payload — the same inputs as the gateway's hash, so local and server dedupe agree
```

Plus a small `adms_batch` table: device, a hash of the received body, line count, `acked_at`, repeat count. It is
used for loop detection and to answer a repeated batch with `OK` without storing anything twice.

Batches sent to AttendOS never mix adapter versions, so the batch's `agent_version` identifies the adapter for every
event in it.

---

## 8. Failure and recovery matrix

The eSSL-specific matrix is §5. The generic rows in revision 1 §23 (gateway down, crash, throttling, expired key,
disk full, corrupt queue, removed device) still apply.

---

## 9. Mock-device test plan (before any hardware)

**Mocks:**
- `mock.essl_pull`: an in-process SDK-session fake with a scripted log. It supports full and time-range reads,
  wrap, clear, reboot, Comm Key and busy.
- `mock.essl_adms`: an HTTP client that behaves like a device toward the receiver. It handshakes, sends `ATTLOG`
  batches of 1–128 lines, keeps a pointer, resends on a missing or bad `OK`, and supports the `.aspx` paths.

Both are registered as manufacturer `mock` and are labelled mock everywhere. They run against the local stack
(PostgreSQL + 0010–0012 + PostgREST), with FaultProxy between the agent and PostgREST.

**Invariant checked after every test:**
- every mock record is either a raw event in AttendOS, or a local terminal row with a reason;
- counts are exact;
- no punch appears twice;
- no forbidden key is ever sent.

| Test | Set-up | Acceptance criteria |
|---|---|---|
| **T1** Mock device records | 500 records, 40 codes incl. `0007` and `007` | 500 raw events; `0007` and `007` stored as different codes; original time strings byte-identical; payload `essl/1` only |
| **T2** Pagination / large logs | 100,000-record log; full read and time-range read; ADMS backlog in 128-line batches | all records captured once; memory under 300 MB in the host; upload batches ≤ 200 events and ≤ 256 KB; drain ≤ 20 min |
| **T3** Duplicate delivery | every record read 3× (overlap) and every ADMS batch sent twice | zero additional raw events; gateway duplicates equal the resends; **zero conflicts** |
| **T4** Delayed historical records | records 1, 5, 30 and 32 days old arriving after newer ones | ≤ 2 days: stored; 3–31 days: stored with `late_backfill`; > 31 days: `expired` locally with export; none missing |
| **T5** Invalid employee codes | codes `""`, `"A B"`, 33 characters, `"९१"` | each `rejected unsupported_format` with an error row in AttendOS; local `rejected` row kept and exportable; alert raised; code never altered by the agent; valid neighbours in the same batch stored |
| **T6** Invalid timestamps | `2026-02-30 10:00:00`, `24:00:00`, empty, a 5-minute-fast clock | impossible dates: `rejected invalid_time` with an error row in AttendOS, string never altered; fast clock: `held_future` then stored with drift flag |
| **T7** Missing direction | status `0`, unknown status, and a device with `direction_mode=device` + verified profile | no direction sent for `0`/unknown (raw status in payload); direction sent only in the verified case |
| **T8** Offline recovery | WAN blocked 72 h (scenario clock) while 18k punches arrive | collection uninterrupted; ADMS answered `OK` only after commit; full drain oldest-first after reconnection; offline alert after 24 h |
| **T9** Interrupted upload | connection cut after the request is sent, before the answer; process killed mid-batch | the same `batch_id` is resent; the gateway replays its answer; no duplicate raw events |
| **T10** Partial acceptance | one batch with valid, unmapped, unknown-device, too-old and future events | each event gets its own terminal or held state with the gateway's reason; batch `answered`; unmapped ones visible in AttendOS review |
| **T11** Agent restart | service killed during SDK read, during an ADMS batch before `OK`, and during upload | SDK resumes from the cursor; ADMS device resends (no `OK` was sent); invariant holds |
| **T12** Device clock drift | device clock +90 s, −400 s, +300 s | drift reported in heartbeat and batches; −400 s flagged by the gateway; device clock never written by the agent |
| **T13** Template / photo safety | mock device offers user, template and photo tables and a command request | the receiver never requests them, drops offered ones, answers `getrequest` with `OK` only; the SDK fake records zero template calls |
| **T14** Spoofed push | right serial from the wrong IP; unknown serial; wrong path; 2 MB body | quarantined or refused; nothing uploaded; alert |
| **T15** Device replacement | old device with 300 queued events; new serial added; old disabled too early | old events `held_unknown_device`, released when re-enabled; no loss |

---

## 10. Hardware purchase and verification checklist

**Before buying (ask the dealer or eSSL in writing):**
- [ ] Exact model and variant (e.g. "X990 + ID", "K30 Pro + Wi-Fi") and the **firmware version** it ships with.
- [ ] ADMS / Cloud Server menu present; can it point at a **private LAN IP and custom port**; is **HTTPS** available.
- [ ] SDK pull over TCP/IP supported for this firmware; **which SDK build**; written **licence/redistribution terms**.
- [ ] Comm Key setting available.
- [ ] Log capacity, and whether the device **deletes the oldest records when full** (and whether that can be turned off).
- [ ] Whether the log has a record number that survives reboot.
- [ ] The **official push protocol document** for this firmware (eSSL or ZKTeco), and who supports integration questions.
- [ ] That no eSSL server software is required for the features we use.

**Bench verification (M9, isolated switch, test company only):**
- [ ] P1 Identity: serial, model and firmware read; matches the label and the registry entry.
- [ ] P2 Pull:
  - read with and without Comm Key;
  - record fields (PIN with leading zeros, time string, status, verify, work code);
  - time-range read;
  - record number stability across reboot;
  - log read does not change the device's log count.
- [ ] P3 Push:
  - handshake and upload paths;
  - `.aspx` variant;
  - HTTPS on/off;
  - pointer behaviour after a missed `OK`;
  - behaviour when the receiver is down for 1 h and for 24 h;
  - what is sent for each table type.
- [ ] P4 Direction: meaning of each status code when staff press the In/Out keys; record in the model profile.
- [ ] P5 Clock: drift reading; behaviour at a 5-minute-fast clock.
- [ ] P6 Pull ↔ push: the same punch delivered by both routes is a duplicate, not a conflict (§4.3).
- [ ] P7 Capacity: fill towards the limit (or use a test log); overflow behaviour; gap detection.
- [ ] P8 Safety: no template or photo traffic observed (packet capture on the device VLAN).
- [ ] Result recorded in BIOMETRIC_HARDWARE_COMPATIBILITY.md for **that model + firmware only**.

---

## 11. Phased implementation plan

Each milestone needs separate approval and stops for review. Milestones carried over from revision 1 keep their
scope, files and security requirements; the eSSL milestones are spelled out here.

| Milestone | Scope | Dependencies | Security requirements | Tests | Acceptance | Risks |
|---|---|---|---|---|---|---|
| **M0** Decisions | §12 decisions; freeze payload `essl/1` and the API contract | owner | — | — | approval recorded | — |
| **M1** Skeleton | service host, settings, logging, CI (rev 1) | M0, .NET 10 | redaction tests | unit, start/stop | as rev 1 | CI runner |
| **M2** Queue + secrets | SQLCipher schema v1 incl. §7 columns, DPAPI (rev 1) | D2 licence | rev 1 | rev 1 + new columns | rev 1 | licence delay |
| **M3** Gateway client | heartbeat, immutable batches, outcomes, backoff; `agent_version` carries the adapter version | M2, local stack | key only in body | rev 1 contract tests | rev 1 | — |
| **M4** Mock eSSL adapters | `mock.essl_pull`, `mock.essl_adms`, Normalizer (string codes, `essl/1` payload, occurrence), scheduler, cursors | M3 | no forbidden keys reachable | **T1–T15** | all §9 criteria with database evidence | mock realism |
| **M5** ADMS LAN receiver | Kestrel on one LAN IP, `cdata`/`getrequest` with `.aspx`, identity checks, quarantine, `OK` after commit, loop detection, firewall rule | M4; **official push protocol document** [E8] | §3.1 rules 1–6; parser fuzzing | T3, T8, T11, T13, T14 + fuzz | spoofing and template tests pass | firmware variations |
| **M6** Installer + CLI | rev 1 M6 plus device-VLAN checks and an eSSL set-up guide (ADMS menu values, Comm Key) | D3 signing | rev 1 | rev 1 | install < 15 min | SmartScreen |
| **M7** Admin agent screens | register/rotate/revoke agent, assign devices, `device_auth` (app change) | separate approval | key shown once | B4-style | rev 1 | — |
| **M8** eSSL SDK adapter | x86 host, `IEsslSdkSession` over `zkemkeeper` (official package), model profile file | [E3] licence; SDK package | host isolation; read-only interface; DLL hashes recorded | contract suite on recorded fixtures; host crash | no hardware claims | COM under .NET 10 x86 (fallback .NET Framework 4.8.1) |
| **M9** Bench verification | §10 P1–P8 on the purchased device | device bought [E1]; staging target [D18] | isolated switch; test company | P1–P8 | model profile filled; status "hardware-verified" for that model + firmware | firmware surprises |
| **M10** Pilot | one site, 2 weeks, projection off; daily reconciliation | M9; owner approval | — | reconciliation | 100 % of device records accounted for | — |
| **M11** ZKTeco | reuse the eSSL adapters with a ZKTeco profile | M9 | same | contract + bench | — | — |
| **M12** Matrix | COSEC adapters (rev 1 §6) | device + documents | same | — | — | — |

Rough effort: M1–M4 about 4–6 weeks, M5–M6 about 2–3 weeks, M8 about 2 weeks, M9 about 1 week on site. These are
planning figures only.

---

## 12. Decisions requiring owner approval

New eSSL decisions (E). Revision 1's decisions still open are D2, D3, D4, D5, D6, D7, D8, D9b, D12–D20 (D9 is now
answered: eSSL).

| # | Decision | Options | Recommendation |
|---|---|---|---|
| **E1** | Which eSSL unit to buy for the bench test (M9) | K30 Pro (about ₹5,000–6,500 at resellers) · X990 (about ₹9,500–15,500) · a model the first customer already owns | a unit whose dealer confirms **both** ADMS to a private IP **and** SDK pull in writing; if the first customer has devices, test that model first |
| **E2** | Integration route for the first pilot | SDK pull (only route that can be `authenticated`) · ADMS push (every punch flagged under today's gateway) · both | **pull first**; push built and tested in parallel, used only where pull is impossible |
| **E3** | eSSL SDK licence | obtain written redistribution terms · ask the customer to install the eSSL SDK themselves (agent loads, never ships it) | written terms; fallback: customer-installed SDK |
| **E4** | ePushServer / eTimeTrackLite | never depend on them (direct integration) · eTTL read-only fallback adapter on request | never ePushServer; eTTL only for a site that insists |
| **E5** | Recording the adapter version | batch `agent_version` string (no change) · new column per event (migration) | batch string now |
| **E6** | Model/firmware mismatch (device reports something different from the registry) | local alert only · report via heartbeat (needs D6 migration) | local alert now; heartbeat field with D6 |
| **E7** | Push device identity | IP + serial + VLAN only · additionally require HTTPS or a per-device secret where the firmware supports it | require it where supported; record "not supported" per model |
| **E8** | Official push protocol document | request from eSSL/ZKTeco before M5 · build M5 from integrator descriptions | **official document before M5** (no invented protocol support) |
| **E9** | Device clock | agent reports only (never writes) · allow an Admin-triggered "set device time" | report only — keeps every adapter read-only |
| **E10** | Payload schema `essl/1` | freeze as specified · include more raw fields | freeze; only device-produced strings |
| **E11** | Device overflow setting | installer turns off "delete oldest when full" where possible · leave the device default | turn off where possible; alert at 80 % regardless |
| **E12** | First-run history (D20 for eSSL) | read all device history · from an Admin-chosen cut-over date | cut-over date |

---

## 13. Sources

**Official eSSL**
- eSSL software downloads (SDK "Device Communication", ePush Server installers, default credentials): https://esslsecurity.com/software
- eSSL K30 Pro specification sheet: https://www.esslsecurity.com/storage/app/media/fingerprint/K30-Pro.pdf ; product page: https://www.esslsecurity.com/fingerprint/k30
- eSSL X990 specification sheet: https://dev.esslsecurity.com/storage/app/media/fingerprint/X990.pdf
- eSSL eTimeTrackLite Web integration: https://esslsecurity.com/etimetracklite-web-integration

**ZKTeco**
- ZKTeco General Introduction of PUSH SDK Protocol (HTTPS, device authentication, overflow deletion): https://cdn.tvc.mx/media/92189/General-Introduction-of-PUSH-SDK-Protocol.pdf
- ZKTeco F18 manual, Comm Key and Cloud Server settings: https://www.manualslib.com/manual/3008180/Zkteco-F18.html?page=33

**Third party**
- ADMS paths, `OK` acknowledgement, ATTLOGStamp, resend behaviour, port 4370, Comm Key: https://prisminfoways.com/blog-single/essl-biometric-adms-push-integration-not-working-fix
- eSSL X990 ADMS configuration: https://get.clockit.io/essl/x990 ; https://okfit.tawk.help/article/how-to-configure-essl-x990
- eSSL AI Face series on the ZKTeco SpeedFace platform (claim): https://get.clockit.io/essl/aiface-mars
- ZK-OEM ADMS menu with HTTPS option: https://support.timemoto.com/en/articles/91
- eSSL MB160 with zkemkeeper (community): https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/tagged/zkemkeeper_page=2
- SDK registration (System32/SysWOW64): https://www.scribd.com/document/681142496/How-to-Register-the-SDK
- ePushServer user manual (Java 1.8, databases, commands, templates and photos): https://pdfcoffee.com/epush-server-user-manual-essl-pdf-free.html
- ePushServer community Docker set-up (Tomcat 7, MySQL 5): https://github.com/shreyasubale/epush-docker
- eTimeTrackLite database integration and editions: https://www.eyetechsecurities.in/essl-biometric-device-logs-parallel-database-integration.html ; https://www.eyetechsecurities.in/essl-etimetracklite-desktop-vs-web-comparison.html
- eSSL software price ranges (reseller): https://www.csplsoftware.com/essl-time-attendace-software.php
- K30 Pro price and 200,000-transaction claim (resellers): https://techjockey.com/detail/k30-pro ; https://fgtechstore.com/?p=80556
- X990 prices (resellers): https://m.indiamart.com/proddetail/essl-x990-time-attendance-access-control-card-fingerprint-id-password-21335518762.html

**Not yet obtained:** the official eSSL/ZKTeco push protocol document for a specific firmware, the eSSL SDK
documentation and licence terms, and firmware lists per model. Each is a precondition in §11.
