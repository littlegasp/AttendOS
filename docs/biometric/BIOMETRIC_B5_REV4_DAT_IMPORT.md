# AttendOS Biometric B5 — Revision 4: DAT import implementation readiness

Status: **DOCUMENTATION AND DESIGN ONLY — for owner review.** Migration 0013 is **not** written. No frontend, backend
or SQL code; no SQL run; no device connection or settings change; no eSSL software. Date 21 Nov 2026. Branch
`feature/biometric-b1`.

**Scope.** Revision 3 (`311878d`) set the three-path direction, and the owner accepted it:
1. Offline USB DAT import — immediate priority.
2. SDK pull — future.
3. ADMS push — future.

This revision does **not** redesign or merge the paths. It makes path 1 ready to build. Where this document and
Revision 3 §4 differ, this document wins. The agent design (Revisions 1–3) is unchanged.

**Still pending:** an original `.dat` file has not yet been supplied. Every format rule below that depends on the file
is written as a **check against the M1 format record** ("M1 says …"), not as a guess about the format.

---

## 0. Code facts this design depends on (inspected at `311878d`)

| # | Fact [CODE] | Where | Consequence |
|---|---|---|---|
| C1 | Mappings: `device_id` null = company-wide; validity `[valid_from, valid_to)`; overlaps refused by exclusion constraints **per scope** (device or company-wide) for the same code and for the same person; history can only be ended, never edited or deleted | 0010 `biometric_employee_mappings`, `biometric_mapping_guard`, `mapping_no_delete` | at most **one** device mapping and **one** company-wide mapping can apply to a code at any instant |
| C2 | `biometric_resolve_mapping(company, device, code, at)` — device mapping valid at `at` first, else company-wide valid at `at`, else none | 0010 l.555 | DAT resolution reuses it, passing the batch's **source device** (§3) |
| C3 | `biometric_save_mapping` **trims spaces** from the code and requires `^[A-Za-z0-9_-]{1,32}$`; device mappings: HR of that employee; company-wide: Admin only, with an explicit confirmation | 0010 l.696 | DAT codes are never trimmed. A DAT code with spaces can never match a mapping → `code_invalid` (§3.4) |
| C4 | `audit_log` is **append-only for ever**: no update, delete or truncate, even from the SQL editor (trigger) | 0005 l.170–181 | anything written there can never be removed → **no personal data or file content may go into it** (§6) |
| C5 | The generic `audit()` trigger copies **whole rows** (`to_jsonb(old/new)`) into `audit_log` | 0003 l.341 | **must not** be attached to the DAT file, chunk or row tables; explicit minimal audit entries only |
| C6 | `biometric_import_batches` exists: `unique (company_id, file_sha256)`, status `draft/approved/rejected` | 0010 | 0013 replaces the full unique constraint with a partial one (§2.7) and extends the states (§2.2) |
| C7 | A raw event has `device_id` **or** `import_batch_id`; the raw-event guard **refuses punches older than `backfill_days` (31, max 92)** | 0010 l.231, 274–276 | promoting historical DAT rows to raw events (M2b) is impossible under today's rules — M2b needs its own design ([R13]) |
| C8 | `biometric_parse_local`: strict `YYYY-MM-DD[ T]HH:MM[:SS[.ffffff]]`, years 2000–2100, real calendar dates, else null | 0011 l.80 | reused for DAT local-time parsing so all paths agree on what a valid device time is |
| C9 | Raw-event guard sets `dst_ambiguous` when the zone's offset changes within ±3 h; Postgres itself silently picks an offset for ambiguous or non-existent local times | 0010 l.258–282 | DAT import detects both cases explicitly and **never** lets Postgres choose (§4) |
| C10 | `biometric_require(admin)`, `is_admin()`, `my_company()`, `hr_of()` exist; signed-in API calls have an 8 s statement timeout (docs/PERFORMANCE.md) | 0010, 0003 | all DAT functions are Admin-only and bounded well under 8 s per call |
| C11 | Projection holds every import (`import_not_enabled`) | 0012 l.416 | a second, independent barrier; M2 doesn't rely on it — M2 never creates raw events at all |

---

## 1. DAT import sequence (updated)

```
BROWSER (Admin)                          DATABASE (checked functions, Admin-only)
───────────────                          ─────────────────────────────────────────
pick file, source device, zone
hash file + 256 KiB chunks (Web Crypto)
  │
  ├─ dat_import_begin(...declared values) ─► check Admin, device, limits (§3.1),
  │                                          zone, same-file rule (§2.7);
  │                                          expire stale batches (§2.6)
  │◄─ batch_id, upload_token ───────────────  state UPLOADING
  │
  ├─ dat_import_chunk(i, bytes) × n ───────► lock batch; i = next or a repeat;
  │◄─ ok, next_index ───────────────────────  hash(bytes) = declared hash[i]
  │
  │   network drop / refresh:
  ├─ dat_import_status ────────────────────► received indexes + their hashes
  ├─ dat_import_resume ────────────────────► new token, old token invalid
  │
  ├─ dat_import_finish ────────────────────► join chunks; server SHA-256 + size
  │◄─ ok | FAILED(hash/size mismatch) ─────  = declared → UPLOADED
  │
  ├─ dat_import_validate ──────────────────► encoding, BOM, terminators, binary,
  │◄─ ok | FAILED(reason, line) ───────────  header, delimiter vs M1 record
  │                                          → PARSING (or FAILED, nothing kept)
  ├─ dat_import_parse(from_line) × k ──────► ≤ 5,000 lines per call: raw line,
  │◄─ next_line | done ─────────────────────  fields, time (§4) → CLASSIFYING
  │
  ├─ dat_import_classify(from_line) × k ───► duplicate labels (§6)
  │◄─ next_line | done ─────────────────────  → READY_FOR_REVIEW
  │
  │   Admin reviews counts, unmapped codes, duplicates, time problems
  ├─ dat_import_mark_reviewed(version) ────► REVIEWED  (M2 ends here)
```

Nothing in this sequence writes `biometric_raw_events`, `biometric_event_state`, `attendance_events` or any register
row, and nothing calls projection.

---

## 2. Upload and recovery

### 2.1 Batch creation and ownership

- `dat_import_begin` is Admin-only (`biometric_require(true)`). The batch belongs to the caller's company
  (`company_id default my_company()`, frozen).
- The **source device** must be an `essl` device of the same company (`check_company_refs`). Its status may be active
  or disabled: a disabled device's old export can still be imported.
- `uploaded_by` = `my_employee_id()`. Only the uploader can send chunks or finish, and only with the current
  `upload_token` (a random 256-bit value returned once). Another Admin can **cancel** the batch but not write to it.
- Declared at creation and **immutable** afterwards:
  - file name (stored only with the file; it may contain the device serial);
  - size;
  - SHA-256;
  - chunk count;
  - every chunk's SHA-256;
  - source device;
  - declared time zone.

  Changing any of them needs a new batch.

### 2.2 Upload / recovery state machine

```
 begin ok
    │
    ▼
 UPLOADING ── chunk ok / repeat ok ──► (stays UPLOADING)
    │   ├── cancel, or 24 h idle ─────────────────► EXPIRED / CANCELLED  ┐
    │   └── finish: hash or size mismatch ────────► FAILED(reason)       │ no bytes,
    ▼ finish: hash + size ok                                              │ no rows,
 UPLOADED                                                                 │ metadata
    │   └── unsupported format ───────────────────► FAILED(reason)       │ only
    ▼ validate ok                                                         │
 PARSING ── error, or no progress for 2 h ────────► FAILED(reason)       │
    │                                                                     │
    ▼ all lines parsed                                                    │
 CLASSIFYING ── no progress for 2 h ──────────────► FAILED(reason)       ┘
    │
    ▼ all lines classified
 READY_FOR_REVIEW ── mark reviewed ──► REVIEWED
    │                                     │
    └──── delete (Admin, reason) ─────────┴──► DELETED (tombstone: metadata only)
```

| State | Reviewable | Promotable (future M2b) | Holds bytes | Holds rows |
|---|---|---|---|---|
| UPLOADING | no | no | partial chunks | no |
| UPLOADED, PARSING, CLASSIFYING | no | no | yes | partial |
| READY_FOR_REVIEW | **yes** | no | yes | yes |
| REVIEWED | yes (read-only) | **only here**, and only after M2b exists and is approved | yes | yes |
| FAILED, EXPIRED, CANCELLED | no | no | **no** (deleted in the same transaction) | **no** |
| DELETED | no | no | no | no |

**Rules:**
- Every state change happens inside one function call that locks the batch row (`for update`) and checks the
  expected current state. So no two calls can move a batch at once, and an incomplete batch can never reach
  READY_FOR_REVIEW.
- Review screens and any future promotion read **only** batches in READY_FOR_REVIEW / REVIEWED. The database
  enforces this, not just the screen.

### 2.3 Chunks

- **Size:** 256 KiB of original bytes (the last chunk may be shorter), sent base64-encoded. That is ≈ 342 KiB of JSON
  per call, the same order as the gateway's proven 256 KB request cap.
- **Numbering:** indexes 0…n−1. The server accepts index `i` only when:
  - `i = next_index` and `sha256(bytes) = declared_hash[i]` → stored; `next_index` + 1; or
  - `i < next_index` and the hash equals the stored chunk's → **idempotent repeat**: `ok`, nothing changes; or
  - anything else → refused, batch unchanged:
    - `i > next_index` → `wrong_order`, the answer gives `expected_index`;
    - wrong hash → `chunk_hash_mismatch`;
    - repeat of `i` with different bytes → `chunk_conflict`.
- **Retry after a network drop:** the browser resends the same index; this is safe by the repeat rule. A lost answer is
  detected by `dat_import_status`.
- **Resume after refresh:**
  - The browser keeps `batch_id` in session storage. The token is **not** stored; a resume always takes over (§2.4).
  - The Admin re-selects the same file. The browser recomputes the whole-file and per-chunk hashes, which must equal
    those declared, and asks `dat_import_status` for `next_index` and the hashes received so far. It then continues
    from `next_index`.
  - If the file differs, the browser refuses to continue and offers to cancel the batch.
- Chunks are stored in a separate table until finish. At finish they are joined into the original file and deleted.

### 2.4 Concurrency

- One active upload per batch, enforced by the token and the row lock. A second tab holding an old token gets
  `taken_over`.
- **Take-over:** `dat_import_resume(batch_id)` by the uploader issues a **new** token and invalidates the old one.
  Received chunks are kept.
- At most **3** batches in UPLOADING…CLASSIFYING per company. This bounds storage held by incomplete work.
- Two Admins uploading the **same file** at once: the second `begin` sees the first's declared hash (§2.7). It is
  refused with "this file is already being uploaded by another Admin (named) — wait or ask them to cancel".

### 2.5 Final verification

`dat_import_finish` joins the chunks in index order and computes SHA-256 and byte length **on the server**.
- If either differs from the declared values: FAILED `hash_mismatch` or `size_mismatch`, and chunks are deleted in
  the same transaction.
- The verified hash is then written to `file_sha256`, subject to the partial unique index (§2.7).

### 2.6 Abandoned batches and safe cleanup

- **Limits:** UPLOADING idle > **24 h** → EXPIRED. UPLOADED/PARSING/CLASSIFYING with no progress for > **2 h** →
  FAILED `processing_stalled`.
- **No scheduler is used** (pg_cron is not installed and not authorised). Expiry is **lazy**:
  - every `begin`, `status` and list call first expires up to 10 stale batches of the caller's company, in their own
    short statements;
  - the import list shows stale batches as "expired";
  - an Admin "Clean up" action runs the same routine.
- **Cleanup** deletes chunks, joined bytes and rows in **one transaction** with the state change. The batch row stays
  with its counts, reason and timestamps. A crash mid-cleanup rolls back to the previous state, so no half-deleted
  batch exists.

### 2.7 Same file uploaded twice

- 0013 changes `unique (company_id, file_sha256)` to a **partial** unique index: only batches in UPLOADED…REVIEWED
  hold the hash. FAILED, EXPIRED, CANCELLED and DELETED batches don't block a fresh attempt.
- At `begin`, the declared hash is checked against active batches of the company:

| Existing batch with that hash | Answer |
|---|---|
| UPLOADING by the same Admin | "resume?" (returns `batch_id`) |
| UPLOADING by another Admin | refused, names the uploader |
| UPLOADED … REVIEWED | refused: "already imported on <date> (batch …)"; nothing created |
| none | new batch |

- The declared hash is only a claim. The partial unique index on the **verified** hash at finish is the real guard.
- Overlapping but **different** exports (the usual case: each USB export repeats older records) are allowed. Their
  repeated rows are labelled, not removed (§5).

---

## 3. File safety limits and format handling

### 3.1 Limits

| Limit | Value | Justification |
|---|---|---|
| Original file size | **16 MiB** | the X2008 holds at most 100,000 records [DEVICE]; at a generous 160 bytes per line that is 16 MB. Third-party descriptions of other devices suggest 40–60 bytes per line, about 6 MB. 16 MiB is still small for the database and ≤ 64 chunks |
| Rows (lines) | **200,000** | 2 × the device's capacity: room for firmware that writes extra lines, while bounding parse work (≤ 40 parse calls of 5,000) |
| Line length | **512 bytes** (without terminator) | 8 × the longest expected attendance line; a longer line means a different or binary file. Exceeding it fails the whole file (§3.3) |
| Field count | **16** | far above the handful of fields expected; more means a different file type |
| Empty lines | kept as `blank` rows; > 1 % of lines → file refused | blank lines are evidence too; many of them mean the wrong file |
| Per call | ≤ 5,000 lines parsed or classified; one chunk per upload call | each call stays far inside the 8 s timeout without raising it |
| Open batches | ≤ 3 per company in progress (§2.4) | bounds incomplete storage |

The owner may change these limits before M2 ([R16]). Any change is recorded here first.

### 3.2 Encoding, BOM, line terminators

- **Accepted encoding:** UTF-8, which includes plain ASCII.
  - A UTF-8 BOM (`EF BB BF`) is recorded (`bom = utf8`) and ignored for parsing only; the stored original keeps it.
  - A UTF-16/32 BOM, or bytes that are not valid UTF-8 → refused `unsupported_encoding`.
  - If M1 shows that the X2008 writes another encoding, this rule is updated **before** M2. It is never guessed at
    run time.
- **Line terminators:** CRLF and LF are accepted and recorded **per line**. A missing terminator on the last line is
  accepted and recorded. A lone CR, or a mix of CRLF and LF in one file, is recorded and allowed only if M1 shows the
  device does it; otherwise → refused `unexpected_line_endings`.
- **Binary or encrypted:** refused `not_a_text_file` if any of these holds:
  - any NUL byte;
  - any C0 control character other than TAB, LF, CR;
  - more than 5 % of bytes outside printable ASCII + TAB/LF/CR in a sample of the first 64 KiB.

  An encrypted file (as some ZK-family vendors produce) fails these checks.

### 3.3 Header, delimiter and malformed rows

The **M1 format record** fixes the expected header (or "none"), delimiter, field count range and time-field position.
At `validate`:

| Situation | Result |
|---|---|
| First line doesn't match the expected header / row shape | whole file refused `unexpected_header` |
| Delimiter in the first 100 non-blank lines doesn't match M1 | whole file refused `unexpected_delimiter` |
| A line > 512 bytes or > 16 fields anywhere | whole file refused `line_too_long` / `too_many_fields` |
| Template, photo or user-table content per the M1 record (e.g. lines starting with a user/template marker) | whole file refused `not_an_attendance_file` |
| More than 2 % of non-blank lines malformed | whole file refused `too_many_malformed_rows` |
| Individual malformed lines within the threshold (wrong field count, unreadable time, invalid code) | **kept** as rows with `parse_status = unparsable` / `code_invalid` / `time_invalid` and a reason; counted and shown |

**When a whole file is refused:**
- the batch becomes FAILED with the reason and its counts;
- original bytes, chunks and any rows are deleted in the same transaction;
- the Admin sees the reason and the line number where it was found;
- **no partial import remains**, and nothing is silently dropped. The file itself is still on the Admin's stick
  and PC.

### 3.4 Row record (what is kept per line)

| Column | Content |
|---|---|
| `line_no` | 1-based position in the file (original order) |
| `raw_line` | exact text of the line without its terminator |
| `terminator` | `crlf`, `lf`, `cr`, `none` |
| `fields text[]` | exact substrings split by the M1 delimiter — no trimming, no case change |
| `employee_code` | field 1 exactly as written (e.g. `"0010"` stays `"0010"`) |
| `code_invalid` | true when the code fails `^[A-Za-z0-9_-]{1,32}$` — including spaces, which the mapping function would trim (C3) — so it can never silently match |
| `local_time_text` | the time field exactly as written |
| `local_ts` / `instant` / `time_status` | §4 |
| `parse_status`, `parse_reason` | `ok`, `blank`, `unparsable` (+ reason) |
| `line_hash` | SHA-256 of `raw_line` (used for exact-duplicate checks, §5) |
| `dup_class`, `dup_ref_*` | §5 |

Fields whose meaning is not documented by eSSL (e.g. status, verify, work code) are stored only in `fields[]`. They
are never named, interpreted or used for direction.

---

## 4. Time zone and timestamp handling

1. **The original string is never changed.** `local_time_text` holds the exact characters; nothing is trimmed,
   rounded or reformatted.
2. **The declared time zone is stored once per batch** (`declared_timezone`, IANA name checked by `valid_timezone`).
   - Default: the source device's `timezone`, shown on the import screen for the Admin to confirm.
   - The zone is never stored inside a row and never changed after `begin`.
3. **Local timestamp** (`local_ts`, timestamp without time zone) = `biometric_parse_local(local_time_text)` — the
   same strict rule as the agent path (C8). It must also match the M1 time format exactly. Otherwise `local_ts` is
   null and `time_status` is:
   - `bad_format` — the string doesn't match the M1 pattern;
   - `impossible_date` — e.g. 30 Feb, hour 24 or minute 60;
   - `out_of_range` — year outside 2000–2100.
4. **Normalised instant** (`instant`, timestamptz) is a **separate** value computed by this rule:
   - Let `z` = declared zone and `lt` = `local_ts`. The candidate offsets are the zone's UTC offsets 3 hours before
     and after `lt`.
   - **Non-existent** (spring-forward gap): `(lt at time zone z) at time zone z ≠ lt` → `instant = null`,
     `time_status = nonexistent_local_time`.
   - **Ambiguous** (fall-back overlap): `lt` reads back as `lt` under **both** candidate offsets → `instant = null`,
     `time_status = ambiguous_local_time`. The import never picks one of the two.
   - Otherwise `instant = lt at time zone z`, `time_status = ok`.
   - Asia/Kolkata has no DST, so for the X2008 these two cases can only arise if the Admin declares another zone.
5. **Flags, never corrections:**
   - `future` — instant later than the upload time + 120 s (the company's `future_tolerance_s`);
   - `older_than_backfill` — older than `backfill_days`. This only matters for M2b (C7).
   - Neither changes or removes the row.
6. **No drift correction.** A wrong device clock produces wrong-looking times, which stay as recorded. Rev 2 E9: the
   device clock is fixed at the device, never by AttendOS.
7. Rows with `instant = null` can't be resolved to a person (§5 needs an instant). Their mapping status is
   `undetermined_time`.

---

## 5. Employee mapping resolution specification

### 5.1 Inputs

| Input | Source | Rule |
|---|---|---|
| company | the batch's `company_id` | never taken from the file |
| source device | the batch's `source_device_id` (Admin-chosen) | required; must be the company's device |
| code | `employee_code` exactly as in the file | **string equality**, case-sensitive, no trimming, no number conversion, leading zeros kept: `"10"`, `"010"` and `"0010"` are three different codes |
| at | `instant` (§4) | the original punch time; never the upload time |

### 5.2 Resolution

```
if code_invalid                          → status = code_invalid          (never matches; shown for correction at the device)
elif instant is null                     → status = undetermined_time
else m := biometric_resolve_mapping(company, source_device, code, instant)       -- existing function (C2)
     1. device mapping: device_id = source_device, same code, valid_from ≤ instant < valid_to (or open)
     2. else company-wide mapping: device_id null, same code, same validity test
     3. else none
  if m is none                           → status = unmapped
  elif employee of m is inactive today   → status = mapped_employee_inactive   (shown; not an error)
  else                                   → status = mapped (employee, mapping id, scope = device | company)
```

- **Device-specific mappings take precedence.** For the source device, a device mapping valid at that instant wins
  over a company-wide mapping. A company-wide mapping applies only at instants with no device mapping for that
  code on that device.
- **Same code on different devices** resolves independently. Code `10` on the X2008 and code `10` on another device
  can be different people, through their own device mappings.
- **Validity boundaries are half-open** `[valid_from, valid_to)`: a punch exactly at `valid_from` matches; a punch
  exactly at `valid_to` does not (it falls to the next mapping, or to company-wide, or to unmapped).
- **Conflicts:**
  - Two mappings in the same scope for the same code and time can't exist (C1 exclusion constraints).
  - Device vs company-wide overlap is not a conflict: precedence decides.
  - A row is shown as `mapping_conflict` only in one case: same code and same `local_ts` within the file
    (`same_code_time_other_fields`, §6) **and** the rows resolve to different people. That can only happen if a
    mapping boundary falls between them; they are shown together for review.
- **Unmapped codes** are listed with their row count and first/last time. The Admin maps them through the existing
  mapping screen, which needs an explicit decision and an effective date. **Nothing is ever mapped automatically**,
  not even by "looks like" matching with employee codes.
- **Preview, not storage.** Mapping status is computed when the batch is viewed, so a mapping added later shows
  immediately. Nothing is frozen in M2. Freezing at promotion is M2b's concern.

### 5.3 Known mapping

| Device | Code (exact) | Employee | Status |
|---|---|---|---|
| the X2008 device record | `10` | WR198 | **the only confirmed mapping** |

- **Recommended:** a **device-specific** mapping on the X2008 record, created by an Admin or HR in the existing
  mapping screen, with `valid_from` = the date the owner confirms WR198 started using code 10 on this device
  ([R11]).
- Not company-wide, unless the owner confirms that code 10 means WR198 on every device.
- If the file writes the code as `0010` (unknown until M1), a mapping for `10` won't match it, and the row shows
  `unmapped`. The mapping must use the file's exact string.
- No other mapping is assumed.

---

## 6. Duplicate detection across all paths

Duplicate labels never remove or hide a row. Every row stays, with one label and a pointer to the earlier evidence.
The labels are checked in this order, and the first match wins:

| Label | Compared with | Exact rule | Pointer |
|---|---|---|---|
| `exact_in_file` | earlier rows of the same file | same `line_hash` (identical raw line) | earlier `line_no` |
| `exact_in_earlier_import` | rows of earlier batches **for the same source device** in READY_FOR_REVIEW / REVIEWED | same `line_hash` | batch id + `line_no` |
| `same_code_time_other_fields` | same file and earlier imports for the same device | same `employee_code` string and same `local_ts`, different `raw_line` (the other fields differ) | the earlier row |
| `already_from_device` | `biometric_raw_events` from SDK pull **or** ADMS push with `device_id` = the batch's source device | same `employee_code` string and same device-local time (`device_local_time` parsed with the same function = `local_ts`); see the occurrence note below | `raw_event_id` + count |
| `new` | — | none of the above | — |

**Why the gateway's fingerprint is not reused as is:**
- The agent fingerprint (rev 2 §0) hashes `code|local_time|direction|verification|occurrence`.
- The DAT path deliberately has **no** direction or verification (their field meanings are undocumented), so the
  inputs and semantics differ.
- The DAT path therefore compares only the parts both paths certainly share: the device, the exact code string and
  the device-local time value.
- `local_ts` is compared instead of the string, because `2026-11-21T09:00:00` and `2026-11-21 09:00:00` are the same
  device reading.

**Occurrence:** if the file has k identical-key rows (same code, same `local_ts`) and the device path has j raw events
with that key, the first min(k, j) file rows (in file order) are `already_from_device`. The rest keep their own
label. Counts never collapse.

**Direction of comparison:**
- M2 checks DAT rows against existing raw events.
- SDK or ADMS events that arrive **after** an import are not compared by the gateway; 0011 is unchanged. A read-only
  "also in DAT import" indicator for raw events is a later item ([R14]).

**Scope:** only the batch's source device. Rows from different devices are never duplicates of each other, even with
the same code and time.

---

## 7. Security and retention specification

### 7.1 Access

- All DAT functions are `security definer` with a fixed `search_path`, and begin with
  `biometric_require(true)` (Admin of the caller's company).
- The new tables have row level security on, **no** direct grants to `authenticated`, and `revoke all … from anon`.
  They are reachable only through the functions.
- Every function checks `company_id = my_company()` on the batch. Other companies' batches answer `not found`, so
  their existence is not revealed.
- New tables follow the AttendOS multi-tenant rules:
  - `company_id default my_company()` + `freeze_company_id`;
  - `check_company_refs` on `source_device_id` and on duplicate pointers;
  - foreign keys `on delete cascade` from file, chunk and row tables to the batch.
- **HR** (non-Admin) has no access in M2 ([R8] kept: Admin only). Mapping creation keeps its existing rules (C3).
- **Download of the original** is an Admin function. Each download writes a minimal audit entry (§7.3).
- The anon gateway and the agent never touch these tables.

### 7.2 Retention (proposal — owner to confirm, [R12])

| Data | Holds personal data? | Proposed retention | Removed by |
|---|---|---|---|
| Original file bytes (+ file name, which may contain the serial) | yes (codes, times) | **90 days** after the batch reaches REVIEWED, or earlier by Admin delete | delete / retention |
| Parsed rows | yes | same as the original (they are derived from it) | same transaction as the original |
| Chunks of incomplete uploads | yes | until finish, expiry (24 h idle) or cancel | §2.6 |
| Batch metadata: state, counts by status and label, sizes, SHA-256, declared zone, source device id, uploader, timestamps, reasons | no personal content (ids, counts, a hash) | **3 years**, then the batch row is removed and only the audit entries remain | retention |
| Audit entries (§7.3) | none | **for ever** — `audit_log` is append-only (C4) | never |

- **Why 90 days:** long enough to cover the following payroll cycle and a dispute about it, then the device and its
  own exports remain the source.
- **Why 3 years for metadata:** it shows what was imported, by whom and when, without personal content.
- Legal retention needs (labour records) are for the owner to confirm. This design is not legal advice.
- **Enforcement without a scheduler:**
  - batches past retention are deleted lazily, by the same mechanism as §2.6, on Admin access to the import screen;
  - a "due for deletion" count is shown;
  - automatic scheduling is a later decision ([R15]; pg_cron stays uninstalled).

### 7.3 Deletion and audit

- **Admin delete** (reason ≥ 5 characters):
  - in one transaction, delete original bytes, chunks and rows;
  - set the batch to DELETED with `deleted_by`, `deleted_at`, reason;
  - keep the metadata (tombstone);
  - write one audit entry.

  Retention deletion does the same with the reason "retention".
- The generic `audit()` trigger is **not** attached to the import tables (C5).
- **Audit entries are written explicitly** for: begin, finish, failure, expiry, cancel, reviewed, download, delete,
  retention delete. Each holds only:

  ```
  action, batch_id, company_id, actor (auth uid), at,
  after = { "state": …, "reason": …, "size": …, "sha256": …, "rows": …, "counts": { "ok": …, "unparsable": …, … },
            "source_device_id": … }
  ```

  It **never** holds the file name, employee codes, times, raw lines, fields or bytes. A test asserts this (T-AU).
- Because `audit_log` can never be cleaned (C4), a mistake there would be permanent. That is why the entry shape is
  fixed and tested.

---

## 8. Tests and acceptance criteria (M2)

**Fixtures:** synthetic files built to the M1 format record. The real file is never committed.

**Global assertions after every test:**
- `biometric_raw_events`, `biometric_event_state`, `attendance_events` and the register outputs are unchanged;
- no batch outside READY_FOR_REVIEW / REVIEWED is returned by review functions;
- `audit_log` entries for the test contain no code, time, file name or line text.

| ID | Test | Acceptance criteria |
|---|---|---|
| T-UP1 | **Partial upload**: 3 of 5 chunks, then stop | state UPLOADING; not listed as reviewable; `finish` refused `missing_chunks` with the missing indexes |
| T-UP2 | **Duplicate chunk**: chunk 2 sent twice with identical bytes | second call `ok`, nothing changes; final file correct |
| T-UP3 | **Duplicate chunk, different bytes** | `chunk_conflict`; stored chunk unchanged |
| T-UP4 | **Wrong chunk order**: chunk 3 before chunk 2 | `wrong_order`, `expected_index = 2`; nothing stored |
| T-UP5 | **Wrong chunk hash** | `chunk_hash_mismatch`; nothing stored; retry with correct bytes succeeds |
| T-UP6 | **Final hash mismatch**: declared hash differs from the real file | FAILED `hash_mismatch`; chunks deleted; no rows; same file can be begun again |
| T-UP7 | **Size mismatch** | FAILED `size_mismatch`; as T-UP6 |
| T-UP8 | **Network interruption**: answer lost after chunk 4 is stored; client resends chunk 4 | idempotent `ok`; upload completes; hash verified |
| T-UP9 | **Resume after refresh**: new session, same file | status returns `next_index` and the received hashes; browser continues; result byte-identical |
| T-UP10 | **Resume with a different file** | the browser refuses; the server refuses any chunk whose hash differs |
| T-UP11 | **Concurrent upload**: two tabs, old token after take-over | old tab `taken_over`; new tab completes; no interleaved chunks |
| T-UP12 | **Concurrent same file by two Admins** | second `begin` refused, names the first uploader |
| T-UP13 | **Expired upload**: idle 24 h (clock injected in the test) | next list call marks EXPIRED; chunks deleted; metadata kept; audit entry without content |
| T-UP14 | **Stalled processing** > 2 h | FAILED `processing_stalled`; bytes and rows deleted |
| T-UP15 | **Same file twice** (after REVIEWED) | refused "already imported"; nothing created |
| T-UP16 | **Same file after FAILED / DELETED** | accepted as a new batch |
| T-UP17 | **Open-batch limit**: 4th concurrent batch | refused |
| T-SEC1 | **Cross-company**: Admin of company B calls every function with company A's batch id | `not found` everywhere; no data returned; no state change |
| T-SEC2 | **Non-Admin** (HR, employee) and **anon** call every function | `Not allowed` / no execute permission |
| T-SEC3 | **Direct table access** (select/insert on new tables as authenticated) | refused by grants and RLS |
| T-SEC4 | **Device of another company** as source device | refused at `begin` |
| T-FM1 | **Oversized file** (16 MiB + 1 byte declared, or real) | refused at `begin` / `finish`; nothing kept |
| T-FM2 | **Line too long** (513 bytes) / **17 fields** | FAILED with reason and line number; no rows kept |
| T-FM3 | **Binary file** (NUL bytes) / **high-entropy (encrypted-like) file** / **UTF-16 BOM** | FAILED `not_a_text_file` / `unsupported_encoding`; no bytes kept |
| T-FM4 | **Unexpected header / delimiter** | FAILED `unexpected_header` / `unexpected_delimiter`; no rows |
| T-FM5 | **Malformed rows under threshold** (1 %) | READY_FOR_REVIEW; each kept as `unparsable` with reason; counts exact; row count = line count |
| T-FM6 | **Malformed rows over threshold** (3 %) | FAILED `too_many_malformed_rows`; nothing kept |
| T-FM7 | **UTF-8 BOM, CRLF, no final newline** | accepted; downloaded original byte-identical; terminators recorded per line |
| T-FM8 | **Codes `10`, `010`, `0010`, ` 10`** | first three distinct `ok` codes; ` 10` is `code_invalid`; none trimmed |
| T-FM9 | **200,001 rows** | refused `too_many_rows`; nothing kept |
| T-TZ1 | **Impossible dates** (`2026-02-30`, hour 24, minute 60, year 1999) | string unchanged; `local_ts` null; `time_status` correct; row kept |
| T-TZ2 | **Declared zone with DST** (e.g. Europe/London): gap time and overlap time | `nonexistent_local_time` / `ambiguous_local_time`; `instant` null; mapping `undetermined_time` |
| T-TZ3 | **Asia/Kolkata** normal time | `instant = local_ts at time zone 'Asia/Kolkata'`; original string unchanged |
| T-MAP1 | **Mapping effective-date boundary**: mapping `10`→WR198 from 2026-11-01 00:00 IST | punch at 2026-10-31 23:59:59 → `unmapped`; punch at exactly 2026-11-01 00:00:00 → mapped |
| T-MAP2 | **End boundary**: mapping ended at T | punch at T−1 s mapped; punch at T falls through (company-wide or unmapped) |
| T-MAP3 | **Same employee code across different devices**: `10` on device A → WR198 (device mapping); `10` on device B → another person | DAT for A resolves to WR198; DAT for B resolves to the other person; never crossed |
| T-MAP4 | **Device vs company-wide precedence**: company-wide `10`→X and device `10`→WR198 | device mapping wins on its device; company-wide applies on devices without their own mapping |
| T-MAP5 | **Unmapped code** | listed with counts and first/last time; no mapping created |
| T-MAP6 | **Employee deactivated after mapping** | `mapped_employee_inactive`, shown, not an error |
| T-DUP1 | **Exact duplicate line within the file** | second row `exact_in_file` → earlier `line_no`; both rows kept |
| T-DUP2 | **Overlapping second export** of the same device | repeated lines `exact_in_earlier_import` with pointers; only new lines `new` |
| T-DUP3 | **Duplicate import versus SDK event**: raw event from device A (sdk_pull) with code `10` at a local time; DAT row with the same code and time | DAT row `already_from_device` → that raw event; raw event unchanged; DAT row kept |
| T-DUP4 | **Versus ADMS event** (local_push raw event) | as T-DUP3 |
| T-DUP5 | **Same code and time from a different device** | `new` (not a duplicate) |
| T-DUP6 | **Occurrence**: 3 identical-key DAT rows, 2 raw events | first 2 `already_from_device`, third keeps its file label |
| T-DUP7 | **Same code and time, different other fields** | `same_code_time_other_fields`, both kept and shown together |
| T-DEL1 | **Deletion and audit retention**: delete a REVIEWED batch | bytes and rows gone; batch row DELETED with reason; audit entries for begin…delete all still present; none contains codes, times, file name or line text |
| T-DEL2 | **Retention deletion** (clock injected past 90 days) | same as T-DEL1 with reason `retention` |
| T-DEL3 | **Delete during upload** (cancel) | CANCELLED; chunks deleted; later chunk calls refused |
| T-AU | **Audit entry shape** for every action | only the allowed keys of §7.3; JSON scanned for the fixture's codes, times and file name → none found |
| T-NO1 | **No side effects** across the whole suite | raw events, event state, attendance events, sync runs and projection queue unchanged; projection functions never invoked |

The M2 acceptance gate is all of the above passing on the local stack, plus the existing database, app and
regression suites green. Real-file checks then run once against the owner's original, read-only and never
committed, to confirm the M1 format record.

---

## 9. Data model delta for 0013 (design summary — not written)

| Object | Change |
|---|---|
| `biometric_import_batches` | add `source_device_id`, `declared_timezone`, `declared_size`, `declared_sha256`, `chunk_count`, `chunk_hashes bytea[]`, `upload_token_hash`, `uploaded_by`, `state` (§2.2), `fail_reason`, `progress_line`, `last_activity_at`, `counts jsonb` (numbers only), `reviewed_by/at`, `deleted_by/at`, `delete_reason`, `version`; replace the full unique on `file_sha256` with a partial unique (§2.7); the existing `status` column stays for compatibility and maps to the new states |
| `biometric_import_chunks` (new) | `batch_id`, `idx`, `bytes`, `sha256`; primary key `(batch_id, idx)`; cascade |
| `biometric_import_files` (new) | `batch_id` primary key, `file_name`, `original bytea`, `bom`, `encoding`; cascade |
| `biometric_import_rows` (new) | §3.4 columns, `local_ts`, `instant`, `time_status`, `line_hash`, `dup_class`, `dup_ref_batch`, `dup_ref_line`, `dup_ref_raw_event`; primary key `(batch_id, line_no)`; indexes on `(company_id, source_device_id, line_hash)` and `(company_id, source_device_id, employee_code, local_ts)` for duplicate checks |
| Functions | `dat_import_begin`, `_chunk`, `_status`, `_resume`, `_finish`, `_validate`, `_parse`, `_classify`, `_list`, `_rows` (paged), `_unmapped`, `_mark_reviewed`, `_cancel`, `_delete`, `_download`, `_cleanup` — all Admin-only |
| Not changed | `biometric_raw_events`, gateway (0011), projection (0012), mappings tables and functions |

---

## 10. Updated phased plan

| Milestone | Scope | Gate |
|---|---|---|
| **M0** | owner decisions below; freeze this specification | owner approval |
| **M1** | inspect a copy of the original X2008 export (read-only); fill the format record (Rev 3 §4.3) and the §3.3 header/delimiter/time-format rules; synthetic fixtures | original file supplied; record approved |
| **M2** | migration 0013 + functions + Admin import screen + Help guide + §8 tests, local stack only | separate implementation approval |
| **M2-hosted** | apply 0010–0013 to the hosted project | separate approval (no hosted SQL before it) |
| **M2b** | promotion of reviewed rows into raw events, incl. the 31-day backfill problem (C7) | own design and approval ([R13]) |
| **M3+** | agent milestones (Rev 3 §7 M3–M13) unchanged | as before |

---

## 11. Remaining owner decisions

| # | Decision | Recommendation |
|---|---|---|
| **R2** | Original file storage | database `bytea` (unchanged from Rev 3) |
| **R8** | Who may import / view imports | Admin only (unchanged) |
| **R9** | Supplying the original `.dat` for M1 | copy for read-only inspection, never committed, deleted after the format record is approved |
| **R11** | Effective-from date (and scope) of the mapping `10` → WR198 on the X2008 | device-specific, from the date the owner confirms; owner supplies the date |
| **R12** | Retention: original + rows 90 days after review; metadata 3 years; audit for ever | approve, or set other periods after a legal check |
| **R13** | M2b promotion: the raw-event guard refuses punches older than 31 days (C7), so historical DAT rows can't become raw events as designed | decide whether history goes to raw events at all (separate design), or whether DAT import remains a review/evidence path only |
| **R14** | Reverse duplicate indicator (agent events that arrive after a DAT import) | later, read-only |
| **R15** | Retention and expiry enforcement | lazy enforcement now; scheduled job only with a later pg_cron approval |
| **R16** | Limits: 16 MiB, 200,000 rows, 512-byte lines, 16 fields, 2 % malformed, 1 % blank, 24 h / 2 h expiry, 3 open batches | approve, or adjust after M1 shows the real file |
| **R17** | Rejected files: keep nothing (only metadata) vs keep the bytes for diagnosis | keep nothing — the Admin still has the file |
| **R18** | Declared zone for the X2008 | Asia/Kolkata (from the device record), confirmed on each import |

Still open from earlier revisions: Rev 3 R1–R7, R10 (R1 server-side parsing and R3 staging-only are confirmed in this
design; R6 is now specified in §5); Rev 2 E-decisions; Rev 1 D-decisions.

---

## 12. Sources

All facts in this revision come from the repository (`supabase/migrations/0001`, `0003`, `0005`, `0010`, `0011`,
`0012`; `docs/PERFORMANCE.md`) at `311878d`, and from the owner's statements (X2008 device values; mapping `10` →
WR198). External research is unchanged from Revision 3 §9 and isn't relied on for any rule here.
