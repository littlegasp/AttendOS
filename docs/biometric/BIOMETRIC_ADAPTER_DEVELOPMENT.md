# Biometric adapters — contract and development rules (Phase B1)

Status: **proposed contract. No adapter written.** Adapters run **inside the Sync Agent**, never in the browser or
the database. The gateway only ever sees the standard event (BIOMETRIC_SYSTEM_ARCHITECTURE.md §3).

## 1. Contract (shown in C#, the recommended agent language — D2; same shape in TypeScript if D2 changes)
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
record RawPunch(string? ExternalEventId, string EmployeeDeviceCode, string DeviceLocalTime, string? UtcOffset,
                string Direction, string VerificationMethod, JsonElement Raw);
```
Capabilities are declared, not assumed: `Pull`, `Push`, `Cursor`, `DeviceTime`, `DirectionKeys`, `LogCapacity`,
`ClearLogs` (never used by AttendOS — logs are not deleted from devices).

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
4. **Cursor**: the last confirmed record (device serial number of record, timestamp, or vendor stamp). The cursor
   advances only after the gateway has confirmed the batch.
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
