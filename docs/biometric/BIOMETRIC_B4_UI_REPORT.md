# Biometric B4 — application UI integration (local implementation and test report)

Date: 21 Nov 2026 (accessibility polish and completion record added the same day, §10). Branch `feature/biometric-b1`.
**Commits:** functional B4 `645b92741e40468f4671aac409e564d9af2af6f9`; accessibility polish
`6bfea2aae354eb64f957cdb9fd663857e150fd3c`; this report is committed on top of that (the final HEAD hash is in §10's
note and in the completion message, since a commit cannot contain its own hash). Authorisation: "AttendOS — B3.4
Owner Decision + B4 Local Implementation Authorization". **Local only:** nothing ran against hosted Supabase; no
pg_cron; no hardware; projection is off for every company; nothing merged, tagged or deployed; no invitations sent.

## 1. B3.4 owner decision (recorded)

The approved pair-selection policy is recorded in BIOMETRIC_B3_4_PROJECTION_DESIGN.md §13, the implementation report
§12.5, PROJECT.md and the status table. No B3.4 logic was changed (no migration file is modified by this commit).

## 2. What was built

| Area | Where | What it does |
|---|---|---|
| Source labels | `src/lib/sources.ts`, `src/components/SourceBadges.tsx` | One wording everywhere: **Web, Biometric, Imported, Correction** (text + shape, never colour alone). |
| Verification wording | `verificationOf()` in `sources.ts` | Only a web punch can say "Location verified (GPS)". Biometric: "Biometric device record · not GPS-verified" (records which device recorded the mapped code — never "verified" or "authenticated"). Imported: "Imported record · not GPS-verified". Correction: "Approved correction". |
| Day timeline | `src/components/DayTimeline.tsx` | `day_events` (0012): time, IN/OUT, source, device, status, counted or not and why. Direction of an uncounted punch from `biometric_raw_events_safe` (HR/Admin only; employees see "Punch"). Provisional note from `biometric_day_pending`. Table on desktop, cards on phones. |
| My Attendance → Today | `AttendanceCard.tsx` (Timeline) | Biometric lines say "Biometric device record · not GPS-verified"; provisional check-out note; link to the full day timeline. |
| History (My Attendance, profile) | `HistoryPanel.tsx` | Source column, provisional check-out in the Out column, date opens the day timeline. |
| Attendance Register | `register/Register.tsx` | Source column, provisional check-out, Timeline button; CSV gets **Source as the last column** (15 existing columns unchanged). |
| Reports (late / overtime) | `reports/ReportScreens.tsx` | Source column on screen and in the CSV (last column). |
| Verification history | `LocationsPanel.tsx` | Biometric / imported rows: "Biometric · not GPS-verified" / "Imported · not GPS-verified" (were shown as "No location needed"). |
| Dashboard activity | `DashboardWidgets.tsx` | "· biometric device" / "· imported" beside the event. |
| Biometric module (approved B2 screens) | `src/lib/biometric-live.ts`, `components/biometric/*`, `app/(app)/biometric/page.tsx` | Connected: the company's real records under row level security; every change through the checked database functions (`biometric_save_device`, `_set_device_status`, `_set_direction_mode`, `_save_mapping`, `_end_mapping`, `_review_event`), then reload. Preview (no database): the B2 demonstration as before. A database without the biometric tables shows "not set up" instead of an error. |

Nothing calculates attendance in the browser: worked hours, overtime, early leaving and status come from the engine
(`attendance_register`, `attendance_history`, `my_today`); sources and provisional state from `attendance_day_sources`
/ `biometric_day_pending`. No new migration was needed (no database gap found).

**Provisional check-out.** Shown only as a "Provisional" badge in the Check-out column, an explanation on Today and in
the timeline ("not counted in working hours, overtime or early leaving; final when the day closes at …"). The CSV does
not export it as a check-out. The engine keeps the day open (status Working, no last out, no overtime/early leaving)
until day close and projection — verified against the database in the tests.

## 3. Changed files

New: `src/lib/sources.ts`, `src/lib/biometric-live.ts`, `src/components/DayTimeline.tsx`, `src/components/SourceBadges.tsx`,
`tests/b4.test.ts`, `e2e/biometric_b4.py`, `supabase/demo/biometric_demo.sql` (local demo data only).
Changed: `app/(app)/biometric/page.tsx`, `globals.css` (B4 block, semantic tokens only), `AttendanceCard.tsx`,
`DashboardWidgets.tsx`, `HistoryPanel.tsx`, `LocationsPanel.tsx`, all `components/biometric/*`, `EmployeeProfile.tsx`,
`register/Register.tsx`, `reports/ReportScreens.tsx`, `lib/attendance.ts` (event source type), `lib/biometric-mock.ts`
(types extended for the real states), `lib/nav.ts` / `lib/permissions.ts` (labels no longer say "demonstration"),
`supabase/demo/rebuild.sh` (adds the demo biometric data), `tests/biometric.test.ts` (two B2 assertions updated),
`e2e/biometric_b2*.py` (marked superseded for connected mode), docs.

## 4. Role-by-role results (executed in the browser against the local stack; database checked after each action)

| Role | Result |
|---|---|
| Admin | Live module, five B2 tabs, no demonstration wording. Disable / enable a device (with confirmation) saved and audited; direction editable; 8-step wizard registers a device in the database; company-wide mapping offered; hardware buttons disabled. |
| HR | No Add device, no Disable, direction read-only, no company-wide option. Maps an unmatched code (the waiting punch is attributed at its own time); dismisses a punch with a reason (saved with role, reason, new version; history shows name · HR and reason); too-short reason stopped in the form and refused by the database; correction_needed punch offers only Dismiss. Direct API calls to add a device, change direction or map company-wide → **403**. |
| Manager, Employee | Permission denied, no menu item. Direct API: `biometric_devices` and `biometric_raw_events_safe` return no rows; `biometric_review_event` → 403; `biometric_raw_payload` → 403/404. Employees see their own day timeline (no raw-record request is made for them). |

## 5. Test results (all executed 21 Nov 2026)

| Suite | Result |
|---|---|
| `e2e/biometric_b4.py` (new) | **60/60** — roles, actions, sources, verification, provisional, CSV, timeline/history, themes × sizes, contrast, empty/loading/error, privacy |
| `npm run check` (tsc + eslint + unit) | **64/64** (53 earlier + 11 in `tests/b4.test.ts`) |
| `e2e/regression.py` (existing app: GPS check-in/out, corrections, leave, exports, print, 208 screen loads) | **29/29** |
| `npm run test:db` | **872** checks, exit 0 (no migration changed) |
| HTTP: gateway / projection | **18/18**, **17/17** (demo now includes the biometric data) |
| `npm run build` | ok |
| `e2e/biometric_b2.py` (B2 demonstration suite) | **superseded for connected mode**: stops at its first check of the demonstration banner, which since B4 exists only in preview mode. Replaced by `biometric_b4.py`. |

Concurrency proofs were not re-run: no SQL changed since they last passed (17/17, 21/21, 6/6).

### Themes and sizes
Dark and light × 390 / 820 / 1440 px × biometric overview, review queue, register, My Attendance (+ the day timeline on
phone and tablet): 24 loads, no sideways page scrolling, no console errors. Register and history tables still fit at
1440 px with the Source column (checked). Contrast measured as painted: source badges 3.76:1 (light) / 3.94:1 (dark),
at least as readable as the existing status badges (2.67:1 / 3.94:1) — **superseded by §10: all source badges now meet
WCAG AA (5.83–8.96:1).**

### CSV sample (register, daily, first lines)
```
Employee,Employee ID,Department,Date,Shift,Work location,Check-in,Check-out,Working hours,Break (min),Late (min),Early leave (min),Overtime (min),Status,Note,Source
Deepak More,E0122,Operations,21 Nov 2026,General,office,07:33 am,,4.00,,,,,Working,,Biometric
Esha Patil,E0104,Sales,21 Nov 2026,General,office,09:51 am,,1.70,,21,,,Working,,Web
Suresh Pawar,E0120,Operations,21 Nov 2026,Early,office,07:00 am,,4.55,,,,,Working,,Biometric
```
Deepak's Check-out is empty: his later biometric punch is only a provisional check-out. Person month export (Deepak):
```
Deepak More,E0122,Operations,19 Nov 2026,General,office,09:28 am,06:32 pm,9.07,,,,64,Present,,Biometric + Correction
```
Full files (copied from the test run's downloads) are in the evidence ZIP.

## 6. Privacy and permission boundaries (executed)

Every API request of the Admin, HR and employee sessions was recorded: no call to `biometric_raw_payload` /
`biometric_error_payload`, no read of `biometric_raw_events` itself (only the column-limited safe view), no read of
agent credentials; no response contains a payload, key hash or agent key; all changes are POSTs to the six checked
functions (no PATCH/PUT/DELETE, no direct table write). A source scan in the unit tests enforces the same. Projection
is off for every company after the tests.

## 7. Deviations from the approved B2 screens

1. **Review kinds follow the real database states.** Besides the B2 kinds, the queue shows *Needs review* (flagged),
   *Extra punch*, *Needs an attendance correction* (only Dismiss; points to the correction workflow) and *Waiting (on
   hold)* (no decision; looked at again automatically). Reasons are written from the stored flags/hold reasons.
2. **Sync Agent queue depth** shows "Not reported" (the database does not store it); the key prefix is not shown (the
   credentials table is not readable by any client role, by design).
3. **Sync runs are per agent delivery**, not per device; the Device column says "All devices of <agent>". *Unmatched*
   counts punches of the run still waiting for a mapping. Retry timing is not stored, so not shown.
4. **Mapping history** is built from the mapping records (created / ended with reason and by whom), not a separate log.
5. **Hardware actions** (Test connection, Sync now, Retry failed syncs) stay disabled: "Arrives with the Sync Agent".
6. **Add device wizard**: the push-authentication choice is saved as a connection setting; a device's communication-key
   requirement (`device_auth`) and Sync Agent registration have no screen (owner set-up), so a company with no agent can
   register only file-import devices.
7. The client-side "Before you save" conflict panel uses the records loaded on screen; the database is the authority
   (it refuses overlaps and moves of processed punches with its own message, shown in the dialog).
8. History: the date opens the day timeline (no extra column, so the table still fits); the register stacks Timeline
   and View in the actions cell.

## 8. Remaining issues and risks

- **Hosted order of work:** this frontend expects migrations 0010–0012. On a database without them it degrades safely
  (module "not set up", Source column blank, timeline "not available"), but it must not be deployed before the owner
  approves the hosted migrations.
- **Status badge contrast** (existing design system, not changed): light theme as low as 2.67:1 for small text. The
  source badges were fixed in §10; the status badges need a separate design decision.
- **Order-dependent projection outcome** (B3.4 §11.6) shows up in real use: if today's punches are projected before an
  older day, the older day's punches go to HR as impossible transitions. The demo data is ingested oldest first.
- **Imported punches** are stored but never counted yet (`import_not_enabled`), so no counted "Imported" row can exist;
  the label is covered by the timeline (waiting import row) and unit tests.
- Open sessions show live worked time (engine behaviour); a provisional check-out never adds to it.
- The B2 demonstration browser suites now apply to preview mode only.

## 9. Confirmation

No hosted Supabase SQL or permission change, no pg_cron, no hardware connection, projection not enabled for any real
company (the local demo company only, inside the demo script, switched off again), no credential change, no
invitations, no merge, no tag, no deployment. Local databases only: `attendos_test`, throwaway copies, `attendos_demo`.

## 10. Accessibility polish and completion record (21 Nov 2026)

Request: "AttendOS B4 — Final Accessibility Polish and Completion Record". Local only; B4 screens not redesigned; no
migration changed (`git diff 645b927 -- supabase/migrations` is empty).

### 10.1 Source badge contrast — fixed

Source badges (`SourceBadge` in `src/components/SourceBadges.tsx`, class `.src-badge` in `globals.css`) now use their
own colours, built only from the existing semantic tokens:

- text = the source tone mixed 55 % with `--color-text` (lighter in dark, darker in light);
- background = the tone at 14 % over `--color-surface` (opaque, so the glass behind it cannot lower the contrast);
- a 1-px outline in the tone; no brightness filter.

Tones are unchanged (Web neutral, Biometric and Imported info blue, Correction amber), so the sources stay
distinguishable. Each source also has its own **marker shape**: Web a filled dot, Biometric a ring, Imported a square
with a **dashed outline**, Correction a diamond. Together with the text label, colour is never the only cue.

Status badges, the glass theme and the orange accent are **not** changed (a unit test checks that the base badge rule
and the light-theme status filter are unchanged). The verification history uses the same source badge.

**Final contrast ratios** (WCAG AA needs ≥ 4.5:1). Two independent measurements give the same numbers:

| Source | Light theme | Dark theme | Before (light / dark) |
|---|---|---|---|
| Web | **7.05:1** | **8.54:1** | 3.76 / 3.94 |
| Biometric | **7.32:1** | **7.39:1** | 3.99 / 3.94 |
| Imported | **7.32:1** | **7.39:1** | 3.99 / 3.94 |
| Correction | **5.83:1** | **8.96:1** | not measured in the browser (2.67 light by calculation) |

1. Computed from the tokens in `globals.css` (unit test `B4 source badges meet WCAG AA…`).
2. Measured as painted in Chrome on the Register, the corrected day, an imported punch's timeline and the verification
   history, in both themes. The browser test records `b4-contrast.json` and uses the lowest value found per source.

### 10.2 Visual regression

Nine screens were checked: Biometric overview, device list, mapping, sync activity, review queue, Attendance Register,
My Attendance, the day timeline and the verification history. Each ran in dark and light at 390, 820 and 1440 px.

- **54 screen loads:** no sideways page scrolling and no console errors. The timeline dialog stays within the screen.
- **Keyboard focus:** a visible outline was checked on the review queue in both themes.
- **Screenshots:** each screen is in the evidence ZIP (`screenshots/<screen>-<size>-<theme>.png`).

### 10.3 Final test results (all executed 21 Nov 2026 after the polish)

| Suite | Result |
|---|---|
| `e2e/biometric_b4.py` | **61/61** (adds the painted contrast check per theme and the 54-load visual regression; the earlier relative-contrast checks were replaced) |
| `npm run check` | **66/66** (adds the token contrast test and the marker-shape / no-status-change test) |
| `e2e/regression.py` | **29/29** |
| `npm run test:db` | **872** |
| HTTP gateway / projection | **18/18**, **17/17** |
| `npm run build` | ok |

### 10.4 Files changed by the polish

`src/app/globals.css` (the `.src-badge` block), `src/components/SourceBadges.tsx` (`SourceBadge`),
`src/components/DayTimeline.tsx` (uses `SourceBadge`), `src/components/LocationsPanel.tsx` (same badge in the verification
history), `tests/b4.test.ts`, `e2e/biometric_b4.py`, and this report. The full B4 file list is in §3.

### 10.5 Remaining limitations

- The existing **status badges** are not changed. In the light theme they are as low as 2.67:1 for small text, and
  fixing them is a separate design-system decision.
- **Wide tables on phones** (verification history, register) still scroll inside their card, as they did before B4. The
  page itself does not scroll sideways.
- **Hosted migrations first:** the frontend needs migrations 0010–0012 before it is deployed. Without them it degrades
  safely (§8).
- **Earlier B4 limitations still apply:**
  - Order-dependent projection (B3.4 §11.6).
  - Imported punches are stored but never counted yet.
  - Sync Agent registration and device communication keys have no screen.
  - The B2 demonstration browser suite now applies to preview mode only.

### 10.6 Completion record

- **Branch:** `feature/biometric-b1`. Not merged, no tag, not deployed.
- **Commits:** `645b92741e40468f4671aac409e564d9af2af6f9` B4 functional; `6bfea2aae354eb64f957cdb9fd663857e150fd3c` accessibility polish. This report
  update is the next commit, and its exact hash (the final HEAD) is in the completion message.
- **Not touched:** no hosted SQL, no hosted migration or permission change, no pg_cron, no hardware, no real-company
  projection, no credential change.
