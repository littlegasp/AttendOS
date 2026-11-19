# Pilot 01 — hosted deployment checklist (Supabase Mumbai + Cloudflare)

Code: branch `phase-4-5` (stabilisation commit `e702229` + these documents). **Nothing below has been done yet.**
Do the steps in order; tick each box and note who did it and when (keep this file as the deployment log).
Don't run any step against a live project without the owner's go-ahead.

> **Never run on the hosted project:** `supabase/tests/*` (they create a fake `auth` schema and would break
> Supabase Auth), `supabase/demo/*` (sample companies) and `supabase/perf/*` (synthetic data). Only the files
> listed in step B and the two scripts in `supabase/deploy/`.

## A. Accounts and project
- [ ] A1. Supabase organisation: every member uses MFA; only the owner and one backup person are Owners.
- [ ] A2. Create **one** project: region **South Asia (Mumbai) — ap-south-1**, plan **Pro** (Free projects pause when idle and have no restorable backups — not suitable for a pilot). Strong database password → stored in the owner's password manager only.
- [ ] A3. Note the project URL `https://<ref>.supabase.co` and the **publishable key** (`sb_publishable_…`, Project Settings → API Keys). Do not copy the secret key anywhere — AttendOS doesn't need it.
- [ ] A4. Backups: Pro daily backups are on; decide whether to add Point-in-Time Recovery for the pilot (recommended if the pilot company relies on it daily).

## B. Database migrations (0001 → 0008, each exactly once, in order)
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
| 5 | `0005_verification.sql` | Safe linking, Auth hook function, append-only audit, exit rules, switched-off references | |
| 6 | `0006_leave_register_reports.sql` | Leave, register, reports, settings, user access | |
| 7 | `0007_invitations.sql` | Employee invitations | |
| 8 | `0008_hardening.sql` | Own-company time zone only; roster calls refuse people outside HR scope | |

- [ ] B9. Run `supabase/deploy/verify_hosted.sql` (read-only). All rows `ok = true` except **9** until step C3 is done. Save the result.

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
- [ ] D3. Build and deploy `phase-4-5` (tag it `pilot-01-rc1` first). `npm run check` and `npm run build` must pass on that commit.
- [ ] D4. Confirm in the browser: `/login` loads over HTTPS; response headers include `Permissions-Policy: … geolocation=(self)`; the built `out/` folder contains no secret key: `grep -rEl 'sb_secret_[A-Za-z0-9_-]{10,}|c2VydmljZV9yb2xl' out/` must list nothing (a real secret key, or a legacy service_role token — the bare word `sb_secret_` appears in Supabase's library code and is fine).

## E. Pilot company
- [ ] E1. Edit the four values in `supabase/deploy/create_pilot_company.sql`, run it once in the SQL editor, check the printed row (company, slug, Asia/Kolkata, Admin record, 4 leave types), then let it commit.
- [ ] E2. The Admin opens `https://<site>/login?company=<slug>` → **First time here? Create your login** with exactly that e-mail → confirms the e-mail → lands on the Dashboard as Admin.
- [ ] E3. Admin: Settings → General (name, logo, date format, half-day rule, leave year), Locations & GPS (offices on the map, radius, accuracy limit, weekly offs), Shifts, Holidays, Departments/Designations, Leave Types.
- [ ] E4. Admin adds the HR person(s) with role HR and invites them; HR then adds and invites everyone else (03-PILOT-TEST-CHECKLIST.md).
- [ ] E5. Re-run `verify_hosted.sql`: all rows `true`.

## F. Go / no-go for day 1
- [ ] F1. Sections A–E done and logged.
- [ ] F2. 03-PILOT-TEST-CHECKLIST.md sections 1–4 passed on the hosted site.
- [ ] F3. Rollback rehearsed: the previous Cloudflare version is known; a manual database backup (`pg_dump` or dashboard backup) taken after E5.
- [ ] F4. Owner's written go-ahead recorded here: ____________________ (name / date)
