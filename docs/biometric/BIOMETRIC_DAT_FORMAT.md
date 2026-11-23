# X2008 DAT attendance export — format record and parser specification

Status: **M1 format record — documentation and parser design only, for owner review.**
- No parser code, no migration 0013, no SQL, no device connection.
- Date 21 Nov 2026. Branch `feature/biometric-b1`.
- Completes the "pending inspection" record of Revision 3 §4.3. Refines Revision 4 §3 and §5 (changes listed in §9).

**Evidence labels:**
- **[OBSERVED]** — owner's direct inspection of the supplied file (owner report, 21 Nov 2026).
- **[DERIVED]** — follows arithmetically from observed values.
- **[UNKNOWN]** — not established; needs HR or eSSL confirmation.
- **[RULE]** — design decision for the AttendOS parser.

Every observation applies **only to the supplied file**. Nothing here is claimed for other exports, other firmware
or other devices.

---

## 1. Inspection metadata

| Item | Value |
|---|---|
| Source device | eSSL X2008, firmware 8.0.4.2-20180530 (device-reported, Rev 3 §1) |
| Supplied file name | `<device-serial>_attlog (1)(1).dat` — **the prefix is redacted**: it has the form of a device serial (ZKTeco-family exports are named `<serial>_attlog.dat`), and serials are kept out of the repository. The ` (1)(1)` suffix suggests the file was saved or copied twice after export (see Q8) |
| Inspected by | owner, directly, 21 Nov 2026 |
| Size | 6,191 bytes [OBSERVED] |
| SHA-256 | `6f0115361bbb2f51c92c3424b3edf14ea07fd68643dbfc96670a3d7122192476` — computed from the original bytes uploaded by the owner on 23 Nov 2026 ("directly from the USB drive"); recomputed by the database on import (`R0`, `R3`) |
| Where the file is kept | owner's own storage. **Not in GitHub and not in test fixtures** [RULE] |

---

## 2. Observed file characteristics [OBSERVED]

| Property | Value |
|---|---|
| Records (lines) | 151 |
| Encoding | decodes as valid UTF-8 (all characters observed are ASCII-range in the example) |
| Byte-order mark | absent |
| Delimiter | TAB (`0x09`) |
| Line ending | CRLF (`0x0D 0x0A`) |
| Final newline | present (the last record ends with CRLF) |
| Header line | none (the first line is a record) |
| Blank lines | 0 |
| Fields per record | exactly 6 on every line |
| Timestamp format | every timestamp matches `YYYY-MM-DD HH:MM:SS` |
| Time span | 2 Nov 2026 to 21 Nov 2026 |
| Order | chronological throughout |
| Exact duplicate lines | none |
| Repeated (code, timestamp) pairs | none |
| Distinct codes | 17 |

**[VERIFIED 23 Nov 2026 from the original bytes]** every point above, plus:
- every line is exactly 41 bytes (39 + CRLF), so fixed width is confirmed for this file;
- all bytes are ASCII (no byte above 127, no NUL); 755 TABs = 151 × 5;
- all 17 codes are digits, at most 2 characters long, with no leading zero. The `10` / `010` / `0010` distinction is
  therefore exercised only by synthetic fixtures;
- field 3 is `1`, field 4 `255` and field 6 `0` on every line; field 5 is `1` on 131 lines and `3` on 20. Meanings
  stay **[UNKNOWN]**;
- the two 21 Nov code-10 records (lines 150, 151) have identical fields 3–6.

**[DERIVED, now confirmed]** 6,191 bytes ÷ 151 lines = exactly **41 bytes per line**. That equals the example line:
9 (field 1) + 1 + 19 (timestamp) + 1 + 1 + 1 + 3 + 1 + 1 + 1 + 1 (fields 3–6 and tabs) + 2 (CRLF). This is
*consistent with* every line having the same widths as the example. It doesn't prove it: other combinations could
produce the same total. It is confirmed only when the parser records each line's length on the real file (§8.2).

---

## 3. Record structure

Example in the observed shape (TAB shown as `→`, CRLF as `␍␊`). **Fully synthetic**: the code, date and time are
invented, and this is not a line of the supplied export. (Until 23 Nov 2026 this section quoted line 1 of the real
export, another employee's record. It was replaced in the correction pass; earlier commits still contain it, and Git
history is deliberately not rewritten.)

```
········7→2030-01-02 08:15:00→1→255→1→0␍␊
```

| Field | Observed content | Meaning | Parser rule |
|---|---|---|---|
| 1 | 9 characters, right-aligned, left-padded with spaces (`········7`) | device user code (owner-confirmed for code `10`) | keep the exact field; extract the code by §4 |
| 2 | `YYYY-MM-DD HH:MM:SS`; no time zone or UTC offset | device-local date and time of the record | keep the exact string; parse by §5 |
| 3 | e.g. `1` | **[UNKNOWN]** | keep as exact string; never interpreted |
| 4 | e.g. `255` | **[UNKNOWN]** | keep as exact string; never interpreted |
| 5 | e.g. `1` | **[UNKNOWN]** | keep as exact string; never interpreted |
| 6 | e.g. `0` | **[UNKNOWN]** | keep as exact string; never interpreted |

**Fields 3–6 [RULE]:**
- They are never used to infer IN/OUT, verification method or any attendance meaning.
- They are never used in calculations.
- They are never given names in the database other than `field_3` … `field_6` (inside `fields[]`).

Third-party descriptions of other devices' ATTLOG data give meanings to similar positions (e.g. status or verify
mode). Those meanings were **not** established for this device or firmware, so they are not adopted.

---

## 4. Employee-code extraction rule (X2008 DAT adapter only) [RULE]

Field 1 is stored unchanged (`raw_code_field`). The **extracted code** (`employee_code`), used only for mapping, is:

1. Remove **leading U+0020 SPACE characters only**. Nothing else is removed:
   - not tabs, not other whitespace;
   - not trailing characters;
   - not zeros.
2. The result must match `^[A-Za-z0-9_-]{1,32}$` (the AttendOS device-code rule). Otherwise
   `employee_code = null` and the row is marked `code_invalid` with a reason:

| Reason | Example |
|---|---|
| `empty_code` | field 1 is all spaces |
| `trailing_space` | `·······10·` |
| `inner_space` | `······1·0` |
| `invalid_character` | any character outside the code rule |
| `too_long` | more than 32 characters remain |

3. **Never** convert to a number, strip zeros or change case: `·······10` → `10`, `······010` → `010`,
   `·····0010` → `0010` — three different codes.
4. **Width:** the observed width is 9.
   - A row whose field 1 is not 9 characters wide is still extracted by the same rule, and flagged
     `code_width_unexpected` (information, not an error).
   - The real width rule is an open question (Q4).
5. The rule is specific to `essl.dat_import` for this export format. It is not applied to SDK or ADMS data, whose
   codes arrive without padding.

This **replaces** Revision 4's "a code containing spaces is `code_invalid`", **for leading spaces in field 1 of this
format only**. Trailing and inner spaces remain invalid. That keeps the C3 concern from Revision 4 closed: a code with
any space left after extraction can never match a mapping.

---

## 5. Timestamp extraction rule [RULE]

- `local_time_text` = field 2 exactly. It must match `^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$`, the format observed in
  every line.
  - A different shape (e.g. `05/03/2030 09:00`, or a `T` separator) → `time_status = bad_format`. The row is kept,
    and counts as malformed (§6).
- `local_ts` = `biometric_parse_local(local_time_text)`, the existing strict function: real calendar dates, years
  2000–2100.
  - An impossible value (30 Feb, hour 24, minute 60) → `time_status = impossible_date`, `local_ts = null`.
  - The row is kept and does **not** count as malformed, because its structure is intact.
- **Time zone:** the file has none.
  - The batch's declared zone is used (Rev 4 §4). Default: the X2008 device record's zone, Asia/Kolkata — to be
    confirmed (Q6).
  - `instant` is a separate value; ambiguous or non-existent local times are never resolved (Rev 4 §4).
- The original string is never changed: no trimming, reformatting, rounding or drift correction.

---

## 6. Parser specification (M2; design only)

**Accepted format profile `essl.x2008.attlog/1`:**

| Property | Profile value | If different |
|---|---|---|
| Encoding | UTF-8, ASCII content expected | invalid UTF-8 or UTF-16/32 → file refused `unsupported_encoding` |
| BOM | none expected; a UTF-8 BOM is accepted and recorded | — |
| Line ending | CRLF | LF-only or mixed → file refused `unexpected_line_endings` (not observed; may be allowed later only by owner decision) |
| Final newline | expected; its absence is accepted and recorded | — |
| Header | none | first line not a record → file refused `unexpected_header` |
| Delimiter | TAB | — |
| Fields | 6 | a line with another count → row kept as `unparsable` (`field_count_<n>`) |
| Line length | ≤ 512 bytes (observed 41) | longer → file refused `line_too_long` |
| Fields per line | ≤ 16 | more → file refused `too_many_fields` |
| Binary content | none | NUL or other control bytes (except TAB, CR, LF) → file refused `not_a_text_file` |

**Malformed rows** are field-count errors, `code_invalid` and `time_status = bad_format`.
- If they are ≤ 2 % of non-blank lines, every such row is kept with its reason.
- Above 2 %, the whole file is refused `too_many_malformed_rows`.

**Blank lines** are kept as `blank` rows if ≤ 1 % of lines; above that the file is refused `too_many_blank_rows`.

**A refused file leaves nothing behind** but batch metadata and the reason (Rev 4 §3.3). Otherwise **every line
becomes exactly one row**, in file order, with:
- `line_no`, `raw_line` (exact text without terminator), `terminator`, `line_length`, `fields[]` (exact);
- `raw_code_field`, `employee_code`, `code_status`;
- `local_time_text`, `local_ts`, `time_status`, `instant`;
- `parse_status` + `parse_reason`, `line_hash`, `dup_class` + pointer;
- informational notes (`code_width_unexpected`, `out_of_order`).

Malformed and duplicate rows are **never** removed.

**Order:** rows keep file order. A row whose `local_ts` is earlier than the previous valid row's is marked
`out_of_order` (information). Nothing is re-sorted.

**Duplicates** (Rev 4 §6, unchanged):
- `exact_in_file` — same `line_hash`;
- `exact_in_earlier_import` — same source device;
- `same_code_time_other_fields` — same extracted code and same `local_ts`, different raw line;
- `already_from_device` — SDK/ADMS raw events of the same device.

The supplied file has none of the first and third kind [OBSERVED].

**No attendance meaning:**
- no direction, sessions, pairing or hours;
- no `attendance_events`, register rows or `biometric_raw_events`;
- no projection.

---

## 7. Confirmed mapping and the supplied file

| Device | Extracted code | AttendOS employee | Status |
|---|---|---|---|
| eSSL X2008 (device record) | `10` | WR198 | owner-confirmed — the only mapping |

- The supplied file has **four** records whose extracted code is `10`, at **lines 24, 95, 150 and 151** [OBSERVED].
- They are raw device records, not attendance sessions; two of them are on the same day.
- Their exact timestamps were first withheld from this document as one identifiable person's attendance data. On
  23 Nov 2026 the owner, who is that person, supplied them for the HR-report comparison. They are recorded in
  BIOMETRIC_HR_REPORT_CORRELATION.md §2.1, which also compares them with the eSSL HR report. On 21 Nov the export contains two records 3 min 45 s apart, and that
  report displays only the first as InTime. Whether eSSL received the second is not established. Raw record count is
  not a reliable basis for IN/OUT pairing.
- **No other code is mapped.** The other 16 codes are reported as unmapped when the file is imported. Any
  similarity between a device code and an AttendOS employee code is ignored.
- The mapping is created by an Admin or HR in the existing mapping screen, as a device-specific mapping on the X2008
  record, with a `valid_from` the owner confirms (Rev 4 R11).
  - With `valid_from` on or before the earliest code-10 record, all four rows resolve to WR198.
  - With a later `valid_from`, earlier rows show `unmapped`. That is correct behaviour, not an error.

---

## 8. Parser test specification

### 8.1 Synthetic tests

Fixtures are in `tests/fixtures/dat/` (all synthetic; see its README for bytes, hashes and expected results).

**Global assertions for every test:**
- the stored original is byte-identical, and its SHA-256 equals the fixture's;
- for accepted files, row count = line count;
- `raw_line` and `fields[]` are byte-identical to the input;
- nothing is written outside import staging;
- `attendance_events`, `biometric_raw_events` and `biometric_event_state` are unchanged.

| ID | Requirement | Fixture | Acceptance criteria |
|---|---|---|---|
| P1 | Observed six-field structure | f01 | 100 rows `ok`; each row has 6 `fields`; `local_time_text` equals field 2; 8 rows with code `10` |
| P2 | Leading-space-padded codes | f01, f02 | `raw_code_field` keeps the 9-character field; `employee_code` has no leading spaces |
| P3 | `10`, `010`, `0010` distinct | f02 | three different `employee_code` values; a mapping for `10` matches only the first |
| P4 | Exact timestamp preservation | f01, f07 | `local_time_text` byte-equal to field 2 in every row, including invalid ones |
| P5 | CRLF and final newline | f01, f03 | terminators recorded per line (`crlf`; last line of f03 `none`); originals byte-identical |
| P6 | Unexpected line endings | f04 | file refused `unexpected_line_endings`; nothing kept |
| P7 | Missing and extra fields (at the limit) | f05 | lines 40 and 70 kept `unparsable` (`field_count_5`, `field_count_7`); 98 `ok` |
| P8 | Malformed over threshold | f06 | file refused `too_many_malformed_rows`; nothing kept |
| P9 | Invalid timestamp | f07 | lines 21–22 `impossible_date`, `local_ts` and `instant` null, strings unchanged, rows kept, not counted as malformed |
| P10 | Timestamp wrong format | f07b | line 31 `bad_format`, kept, counted as malformed (1 %) |
| P11 | Invalid encoding | f08, f08b | file refused `unsupported_encoding`; nothing kept |
| P12 | UTF-8 BOM | f08c | accepted; `bom = utf8`; original keeps the BOM |
| P13 | Blank rows | f09, f09b | f09: line 61 kept as `blank`, others `ok`; f09b refused `too_many_blank_rows` |
| P14 | Exact duplicates | f10 | lines 16 and 26 `exact_in_file` pointing to 15 and 6; all 32 rows kept |
| P15 | Same code and time, different raw fields | f11 | line 14 `same_code_time_other_fields` → 13; both kept and shown together |
| P16 | Chronological and out-of-order records | f01, f12 | f01: no `out_of_order`; f12: lines 12 and 21 noted `out_of_order`; file order kept |
| P17 | Unknown field values | f13 | every value (incl. empty, `x`, `-1`, `01`, `00`) stored exactly; nothing derived from them |
| P18 | Code field variants | f14 | lines 1–3 → `10` (2–3 `code_width_unexpected`); line 4 `code_invalid trailing_space` (also `code_width_unexpected`: 10 wide); line 5 `inner_space`; line 6 `empty_code`; line 7 → `A-10` |
| P19 | Header line | f15 | file refused `unexpected_header` |
| P20 | Binary file | f16 | file refused `not_a_text_file` |
| P21 | Limits | f17, f17b | refused `line_too_long` / `too_many_fields` with line 11 |
| P22 | No interpretation | all accepted fixtures | no direction, verification or attendance value is stored or returned anywhere |
| P23 | Mapping preview with code `10` | f01 + device mapping `10` → test employee with `valid_from` between two code-10 rows | rows before `valid_from` `unmapped`, rows at or after it `mapped`; other codes `unmapped`; no mapping created by the import |

Rev 4's upload, security, retention and audit tests (T-UP, T-SEC, T-DEL, T-AU) are unchanged and run with these
fixtures.

### 8.2 Real-file check (local only, never committed)

Run once by the owner against their copy, after M2 is built and approved. It confirms the format record:
- 151 rows, all `ok`;
- 0 blank rows; 0 `exact_in_file`; 0 `same_code_time_other_fields`;
- every line 41 bytes; every field 1 is 9 characters; terminators all `crlf`;
- 17 distinct extracted codes;
- code `10` exactly on lines 24, 95, 150, 151, with the timestamps in the owner's inspection note;
- SHA-256 equals the value recorded in §1.

A mismatch is reported to the owner, not "fixed".

---

## 8.3 Implementation status (23 Nov 2026, correction pass)

Implemented locally as profile `essl.x2008.attlog/1`:
- migration `supabase/migrations/0013_biometric_dat_import.sql`, local only and not applied to any hosted database;
- the screen *Biometric Devices → File import* (HR and Admin prepare imports; an Admin approves).

What the implemented reader accepts — and nothing more:
- **Line endings: CRLF only.** Every line must end in CRLF (the last line may have no ending). A file with any bare LF
  or bare CR is refused as `unexpected_line_endings` and nothing is kept. LF-only files are **not** accepted; that would
  need a separate specification, tests and a new profile version.
- **Devices: X2008 only.** An Admin assigns the profile to each device; only eSSL devices of model X2008 can receive it,
  and the model is checked again at every import. No other eSSL model, firmware or export menu is claimed.
- The batch records the device's model and firmware and the profile used.
- Code rule broader than observed: letters, `_` and `-` up to 32 characters are accepted as codes (the export showed
  digits only, at most 2 characters). Those cases are tested only with synthetic fixtures.

All P-tests above, the real-file check (R0–R17) and the upload, security, mapping, time, duplicate, deletion and audit
tests run in `supabase/tests/biometric_dat_import_test.sql` (see BIOMETRIC_B5_DAT_IMPORT_REPORT.md).

## 9. Changes to earlier revisions

| Document | Change |
|---|---|
| Rev 3 §2.2 | "USB attendance export" and "original DAT format" are now **observed for one supplied file**. All other X2008 capabilities are still unverified |
| Rev 3 §4.3 | the pending format record is this document |
| Rev 4 §3.2 | line endings: CRLF only (the observed profile, and what the reader implements); LF-only or mixed files are refused unless the owner separately specifies and tests them |
| Rev 4 §3.3 | header: none; delimiter: TAB; field count: 6 (other counts are malformed rows) |
| Rev 4 §3.4 / §5.1 | adds `raw_code_field` and the leading-space extraction rule (§4); `employee_code` is the extracted value; trailing or inner spaces remain `code_invalid` |
| Rev 4 T-FM8 | ` 10` (leading space) now extracts to `10`; `10 ` (trailing) stays `code_invalid` — see P18 |
| Rev 4 R16 | limits unchanged; the observed 41-byte lines and 151 rows are far inside them |

---

## 10. Open questions for HR / eSSL

| # | Question | Why it matters |
|---|---|---|
| Q1 | The device showed **31,207** stored attendance records; this export has **151** (2–21 Nov 2026). Was the export **restricted by date** or another selection in the USB menu? | **This file must not be treated as the device's full history.** Completeness checks depend on it |
| Q2 | Does the USB download export all historical punches, or only a range, or only records not yet downloaded? Does downloading delete or mark records on the device? | completeness; read-only behaviour (Rev 3 §2.2) |
| Q3 | Was the file opened or re-saved in any program (Excel, Notepad, eSSL software) before it was supplied? | any re-save can change padding, line endings or values; the importer must receive the device's original bytes |
| Q4 | Is field 1 **always** padded to nine characters? What happens with codes longer than 9 digits? | the extraction rule tolerates other widths but flags them |
| Q5 | What do fields 3, 4, 5 and 6 mean (eSSL documentation for this firmware)? | until documented they stay uninterpreted; direction is never inferred |
| Q6 | Which time zone is the device clock set to? Is the clock kept correct (NTP or manual)? | the declared zone for imports; the file carries no zone |
| Q7 | Does eSSL software (eTimeTrackLite or other) modify, filter or re-export the original records anywhere in this workflow, or did this file come straight from the device to the USB stick? | provenance; trust is "imported file" only |
| Q8 | The supplied name ends ` (1)(1)`: is this a copy of the stick's file? Can the next file be supplied straight from the stick? | provenance |
| Q9 | ~~SHA-256 of the original~~ — **answered 23 Nov 2026** (§1). Q8 still open: the uploaded copy was named `…_attlog__1_.dat`, the earlier one `…(1)(1).dat`; the bytes match the inspection exactly | — |
| Q11 | See BIOMETRIC_HR_REPORT_CORRELATION.md §5 for the questions raised by comparing this export with the eSSL HR report (data source, 15:53:01 punch, shift settings, seconds) | the report and the export may not come from the same records |
| Q10 | Can the export include other files (user, fingerprint, photo data)? Which files appeared on the stick? | anything other than the attendance file is out of scope and must never be uploaded |
