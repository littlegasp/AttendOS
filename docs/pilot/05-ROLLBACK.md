# Rollback procedure (Pilot 01)

Rule: **back up before every change, roll forward when you can, restore only when you must.** Never force-push,
never delete a branch or tag, never edit a migration that has run.

## 0. Before any change (deploy, migration, settings)
1. Git tag the code being deployed: `git tag pilot-01-rcN && git push origin pilot-01-rcN`.
2. Database backup:
   - Supabase dashboard → Database → Backups: confirm last night's backup exists (Pro plan; PITR if enabled).
   - Plus your own copy: `pg_dump "<session-pooler connection string>" -Fc -n public -f attendos-YYYYMMDD-HHMM.dump`
     (or `supabase db dump`). Store it encrypted with the owner; it holds personal data. Delete copies after 30 days.
3. Note the current Cloudflare deployment ID (Workers → attendos → Deployments).

## 1. Front-end problem (screens broken, wrong build)
Data is unaffected.
- Cloudflare dashboard → Workers → attendos → Deployments → previous version → **Rollback**; or
  `npx wrangler rollback` (choose the previous version); or check out the previous tag and `npm run deploy`.
- Takes about a minute. Re-run test-checklist section 3 and 4.1 afterwards.

## 2. Database problem after a migration
- **Small, understood problem:** write the fix as the next migration (0009…), test it locally with
  `npm run test:db`, back up, apply. This keeps every company's history.
- **Data damaged or migration half-applied:** restore.
  1. Take the site offline (§3) so nobody writes during the restore.
  2. Restore the backup from step 0: dashboard backup / PITR to the time before the change (replaces the whole
     database, Auth users included), or `pg_restore --clean --if-exists -d "<conn>" attendos-….dump` for the
     `public` schema only.
  3. Run `supabase/deploy/verify_hosted.sql`; all rows true.
  4. Deploy the matching front-end tag; bring the site back.
  - Expect 15–60 minutes. Punches made after the backup are lost; tell HR the window so they can enter
    corrections.

## 3. Suspend or stop the pilot
1. Tell the pilot company's HR first; they continue their old process.
2. Export: HR downloads the Register (month) and Reports CSVs; the owner takes a `pg_dump`.
3. Stop new logins: Authentication → Sign In / Providers → turn off "Allow new users to sign up".
4. Take the site offline: replace the deployment with a maintenance page, or remove the custom domain route.
5. If the pilot ends for good, agree with the company how long data is kept; then delete the company's rows (or the
   whole project if it held only this company) and confirm in writing.

## 4. Security incident (key leaked, wrong person sees data)
1. Rotate: Settings → API Keys → roll the publishable key (and the secret key if it could have leaked); update
   the Cloudflare variable and redeploy. Change the database password.
2. Revoke sessions: deactivate affected logins in AttendOS; Supabase → Authentication → Users → sign out.
3. Keep the evidence: Activity log, Supabase Auth and API logs. Don't delete anything.
4. Owner informs the pilot company the same day so they can meet their own notice duties.

## 5. Git
- `main` stays at the last reviewed merge; pilot builds come from tags on `phase-4-5` until merged.
- Fixes go on a new commit; tags are never moved; history is never rewritten.
