# Recommendation: starting Pilot 01

Status of every item: STATUS-LEGEND.md. Nothing is deployed; each hosted step needs the owner's explicit approval.

**Recommendation: go ahead with Pilot 01 once the deployment checklist (sections A–F) and test-checklist
sections 1–4 (including 2b) pass on the hosted site.** The code is ready for a controlled pilot; what remains unproven is the
hosted setup, e-mail delivery and GPS on real phones, and the checklists exist to prove those first.

## Shape
- One company, **100 people or fewer**, one or a few offices.
- **2–4 weeks.** For the first 2 weeks HR keeps its current attendance process in parallel and compares.
- Built from tag `pilot-01-rc1` = application commit `6d47386` (see Source below). `main` is merged only after the pilot passes
  its go-live review.
- Owner keeps the Supabase and Cloudflare accounts; nobody at the pilot company gets dashboard access.

## Source (application vs documentation)
| What | Commit | Contains |
|---|---|---|
| **Application** | `6d4738643388ec8c8da302775f1f96ff0ce46415` (`6d47386`) | Front end (`src/`, `public/`, build config — unchanged since `e702229`), migrations 0001–0009, deploy scripts and tests. This is what is built, deployed and migrated. |
| **This deployment pack (final)** | the documentation-only commit after it (hash printed on every page of the PDF) | Documents only. `git diff --stat 6d47386 <pack commit> -- src public supabase/migrations package.json package-lock.json next.config.ts wrangler.jsonc` prints nothing. |

- `pilot-01-rc1` will point at the **application commit `6d47386`**, created only with the owner's approval
  (01-DEPLOYMENT-CHECKLIST D3). Not created yet.
- Documentation-only commits never get a new tag. Any change to the application (a fix found in the pilot) is a new
  commit, tested, and tagged `pilot-01-rc2`, `rc3`…; earlier tags are never moved.
- The first new migration after this pack is `0010_…`.

## Go / no-go before day 1
- verify_hosted.sql: all 12 rows true; check_auth_links.sql: all 6 rows ok.
- Restore rehearsed once into a throwaway project (deployment checklist A5) and the time noted.
- Data retention agreed in writing with the pilot company (07-DATA-RETENTION.md).
- Admin, HR, one Manager, two employees (Android + iPhone) signed in through real invitation e-mails that landed in Inbox.
- GPS check-in accepted inside the office and refused 1 km away on both phones.
- Test company T cannot see any pilot data; T then deleted with `delete_company.sql`, other company unchanged.
- Backup taken and the rollback steps read through; secret key confirmed absent from the build.
- The pilot company has received 04-KNOWN-LIMITATIONS.md and agreed to it.
- Owner's written go-ahead.

## During the pilot (weekly review with HR)
- Daily: errors reported by staff; failed check-ins and the accuracy shown.
- Weekly: HR compares 10 people's register and leave against their own records; note the monthly register and
  report load time.
- Fix only defects, as new commits and new tagged builds; no new features during the pilot.

## Success
- ≥95% of working days have a check-in made in AttendOS by week 2.
- Register and leave balances match HR's records for the sampled people (differences explained).
- No case of anyone seeing another company's or another team's data.
- Monthly report loads under about 5 s.
- HR is willing to stop the parallel process.

## Stop or pause if
- Any data shows up for the wrong company or person → stop at once (05-ROLLBACK.md §4).
- Check-ins fail for more than ~10% of people for two days running and accuracy tuning doesn't fix it.
- Monthly reports exceed the 8 s limit → pause onboarding growth; build the daily summary table
  (docs/requirements/DAILY-SUMMARY.md).

## After the pilot
Merge `phase-4-5` into `main` only after the pilot review, then build the daily summary table before any company
above about 150 people.
