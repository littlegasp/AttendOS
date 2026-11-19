# Working on AttendOS

AttendOS is Aniket's personal attendance & workforce SaaS. It is **not** the company ERPNext
geofenced attendance system — never mix code, data or settings between the two.

**Start with `docs/PROJECT.md`** (phases, decisions, what is next) and the spec PDF
"AttendOS Complete UI/UX and Claude Implementation Guide". Update PROJECT.md in the same commit
when something it describes changes.

## Stack (same as studio-crm)
Next.js static export (`output: "export"`) + React + TypeScript, served by Cloudflare from `out/`.
From Phase 2: Supabase (Mumbai) for auth and data, with row level security and checked database
functions for anything that must be trusted (server time, geofence, duplicates, approvals).

## Rules
- Build one phase at a time and stop for review before the next.
- Never replace working functionality just to match the new design.
- Components use the semantic tokens in `src/app/globals.css` only (`--color-*`); no hex in components.
- Dark and light themes must both work; one theme mechanism only (`data-theme` + `attendos.theme`).
- Access is defined once in `src/lib/permissions.ts`. UI gates are convenience; the server enforces.
- No fake data in finished features. Placeholders say which phase builds them.
- GPS is sensitive: capture only during check-in/out, validate on the server, never track in the background.
- Keep `public/_headers` (geolocation allowed for this site only).
- **Multi-tenant (from migration 0003):** one Supabase project serves every company. Every table carries
  `company_id` (or reaches it through `employee_id`), and row level security keeps each company to its own
  rows. New tables must do the same: `company_id ... default public.my_company()`, policies through
  `my_company()` / `can_see()` / `hr_of()`, `check_company_refs` on every foreign key to company data,
  `freeze_company_id`, and an audit trigger if HR/Admin change it. Branding lives in `companies`, not code.
- Time is per company (`companies.timezone`, default Asia/Kolkata): use `local_today(company)` and
  `at_local(company, date, time)`, never the server's time zone.
- Employees are records first; a login is linked later by confirmed e-mail. Never key data on `auth.uid()`
  directly — use `my_employee_id()`.
- Deployment requirements (Auth settings, maps, address search): `docs/DEPLOYMENT.md`.

## Checks before pushing
`npm run check` (tsc + eslint + tests), `npm run test:db` when SQL changes (needs a local Postgres:
PGHOST/PGPORT/PGUSER), and `npm run build`. New SQL goes in a new numbered migration, never by editing
one that has been run on a company's database.
