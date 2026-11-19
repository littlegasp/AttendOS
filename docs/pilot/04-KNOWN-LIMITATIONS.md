# Known limitations (Pilot 01)

What is done, locally tested, hosted-tested or pending, item by item: STATUS-LEGEND.md.

**Fixed in this pass:** someone who opened their invitation while HR had switched them off could never be linked
(found by the new invitation edge-case check). Migration `0009_link_on_reactivation.sql` links them when access is
switched back on. Locally tested; it ships with the other migrations.

Tell the pilot company about these before day 1. None blocks a pilot of up to about 100 people; each one says
what to do about it.

## Not yet verified on the hosted site
| Item | Status | What to do |
|---|---|---|
| Hosted Supabase (Mumbai) end to end | Tested on local Postgres plus the real Supabase Auth server, not on a hosted project | 01-DEPLOYMENT-CHECKLIST §B9 and 03-PILOT-TEST-CHECKLIST sections 1–4 |
| Auth hook grant to `supabase_auth_admin` | That role only exists on hosted Supabase (verify_hosted.sql row 9) | Check row 9 after enabling the hook |
| Publishable key (`sb_publishable_…`) in the `…_ANON_KEY` variable | Expected to work with supabase-js; not tried on hosted | Sign in once; if it fails, use the legacy anon key for the pilot |
| GPS on real phones | Tested with simulated positions in the browser | Section 4 of the test checklist, Android and iPhone, indoors and outdoors |
| E-mail delivery | Tested with a local mail catcher | Send to Gmail and Outlook; check Inbox, not Spam |
| Invitation edge cases (expired, re-invite, changed e-mail, duplicate, already linked, other company) | 26/26 locally with the real Auth server | Test checklist 2b |
| Restore of a whole database (backup / PITR) | Not possible locally (Supabase feature) | Rehearse once into a new project (deployment checklist A5) |
| Login/record consistency repair and company deletion scripts | Tested on local copies, incl. the real Auth schema | Company deletion on test company T (test checklist 12.5) |

## Size and speed
- Monthly register and reports work out every person-day on request (about 0.9 ms each). Measured: 100 people
  about 3.2 s, 300 about 8.2 s, 600 about 16.5 s per month. Supabase stops signed-in calls at 8 s.
- **Fine for the pilot (≤100 people). Not fine above about 150–200 people.** The fix is the daily summary table,
  a requirement before larger companies (docs/requirements/DAILY-SUMMARY.md). The statement timeout is not raised.
- The monthly grid stops at 5,000 rows; reports cover at most 93 days at a time.

## Features that are not there yet
- Leave: no accrual, carry-forward or encashment rules; no attachments (e.g. medical certificate); balances are
  set and adjusted by HR.
- Roster: one person or a selected list at a time; no bulk by department/group and no shift templates.
- No notifications (e-mail, push or WhatsApp) for approvals, late marks or reminders.
- Employee Documents module not built.
- No in-app Help guide.
- No CSV import of employees; HR adds people one by one.
- Fixed roles (Admin, HR, Manager, Employee); no custom roles.
- No scheduled or e-mailed reports.
- Export is CSV (opens in Excel); PDF is the browser's Print → Save as PDF.
- Maps and address search use the free OpenStreetMap services: no availability guarantee, about one address
  search per second, no autocomplete, attribution required. They are used only by HR when placing offices; the
  check-in decision is made by the database and does not depend on them (tested with them blocked). Details and
  alternatives: 02-ENVIRONMENT.md §7.
- No in-app deletion of one person's data; company deletion and exports of a whole company are owner-run
  (07-DATA-RETENTION.md).
- No secret-key server functions (by design): anything needing one — e.g. a branded "Invite user" e-mail via
  the Auth admin API — is not built.

## Behaviour to explain to the pilot company
- GPS is read only when someone presses Check In or Check Out, never in the background.
- Accuracy indoors can be poor; the accuracy limit is a setting HR may need to tune in week 1.
- Corrections are added beside the original punch; originals are never changed.
- A login belongs to the work e-mail HR entered. Changing that e-mail changes who can sign in.
- Deactivating someone signs them out on their next screen; their history stays.
