# AttendOS — going live: what is verified and what is still needed

> **Pilot 01 runbook:** follow `docs/pilot/01-DEPLOYMENT-CHECKLIST.md` step by step (with
> `02-ENVIRONMENT.md`, `03-PILOT-TEST-CHECKLIST.md`, `04-KNOWN-LIMITATIONS.md`, `05-ROLLBACK.md`,
> `06-RECOMMENDATION.md`, `07-DATA-RETENTION.md`, `STATUS-LEGEND.md`). Scripts in `supabase/deploy/`:
> `verify_hosted.sql`, `check_auth_links.sql` (read-only), `create_pilot_company.sql`, `relink_logins.sql`,
> `delete_company.sql`. This page stays the background reference.

**AttendOS is not production-ready yet.** Nothing has run on a real Supabase project. What has been verified,
and how:

| Layer | Verified with | Not yet verified |
|---|---|---|
| Database rules (RLS, triggers, functions) | PostgreSQL 16, `npm run test:db` (all migrations, 360 checks incl. the security matrix) | Supabase's Postgres build and its built-in roles |
| REST API | PostgREST 12 (the layer Supabase uses) | Supabase's API gateway in front of it |
| Sign-in and invitations | **Real Supabase Auth server** (`supabase/auth` v2.198.0 release binary) + real PostgREST, mail caught locally — `supabase/authcheck`, 36 browser checks, plus 26 invitation edge cases (`invite_edges.py`) |
| App behaviour | `e2e/regression.py`: GPS cases, HR workflows, exports, print, 208 screen loads, map provider blocked — 29 checks | Hosted Auth settings, real e-mail delivery (SMTP), rate limits, custom domain |
| Review screenshots | Real app build + PostgREST + PostgreSQL with sample data and signed test tokens | — |

### The simulated-token limitation (review screenshots)
The Phase 2/3 review screenshots sign people in with a **test token signed by a local secret**, not through
Supabase Auth: the database still checks each person's role and company exactly as in production, but no
password, e-mail or session was involved. Since this verification pass, the sign-in flows themselves are
checked separately against the real Supabase Auth server (`supabase/authcheck`). The hosted project still has
to be checked once (section 5).

## 1. Supabase project (one for all companies)
1. Create **one** project in **Mumbai (ap-south-1)**. Row level security keeps companies apart.
2. SQL editor → run, in order, once each: `0001_attendance_core.sql`, `0002_refinement.sql`,
   `0003_multi_tenant.sql`, `0004_employees.sql`, `0005_verification.sql`, `0006_leave_register_reports.sql`, `0007_invitations.sql`, `0008_hardening.sql`, `0009_link_on_reactivation.sql`. Later changes come as new numbered files.
3. Create each company (owner only):
   `select public.create_company('Acme Industries', 'acme', 'Asia/Kolkata', 'owner@acme.in', 'Owner Name');`
4. Cloudflare build variables: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` (see `.env.example`).
   The service-role key never goes into the site.
5. Backups: check point-in-time recovery / daily backup retention on the plan.

## 2. Supabase Auth settings
Logins are linked to employee records **only by a confirmed work e-mail** (migration 0005):
- linked when the e-mail is confirmed, or when HR adds the person after they confirmed;
- never to a switched-off record, never to two records, one work e-mail = one person across all companies;
- if a login changes its e-mail away from the work e-mail, the link is removed (and logged); it comes back if
  the login returns to the work e-mail.

| Setting (Dashboard → Authentication) | Value | Why |
|---|---|---|
| Email provider | Enabled, **Confirm email ON** | Linking trusts the confirmed address. Off = anyone could claim a colleague's record. |
| Secure email change | ON | Changing a login's e-mail needs both addresses confirmed. |
| Hooks → **Before User Created** | Postgres function `public.hook_before_user_created` | Only work e-mails HR has added can create a login; others get "isn't set up in AttendOS yet". Grant: `grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;` (0005 does this when the role exists). Note: this tells a visitor whether an e-mail is registered — acceptable for work e-mails; leave the hook off if not. |
| Site URL | the company site, e.g. `https://attendos.example.com` | Base for e-mail links. |
| Redirect URLs | `https://<site>/login*`, `https://<site>/reset-password*` | Confirmation and reset return here. |
| Allow new users to sign up | ON (with the hook) | People create their own login on `/login` → "First time here? Create your login". |
| Minimum password length | 8 or more | Matches the app's checks. |
| JWT expiry | default 3600 s | See "sessions" below. |
| SMTP | **Custom SMTP** on the company's domain (SPF/DKIM/DMARC) | Supabase's built-in sender is for testing only and heavily rate-limited. |
| E-mail templates | Confirm signup, Reset password | Plain wording, company name; keep `{{ .ConfirmationURL }}`. |

**Sessions (verified locally):** sign-out ends the session in the browser and on the server; a new password signs
out every other device; another device's current token keeps working until it expires (up to the JWT expiry,
1 hour by default) and is then refused — but **deactivation or exit takes effect on the very next request**,
because the database checks the employee record each time, not the token.

## 3. Invitation e-mails (built — migration 0007)
HR opens the person's profile → **Send invite**. The database (`prepare_invitation`) checks that the caller is
HR/Admin of that company, the person is active, has no login yet and wasn't invited in the last 10 minutes (max 5
a day), records the invitation and returns the **work e-mail from the employee record**. The app then asks
Supabase Auth to e-mail a one-time sign-in link to that address (`signInWithOtp`, no service key needed).
Opening the link confirms the address → the login is linked to that employee (0005 rules) → the person lands on
`/reset-password?welcome=1` and chooses a password. The invitation shows as Sent / Not sent / Accepted on the
profile and in the activity log. Verified locally with the real Auth server.

Hosted settings it needs:
- Before User Created hook ON (section 2), so only HR-added work e-mails can create a login.
- Redirect URL `https://<site>/reset-password*` (already listed).
- E-mail templates: a new login receives **Confirm signup**; a login that already exists but isn't linked receives
  **Magic Link**. Word both as an invitation that also works for self sign-up, e.g. "You've been invited to
  {company} on AttendOS — open this link to confirm your work e-mail and set your password." Keep
  `{{ .ConfirmationURL }}`.
- Custom SMTP (section 2) — Supabase's built-in sender only delivers to project team addresses and is heavily
  rate-limited.
- Optional later: a branded server-side invite (Edge Function with `auth.admin.inviteUserByEmail`) if a separate
  "Invite user" template is wanted.

## 3b. Performance limits on hosted Supabase
Signed-in API calls have a default statement timeout of 8 seconds on Supabase. Monthly register/reports take
about 3 s at 100 people and 8 s at 300 here (`docs/PERFORMANCE.md`), so: pilot with up to ~100 people, and add
the daily summary table before larger companies. Do not just raise the timeout as the fix.

## 4. Maps and address search
Leaflet with **OpenStreetMap public tiles**; address search uses **Nominatim** from the browser.
- Keep the "© OpenStreetMap contributors" attribution (shown). Fine for a few HR users; for many companies use a
  tile provider with a key (MapTiler, Stadia, Thunderforest) or self-hosted tiles.
- Nominatim: at most about one request per second, identifiable traffic, **no type-ahead autocomplete**.
  AttendOS searches only when HR presses Search. For a multi-company service, plan a paid geocoder or self-host.
- If a Content-Security-Policy is added to `public/_headers`, allow those hosts in `img-src` / `connect-src`.
- Without tiles the screen still works (pin, radius and coordinates); check-in never uses maps or geocoding —
  the office check is computed by the database (tested with OpenStreetMap blocked; `docs/pilot/02-ENVIRONMENT.md` §7).

## 5. Before the first real company (checklist)
- [ ] Project in Mumbai, migrations 0001–0009 run, `create_company` done.
- [ ] Auth settings in section 2, hook enabled, custom SMTP, templates.
- [ ] Repeat `supabase/authcheck` by hand on the real project: sign-up refused for unknown e-mail, sign-up +
      confirm, resend, reset, sign-out, second device after reset, deactivate mid-session, reactivate.
- [ ] Two companies, four roles each: repeat the isolation checks by hand (directory, departments, audit log).
- [ ] `public/_headers` served (geolocation for this site only).
- [ ] Send a real invitation from the hosted app; confirm the e-mail arrives (Inbox, not Spam) and links correctly.
- [ ] Pilot on real phones (Android Chrome, iPhone Safari): permission prompt, accuracy indoors/outdoors, check-in inside/outside.
- [ ] Choose map/geocoder provider (section 4). Company size ≤ ~100 for the pilot (section 3b).
