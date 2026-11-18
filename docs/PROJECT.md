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
- **One company per copy.** Each company gets its own copy (own Supabase project, own address) with its
  own name, logo and accent colour in `src/lib/brand.ts`, so it feels like their own system.
  Status colours never change between companies.
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

### Setting up a company copy
1. Create a Supabase project in the Mumbai region; run `0001_attendance_core.sql` in the SQL editor.
2. Put the project URL and anon key in Cloudflare build variables (see `.env.example`).
3. Set `src/lib/brand.ts` and the logo; set the organization time zone if not Asia/Kolkata.
4. The first person to sign up becomes Admin. Until the Employees module (Phase 3), add people with
   Supabase → Authentication → Invite user; they appear in the roster after first sign-in.

### Known limits of Phase 2
- No in-app employee onboarding, managers or departments yet (Phase 3) — set `manager_id` in the
  database if needed. No attendance corrections yet (Phase 3, with reasons and audit).
- Shift timings / late rules / overnight shifts come in Phase 4; sessions are not tied to a shift yet.
- Without the two build variables the app runs as the labelled design preview.

## Next — Phase 3 (workforce)
Employees (invite, profile, manager, department, home office, deactivate), departments,
Attendance Register (daily/monthly, filters, export within scope) and HR corrections with audit.
