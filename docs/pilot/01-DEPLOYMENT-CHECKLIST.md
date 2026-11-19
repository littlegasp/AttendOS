# Pilot 01 — hosted deployment checklist (Supabase Mumbai + Cloudflare)

Source: **application commit `6d47386`** on `phase-4-5` (front end as of `e702229`, migrations 0001–0009). This
deployment pack is in a later, documentation-only commit (06-RECOMMENDATION.md "Source").
**Status: PENDING — no step below has been done on a hosted project.** What has been tested locally is listed in
`STATUS-LEGEND.md`. Do the steps in order; tick each box and note who did it and when (keep this file as the
deployment log).

> **Approval gate.** Creating the hosted project, running migrations on it, creating the live pilot company,
> setting or changing any production credential, deploying to Cloudflare and merging `phase-4-5` into `main` each
> need the owner's explicit written approval first. Record it next to the step.

> **Never run on the hosted project:** `supabase/tests/*` (they create a fake `auth` schema and would break
> Supabase Auth), `supabase/demo/*` (sample companies) and `supabase/perf/*` (synthetic data). Only the files
> listed in step B and the scripts in `supabase/deploy/` (`verify_hosted.sql`, `check_auth_links.sql` and
> `create_pilot_company.sql` here; `relink_logins.sql` and `delete_company.sql` only as 05-ROLLBACK.md and
> 07-DATA-RETENTION.md describe).

## A. Accounts and project
- [ ] A1. Supabase organisation: every member uses MFA; only the owner and one backup person are Owners.
- [ ] A2. Create **one** project: region **South Asia (Mumbai) — ap-south-1**, plan **Pro** (Free projects pause when idle and have no restorable backups — not suitable for a pilot). Strong database password → stored in the owner's password manager only.
- [ ] A3. Note the project URL `https://<ref>.supabase.co` and the **publishable key** (`sb_publishable_…`, Project Settings → API Keys). Do not copy any secret key (`sb_secret_…`) or the legacy `service_role` key anywhere — AttendOS doesn't use them. If the project shows legacy keys, leave them unused; the app works with the publishable key alone (02-ENVIRONMENT.md §1).
- [ ] A4. Backups: Pro daily backups are on (kept 7 days on Pro). Decide on Point-in-Time Recovery (recommended for the pilot: restore to the minute instead of losing up to a day). Write down the retention window — 07-DATA-RETENTION.md uses it.
- [ ] A5. Rehearse a restore once, before real data: Database → Backups → **Restore to a new project** into a throwaway project, run `verify_hosted.sql` and `check_auth_links.sql` there, note how long it took, then delete that project (05-ROLLBACK.md §2).

## B. Database migrations (0001 → 0009, each exactly once, in order)
Run each file whole. Either paste it into **SQL Editor → New query → Run**, or from a laptop with `psql`:
`psql "<session-pooler connection string>" -v ON_ERROR_STOP=1 --single-transaction -f supabase/migrations/000N_….sql`
(use the Session pooler string if the network has no IPv6). If a file fails, stop — don't run the next one; fix and
re-run that file from a fresh project or restore (see 05-ROLLBACK.md).

| # | File | What it adds | Done (who / when) |
|---|---|---|---|
| 1 | `0001_attendance_core.sql` | Locations, employees, roster, check-in/out with GPS check, audit log, row level security | |
| 2 | `0002_refinement.sql` | Shifts, breaks, overnight shifts, late/early/overtime, corrections, history | |
| 3 | `0003_multi_tenant.sql` | Companies, company isolation, per-company time zone, login linking | |
| 4 | `0004_employees.sql` | Employee IDs, designations, departments, roles, exit, people pickers | |
| 5 | `0005_verification.sql` | Safe linking, Auth hook function, append-only audit (in normal operation; see 07 §4 for company deletion), exit rules, switched-off references | |
| 6 | `0006_leave_register_reports.sql` | Leave, register, reports, settings, user access | |
| 7 | `0007_invitations.sql` | Employee invitations | |
| 8 | `0008_hardening.sql` | Own-company time zone only; roster calls refuse people outside HR scope | |
| 9 | `0009_link_on_reactivation.sql` | Defect fix: a login confirmed while access was off links when access is switched back on | |

- [ ] B10. Run `supabase/deploy/verify_hosted.sql` (read-only). All rows `ok = true` except **9** until step C3 is done. Save the result.

## C. Authentication (Dashboard → Authentication) — values in 02-ENVIRONMENT.md §2
- [ ] C1. URL Configuration: Site URL and the two redirect URLs.
- [ ] C2. Sign In / Providers → Email: enabled, **Confirm email ON**, **Secure email change ON**, minimum password length 8+, e-mail OTP/link expiry 86400 s (so invitations last a day).
- [ ] C3. Hooks → **Before User Created** → Postgres → `public.hook_before_user_created`. Re-run `verify_hosted.sql`: row 9 now `true`.
- [ ] C4. SMTP Settings → custom SMTP (02-ENVIRONMENT.md §3). Sender domain has SPF, DKIM and DMARC.
- [ ] C5. Emails → Templates: paste the four templates from 02-ENVIRONMENT.md §4.
- [ ] C6. Rate limits: e-mails per hour high enough for the pilot (e.g. 100); keep the other limits at defaults.
- [ ] C7. Do **not** change the database statement timeout (stays at Supabase's default).

## D. Front end (Cloudflare)
- [ ] D1. Cloudflare Worker `attendos` (static assets from `out/`, `wrangler.jsonc`), custom domain e.g. `attendance.<company-domain>` or `pilot01.<your-domain>` with HTTPS.
- [ ] D2. Build variables: exactly the two `NEXT_PUBLIC_*` values (02-ENVIRONMENT.md §1). Nothing else.
- [ ] D3. With the owner's approval, tag the application commit — `git tag pilot-01-rc1 6d4738643388ec8c8da302775f1f96ff0ce46415 && git push origin pilot-01-rc1` — and build and deploy **that tag** (not the branch head). `npm run check` and `npm run build` must pass on it.
- [ ] D4. Confirm in the browser: `/login` loads over HTTPS; response headers include `Permissions-Policy: … geolocation=(self)`; the built `out/` folder contains no secret key: `grep -rEl 'sb_secret_[A-Za-z0-9_-]{10,}|c2VydmljZV9yb2xl' out/` must list nothing (a real secret key, or a legacy service_role token — the bare word `sb_secret_` appears in Supabase's library code and is fine).

## E. Pilot company
- [ ] E1. Edit the four values in `supabase/deploy/create_pilot_company.sql`, run it once in the SQL editor, check the printed row (company, slug, Asia/Kolkata, Admin record, 4 leave types), then let it commit.
- [ ] E2. The Admin opens `https://<site>/login?company=<slug>` → **First time here? Create your login** with exactly that e-mail → confirms the e-mail → lands on the Dashboard as Admin.
- [ ] E3. Admin: Settings → General (name, logo, date format, half-day rule, leave year), Locations & GPS (offices on the map, radius, accuracy limit, weekly offs), Shifts, Holidays, Departments/Designations, Leave Types.
- [ ] E4. Admin adds the HR person(s) with role HR and invites them; HR then adds and invites everyone else (03-PILOT-TEST-CHECKLIST.md).
- [ ] E5. Re-run `verify_hosted.sql` (all rows `true`) and `check_auth_links.sql` (all rows `ok`).

## F. Go / no-go for day 1
- [ ] F1. Sections A–E done and logged.
- [ ] F2. 03-PILOT-TEST-CHECKLIST.md sections 1–4 passed on the hosted site.
- [ ] F3. Rollback ready: the previous Cloudflare version is known; restore rehearsed (A5); a database backup taken after E5 (dashboard backup or PITR point noted, plus a `pg_dump` of the `public` schema — 05-ROLLBACK.md §0).
- [ ] F4a. 07-DATA-RETENTION.md agreed in writing with the pilot company (how long data is kept, who may export, what happens at the end).
- [ ] F4. Owner's written go-ahead recorded here: ____________________ (name / date)
