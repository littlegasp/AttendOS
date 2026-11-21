# AttendOS Biometric B5 — Revision 3: X2008 reference machine and offline DAT import

Status: **DOCUMENTATION AND ARCHITECTURE ONLY — for owner review.** No code, migration, hosted SQL, device
connection, device-setting change or eSSL software install. Date 21 Nov 2026. Branch `feature/biometric-b1`.

**DAT format observed (21 Nov 2026): BIOMETRIC_DAT_FORMAT.md records the supplied X2008 export (151 records, 6 tab-separated fields, CRLF) and replaces §4.3's pending record.**

**Revision 4 (DAT import readiness): BIOMETRIC_B5_REV4_DAT_IMPORT.md takes precedence for the DAT path.**

**Document history:** Revision 1 (generic agent, `a1b4773`) → Revision 2 (eSSL first, `1cab101`) → **Revision 3
(this document)**. Where they differ, Revision 3 wins. Revisions 1 and 2 remain the reference for the parts they
specify and this one does not change:

- Windows Service lifecycle, folders, upgrade/rollback, logging (rev 1 §2, §16, §17);
- the SQLCipher queue schema (rev 1 §8, rev 2 §7);
- the gateway API contract (rev 1 §24);
- eSSL SDK/ADMS research and the `essl/1` payload rule (rev 2 §1, §4.3).

---

## 0. Evidence labels (used everywhere in this document)

| Label | Meaning | Example |
|---|---|---|
| **[DEVICE]** | read directly from the physical X2008 by the owner (System Info screen); not interpreted | "Push Service 2.0.34-20180603" |
| **[DOC]** | stated in a manufacturer document (eSSL or ZKTeco) | K30 Pro "Push Data: Yes" |
| **[3P]** | third-party research: integrators, community, resellers — often about **other** models or firmware | an integrator's X2008 running different firmware |
| **[CODE]** | what the AttendOS repository actually does (migrations 0010–0012, app code at `1cab101`) | `source_auth` rules |
| **[UNVERIFIED]** | an assumption or open question; must not be relied on until tested or documented | whether this X2008 has an ADMS menu |

**Rules:**
- A **[DEVICE]** version string proves only that the component exists. It does **not** prove that a communication
  method works.
- **No claim made for K30 Pro, X990 or another X2008 carries over to this machine.**

---

## 1. The reference machine: eSSL X2008 [DEVICE]

All values were read by the owner from the device's own information screens and reported on 21 Nov 2026. The serial
number and MAC address are deliberately **not** recorded in any document in this repository.

| Item | Value [DEVICE] |
|---|---|
| Model | eSSL X2008 |
| Platform | ZMM210_TFT |
| Fingerprint algorithm | Finger VX10.0 |
| MCU version | 1020 |
| Firmware | 8.0.4.2-20180530 |
| Bio Service | 2.1.12-20151031 |
| Push Service | 2.0.34-20180603 |
| Standalone Service | 2.1.0-20160426 |
| System Version | 17.7.26-20161214 |
| Users | 28 / 5,000 |
| Fingerprints | 42 / 3,000 |
| Badges (cards) | 1 / 5,000 |
| Attendance records | 31,207 / 100,000 (31 % used) |

**What these values do *not* establish** (each is [UNVERIFIED] until tested):
- that the ADMS/Cloud Server menu is present or enabled on this unit;
- that the "Push Service" speaks a protocol version compatible with any published document;
- that SDK pull over TCP/IP works or which SDK build matches;
- whether the device deletes old records when the 100,000 limit is reached.

---

## 2. X2008 compatibility assessment

### 2.1 What outside evidence says, and why it does not transfer

| Evidence | What it says | Why it is not proof for this machine |
|---|---|---|
| [3P] An open integration guide (Sep 2026) for an **X2008 on firmware ZLM60_TFT 8.0.4.3-20230601, `pushver 2.4.1`** | ADMS push works over **plain HTTP only** (no redirects); paths `/iclock/cdata.aspx`, `/iclock/getrequest.aspx`; ATTLOG lines are tab-separated, CRLF-terminated, fields PIN, time, InOut, VerifyMode, WorkCode; a server command made the device upload `OPERLOG` incl. **fingerprint template (`FP`) lines** | **different platform (ZLM60 vs ZMM210), firmware (8.0.4.3-2023 vs 8.0.4.2-2018) and push version (2.4.1 vs Push Service 2.0.34)** |
| [3P] An open-source HRMS lists eSSL X2008 among devices it has "integrated and tested", using its ZKTeco method | some X2008 units have worked with a ZKTeco-style integration | firmware and method not stated |
| [DOC] ZKTeco: the same ZMM210 core board ships with **different firmware builds** (access-control push, standalone, or attendance push) | the firmware build, not the hardware, decides what the device speaks | confirms that model name and board alone don't settle compatibility |
| [DOC] ZKTeco distributors: some models need a **firmware licence or upgrade to enable ADMS** | ADMS can be absent on a given unit | applies directly as a caution |
| [3P] Some ZK-family vendors (e.g. FingerTec) write an **encrypted** `1_attlog.dat` to USB | a `.dat` export is not necessarily plain text | the format must come from inspecting our own file |

### 2.2 X2008 compatibility matrix (this unit, firmware 8.0.4.2-20180530)

| Capability | Status | Basis | What would verify it |
|---|---|---|---|
| **USB attendance export to `.dat`** | **Reported by the owner as the current workflow**; file format **[UNVERIFIED]** — no original file inspected yet | owner workflow; [3P] other ZK devices export `X_attlog.dat` | inspect an original exported file (M1) |
| Original DAT format (fields, separators, encoding, line endings, header) | **[UNVERIFIED] — pending inspection** | [3P] other devices: tab-separated, no header; some vendors encrypt | M1 inspection report |
| SDK / TCP/IP pull | **[UNVERIFIED]** | [3P] other X2008 units and the eSSL family generally; no [DOC] for this firmware | bench test with the official SDK package (M12) |
| ADMS / Push Service | **[UNVERIFIED]**: the component version exists [DEVICE]; menu presence, protocol version and HTTPS unknown | [DEVICE] Push Service 2.0.34; [3P] another X2008 firmware pushes over plain HTTP | (a) owner photographs the Comm menu without changing anything; (b) bench test (M12) |
| Firmware-specific protocol support | **[UNVERIFIED]**: push protocol document for Push Service 2.0.34 not obtained | — | official document from eSSL/ZKTeco ([E8]) |
| Communication authentication | **[UNVERIFIED]**: Comm Key setting expected on ZK-family devices [DOC: ZKTeco F18 manual], not seen on this unit | — | owner checks the Comm menu (no changes); bench test |
| Historical record retrieval | USB: owner reports exporting records; network: **[UNVERIFIED]** | owner workflow | M1 (USB) and M12 (network) |
| Stable event IDs / sequence numbers | **[UNVERIFIED] — assume none**; the design uses the fingerprint basis | no evidence for this firmware | M1 (does the file carry an index?) and M12 |
| Read-only access without deleting records | USB export: **[UNVERIFIED]** whether the export menu offers or implies deletion; network: adapters never call delete, but device behaviour is unverified | — | owner notes the exact menu path and any "delete after download" option; M12 |
| Template / photo exposure | USB: **[UNVERIFIED]** whether user/template files are written alongside the attendance file; push: [3P] another X2008 sends `FP` template lines on request | [3P] | M1 (list every file the export creates); M12 packet capture |
| Overflow behaviour at 100,000 records | **[UNVERIFIED]**; [DOC] ZKTeco push devices can auto-delete oldest records | [DOC] | device menu inspection; M12 |

**Matrix entry for planning tables (replaces any eSSL "research example" for this machine):**

| Model | Firmware | Communication | SDK | Push | LAN pull | Agent requirements | Network | Licensing | Known limitations | Evidence | Verification status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| eSSL X2008 (ZMM210_TFT) | 8.0.4.2-20180530; Push Service 2.0.34; Standalone 2.1.0 [DEVICE] | USB export (owner workflow); TCP/IP and push [UNVERIFIED] | [UNVERIFIED] | component present [DEVICE]; working push [UNVERIFIED] | [UNVERIFIED] | **none for DAT import**; agent + x86 SDK host (pull) or LAN receiver (push) later | none for DAT import; device VLAN later | SDK terms unknown | DAT format not yet inspected; 31 % of log used | [DEVICE] values; [3P] for other firmware only | **device facts recorded; every communication capability unverified** |

---

## 3. Three ingestion paths, kept separate

```
PATH 1  DAT IMPORT (now) — no agent, no LAN connection to the device
  X2008 ──USB stick──► Admin PC browser ──HTTPS 443, Admin sign-in (RLS)──┐
                                                                         ▼
                                              import staging (0013 proposal):
                                              no raw events, no projection,
                                              no register rows

PATH 2  SDK PULL (later) — Sync Agent (Windows Service + x86 SDK host)
  X2008 ◄──TCP 4370, Comm Key── Agent ─► SQLCipher queue ─► HTTPS 443 ──┐
                                                                        ▼
PATH 3  ADMS PUSH (later) — Sync Agent LAN receiver (one LAN IP)        │
  X2008 ──HTTP on LAN──► Agent ─► SQLCipher queue ─► HTTPS 443 ─────────┤
                                                                        ▼
                                    rpc/biometric_ingest (agent key in POST body)
                                    → raw events (0011) → projection only if enabled
```

| | DAT import | SDK pull | ADMS push |
|---|---|---|---|
| Runs in | AttendOS web app (Admin) + checked database functions | Sync Agent (Windows Service + x86 host) | Sync Agent (Windows Service) |
| Depends on the other two? | **No.** Shares no code, process, credential or queue with the agent | no | no |
| Needs network to the device | **No** | yes (LAN) | yes (LAN) |
| Credential | Admin's normal sign-in | agent key (DPAPI) + device Comm Key | agent key; device identity = serial + IP |
| Lands in | **import staging only** (0013 proposal) | `biometric_raw_events` via gateway | same |
| Trust classification | `import` (file, not device) | `authenticated` when Comm Key configured | `unauthenticated_lan` |
| Attendance effect | **none** | projection if enabled (0012) | flagged → HR acceptance per punch |

Unchanged architecture (rev 1/2):
- .NET 10 Windows Service; SQLCipher + DPAPI; outbound HTTPS only;
- vendor-neutral `IBiometricAdapter`, with eSSL-specific SDK and ADMS adapters;
- mock devices first; no service-role key on the agent;
- no internet-facing receiver;
- no template or photo collection on any path.

---

## 4. `essl.dat_import` — offline DAT import architecture

### 4.1 What it does and does not do

**It does:**
- keep the original file byte-for-byte;
- keep every line in its original order, with every raw field as the original string;
- record the file hash and the import metadata;
- show which rows are duplicates and of what;
- show which codes have an approved mapping.

**It never does any of these:**
- infer IN/OUT;
- convert codes to numbers;
- change a timestamp;
- calculate attendance;
- write `attendance_events` or any register row;
- create `biometric_raw_events`;
- call or trigger projection;
- create or guess employee mappings.

### 4.2 Where it runs

- A screen in the existing **Biometric Devices** module: "Import device file". Admin only [Decision R8].
- The browser reads the file and computes a SHA-256 for display only.
- It uploads the bytes to checked database functions, which compute the **authoritative** hash and parse the file
  **on the server**. The browser never sends parsed rows, so a modified browser can't alter what is stored [R1].
- No Windows Service, no agent key, no LAN access, no device connection. It works with the device switched off.

### 4.3 DAT format — **pending inspection of the original file**

**No original `.dat` file has been supplied to this design session.** As instructed, the format is **not** documented
from assumptions. M1 produces the format record by inspecting the owner's original export, under these rules:
- read-only inspection of a copy;
- the real file is **never committed** to the repository (it holds personal data, and its name may contain the
  device serial);
- tests use synthetic fixtures built to the same structure.

**M1 format record (to be filled from the file; every field meaning not documented by eSSL is marked "unknown"):**

| Property | Value | Source |
|---|---|---|
| File name pattern (serial / machine number redacted) | pending | file |
| Other files written by the same export (user, template, photo files?) | pending — **any template/photo file is out of scope and is never uploaded** | USB listing |
| Size, line count | pending | file |
| Encoding / binary or text / encrypted? | pending | byte inspection |
| Byte-order mark, line terminator (CRLF/LF), final newline | pending | byte inspection |
| Header line | pending | file |
| Delimiter (tab / spaces / other), constant field count? | pending | file |
| Field 1 … n: example shape (digits redacted), meaning | pending; meanings **unknown** unless documented by eSSL | file + [DOC] only |
| Timestamp string format, seconds present | pending | file |
| Leading zeros in codes present? | pending | file |
| Rows in time order? Identical rows present? | pending | file |
| Does the record count match the device's 31,207 at export time? | pending | file vs [DEVICE] |

Third-party descriptions of other devices' `attlog.dat` (tab-separated, no header; code, time, then numeric fields;
some vendors encrypt) are recorded **only as hypotheses to check**, not as the format.

### 4.4 Processing steps (server side)

1. **Start batch.**
   - Inputs: file name, size, the Admin's chosen **source device** (X2008 registered as an `essl` device with
     `integration_method = file_import`), declared **time zone** (default: the device's, else the company's)
     [R4].
   - Refused if the same SHA-256 already exists for the company (0010 already enforces `unique (company_id,
     file_sha256)`); the answer names the earlier batch.
2. **Upload original bytes** in ordered chunks (≤ 512 KB each, each with its own hash), then **finalise**:
   - the server joins the chunks and checks the total SHA-256 and size;
   - the original is stored unchanged [R2];
   - a 100,000-record file is about 4 MB.
3. **Safety check before parsing:** a file that is not text, or that contains template, photo or user-table content,
   is refused **without storing it**. The rule comes from the M1 format record.
4. **Split and parse in chunks** of at most 5,000 lines per call, each well inside the 8 s statement timeout for
   signed-in calls (docs/PERFORMANCE.md; the timeout is not raised). For every line it stores:
   - `line_no` (1-based, file order);
   - `raw_line` (exact text without its terminator, terminator recorded);
   - `fields` (exact strings split by the documented delimiter);
   - `parse_status`: `ok`, `blank`, `unparsable` with a reason.
   - Field 1 is copied to `employee_code` and the timestamp field to `local_time` **as strings**. Codes outside
     `[A-Za-z0-9_-]{1,32}` are kept, marked `code_invalid`.
5. **Classify duplicates — evidence is never discarded.** Every row stays; a label points at the earlier row:

   | Label | Rule |
   |---|---|
   | `exact_in_file` | identical `raw_line` earlier in this file (points to that line) |
   | `exact_in_earlier_import` | identical `raw_line` from the same source device in an earlier batch (points to batch + line). This is the normal case: each USB export repeats all older records |
   | `same_code_time_other_fields` | same code and timestamp string, other fields differ (possible conflict, shown to the Admin) |
   | `already_from_device` | same code and time already received from this device through the agent (fingerprint basis) — for later, when paths 2/3 exist |
   | `new` | none of the above |

6. **Mapping preview (read-only):**
   - For each `new` row, show whether an approved mapping exists at that time. **Nothing is created automatically.**
   - Unmapped codes are listed for the Admin to map through the existing mapping screen (which already requires
     an explicit decision and a validity date).
7. **Batch status:**
   - `draft` → `reviewed` (the Admin has looked at the counts) → `closed`.
   - Nothing beyond staging happens in M2.
   - Promoting rows to `biometric_raw_events` (`source_auth = import`) is a **separate later step with its own
     approval** [R3]. Even then, 0012 already holds every import with `import_not_enabled`, so no attendance can
     result.

### 4.5 Known mapping

| Device user code (exact string) | AttendOS employee | Status |
|---|---|---|
| `10` | WR198 (`employees.emp_code`) | **the only confirmed mapping** (owner, 21 Nov 2026) |

- **No other mapping is assumed.**
- Whether the DAT file writes this code as `10` or zero-padded is unknown until M1. A mapping matches only the exact
  string.
- [CODE] Raw events from imports carry no `device_id` (0010: device *or* import batch). The current
  `biometric_resolve_mapping` therefore applies only **company-wide** mappings to imports.
- So the code-10 mapping must either be company-wide, or 0013 must resolve import rows through the batch's source
  device [R6].
- The mapping itself is created by the Admin in the app, not by this design.

### 4.6 Data model proposal (migration 0013 — **not written**; separate approval)

```
biometric_import_batches (exists, 0010) + columns: source_device_id, declared_timezone, file_size, line_count,
                                         parse_status, reviewed_by/at, closed_at   (status set extended accordingly)
biometric_import_files   (new) batch_id PK/FK on delete cascade, original_bytes bytea, sha256, chunk_count, encoding,
                                line_terminator, uploaded_by, uploaded_at
biometric_import_rows    (new) batch_id FK on delete cascade, line_no, raw_line, line_terminator, fields text[],
                                parse_status, parse_reason, employee_code text, local_time text, code_invalid bool,
                                dup_class, dup_of_batch, dup_of_line, preview_mapping_id (nullable, informational)
                                primary key (batch_id, line_no)
```

All new tables follow AttendOS rules:
- `company_id default my_company()` and row level security through `my_company()`;
- Admin-only functions; `check_company_refs` and `freeze_company_id`; an audit trigger;
- `revoke all … from anon`;
- no anon access (the agent never touches these tables);
- deleting a batch deletes its file and rows.

### 4.7 Tests for the DAT path (M2)

**Synthetic fixtures** match the M1 record. Every test asserts:
- the stored original's SHA-256 equals the file's;
- the row count equals the line count;
- the order is preserved;
- `attendance_events`, `biometric_raw_events` and `biometric_event_state` are **unchanged**.

| Test | Acceptance |
|---|---|
| byte-exact round trip (CRLF, no final newline, BOM if present) | downloaded original identical to the upload |
| codes `0010`, `010`, `10` | three different codes; nothing trimmed or converted |
| timestamps incl. impossible dates | strings unchanged; impossible ones `unparsable` with reason; nothing corrected |
| duplicate lines in one file; overlapping second export; same code + time with a different status field | correct `dup_class` with pointers; every row kept |
| same file twice | refused, earlier batch named |
| template/photo/user file or binary data | refused, nothing stored |
| 100,000 lines | every call < 8 s; complete batch |
| non-Admin, other company, anon | refused by RLS / functions |
| status field values | no direction stored anywhere |
| delete batch | file and rows gone |

---

## 5. Trust classifications and their limits

| Path | Classification (gateway or import) [CODE] | What it does show | What it does **not** show |
|---|---|---|---|
| SDK pull with configured Comm Key | `authenticated` (0011: only `sdk_pull` + `device_auth = comm_key`) | the agent, holding a valid agent key, read the record from a device that required the configured Comm Key, i.e. **who delivered it and over which configured path** | not cryptographic proof of each punch; the Comm Key is a short numeric connection password ([DOC] ZKTeco: "a password is required to connect"); no evidence the LAN traffic is encrypted; it doesn't prove the device clock was right or that the enrolled finger belongs to the mapped person |
| ADMS push | `unauthenticated_lan`, flagged → per-punch HR acceptance | the request came from a registered device serial at the expected LAN address, to a receiver reachable only on the device network | the serial and IP can be copied by anyone on that network; [3P] other X2008 firmware pushes over plain HTTP. Upgrade only if a **documented and verified** device authentication mechanism is established (rev 2 [E7]) |
| DAT import | `import` (0010 `source_auth`; 0012 holds imports `import_not_enabled`) | an Admin uploaded this exact file at this time; its hash and content are preserved unchanged from that point | **no physical-device authentication**: a text file can be edited before upload; the file name or content does not prove which device wrote it. The chosen source device is the Admin's statement |

The agent and the import never send or claim a higher trust level than the gateway assigns.

---

## 6. Network and security diagram (updated)

```
 OFFICE                                       │ INTERNET
                                              │
 X2008 (no network change)                    │
   │ USB stick: original .dat only;           │
   │ delete from stick after upload           │
   ▼                                          │
 Admin PC — browser signed in to AttendOS ────┼── HTTPS 443 ──► AttendOS app (Cloudflare)
 (no agent, no LAN access to the device)      │                 → Supabase Mumbai: checked
                                              │                   functions + RLS, import
                                              │                   staging (0013)
 ── later, after separate approval ────────── │ ─────────────────────────────────────────
 eSSL devices on a device VLAN                │
   ▲ TCP 4370 (pull)  │ HTTP to one LAN IP    │
   │                  ▼ (push)                │
 Sync Agent (Windows Service, SQLCipher +  ───┼── HTTPS 443 ──► rpc/biometric_heartbeat,
 DPAPI; no inbound from the internet)   outbound only           rpc/biometric_ingest
                                              │                 (anon, agent key in body)

 No port forwarding, no UPnP, no public receiver, no device port exposed to the internet.
```

**DAT-specific handling of personal data:**
- The stick and the PC hold codes and punch times. Delete the file from the stick after a successful upload, and
  don't use shared or public PCs.
- The original file name may contain the device serial. It is stored in the database (Admin-only), and never put
  in docs, test fixtures or logs.

---

## 7. Phased implementation plan (updated priority)

Each milestone needs separate approval and ends with a stop for review. **The DAT path (M1–M2) doesn't depend on
any hardware connectivity.**

| Milestone | Scope | Files (indicative) | Dependencies | Security requirements | Tests | Acceptance | Risks |
|---|---|---|---|---|---|---|---|
| **M0** Owner decisions, architecture freeze | §8 decisions; freeze the three-path split and trust table | this document | owner | — | — | approval recorded | — |
| **M1** DAT format investigation + mock parser design | inspect a **copy** of the original export read-only; fill the §4.3 record; list every file the export creates; write a parser design and synthetic fixtures | `docs/biometric/BIOMETRIC_DAT_FORMAT.md`, `tests/fixtures/dat/*` (synthetic only) | **original file from the owner**; no device connection | real file never committed; serial redacted | fixture review | format record complete; unknown meanings marked unknown | file encrypted or non-text → stop and report |
| **M2** Local DAT import (after separate approval) | migration 0013 staging tables + checked functions; Admin import screen; Help guide section | `supabase/migrations/0013_*.sql`, `src/components/biometric/*`, `src/content/*`, tests | M1; local stack only | §4.6 rules; RLS tests; no raw events, no projection | §4.7 + database tests + browser tests | all §4.7 criteria; existing suites green | 8 s timeout on large files → chunk sizes tuned |
| **M2b** Promote reviewed rows to raw events | `source_auth = import`, still held `import_not_enabled` | 0014 proposal | M2; owner decision [R3] | no projection | — | — | — |
| **M3** Agent skeleton | rev 1 M1 | `agent/…` | M0, [D4] | redaction | rev 1 | rev 1 | — |
| **M4** Encrypted queue + secrets | rev 1 M2, rev 2 §7 | | [D2] licence | rev 1 | rev 1 | rev 1 | licence |
| **M5** Gateway client | rev 1 M3 | | M4 | rev 1 | rev 1 | rev 1 | — |
| **M6** Mock eSSL SDK/ADMS adapters | rev 2 M4, tests T1–T15 | | M5 | rev 2 | rev 2 §9 | rev 2 §9 | — |
| **M7** ADMS LAN receiver | rev 2 M5; must drop `OPERLOG`/`FP`/photos and never send commands | | M6, official protocol doc [E8] | rev 2 §3.1 | rev 2 + fuzz | rev 2 | firmware variation |
| **M8** Installer + CLI | rev 1 M6 | | [D3] | rev 1 | rev 1 | rev 1 | — |
| **M9** Admin agent screens | rev 1 M7 | | separate approval | rev 1 | rev 1 | rev 1 | — |
| **M10** eSSL SDK adapter (fixtures) | rev 2 M8 | | [E3] SDK terms | rev 2 | rev 2 | rev 2 | COM interop |
| **M11** X2008 menu observation | owner photographs System Info, Comm (ADMS / Comm Key) and USB menus **without changing anything** | doc update | owner | serial/MAC redacted | — | matrix §2.2 updated from [DEVICE] facts | — |
| **M12** X2008 SDK/ADMS bench verification | rev 2 §10 P1–P8 on the X2008, read-only, isolated network, test company | compatibility doc | M10, M7, official docs, **separate hardware authorisation** | no settings changed except as approved | P1–P8 | "hardware-verified" for this model + firmware only | firmware 2018 may lack features |
| **M13** Pilot; later ZKTeco and Matrix | rev 2 M10–M12 | | M12 | | | | |

---

## 8. Owner decisions

**New for Revision 3 (DAT import):**

| # | Decision | Options | Recommendation |
|---|---|---|---|
| **R1** | Where the DAT file is parsed | server (database function, from stored bytes) · browser (sends parsed rows) | **server** — the stored rows always derive from the stored original |
| **R2** | Where the original file is kept | database (`bytea`, Admin-only, cascades with the batch) · Supabase Storage private bucket (Mumbai) with policies | **database** — one access model, deletion follows the batch, about 4 MB per file |
| **R3** | What happens after review | staging only for now · promote to `biometric_raw_events` (`import`), still held from projection | **staging only in M2**; promotion as M2b with its own approval |
| **R4** | Time zone for DAT timestamps | the source device's zone · the company's zone · ask on every import | device zone, shown and confirmable on every import |
| **R5** | Duplicate labels (§4.4 step 5) | as proposed · stricter/looser | as proposed — nothing ever removed |
| **R6** | Mapping scope for imports (code `10` → WR198) | company-wide mapping · per-device mapping resolved via the batch's source device (0013) | per-device via the source device; company-wide only if the same code means the same person on every device |
| **R7** | Retention of uploaded files and rows | keep until an Admin deletes the batch · fixed period (e.g. 1 year) | fixed period, owner to choose; deletion removes file and rows |
| **R8** | Who may import | Admin only · Admin + HR | Admin only |
| **R9** | Handling of the real DAT file during M1 | owner provides a copy for read-only inspection, never committed · owner inspects and reports structure only | copy for inspection, never committed, deleted after the format record is approved |
| **R10** | X2008 menu observation (M11) | owner photographs menus without changes · skip until bench test | photograph now — it settles ADMS presence, Comm Key and USB export options without touching settings |

**Still open from Revision 2** (unchanged unless noted):
- **E2 (revised):** the first ingestion path is DAT import. Pull vs push for later network collection is still to
  be decided.
- **E1:** superseded. The X2008 is the reference machine; buying another unit is a separate question.
- **Remaining E decisions:** E3 SDK licence terms; E5 adapter version recording; E6 model/firmware mismatch
  alerts; E7 push device identity; E8 official push protocol document; E9 device clock (report only); E10 payload
  `essl/1`; E11 overflow setting; E12 first-run cut-over.

**Still open from Revision 1:** D2 SQLCipher licence; D3 code signing; D4 agent code location; D5 push trust;
D6/D7 telemetry and agent errors; D8 fast clocks; D9b invalid codes; D12–D20.

---

## 9. Sources

- [DEVICE] X2008 information screen values, read by the owner (21 Nov 2026); serial and MAC withheld.
- [CODE] `supabase/migrations/0010_biometric_core.sql` (import batches, raw events, mappings,
  `biometric_resolve_mapping`), `0011_biometric_gateway.sql` (`source_auth`), `0012_biometric_projection.sql`
  (`import_not_enabled`); docs/PERFORMANCE.md (8 s timeout).
- [3P] X2008 integration guide, firmware ZLM60_TFT 8.0.4.3, pushver 2.4.1: https://github.com/Abdullah801953/biometric-device-integration-sop
- [3P] Open-source HRMS device list incl. eSSL X2008: https://github.com/horilla-opensource/horilla/discussions/338
- [DOC] ZKTeco F18 product page (ZMM210 core board; access-control push, standalone and attendance push firmware): https://www.zkteco.com/en/product/F18.html
- [DOC]/[3P] ADMS enabled by firmware licence or upgrade on some ZKTeco models (distributor): https://syscom.mx/products/85722
- [DOC] ZKTeco F18 manual (Comm Key; `X_attlog.dat` USB download): https://www.manualslib.com/manual/3008180/Zkteco-F18.html?page=33 ; https://www.manualslib.com/manual/1343519/Zkteco-F18.html?page=74
- [3P] Attendance log file described as tab-delimited, no header (other devices): https://sundialtimesystems.freshdesk.com/support/solutions/articles/1000291359-timekeeper-timecards-import-attendance-file
- [3P] Encrypted `1_attlog.dat` on FingerTec terminals: https://tips.fingertec.com/biobridge/2011DecryptingALog.pdf
- Revision 2 sources (eSSL, ZKTeco push, ePushServer): BIOMETRIC_B5_ESSL_FIRST_DESIGN.md §13.
