# AttendOS — what is still needed to go live

Everything below is **not done yet**. The database and app were tested against a local PostgreSQL 16
with PostgREST 12 (the same REST layer Supabase uses). None of it has run on a real Supabase project.

## 1. Supabase project (one for all companies)
1. Create **one** Supabase project in the **Mumbai (ap-south-1)** region. Every company shares it;
   row level security keeps each company's rows separate (migration 0003).
2. SQL editor → run the migrations in order, once each:
   `0001_attendance_core.sql`, `0002_refinement.sql`, `0003_multi_tenant.sql`, `0004_employees.sql`.
   Later changes always come as a new numbered file; never edit one that has run.
3. Create each company from the SQL editor (it runs as the database owner, which is the only role
   allowed to call this):
   ```sql
   select public.create_company('Acme Industries', 'acme', 'Asia/Kolkata', 'owner@acme.in', 'Owner Name');
   ```
   This makes the company and its first Admin record. Branding (app name, logo URL, accent colours)
   is a row in `companies`; the Admin can change the time zone and rules in Settings.
4. Cloudflare build variables (see `.env.example`): `NEXT_PUBLIC_SUPABASE_URL` and
   `NEXT_PUBLIC_SUPABASE_ANON_KEY`. The service-role key must **never** go into the site.
5. Turn on Point-in-Time Recovery or check the daily backup retention on the chosen plan.

## 2. Supabase Auth — settings this design depends on
People are employee records first. A login is linked to the record **only when the sign-in e-mail
matches and is confirmed** (`handle_new_user` and `on_auth_user_confirmed` triggers). So:

| Setting | Required value | Why |
|---|---|---|
| Authentication → Providers → Email | Enabled, **Confirm email ON** | Linking trusts `email_confirmed_at`. With confirmation off, anyone could sign up with a colleague's address and take over their record. |
| Site URL | the company site, e.g. `https://attendos.example.com` | Used in confirmation and reset links. |
| Redirect URLs | `https://<site>/login*` and `https://<site>/reset*` (plus preview URLs if used) | Password reset returns to the app. |
| Allow new users to sign up | ON (sign-ups without an employee record see "not linked" and get no data) or OFF if every login is invited | Both are safe; OFF is tidier. |
| SMTP | Custom SMTP (own domain, SPF/DKIM) | Supabase's built-in mailer is rate-limited and only for testing. |
| JWT expiry / refresh | defaults are fine | RLS reads `auth.uid()` from the token on every request. |

**Inviting people from the app is not built.** Today HR adds the employee in Employees, then the person
signs up at `/login` (or `/login?company=<slug>` for the company's branding) with that same work e-mail
and confirms it. A one-click "Send invite" button needs a **Supabase Edge Function** holding the
service-role key (`auth.admin.inviteUserByEmail`), which checks that the caller is HR/Admin of the
employee's company. That is a small, separate piece of work to schedule.

Also still to verify on the real project: password reset round trip, sign-out on all devices,
an exited employee being refused (the app signs them out because `active = false`; RLS also hides data).

## 3. Maps and address search (Settings → Locations & GPS)
The map uses **Leaflet** with **OpenStreetMap's public tiles**, and address search calls
**Nominatim** (`nominatim.openstreetmap.org`) from the browser. Both are free community services with
usage policies:

- **Tiles:** keep the visible "© OpenStreetMap contributors" attribution (already shown); fine for
  light use by a few HR/Admin users. Heavy or commercial use across many companies should move to a
  tile provider with a key (e.g. MapTiler, Stadia, Thunderforest) or self-hosted tiles.
- **Nominatim:** at most about one request per second, identified traffic, and **no type-ahead
  autocomplete**. AttendOS only searches when HR presses Search, which fits. For a multi-company SaaS,
  plan a paid geocoder (or self-hosted Nominatim) before onboarding many companies.
- If a Content-Security-Policy is added to `public/_headers` later, allow the tile and geocoder hosts
  in `img-src` / `connect-src`.
- Without tiles the screen still works: the office pin, radius circle and coordinates are drawn and
  saved; only the background map is blank (as in the review screenshots, taken offline).
- Employees' check-in never uses the map or geocoder — the GPS check is done in the database.

## 4. Before the first real company
- Run `npm run test:db` against a fresh Supabase branch/project, not only local Postgres.
- Sign up a test Admin, HR, Manager and Employee in two companies and repeat the isolation checks by hand.
- Check `public/_headers` is served (geolocation allowed for this site only).
