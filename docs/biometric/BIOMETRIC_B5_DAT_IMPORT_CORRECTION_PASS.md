# B5 DAT import: authorised correction pass, review report

Status: **implemented and tested locally, awaiting owner approval.**
- Date: 23 Nov 2026. Branch: `feature/biometric-b1` (reviewed base `e27ef9d`). Local development only.
- Nothing was done outside local development:
  - no hosted SQL, no production connection, no credential or environment change;
  - no deploy, merge, tag or release;
  - no X2008 connection, no eSSL software, no pg_cron;
  - no real company mapping, no Git history rewrite and no force-push.

This pass implements the correction set approved after the technical review
(BIOMETRIC_B5_DAT_IMPORT_TECH_REVIEW.md). Migration 0013 has never run on a hosted or company database, so it was
corrected in place. The rule against editing a migration that has run on a company's database still holds.

Evidence files `E1`–`E6` and the screenshots are in the review package. Line references are to the corrected
`supabase/migrations/0013_biometric_dat_import.sql`.

## 1. What changed, item by item

| Item | Change | Proven by |
|---|---|---|
| **A. Permissions** | Server-side split. HR and Admin may upload, process, continue and cancel **their own** uploads, and read batches, records, duplicate labels and mapping previews (`biometric_require(false)` plus uploader checks). Admin alone may mark reviewed, delete, download the original, cancel someone else's upload and assign a device's format (`biometric_require(true)`, or `biometric_dat_owner_or_admin`). Existing mapping rights are untouched: device-specific codes HR and Admin, company-wide Admin only, device configuration Admin only. UI capabilities: `importBiometricFiles` (HR, Admin) and `approveBiometricImports` (Admin) | DB permission matrix T-PERM (8 roles × 20 operations, §2); ownership tests T-OWN1–13; unit permission test; e2e HR flow and direct API calls |
| **F2. Performance** | Duplicate labels are computed once per slice into a `MATERIALIZED` CTE, then written by line number. `ANALYZE public.biometric_import_rows` runs at the end of parsing | Scale suite S1–S4 at 32,000 and 200,000 lines, autovacuum normal and OFF, with an 8 s limit on every call (§3) |
| **F2. Retries** | Unchanged design: one transaction per call. Now proven under forced cancellation | S5a–c: a parse call and a classify call cancelled mid-way change nothing; the retried run has every line exactly once |
| **F1. Database access** | The 0010 `bio_read` policy and `SELECT` grant on `biometric_import_batches` are removed (0013, "F1" block). No API role can read any column, including `upload_token_hash`, `chunk_hashes`, `delete_reason` and `file_name`. Nothing in the app read the table directly | C2, C2b (catalog: no table or column privilege, no policy); T-PERM `table:*` rows; e2e: Admin and HR get HTTP 401/403 on all four tables |
| **F4. Format scope** | New table `biometric_device_import_formats`: an Admin assigns the profile per device (`biometric_dat_set_device_format`), and only to eSSL devices of model X2008. `begin` refuses a device with no assigned format (`no_import_format`) and re-checks the model at every import (`model_not_supported`). Each batch records `device_model`, `device_firmware` and `format_version`. No other model or export format is claimed | F4a–e, T-SEC5 (ZKTeco, eSSL K21, unassigned X2008, re-modelled device); e2e allow flow |
| **F5. Concurrent starts** | `pg_advisory_xact_lock` keyed on the company, at the start of `begin`, before the open-batch count | C1: 4 simultaneous starts → 3 begun, 1 `too_many_open_batches`, 3 open (before: 4 open). C2: the same file by two Admins → 1 batch |
| **F6. Chunk handling** | The encoded payload length (≤ 349,528 characters, empty refused) is checked **before** decoding. Every existing size, order and hash check is kept | F6, F6b (a real full chunk is exactly at the limit; longer, empty or non-base64 refused, nothing stored) |
| **F3. Recovery** | **Continue processing** on the uploader's own uploaded, parsing or classifying batch (screen and `processBatch`). Choosing the same file again returns `continue_processing` (own) or `being_processed` (someone else's). Ownership, lock, progress and retries unchanged | T-OWN2–5; unit tests; e2e "Continue processing" (07) |
| **R1. Documentation** | The Stage 1–2 report now says CRLF only. The format doc §8.3 states CRLF only, and that LF-only needs a separate specification, tests and a new profile version. The parser is **not** broadened | P6 (LF-only refused, nothing kept) |
| **C. File name** | The uploaded name is no longer sent, stored or shown. The server generates `x2008-<8 hex of device id>-<YYYYMMDD-HHMM in the declared zone>-<8 hex of SHA-256>.dat`, never using the device's name or serial. Download serves the generated name | R5b; unit test "the file's own name is never sent"; e2e: no uploaded name in requests, database, screen or audit |
| **C. Privacy in docs** | `BIOMETRIC_DAT_FORMAT.md` §3 example replaced with a fully synthetic line (code 7, 2030-01-02 08:15:00). History **not** rewritten: commits `2910952` and `ba99301` still contain the earlier real line or its time | a search of the working tree for the real line's time finds nothing (E4g) |
| **D. Mapping** | `10` → WR198 stays a **test assumption**: marked so in the DB tests and the e2e. The demo seed creates no mapping. No real company mapping exists or was created | R13 label; e2e step 05 |
| **E. Retention** | Ready but not reviewed: 30 days. Reviewed: 90 days after review. Failed, expired, cancelled or deleted: bytes, chunks and rows removed at once. Non-personal tombstone: 3 years. Audit: unchanged house rule. Deletion is bounded (at most 50,000 rows per call, the rest on later calls) and lazy (no scheduler). Retention dates are shown on the list and the review | T-RET1–9; S6, S7; e2e (retention text) |

## 2. Security and permission matrix

### 2.1 Functions and tables by role

Database test T-PERM (E3). Outcomes:
- *allowed*: the function ran; any refusal came back as data.
- *denied*: `Not allowed` or `permission denied`.
- *not_found*: another company's batch or device; existence is not revealed.

| Operation | A Admin | A HR | A Manager | A Employee | B Admin | B HR | B Employee | anon |
|---|---|---|---|---|---|---|---|---|
| begin (upload) | allowed | allowed | denied | denied | not_found | not_found | denied | denied |
| chunk / resume / finish | allowed¹ | allowed¹ | denied | denied | not_found | not_found | denied | denied |
| process / continue | allowed¹ | allowed¹ | denied | denied | not_found | not_found | denied | denied |
| status / codes / rows | allowed | allowed | denied | denied | not_found | not_found | denied | denied |
| batches (list) / housekeeping | allowed | allowed | denied | denied | allowed² | allowed² | denied | denied |
| cancel someone else's upload | allowed | **denied** | denied | denied | not_found | not_found | denied | denied |
| mark reviewed | allowed | **denied** | denied | denied | not_found | denied | denied | denied |
| delete | allowed | **denied** | denied | denied | not_found | denied | denied | denied |
| download original | allowed | **denied** | denied | denied | not_found | denied | denied | denied |
| assign device format | allowed | **denied** | denied | denied | not_found | denied | denied | denied |
| direct SELECT on any of the 5 import tables | denied | denied | denied | denied | denied | denied | denied | denied |

¹ Only on one's **own** upload. Someone else's upload returns *Not allowed*, for an Admin as well (T-SEC2a,
T-UP12b, T-OWN2). An Admin may cancel it instead.
² Lists only the caller's own company: empty for company B (T-PERM2, T-PERM3).

### 2.2 Security checks against the code

| Check | Result and evidence |
|---|---|
| Company isolation for every operation | Every function takes `cid` from `biometric_require` → `my_company()`. Every batch access goes through `biometric_dat_lock(cid, …)` or filters on `company_id = cid`. Device and format look-ups are company-filtered. Matrix columns B Admin and B HR |
| Server-side authorisation | `biometric_require(false)` (HR/Admin) or `(true)` (Admin) at the top of every granted function. Ownership via `uploaded_by = my_employee_id()` or `biometric_dat_owner_or_admin`. Catalog test C4: only the 15 checked functions are executable by `authenticated`; every helper is executable by none |
| No direct table access | C2, C2b, T-PERM `table:*`, e2e HTTP 401/403 for Admin and HR on batches, rows, files and formats |
| Security-definer search_path | C6: every security-definer function in the schema has a fixed `search_path`. All relation references in 0013 are schema-qualified |
| No cross-company file or batch access | T-SEC1a–g, T-SEC4, T-PERM |
| No unauthorised mapping change | 0013 writes only the import tables, the format table and `audit_log` (E4a). Mapping writes stay with the unchanged `biometric_save_mapping` |
| Upload token | 2 × UUIDv4 random (≈ 244 bits), returned once, only its SHA-256 stored, never readable (C2b). Cleared on finish, end, expiry and delete. Expires with the batch after 24 h idle |
| Chunk ownership and integrity | Uploader-only, token-checked, in order, exact length and declared SHA-256. Length checked before decoding (F6). The whole file's size and hash are checked at finish |
| Concurrency | C1–C3 (E5) |
| Resource limits | 16 MiB, 200,000 lines, 512-byte lines, 16 fields, 64 chunks, 5,000 lines per call, 3 open batches, bounded purge. Every call under 8 s at the limits (§3) |
| No raw employee data in generic audit | No `audit()` trigger on any import table (C5). Explicit entries have whitelisted keys (T-AU, including the new `rows_removed`). e2e: no audit entry holds a file name |
| Serial or MAC exposure | Not in batch names, UI, audit entries or screenshots (generated name; e2e checks every list and review screen in both themes and both sizes). The device's own serial stays in the B4 device record, as before |

## 3. Performance timings

Local PostgreSQL 16. Synthetic files in the observed shape. Every call made as a signed-in Admin or HR user with
`statement_timeout = 8s`. Final run (E5) made while the browser tests ran on the same server.

| Scenario | Upload | Validate | Parse (5,000 lines per call) | Classify (5,000 lines per call) | Result |
|---|---|---|---|---|---|
| S1 32,000 lines, autovacuum normal | 8 calls, max 35 ms | 469 ms | 7 calls, max 662 ms | 7 calls, max 513 ms | ready; 32,000 rows, each once, all labelled |
| S2 32,000 lines, autovacuum **OFF** | 8 calls, max 35 ms | 473 ms | 7 calls, max 1,042 ms | 7 calls, max 545 ms | ready (before the fix: first classify call cancelled at 8 s; still running after 3 min with no limit) |
| S3 200,000 lines, autovacuum normal | 34 calls, max 311 ms | 3,484 ms | 40 calls, max 1,313 ms | 40 calls, max 899 ms | ready; 200,000 rows |
| S4 200,000 lines, autovacuum **OFF** | 34 calls, max 150 ms | 3,088 ms | 40 calls, max 1,295 ms | 40 calls, max 1,284 ms | ready; 200,000 rows |
| S6 delete a 200,000-row batch | — | — | — | — | delete call 195 ms (file + first 50,000 rows), then 3 housekeeping calls, max 258 ms; nothing left |
| S7 retention expiry, reviewed 200,000-row batch | — | — | — | — | 4 housekeeping calls by HR, max 307 ms; expired `retention_period`, nothing left |

The slowest call anywhere was validation of a 200,000-line file, at about 3.1–3.5 s. Validation reads the whole file
once.

## 4. Retention and deletion

| Batch | Data (file + rows) removed | Record kept |
|---|---|---|
| failed, cancelled, idle 24 h (expired), stalled 2 h (failed), deleted | at once (bytes at once, rows in steps of ≤ 50,000) | 3 years, then removed (`dat_import.tombstone_removed` audited) |
| ready for review, not reviewed | 30 days after it became ready → `expired` / `review_timeout` | 3 years after that |
| reviewed | 90 days after review → `expired` / `retention_period` (who reviewed and when is kept) | 3 years after that |
| audit entries | never (existing house rule; they hold ids, counts and hashes only) | — |

How it runs, with no scheduler:
- `biometric_dat_expire` runs on begin, status, the batch list and `biometric_dat_housekeeping()`. The Biometric page
  calls housekeeping once whenever HR or an Admin opens it.
- Each call:
  1. continues pending row removals (budget 50,000 rows);
  2. applies up to 10 time-based state changes;
  3. removes up to 50 old tombstones.
- A batch being removed is unreadable from the first step: the read functions require ready or reviewed (T-RET7).

**Limitation:** removal happens on the first visit after the date. If nobody opens Biometric, data stays until
someone does. That is stated on screen ("kept until …"); no fixed deadline is claimed.

Supabase backups (30 days) still hold removed rows until those backups expire. This was not changed.

## 5. Parser assumptions (unchanged scope; R1 corrected)

As in the technical review §4. The profile is `essl.x2008.attlog/1`, for the X2008 only; it is now enforced per
device (F4).

**Confirmed by the supplied export:**
- TAB delimiter, 6 fields;
- CRLF line endings, including a final newline;
- field 1 nine wide;
- `YYYY-MM-DD HH:MM:SS` timestamps;
- ASCII, no BOM.

**Still needs a fresh USB export or HR confirmation:**
- whether the export covers the device's full history (151 vs 31,207 records);
- provenance of the supplied copy;
- whether field 1 is always nine wide, and codes longer than nine digits;
- the meaning of fields 3–6;
- the device clock's time zone.

The reader still accepts more than was observed in one respect: codes with letters, `_` or `-` up to 32 characters.
LF-only files are refused.

## 6. Regression and scope

The B5 boundary holds:

| The import cannot… | Evidence |
|---|---|
| create attendance register entries, calculate attendance, infer IN/OUT, calculate shift, hours or overtime | 0013 writes only the import tables, the format table and `audit_log` (E4a); no attendance or direction terms in the DAT code (E4f); T-NO1 (byte-for-byte snapshot of every other table); e2e snapshot of attendance, raw events, event state, sync runs and reviews |
| create raw biometric events or trigger projection | E4b: no call to projection, ingest or raw-event inserts; T-NO2; T-DUP3b |
| change B3.3 or B3.4 | `git diff e27ef9d` touches no migration 0001–0012, no B3 test and no engine file (E4e); no `create or replace` in 0013 (E4d); gateway and projection DB suites and HTTP e2e pass |

## 7. Tests run (23 Nov 2026, local)

| Command | Result |
|---|---|
| `npm run check` (tsc + eslint + unit) | 85 tests: 84 pass, 1 skipped (real-file unit check without the variable); with `ATTENDOS_REAL_DAT` set: 85/85 |
| `PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres ATTENDOS_REAL_DAT=<outside repo> npm run test:db` | **1,025 ok, 0 failed**; 153 DAT checks, including real-file R0–R17, T-PERM, T-OWN, F4–F6 and T-RET. See the note on the first run below |
| `python3 supabase/tests/dat_scale_test.py <report>` (after test:db) | **12/12**: S1–S7, C1–C3 |
| `NEXT_PUBLIC_SUPABASE_URL=https://demo-attendos.supabase.co NEXT_PUBLIC_SUPABASE_ANON_KEY=demo-anon npm run build` (dummy values routed locally) | built |
| `ATTENDOS_REAL_DAT=… python3 e2e/biometric_dat_import.py http://localhost:4175 …` | **97/97** |
| `python3 e2e/regression.py …` | **29/29** |
| `python3 e2e/biometric_gateway_http.py` (B3.3) | **18/18** |
| `python3 e2e/biometric_projection_http.py` (B3.4) | **17/17** |
| `python3 e2e/biometric_b4.py …` | **60/61**. The one failure is the known, pre-existing timeline check that fails when "yesterday" (22 Nov) is a Sunday. It also failed on the unchanged B4 build earlier |

**Note on the first test:db run of the final code:**
- It stopped on the known, pre-existing intermittent B3.3 check "the key appears in no audit entry" (E2b). The test
  splits a random key on `_`, and a short fragment can match unrelated text.
- The rerun passed in full (above). Not related to this work and not changed.

**Not run:**
- anything hosted;
- a fresh complete USB export, which has not been supplied.

## 8. Screenshots (package `shots/b5/`)

The serial and the uploaded name do not appear in any screenshot.

| File | Shows |
|---|---|
| 01-device-format-not-allowed-light | before an Admin allows it, no device can import; Devices and file formats with **Allow X2008 file import** |
| 02-device-format-allowed-light | X2008 export allowed; the device offered for upload |
| 03-hr-file-chosen-light | HR: file chosen; size and SHA-256 shown, no file name |
| 04-hr-review-unmapped-light | HR's review: generated name, retention date, no Admin buttons, "An Admin marks this import as reviewed" |
| 05-admin-test-mapping-code-10-light | Admin maps 10 → WR198 (**test mapping, date assumed**) |
| 06-code-10-records-light | lines 24, 95, 150, 151, both 21 Nov records |
| 07-hr-continue-processing-light | interrupted check, **Continue processing**; retention text on the list |
| 08-list-{admin,hr}-{1440,390}-{light,dark} | the list for both roles, sizes and themes |
| 09-review-{admin,hr}-{1440,390}-{light,dark} | the review for both roles, sizes and themes |

## 9. Files

| File | Change |
|---|---|
| `supabase/migrations/0013_biometric_dat_import.sql` | corrected as above |
| `supabase/tests/biometric_dat_import_test.sql` | new begin signature and generated names; HR reads; new sections T-OWN, T-PERM, T-RET; F4–F6; catalog C2b, C4, C6 |
| `supabase/tests/dat_scale_test.py` | **new**: scale, retry, deletion and concurrency (needs psycopg 3; run after `npm run test:db`) |
| `src/lib/dat-import.ts` | no file name sent; `processBatch` (continue); device formats, housekeeping, retention types; new texts |
| `src/components/biometric/DatImport.tsx` | role-aware actions, Devices and file formats, Continue processing, retention, no uploaded name |
| `src/app/(app)/biometric/page.tsx` | housekeeping call when HR or an Admin opens Biometric |
| `src/lib/permissions.ts` | `importBiometricFiles` HR + Admin; new `approveBiometricImports` (Admin) |
| `src/app/globals.css` | `.bio-batches` wrapping (semantic tokens only; no colours) |
| `tests/dat-import.test.ts` | name never sent, continue processing, permission split |
| `e2e/biometric_dat_import.py`, `e2e/biometric_b4.py` | new flow; tab label text |
| docs | this report; format doc (synthetic example, CRLF only, implementation status); Stage 1–2 report (R1); review report status; PROJECT.md; status doc |

## 10. Remaining owner decisions

1. **Code 10 → WR198:** HR's written confirmation of the effective date and of any earlier use of code 10. Until then
   no real mapping is created; the local one is a test assumption.
2. **A fresh, complete, unopened USB export:** settles full-history coverage (151 vs 31,207), provenance, the field-1
   width and the device clock zone. Also HR/eSSL on the meaning of fields 3–6.
3. **Approval of this correction pass**, then a separate decision on whether and when 0013 may run on a hosted
   project. That run would need a hosted check that `authenticated` has no CREATE on `public`, plus the same timings
   on hosted hardware.
4. **The next stage** (reviewed records → raw events, under the 31-day guard R13): a new design approval. Nothing here
   starts it.
5. **Pre-existing test issues**, which may be fixed separately if you want:
   - the intermittent B3.3 gateway key check;
   - the B4 timeline check that fails when "yesterday" is a Sunday.
6. **Git history:** the earlier real line (code 7) and its time remain in pushed commits `2910952` and `ba99301`, as
   instructed (no rewrite). Removing them would need your explicit go-ahead for a history rewrite.
