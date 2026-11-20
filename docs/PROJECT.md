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
