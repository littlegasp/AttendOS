# Synthetic X2008-style DAT fixtures

**Every file in this folder is synthetic.** The rows were generated to match the structure of the owner's X2008
attendance export, as recorded in docs/biometric/BIOMETRIC_DAT_FORMAT.md:
- six tab-separated fields;
- field 1 right-aligned to nine characters with leading spaces;
- `YYYY-MM-DD HH:MM:SS` timestamps;
- CRLF line endings.

**Nothing here is real data:**
- No real attendance record, real employee code list or device serial is used.
- Dates are in March 2030, so a synthetic row can never be mistaken for a real one.
- Code `10` appears only as a string, so the mapping rules can be tested.
- The values in fields 3–6 are arbitrary. They imply nothing about what those fields mean.

**Never add a real export here.** `.gitignore` ignores `*_attlog*.dat` anywhere in the repository.

These fixtures support the parser test specification (BIOMETRIC_DAT_FORMAT.md §8). No parser exists yet; the
"expected" column is the specification the M2 implementation must meet.

| File | Bytes | SHA-256 (first 16 hex) | Lines | Case | Expected result |
|---|---|---|---|---|---|
| `f01_six_field_crlf.dat` | 4031 | 6c76bc909a7a4e59 | 100 | observed structure, chronological, final CRLF | accepted; 100 rows `ok`; 8 rows with extracted code `10` |
| `f02_codes_10_010_0010.dat` | 123 | 334865950883743c | 3 | codes `10`, `010`, `0010` padded to 9 | three distinct extracted codes; none converted |
| `f03_no_final_newline.dat` | 805 | 7fdebb3bac6c91a3 | 20 | CRLF, last line without terminator | accepted; last row terminator `none`; byte-identical original |
| `f04_lf_only.dat` | 780 | 0ece1652d26c46ae | 20 | LF endings (not observed on the X2008) | file refused `unexpected_line_endings` (rule may change only by owner decision) |
| `f05_missing_and_extra_field.dat` | 4030 | a506783ebca2fcd5 | 100 | line 40 has 5 fields, line 70 has 7 (2 % — at the limit) | accepted; lines 40 and 70 kept `unparsable` (`field_count_5`, `field_count_7`); 98 `ok` |
| `f06_malformed_over_threshold.dat` | 4033 | 9ea15222a2437d6a | 100 | 3 lines with 5 fields (3 %) | file refused `too_many_malformed_rows`; nothing kept |
| `f07_invalid_timestamps.dat` | 4021 | 2376e287a875f55e | 100 | line 21 `2030-02-30 09:00:00`, line 22 `2030-03-05 24:00:00` | accepted; both rows kept with exact strings, `time_status = impossible_date`, no instant |
| `f07b_timestamp_bad_format.dat` | 4040 | 703e1e6fea4d412a | 100 | line 31 `05/03/2030 09:00` | accepted; line 31 kept, `time_status = bad_format` (counts as malformed: 1 %) |
| `f08_invalid_utf8.dat` | 400 | c1dc3eede2bf11e2 | 10 | byte `0xFF` in line 1 field 1 | file refused `unsupported_encoding`; nothing kept |
| `f08b_utf16_bom.dat` | 398 | 5e673ed3af822b9d | — | UTF-16 with BOM | file refused `unsupported_encoding` |
| `f08c_utf8_bom.dat` | 409 | f7b15ec7496daf48 | 10 | UTF-8 BOM (not observed on the X2008) | accepted; `bom = utf8` recorded; original keeps the BOM |
| `f09_one_blank_row.dat` | 4810 | ae0734a71ac9382d | 121 | blank line 61 (0.8 %) | accepted; line 61 kept as `blank` |
| `f09b_blank_rows_over_threshold.dat` | 4034 | 24b29c2cc1f7eef9 | 103 | blank lines 21, 51, 81 (2.9 %) | file refused `too_many_blank_rows` |
| `f10_exact_duplicates.dat` | 1281 | 8c39cd4ed2f27297 | 32 | line 16 = line 15; line 26 = line 6 | accepted; lines 16 and 26 `exact_in_file` → 15 and 6; all 32 rows kept |
| `f11_same_code_time_other_fields.dat` | 1246 | b01e757bb29d7ccb | 31 | line 14: same code and time as line 13, different fields 3–6 | accepted; line 14 `same_code_time_other_fields` → 13; both kept |
| `f12_out_of_order.dat` | 1208 | dd01c426ec90aad1 | 30 | lines 11 and 21 swapped | accepted; order kept as in the file; `out_of_order` noted on lines 12 and 21; nothing re-sorted |
| `f13_unknown_field_values.dat` | 204 | bf4a89e6ba18ed91 | 5 | fields 3–6 with unusual or empty strings (`9`, `999`, ``, `x`, `-1`, `01`, `00`) | accepted; values stored exactly; no field interpreted |
| `f14_code_field_variants.dat` | 6420 | 4607941b9c323ee3 | 157 | lines 1–7, field 1: 9-wide `10`; unpadded `10`; 12-wide `10`; `10 ` (trailing space); `1 0`; all spaces; `A-10` — then 150 valid lines, so the 3 invalid codes stay under the 2 % malformed limit | lines 1–3 → code `10` (lines 2–3 flagged `code_width_unexpected`); line 4 `code_invalid` (trailing space; field is 10 wide, so also `code_width_unexpected`); line 5 `code_invalid`; line 6 `code_invalid` (empty); line 7 → `A-10` |
| `f15_header_line.dat` | 835 | 43896521c57ed8b1 | 21 | header text on line 1 | file refused `unexpected_header` |
| `f16_binary.dat` | 2048 | 47294e680a3ee6fa | — | random bytes | file refused `not_a_text_file` |
| `f17_line_too_long.dat` | 2516 | 4ba22aa5462f74d9 | 50 | line 11 over 512 bytes | file refused `line_too_long` (line 11) |
| `f17b_too_many_fields.dat` | 2019 | 453a23beaf3ac2e9 | 50 | line 11 with 17 fields | file refused `too_many_fields` (line 11) |

The full SHA-256 of each file is re-computed by the test suite. The short prefixes above only help a reviewer
recognise the files.
