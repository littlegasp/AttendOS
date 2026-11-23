# Development-Supabase preflight: owner runbook (Option A: the owner runs, Claude prepares)

Plan: `docs/biometric/BIOMETRIC_B5_DEV_SUPABASE_PREFLIGHT_PLAN.md`. Revised report and evidence:
`docs/biometric/BIOMETRIC_B5_DEV_PREFLIGHT_G1_REPORT.md`.
**Nothing here may run until the owner approves the gate it belongs to (G2 onwards).**

Rules:
- Development project only, synthetic data only.
- No pg_cron, no projection, no deployment, no real employee data, no real X2008 export, no real mapping.
- Secrets live only in your own terminal's environment and local files outside this repository. They never go into
  chat, issues, commits, logs or reports. The tools redact them from everything they print.

## Safety layers (every hosted step passes all of them)
1. **Project reference.** `ATTENDOS_DEV_PROJECT_REF` must be the development project's Reference ID. Every tool checks
   that the connection string or API URL names **exactly** that reference, and refuses any reference listed in
   `ATTENDOS_FORBIDDEN_PROJECT_REFS`.
2. **Development marker.** Step 3 writes `attendos_dev.environment_marker` once. Every later script first runs
   `dev_guard.sql` in the same transaction: no marker, or a marker for another reference, means STOP and nothing
   runs. A pilot or production database never has this marker.
3. **Single transaction.** Every SQL step is one transaction, so a failure leaves nothing behind.
4. **Exact files.** Migrations must match `migrations.sha256` and the approved commit. Applied migrations are frozen
   (D6).
5. **No service-role key.** The API tools refuse it, and Auth tokens must be issued by the development project.

## Tools
| File | Purpose | Writes? |
|---|---|---|
| `devguard.py` | the shared guard (reference, URL/key checks, redaction, reports outside the repo) | — |
| `dev_sql.py` | runs guarded SQL files (`--mark` writes the marker) | as the file says |
| `dev_mark_project.sql` | the development marker (once, new empty project only) | marker schema |
| `dev_guard.sql` | prepended to every script by the wrappers | no |
| `../check_biometric_prereqs.sql` | V1 prerequisites (read-only) | no |
| `dev_revoke_public_create.sql` | D5: revoke CREATE on `public` from anon and authenticated; stops if still granted | privileges |
| `dev_apply_migrations.py` | 0001–0013, one transaction each, exact commit and SHA-256 | schema |
| `../verify_hosted.sql` | V2 catalog checks (read-only; items 15–21 for 0013) | no |
| `dev_seed_synthetic.sql` | two invented companies, 10 invented people, 4 devices; no mapping | data |
| `dat_hosted_matrix.py` | V3/V4/V5 over the real API with real sign-ins (`--scale`: API timings) | synthetic batches, removed |
| `dat_hosted_scale.py` | G6: S1–S7, C1–C3, V7 boundary snapshot, inside the database as signed-in users | synthetic batches, removed |
| `dev_autovacuum.sql` | manual on/off for the rows table (the scale tool also does this itself and always resets) | table option |
| `rollback_0013_dev_only.sql` | remove 0013 from the development project only (§6.2) | schema |
| `rehearsal/` | the local rehearsal of all of the above (no hosted system) | local only |

## Exact owner actions (only after the matching gate is approved)

### Before G2: on your computer
1. Tools: `psql` 15+ (or 16), Python 3.11+, `pip install "psycopg[binary]"`, and this repository at the approved
   commit (`git checkout <commit>`; `git status` clean).
2. Copy `dev.env.example` to **`~/.attendos-dev.env`** (outside the repo), then `chmod 600 ~/.attendos-dev.env`.
   Fill it in after G2.

### G2: create the development project (Supabase dashboard; cost approved first, D1)
3. New project in your organisation: name `attendos-dev`, region **South Asia (Mumbai)**, compute as approved (D1).
   Generate a strong database password and store it in your password manager.
4. Note the **Reference ID** (Project Settings → General). Check it is a new project, not any other.
5. Database → Extensions: confirm `btree_gist` is available. Do **not** enable `pg_cron`.
6. Authentication → Providers: Email on, "Confirm email" on, **"Allow new users to sign up" off** (the test logins are
   created by you). Leave the Before-User-Created hook off on this project.
7. Fill `~/.attendos-dev.env`:
   - the Reference ID;
   - the **Session pooler** connection string (Connect → Session pooler; user `postgres.<ref>`; your password);
   - `https://<ref>.supabase.co`;
   - the anon / publishable key;
   - `ATTENDOS_DEV_LOGINS_FILE=~/.attendos-dev-logins.json`;
   - `ATTENDOS_FORBIDDEN_PROJECT_REFS` with any pilot/production reference that exists.

   Load it in your terminal: `set -a; . ~/.attendos-dev.env; set +a`.
8. Check the guard: `cd supabase/deploy/dev_preflight && python3 devguard.py`. It must print
   `database guard ok for project <ref>`.

### G3: marker, prerequisites, D5
9. `python3 dev_sql.py --mark`: shows `development | <ref>`.
10. `python3 dev_sql.py check_biometric_prereqs.sql`. Share the report file (redacted) with Claude.
    - Expected: `ok = t` everywhere, except rows 6–7 (pg_cron, not used) and possibly 13–14 (CREATE on public).
    - **Row 15 false = STOP.**
11. If row 13 or 14 is false: `python3 dev_sql.py dev_revoke_public_create.sql`. Then repeat step 10: rows 13–14 must
    be `t`.

### G4: migrations and catalog
12. `python3 dev_apply_migrations.py --commit <approved commit>`: 13 × `ok`. Any STOP: share the report, do nothing else.
13. `python3 dev_sql.py verify_hosted.sql`: all 21 items `t`. Share the report.

### G5: synthetic data, logins, API checks
14. `python3 dev_sql.py dev_seed_synthetic.sql`.
15. Authentication → Users → **Add user** → **Create new user** with "Auto Confirm User" for each e-mail below. Give
    each a long random password from your password manager.
    - `a.admin@`, `a.admin2@`, `a.hr@`, `a.manager@`, `a.employee@`, `b.admin@`, `b.hr@`, `b.employee@`
    - all at `attendos-dev.example` (a reserved domain; no mail is ever sent)
16. Write `~/.attendos-dev-logins.json` (then `chmod 600`) in the form
    `{"A admin": {"email": "a.admin@attendos-dev.example", "password": "…"}, "A admin2": {…}, "A hr": {…},
    "A manager": {…}, "A employee": {…}, "B admin": {…}, "B hr": {…}, "B employee": {…}}`.
17. `python3 dat_hosted_matrix.py --scale`: must end with `ALL API CHECKS PASSED`. Share the report.

### G6: performance in the database
18. `python3 dat_hosted_scale.py`: must end with `ALL DB-LEVEL CHECKS PASSED`. Share the report.
19. B3.3/B3.4 HTTP suites (D7): hosted versions are **not prepared yet** (see the G1 report, remaining risks). Skip
    until they are prepared and approved.

### G8: afterwards
20. Pause or delete the project (D4), or keep it until the report is accepted. Rotate the database password and API
    keys if the project is kept. Delete `~/.attendos-dev-logins.json` when done.

### Only if a hosted-only defect forces 0013 out (owner decision)
`python3 dev_sql.py rollback_0013_dev_only.sql -v confirm=REMOVE-0013-FROM-DEVELOPMENT`, then `verify_hosted.sql`.
Deleting and recreating the project is equally valid.

## STOP rule
Any `STOP`, any `FAIL`, any `ok = f` outside the expected rows, or any permission difference means:
- do nothing further on the project;
- share the redacted report;
- nobody improvises a fix on the hosted project.
