# B5 DAT import Stages 1–2: post-implementation technical review

Status: **review only, awaiting owner decision.**
- Date: 23 Nov 2026. Reviewed commit: `e27ef9d` on `feature/biometric-b1` (parent `3ecdf17`).
- No implementation code and no part of migration 0013 was changed during this review.
- No hosted SQL, no production, no deploy/merge/tag, no X2008 connection, no pg_cron.
- All runs used the local PostgreSQL 16 stack and synthetic or throwaway copies of the local demo database.

Line references such as **0013:293** point to `supabase/migrations/0013_biometric_dat_import.sql` at `e27ef9d`.
Evidence files `E1`–`E7` are in the review package.

## 0. Verdict in brief

Company isolation, Admin-only access to the new functions, the locked staging tables, upload integrity, audit
minimisation and the "no attendance side effects" scope all hold. The SQL and the tests support this.

The review found **one functional defect that blocks approval for realistic file sizes**, plus five issues that
should be corrected before any hosted run:

| # | Severity | Finding | Blocks hosted use? |
|---|---|---|---|
| F2 | **High** (availability) | Processing a realistic full-history file (≈ 32,000 lines) times out at the 8 s limit, because the duplicate-labelling step degrades badly when table statistics are stale | **Yes** |
| F1 | **Medium** (exposure) | HR can read the import-batch table directly (file name, hashes, upload-token hash), through a 0010 grant that 0013 did not narrow | Yes |
| F4 | **Medium** (scope) | The X2008 format is accepted for **any** eSSL device, not only the X2008 | Yes |
| P1 | **Medium** (privacy) | One real record of another employee (code 7, file line 1) is in `BIOMETRIC_DAT_FORMAT.md` since commit `2910952` (pushed) | Owner decision |
| F5 | Low | The 3-open-batch limit can be exceeded by simultaneous starts (reproduced: 4 open) | No |
| F3 | Low (usability) | If the browser stops during processing, the screen offers no "continue processing", so the batch can only be cancelled or will fail after 2 h | No |
| F6 | Low | Chunk data is base64-decoded before its size is checked | No |
| F7–F9 | Information | search_path convention, cancel by any Admin, file name kept until deletion | No |
| R1 | Correction | My Stage 1–2 report said lines may end in CRLF **or LF**. The code accepts **CRLF only** and refuses any other ending (0013:414) | — |

No data was lost or corrupted in any scenario tested. Every failing call rolls back as one transaction.

## 1. Package contents

| Item | File in the package |
|---|---|
| Complete migration 0013 (with every RPC/function, RLS, grants, storage and deletion) | `source/supabase/migrations/0013_biometric_dat_import.sql` |
| Complete diff `3ecdf17..e27ef9d` (19 files, +2,999 / −15) | `git_diff_3ecdf17_e27ef9d.patch` (text) + `git_diff_f14_fixture_binary.patch` (synthetic fixture) + `diff_stat.txt` |
| Parser | inside 0013: `biometric_dat_split` (162–180), `_validate` (396–452), `_parse` (454–494), `_instant` (184–201), `_text` (385–394) |
| Duplicate labelling | `biometric_dat_classify` (498–578) |
| Mapping preview | `biometric_dat_row_mapping` (631–651), `_codes` (653–688), `_rows` (691–723) |
| Upload, storage, deletion | `_begin` (258–311), `_chunk` (313–341), `_resume` (344–356), `_finish` (358–382), `_purge` (204–209), `_expire` (212–232), `_cancel` (739–752), `_delete` (756–770), `_download` (772–782) |
| RLS and grants | 0013:142–149 (new tables), 0013:785–797 (functions); 0010:845–866 (batch table, unchanged) |
| Browser upload | `source/src/lib/dat-import.ts` |
| Screen | `source/src/components/biometric/DatImport.tsx`, `source/src/app/(app)/biometric/page.tsx` |
| Permission change | `source/src/lib/permissions.ts` (line 85) |
| Tests | `source/supabase/tests/biometric_dat_import_test.sql`, `source/tests/dat-import.test.ts`, `source/e2e/biometric_dat_import.py`, `source/supabase/tests/run.sh` |
| Evidence | `evidence/E1_catalog.txt` … `E7_privacy.txt` |

Excluded:
- the real export;
- the full parsed preview, which holds other employees' records and was sent separately with the Stage 1–2 package;
- `supabase/demo/postgrest.conf`, which holds the local demo JWT secret (a local test value, not a production secret).

The diff contains no production keys. The only names in it are the demo's fictional employees.

## 2. Security review

### 2.1 Company isolation (every operation)
- Every granted function starts `cid := public.biometric_require(true)`, which returns `my_company()` and refuses
  callers who are not signed in, not HR or not Admin (0010:578–586).
- Every batch read or lock filters on `company_id = cid`:
  - `biometric_dat_lock` (0013:239)
  - `_status` (599), `_batches` (626), `_codes` (657), `_rows` (695), `_download` (776)
- `begin` reads the device with `company_id = cid` (265).
- Another company's batch id answers **"not found"**, not "forbidden", so its existence is not revealed (240, 600).
- Duplicate look-ups across batches stay inside the company and device: `x.company_id = r2.company_id and
  x.source_device_id = r2.source_device_id` (525, 533). The raw-event look-up uses `ev.company_id = r2.company_id`
  (541). Mapping resolution uses `mm.company_id = cid` (644).
- Every new table carries `company_id`, composite foreign keys `(company_id, batch_id)` to the batch (90, 99, 131),
  and `freeze_company` triggers (138–140). The batch table has `check_company_refs` on uploader, approver, reviewer,
  deleter and source device (76–79).
- Tests: T-SEC1a–g and T-SEC4. A company-B Admin gets "not found" for status, rows, codes, download, delete and
  process on company A's batch, lists none of A's batches, and cannot import against A's device. Re-verified in this
  review on the demo (E1 and the session in §2.3): the other company's Admin sees 0 rows of A's batch table and gets
  "Import batch not found".

**Verdict: holds.**

### 2.2 Admin authorisation on upload, processing, review, deletion
- All 13 granted functions use `biometric_require(true)`, which is Admin only. E1a/E1b list exactly which functions
  `authenticated` may execute: begin, chunk, resume, finish, process, status, batches, codes, rows, mark_reviewed,
  cancel, delete, download.
- The 14 helpers (`audit`, `purge`, `expire`, `lock`, `fail`, `text`, `validate`, `parse`, `classify`,
  `row_mapping`, `split`, `instant`, `hex`, `limits`) are executable by **no** API role.
  - Several of them are security definer and take a company id as a parameter (`purge`, `expire`, `row_mapping`).
  - That is safe **only because** they are not granted. The grant loop at 785–792 revokes everything named
    `biometric_dat_%` before granting the 13.
- Upload continuation is restricted further to the uploading person: `uploaded_by is distinct from my_employee_id()`
  → "Not allowed" (320, 350, 364). Another Admin cannot send chunks, finish or take over (T-UP12b) but **can cancel**
  (T-DEL3, see F8).
- Review needs the current `version`, so a stale screen is refused (732, T-REV1).
- In the browser, the tab is shown only when `may("importBiometricFiles")` (page.tsx); that is convenience only. The
  server enforces.
- Tests: T-SEC2a–e (HR cannot send chunks, list imports or read rows; an employee cannot list imports; anon cannot
  call any DAT function).

**Verdict: holds for the functions.** See F1 for the directly granted batch table.

### 2.3 No direct table access for unauthorised users
- `biometric_import_chunks`, `_files` and `_rows` have RLS on, no policies and `revoke all … from public, anon,
  authenticated` (142–149). E1c shows `auth_sel = f` and `auth_write = f`. T-SEC3a–d: even an Admin cannot select
  directly, and a direct insert is refused.
- **F1, `biometric_import_batches` (Medium):**
  - 0010 created this table with policy `bio_read` (`company_id = my_company() and is_hr()`) and `grant select …
    to authenticated` (0010:845–866), so HR and Admin of the same company can `SELECT` it directly.
  - 0013 added 22 columns to it (40–68) without narrowing that grant.
  - Reproduced on the local demo as HR "Hema Kulkarni": a direct select returned the batch list with `file_name`.
    During an upload, the visible columns also include `upload_token_hash`, `chunk_hashes` and `delete_reason`.
  - The DAT function `biometric_dat_batches()` correctly refuses HR ("Not allowed"), so the screen and the table
    disagree.
  - Not cross-company: a manager and an Admin of another company see 0 rows.
  - The token **hash** is not usable to continue an upload. The token itself is 2 random UUIDv4s (≈ 244 random
    bits) and only its SHA-256 is stored (298, 303). Even with it, chunk and finish also require `uploaded_by =` the
    caller.
  - **Real exposure:** the uploaded file name, which for an X2008 export holds the device serial (see decision A),
    and import metadata, visible to HR without the import permission.
  - **Proposed correction:** in the corrected 0013 (it has never run on a hosted database), revoke table `SELECT` on
    `biometric_import_batches` from `authenticated`. Then either re-grant only the 0010 columns (id, company_id,
    rows, accepted, rejected, status, approved_by/at, created_at, updated_at) or rely on the functions alone. Add DB
    tests: HR direct select refused or limited; `upload_token_hash` never selectable by any API role.

### 2.4 Security-definer functions and search_path
- E1e: **no** security-definer function in schema `public` (any migration) lacks a fixed `search_path`. All 23 DAT
  security-definer functions use `set search_path = public` (E1a).
- Every table reference inside them is schema-qualified as `public.…`. A search of 0013 for unqualified
  `from/join/into/update/delete` targets found none (the only hit is the migration-time `DO` block over
  `pg_proc`). That matters because, with `search_path = public`, `pg_temp` is still searched first for relations:
  qualification is what prevents a caller's temporary table from shadowing a real one.
- Built-in functions and operators come from `pg_catalog`, which is always searched before `public`. On the local
  stack, `authenticated` and `anon` have no CREATE on `public` (E1f).
- **F7 (information):** the same must be true on the hosted project (`select has_schema_privilege('authenticated',
  'public','create')` must be `false`). That check is planned, not run (no hosted access). For new migrations I
  recommend `set search_path = pg_catalog, public, pg_temp`, which pins `pg_temp` last explicitly. 0013 follows the
  project convention used since 0001.

**Verdict: no unsafe search_path.**

### 2.5 No cross-company file or batch access
- Covered in 2.1. Files and rows are reached only through a batch already filtered by company (`lock`, or the
  `exists` checks at 657 and 695).
- `_download` reads `biometric_import_files where batch_id = b.id` only after the batch was found for `cid`
  (776–778).

**Verdict: holds** (T-SEC1a–g).

### 2.6 No unauthorised mapping modification
- 0013 never writes `biometric_employee_mappings`. E3a lists every write target in 0013: only the four import
  tables and `audit_log`. The single reference to mappings is the read in `row_mapping` (643). The import creates
  no mapping (T-MAP5).
- The screen's **Map code** button opens the **existing** B4 `MappingForm`, which calls the existing
  `biometric_save_mapping` (0010:696). The DAT work does not change it; its rules still apply:
  - device-specific codes: Admin and HR (`biometric_require(false)`, permission `mapBiometricCodes`);
  - company-wide codes: Admin only;
  - mappings cannot be deleted, and inactive employees are refused.
- Note for decision B: saving a mapping is existing B3.2 behaviour that also attributes any **waiting SDK punches**
  of that code and device (0010, `status = 'unmatched'` → `'stored'`, audited as `attribute_unmatched`).
  - It never touches DAT staging rows. No DAT row is a raw event.
  - For the X2008 today there are no SDK punches, so nothing is attributed.

**Verdict: holds.** Mapping rights are B4's and are unchanged.

### 2.7 Upload token security and expiry
- The token is generated server-side from two `gen_random_uuid()` values (298), returned once, and kept only in a
  JavaScript variable during the upload (`dat-import.ts:156–171`). It is never in localStorage, the URL or the logs.
- Only `sha256(token)` is stored (303). It is compared on every chunk and finish (321, 365) and cleared to `null` on
  finish, fail, cancel, expiry and delete (223, 226, 248, 377, 748, 767).
- `resume` issues a new token and invalidates the old one (352). The old tab is answered `taken_over` (T-UP11).
  Resume itself requires the same uploader.
- Expiry: an upload idle 24 h expires (218). It is lazy, running when any Admin of that company calls begin,
  status or batches (264, 598, 612), and the token hash is cleared. There is no fixed lifetime while the upload is
  active; each accepted chunk extends it.

**Verdict: holds.**

### 2.8 Chunk ownership and integrity
- `begin` fixes the size, the whole-file SHA-256 and every chunk's SHA-256 in advance (272–279). It allows at most
  64 chunks of exactly 256 KiB (the last chunk is the remainder) (44, 86–87, 334).
- A chunk must be the next index (333), have the exact length and match its declared hash (335). A repeat with the
  same bytes is idempotent; a repeat with different bytes is refused (328–331). Chunks belong to the batch by the
  `(company_id, batch_id)` foreign key and primary key `(batch_id, idx)`.
- `finish` joins the chunks in index order and checks the total size and the whole-file SHA-256 (372–374). On a
  mismatch the batch fails and all bytes are purged (`fail` → `purge`).
- `download` re-computes the SHA-256 when it serves the file (781). T-DL: the bytes come back identical.

**Verdict: holds.** Tests: T-UP1–T-UP6, T-UP9, T-UP11.

### 2.9 Concurrent uploads and processing (E6)
- **Processing:** every state-changing call takes the batch row lock (`for update`, 239), so two browsers
  processing the same batch serialise. C3 reproduced this with two parallel sessions: 12,000 rows, no duplicate
  line, nothing left unclassified.
- **The same file twice at once:** the partial unique index `(company_id, file_sha256)` on active batches (72–73)
  and the `unique_violation` handler (305) let exactly one through (C2).
- **F5 (Low):** the 3-open-batch limit is a plain `count(*)` (293–296) without a lock. C1 started four different
  files at once and got **4** open batches.
  - Impact: bounded by the number of simultaneous Admin uploads.
  - Fix: `pg_advisory_xact_lock` on the company id at the start of `begin`.
- **Lazy expiry** uses `for update skip locked` (220), so it never purges a batch that a running call holds.

### 2.10 File size and resource-exhaustion limits (E5)
- Limits are in one function (21–37): 16 MiB, 200,000 lines, 512 bytes per line, 16 fields, 64 chunks, 5,000 lines
  per processing call, 3 open batches, 1% blank, 2% malformed. Size is checked at `begin` before any byte is stored
  (271), and line length, field count and line count before any row is written (418–431). A refused file leaves
  nothing behind.
- **F2 (High, availability).** Measured at the 8 s Supabase signed-in timeout:
  - The upload itself is cheap (24–141 ms per call) and parsing is linear (≈ 0.75 s per 5,000 lines).
  - The **first classification call** was cancelled at 8.0 s for a **32,000-line file** (about the device's
    reported 31,207 records), in the normal run as well as with autovacuum off. It was also cancelled for one of two
    200,000-line runs.
  - Without a limit the same call was still running after 3 minutes.
  - After a manual `ANALYZE`, the same calls took 0.17–1.24 s.
  - **Cause:** shown by `EXPLAIN` of the UPDATE at 503–549. With no statistics for rows inserted seconds earlier,
    the planner expects 1 row and nests the derived table of seven lateral look-ups inside the join on `line_no`.
    That recomputes it once per row: 5,000 × 5,000 evaluations per call.
  - **Effect:** no corruption (the call rolls back; progress is unchanged), but a realistic full-history file stays
    in `classifying`. The browser retries 4 times in about 4 s, then shows an error. With F3 the user can only
    cancel, or wait for the 2 h stall-fail.
  - The 151-line real export is unaffected (tested end to end).
  - **Proposed correction**, before any hosted run:
    1. Compute the labels into a `MATERIALIZED` CTE (or a temporary result) before the UPDATE, so the join cannot
       be re-evaluated per row.
    2. Run `ANALYZE public.biometric_import_rows` at the end of the parse phase, inside the security-definer
       function (allowed for the table owner).
    3. Add DB tests at 32,000 and 200,000 lines with `statement_timeout = '8s'` and autovacuum off for the table.
- **F6 (Low):** `_chunk` decodes `p_data` (325–326) before the length check (335). An oversized body is bounded by
  the PostgREST/Supabase request limit, but checking `length(p_data) <= 349,528` (the base64 length of 256 KiB)
  before decoding is cheaper.
- `_download` returns the whole file as base64 in one JSON response (≈ 22 MB at the 16 MiB maximum). That is
  acceptable for Admin-only, occasional use.

### 2.11 No raw employee data in generic audit logs
- E1d: the four tables have **no** `audit()` trigger, only `company_refs` and `freeze_company`. The generic trigger
  remains on settings, agents, devices and mappings as in 0010:501–504.
- Explicit entries go through `biometric_dat_audit`, which keeps only whitelisted keys (158): state, reason, line,
  size, sha256, chunk_count, lines, counts, source_device_id and format_version. `counts` holds numbers only.
- T-AU checks every `dat_import.*` entry for any other key and for file names, codes, times, line text and TABs.
  T-AU2 checks that the begin, uploaded, ready, failed, expired, cancelled, reviewed, downloaded and deleted actions
  are audited.

**Verdict: holds.**

### 2.12 Device serial and MAC address (E7)
- In the repository: no serial and no file-name prefix anywhere in `HEAD` (E7a), no file with the real export's hash
  (E7b), no MAC-address-shaped string (E7d). Exports are ignored by `.gitignore:61`. The unit test "the real X2008
  export is never in the repository" checks the hash.
- In the data: the file's **content** holds no serial or MAC (6 fields; E7 / format doc §2). The **uploaded file
  name** does: it is stored in `biometric_import_batches.file_name`, shown in the list, review and download, and
  readable by HR through F1.
  - It is removed on delete (`file_name = 'deleted'`, 766).
  - It is never in audit entries.
  - The e2e and screenshots use a renamed copy, which is why no screenshot shows it.
  - Decision A addresses it.
- **P1 (Medium, privacy, owner decision):**
  - `docs/biometric/BIOMETRIC_DAT_FORMAT.md:73` shows **file line 1 of the real export** (an employee other than
    code 10) as the format example. That is another employee's real record. It has been in the pushed branch since
    commit `2910952` (21 Nov).
  - Options:
    1. Replace it with a synthetic line in a docs-only commit. The record stays in branch history.
    2. Also rewrite the unmerged branch history, which needs a force-push and your explicit approval.
- **P2 (information):** code 10's four record times (WR198) are in the approved correlation and format docs and, as
  expected values, in `biometric_dat_import_test.sql:191` and `e2e/biometric_dat_import.py:137`. No other employee's
  record is in the tests. If you prefer, the tests can compare a hash of those four lines instead.

## 3. Outstanding decisions: recommendations

### A. Original file name: recommend a generated internal name
- **Store a server-generated name, never the uploaded one.** Example:
  `x2008-<device short name>-<YYYYMMDD-HHMM company time>-<first 8 hex of SHA-256>.dat`.
  - It is built in `begin` from the device record, `created_at` and the hash.
  - The browser stops sending `file.name`; the parameter can stay and be ignored for one version.
  - Download serves the generated name.
- Keep only a boolean `name_had_expected_pattern` (whether the uploaded name matched `*_attlog*.dat`) if
  provenance checks need it. It reveals nothing.
- The browser may still show the chosen file's name locally before upload, since nothing is stored. To keep
  screenshots and screen-sharing clean, show the generated name instead.
- The fix belongs in the corrected 0013 together with F1. No hosted data exists to migrate. The local demo batch is
  recreated by the e2e.

### B. Import permissions: recommend HR prepares, Admin approves
| Action | Today | Recommended |
|---|---|---|
| Upload, process, cancel **own** upload | Admin | **HR and Admin** |
| View review (records, codes, duplicates, mapping preview) | Admin | **HR and Admin** |
| Cancel someone else's upload in progress | any Admin (F8) | Admin |
| **Mark reviewed** | Admin | **Admin only.** It becomes the gate to the next stage (raw events), so it should stay with whoever owns configuration |
| Delete a batch, download the original file | Admin | **Admin only** (download is a full copy of every employee's records) |
| Map **device-specific** codes | Admin **and HR** (B4, `mapBiometricCodes`) | **Your decision.** Your brief says "Admin retains mapping"; today HR already maps device-specific codes (approved in B4). Restricting it to Admin changes B4 behaviour and its tests, so it should be a separate, explicit change |
| Map company-wide codes, configure devices | Admin | Admin (unchanged) |

Server side: begin, chunk, resume, finish, process, status, batches, codes and rows would use
`biometric_require(false)`, with the uploader-only checks kept as they are. Mark reviewed, delete, download and
cancel-of-others keep `biometric_require(true)`. Two new UI capabilities would be added
(`prepareBiometricImports` HR+Admin, `approveBiometricImports` Admin). The Help section and the
permission-matrix tests would be updated with them.

### C. Mapping validity: `10` → WR198 stays a test mapping
- **Today:** the mapping exists only in the local demo (created on screen by the e2e) and in the DB test fixture,
  both with `valid_from = 2026-11-01 00:00 Asia/Kolkata`. That date is an **assumption**. The demo seed deliberately
  does not create it.
- **Recommendation:**
  - Label it in tests and fixtures as a test mapping (`-- TEST MAPPING: date not confirmed by HR`).
  - Create no mapping on any company database until HR confirms in writing (a) the date from which code 10 has
    been WR198 on this X2008 and (b) whether the code was ever used by someone else.
  - Then enter it once, with that date, through the normal mapping screen.
  - Mappings cannot be deleted or back-dated later, only ended, and saving one attributes waiting SDK punches. A
    wrong start date is therefore hard to undo, which is why it should wait for HR.
- Until then the import still works: records show **Not mapped** and are kept.

### D. Retention: proposal with no scheduler
| Data | Kept for | Then |
|---|---|---|
| Failed, expired or cancelled batch: bytes, chunks, rows | removed immediately (already so) | tombstone only |
| Upload idle | 24 h (already) | expired, bytes removed |
| Processing stalled | 2 h (already) | failed, bytes removed |
| **Ready for review but never reviewed** | **30 days** from ready | expired as "review_timeout": file and rows removed |
| **Reviewed:** original file and parsed rows | **90 days** from review (≈ one payroll month plus two months for disputes and HR checks against the eSSL report) | removed, name scrubbed, tombstone kept |
| Tombstone (ids, hash, counts, states, who/when/why; no name, code, time or line) | 3 years | removed (no personal data in it) |
| Audit entries | permanent, per the house rule; they hold no personal data (T-AU) | — |

**How deletion and expiry would work without a scheduler:**
1. Extend the existing lazy `biometric_dat_expire(cid)` to apply the review and retention rules. It is already
   called on begin, status and batches. Also call it from the Biometric overview load, so it runs whenever HR or an
   Admin opens Biometric, not only the import tab.
2. Each call removes at most N batches, deleting rows in slices. 200,000-row deletion time must be measured under
   the 8 s limit before approval; it has **not** been measured yet.
3. Show "Kept until <date>" on each batch, and give Admins **Delete now**, which already exists with a reason
   required.
4. Make the limit honest: if nobody opens Biometric, data can outlive its date. That is the cost of having no
   scheduler. When pg_cron is approved later, a daily job calls the same function, and nothing else changes.
5. Supabase backups keep deleted rows until the backups themselves expire (PITR or daily backups, per plan).
   Restoring a backup could bring back purged rows. That belongs in the data-protection notes.
6. When the next stage turns reviewed records into raw events, the staging rows are no longer the source. The
   90 days can then be shortened, or rows removed as soon as their raw events are confirmed. That is a later
   decision.

## 4. Parser assumptions: confirmed vs open

The profile is **`essl.x2008.attlog/1`, for this X2008 (firmware 8.0.4.2-20180530) only**. Nothing here is claimed
for other eSSL models, firmwares or export menus.

| Characteristic | Status | Basis / what would confirm it |
|---|---|---|
| UTF-8-decodable, ASCII only, no BOM, no NUL | **Confirmed** for this export | byte inspection, R-tests |
| TAB delimiter, exactly 6 fields on every line | **Confirmed** for this export | 755 TABs = 151 × 5 |
| CRLF on every line, including the last | **Confirmed** for this export | the parser **requires** CRLF everywhere and refuses LF (R1 correction) |
| No header line, no blank lines | **Confirmed** for this export | — |
| Field 1 right-aligned to 9 characters with spaces; every line 41 bytes | **Confirmed** for this export | width flag 0 of 151 |
| Field 1 always 9 wide; codes longer than 9 | **Open:** HR/eSSL (H4) | a code with more digits, or eSSL documentation |
| Codes are digits, ≤ 2 characters, no leading zero | **Confirmed** for this export only | the parser is broader than observed: it accepts letters, `_` and `-`, up to 32 characters (0013:172–173), and keeps leading zeros (`010` ≠ `10`). Those cases are tested only with synthetic fixtures |
| Field 2 `YYYY-MM-DD HH:MM:SS`, device-local, no zone | **Confirmed** shape; **zone open** (H6) | device clock zone and how it is kept correct |
| Records chronological, no duplicates | **Confirmed** for this export | not assumed by the parser: out-of-order and duplicates are labelled, never rejected |
| Fields 3–6 values (1 / 255 / 1 or 3 / 0) | **Observed** only | **meaning unknown (H5)**; never interpreted |
| Export covers the device's full history | **Not confirmed**: 151 records vs 31,207 on the device (H2) | a fresh, complete, unopened USB export |
| File came straight from the device | **Not confirmed** (H3) | supply the next file straight from the stick |
| The same format for other menus, firmware or eSSL models | **Not assumed** | each needs its own sample and its own profile version |

**F4 (Medium, scope):** the code does not yet enforce "this X2008 only". `begin` checks only
`manufacturer = 'essl'` (267), so any registered eSSL device could import with the X2008 profile.
Recommendation: require the device's model to be `X2008`. Better still, make the format profile a per-device
setting that an Admin assigns, refuse any device without it, and record the device firmware on the batch.

## 5. Regression and scope verification

| Cannot… | Code evidence | Test evidence |
|---|---|---|
| Create attendance register entries | 0013 writes only `biometric_import_*` and `audit_log` (E3a). No reference to `attendance_events`, sessions or register objects apart from the header comment (E3b) | T-NO1: attendance events, sessions, register inputs, raw events, event state, sync runs, devices and employees are byte-for-byte unchanged by every DAT call; T-NO2; the e2e snapshot of 5 tables is unchanged after the browser run (48/48) |
| Calculate present/absent | No status or day logic in 0013, `dat-import.ts` or `DatImport.tsx`. The words appear only in UI text that says nothing is worked out (E3g) | as above |
| Infer IN/OUT | Fields 3–6 are stored in `fields[]` and never compared (0013:461–485). No direction column is written | P-tests and R-tests: fields kept exactly |
| Calculate hours or overtime | Only interval arithmetic for expiry (218–219) and DST detection (190–191) | — |
| Trigger biometric projection | No call to any projection or ingest function. `biometric_raw_events` is only **read** for the `already_from_device` label (540–543). No triggers were added to existing tables | T-NO2; T-DUP3b: the raw events are untouched and none is created |
| Modify B3.3 or B3.4 behaviour | `git diff 3ecdf17 e27ef9d` touches no migration 0001–0012, no gateway or projection test and no engine file (E3d). 0013 has no `create or replace` (E3c). It alters only the 0010 import-batch table, which B3.3/B3.4 reference by `id` only; the unique constraint it replaces is used nowhere else (E3e) | gateway 18/18, projection 17/17, full DB suite 990/990 including the B3.3/B3.4 suites |

## 6. Tests run in this review (23 Nov 2026, commit `e27ef9d`, local)

| Command | Result |
|---|---|
| `npm run check` | 82 tests: 81 pass, 0 fail, 1 skipped (real-file unit check without the env var) |
| `PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres ATTENDOS_REAL_DAT=<outside repo> npm run test:db` | **990 ok, 0 failures**, 118 of them DAT; "ALL BIOMETRIC DAT IMPORT TESTS PASSED" |
| `NEXT_PUBLIC_SUPABASE_URL=https://demo-attendos.supabase.co NEXT_PUBLIC_SUPABASE_ANON_KEY=demo-anon npm run build` (dummy values routed to the local stack by the e2e) | built |
| `python3 e2e/biometric_dat_import.py http://localhost:4175 …` | **48/48** |
| `python3 e2e/regression.py …` | **29/29** |
| `python3 e2e/biometric_gateway_http.py` | **18/18** |
| `python3 e2e/biometric_projection_http.py` | **17/17** |
| Catalog queries (E1), scope inspection (E3), stress runs (E5), concurrency runs (E6), privacy scan (E7) | as reported above |

Process notes:
- My first e2e attempt in this review used a build without the local-stack variables. The page showed preview mode
  and the script failed at device selection (2 checks failed). That was a mistake in how I built it, not in the
  code. After rebuilding as above, 48/48 passed.
- `e2e/biometric_b4.py` was **not** rerun in this review. Its known Sunday-dependent timeline check is unchanged and
  is reported in the Stage 1–2 report.

**Planned, not run:**
- the hosted `CREATE`-privilege check (F7);
- timing of 200,000-row deletion;
- re-runs after the corrections, which come only after your approval.

## 7. Proposed correction set (needs approval; nothing started)

All of these would be applied to 0013 itself. It has never run on a hosted or company database, so the project rule
"never edit a migration that has been run on a company's database" is respected.

1. **F2:** materialise the labels before the UPDATE; `ANALYZE` after parse; 32k and 200k timeout tests.
2. **F1:** narrow table `SELECT` on `biometric_import_batches`; test that no API role can read
   `upload_token_hash`.
3. **A:** generated internal file name.
4. **F4:** X2008 model or per-device profile required.
5. **F5:** company advisory lock in `begin`.
6. **F6:** length check before decoding.
7. **F3:** a "Continue processing" action for uploaded, parsing and classifying batches that are the caller's own.
8. **B** (if approved): HR prepares, Admin reviews, deletes and downloads; Help guide and permission tests.
9. **D** (if approved): review timeout and retention in the lazy expiry, "Kept until" on screen; deletion timing
   test.
10. **C:** label the test mapping; no hosted mapping until HR confirms.
11. **R1:** correct the Stage 1–2 report's line-ending sentence (docs).
12. **P1:** replace the real example line in the format doc; optionally rewrite branch history (needs your
    explicit go-ahead).

Then the full local suite runs again and a new review package is prepared.
