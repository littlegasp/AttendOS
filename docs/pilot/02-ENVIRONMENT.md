# Environment configuration guide (Pilot 01)

Replace `<site>` with the pilot address (e.g. `https://attendance.example.in`) and `<ref>` with the Supabase
project reference.

## 1. What goes where — and what never leaves Supabase

| Setting | Value | Where it lives | Visible to |
|---|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://<ref>.supabase.co` | Cloudflare build variable (and `.env.local` for local builds) | Everyone (built into the page — by design) |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | the **publishable key** `sb_publishable_…` (the legacy `anon` JWT also works until Supabase retires it) | Cloudflare build variable | Everyone (by design; row level security protects the data) |
| Secret key `sb_secret_…` / legacy `service_role` | — | **Supabase dashboard only. AttendOS doesn't use it.** Never in Cloudflare, GitHub, `.env*`, chat or e-mail. | Owner only |
| Database password | — | Owner's password manager | Owner (+ backup person) |
| SMTP username / password | — | Supabase → Authentication → SMTP Settings only | Owner |
| Supabase account | MFA on | — | Owner + backup |

The app is a static site: anything in a `NEXT_PUBLIC_*` variable is readable by anyone who opens it. That is why
only the URL and the publishable key are allowed there. After every build: `grep -rEl 'sb_secret_[A-Za-z0-9_-]{10,}|c2VydmljZV9yb2xl' out/`
must list nothing (a real secret key, or a legacy service_role token — the bare word `sb_secret_` appears in Supabase's library code and is fine).

Local development stays on the sample database (`supabase/demo`) — never point a laptop build at the pilot project
with someone else's login.

## 2. Supabase Authentication settings

| Dashboard place | Setting | Value |
|---|---|---|
| URL Configuration | Site URL | `<site>` |
| URL Configuration | Redirect URLs | `<site>/login**` and `<site>/reset-password**` (exactly these two) |
| Sign In / Providers → Email | Enable Email provider | ON |
| | Confirm email | **ON** (linking trusts confirmed addresses only) |
| | Secure email change | **ON** |
| | Minimum password length | 8 (or more); require letters and digits |
| | Email OTP / link expiration | 86400 seconds (invitation links last one day) |
| Sign In / Providers | Allow new users to sign up | ON — the hook below limits it to HR-added work e-mails |
| Other providers (Google, Apple, phone…) | | OFF |
| Hooks | Before User Created | Postgres function `public.hook_before_user_created` |
| Rate Limits | E-mails sent per hour | ~100 for the pilot; others default |
| Sessions | JWT expiry | Default (3600 s) |
| Database settings | Statement timeout | **Leave the default** (signed-in calls stop at 8 s) — never raised as a workaround |

## 3. SMTP (custom sender)
Supabase's built-in sender is only for testing. Use a transactional provider with an India/Asia region, e.g. Amazon
SES (ap-south-1), Postmark, Resend or Zoho ZeptoMail.

| Field | Value |
|---|---|
| Sender e-mail | `attendance@<company or your domain>` (a real mailbox for replies) |
| Sender name | `AttendOS` (or the pilot company's name) |
| Host / Port | provider's SMTP host, port **587** (STARTTLS) |
| Username / Password | provider SMTP credentials (stored only in Supabase) |
| DNS on the sender domain | SPF include of the provider, DKIM records, `DMARC p=none` to start (move to quarantine after the pilot) |

Test: send an invitation to a Gmail and an Outlook address and check it lands in **Inbox**, not Spam.

## 4. E-mail templates (Authentication → Emails → Templates)
Templates are project-wide (one set for all companies), so they don't name the company. Keep
`{{ .ConfirmationURL }}` — it carries the right return page for each case (sign-up → `/login?confirmed=1`,
invitation → `/reset-password?welcome=1`, reset → `/reset-password`).

**Confirm signup** — subject: `Your AttendOS access — confirm your work e-mail`
```html
<h2>Welcome to AttendOS</h2>
<p>Your company has set up attendance on AttendOS for {{ .Email }}.</p>
<p><a href="{{ .ConfirmationURL }}">Confirm your work e-mail and continue</a></p>
<p>The link works once and expires in 24 hours. If you didn't expect this, ignore this e-mail.</p>
```

**Magic Link** (used when HR re-invites someone whose login exists but isn't linked yet) — subject: `Your AttendOS sign-in link`
```html
<h2>Your AttendOS sign-in link</h2>
<p><a href="{{ .ConfirmationURL }}">Open AttendOS</a> — you'll be asked to choose a password.</p>
<p>The link works once and expires in 24 hours. If you didn't ask for this, ignore this e-mail.</p>
```

**Reset Password** — subject: `Reset your AttendOS password`
```html
<h2>Reset your password</h2>
<p><a href="{{ .ConfirmationURL }}">Choose a new password</a>. Other devices will be signed out.</p>
<p>The link works once and expires in 24 hours. If you didn't ask for this, ignore this e-mail.</p>
```

**Change Email Address** — subject: `Confirm your new e-mail for AttendOS`
```html
<p>Confirm this address for AttendOS: <a href="{{ .ConfirmationURL }}">confirm</a>.</p>
<p>Note: your attendance login follows your work e-mail. If this isn't your work e-mail, access will stop until HR updates it.</p>
```

## 5. Cloudflare
- Worker name `attendos`, static assets from `out/` (`wrangler.jsonc`), `not_found_handling: 404-page`.
- `public/_headers` must be served (check `Permissions-Policy: … geolocation=(self)` on `/my-attendance`).
- Custom domain with HTTPS (GPS only works on HTTPS).
- Build: `npm ci && npm run build` with the two variables from §1; deploy `out/`.
- Keep the previous deployment available for rollback (Workers → Deployments).

## 6. Migration order and why
`0001 → 0008`, each once (01-DEPLOYMENT-CHECKLIST.md §B). Each file builds on the previous one: 0003 replaces the
single-organisation tables with companies, 0005 replaces the linking trigger and stamps the audit log, 0006
renames and wraps several functions (`punch`, `my_today`, `dashboard_summary`, `day_for`), 0008 wraps the roster
functions. Running out of order, twice, or partially fails or leaves the database inconsistent — if that happens,
restore (05-ROLLBACK.md) rather than patching by hand. Future changes always arrive as 0009, 0010…, never as edits.
