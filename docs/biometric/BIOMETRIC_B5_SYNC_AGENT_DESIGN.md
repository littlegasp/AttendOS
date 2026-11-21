# AttendOS Biometric B5 — Local Sync Agent: architecture and implementation plan

Status: **DESIGN ONLY — for owner review.** No code, migration, hosted operation or hardware connection is part of
this document. Date 21 Nov 2026. Branch `feature/biometric-b1` (design document only; base `5b7d32e`).

It replaces the B1 proposal (BIOMETRIC_SYNC_AGENT.md, BIOMETRIC_ADAPTER_DEVELOPMENT.md) where the two differ. The
B1 documents stay as history.

Where something needs a decision, it is marked **[Decision Dn]** and collected in §32.

---

## 0. What was inspected, and where the documents differ from the code

The design is based on the code as it is at `5b7d32e`, not on the earlier documents:

- **Migrations:** `0010_biometric_core.sql`, `0011_biometric_gateway.sql` (gateway: `biometric_ingest`,
  `biometric_heartbeat`, `biometric_set_device_auth`) and `0012_biometric_projection.sql`.
- **B4 app code:** `src/lib/biometric-live.ts`, `src/components/biometric/*`, `src/lib/permissions.ts`.
- **Test suites:** the HTTP tests `e2e/biometric_gateway_http.py` and `e2e/biometric_projection_http.py`, and the
  demo data `supabase/demo/biometric_demo.sql`.
- **Deployment:** Cloudflare serves the static frontend from `out/`; Supabase (Mumbai) holds data and auth; PostgREST
  exposes `/rest/v1/rpc/*`.

Each row below is a difference between the B1 documents and the code. **The code wins.**

| Topic | B1 document said | Implementation (0010/0011) | Effect on B5 |
|---|---|---|---|
| Batch limits | ≤ 500 events, ≤ 1 MB | **≤ 200 events, ≤ 256 KB** per call; ≤ 30 batches per agent per rolling minute | Batches of at most 200 events. Throughput ceiling 6,000 events/min |
| Heartbeat | every 5 min, with queue depth, cursors, errors | accepted at most every **30 s**; stores only `agent_version`, and per device `reachable` and `clock_drift_s`. **Everything else is ignored** | Queue depth, adapter errors and cursor state cannot reach AttendOS today → [Decision D6] |
| Key format | "8-char prefix" | `bak_<12 hex>_<43 base64url>` = **60 characters**; SHA-256 stored | Agent validates the format locally before storing a key |
| Rotation | agent writes new key with `set-key` | `biometric_rotate_agent_key` (Admin) issues a new key; **old keys expire after 24 h**. No agent self-rotation; **no B4 screen** for register/rotate/revoke | Admin screens needed (§20, M7); manual key hand-over |
| Direction source | adapter sends `device_key` / `device_fixed` / `none` | gateway derives `direction_source` = `device` if `direction` is present, else `none`; the agent **cannot** send it | Adapter sends `direction` only when the device record says in/out |
| Gateway outcomes | stored / duplicate / unmatched / rejected | per event: **stored** (with `status` stored, unmatched, flagged or possible_duplicate), **duplicate**, **conflict**, **rejected** (`reason`) | Outcome table in §24 |
| Error kinds | `auth_failure` for receiver rejections | no such kind; the agent has **no call** to report its own rejections | Kept in the local log only → [Decision D7] |
| Push trust | unauthenticated push allowed "per device" with Admin acceptance | `source_auth = authenticated` **only** for `sdk_pull` + `device_auth = comm_key`; every other punch is `unauthenticated_lan` and **flagged** → never projected without an **individual HR acceptance per punch** | Push devices can't feed attendance automatically today → [Decision D5] |
| Device config | stored in the agent | the **heartbeat answer** is the agent's work list: active devices assigned to it, with manufacturer, serial, model, method, adapter type, time zone, direction mode, `device_auth`, non-secret `connection` | Agent configuration is pulled from AttendOS; only secrets are local |
| Time window | — | `future_tolerance_s` 120, `backfill_days` 31, `drift_flag_s` 300, `auto_project_max_age_days` 2 (company settings) | Fast device clocks are rejected (§14); events older than 31 days are rejected `too_old` |
| Statement timeout | — | anon calls run under Supabase's short anon timeout (B3.1 assumed ≈ 3 s; 200-event batch measured ≈ 170 ms locally) | Adaptive batch size (§10); timeout handled as "not stored" |

Also found: the hosted project does **not** yet have migrations 0010–0012 (owner approval pending). Until it does, the
agent can only be run against the **local stack**, or a **staging** project if one is approved [Decision D18].

---

## 1. System architecture

### 1.1 Context

```
   Office LAN (private)                                     |  Internet (outbound HTTPS 443 only)
                                                            |
 ┌──────────────┐  LAN pull (TCP, vendor SDK)               |
 │ Biometric    │◄──────────────────────┐                   |
 │ device A     │                       │                   |
 └──────────────┘                ┌──────┴────────────────┐  |   ┌──────────────────────────────┐
 ┌──────────────┐  LAN push      │  AttendOS Sync Agent  │  |   │ Supabase (Mumbai)            │
 │ Biometric    │───────────────►│  (Windows Service on  │──┼──►│ PostgREST /rest/v1/rpc/      │
 │ device B     │  (to agent's   │   a company PC)       │  |   │  biometric_heartbeat (anon)  │
 └──────────────┘   LAN address  └───────────────────────┘  |   │  biometric_ingest    (anon)  │
                    only)                 ▲                 |   │ → raw events + state (0011)  │
                                          │ local admin CLI |   │ → projection (0012, when on) │
                                   (installer / support)    |   └──────────────┬───────────────┘
                                                            |                  │
                                                            |   ┌──────────────▼───────────────┐
                                                            |   │ AttendOS app (Cloudflare)    │
                                                            |   │ Admin/HR: devices, mapping,  │
                                                            |   │ review queue, sync activity  │
                                                            |   └──────────────────────────────┘
```

Nothing on the internet can open a connection to the agent or to a device. The agent's only internet traffic is
outbound HTTPS to the company's Supabase project.

### 1.2 Components inside the agent

```
┌─────────────────────────────── AttendOS.Agent.Service (x64, .NET 10, Windows Service) ──────────────────────────────┐
│                                                                                                                     │
│  Supervisor ─ starts/stops everything, watchdog, SCM status, graceful shutdown                                      │
│     │                                                                                                               │
│     ├── ConfigManager ── local settings (endpoint, publishable key, instance) + work list from heartbeat           │
│     ├── SecretStore ──── DPAPI blobs (queue key, agent key, device credentials), never logged                     │
│     ├── DeviceScheduler ─ one worker per device; pull interval, overlap re-read, backoff                           │
│     │      ├── in-process adapters: mock.*, zkteco.adms / essl.adms (push), matrix.* (HTTP), file.*               │
│     │      └── AdapterHostClient ──named pipe──► AttendOS.Agent.AdapterHost (x86) ── vendor COM SDK (zkemkeeper) │
│     ├── PushReceiver ──── Kestrel bound to ONE LAN address; per-device allow rules; quarantine                     │
│     ├── Normalizer ────── device record → standard event (string time, code, direction, verification, occurrence) │
│     ├── Queue (SQLCipher) ─ events, batches, batch items, cursors, device state, outcomes                          │
│     ├── Uploader ──────── builds immutable batches, POSTs biometric_ingest, applies per-event outcomes             │
│     ├── Heartbeat ─────── POSTs biometric_heartbeat every 60 s; refreshes work list; measures server time          │
│     ├── ClockMonitor ──── agent vs server clock, device vs agent clock → drift                                     │
│     ├── HealthReporter ── local status file + Windows Event Log + (later) telemetry [D6]                           │
│     └── Diagnostics ───── structured logs, redacted support bundle, local CLI                                      │
│                                                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
  AttendOS.Agent.Cli (x64): install-time and support commands, talking to the service over a local admin-only pipe.
```

### 1.3 Data flow of one punch

```
device log ─► adapter (read-only) ─► Normalizer ─► Queue: event row (state=captured)
                                                     │  same transaction: cursor advance is NOT done here
                                                     ▼
                                     Uploader picks oldest events (global oldest-first, fair per device)
                                                     │
                                  writes batch row + batch_items (batch_id fixed forever) ── commit
                                                     │
                                  POST /rest/v1/rpc/biometric_ingest {p_key, p_batch}
                                                     │
                     ┌───────────────────────────────┼────────────────────────────────────┐
                 2xx + ok:true                  2xx + ok:false / HTTP error / timeout     no answer
                     │                               │                                     │
     per-event outcome → event state           whole-batch handling (§10.3)          resend SAME batch_id
     (accepted / duplicate / conflict /                                               (gateway replays answer)
      rejected-<reason>); commit
                     │
     cursor of a pull device advances only past records whose events are terminal (§8.4)
                     │
     AttendOS: raw event + state → mapping at punch time → review queue / projection (0012)
```

---

## 2. Windows Service lifecycle and installation

### 2.1 Processes and identities

| Process | Bitness | Runs as | Network | Purpose |
|---|---|---|---|---|
| `AttendOS.Agent.Service` | x64 | virtual account `NT SERVICE\AttendOSAgent` (or `…$<instance>`) | outbound 443 to the project; LAN to devices; listener on one LAN IP only if a push device exists | everything except vendor COM SDKs |
| `AttendOS.Agent.AdapterHost` | x86 (or x64 if a 64-bit SDK proves stable) | same virtual account, started by the service as a child process with a job object (kill on parent exit) | LAN to its devices only (outbound blocked by firewall rule) | loads vendor DLLs; no secrets except the device credentials it is given over the pipe |
| `AttendOS.Agent.Cli` | x64 | the local administrator who runs it | none | install, set-key, status, support bundle |

- **Hosting:** `Microsoft.Extensions.Hosting.WindowsServices` (`UseWindowsService`) with a `BackgroundService`
  per component. The program is self-contained (no machine-wide .NET install).
- **Start type:** Automatic (Delayed Start), so the network is up first.
- **Recovery (SCM):** restart after 1 min, 1 min, 5 min; reset the failure count after 1 day.
- **Shutdown:** on SCM stop, stop polling, refuse new push requests (503), finish or abandon the in-flight HTTP
  request (a batch is safe either way, §10), checkpoint the WAL, close the database. Allow 30 s
  (`HostOptions.ShutdownTimeout`).
- **Start-up checks** (the service refuses to start, with an Event Log entry, if any fails): the queue opens with its
  key; the schema version is known; the data folder ACL is correct; the endpoint is HTTPS; the publishable key is
  present; the agent key is present and well-formed.

### 2.2 Folders

| Path | Contents | ACL |
|---|---|---|
| `C:\Program Files\AttendOS Agent\<version>\` | signed binaries, versioned side by side | Administrators: full; service: read/execute |
| `C:\ProgramData\AttendOS\Agent\<instance>\` | `queue.db` (+ `-wal`, `-shm`), `secrets\*.blob`, `settings.json`, `logs\` | SYSTEM + service account only (Administrators can take ownership for support) |

### 2.3 Lifecycle states (shown by `attendos-agent status` and in the heartbeat)

`Starting → Ready → Running`. From `Running` the agent can enter:

- `Degraded (device unreachable | offline | throttled)`
- `Blocked (key not accepted | clock unsafe | disk full)`

From any state it can go to `Stopping`. `Blocked` never deletes anything: collection continues where it is safe
(§9), and uploading pauses.

---

## 3. Device adapter interface and manufacturer abstraction

The B1 contract is kept, with these changes to match the gateway:

```csharp
public interface IBiometricAdapter : IAsyncDisposable
{
    AdapterInfo Info { get; }    // id ("zkteco.standalone_sdk"), manufacturer, methods, Capabilities flags
    Task<ConnectionResult> TestConnectionAsync(DeviceConfig cfg, DeviceSecrets secrets, CancellationToken ct);
    Task<DeviceInfo> GetDeviceInfoAsync(CancellationToken ct);          // model, serial, firmware, device clock text, log count/capacity if available
    Task<ReadResult> ReadAsync(ReadRequest req, CancellationToken ct);   // pull: records after cursor (with overlap), max N
    IAsyncEnumerable<PushedRecord> ReceiveAsync(CancellationToken ct);   // push: records handed over by the PushReceiver
    Task<DeviceStatus> GetStatusAsync(CancellationToken ct);
}

[Flags] public enum Capabilities { Pull = 1, Push = 2, Cursor = 4, DeviceClock = 8, DirectionKeys = 16, LogCapacity = 32,
                                   StableEventId = 64, StableRecordSeq = 128 }

public sealed record DeviceRecord(          // what an adapter returns — exactly what the device said
    string EmployeeDeviceCode,              // as on the device; never trimmed or re-padded
    string DeviceLocalTime,                 // "yyyy-MM-dd HH:mm:ss" as the device printed it
    string? UtcOffset,                      // only if the device states it ("+05:30")
    string? Direction,                      // "in" / "out" only when the record carries an explicit state; else null
    string? Verification,                   // lower-case token ("fingerprint", "face", "card", "password"), else null
    string? ExternalEventId, long? RecordSeq,
    string CursorToken,                     // opaque per-adapter position of this record
    IReadOnlyDictionary<string, JsonElement> Extra); // allow-listed non-biometric fields only (≤ 4 KB as JSON)
```

**Rules every adapter follows** (B1 §3 rules stay; new or changed ones in bold):

1. **Read-only.** Only documented interfaces. Never clear logs, enrol users, change settings, open doors, or
   download templates, photos or user tables.
2. **No biometric data leaves the adapter.** `Extra` is allow-listed per adapter (for example `workcode`,
   `state_raw`). Anything matching the gateway's forbidden-key pattern (`template|finger|face|photo|image|picture|
   palm|iris|vein|biodata`) is dropped. The adapter host strips again before returning.
3. **Time is a string.** Exactly as reported; no conversion, rounding or time-zone guessing.
4. **`Direction` only from an explicit record state.** The state-code → in/out mapping is per adapter and model,
   recorded in the compatibility matrix, and off by default until verified on hardware.
5. **`Occurrence` is assigned by the Normalizer, not the adapter:** among records with identical (code, local time,
   direction, verification) on one device, 1, 2, … in device log order. The rule is deterministic, so a re-read
   gives the same numbers.
6. **Typed errors:** `unreachable`, `auth_failed`, `timeout`, `protocol_error`, `unsupported_model`,
   `log_wrapped`, `sdk_crash`.
7. **`StableEventId` / `StableRecordSeq`** are declared only after hardware tests show they survive re-reads,
   reboots and log wrap. Until then the gateway's fingerprint basis is used (only `occurrence` is sent).

**Registered adapter ids:**

- `mock.pull`, `mock.push`
- `zkteco.standalone_sdk`, `zkteco.adms`
- `essl.standalone_sdk`, `essl.adms` (aliases of the ZKTeco adapters with eSSL model tables)
- `matrix.cosec_push`, `matrix.cosec_webapi`
- `file.csv` — later; imports are not projected yet (`import_not_enabled`).

The device's `adapter_type` from the work list selects the adapter. A device whose adapter is not installed is shown as
`unsupported_adapter` in local status (and in the heartbeat once [D6] is approved).

---

## 4. ZKTeco integration assessment

| Path | Mechanism | Evidence | Assessment |
|---|---|---|---|
| **Pull — Standalone SDK** | COM library `zkemkeeper.dll` with companion DLLs; TCP 4370 on the LAN; reads the attendance log | ZKTeco publishes the SDK (github.com/ZKTeco/Standalone-SDK). The public communication package is labelled **32-bit** (Ver 6.2.4.11); a third-party package of SDK 6.3.1.37 ships 32- and 64-bit folders, and a third-party NuGet wrapper claims x86/x64 COM interop | **Preferred first path.** Run in the x86 adapter host; 64-bit only after testing. It is the only path the gateway accepts as `authenticated` (`device_auth = comm_key`), so punches can be projected automatically |
| **Push — ADMS / PUSH SDK** | the device makes HTTP requests to a configured server (`/iclock/cdata` handshake and uploads, `/iclock/getrequest`); a "stamp" tracks what was sent | ZKTeco "General Introduction of PUSH SDK Protocol" (lists "Support HTTPS" and an "equipment access authentication mechanism" without details); attendance PUSH protocol v3.7 (2020) circulates via distributors | Supported as the second path, behind [D5]: under today's gateway every pushed punch is flagged for individual HR acceptance. Full protocol document needed from ZKTeco |
| Unofficial TCP clients (pyzk, openzk) | reverse-engineered 4370 protocol | community projects | **Not used** (B1 rule) unless the owner decides otherwise [D11] |

Facts to verify on hardware: whether the log state field is meaningful for the site; whether a record index exists and
is stable; log capacity and wrap behaviour; Comm Key behaviour (it is a number of up to 6 digits — raises the bar, does
not replace network isolation); device clock read; the SDK under .NET 10 x86 COM interop vs .NET Framework 4.8.1.

## 5. eSSL integration assessment

| Path | Mechanism | Evidence | Assessment |
|---|---|---|---|
| ZK-platform models (MB160, X990, K90, uFace, AiFace …) | same as ZKTeco: Standalone SDK pull, ADMS push ("Cloud Server" setting) | integrators and cloud T&A vendors document eSSL MB160 ADMS set-up; eSSL itself does not publish the protocol | **Per model, third-party claim.** Treat as ZKTeco adapters with an eSSL model table; confirm with eSSL and on hardware |
| eTimeTrackLite (vendor software) | eSSL's T&A software stores logs in its database (MS Access/SQL Server/Oracle per its manual) and offers "parallel database" export and an API in the web edition | eSSL product page and manual | **Fallback only**, for sites already running it: an `essl.etimetracklite` adapter reading its export or parallel database, read-only. Not in B5 unless a pilot site needs it [D15] |

## 6. Matrix (COSEC) integration assessment

| Path | Mechanism | Evidence | Assessment |
|---|---|---|---|
| Device push API | COSEC devices push events to a configured third-party server (Matrix "COSEC Devices PUSH API User Guide", 145 pp) | Matrix-published guide (copies seen via document sites) | `matrix.cosec_push` through the agent's receiver, after the official guide is obtained from Matrix. Same trust issue as all push [D5] |
| COSEC Web API 2.0 / CENTRA | platform API on the customer's COSEC server; database integration | Matrix-published "COSEC Web API 2.0 User Guide" | `matrix.cosec_webapi`: pull from the customer's COSEC server where one exists; vendor-authenticated API → candidate for a new trust level [D5] |
| Panel API | panel-level guide exists | Matrix guide | Not in scope |

**Matrix is after the first hardware pilot**, when a customer device and the official documents are in hand (B1
decision unchanged).

---

## 7. Device polling versus push

| | Pull (agent → device) | Push (device → agent's LAN receiver) |
|---|---|---|
| Who starts | agent, every 60 s per device (configurable 30 s–15 min) | device, near real time |
| Authentication of the device | the device refuses the agent without the Comm Key → gateway may mark `authenticated` | the device only proves serial + source IP (unless the firmware supports per-device secrets/HTTPS — to verify) → `unauthenticated_lan` |
| Recovery after outage | read from cursor with overlap; limited by device log capacity | device retries unsent records per its stamp; limited by device memory and firmware behaviour |
| Exposure | no listener | a LAN listener (bound to one address, firewall-scoped to device IPs) |
| Vendor code | COM SDK in the x86 host | plain HTTP parser in the main service |
| Projection today | automatic when the device is `comm_key` + the person is mapped | **flagged → per-punch HR acceptance** |

**Design decision:** pull is the default and the recommended production mode. Push is implemented as an equally
supported adapter for devices that cannot be pulled, with the trust limitation shown to the Admin until [D5] is
decided. Direct device-to-cloud push stays out (B1 decision D6).

---

## 8. Local encrypted event queue

### 8.1 Engine and keys

- **Engine:** SQLite with **SQLCipher** (Zetetic commercial "SQLCipher for .NET", via `Microsoft.Data.Sqlite.Core`).
  Zetetic lists the Commercial Edition from US $999 per application per year [D2].
- **Free option:** the free SQLitePCLRaw encrypted bundles are deprecated from SQLitePCLRaw 3.0, so they are not used.
  The fallbacks are SQLite3 Multiple Ciphers (if a maintained .NET 10 package is confirmed) or an encrypted VHDX —
  B1 §7.1 wording kept.
- **Settings:** page size 4096; `journal_mode=WAL`; `synchronous=FULL` (durability over speed: one punch must never be
  lost on power cut); `foreign_keys=ON`; `secure_delete=ON`.
- **Queue key:** 32 random bytes, a DPAPI blob in the service account's user scope (B1 §7.2, unchanged). An optional TPM
  wrap via the Platform Crypto Provider is decided in [D16].

### 8.2 Schema (version 1)

```sql
-- every captured record, immutable fields + upload state
create table event (
  id               integer primary key,                 -- local only
  device_key       text not null,                       -- "<manufacturer>|<SERIAL>" as AttendOS knows it
  manufacturer     text not null, serial text not null,
  employee_code    text not null,
  local_time       text not null,                       -- exact device string
  utc_offset       text,
  direction        text check (direction in ('in','out')),
  verification     text,
  occurrence       integer not null check (occurrence >= 1),
  external_event_id text, record_seq integer,
  extra_json       text check (length(extra_json) <= 4096),
  cursor_token     text not null,                       -- adapter position of this record
  captured_at      text not null,                       -- agent UTC time of capture
  agent_clock_skew_ms integer,                          -- agent minus server at capture (from heartbeat)
  content_hash     blob not null,                       -- SHA-256 of the fields above (local dedupe + conflict check)
  state            text not null check (state in ('captured','queued','in_batch','accepted','duplicate','conflict',
                                     'held_future','held_unknown_device','held_invalid','rejected','expired')),
  state_reason     text,
  server_raw_id    integer, server_status text,         -- from the outcome (stored → stored/unmatched/flagged/possible_duplicate)
  attempts         integer not null default 0,
  terminal_at      text,
  unique (device_key, content_hash, occurrence)         -- the same record read twice is stored once
);
create index event_pending on event (state, local_time) where state in ('captured','queued','held_future','held_unknown_device');

create table batch (
  batch_id     text primary key,                        -- UUID v4, chosen once
  created_at   text not null, first_sent_at text, last_sent_at text,
  attempts     integer not null default 0,
  state        text not null check (state in ('built','sending','answered','abandoned')),
  answer_json  text,                                    -- gateway answer kept for audit
  body_sha256  blob not null                            -- hash of the exact request body; the body never changes
);
create table batch_item (batch_id text references batch, idx integer, event_id integer references event,
                         primary key (batch_id, idx));   -- idx = 1-based position in the request = gateway "index"

create table cursor (device_key text primary key, adapter text not null, confirmed_token text, read_token text,
                     overlap_records integer not null default 50, updated_at text not null);
create table device_state (device_key text primary key, reachable integer, last_ok_at text, last_error text,
                           device_clock_text text, drift_s integer, drift_measured_at text, log_count integer,
                           log_capacity integer, suspected_gap_from text, quarantined integer not null default 0);
create table kv (k text primary key, v text not null);  -- schema_version, instance id, last heartbeat, server skew …
create table outcome_log (id integer primary key, at text not null, event_id integer, batch_id text,
                          kind text not null, detail text);  -- append-only local trail of every state change
```

### 8.3 Rules

1. **Capture is a single transaction.** For a pull device: insert the events read and update `cursor.read_token`. The
   `confirmed_token` moves only when every event at or before it is terminal (accepted, duplicate, conflict, rejected
   or expired).
2. **A batch is immutable.** `batch` + `batch_item` + `event.state = in_batch` are committed *before* the HTTP request.
   The request body is rebuilt byte-for-byte from those rows (checked with `body_sha256`), so a resend with the same
   `batch_id` always carries the same events. This matters because the gateway answers a repeated `batch_id` from its
   stored response without looking at the body.
3. **Outcomes are applied per index** in one transaction with the batch state.
4. **No row is deleted before it is terminal *and* older than the retention period** (default: accepted and duplicate
   rows kept 14 days; conflict, rejected and expired rows kept 90 days, exportable) [D14]. Pruning runs daily and
   writes to `outcome_log`.
5. **Size cap:** default 2 GB on disk. An alert at 80 %. At 100 %, capture stops for pull devices (they keep their
   own logs) and push requests get HTTP 503 (devices keep and retry). **Nothing is overwritten.**
6. **Integrity:** `PRAGMA quick_check` at start-up. If the file fails to open or is corrupt: rename it to
   `queue.corrupt.<time>.db` (kept, not deleted), start an empty queue, re-read every pull device from its *oldest
   available* record, raise a Blocked/alert state until an Admin acknowledges, and record it in the log. Gateway
   dedupe absorbs everything already delivered.

### 8.4 Size estimate

One event row with indexes is about 0.6–1 KB. 1,000 employees × 6 punches × 3 days = 18,000 events ≈ 18 MB for a
72-hour outage. The 2 GB cap is about 2 million events.

---

## 9. Offline operation and recovery

- **Collection never depends on the internet.** Pull and push continue into the queue while uploads fail.
- **Upload resumes automatically:** exponential backoff (§10.2) while unreachable; when it is back, the backlog
  drains **oldest first across all devices** (round-robin per device inside the same minute). Oldest-first also helps
  projection, whose outcome can depend on the order days arrive (B3.4 §11.6).
- **Backfill horizon:** the gateway rejects punches older than `backfill_days` (31) as `too_old`. The agent raises a
  local warning when its oldest unsent event is 7 days old and an urgent alert at 20 days. At 31 days the events are
  rejected by the gateway; the agent marks them `expired`, keeps them 90 days and offers a CSV export for HR.
  **Nothing disappears silently.**
- **After a restart:** unfinished batches (`sending`) are resent with the same `batch_id`. `captured`/`queued`
  events continue. Pull adapters re-read from `confirmed_token` minus the overlap.
- **Device log capacity** limits recovery for pull devices that were off longer than their log holds. The agent
  detects this (§10.5) and reports a suspected gap.

## 10. Retry, backoff and duplicate prevention

### 10.1 Layers of duplicate prevention

| Layer | Mechanism | Covers |
|---|---|---|
| Agent | `unique (device_key, content_hash, occurrence)`; overlap re-reads land on the same row | re-reads, push retries from the device |
| Transport | same `batch_id` → gateway returns its stored answer (`replay: true`), stores nothing | lost responses, crashes mid-send |
| Gateway | dedupe key per device: `event_id` → `record_seq` → fingerprint(code, local time, direction, verification, occurrence); same key + same content = `duplicate`; same key + different content = `conflict` (logged, never overwritten) | any resend, even in a new batch |
| AttendOS | possible-duplicate detection within `double_press_s` (60 s) → review | genuine double presses |

**Consequence:** splitting a batch into new batches (new ids) is always safe. The worst case is `duplicate` outcomes.

### 10.2 Backoff

Exponential backoff with full jitter: base 2 s, factor 2, cap 5 min, for network errors, 5xx and timeouts.
`throttled` waits exactly `retry_after_s` (+ jitter). The heartbeat keeps its own 60 s schedule and is not counted as
traffic for the batch throttle (it has its own 30 s limit).

### 10.3 Whole-request results

| Result | Meaning | Agent action |
|---|---|---|
| `ok:true` | stored as answered | apply per-event outcomes |
| `ok:true, replay:true` | already processed earlier | apply the stored outcomes (identical) |
| `not_accepted` | key unknown, revoked, expired, company inactive — deliberately indistinguishable | stop uploading; state `Blocked: key not accepted`; heartbeat every 15 min to detect a fix; keep collecting; Event Log error; never delete |
| `throttled` | > 30 batches/min | wait `retry_after_s` |
| `too_large` / `bad_request` | agent bug or a request > 256 KB | halve the batch size and rebuild as new batches; if a single event is still refused → that event `held_invalid` + alert |
| `processing_failure` | the gateway rolled the batch back | resend the same `batch_id` after backoff (the sync run was rolled back too, so it is processed fresh); after 5 failures split into halves |
| HTTP 5xx / timeout / `57014` | not stored, or unknown | resend the same `batch_id`; after 3 timeouts in a row, mark the batch `abandoned` and rebuild smaller batches (new ids) — safe by §10.1 |
| `use_post` | client bug | never retried; alert |

### 10.4 Adaptive batch size

Start at 50 events; grow by +50 after 3 successes under 1 s; halve on a timeout or 5xx; range 10–200. This keeps each
call well inside the anon statement timeout without raising it.

### 10.5 Device-side gaps

For pull devices:

- If the record count drops, or the first available record is newer than `confirmed_token`, the log has wrapped or been
  cleared. Set `device_state.suspected_gap_from`, raise an alert and keep reading what remains.
- After an outage, if the device's oldest record is newer than the last confirmed one, the gap is reported (and in
  AttendOS once [D6] or [D7] exist).

---

## 11. Agent authentication and credential rotation

- **Credential:** the agent key (`bak_…`, 60 chars, 256-bit), issued by `biometric_register_agent` or
  `biometric_rotate_agent_key` (Admin only), shown once. It is stored as a DPAPI blob and sent **only in the POST body**
  over HTTPS (never in a URL, header or log). The public **publishable/anon key** goes in the `apikey` header; it is not
  a secret.
- **No service-role key, database password or user session** exists on the agent.
- **Rotation today (code as is):** Admin rotates → the new key is shown once → the operator runs
  `attendos-agent set-key` on the agent PC. The CLI validates the format, **tests the key with a heartbeat** before
  replacing the blob, and keeps the old blob until the new key works. The old key keeps working for 24 h. Rotate every
  12 months, on staff change, or on suspicion.
- **Expired or revoked key:** `not_accepted` → Blocked state, local alerts, queue kept and collection continues. The
  AttendOS overview shows the agent offline (no heartbeat).
- **Gap:** the Admin screens for register, rotate and revoke do not exist yet (the database functions do) → milestone
  M7. Agent-assisted rotation (the agent requests a new key with its current one) would need a new gateway function →
  [D13], not in the base plan.

## 12. Device authentication and trust classification

| Class (in the agent) | How | Becomes in AttendOS (code today) |
|---|---|---|
| **Pulled with Comm Key** | `sdk_pull` + device configured `comm_key`; the agent holds the key (DPAPI); the device refuses without it | `authenticated` → can be projected automatically |
| **Pulled without key** | `sdk_pull` on a device with no Comm Key | `unauthenticated_lan` → flagged |
| **Pushed, verified sender** | request from the expected source IP **and** serial **and** path **and** an active device of this agent; optional per-device secret/HTTPS where the firmware supports it | `unauthenticated_lan` → flagged ([D5] could add a level) |
| **Quarantined** | known serial from a new IP, unknown serial from a known IP, burst of unknown codes, signature or format errors | **not uploaded**; held locally (`held_invalid` with reason `quarantine`); alert; an Admin releases or discards with the CLI (later in the UI, [D7]) |

The agent **never** sends `source_auth: authenticated` for pushed records. It may send `unauthenticated_lan` (which can
only lower trust) — the gateway already decides from Admin configuration.

## 13. Heartbeat and health monitoring

- **Interval:** every 60 s (the server accepts ≥ 30 s). After 3 failures, back off to 5 min until it succeeds.
- **Body today** (the only fields the gateway stores):
  `{"agent_version": "x.y.z", "devices": [{"manufacturer", "serial", "reachable": true|false, "clock_drift_s": n}]}`.
- **Answer:** `server_time` and the **work list** (active devices of this agent with non-secret connection details).
- **What the agent does with the answer:**
  - Records its own clock skew (`server_time − local UTC`, using the midpoint of the round trip).
  - Starts or stops device workers to match the list.
  - Moves `held_unknown_device` events back to `queued` when their device appears in the list.
- **Local health** (always available, even offline):
  - `attendos-agent status`
  - `status.json` written every 30 s
  - Windows Event Log entries for every state change
  - The same states sent in the heartbeat body for [D6] (ignored by today's gateway, harmless).
- **Proposed for [D6]** (a migration, not part of this design phase): store `queue_depth`, `oldest_unsent_at`,
  `last_upload_ok_at`, `state`, and per device `adapter_state`, `last_error`, `suspected_gap_from` on the agent and
  device rows. The B4 screens already have places for them ("Not reported" today).

## 14. Event timestamp and time-zone preservation

- The device's local time **string** is sent unchanged as `local_time`. `utc_offset` is sent only if the device itself
  states one. Otherwise the gateway interprets the time in the device's time zone from AttendOS (the zone is pinned on
  every raw event by `raw_zone_guard`).
- The agent **never adjusts** punch times for drift. Drift is measured and reported separately, as
  `devices[].clock_drift_s` in each batch and the heartbeat. The gateway sets the `clock_drift` time flag when it
  exceeds `drift_flag_s` (300 s), and HR sees it.
- **Drift measurement:** device clock text (read via the SDK, or the push request's time) vs agent UTC corrected by the
  server skew. Measured every 15 min per pull device.
- **Agent clock safety:** if the agent's own clock differs from `server_time` by more than 120 s, the state becomes
  `Degraded: agent clock`. The agent's clock is used for nothing on the server side, but drift figures would be wrong.
- **Fast device clocks** (an important case found in the code): the gateway rejects punches more than
  `future_tolerance_s` (120 s) in the future. A device 5 min fast would have every punch sent within 5 min
  **rejected** `future_time`. The agent therefore:
  - computes each event's instant (in the device zone) before sending;
  - keeps events that would be in the future by server time as `held_future`;
  - releases each once it is no longer in the future, so it is stored with its time as recorded and flagged for drift.
  - raises an alert at the first such hold, so the device clock gets fixed.

  The alternative (send immediately, accept rejections) is [D8].
- **Daylight-saving zones:** times are sent as printed; the gateway flags ambiguity (`dst_ambiguous`). India has no
  DST; this still matters for multi-zone companies.
- **Late arrivals:** events older than `auto_project_max_age_days` (2) are stored but need an HR acceptance
  (`late_backfill`). A long outage therefore creates review work, which the agent's alerts make visible early.

## 15. Network and firewall requirements

| Direction | From → to | Port / protocol | Notes |
|---|---|---|---|
| Outbound | agent PC → `https://<project>.supabase.co` | 443 / HTTPS (TLS 1.2+) | the only internet traffic; a corporate proxy is supported via system or explicit proxy settings; no TLS interception allowed for this host (or the proxy's CA installed in the machine store, documented) |
| LAN | agent → device | 4370/TCP (ZKTeco/eSSL SDK; configurable); vendor API ports | from the agent PC only |
| LAN | device → agent | one configured port (for example 8081) on one LAN IP | Windows Firewall rule created by the installer, scope = registered device IPs; never 0.0.0.0, never public; no UPnP or port forwarding |
| Local | CLI ↔ service | named pipe `\\.\pipe\attendos-agent-<instance>`, ACL Administrators + service | no TCP |
| Local | service ↔ adapter host | named pipe, ACL service account only | adapter host outbound internet blocked by a firewall rule |

**Recommended network set-up** (in the hardware checklist): devices on a separate VLAN or subnet with static IPs and
switch port security; the agent PC on that VLAN or routed to it; NTP for the PC.

## 16. Logging, diagnostics and support

- **Structured JSON logs** (Serilog), daily files, 14 days or 200 MB, whichever comes first, plus Windows Event Log
  for state changes.
- **Never logged:** keys, comm keys, the `p_key` field, request bodies, `Extra` content, employee names (the agent
  does not have them).
- **Logged:** device codes only at Debug level, which is off by default [D17].
- **Correlation:** every request logs `batch_id`, size, latency, HTTP status, gateway code and outcome counts.
- **`attendos-agent support-bundle`** produces a zip containing:
  - status, versions and settings (secrets removed);
  - last 2 days of logs (codes masked);
  - queue counts by state (no rows);
  - OS and .NET info;
  - the firewall rule dump.

  A redaction test asserts that no key pattern (`bak_…`) or comm key is ever in it.
- **Other CLI commands:**
  - `test-connection <serial>`, `read-device-info <serial>`, `queue stats`
  - `export --state rejected|expired|conflict` (CSV for HR, codes and times only)
  - `release-quarantine`, `resend-since <time>` (re-reads devices from a time; safe because of dedupe)
  - `rekey-queue`

## 17. Upgrade and rollback

- **Packaging:** signed MSI (WiX v5 or later), per-machine, Major Upgrade. Binaries go in versioned folders; the
  service binary path switches at the end of the install. Code-signing certificate → [D3].
- **Queue schema migrations** are forward-only and run by the service at start-up inside a transaction. **Before
  migrating**, the service copies the encrypted file (`queue.db.pre-<version>`, still encrypted with the same key) and
  keeps the last two copies.
- **Rollback:** the MSI of the previous version is reinstalled. If the queue's `schema_version` is newer than the
  binary understands, the old binary refuses to start (no silent data loss) and prints how to restore the
  `pre-<version>` copy. Events captured after the upgrade would then be re-read from the devices (dedupe), and pushed
  ones not yet delivered are listed by `export` first.
- **Updates are manual in B5** (Admin installs the MSI). Automatic updates are a later decision [D12]. The version is
  reported in every heartbeat; AttendOS can show "update available" later.
- **.NET servicing:** monthly patch updates shipped as agent releases; plan the move to the next LTS before .NET 10
  support ends on 14 Nov 2028 (Microsoft support policy).

## 18. Multi-company and multi-device isolation

- **One agent key = one agent row = one company** (the gateway takes the company only from the key; devices must be
  assigned to that agent). One service instance serves one company.
- A PC serving two companies (for example a shared building) runs **two instances**. Each has its own virtual account,
  data folder, queue key, agent key and pipe names, and its own installer instance id. The push receiver ports must
  differ, and the device IP scopes are disjoint [D10].
- **Per device:** separate worker, cursor, backoff, state and quarantine; one failing device never blocks others. The
  adapter host can run one process per vendor SDK. One crashing SDK call restarts only that host, and its devices show
  `sdk_crash`.
- **Fairness:** the uploader interleaves devices so one large backlog does not starve others.

---

## 19. Security threat model (STRIDE)

| # | Threat | Asset | Mitigation in the design | Residual risk |
|---|---|---|---|---|
| S1 | **Spoofed device** pushes fake punches on the LAN | attendance integrity | receiver bound to one LAN IP, firewall scoped to device IPs, IP + serial + path + agent match, quarantine on mismatch; gateway marks pushed punches unauthenticated → HR acceptance | an attacker on the device VLAN who copies IP + serial can still create flagged punches → VLAN + switch port security; [D5] |
| S2 | **Spoofed agent** sends punches | integrity | 256-bit agent key, hash-only on the server, POST body only, 24 h overlap on rotation | key theft from the PC → DPAPI user-scope + ACL; rotate on suspicion |
| S3 | Agent key theft from disk, backups or logs | key | DPAPI user scope of a virtual account, separate blob, never logged, redacted support bundle, not in backups | local admin or SYSTEM compromise defeats DPAPI → that is a full PC compromise; BitLocker against offline theft |
| S4 | Queue theft (disk or copy) | personal data (codes, times) | SQLCipher AES-256 with per-page HMAC; key in DPAPI | live-memory attack by an admin |
| T1 | Tampering with queued events | integrity | encrypted, authenticated pages; `content_hash`; gateway `conflict` on changed content under the same dedupe key | none practical without the key |
| T2 | Tampering with agent binaries | integrity | signed binaries/MSI; Program Files ACL; the service verifies its own Authenticode signature at start (warns if unsigned in development builds) | admin compromise |
| R1 | "Punch never happened" / "agent lost it" | accountability | `outcome_log` append-only locally; gateway sync runs + raw events immutable; batch answers kept | local log is deletable by an admin → AttendOS sync runs are the authority |
| I1 | Biometric data leakage | privacy | adapters never read templates or photos; allow-listed `Extra`; double strip; gateway rejects forbidden keys | firmware bugs sending images in push → parser drops unknown record types |
| I2 | Logs leaking personal data | privacy | codes only at Debug; masked in bundles | — |
| I3 | TLS interception | key, data | HTTPS only; system trust store; optional certificate pinning to the Supabase intermediate [D19] | corporate proxies that intercept → documented exception |
| D1 | Flood of pushes | availability | per-device rate limit (20 req/min), 256 KB body cap, 10 s timeout, 503 on disk cap | LAN-only attacker can slow the receiver; devices retry |
| D2 | Gateway throttling / outages | availability | queue + backoff + `retry_after` | long outages → `late_backfill` reviews, 31-day limit |
| E1 | Vendor DLL exploited by a malicious device response | PC | DLLs in a separate low-privilege x86 process, no internet egress, job object, no secrets except its devices' comm keys | DLL memory bugs remain → isolation limits impact |
| E2 | Remote command execution via AttendOS | PC | the agent accepts no commands from AttendOS except the work list (data only); no remote shell or update | — |
| E3 | Service account privilege | PC | virtual account, no interactive logon, write only to its data folder | — |

---

## 20. Installation and configuration workflow

1. **Prerequisites (customer IT):**
   - Windows 10/11 Pro or Windows Server 2019+ x64, always on, UPS, NTP.
   - Outbound 443 to the Supabase project.
   - Devices on fixed IPs.
2. **AttendOS (Admin):** register the agent (name, identifier) → key shown once. Register devices (manufacturer,
   model, serial, office, method, assigned agent, direction mode, `device_auth`).
   *Screens for agents are a gap → M7; until then the owner runs the existing function from a local tool [D18].*
3. **Agent PC (local administrator):** run the signed MSI, then:
   1. Choose an instance name.
   2. The installer creates the virtual account, folders, ACLs and firewall rules (receiver only if needed).
   3. `attendos-agent configure --endpoint https://<project>.supabase.co --publishable-key …`
   4. `attendos-agent set-key` (paste key; a heartbeat test must succeed).
   5. `attendos-agent set-device-secret <serial>` for comm keys (never sent to AttendOS).
4. **First run:**
   1. Heartbeat → work list → workers start.
   2. `test-connection` per device.
   3. First read from the oldest record (or from a cut-over time chosen by the Admin) [D20].
   4. The Admin sees sync runs and unmatched codes in AttendOS, maps codes, and only then (separately approved per
      company) turns projection on.
5. **Hand-over checklist** (§31) signed off; key hand-over is never by e-mail or chat.

## 21. Mock-device testing architecture

```
                 ┌────────────── test harness (xUnit + scripted scenarios) ───────────────┐
                 │  ScenarioRunner: clock control, network faults, crash/restart, disk-full │
                 └──────┬───────────────────┬───────────────────────────┬────────────────┘
                        │                   │                           │
           ┌────────────▼──────┐  ┌─────────▼─────────┐     ┌───────────▼─────────────┐
           │ MockPullDevice    │  │ MockAdmsDevice     │     │ FaultProxy (Toxiproxy-   │
           │ (in-proc adapter  │  │ (HTTP client that  │     │ style) between agent and │
           │  + scripted log:  │  │  speaks the push   │     │ PostgREST: drop, delay,  │
           │  wrap, reboot,    │  │  protocol to the   │     │ 5xx, timeout, truncate   │
           │  drift, dup, gaps)│  │  agent's receiver) │     └───────────┬─────────────┘
           └────────────┬──────┘  └─────────┬─────────┘                 │
                        └────────── Agent (real service build) ────────┘
                                                                        │
                                 local stack: PostgreSQL + 0010–0012 + PostgREST (supabase/demo)
```

- **Mock adapters are labelled `mock` everywhere** and register with manufacturer `other`. Mock devices are created
  only in local/test companies.
- **Contract tests** run every adapter (mock now, vendor ones later against recorded fixtures) through the same suite:
  read-only, time strings, occurrence, no forbidden keys, typed errors.
- **End-to-end runs** use the real gateway on the local stack and assert the database after each scenario (raw events,
  outcomes, sync runs, review states).
- **Time travel:** the scenario clock drives mock device clocks; the server's `now()` is real, so future/old rules
  are exercised by device-clock offsets, not by faking the server.
- **The "nothing disappears" invariant** is checked after every scenario:
  - every mock-generated record is either a raw event in AttendOS, or a local terminal row with a reason;
  - counts match exactly.

## 22. Real-hardware pilot plan

| Step | What | Exit criteria |
|---|---|---|
| P0 | Owner confirms device (D9), SDK documents from the vendor, pilot site, staging/hosted target [D18] | written approval |
| P1 | Bench test (office desk, isolated switch): device info, clock read, log read, state field meaning, record index stability across reboot, Comm Key on/off | compatibility record filled for model + firmware |
| P2 | Duplicate and recovery tests: re-read, power-cycle device, kill agent mid-batch, unplug WAN 24 h and 72 h (simulated with firewall), clock 5 min fast/slow | invariant holds; no duplicates in AttendOS; drift flagged |
| P3 | Capacity: fill the log to wrap (or as far as safe), measure gap detection | gap detected and reported |
| P4 | Pilot at one site, 2 weeks, projection **off**; daily reconciliation device count vs AttendOS raw events | 100 % records accounted for |
| P5 | Projection on for the pilot company only (separate approval) | HR sign-off |

Status in BIOMETRIC_HARDWARE_COMPATIBILITY.md goes to "hardware-verified" **only for the model and firmware tested**.

---

## 23. Failure scenarios

| Scenario | What happens | Why nothing is lost |
|---|---|---|
| **Internet down 24–72 h** | collection continues; uploads back off (cap 5 min); after reconnection the backlog drains oldest first at ≤ 6,000 events/min. 72 h of 1,000 people ≈ 18k events ≈ 3–4 min | events are durable in the queue before any upload; events older than 2 days arrive as `late_backfill` (HR acceptance) — alert after 24 h offline tells HR to expect it |
| **Gateway unavailable** (5xx, timeouts) | same batch resent with backoff; after 3 timeouts rebuilt smaller | §10.1: replay + dedupe |
| **Windows restart during sync** | batch was committed as `in_batch` before sending; on start it is resent with the same `batch_id`; the gateway either replays its answer or processes it fresh | the immutable batch rule (§8.3.2) |
| **Service crash** | SCM restarts it in 1 min; WAL recovery; same as restart. Adapter host crash → only that host restarts | `synchronous=FULL`; cursors advance only after terminal outcomes |
| **Device network interruption** | worker backs off (1 s → 5 min); `reachable=false` in heartbeat; reads resume from `confirmed_token − overlap` | device keeps its own log; push devices retry per their stamp |
| **Duplicate delivery** | local unique key, batch replay, gateway dedupe, possible-duplicate review | §10.1 |
| **Device clock drift** | measured, reported, never corrected; > 300 s flagged by the gateway; fast clocks held until no longer in the future [D8] | held, not dropped |
| **Device storage/polling gaps** | overlap re-reads; wrap/clear detection; `suspected_gap_from` + alert; `resend-since` for re-reads | gaps are reported, never hidden; what the device no longer has cannot be recovered — exposure visible |
| **Invalid employee codes** | valid-format but unmapped → stored `unmatched` in AttendOS (review queue, "Map this code"); codes outside `[A-Za-z0-9_-]{1,32}` → `held_invalid` locally + alert, never altered [D9b] | held with reason, exportable |
| **Device credential rotation** (Comm Key changed) | adapter `auth_failed`; device shown unreachable; records stay on the device; after `set-device-secret` reading resumes from the cursor | nothing is read without the key, so nothing to lose |
| **Large backlog** | adaptive batches, throttle-aware pacing, per-device fairness; disk-cap protections; progress in status | §8.3.5, §10.4 |
| **Partial batch acceptance** | each index gets its own outcome; rejected ones are classified (§24.3), never resent blindly; batch `answered` | per-event terminal states with reasons |
| **Expired/revoked agent key** | `not_accepted` → Blocked; collection continues; Event Log + status; heartbeat probe every 15 min; `set-key` fixes it | queue retained; 31-day horizon alert |
| **Disk full / queue cap** | capture pauses (pull) or 503 (push); alert | devices keep records |
| **Queue file corrupt or key lost** | file kept aside; new queue; full re-read from devices; Admin alert | dedupe; exposure limited to push records not yet delivered (reported) |
| **Device removed from agent in AttendOS** | its events get `unknown_device` → `held_unknown_device`; worker stops at the next heartbeat; Admin either reassigns (events released) or discards via CLI with a reason | held with reason |

---

## 24. API integration contract (as implemented in 0011)

### 24.1 Transport

```
POST https://<project>.supabase.co/rest/v1/rpc/biometric_heartbeat     (and …/rpc/biometric_ingest)
Headers: apikey: <publishable/anon key>   Content-Type: application/json   Accept: application/json
         (no Authorization user token; requests run as the anon role, which may execute only these two functions)
Body:    {"p_key": "<agent key>", "p_status": {…}}      /      {"p_key": "<agent key>", "p_batch": {…}}
```

GET is refused (`use_post`). Key ≤ 64 characters (the valid format is exactly 60). Request ≤ 256 KB. Heartbeat body ≤ 16 KB.

### 24.2 Ingest request

```json
{
  "batch_id": "4f6b0d1e-6c55-4b0f-9b1d-0d6c0b4b8b01",       // required, UUID, unique per agent, chosen by the agent
  "agent_version": "1.0.0",                                  // ≤ 40 chars
  "devices": [ { "manufacturer": "zkteco", "serial": "CKUH201960123", "clock_drift_s": -12 } ],
  "events": [                                                // ≤ 200
    { "manufacturer": "zkteco", "serial": "CKUH201960123",   // must be an active device assigned to this agent
      "employee_code": "101",                                // ^[A-Za-z0-9_-]{1,32}$
      "local_time": "2026-11-21 09:02:14",                   // YYYY-MM-DD HH:MM[:SS[.ffffff]]
      "utc_offset": "+05:30",                                // optional; only if the device states it
      "direction": "in",                                     // optional: in | out
      "verification": "fingerprint",                         // optional: ^[a-z_]{1,32}$
      "occurrence": 1,                                       // 1..999999, default 1
      "record_seq": 48211,                                   // optional, only when StableRecordSeq is declared
      "event_id": "…",                                       // optional, only when StableEventId is declared
      "source_auth": "unauthenticated_lan",                  // optional; can only lower trust
      "payload": { "workcode": "0" } }                       // optional object ≤ 4 KB, no biometric keys
  ]
}
```

### 24.3 Ingest response and the agent's handling

```json
{ "ok": true, "batch_id": "…", "sync_run_id": 812, "received": 3, "stored": 2, "confirmed_duplicates": 1,
  "possible_duplicates": 0, "conflicts": 0, "rejected": 0,
  "outcomes": [ {"index":1,"outcome":"stored","raw_event_id":5501,"status":"stored"},
                {"index":2,"outcome":"stored","raw_event_id":5502,"status":"unmatched"},
                {"index":3,"outcome":"duplicate","raw_event_id":5300} ] }
```

| Outcome | Local state | Notes |
|---|---|---|
| `stored` (status stored / unmatched / flagged / possible_duplicate) | `accepted` + `server_raw_id`, `server_status` | review work happens in AttendOS |
| `duplicate` | `duplicate` | already in AttendOS |
| `conflict` | `conflict` (kept 90 d, alert) | same dedupe key, different content — usually an adapter or firmware issue; AttendOS keeps the second payload for Admin |
| `rejected: unknown_device` | `held_unknown_device` | released when the device is in the work list again |
| `rejected: future_time` | `held_future` | resent when no longer in the future [D8] |
| `rejected: too_old` | `expired` (kept 90 d, exportable) | > 31 days |
| `rejected: invalid_time` / `unsupported_format` | `rejected` + alert | adapter bug; never resent unchanged |

### 24.4 Heartbeat

Request `{"agent_version": "1.0.0", "devices": [{"manufacturer","serial","reachable":true,"clock_drift_s":4}], …}`.
Fields beyond these are accepted and ignored today ([D6]).

Response `{"ok":true,"server_time":"…","devices":[{"manufacturer","serial","model","integration_method",
"adapter_type","timezone","direction_mode","device_auth","connection":{…}}]}`.

Errors: `not_accepted`, `throttled` (`retry_after_s`), `too_large`, `use_post`.

---

## 25. Device compatibility matrix (planning status — nothing hardware-verified)

| Manufacturer / family | Method | Adapter | Runtime | Trust (code today) | Documentation | Status |
|---|---|---|---|---|---|---|
| ZKTeco T&A (MB160, F22, K40, SpeedFace, ProFace X …) | Standalone SDK pull, TCP 4370 | `zkteco.standalone_sdk` | x86 adapter host (.NET 10 x86 COM interop; fall back to .NET Framework 4.8.1) | authenticated with Comm Key | official SDK (GitHub), 32-bit package | documented — to verify |
| ZKTeco T&A | ADMS / PUSH SDK | `zkteco.adms` | main service | unauthenticated_lan | protocol doc via distributor; full spec needed | documented (partial) |
| eSSL ZK-platform (MB160, X990, K90 Pro, uFace 302, AiFace) | SDK pull / ADMS | `essl.standalone_sdk` / `essl.adms` | as ZKTeco | as ZKTeco | third-party claims; eSSL confirmation needed | third-party claim |
| eSSL eTimeTrackLite | vendor software DB/export | `essl.etimetracklite` (optional) | main service | to define [D5] | eSSL manual | not planned in B5 |
| Matrix COSEC (ARGO, VEGA, PATH) | device push API | `matrix.cosec_push` | main service | unauthenticated_lan | Matrix PUSH API guide | documented — after pilot |
| Matrix COSEC CENTRA | Web API 2.0 pull | `matrix.cosec_webapi` | main service | to define [D5] | Matrix Web API guide | documented — after pilot |
| Mock | scripted | `mock.pull`, `mock.push` | main service | as configured | — | to build (M4) |

---

## 26. Implementation roadmap (each milestone needs separate approval; stop for review after each)

Code location: a new top-level `agent/` folder in this repository (or a separate repository) [D4]. CI runs on a GitHub
Actions Windows runner; nothing is deployed anywhere.

### M0 — Decisions and contract freeze (this document)
- **Scope:** owner decisions §32; freeze §24 as contract v1; agree milestone order.
- **Files:** this document; BIOMETRIC_IMPLEMENTATION_STATUS.md.
- **Acceptance:** approval recorded.

### M1 — Solution skeleton, service host, configuration, logging
- **Scope:** .NET 10 solution: `Agent.Service`, `Agent.Core`, `Agent.Cli`, `Agent.Tests`; Windows Service host;
  settings model; Serilog + Event Log; status file; CI build and tests on a Windows runner.
- **Files:** `agent/AttendOS.Agent.sln`, `src/Service`, `src/Core`, `src/Cli`, `tests/*`, `.github/workflows/agent.yml`.
- **Dependencies:** M0; .NET 10 SDK.
- **Security:** no secrets yet; logging redaction rules and tests in place from day one.
- **Tests:** unit; service start/stop on the CI runner; log redaction test (key patterns never written).
- **Acceptance:** service installs/uninstalls on a test VM via a script, reports `Ready`, shuts down cleanly.
- **Risks:** CI Windows runner minutes; environment parity.

### M2 — Encrypted queue and secret store
- **Scope:** SQLCipher queue (schema v1, §8), migrations, integrity check, corruption handling; DPAPI SecretStore;
  `rekey-queue`; retention and size cap.
- **Dependencies:** [D2] licence (or the approved fallback).
- **Security:** user-scope DPAPI, ACLs, crypto-shred on uninstall.
- **Tests:**
  - the file is unreadable without the key (opened with plain SQLite → fails);
  - power-cut simulation (kill -9 during write) → no lost committed rows;
  - corrupt-file path;
  - rekey;
  - cap behaviour;
  - DPAPI blobs readable only by the service account (integration test on CI VM).
- **Acceptance:** all tests green; threat items S3, S4, T1 covered.
- **Risks:** licence delay; SQLCipher + .NET 10 packaging.

### M3 — Gateway client (heartbeat + ingest) against the local stack
- **Scope:** HTTP client (HttpClientFactory, TLS 1.2+, proxy support); heartbeat loop + work list; immutable batch
  builder; outcome application; backoff, throttle and adaptive size; `not_accepted` handling; clock skew.
- **Files:** `Core/Gateway/*`, `Core/Upload/*`.
- **Dependencies:** M2; local stack (supabase/demo) with a test company and agent key.
- **Security:** key only in body; never logged; HTTPS enforced (HTTP allowed only for `localhost` in test builds).
- **Tests:**
  - contract tests against PostgREST (every §24 outcome);
  - FaultProxy: drop, delay, 5xx, timeout, truncated response, duplicate responses;
  - replay;
  - 72 h offline backlog simulation;
  - partial acceptance;
  - revoked and expired key;
  - throttle (31 batches/min).
- **Acceptance:** invariant "every event terminal or pending with a reason"; zero duplicates in raw events after
  fault runs; no request over 256 KB.
- **Risks:** hosted timeout differences → measured again in the pilot.

### M4 — Mock adapters, scheduler, cursors, end-to-end
- **Scope:** adapter contract (§3), Normalizer (occurrence), DeviceScheduler, cursors and overlap, gap detection,
  `mock.pull`/`mock.push` with scripted scenarios, ScenarioRunner.
- **Tests:**
  - every failure scenario in §23 automated;
  - adapter contract suite;
  - "nothing disappears" counts.
- **Acceptance:** all §23 rows demonstrated with database evidence on the local stack.
- **Risks:** mock realism — tied to recorded fixtures later.

### M5 — Local push receiver (hardened)
- **Scope:** Kestrel receiver on one LAN IP; protocol paths for ADMS (from the official spec) behind the adapter;
  per-device rules, rate limits, size limits, quarantine; firewall rule management.
- **Security:** start-up refuses public/unknown addresses; no management commands to devices; strict parser; drop of
  biometric record types.
- **Tests:**
  - spoofed serial, spoofed IP, unknown path, oversize, slowloris (timeouts), template upload attempt, burst;
  - fuzzing of the parser.
- **Acceptance:** threat items S1, D1, I1 covered; only mock devices.
- **Risks:** protocol variations by firmware.

### M6 — Installer, CLI, upgrade/rollback, uninstall
- **Scope:** WiX MSI, virtual account, ACLs, firewall rules, `configure`, `set-key` (heartbeat-tested), device
  secrets, `status`, `support-bundle`, `export`, `release-quarantine`, `resend-since`; versioned install; queue backup
  before migration; crypto-shred uninstall.
- **Dependencies:** [D3] signing certificate (unsigned builds only on test VMs).
- **Tests:**
  - clean install / upgrade / downgrade refusal / restore-from-backup;
  - uninstall leaves no secrets;
  - support bundle redaction.
- **Acceptance:** documented install takes under 15 minutes on a clean VM.
- **Risks:** SmartScreen / Defender reputation without an EV certificate.

### M7 — AttendOS Admin screens for agents (application change; separate approval)
- **Scope:** register / rotate / revoke agent (functions exist since 0010), show key once, assign devices to agents,
  set `device_auth`; agent health from heartbeat fields that exist today.
- **Files:** `src/components/biometric/*`, `src/lib/biometric-live.ts`, tests, Help/report.
- **Dependencies:** none on the database for the base scope. Telemetry needs a separate migration proposal [D6, D7].
- **Security:** Admin-only (database already enforces); key shown once, never stored in the browser.
- **Tests:** B4-style browser and role tests; key never in logs or the network log beyond the one response.
- **Risks:** a key shown on screen → instructions and a copy button only; no e-mail.

### M8 — Vendor adapters: ZKTeco/eSSL (Standalone SDK pull + ADMS push) on mock fixtures
- **Scope:** x86 adapter host + named pipe protocol; `zkteco.standalone_sdk` (official SDK only); `zkteco.adms` /
  `essl.adms` parsers from official documents; recorded-fixture tests.
- **Dependencies:** vendor SDK licence/terms, official push protocol document, [D11].
- **Security:** host isolation (job object, no egress, minimal secrets); DLLs from the vendor package only, hashes
  recorded.
- **Tests:** contract suite on fixtures; host crash/restart; COM interop under .NET 10 x86 (or the 4.8.1 fallback).
- **Acceptance:** adapters pass contract tests; no hardware claims.

### M9 — Real-hardware pilot (separate authorisation)
- **Scope:** §22 P1–P4 with the device chosen in D9; compatibility record.
- **Dependencies:** D9, hardware on site, target environment [D18].
- **Acceptance:** P1–P4 exit criteria; owner sign-off.

### M10 — Matrix adapters (when device and documents exist)

**Order and size:** M1–M4 are the core (about 4–6 weeks of focused work); M5–M6 about 2–3 weeks; M7 about 1 week;
M8 about 2–3 weeks. These are rough planning figures, not commitments.

---

## 27. Hardware and site requirements checklist

**Agent PC**
- [ ] Windows 10/11 Pro (22H2+) or Windows Server 2019/2022/2025, x64, latest updates.
- [ ] 2+ cores, 4 GB RAM, 10 GB free SSD space.
- [ ] Always on, UPS-backed, sleep and hibernate disabled.
- [ ] NTP time sync working (`w32tm /query /status`).
- [ ] BitLocker on the system drive (recommended); local admin access for installation.

**Network**
- [ ] Outbound 443 to the company's Supabase project host.
- [ ] Proxy details if any; no TLS interception for that host.
- [ ] Devices with static IPs; separate VLAN/subnet recommended; switch port security if push is used.
- [ ] Ports: 4370/TCP agent → device (SDK); receiver port device → agent (push only).

**Each device**
- [ ] Manufacturer, model, serial, firmware (System info screen).
- [ ] ADMS/Push support, SDK pull support, Comm Key setting.
- [ ] Log capacity and current record count.
- [ ] Whether staff press In/Out keys; time zone and clock accuracy.
- [ ] Whether it is already connected to other software (eTimeTrackLite, BioTime, COSEC).

**Documents from the vendor**
- [ ] SDK package and licence/terms; push protocol document for the firmware; API guide (Matrix).

**AttendOS**
- [ ] Target environment approved (local / staging / hosted) [D18].
- [ ] Agent registered; devices registered and assigned; mapping plan for device codes.
- [ ] Projection remains off until separately approved.

---

## 28. Component specifications (summary)

| Component | Inputs | Outputs | Key guarantees |
|---|---|---|---|
| Supervisor | SCM commands, child health | lifecycle state | clean start/stop; restarts children; never deletes data |
| ConfigManager | settings.json, heartbeat work list | device set, endpoints | secrets never in settings.json |
| SecretStore | DPAPI blobs | in-memory secrets (pinned, cleared on dispose) | user-scope DPAPI; separate entropy per blob |
| DeviceScheduler | work list, adapter registry | read requests, device state | per-device isolation and backoff |
| AdapterHost (x86) | pipe requests | DeviceRecords | vendor DLL isolation; strips forbidden fields |
| PushReceiver | LAN HTTP | DeviceRecords | bound to one LAN IP; validation; quarantine |
| Normalizer | DeviceRecords | event rows | exact time strings; deterministic occurrence; content hash |
| Queue | event rows | batches, outcomes | durability, immutability of batches, no silent deletion |
| Uploader | queued events | ingest requests, outcomes | oldest-first, fair, adaptive, idempotent |
| Heartbeat | status | work list, server time | ≥ 30 s spacing; probe mode when blocked |
| ClockMonitor | device clocks, server time | drift values, alerts | never alters punch times |
| HealthReporter | all states | status.json, Event Log, heartbeat fields | always available offline |
| Diagnostics/CLI | admin commands | status, bundles, exports | redaction; admin-only pipe |

---

## 29. Test strategy summary

Unit → contract (adapters, gateway) → end-to-end on the local stack with fault injection → installer tests on clean
Windows VMs → hardware bench → pilot. Every milestone keeps the existing AttendOS suites green (no application or
database change before M7, which is separately approved).

## 30. What B5 does not change

- No database migration, no change to the gateway, projection or B4 screens in M1–M6 and M8.
- M7 is the first application change.
- Any telemetry migration (D6/D7) or trust-level change (D5) is a separate proposal with its own review.

## 31. Hand-over checklist for a new site (operational)

- Agent installed, status `Running`, heartbeat visible in AttendOS.
- Each device `reachable` with drift < 60 s; first sync run visible; unmatched codes listed.
- Firewall rules verified.
- Support contact and key-rotation date recorded.

## 32. Open decisions requiring owner approval

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Approve this design and milestone order | approve / amend | approve M1–M4 first |
| D2 | Queue encryption library | SQLCipher Commercial (from US $999/app/year) · SQLite3 Multiple Ciphers (after confirming a maintained .NET 10 package) · encrypted VHDX | SQLCipher Commercial |
| D3 | Code-signing certificate | OV · EV (better SmartScreen reputation) · none for pilot VMs only | OV/EV before any customer install |
| D4 | Where the agent code lives | `agent/` in this repo · separate private repo | separate private repo, linked from docs (different release cycle and CI) |
| D5 | Trust for push devices (today every pushed punch needs individual HR acceptance) | keep as is (pull-only for automatic attendance) · new trust level for push with documented network controls (migration) · vendor-authenticated APIs (Matrix CENTRA) as trusted | keep as is for the pilot; revisit with pilot evidence |
| D6 | Store heartbeat telemetry (queue depth, oldest unsent, adapter state, gaps) | migration 0013 proposal · keep local only | propose 0013 after M3 |
| D7 | Report agent-side errors (receiver rejections, quarantine, auth failures) to AttendOS | new gateway function (migration) · local only | propose with D6 |
| D8 | Fast device clocks (punch "in the future") | hold until valid, then send (stored + drift flag) · send immediately (rejected) | hold |
| D9 | First physical device (B1 D9) | model + firmware | eSSL/ZKTeco ADMS-capable model that also supports SDK pull |
| D9b | Device codes outside `[A-Za-z0-9_-]{1,32}` | hold + alert · normalise (e.g. trim) | hold + alert; never alter |
| D10 | Multiple companies on one PC | allowed as separate instances · one company per PC | allowed, separate instances |
| D11 | Unofficial protocols (pyzk-style TCP 4370) | never · only with written approval per case | never (B1 rule) |
| D12 | Automatic updates | manual MSI in B5 · signed auto-update later | manual in B5 |
| D13 | Agent-assisted key rotation | not now · new function later | not now |
| D14 | Local retention | accepted 14 d; rejected/expired/conflict 90 d; cap 2 GB | as proposed |
| D15 | eSSL eTimeTrackLite adapter | only if a pilot site needs it | as needed |
| D16 | TPM wrapping of the queue key | optional where TPM exists · required | optional |
| D17 | Device codes in logs | Debug only, off by default · never | Debug only |
| D18 | Target environment for M3–M9 | local stack only · staging Supabase project with 0010–0012 · hosted after approval | local through M8; staging for M9 |
| D19 | TLS certificate pinning | no (system trust) · pin Supabase intermediate | no — pinning breaks on CA rotation |
| D20 | First-run history | read everything on the device · from an Admin-chosen cut-over time | cut-over time (avoids months of `late_backfill` reviews) |

## 33. Sources (external facts used)

- Microsoft .NET support policy (.NET 10 LTS, end of support 14 Nov 2028): https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core
- Zetetic, SQLCipher for .NET (Microsoft.Data.Sqlite.Core support): https://www.zetetic.net/sqlcipher/sqlcipher-for-dotnet ; Commercial Edition pricing: https://www.zetetic.net/sqlcipher/commercial/
- SQLitePCLRaw encryption options (free encrypted bundles deprecated in 3.0): https://github.com/ericsink/SQLitePCL.raw/wiki/SQLite-encryption-options-for-use-with-SQLitePCLRaw
- ZKTeco, General Introduction of PUSH SDK Protocol (distributor copy): https://cdn.tvc.mx/media/92189/General-Introduction-of-PUSH-SDK-Protocol.pdf ; attendance PUSH protocol 2020 (v3.7) referenced via a document-sharing copy
- ZKTeco Standalone SDK package (32-bit communication SDK; companion DLLs) — public package notes; third-party 6.3.1.37 package with 64-bit folder (claim): https://gh.r-mj.com/KushX/NetFrameworkZKTecoAttLogsDemo
- eSSL eTimeTrackLite (database export, parallel database, API): https://esslsecurity.com/etimetracklite-web-integration ; eSSL MB160 ADMS set-up (third party): https://get.clockit.io/essl/mb160
- Matrix COSEC Devices PUSH API User Guide and COSEC Web API 2.0 User Guide (Matrix-published; seen via document-sharing copies — official copies to be obtained from Matrix)
- Inherited B1 references: BIOMETRIC_HARDWARE_COMPATIBILITY.md
