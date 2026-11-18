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

## Next — Phase 2 (attendance core)
Supabase project, sign-in, organization/employee/attendance-event tables with RLS,
a server-side check-in function (server time, geofence distance, accuracy, no duplicate open session),
My Attendance screen with the GPS flow and every failure case from guide section 6.

### Open questions for Phase 2
- One organization or several (multi-tenant) from day one?
- Office coordinates/radius per location, or one office to start?
- Remote attendance policy: allowed for some people, or not in V1?
