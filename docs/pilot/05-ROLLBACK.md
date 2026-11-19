# Rollback, restore and incident procedure (Pilot 01)

Status: **written; restore, relink and session steps tested locally** (scratch copies, real Supabase Auth
server). **Not yet done on a hosted project** — rehearse §2.2 once before day 1 (01-DEPLOYMENT-CHECKLIST A5).
No step here is run on the live project without the owner's explicit approval.

Rule: **back up before every change, roll forward when you can, restore only when you must.** Never force-push,
never delete a branch or tag, never edit a migration that has run.

## What lives where (this decides what a restore brings back)
| Data | Where | In a Supabase backup / PITR | In our `pg_dump -n public` |
|---|---|---|---|
| Employees, attendance, leave, settings, invitations, Activity log | Postgres, schema `public` | Yes | Yes |
| Logins: e-mail, password hash, confirmation, sessions, identities | Postgres, schema `auth` (Supabase Auth) | **Yes** | **No** |
| Auth settings, hook, SMTP, templates, API keys | Supabase project settings (outside Postgres) | No — unchanged by a restore | No |
| Site code | Cloudflare / git tags | No | No |

**A `public`-schema dump never restores logins.** Logins only come back with a Supabase restore of the whole
database (§2.1–2.2). The link between the two is `employees.user_id` → `auth.users.id`, plus the rule that a
login belongs to the employee whose work e-mail it confirmed.

## 0. Before any change (deploy, migration, settings)
1. Git tag the code being deployed: `git tag pilot-01-rcN && git push origin pilot-01-rcN`.
2. Note the restore point: Database → Backups shows the last daily backup; with PITR note the current time (IST).
3. Our own copy of the business data: `pg_dump "<session-pooler connection string>" -Fc -n public -f attendos-public-YYYYMMDD-HHMM.dump`
   (or `supabase db dump --data-only`). This is the only copy you can download — Supabase's physical backups can
   only be restored, not downloaded. It holds personal data: store it encrypted, owner only, list it in the
   export register (07-DATA-RETENTION.md) and delete it after 30 days.
4. Note the current Cloudflare deployment (Workers → attendos → Deployments).

## 1. Front-end problem (screens broken, wrong build) — data unaffected
- Cloudflare → Workers → attendos → Deployments → previous version → **Rollback**; or `npx wrangler rollback`; or
  check out the previous tag and `npm run deploy`.
- About a minute. Afterwards re-run test-checklist 3.2 and 4.3.

## 2. Database problems — pick the scenario

### 2.1 Whole database back to an earlier time, in place (daily backup or PITR)
Use when data is damaged widely (bad migration, mass wrong update) and losing changes since the restore point is
acceptable.
- Brings back **`public` and `auth` together, consistent with each other**: every employee link points to a
  login that existed at that moment.
- Lost: everything after the restore point — punches, leave, corrections, *and* logins created, passwords changed
  and invitations accepted after it. Sessions issued after it stop working; people sign in again.
- The project is **unavailable during the restore**; time grows with database size (rehearsal A5 gives the number).
1. Owner approval. Tell HR the outage and the restore point.
2. Take the site to the maintenance page (§3 step 4) so nobody types into a database that is about to be replaced.
3. Database → Backups → choose the daily backup / Point in Time (IST) before the damage → confirm.
4. Run `verify_hosted.sql` (all true) and `check_auth_links.sql` (all ok).
5. If the restore point is before a migration that the deployed site needs, deploy the matching earlier tag.
6. Bring the site back. HR re-enters punches made after the restore point as corrections; HR re-invites anyone
   whose invitation was accepted after it (Roles & Permissions → **User access** shows who has no login).

### 2.2 Restore to a new project (investigation or partial recovery — live data untouched)
Use when only some records are damaged, or to see what the data looked like.
Database → Backups → **Restore to a new project** (daily backup or PITR point). The copy has `public` *and* `auth`.
Nothing changes on the live project. Read what you need there, then go to §2.3. Delete the copy when done
(it holds personal data).

### 2.3 Repair selected records from a copy or from a `public` dump
**Never `pg_restore --clean` a dump over the live `public` schema.** It drops and recreates tables whose rows
point at logins in `auth` (and whose functions are used by triggers on `auth.users`); links to logins created or
deleted since the dump break, and the restore fails part-way.
1. Load the dump into a local Postgres or a scratch project (or use the §2.2 copy).
2. Select only the affected company's damaged rows; write them as a reviewed SQL script (`insert … on conflict`
   or `update … where id = …`) that never touches `employees.user_id` and never touches another company.
3. Owner approval → back up (§0) → run the script on the live project in one transaction.
4. Run `check_auth_links.sql`; if rows 1–4 are not 0, run `relink_logins.sql` (§2.4).

### 2.4 Keeping logins and employee records consistent after any restore or repair
`check_auth_links.sql` (read-only) reports:
1. records linked to a login that no longer exists; 2. linked to a login with a different e-mail;
3. linked to an unconfirmed login; 4. active records not linked although their confirmed login exists;
5. one login linked twice; 6. logins with no employee record.

`relink_logins.sql` (owner, one transaction) fixes 1–4 with the app's own rule — unlink anything that doesn't
match; link each active, unlinked record to the confirmed, unclaimed login with the same work e-mail. It never
creates or deletes logins or touches passwords; each change goes to the Activity log as a system change.
Then: people whose login no longer exists (deleted after the backup) get a new invitation from HR; row 6
leftovers are reviewed and deleted in Authentication → Users. Tested locally on a copy with the real Supabase
Auth schema: a record restored without its link and a record restored with a link to a deleted login were both
repaired, and all six checks returned 0.

## 3. Suspend or stop the pilot
1. Tell the pilot company's HR first; they continue their old process.
2. Export: HR downloads the Register (month) and Reports CSVs; the owner takes a `pg_dump` (§0.3).
3. Stop new logins: Authentication → Sign In / Providers → turn off "Allow new users to sign up".
4. Take the site offline: deploy a maintenance page, or remove the custom domain route.
5. Ending for good: follow 07-DATA-RETENTION.md §4 (deletion with evidence).

## 4. Credential or access incident
### 4.1 Which keys matter
| Credential | What it can do | If exposed |
|---|---|---|
| **Publishable key** `sb_publishable_…` (or legacy `anon`) | Public by design; it is in every visitor's browser. Grants only what row level security allows an anonymous visitor: here, one function (`company_brand`, a company's name and logo). | Not an incident. Rotate only if it is being abused (traffic): create a new publishable key, update the Cloudflare variable, redeploy, then delete the old key. |
| **Secret key** `sb_secret_…` | Full access, **bypasses row level security**. AttendOS never uses one. | Critical. Settings → API Keys → delete it (create a new one only if something legitimate needs it — AttendOS doesn't). |
| **Legacy `service_role` key** (JWT) | Same as a secret key. | Critical. If the site was built with the legacy `anon` key, rebuild it with the publishable key first. Then Settings → API Keys → deactivate the legacy keys, **and revoke the legacy JWT secret** (JWT Keys → migrate to signing keys → rotate → revoke the old secret), because anything that still trusts that secret accepts the leaked key. |
| **Database password** (`postgres`) | Full access to all data, bypasses everything. | Critical. Database → Settings → **Reset database password**; store the new one in the password manager; update any saved connection strings. The app doesn't use it, so nothing to redeploy. |
| **JWT signing key** (signs people's sessions) | Could forge any person's session. | Critical. JWT Keys → rotate → revoke the previous key. All sessions end; everyone signs in again. |
| **Supabase / Cloudflare / GitHub account** | Everything above. | Change password, check MFA, remove unknown members and tokens, then treat every credential above as exposed. |
| **SMTP credentials** | Sending mail as the sender address. | Rotate at the mail provider; update Authentication → SMTP Settings. |

The front end needs only the URL and the publishable key — no secret key is ever built into it, set in Cloudflare
or stored in git (01-DEPLOYMENT-CHECKLIST D4 checks the build).

### 4.2 Ending sessions
- **One person:** HR/Admin switches their access off — the database refuses their data on the very next request
  (tested), and the app signs them out. To also end their refresh tokens, the owner runs in the SQL editor:
  `delete from auth.sessions where user_id = (select user_id from public.employees where email = '<work e-mail>');`
  (tested locally: the old refresh token is refused afterwards). Their current access token stops being accepted
  by Auth when it expires (1 hour by default); the database already refuses it while access is off.
- **One company:** switch access off for its people, then
  `delete from auth.sessions where user_id in (select user_id from public.employees where company_id = '<company id>');`
- **Everyone:** rotate and revoke the JWT signing key (table above).

### 4.3 Order of work
1. Contain: rotate/revoke the exposed credential (table) and end sessions (4.2) if people's access may be misused.
2. Keep evidence: don't delete anything. Save the Activity log for the period (owner, SQL editor:
   `select * from public.audit_log where at >= '<start>' order by id;` → download the result as CSV), Supabase
   Auth and API logs (Logs → Auth / API) and Cloudflare logs. Supabase keeps logs only for a limited time on each
   plan, so save them the same day.
3. Check: `verify_hosted.sql`, `check_auth_links.sql`; Activity log for changes nobody recognises.
4. Inform: the owner tells the pilot company the same day with what is known, so they can meet their own
   obligations to their staff and the authorities; then a written timeline.
5. Fix the cause before issuing new credentials (otherwise the new one leaks the same way).

## 5. Git
- `main` stays at the last reviewed merge; pilot builds come from tags on `phase-4-5` until merged.
- Fixes go on a new commit; tags are never moved; history is never rewritten.
