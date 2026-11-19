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
- Tests: `npm run test:db` 174 database checks (attendance, refinement, tenancy, employees);
  `npm run check` 24 app checks.

### Known limits of Phase 3
- No "Send invite" e-mail from the app (needs an Edge Function — see DEPLOYMENT.md); the person signs up
  with the work e-mail HR entered.
- Attendance Register moved to Phase 4 with Leave and Reports (not in the Phase 3 brief).
- No bulk import (CSV) of employees yet.

### What is real and what is not (Phase 3 review)
Same as the refinement pass: real app, real local PostgreSQL + PostgREST with row level security, signed
test tokens instead of Supabase Auth, sample companies (Acme Industries, Beta Logistics), offline map tiles.
Not deployed to a Supabase project yet.

## Next — Phase 4 (do not start until Phase 3 is approved)
Leave management, Attendance Register (daily/monthly, export within scope), shift/late rules polish.
