# AttendOS Sync Agent — proposed design (Phase B1)

Status: **design only. Not built.** Technology pending decision D2 (recommended .NET 8, Windows service first).

## 1. What it is
A small background service installed on a company-controlled PC or server **on the same network as the biometric
machines**. It talks to the machines over the LAN and to AttendOS over outbound HTTPS. It is the only thing that needs
network access to the machines; the machines are never exposed to the internet.

## 2. Components
| Part | Job |
|---|---|
| Config store | Agent key, gateway URL, device list (from AttendOS) and device secrets (comm keys) — encrypted with Windows DPAPI (machine scope) / a root-only key file on Linux |
| Adapters | Plug-ins per manufacturer/method (BIOMETRIC_ADAPTER_DEVELOPMENT.md) |
| Poller / receiver | Pull adapters on an interval (default 60 s, per device); local HTTP listener on the LAN for push adapters (bound to the LAN interface only, allow-list of device IPs) |
| Local queue | SQLite file, encrypted at rest; one row per punch with status (pending / sent / confirmed); confirmed rows pruned after 7 days |
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
