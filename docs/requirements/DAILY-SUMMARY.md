# Requirement: daily attendance summary table

**Status:** required before onboarding any company above about 150 people, or sooner if Pilot 01's monthly
register or report takes more than about 4 s. Not built for Pilot 01 (decision 19-Nov-2026).

## Why
The register, reports, trend and dashboard work out every person's day on request through `day_for()` (about
0.9 ms per person-day). A month for 600 people is about 18,000 person-days ≈ 16.5 s, past Supabase's 8 s limit
for signed-in calls. Raising the statement timeout is **not** an accepted fix: it only moves the wall and lets one
company's report slow everyone else in the shared project.

## What to build
1. Table `attendance_days` — one row per person per date: `company_id`, `employee_id`, `day`, status, shift,
   first in / last out, worked / break / late / early / overtime minutes, leave type and portion, remote flag,
   holiday/weekly-off flag, `computed_at`. Primary key `(employee_id, day)`; index `(company_id, day)`.
   Same rules as every table: RLS through `my_company()` / `can_see()`, `check_company_refs`, `freeze_company_id`,
   no anon access, removed when the employee is removed.
2. Kept current by the same code that shows the day today: a function `refresh_days(employee, from, to)` that
   writes `day_for()` results. Called after every change that can alter a day:
   punches, approved corrections, leave approve/cancel/record, roster and shift-pattern changes, remote exceptions,
   holidays, shift edits, office/settings changes (company-wide refresh queued), employee join/exit dates.
3. Nightly Supabase Cron job: refresh yesterday and today for every active person (covers absences and days that
   end without any event), and re-check the last 7 days.
4. Reports read the table; today's row is still worked out live so the dashboard is current.
5. Backfill per company in batches (e.g. one month at a time) before switching that company over.

## Acceptance
- For every person-day in the test data, the table equals `day_for()` (consistency test in `npm run test:db`),
  including after each kind of change above.
- Monthly register and reports for 600 people / 30 days under 1 s; dashboard under 0.5 s.
- A nightly consistency check reports any differences in the Activity log.
- Existing screens, exports and numbers unchanged (compare CSVs before and after on the same data).
- New numbered migration; no edit to 0001–0008.
