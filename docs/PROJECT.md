# AttendOS — project status

## Phase 0 — repository audit (done, 19 Nov 2026)
No AttendOS repo existed, so the project starts fresh on **studio-crm's stack and patterns**:
- Reused from studio-crm: static Next.js export + Cloudflare config, `_headers`, the before-paint
  theme boot script and `data-theme` mechanism, menu fold remembered per device, the gliding
  menu highlight (`SlidingHighlight`), tap ripple (`ClickFeel`), event-based toasts, skeleton
  loading, glass material with reduced-transparency fallback, phone bottom tab bar.
- Not reused yet: Supabase session/auth, migrations, Help guide system (they arrive with real data).

## Phase 1 — foundation (done, awaiting review)
- Design tokens from the guide, dark (default) + light, Inter, 8px spacing scale.
- Shell: 250px sidebar that folds to a 76px rail with tooltips (tablets start folded),
  68px header with page context, screen search (Ctrl/⌘ K), notifications, theme switch, profile menu;
  phones get a compact header, slide-in menu and bottom bar (Home, Attendance, Leave, Menu).
- Navigation groups Workspace / Management / Insights / Configuration, filtered by role.
- Role matrix in `src/lib/permissions.ts`; `RoleGate`, `PermissionGate`, `PermissionDenied`.
- Building blocks: GlassCard, SectionCard, MetricCard, Button (loading/disabled), StatusBadge,
  FormInput/Select/Textarea/DateInput, EmptyState, ErrorState, LoadingState, ConfirmDialog, Toaster,
  PageContainer + Breadcrumbs. Reference page at `/design`.
- All 12 routes share the shell; module screens say which phase builds them (no made-up figures).

### Known limits of Phase 1
- **Design preview mode:** no sign-in or database yet. The role comes from a labelled
  "Preview as role" switch in the profile menu. Phase 2 replaces it with real sign-in.
- Charts, DataTable/FilterBar/Pagination/DateRangePicker/ExportMenu, FileUpload and the attendance
  components (CheckInButton, LocationVerificationCard, Timeline, Timer) are built with their modules.

## Decisions (19 Nov 2026)
- ~~One company per copy~~ — **replaced on 19 Nov 2026 (before Phase 3): one shared Supabase project,
  `company_id` on every table**, isolated by row level security (see "Multi-tenancy" below). Each company
  still gets its own name, logo and accent colour (now a row in `companies`; `src/lib/brand.ts` is only the
  fallback for the design preview), so it feels like their own system. Status colours never change.
- **Several office locations**, each a map point + area size (25–2000 m).
- **Office / remote roster set by HR**: a weekly pattern per person plus changes for single dates.
  Check-in follows it: office days must be inside the (rostered) office area, remote days need no
  office area, days off block check-in.

## Phase 2 — attendance core (done, awaiting review)
- Database `supabase/migrations/0001_attendance_core.sql`: organization rules, locations, departments,
  employees (first sign-in becomes Admin), roster pattern + date changes, attendance events,
  refused attempts, precise coordinates in a separate HR-only table, audit log on every roster,
  location, rules and employee change. Row level security on everything; anon has no access.
- `punch()` decides every check-in/out on the server: server time, roster, accuracy, distance to the
  office (haversine), one open session at a time (locked per person), check-out follows the check-in's mode.
- `my_today()`: today's plan, events and server clock for My Attendance.
- `set_roster_pattern()`: replaces weekly patterns for several people in one all-or-nothing step.
- Screens: Sign in + password reset, My Attendance (clock from server time, plan, Check In/Out,
  location verification card, every failure message, timeline, worked-time timer, screen-reader
  announcements), Shifts & Schedules → Work roster (HR edits, manager sees team, employee sees own),
  Settings → Locations & GPS (locations for HR/Admin; attendance rules Admin-only).
- Tests: `npm run test:db` (39 database checks on a local Postgres), `npm test` (14 app checks).

### Setting up (superseded)
Setup now follows `docs/DEPLOYMENT.md` (one shared project, four migrations, `create_company()`).

### Known limits of Phase 2
- No in-app employee onboarding, managers or departments yet (Phase 3) — set `manager_id` in the
  database if needed. No attendance corrections yet (Phase 3, with reasons and audit).
- Shift timings / late rules / overnight shifts come in Phase 4; sessions are not tied to a shift yet.
- Without the two build variables the app runs as the labelled design preview.

## Refinement pass (after Phase 2 review, 19 Nov 2026 — awaiting review)
Database `supabase/migrations/0002_refinement.sql` (nothing from 0001 removed):
- **Shifts separate from work location**: `shifts` (start, end, break, grace; overnight when end ≤ start),
  `shift_pattern` / `shift_day`, person default and company default. `shift_for()` mirrors `plan_for()`.
- **Work location plan** now: HR date change > holiday > remote-work exception > weekly pattern > default.
- **Breaks** (`break_start` / `break_end`, no location read), **work_date** on every event so overnight
  check-outs count for the shift's start date, check-out while on break closes the break.
- **day_for()** works out worked / break / late / early / overtime minutes and the day status
  (present, late, working, on break, missing check-out, absent, not started, off, holiday);
  days before someone joined are not counted. `attendance_history()` (self, manager, HR/Admin).
- **Corrections**: `request_correction()` (own, last 31 days, one pending per day), `cancel_correction()`,
  `decide_correction()` (HR/Admin any, Manager own team, never own). Approval adds events marked
  `source = 'correction'`; replaced originals are kept with `superseded_by`. Decisions audited.
- **Holidays** (all offices or one office), **remote-work exceptions** (date ranges), **assigned office /
  default shift per employee**, **verification_log()** (HR/Admin, no coordinates),
  **dashboard_summary()** scoped: Admin/HR organization, Manager self + team, Employee self.
- Internal helpers that take any employee id are not callable directly by users.
- Company rules: Admin only (also enforced by a trigger); the database owner (setup) may change them.
- Tests: 90 database checks (`npm run test:db`), 19 app checks.

Screens: Dashboard (team/org widgets, personal dashboard for employees and phones), My Attendance
(Today · History · Corrections, breaks, shift, late/early/overtime), Work roster (location chip + shift
line, separate sections in the editors) + Shifts tab, Holidays (list/add/remove), Settings →
Locations & GPS (Leaflet map with OpenStreetMap tiles, Nominatim address search, radius slider,
read-only rules for HR), Assignments & exceptions, Verification history.

### What is real and what is not (honest status)
| Item | Status |
|---|---|
| Database logic (check-in/out, GPS distance, breaks, calculations, corrections, roster, scopes) | Built and tested on PostgreSQL 16 locally (90 checks). Not yet run on a Supabase project. |
| App ↔ database | The review screenshots were taken with the real app talking to a real local REST API (PostgREST 12, as Supabase uses) over that database, with row-level security on. Sign-in was simulated with a signed test token because Supabase Auth only exists in a real project. |
| Demo company data | Sample people, offices, shifts and two weeks of history created for the review (`supabase/demo/` — local-only; the JWT secret there is a throwaway test value). Its time zone was set mid-morning so "today" has activity. |
| Map tiles / address search | Code calls OpenStreetMap; unreachable from the build sandbox, so tiles were blank in screenshots. Point, circle and coordinates work without tiles. |
| Production | Not live. Needs a Supabase project (Mumbai), both migrations run, and the two build variables. |

## Checks before Phase 3 (19 Nov 2026)
- **Time zone per company:** `companies.timezone` (validated against PostgreSQL's zone list, default
  **Asia/Kolkata**). Every date/time rule uses `company_tz(c)`, `local_today(c)`, `at_local(c, d, t)`.
  Admin changes it in Settings → Locations & GPS → Company rules. The demo no longer uses Pacific/Kiritimati.
- **Multi-tenancy** (`0003_multi_tenant.sql`): `companies` replaces `organization`; `company_id` on locations,
  departments, designations, employees, shifts, holidays and audit_log; employee-keyed tables (events,
  rosters, corrections, exceptions, coordinates) reach the company through the employee. Every policy is
  scoped by `my_company()`; `check_company_refs` refuses links to another company's office, shift,
  department, manager or designation; `company_id` cannot be changed after insert. Anonymous visitors can
  only read a company's public branding (`company_brand(slug)`), used by `/login?company=slug`.
  `create_company()` is owner-only. Proved by `tenancy_test.sql` (two companies, every table and function).
- **Permissions and audit review:** sensitive changes are checked by triggers, not just the UI (roles Admin-only,
  no self-role/self-deactivate, HR cannot change Admin/HR access, company rules Admin-only, last Admin kept).
  Audit triggers on companies, employees, departments, designations, locations, shifts, holidays, roster
  and shift patterns/days, remote exceptions; correction decisions logged explicitly. Each entry records who
  (`actor_employee`), when, before and after. HR/Admin read it in Settings → Activity log.
- **Deployment requirements** for Supabase Auth and maps/address search: `docs/DEPLOYMENT.md`.

## Phase 3 — employees and departments (done, awaiting review)
Database `supabase/migrations/0004_employees.sql` (no tables duplicated; `employees` and `departments` extended):
- Employees are records first: own id, `user_id` linked when someone signs in with the same **confirmed**
  e-mail. E-mail unique across the system. Fields added: phone, designation, employment status
  (probation / confirmed / contract / intern / notice period / exited), exit date, updated time.
  Already there: joining date, department, reporting manager, assigned office, default shift, role, active.
- **Employee IDs** `E0001…` per company, automatic, or a custom code (upper-cased, unique in the company).
- **Designations** table (per company); departments gain head and description; departments are switched
  off, never deleted.
- Rules in the database: only Admin assigns HR/Admin/Manager roles (HR can add employees only); nobody
  changes their own role or deactivates themselves; reporting lines cannot loop or point at inactive people;
  "Exited" switches access off and sets the exit date; the last active Admin cannot be removed.
- `my_profile()` for employees; `people_directory()` for pickers (names from live data, company only).
- Screens: **Employees** (search by name/e-mail/ID/phone, filters for department, designation, office,
  employment, role, access; pages of 25; table on desktop, cards on phones), **Profile** (work details,
  sign-in status, direct reports, last 14 days attendance, change history), **Add/Edit** form, **Change role**
  (Admin), **Deactivate/Reactivate** with confirmation; Managers see their team read-only; employees see
  **My profile**. **Departments** (Departments | Designations tabs). **Settings → Activity log**.
- Attendance, GPS, corrections and roster unchanged in behaviour; re-tested on the new schema.
- Tests at Phase 3 review: 174 database checks, 24 app checks (see the verification pass below for current counts).

## Phase 3 verification pass (19 Nov 2026, before merging to main)
Migration `0005_verification.sql`, tests `supabase/tests/verification_test.sql` (75 checks) and the real sign-in
check `supabase/authcheck` (29 browser checks against the real Supabase Auth server).
- **Sign-in:** "Create your login" on `/login` (sign-up for people HR added), confirmation e-mail, resend,
  expired-link message, password reset (signs out other devices), sign-out, session renewal, clear messages for
  switched-off / not-linked logins (`my_account_status()`). Linking only by confirmed work e-mail; never to a
  switched-off record or twice; follows login e-mail changes; links a person who confirmed before HR added
  them. Optional Auth hook `hook_before_user_created` lets only known work e-mails create a login.
- **Bug found and fixed:** adding an employee from the app failed with "You don't have permission" (the read
  policy looked the new row up again inside the same request). The Phase 3 screenshots only opened the form, so
  this wasn't caught; the real sign-in check found it. The rule is now written on the row itself.
- **Audit log:** who/when/company/source filled in by the database; append-only (no grants, and a trigger
  refuses update/delete/truncate even from the SQL editor); `source` = app (signed-in person) / system
  (sign-in linking, setup) / seed (sample data — only honoured for scripts run directly on the database, never
  through the API). Activity log shows "Sample data" and "Automatic" badges and a "Who" filter.
- **Exit:** exit date in the company's time zone; "Exited" can't have a future date (use Notice period with the
  last day); access ends automatically after the last working day; can't reactivate while Exited; rejoining
  clears the exit date and keeps the same login and roster; days after leaving aren't counted as absent;
  nobody can mark themselves exited; HR can't exit an Admin/HR.
- **Departments, designations, offices, shifts:** switched-off ones can't be newly assigned; people already
  assigned keep them (history stays right); department heads must be active.
- **Multi-tenant:** re-checked employees, departments, designations, audit log and company settings across
  two companies (moving records, creating in the other company, reading by company id, editing by id).
- **Employee Documents:** assessed, not built — `docs/EMPLOYEE-DOCUMENTS.md` (separate phase).
- Requirements still open for going live: `docs/DEPLOYMENT.md`.

### Known limits of Phase 3
- Not on a real Supabase project yet; hosted Auth settings, SMTP and invitations untested there.
- No "Send invite" e-mail from the app (needs an Edge Function — see DEPLOYMENT.md); people create their own
  login with the work e-mail HR entered.
- Attendance Register moved to Phase 4 with Leave and Reports (not in the Phase 3 brief).
- No bulk import (CSV) of employees yet. No Employee Documents yet.

### What is real and what is not (Phase 3 review)
Review screenshots: real app, real local PostgreSQL + PostgREST with row level security, signed test tokens
instead of Supabase Auth, sample companies (Acme Industries, Beta Logistics), offline map tiles. Sign-in
screenshots: real Supabase Auth server, real PostgREST, local mail catcher, fresh database.

## Phase 4 — leave and attendance register (done, awaiting full-system review)
Migration `0006_leave_register_reports.sql` (shared with Phase 5), tests `supabase/tests/leave_reports_test.sql`.
- **Leave types** per company (defaults Casual 12, Sick 8, Earned 15, Unpaid no limit; new companies get them
  automatically): yearly days, paid/unpaid, approval needed or automatic, half days allowed, how far back people
  may apply. HR/Admin manage them; never deleted.
- **Requests** only through checked functions: `apply_leave` (days counted by the server from the person's roster
  and holidays; no overlap; no full day where they already checked in; enough balance; within the leave year;
  not before joining or after the last day; backdating limit), `decide_leave` (their manager or HR; never your
  own; reject needs a reason; balance re-checked), `cancel_leave` (own pending, own approved before it starts,
  HR any), `adjust_leave` (HR, opening balances / carry-over, not their own). HR can **record leave** for
  someone (approved at once, marked "Recorded by HR"). `leave_preview` shows days, balance and conflicts before
  submitting. Leave year start month is a company setting.
- **Leave in attendance:** an approved leave day shows as **On leave** (not absent) in history, register, dashboard
  and reports; check-in on a full day of leave is refused with a message; My Attendance shows the leave.
- **Screens:** Leave Management → My Leaves (balance + requests), Team Requests / Requests (approve, reject with
  reason, cancel, Record leave), Leave Balance (any visible person; HR adjustments), Leave Calendar (month grid +
  table), Leave Types (HR/Admin). Dashboard: **On leave** KPI and "Leave today" with requests to decide.
  Employee profile and My profile show balance and recent leave.
- **Attendance Register:** Daily, Monthly (grid with letters P/L/A/LV/H/O, totals) and Employee detail views;
  filters for department, employee, shift and status (remembered on the device); sortable columns; paging;
  **Export CSV** of exactly what the view shows (same database function, same scope). Managers see their team,
  HR/Admin everyone; employees use My Attendance → History.

## Phase 5 — reports, analytics, roles, settings (done, awaiting full-system review)
- `report_days` (one scope for register, reports and exports, ≤ 93 days), `report_people`, `report_trend`.
- **Reports:** Summary (attendance rate on due days only, average hours per completed day, late arrivals, early
  departures, absenteeism, overtime, half days, leave), Employee-wise, Department-wise, Late arrivals, Overtime,
  Leave, Daily. Filters: period presets or custom range, department, employee, shift. **Export CSV** per report
  and **Print / PDF** (print layout hides the app shell). CSV cells can't start a spreadsheet formula.
- **Analytics:** attendance trend, working-hours trend, status distribution, department comparison — each with a
  text summary and "Show as table".
- **Roles & Permissions (Admin):** the role matrix from `permissions.ts` (enforced again by the database) and
  **User access**: everyone's role, access on/off, login linked / e-mail confirmed, last sign-in (`user_access()`,
  Admin only). Role changes stay on the profile.
- **Settings → General** (Admin edits, HR reads): company name, app name, logo, accent colours, date format,
  time zone (edited in Attendance rules), **half-day rule** (minimum hours for a full day, used in reports) and
  **leave year start**. **Settings → Access:** user access + role matrix.
- Speed: day calculations are now made once per person-day (`(f()).*` was calling them once per column):
  register ~13× faster, dashboard ~5× faster.

## Phase 6 — QA (19 Nov 2026)
- `npm run test:db` **308** database checks (6 suites); `npm run check` **35** app checks + type-check + lint;
  production build; real sign-in check **29/29** against Supabase Auth with migrations 0001–0006.
- Every screen captured with the real app and database in dark, light and phone layouts; no console errors.

### Known limits after Phase 6
- Not on a real Supabase project yet (see `docs/DEPLOYMENT.md`); invitations, SMTP and map provider pending.
- Reports and the register calculate days live: about 1 ms per person-day locally (100 people × 31 days ≈ 3 s).
  Larger companies will need a nightly summary table — a later change.
- Excel export is CSV (opens in Excel); PDF is the browser's print-to-PDF. No scheduled/e-mailed reports.
- Leave: no accrual per month, no carry-forward rules (HR adjusts balances), no attachments (needs the private
  storage planned in `docs/EMPLOYEE-DOCUMENTS.md`), no notifications/e-mails on decisions.
- Shift templates per department and bulk shift assignment by group are not built (per person + weekly pattern).
- No Help guide inside the app yet (studio-crm has one; worth adding before go-live).
- Employee Documents: planned, not built.

## Stabilisation / production-readiness pass (19 Nov 2026, branch phase-4-5, not merged)
No redesign, no new modules. Added: **employee invitations** (0007; see DEPLOYMENT.md §3) — the one item asked
for that didn't exist. Hardening (0008): time-zone lookups only answer for the caller's own company; weekly
roster/shift calls naming people outside the caller's HR scope now fail instead of silently doing nothing.
Fixed: pages scrolled sideways on phones (screen-reader labels inside scroll areas escaped them).
New checks: `supabase/tests/invitations_test.sql`, `supabase/tests/security_matrix_test.sql` (catalog rules +
every table and callable function across roles and companies), `e2e/regression.py` (browser: GPS cases, HR
workflows, exports, print, 208 screen loads), `supabase/perf/` (100/300/600 people). Status per feature:
`docs/STATUS.md`; performance: `docs/PERFORMANCE.md`.
Results: 356 database checks, 35 app checks, 36 real sign-in checks, 26 browser regression checks, all passing.

## Pilot 01 preparation (19 Nov 2026, documents only — nothing deployed)
Approved: a controlled pilot (one company, ≤100 people, 2–4 weeks, parallel running for 2 weeks). Added the
runbook in `docs/pilot/` (deployment checklist, environment guide, test checklist, known limitations, rollback,
recommendation) and `supabase/deploy/` (`verify_hosted.sql`, `create_pilot_company.sql`, both tested locally).
Decisions: no change to the reporting architecture for the pilot; the daily summary table
(`docs/requirements/DAILY-SUMMARY.md`) is required before companies above about 150 people; Supabase's statement
timeout is never raised as a workaround; the app uses only the URL and the publishable key — no secret key.
`phase-4-5` is not merged into `main` until the hosted checks pass. Correction: there are 21 tables (an earlier
report said 22).
Next: owner's go-ahead → hosted setup (checklist A–F) → pilot.

## Pilot 01 safety pass (19 Nov 2026, documents + one defect fix — nothing deployed)
Restore scenarios separated (whole-database backup/PITR restores `auth` too; a `public` dump never restores
logins; never `pg_restore --clean` over live) with `check_auth_links.sql` / `relink_logins.sql`; key incident
response (publishable key is public by design; secret/service_role, database password and JWT signing key are the
critical ones; session ending by SQL, no secret key); company retention and deletion (`07-DATA-RETENTION.md`,
`delete_company.sql` with dry run and an other-companies-unchanged check); map/address search separated from the
server-side office check. New checks: `supabase/authcheck/invite_edges.py` (26), `supabase/tests/relink_test.sql`,
3 browser checks. Defect found and fixed: a login confirmed while access was off never linked —
`0009_link_on_reactivation.sql`. Status per item: `docs/pilot/STATUS-LEGEND.md`.

## Biometric integration — Phase B1 (19 Nov 2026, documents only, branch `feature/biometric-b1`)
Owner's spec "AttendOS – Biometric Integration Platform v1.0". B1 audit and proposed architecture in
`docs/biometric/` (audit, architecture, schema/migration plan 0010–0013, adapter contract, Sync Agent, security,
hardware compatibility research, test plan, status). Key proposals: gateway as key-checked database functions (no
server, no secret key); Sync Agent on the company LAN; biometric punches become `attendance_events` rows
(`source = 'biometric'`) so the existing engine is unchanged; first-in/last-out direction rule; 5-minute app/machine
reconciliation. Nothing implemented; awaiting owner decisions D1–D9.
B1 revision 2 (20 Nov 2026, documents only): .NET 10 LTS agent with isolated legacy SDK host; device direction
where reliable, else controlled first-in/last-out with no checkout without evidence; stable slot projection updated in
place, corrected slots locked; dedupe by event ID → record sequence → fingerprint with occurrence; D1–D8 accepted
as planning defaults (owner sign-off pending),
D9 and six detail questions open (docs/biometric/BIOMETRIC_SYSTEM_ARCHITECTURE.md §11).
B1 revision 3 (20 Nov 2026, documents only): provisional check-outs are display-only raw-punch roles, never attendance
rows, finalised at day close with no engine change; local push receiver authentication/validation rules; Sync Agent
queue encrypted with SQLCipher (official edition) and separate DPAPI-protected secrets; decision wording corrected to
"recommended defaults accepted for planning; final owner sign-off pending".

## Biometric Phase B2 — device management UI on demonstration data (20 Nov 2026)
Configuration → Biometric Devices (`/biometric`, Admin + HR, new capability `biometric`): overview, devices, add-device
wizard, device detail, employee mapping, sync activity, review queue. All data is local mock state
(`src/lib/biometric-mock.ts`) except people and offices, which are read-only real records when connected. No
migrations, functions, gateway, agent or device connections. Details: docs/biometric/BIOMETRIC_B2_DEVICE_UI.md.
Review corrections (20 Nov 2026): device-specific code mapping by default with effective dates and attribution by punch
time; company-wide codes Admin-only with confirmation; conflicts explained before saving; raw punches frozen, decisions
append-only with reasons; device configuration Admin-only; roles enforced in the reducer (`assertAllowed`), new
capabilities `manageBiometricDevices`, `mapBiometricCodes`, `mapBiometricCompanyWide`, `reviewBiometric`,
`retryBiometricSync`; scrollable tab bar on phones. Final verification: mapping changes can no longer silently
reassign already processed punches (blocked before saving); sign-off script `e2e/biometric_b2_signoff.py`.
B2 approved. B3.1 (20 Nov 2026): database audit and design only — docs/biometric/BIOMETRIC_B3_1_DB_DESIGN.md;
no migration written. B3.2 (20 Nov 2026): migration 0010_biometric_core written and tested LOCALLY only (11 tables,
RLS, column-limited raw payload, immutable raw events, effective-dated mappings, agent credentials, Admin/HR functions);
not run on any hosted project. Revision 3 (SQL review): offsets ≤ ±14:00, error records immutable except retries/resolution,
review actions = implemented decisions, code-lock protocol for mapping vs processing. Future migrations start at 0011.
B3.2 approved for local development (20 Nov 2026; not for hosted). B3.3 (20 Nov 2026): migration 0011_biometric_gateway
written and tested locally — anon biometric_ingest/biometric_heartbeat (key in body, POST only, generic refusals, size
caps, replay, dedupe, timestamp validation, ownership, throttle, shared code locks); no attendance projection.
Not run on any hosted project. Future migrations start at 0012. Awaiting owner review before B3.4 (projection).
B3.3 approved for local development (20 Nov 2026; B3.3 report r5.1 corrects the test figures to 633/79/18, no code
changed). B3.4 (20 Nov 2026): **design only** for migration 0012 (attendance projection) —
docs/biometric/BIOMETRIC_B3_4_PROJECTION_DESIGN.md: per employee-day projection by a pg_cron procedure under the
punch lock (7), stable slot rows with raw-punch links, provisional check-out kept off the register until day close,
gate/holds/review routing, correction lock wrapper, Biometric/Imported labels. Nothing implemented; no existing
function changed. Revision 2 (20 Nov 2026, owner review): HR acceptance never bypasses session safety (new status
`correction_needed`, reachable only through an approved correction), source-value preflight that stops 0012 without
changes, provisional time shown separately from final hours, explicit device-direction transition rules and tests,
owner decisions Q1–Q10 applied (pg_cron later under separate approval; per-punch acceptance; CSV Source column; Admin
shift-gap warning). Revision 3 (20 Nov 2026): held punches re-evaluated at any age on a backoff in a separate
bounded queue budget; a hold released after the 2-day window needs a new individual HR acceptance; company-local dates;
null-safe authentication gate. Revision 4 (20 Nov 2026): held punches that are not due are never touched when
another punch brings their day in; each employee-day call is limited to 200 writes with continuation marks, and the
queue has run-level write budgets. Revision 5 (20 Nov 2026): the guard re-validates the whole attribution tuple
(time, raw punch, device, import batch, device office) against the raw punch on any change; write budgets are strict
(no lower clamp, one write reserved for continuation, slot step all-or-nothing, fewer than 6 writes → day deferred);
a failed call costs one error record. Revision 6 (20 Nov 2026): the guard refuses any change of an attendance
row's source (web/correction can never become biometric/import, nor the reverse). Revision 6 approved for LOCAL
implementation (20 Nov 2026). **B3.4 implemented locally:** `supabase/migrations/0012_biometric_projection.sql`
(projection, guard, held/queue procedure, correction wrapper, verification label, read functions) with
`biometric_projection_test.sql` (210 checks), `preflight_test.sh`, `concurrency/projection_proof.sh`,
`e2e/biometric_projection_http.py`; deletion script reordered; read-only hosted checks extended. Full database run 843
checks. Not run on any hosted project; pg_cron not installed; projection off for every real company; the UI items
(provisional display, labels, CSV Source column) are NOT built yet — projection must stay off until they are.
Report: docs/biometric/BIOMETRIC_B3_4_IMPLEMENTATION_REPORT.md. **Final review (21 Nov 2026):** a delayed device-mode
IN on a finished day is now counted only together with the OUT that closes it (decided as one unit by the OUT's own
rules), otherwise it is correction_needed; re-presses inside a counted pair stay extra on every run. New test group R
(16), proofs 9a/9b; report §11. **Pair-selection review (21 Nov 2026):** the punch that closes a delayed IN is
looked for in raw time order across every state, so a flagged/held/duplicate/correction_needed punch in between is never
jumped over (the IN goes to HR); punches HR dismissed or confirmed as duplicates are passed over. Test group RP (13),
proof 9c; full database run 872 checks; report §12. **Owner decision 21 Nov 2026: this pair-selection policy is
approved** (HR-resolved punches passed over; unresolved/ambiguous ones block; a correction_needed IN is never
re-paired automatically) — design §13. B3.4 database work is complete locally; nothing hosted.

**B4 — application UI (21 Nov 2026, local only):** source labels Web / Biometric / Imported / Correction in Today,
History, Register, late/overtime reports and verification history; biometric records never shown as GPS-verified;
day timeline (`day_events`); provisional check-out shown apart from final hours (engine unchanged); CSV Source column
(last column, existing columns unchanged); Biometric Devices module on the company's real records with every change
through the checked database functions (preview keeps the B2 demonstration). No new migration. Tests: browser B4 60/60,
app checks 64, regression 29/29, database 872, HTTP 18 + 17. Local demo data: `supabase/demo/biometric_demo.sql`.
Report: docs/biometric/BIOMETRIC_B4_UI_REPORT.md. Not deployed; needs the hosted migrations (separate approval) first.
Accessibility polish (21 Nov 2026): source badges meet WCAG AA in both themes (5.83–8.96:1) with a marker shape per
source; status badges unchanged; B4 browser 61/61, app checks 66/66.

**B5 — Local Sync Agent design (21 Nov 2026, design only):** architecture and implementation plan for the Windows
agent (.NET 10 Windows Service, x86 vendor-SDK host, SQLCipher queue with DPAPI keys, outbound HTTPS only, LAN-bound
push receiver, mock adapters first). Written from the 0010–0012 code, with a table of where the B1 agent documents
differ (batch ≤ 200 events / 256 KB, heartbeat stores only version + reachability + drift, no agent self-rotation, push
punches always flagged). Milestones M0–M10, failure scenarios, STRIDE threat model, API contract, compatibility matrix
(nothing hardware-verified) and 21 open decisions: docs/biometric/BIOMETRIC_B5_SYNC_AGENT_DESIGN.md. No code, migration
or hosted change. **Awaiting owner review and separate implementation authorisation.**

**B5 revision 2 — eSSL first (21 Nov 2026, design only):** owner decision: eSSL is the first manufacturer (model and
firmware unknown). docs/biometric/BIOMETRIC_B5_ESSL_FIRST_DESIGN.md: eSSL SDK pull, ADMS push and ePushServer
research with sources; K30 Pro / X990 as research examples (nothing hardware-verified); direct integration, no eSSL
server software; event normalization (user codes stay text, original time never altered); new rule from the gateway's
conflict check: the payload holds only device-produced values (`essl/1`), never agent metadata; offline/recovery
matrix; mock eSSL test plan T1–T15; purchase checklist; milestones M0–M12; decisions E1–E12. No code or migration.

**B5 revision 3 — X2008 + offline DAT import (21 Nov 2026, design only):** reference machine eSSL X2008 recorded from
its own info screen (ZMM210_TFT, firmware 8.0.4.2-20180530, Push Service 2.0.34; serial/MAC withheld); every
communication capability marked unverified; third-party X2008 evidence is for other firmware. New third path
`essl.dat_import` (USB export → original .dat → Admin upload → import staging only; no raw events, projection or
register rows; original bytes, row order and raw strings kept; duplicates labelled, never removed). DAT format pending
inspection of an original file (none supplied yet). Trust limits per path; roadmap now M1 DAT format → M2 DAT import
(migration 0013, separate approval) → agent milestones; decisions R1–R10.
docs/biometric/BIOMETRIC_B5_REV3_DESIGN.md. No code or migration.

**B5 revision 4 — DAT import readiness (21 Nov 2026, design only):** owner accepted the three-path direction. Revision 4
makes the DAT path buildable: upload/recovery state machine (resumable 256 KiB chunks with per-chunk and final SHA-256,
token take-over, lazy expiry without pg_cron, incomplete batches never reviewable); file limits (16 MiB, 200,000 rows,
512-byte lines, 16 fields, UTF-8, binary/encrypted refused, whole-file refusal leaves nothing behind); time handling
(original string kept, declared zone per batch, separate instant, gap/overlap never guessed); mapping resolution
(exact string, source device first, then company-wide, half-open validity at the punch instant; only `10` → WR198
known); duplicate labels across DAT, SDK and ADMS without discarding rows; retention (file + rows 90 days, metadata
3 years, audit for ever with no personal data — the generic audit trigger is not used because audit_log can never
be cleaned); 50 tests. Found: historical DAT rows can't become raw events under the 31-day guard (R13).
docs/biometric/BIOMETRIC_B5_REV4_DAT_IMPORT.md. Migration 0013 not written.

**X2008 DAT format recorded (21 Nov 2026, documentation only):** owner inspected the supplied export (151 records,
6,191 bytes, UTF-8 without BOM, TAB, CRLF with final newline, 6 fields, field 1 right-aligned to 9 characters with
leading spaces, `YYYY-MM-DD HH:MM:SS`, 2–21 Nov 2026, 17 codes, no duplicates). docs/biometric/BIOMETRIC_DAT_FORMAT.md:
format profile `essl.x2008.attlog/1`, code extraction (remove leading spaces only; never numeric), timestamp rule,
fields 3–6 unknown and never interpreted, parser tests P1–P23, real-file check (local only), open questions Q1–Q10
(the device showed 31,207 records; the export has 151 — not treated as full history). 22 synthetic fixtures in
tests/fixtures/dat (no real data; real exports ignored by .gitignore). Code `10` → WR198 remains the only mapping.

**HR eSSL report correlation (23 Nov 2026, documentation only):** the eSSL "Daily Attendance Report (Summary Report)"
(printed 23 Nov 2026) is recorded as a reference artifact, not raw data, and not committed (other employees' data).
For code 10 the report's three InTimes match DAT lines 24, 95 and 150 to the minute. DAT line 151 (21 Nov 15:53:01,
3 min 45 s after line 150) is not shown; the report gives OutTime blank, "Absent (No OutPunch)". Recorded without
inferring eSSL's reason: raw record count is not an IN/OUT rule; pairing stays outside the DAT parser.
docs/biometric/BIOMETRIC_HR_REPORT_CORRELATION.md (evidence E1–E5 needed, questions Q1–Q9).

**B5 DAT import Stages 1–2 (23 Nov 2026, local implementation, awaiting owner review):** migration 0013 (local only)
adds the versioned reader `essl.x2008.attlog/1` and import staging: resumable hashed upload, byte-exact file kept,
every line kept as a row in file order (raw text, all six fields as text, original timestamp string, instant in the
declared zone; malformed, blank and duplicate lines kept with a status), five duplicate labels (no row removed),
mapping preview computed on read (device first, then company; half-open validity). Admin-only tab **Biometric → File
import** (`importBiometricFiles`). Never writes raw events, attendance or register rows, never projects, never infers
IN/OUT or reads fields 3–6. Real export (151 lines): 151 ok/new, 17 codes; code 10 → WR198 on lines 24, 95, 150, 151.
Real file never committed (gitignore + hash guard test). Tests: check 81+1 skipped, test:db 990 ok, DAT e2e 48/48.
90-day purge not built (needs a scheduler). Open: mapping start date for 10 (assumed 2026-11-01 locally), file name
holds the device serial. docs/biometric/BIOMETRIC_B5_DAT_IMPORT_REPORT.md.

**B5 DAT import technical review (23 Nov 2026, review only, awaiting owner decision):** independent review of
`e27ef9d`. Isolation, Admin-only functions, locked staging tables, upload integrity, audit minimisation and "no
attendance side effects" hold (catalog, code and test evidence). Found: F2 (High) classification times out at the
8 s limit for ≈ 32,000-line files when table statistics are stale (planner re-evaluates the label subquery per row);
F1 HR can read the batch table directly (0010 grant, now with file name / token hash); F4 X2008 profile accepted for
any eSSL device; P1 one real record of another employee in the format doc; F5 open-batch limit race; F3 no
"continue processing"; F6 decode before size check. Recommendations for file name (generated), permissions (HR
prepares, Admin approves), test-only mapping for 10 → WR198, retention (30 days unreviewed, 90 days reviewed, lazy
expiry). No code or migration changed. docs/biometric/BIOMETRIC_B5_DAT_IMPORT_TECH_REVIEW.md.

**B5 DAT import correction pass (23 Nov 2026, local, awaiting owner approval):** owner-approved corrections to 0013
(never run hosted, so corrected in place). HR and Admin prepare imports (upload, process, Continue processing,
cancel own, view); Admin alone marks reviewed, deletes, downloads, cancels others' uploads and assigns a device's file
format; mapping rights unchanged. F1 batch table no longer readable by any API role; F2 labels materialised + ANALYZE
after parsing (32,000 and 200,000 lines, autovacuum on/off, every call < 8 s); F4 per-device Admin-assigned profile,
X2008 only, model/firmware on the batch; F5 company advisory lock (4 simultaneous starts → 3 open); F6 base64 length
checked before decoding; server-generated batch names (uploaded name never sent/stored/shown); retention 30 days
unreviewed / 90 days reviewed / 3-year tombstone with bounded lazy deletion (no scheduler). 10 → WR198 is a test
assumption only. Format doc example replaced with a synthetic line (history not rewritten). Tests: check 84+1 skip,
test:db 1,025 ok, scale suite 12/12, DAT e2e 97/97. docs/biometric/BIOMETRIC_B5_DAT_IMPORT_CORRECTION_PASS.md.
