# B5 DAT import foundation — Stage 1 and Stage 2 implementation report

Status: **implemented and tested locally; superseded in parts by the correction pass (BIOMETRIC_B5_DAT_IMPORT_CORRECTION_PASS.md, 23 Nov 2026).**
- Date: 23 Nov 2026. Branch: `feature/biometric-b1`. Not merged, tagged or deployed.
- No hosted SQL was run and no migration was applied to any company database.
- No production data or credentials were used. There was no connection to the X2008, no eSSL software was installed,
  and projection and pg_cron were not touched.

Scope delivered:
- **Stage 1: versioned DAT reader.** Format profile `essl.x2008.attlog/1`.
- **Stage 2: employee mapping and import preparation.**

Scope not delivered, by instruction:
- IN/OUT pairing or first/last punch rules.
- Attendance, status, shift or overtime calculations.
- Register writes, raw-event creation or biometric projection.
- Scheduled processing.
- Any change to the attendance engine, B3.3 or B3.4.

## 1. Summary

An Admin uploads the X2008 USB export on **Biometric → File import**:

- The server keeps the file **byte for byte**.
- It splits the file into lines **in the original order**.
- It stores **every line** as a row with:
  - the raw line text
  - its line ending and byte length
  - **all six original fields as text**
  - the extracted employee code
  - the **original timestamp string**
  - the local timestamp and its instant in the declared zone
- Malformed, blank and duplicate lines are kept as rows too, each with a status. Nothing is discarded.

Fields 3–6 are stored and shown exactly as they are. No code reads them for meaning.

The review screen shows, for each record:
- whether the record is a duplicate (5 labels, §5);
- which approved mapping applies at the punch instant (computed on read, §6).

Unmapped codes are listed with their record counts. An Admin may map a code from the same screen, using the
existing mapping form and its rules. The import never creates a mapping.

Nothing goes further than staging. The batch ends at **Reviewed**. Turning reviewed records into raw events is a
later stage and needs a new approval (the 31-day guard, R13 in revision 4, still applies).

## 2. Files

### Created
| File | What it is |
|---|---|
| `supabase/migrations/0013_biometric_dat_import.sql` | Tables, parser, classifier, upload protocol and Admin functions (797 lines). Local only |
| `supabase/tests/biometric_dat_import_test.sql` | 118 database checks (100 synthetic + 18 real-file checks R0–R17 that run only when `ATTENDOS_REAL_DAT` points to the file) |
| `src/lib/dat-import.ts` | Browser side: hashing, chunking, resumable upload, read helpers, plain-language labels |
| `src/components/biometric/DatImport.tsx` | The File import tab: upload card, batch list, review, records table, review and delete dialogs |
| `tests/dat-import.test.ts` | Unit tests: fake protocol server, fixture hash checks, "no real file in the repo" guard, permission check |
| `e2e/biometric_dat_import.py` | 48 browser checks plus the screenshots |
| `docs/biometric/BIOMETRIC_B5_DAT_IMPORT_REPORT.md` | This report |

### Changed
| File | Change |
|---|---|
| `src/app/(app)/biometric/page.tsx` | New tab **File import**, shown only to people with `importBiometricFiles` |
| `src/lib/permissions.ts` | New capability `importBiometricFiles`: Admin only ("Import device export files (raw records)") |
| `src/app/globals.css` | Classes for the new screen; semantic `--color-*` tokens only |
| `supabase/tests/run.sh`, `supabase/demo/rebuild.sh` | Apply 0013 and run the new test file |
| `supabase/demo/biometric_demo.sql` | Demo employee WR198 and a demo X2008 (serial `DEMO-X2008-0001`). **No mapping seeded**: the e2e creates it on screen |
| `e2e/biometric_b4.py` | The Admin tab-list check now expects the sixth tab |
| `tests/fixtures/dat/f14_code_field_variants.dat` + README | 150 valid lines added. With only 7 lines, the 2% malformed-row limit refused the whole file before the per-code labels could be tested. Synthetic only |
| `docs/biometric/BIOMETRIC_DAT_FORMAT.md` | SHA-256 recorded, verified facts, §8.3 implementation status |
| `docs/PROJECT.md`, `docs/biometric/BIOMETRIC_IMPLEMENTATION_STATUS.md` | Status |

The real export is **not** in the repository or in any fixture:
- `.gitignore` excludes `*_attlog*.dat`.
- `tests/dat-import.test.ts` fails if any file in the repo has the real file's SHA-256.
- The real-file checks read it from a path outside the repo.
- The device serial and MAC address appear nowhere in the repo or in the screenshots. The e2e uploads a
  byte-identical copy named `x2008-usb-export.dat`.

## 3. Parser (profile `essl.x2008.attlog/1`)

The full specification is in BIOMETRIC_DAT_FORMAT.md §4–§6. The implemented behaviour:

| Step | Rule |
|---|---|
| Accept | UTF-8 (BOM noted, not required), at most 16 MiB, 200,000 lines, 512 bytes per line, 16 fields. A NUL byte or invalid UTF-8 refuses the file as binary or encrypted |
| Lines | **CRLF only** (corrected 23 Nov 2026: this row first said "CRLF or LF", which was wrong). A file with any bare LF or CR is refused as `unexpected_line_endings`. Each row records its own terminator. A missing final newline is recorded, not "fixed" |
| Fields | Split on TAB only. Every field is kept as the exact text, including padding. A count other than 6 makes the row `malformed` (kept) |
| Code | Leading spaces removed from field 1, nothing else. Never converted to a number, so `010` ≠ `10`. Invalid codes are kept and labelled `empty_code`, `trailing_space`, `inner_space`, `too_long` or `invalid_character`. A field-1 width other than 9 adds the flag `code_width_unexpected` |
| Time | Field 2 must match `YYYY-MM-DD HH:MM:SS` exactly. The string is kept as it is. The instant is calculated in the batch's declared zone (default: the company zone). A time in a DST gap or overlap is labelled `nonexistent_local_time` or `ambiguous_local_time` and gets **no** instant. Asia/Kolkata has neither |
| Fields 3–6 | Stored and displayed. Never compared with constants and never used for direction or status |
| Refusal | Over 1% blank lines or over 2% malformed rows refuses the whole file. Nothing is left behind except the failed batch record with its reason |
| Order | `line_no` is the file position. Every list is ordered by it unless the Admin sorts. Out-of-order times are counted (`out_of_order`), never re-sorted |

## 4. Parsed preview of the real export

Source file:
- 151 lines, 6,191 bytes.
- SHA-256 `6f0115361bbb2f51c92c3424b3edf14ea07fd68643dbfc96670a3d7122192476`.
- Imported in the local demo with the declared zone Asia/Kolkata.

Batch result:
- ok 151, new 151, blank 0, unparsable 0
- 17 codes
- 0 duplicates of any kind
- 0 time problems, 0 out-of-order
- 0 `code_width_unexpected`

Every field-1 value is 9 characters wide.

Records per code (aggregates only):

| Code | 1 | 3 | 4 | 5 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 20 | 58 | 65 | 75 | 79 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Records | 16 | 4 | 7 | 2 | 11 | 13 | 19 | 4 | 7 | 6 | 13 | 5 | 13 | 18 | 8 | 2 | 3 |

Code `10`, after the Admin mapped it on screen (device-specific, valid from 2026-11-01):

| Line | Field 1 (9 chars) | Field 2 (kept as text) | F3 | F4 | F5 | F6 | Code | Instant (IST) | Parse | Duplicate | Mapping |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 24 | `·······10` | `2026-11-04 09:26:53` | 1 | 255 | 1 | 0 | 10 | 2026-11-04 09:26:53 | ok | new | WR198 (device) |
| 95 | `·······10` | `2026-11-16 09:25:04` | 1 | 255 | 1 | 0 | 10 | 2026-11-16 09:25:04 | ok | new | WR198 (device) |
| 150 | `·······10` | `2026-11-21 15:49:16` | 1 | 255 | 1 | 0 | 10 | 2026-11-21 15:49:16 | ok | new | WR198 (device) |
| 151 | `·······10` | `2026-11-21 15:53:01` | 1 | 255 | 1 | 0 | 10 | 2026-11-21 15:53:01 | ok | new | WR198 (device) |

(`·` marks a leading space.)

Both 21 Nov records (lines 150 and 151) are present, separate and unlabelled. Their fields 3–6 are identical, and
they are 3 min 45 s apart. Neither is treated as IN or OUT, as a duplicate or as a correction.

The other 147 records are all `ok` / `new` / `unmapped`.

The full 151-row preview is in the review package (`real_file_parsed_preview.csv`). It is not in the repository
because it holds other employees' records.

## 5. Duplicate identification

Each row gets exactly one label. Precedence follows the order below. **No row is ever removed.**

| Label | Meaning | Points to |
|---|---|---|
| `exact_in_file` | Same raw line bytes earlier in this file | earlier line number |
| `exact_in_earlier_import` | Same device, same raw line in an earlier active batch | batch + line |
| `same_code_time_other_fields` | Same device, code and timestamp, but fields 3–6 differ (in this file or an earlier batch) | batch + line |
| `already_from_device` | Same device, code and instant already received as a raw event (SDK/ADMS path), matched occurrence by occurrence | raw event id |
| `new` | none of the above | — |

Results:
- **Real export:** 151 `new`. No duplicate of any kind.
- **Second import of the same file:** refused before upload by the file hash and metadata ("This file has already
  been imported"). After the first batch is deleted, the same file may be imported again (T-UP16b).
- **Overlapping second export (synthetic):** 60 lines labelled `exact_in_earlier_import` with pointers to the first
  batch, and 10 `new`. All 70 lines are kept (T-DUP2).
- **Same code and time from a different device:** not a duplicate (T-DUP5).
- **SDK raw events for the same code and time:** labelled `already_from_device`. The raw events are not changed, and
  the import creates none (T-DUP3).

## 6. Employee mapping

The starting state is the explicit mapping `10` → **WR198** only. No mapping is created by the import, and no code
is guessed from a name or a report.

The mapping is resolved on read, per record:
- exact code string;
- the record's own device first, then a company-wide mapping;
- validity is half-open [from, to), tested at the punch instant.

Results on the real export:
- **Before mapping:** 151 records, 17 codes, all `unmapped`. The codes table lists each code with its record count
  and a **Map code** button (screenshot 03).
- **After the Admin mapped `10` → WR198** with the existing form and its rules (screenshot 04): lines 24, 95, 150
  and 151 show WR198 (device). The other 16 codes stay unmapped and are retained.

Boundary tests (T-MAP):
- 23:59:59 the day before `valid_from` → unmapped; exactly 00:00:00 → mapped.
- 1 s before `valid_to` → mapped; exactly at `valid_to` → not mapped.
- The same code on another device resolves to that device's mapping.
- A record with no instant (DST gap/overlap) is `undetermined_time`, never mapped.

Existing mapping rules are kept as they are:
- A mapping cannot be deleted.
- A mapping cannot point to an inactive employee.
- A person can have only one code per device at a time.

**Not owner-confirmed:** the demo and the tests use `valid_from = 2026-11-01` for `10` → WR198. The real effective
date must come from HR (question H1).

## 7. Import batch behaviour

States:
- `uploading` → `uploaded` → `parsing` → `classifying` → `ready_for_review` → `reviewed`
- Side exits: `failed`, `expired`, `cancelled`, `deleted`

Only `ready_for_review` can be reviewed, and only by an Admin. Review needs the batch `version`, so a stale screen
is refused.

| Behaviour | Implementation |
|---|---|
| Upload | 256 KiB chunks, each with its SHA-256. The whole file's SHA-256 and size are declared at the start and verified at the end. A chunk that is out of order or fails its hash is refused (`wrong_order`, `chunk_hash`) |
| Resume | Another tab or a reload takes over with a new token. The old token is then refused (`taken_over`). On resume the browser checks the chosen file against the declared hashes before sending anything |
| Processing | At most 5,000 lines per call. The browser keeps calling until done, and progress is shown. A crash mid-way resumes from `progress_line` |
| Limits | At most 3 open batches per company. Uploads idle for 24 h expire. Processing stalled for 2 h fails. Both happen **lazily** when an Admin opens the screen — no scheduler |
| Duplicate files | A partial unique index on (company, file SHA-256) covers active batches only. A failed, expired, cancelled or deleted batch does not block a re-import |
| Download | The Admin can download the original bytes. The hash is re-checked before the download |
| Cancel / Delete | Cancel works before review. Delete (Admin, reason required) removes the file bytes, chunks and rows straight away and keeps only the batch metadata |
| Audit | Explicit entries for begin, finish, process, review, download, cancel and delete. Each carries ids, counts and hashes only — never file names, codes, times or line text (T-AU). The generic `audit()` trigger is not attached |
| Access | Admin only, own company only. The tables have RLS on and no grants, so even an Admin cannot read them directly. HR, employees, `anon` and another company's Admin are refused (T-SEC) |
| No side effects | No `biometric_raw_events`, attendance, sessions or register rows are written. Projection is never called (T-NO1, T-NO2) |

**Not implemented in this stage:** the 90-day automatic purge of file bytes and rows (revision 4 retention). It
needs a scheduled job, which is out of scope. Until then the rows stay until an Admin deletes the batch.

## 8. Tests

### Run (23 Nov 2026, local machine, all executed)
| Command | Result |
|---|---|
| `npm run check` (tsc + eslint + vitest) | **81 passed, 1 skipped** (the real-file unit check, skipped without `ATTENDOS_REAL_DAT`) |
| `ATTENDOS_REAL_DAT=<path outside repo> npm test` | **82 passed** |
| `PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres ATTENDOS_REAL_DAT=<path> npm run test:db` | **990 ok, all suites passed.** 118 of them are in the DAT test file |
| `PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres npm run test:db` (no real file) | **972 ok**, with a `SKIPPED R0–R17` line printed |
| `npm run build` | static export built (`out/`) |
| `python e2e/biometric_dat_import.py` (fresh demo) | **48/48** |
| `python e2e/regression.py` | **29/29** |
| `python e2e/biometric_gateway_http.py` | **18/18** |
| `python e2e/biometric_projection_http.py` | **17/17** |
| `python e2e/biometric_b4.py` | **60/61** — see the first pre-existing failure below |

### Pre-existing failures (not caused by this work, not fixed)
1. **B4 timeline check, day-of-week dependent.**
   - The demo's "yesterday" punches fell on Sunday 22 Nov, so they are held as `non_working_day` and the timeline
     count is 0.
   - The unchanged B4 build fails the same check today.
   - It is a calendar dependency in the B4 demo and test, not in the engine.
2. **Intermittent B3.3 gateway check "the key appears in no audit entry".**
   - The test splits the agent key on `_`. The base64url part can itself contain `_`, and a short fragment can then
     match unrelated audit text.
   - Test-only flakiness. It passed on the reported run.

### Planned, not run
- Any hosted or staging database run of 0013. **Not authorised.**
- A test with a fresh, complete export from the stick (needs HR question H2).
- Sync-agent upload of the same file. That path is not built.

## 9. Screenshots (review package, not in the repo)

The X2008 serial is not visible in any screenshot.

| File | Shows |
|---|---|
| `01-import-empty-light` | File import tab before any upload |
| `02-file-chosen-light` | File chosen, size and hash shown before upload |
| `03-review-unmapped-light` | Review: 151 records, 17 codes, all unmapped |
| `04-map-code-10-light` | Map code → existing mapping form for `10` → WR198 |
| `05-code-10-records-light` | Records filtered to code 10: lines 24, 95, 150, 151 mapped |
| `06-import-list-light` | Batch list after review |
| `07-list-{1440,390}-{light,dark}` | Batch list, desktop and phone, both themes |
| `08-review-{1440,390}-{light,dark}` | Review screen, desktop and phone, both themes |

## 10. Outstanding questions for HR / eSSL

| # | Question | Why it matters |
|---|---|---|
| H1 | From which date is code `10` WR198 on this X2008? Is the code ever reused? | Mapping `valid_from`. The 2026-11-01 used locally is an assumption |
| H2 | The device showed 31,207 records and the export has 151 (2–21 Nov). Was the USB export date-limited? Can a complete, unopened export be supplied? (DAT Q1, Q2; correlation E4) | Completeness. This file is not treated as full history |
| H3 | Was the file opened or re-saved before it was supplied? Can the next file come straight from the stick? (DAT Q3, Q7, Q8) | Provenance |
| H4 | Is field 1 always 9 characters wide? Can codes be longer than 9 digits? (DAT Q4) | The width flag |
| H5 | What do fields 3–6 mean for this firmware? (DAT Q5) | They stay uninterpreted until documented |
| H6 | Device time zone and how the clock is kept correct (DAT Q6) | The declared zone for each batch |
| H7 | Which other files appear on the stick? (DAT Q10) | Only the attendance file may be uploaded |
| H8 | The X2008 names its export with its serial number. Should the Admin rename the file before uploading, or should AttendOS stop storing the uploaded file name? | The batch keeps the uploaded name, which would hold the serial. Audit entries never do |
| H9 | Report correlation questions Q1–Q8 (BIOMETRIC_HR_REPORT_CORRELATION.md §5): the software's data source, the 15:53:01 punch, shift settings `GS`/`NS`, seconds, 24 vs 17 codes, report period | They decide how a later stage compares imported records with eSSL's report. They don't affect Stages 1–2 |

## 11. What needs owner approval next
1. Approve Stages 1–2 as built, or list corrections.
2. Answer H1, so the real mapping date can be entered.
3. Decide H8, file-name handling.
4. Approve a design for the next stage: reviewed records → raw events, the 31-day guard (R13), and the retention job.
   That is a separate approval. Nothing in this branch starts it.
