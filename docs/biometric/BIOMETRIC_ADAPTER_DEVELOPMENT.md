# Biometric adapters — contract and development rules (Phase B1, revision 2)

Status: **proposed contract. No adapter written.** Adapters run **inside the Sync Agent** (in the main service or,
for legacy/COM SDKs, in an isolated adapter host process — §5), never in the browser or the database. The gateway only ever sees the standard event (BIOMETRIC_SYSTEM_ARCHITECTURE.md §3).

## 1. Contract (C#, .NET 10 — D2)
```csharp
public interface IBiometricAdapter : IAsyncDisposable {
  AdapterInfo Info { get; }                       // manufacturer, adapter id, supported methods, capabilities
  Task<ConnectionResult> TestConnectionAsync(DeviceConfig cfg, CancellationToken ct);
  Task<DeviceInfo> GetDeviceInfoAsync(CancellationToken ct);     // model, serial, firmware, device clock, log count/capacity if available
  Task<AttendanceBatch> FetchAttendanceAsync(string? cursor, int maxRecords, CancellationToken ct); // pull adapters
  IAsyncEnumerable<RawPunch> ReceivePushedAsync(CancellationToken ct);                              // push adapters (local receiver)
  Task<DeviceStatus> GetStatusAsync(CancellationToken ct);
}
record AttendanceBatch(IReadOnlyList<RawPunch> Punches, string? NextCursor, bool More);
record RawPunch(string? ExternalEventId, string? RecordSeq, int Occurrence, string EmployeeDeviceCode,
                string DeviceLocalTime, string? UtcOffset, string Direction, string DirectionSource,
                string VerificationMethod, JsonElement Raw);
```
Capabilities are declared, not assumed: `Pull`, `Push`, `Cursor`, `DeviceTime`, `DirectionKeys`, `LogCapacity`,
`StableEventId`, `StableRecordSeq`, `ClearLogs` (never used by AttendOS — logs are not deleted from devices).
`StableEventId` / `StableRecordSeq` may be declared only after hardware testing shows the value survives re-reads,
reboots and firmware behaviour; until then the gateway uses the fallback fingerprint (schema §3).

## 2. Registration
Adapters register by id in the agent (`zkteco.standalone_sdk`, `zkteco.adms`, `essl.adms`, `matrix.cosec_push`,
`matrix.cosec_webapi`, `file.csv`, `mock`). The device row's `adapter_type` selects one. A device whose adapter is
not installed in that agent reports `unsupported_adapter` in its heartbeat.

## 3. Rules for every adapter
1. **Only documented interfaces.** Use the manufacturer's SDK, published protocol document or official API.
   Reverse-engineered protocols are not used without the owner's written decision and a note in
   BIOMETRIC_HARDWARE_COMPATIBILITY.md.
2. **Read-only.** Never delete logs, enrol users, change device settings or download fingerprint/face templates or
   photos. Fields carrying templates or images are dropped before the event leaves the adapter.
3. **Preserve time exactly** as the device reports it (string), plus offset if given.
4. **Cursor**: the last confirmed record (record sequence, timestamp, or vendor stamp). The cursor advances only
   after the gateway has confirmed the batch.
4a. **Occurrence**: for records identical in code, time, direction and method, number them 1, 2, … in the device's
   own log order, so two genuine identical punches stay two and a re-read gives the same numbers.
4b. **Direction source**: report `device_key` only when the device record carries an explicit state the person
   chose; `device_fixed` when the device is set to a fixed mode (e.g. an "entry only" terminal); `none` otherwise.
5. **Errors** are typed (`unreachable`, `auth_failed`, `timeout`, `protocol_error`, `unsupported_model`) and
   reported in the heartbeat; never swallowed.
6. **Reconnect** with exponential backoff and jitter (1 s → 5 min cap).
7. **Mock adapter** produces scripted punches (normal day, overnight, duplicates, clock drift, unknown codes,
   offline gaps) and is labelled `mock` everywhere — it never sets a real manufacturer.

## 4. Definition of done for a real adapter
- Contract tests pass against the mock harness.
- Run against at least one real device: model, firmware, serial (masked), method, dates, record counts,
  offline/recovery test, duplicate test, clock-drift test — recorded in BIOMETRIC_HARDWARE_COMPATIBILITY.md.
- Status raised from "documented" to "hardware-verified" **only for that model and firmware**.

## 5. Runtime and SDK compatibility
- Main Sync Agent service: **.NET 10 LTS** (Microsoft support until 14 Nov 2028), x64. Plan the move to the next LTS
  before that date. No unsupported runtime is used for the main service.
- Legacy SDKs (for example ZKTeco's Standalone SDK, distributed as a **32-bit COM** library `zkemkeeper.dll` with
  companion DLLs) run in a separate **adapter host process** of matching bitness (x86), started and supervised by the
  main service, talking to it over a local named pipe restricted to the service account. A crash or hang in a vendor
  DLL then cannot take down the agent, the queue or other devices.
- The adapter host targets .NET 10 (x86) using COM interop on Windows if the vendor SDK works there; if a vendor SDK
  only works under .NET Framework, the host may use **.NET Framework 4.8.1** (supported as a Windows component) —
  only for that host, never the main service. Which one each SDK needs is recorded in the compatibility matrix below
  after testing.
- Linux agents run only adapters that need no Windows/COM components (push receivers, HTTP APIs, file import).

| Adapter | Vendor component | Bitness | Host | Runtime | Status |
|---|---|---|---|---|---|
| `zkteco.standalone_sdk` | Standalone SDK (`zkemkeeper.dll`, COM) | x86 (public package) | adapter host | .NET 10 x86 COM interop → fall back to .NET Framework 4.8.1 | to verify |
| `zkteco.adms` / `essl.adms` (local push receiver) | none (HTTP) | n/a | main service | .NET 10 | to verify |
| `matrix.cosec_push` / `matrix.cosec_webapi` | none (HTTP API) | n/a | main service | .NET 10 | to verify |
| `file.csv` | none | n/a | in-app import | — | to verify |
| `mock` | none | n/a | main service | .NET 10 | to build in B4 |

