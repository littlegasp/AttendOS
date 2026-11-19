# AttendOS — going live: what is verified and what is still needed

**AttendOS is not production-ready yet.** Nothing has run on a real Supabase project. What has been verified,
and how:

| Layer | Verified with | Not yet verified |
|---|---|---|
| Database rules (RLS, triggers, functions) | PostgreSQL 16, `npm run test:db` (all migrations, ~250 checks) | Supabase's Postgres build and its built-in roles |
| REST API | PostgREST 12 (the layer Supabase uses) | Supabase's API gateway in front of it |
| Sign-in | **Real Supabase Auth server** (`supabase/auth` v2.198.0 release binary) + real PostgREST, mail caught locally — `supabase/authcheck`, 29 browser checks | Hosted Auth settings, real e-mail delivery (SMTP), rate limits, custom domain |
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
   `0003_multi_tenant.sql`, `0004_employees.sql`, `0005_verification.sql`. Later changes come as new numbered files.
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

## 3. Invitation e-mails (not built)
Today: HR adds the person → tells them to open `https://<site>/login?company=<slug>` → "First time here? Create
your login" with the same work e-mail → confirm the e-mail. Verified locally end to end.

A "Send invite" button needs a **Supabase Edge Function** (server side, holds the service-role key) that:
checks the caller is HR/Admin of the employee's company (verify their JWT, call `my_role()`), then calls
`auth.admin.inviteUserByEmail(work_email, { redirectTo: https://<site>/reset-password })`, and logs the invite in
the audit log. The invite link confirms the address (so linking happens) and lets the person set a password.
Needs: the function, the "Invite user" e-mail template, the redirect URL above, and a test on the real project.

## 4. Maps and address search
Leaflet with **OpenStreetMap public tiles**; address search uses **Nominatim** from the browser.
- Keep the "© OpenStreetMap contributors" attribution (shown). Fine for a few HR users; for many companies use a
  tile provider with a key (MapTiler, Stadia, Thunderforest) or self-hosted tiles.
- Nominatim: at most about one request per second, identifiable traffic, **no type-ahead autocomplete**.
  AttendOS searches only when HR presses Search. For a multi-company service, plan a paid geocoder or self-host.
- If a Content-Security-Policy is added to `public/_headers`, allow those hosts in `img-src` / `connect-src`.
- Without tiles the screen still works (pin, radius and coordinates); check-in never uses maps or geocoding.

## 5. Before the first real company (checklist)
- [ ] Project in Mumbai, migrations 0001–0005 run, `create_company` done.
- [ ] Auth settings in section 2, hook enabled, custom SMTP, templates.
- [ ] Repeat `supabase/authcheck` by hand on the real project: sign-up refused for unknown e-mail, sign-up +
      confirm, resend, reset, sign-out, second device after reset, deactivate mid-session, reactivate.
- [ ] Two companies, four roles each: repeat the isolation checks by hand (directory, departments, audit log).
- [ ] `public/_headers` served (geolocation for this site only).
- [ ] Decide invitation approach (section 3) and map/geocoder provider (section 4).
