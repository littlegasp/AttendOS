# AttendOS Sync Agent — proposed design (Phase B1, revision 3)

Status: **design only. Not built.** Runtime decided (D2): **.NET 10 LTS** Windows service first (Microsoft support
until 14 Nov 2028); Linux later for adapters that need no Windows components.

## 1. What it is
A small background service installed on a company-controlled PC or server **on the same network as the biometric
machines**. It talks to the machines over the LAN and to AttendOS over outbound HTTPS. It is the only thing that needs
network access to the machines; the machines are never exposed to the internet.

## 2. Components
| Part | Job |
|---|---|
| Config store | Gateway URL and device list (non-secret). Secrets are **separate protected blobs** (§7.2): agent key, device credentials, queue key — each its own file |
| Adapters | Plug-ins per manufacturer/method (BIOMETRIC_ADAPTER_DEVELOPMENT.md) |
| Adapter host | Separate supervised process (x86 where the vendor SDK is 32-bit COM) for legacy SDKs; local named pipe to the service, ACL = service account; restarted on crash/hang; no network listener |
| Poller / receiver | Pull adapters on an interval (default 60 s, per device); local push receiver for push adapters — bound to one configured LAN address only, never to all interfaces or a public address; authentication and validation rules in BIOMETRIC_SECURITY.md §8 |
| Local queue | SQLite file **encrypted with SQLCipher** (§7); one row per punch with status (pending / sent / confirmed) and its dedupe fields; **confirmed rows kept 14 days** (so they can be re-sent after a database restore — "resend since <time>" from AttendOS), then pruned |
| Uploader | Batches ≤ 500 punches, oldest first, `batch_id` per batch; HTTPS POST to `biometric_ingest`; retry with exponential backoff + jitter; honours `retry_after` from the gateway |
| Heartbeat | Every 5 min: agent version, uptime, queue depth, per-device reachability, device clock vs agent clock, last cursor, last error |
| Logs | Structured JSON lines, rotated, no keys or personal data beyond device codes |

## 3. Flows
- **Normal:** poll/receive → queue → upload → gateway confirms each event (stored / duplicate / unmatched / rejected) →
  queue marks confirmed → cursor advances.
- **Internet down:** polling continues into the queue; uploads retry with backoff; nothing is dropped while disk
  stays under the configured cap (alert in AttendOS when heartbeat shows the queue above 80 %).
- **Agent restart:** queue and cursors survive; unconfirmed rows are re-sent (the gateway de-duplicates).
- **Agent PC off for days:** on start, adapters read from their last cursor; recovery depends on the machine's own log
  capacity (measured per model in B5).
- **Key revoked:** gateway refuses; agent stops uploading, keeps the queue, shows "key revoked" locally and in its log.

## 4. Installation, upgrade, removal (to be detailed in B4)
1. Admin creates the agent in AttendOS → key shown once → copied into the installer prompt (never e-mailed or chatted).
2. Installer (signed MSI on Windows; .deb/.rpm + systemd on Linux) installs the service under a dedicated
   low-privilege account, opens no inbound internet ports, and stores the key encrypted.
3. Upgrade: new installer keeps config and queue; version reported in heartbeat.
4. Removal: uninstall wipes config and queue; Admin revokes the key in AttendOS.

## 5. Not allowed in the agent
Supabase secret/service-role key, database password, any other company's key, fingerprint/face templates, photos,
remote code execution or remote shell from AttendOS, inbound connections from the internet.

## 6. Runtime and deployment compatibility (to be confirmed in B4/B5)
| Item | Plan |
|---|---|
| Main service | .NET 10 LTS, x64, self-contained publish (no separate runtime install), Windows 10/11 and Windows Server 2019+ (to confirm against .NET 10's supported OS list at build time) |
| Adapter host | x86 or x64 to match each vendor SDK; .NET 10 COM interop where it works, .NET Framework 4.8.1 only where a vendor SDK requires it |
| Vendor SDK install | Vendor DLLs registered by the installer for the host's bitness only; versions recorded in the heartbeat |
| Updates | Monthly .NET 10 servicing updates shipped in agent releases; move to the next LTS before Nov 2028 |
| Code signing | Installer and binaries signed (certificate to be arranged before B4 release) |

## 7. Queue encryption and secret storage (revision 3)
A plain SQLite file is **not** encrypted, even if the agent's configuration is protected with DPAPI. The queue holds
employee device codes and punch times, so the database file itself is encrypted.

### 7.1 Chosen approach: SQLCipher (official build)
- **Library:** Zetetic's **SQLCipher for .NET** (commercial edition), which supports Microsoft's ADO.NET provider
  `Microsoft.Data.Sqlite.Core`. Page-level AES-256 encryption with an HMAC per page; the whole file (data, indexes,
  journal/WAL) is unreadable without the key.
- **Not used:** the free `SQLitePCLRaw.bundle_e_sqlcipher` / `e_sqlite3mc` builds — their maintainer describes the
  SQLCipher builds as unofficial and unsupported and has deprecated the free encrypted bundles from SQLitePCLRaw 3.0.
- **Alternative if the licence is declined (open question 7):** SQLite3 Multiple Ciphers (open source), only after
  confirming a maintained .NET 10 packaging; or, as a last resort, an **encrypted volume** (BitLocker on a dedicated
  VHDX or data drive, unlocked by TPM at boot) — documented as weaker because the data is readable to any process
  with file access while the machine runs.
- BitLocker on the system drive is still recommended as defence in depth, not as the queue's protection.

### 7.2 Keys and where they live
| Secret | Generated | Stored as | Who can read it |
|---|---|---|---|
| Queue key (256-bit random) | At install, by the agent | Windows DPAPI blob in **user scope of the agent's dedicated service account** (`NT SERVICE\AttendOSAgent`), file ACL: that account + SYSTEM | Only the service process |
| Agent key (from AttendOS) | By Admin in AttendOS, pasted once into the installer | Separate DPAPI blob, same account scope, different file and entropy | Only the service process |
| Device credentials (comm keys, push secrets) | Entered by the installer/Admin on the PC | Separate DPAPI blob per device | Only the service process; passed to the adapter host over the named pipe at start |
DPAPI **machine** scope is not used (any local process could decrypt it). Optional hardening: wrap the queue key with a
TPM-backed CNG key (Microsoft Platform Crypto Provider) where the PC has a TPM. On Linux: key files owned by the
service user, mode 0600, or `systemd-creds` encrypted with the host/TPM key.
The service account has no interactive logon, no admin rights and write access only to the agent's data folder.

### 7.3 Rotation
- Queue key: `PRAGMA rekey` with a new random key every 12 months, on suspicion of compromise, and whenever the
  service account or machine changes. The old DPAPI blob is overwritten after the rekey succeeds.
- Agent key: rotated from AttendOS (Admin); the installer/`attendos-agent set-key` writes the new blob.
- Device credentials: changed on the device and in the agent together.

### 7.4 Backup and recovery
The queue is a **transient buffer**, not a record of truth — the device's own log and AttendOS are. It is therefore
**not backed up**. If the key or the file is lost (disk failure, OS reinstall, service account change): the agent
starts a new empty queue with a new key, and re-reads from the devices over the backfill window (31 days default);
de-duplication removes anything AttendOS already has. Punches only in the lost queue and already overwritten on the
device would be lost — the heartbeat's queue depth and last-confirmed time show the exposure.

### 7.5 Secure removal
Uninstall and "decommission agent" **crypto-shred**: delete the three DPAPI blobs first (the queue becomes
unrecoverable), then delete the database, WAL and log files, then the Admin revokes the agent key in AttendOS.
Overwriting files is not relied on (SSDs do not guarantee it).

