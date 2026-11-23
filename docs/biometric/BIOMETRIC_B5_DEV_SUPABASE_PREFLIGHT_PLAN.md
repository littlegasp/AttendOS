# Development-Supabase preflight plan: migrations 0001–0013 incl. B5 DAT import

Status: **Approved by the owner (D1–D7, 23 Nov 2026). G1 (§4.3) done locally — see BIOMETRIC_B5_DEV_PREFLIGHT_G1_REPORT.md. Nothing hosted has been executed; G2 needs the owner's approval.**
- Date: 23 Nov 2026. Branch `feature/biometric-b1`; the code under test would be pinned to the accepted commit
  (`7a673dc` or a later owner-approved one).
- No Supabase project has been created, connected to or changed.
- Every step below is gated, and the first gate is your explicit approval of this plan.
- Production, the pilot project, deployments, merges, releases, real employee mappings, pg_cron and the next B5 stage
  (reviewed records → raw events or projection) stay out of scope.

## 1. Why a preflight, and why all of 0001–0013

AttendOS has never run on hosted Supabase (`docs/STATUS.md`: "no hosted project exists"). 0013 depends on every
earlier migration, so the preflight installs the whole chain on a **separate, disposable development project**.

Everything so far was proven on local PostgreSQL 16 + PostgREST 12. That cannot show:

| Hosted difference | Why it matters for 0001–0013 |
|---|---|
| Supabase's Postgres build, extensions, and the `postgres` role (not a true superuser) | migrations must run as written: `btree_gist`, `pgcrypto`, grants, policies, `ANALYZE` inside a security-definer function (F2) |
| Supabase default privileges and schema grants | whether `anon` / `authenticated` receive grants or **CREATE on schema `public`** (review finding F7) |
| Role settings, e.g. the signed-in `statement_timeout` (8 s) | every DAT call was designed and measured against 8 s locally |
| API gateway in front of PostgREST | request and response size limits: a chunk call carries about 342 KB of base64; downloading a 16 MiB original returns about 22 MB |
| Real Auth tokens | the permission matrix must hold with real sign-ins, not locally signed test tokens |
| Hosted hardware, disk and network | the scale timings (§5) were local; validation of a 200,000-line file took about 3.1–3.5 s locally |
| Autovacuum, `ANALYZE` and the advisory lock under hosted settings | F2 and F5 fixes |

## 2. The development project (owner actions, after approval)

| Item | Proposal | Decision needed |
|---|---|---|
| Project | a **new, separate** Supabase project, e.g. `attendos-dev`, in **Mumbai (ap-south-1)**. Never the future pilot or production project | — |
| Compute size | the size intended for the pilot, so the timings mean something (a smaller instance would understate risk; record the size in the report) | **D1** |
| Data | **synthetic only**: two invented companies, invented people, synthetic X2008-shape files (2030 dates). No real employee data, and **no real X2008 export** on the development project | **D2** (recommended: no real file) |
| Access | owner only, as project owner. Claude never receives the service-role key, the database password or connection strings in chat (CLAUDE.md "never expose keys") | **D3**: how steps are executed (§3) |
| Auth | Email provider with Confirm email ON; test logins for the 8 test roles created by the owner (or the owner-approved test script) with random passwords kept in the owner's password manager; Site URL / redirect URLs limited to `http://localhost:4175` for local test builds | D3 |
| Lifetime | kept until the preflight report is accepted, then **paused or deleted** (it holds no personal data; deleting it is the cleanest rollback, §6) | **D4** |
| pg_cron, projection | not installed and not enabled. B3.4 projection remains off for every company | — |
| Deployment | none. The app is built locally and pointed at the dev project only for local browser tests; nothing goes to Cloudflare | — |

## 3. How the steps would be executed (decision D3)

The keys must never pass through chat. Three options:

| Option | How | Trade-off |
|---|---|---|
| **A. Owner runs, Claude prepares** (recommended for the first run) | Claude prepares reviewed scripts in the repo. The owner runs the SQL in the Supabase SQL editor, or runs the test scripts on their own machine with the keys in local environment variables, and shares the **outputs** (which contain no secrets) | slowest; the safest; the owner sees every step |
| B. Manual GitHub Actions workflow | a `workflow_dispatch` job reads the dev URL and keys from GitHub **secrets** (dev project only) and uploads the outputs as artifacts | repeatable; GitHub runners are usually outside India, so API timings include extra network latency (in-database timings are unaffected) |
| C. Session-scoped environment variables | the owner sets the dev keys as environment variables in a Claude session (never typed in chat) | fastest; keys live in a cloud session for its duration; needs your explicit approval and a key rotation afterwards |

In every option:
- the service-role key is used only by the owner for setup steps;
- the tests sign in as ordinary users through Auth, exactly like the app;
- after the preflight the dev keys are rotated, or the project is deleted.

## 4. Migration permissions and order

### 4.1 Read-only prerequisite checks (before anything is created)
Run `supabase/deploy/check_biometric_prereqs.sql` (read-only, exists), extended with:
- PostgreSQL ≥ 15;
- `btree_gist` and `pgcrypto` available (enabled by the owner in Database → Extensions; the SQL creates none);
- `pg_cron` **absent or unused**;
- the `authenticated` / `anon` / `authenticator` role settings, `statement_timeout` included;
- **CREATE on schema `public`** for `anon` and `authenticated`. If granted: decision **D5**, revoke it before 0001.
  Recommended. Our security-definer functions schema-qualify every table, but a role that can create functions in
  `public` widens the search_path surface (F7);
- default privileges on schema `public`, recorded (Supabase grants new tables and functions to the API roles; every
  AttendOS migration revokes explicitly, as the local stub already proves);
- whether the `postgres` role owns the tables it creates and may `ANALYZE` them, so the F2 `ANALYZE` in
  `biometric_dat_parse` works;
- whether `postgres` has BYPASSRLS. The DAT functions filter by company explicitly, but this is recorded.

### 4.2 Applying 0001–0013
- **Who:** the owner, as `postgres`, in the SQL editor (or `psql --single-transaction` with the session-pooler
  string on the owner's machine).
- **Exact bytes:** each file's SHA-256 at the pinned commit is recorded first and compared with what is pasted or
  run.
- **Order:** `0001` … `0013`, **one transaction per file**. A failure leaves that migration entirely unapplied.
- **0012 preflight:** 0012 stops by itself on unexpected `attendance_events.source` values (proven by
  `preflight_test.sh`). The dev project starts empty, so this cannot trigger.
- **Between files:** `verify_hosted.sql` after 0009, after 0012 and after 0013 (all `ok = true`).
- **Stop rule:** any error, any `ok = false`, or any grant or privilege that differs from local → stop, record, report.
  No improvising on the hosted project.
- **Frozen after the dev run (decision D6):** once 0013 has run on the dev project, it is treated as frozen and any
  change comes as `0014_…`. The alternative is allowing in-place correction while it has run only on a disposable dev
  project that is then recreated. Recommendation: **frozen**, so the dev run tests exactly what a company database
  will get.

### 4.3 Preparation needed before execution (done in G1, 23 Nov 2026; tools in `supabase/deploy/dev_preflight/`)
1. Extend `supabase/deploy/verify_hosted.sql` for 0013:
   - 36 `public` tables with biometrics (21 + 15);
   - the four DAT tables with RLS on and no grants;
   - no column privilege on `biometric_import_batches`;
   - only the 15 checked DAT functions executable by `authenticated`;
   - no `audit()` trigger on import tables.
2. Extend `check_biometric_prereqs.sql` as in §4.1.
3. Write `supabase/deploy/dev_seed_synthetic.sql`: two synthetic companies, devices (one X2008, one eSSL K21, one
   ZKTeco), and employees with obviously invented names. It runs only on the dev project.
4. Port the checks to HTTP, so they run against any PostgREST endpoint with real Auth sign-ins. The URL and anon key
   come from environment variables; logins come from a local, untracked file.
   - `e2e/hosted/dat_permission_matrix.py`: the 8 roles × 20 operations of T-PERM.
   - `e2e/hosted/dat_scale_http.py`: S1–S7 and C1–C3 over the API.
5. Write and **test locally** `supabase/deploy/rollback_0013_dev_only.sql` (§6.2). It refuses to run unless a
   dev-marker setting is present, so it can never run on a company database.
6. All of this is tested end to end against the local stack (PostgreSQL + PostgREST + real Supabase Auth binary)
   before any hosted step.

## 5. Hosted verification and performance testing

### 5.1 Verification (pass = every item true)
| # | Check | Tool |
|---|---|---|
| V1 | prerequisites and role settings as expected (§4.1) | extended `check_biometric_prereqs.sql` |
| V2 | catalog after 0013: RLS, grants, column privileges, function ACLs, search_path on every security-definer function, no audit trigger on import tables | extended `verify_hosted.sql` |
| V3 | **permission matrix** with real Auth: A Admin, A HR, A Manager, A Employee, B Admin, B HR, B Employee, anon × 15 functions + 5 tables. It must equal the local matrix exactly (correction-pass §2.1) | `dat_permission_matrix.py` |
| V4 | direct REST reads of the 5 import tables refused for Admin and HR | same |
| V5 | request and response size: a full 256 KiB chunk (≈ 342 KB base64) accepted; a 16 MiB download returned intact (hash compared) | `dat_scale_http.py` |
| V6 | upload → process → review flow with a synthetic file through the **local app build** pointed at the dev project (HR uploads, Admin allows the device format and marks reviewed, Continue processing, no uploaded file name anywhere) | `e2e/biometric_dat_import.py` variant with a synthetic file |
| V7 | B5 boundary: after all tests, `attendance_events`, `biometric_raw_events`, event state and sync runs are unchanged (snapshot hashes before and after); projection functions present but never called; pg_cron absent | SQL snapshot (read-only) |
| V8 | B3.3 / B3.4 installed correctly: read-only catalog checks plus the existing HTTP suites `biometric_gateway_http.py` and `biometric_projection_http.py`, if D7 allows them on dev (they create synthetic gateway data only) | existing scripts |
| V9 | audit: DAT audit entries carry only whitelisted keys; no file names | read-only SQL |
| V10 | logs: no unexpected errors in the Supabase API and Postgres logs during the run | Dashboard → Logs |

### 5.2 Performance (synthetic files; every call through the API as a signed-in user)
| Scenario | Pass criterion | Local result (23 Nov) for comparison |
|---|---|---|
| S1/S2: 32,000 lines; autovacuum normal / OFF for the rows table¹ | every call < 8 s; **target < 4 s** (50 % margin) | slowest 1.0 s |
| S3/S4: 200,000 lines; autovacuum normal / OFF¹ | every call < 8 s; target < 4 s | slowest 3.1–3.5 s (validate) |
| S5: forced cancellation mid-parse and mid-classify, then retry | nothing changed by the cancelled call; every line exactly once at the end | pass |
| S6: delete a 200,000-row batch | each call < 8 s; nothing left | 0.2–0.3 s per call |
| S7: retention expiry of a reviewed 200,000-row batch (timestamps moved back by the owner on synthetic data) | each call < 8 s; expired `retention_period`; nothing left | 4 calls, max 0.3 s |
| C1: 4 simultaneous starts | exactly 3 open, 1 `too_many_open_batches` | pass |
| C2 / C3: the same file by two Admins; two browsers processing one batch | 1 batch; every line once | pass |

¹ Autovacuum OFF requires `ALTER TABLE … SET (autovacuum_enabled = false)` by the owner on the **dev project
only**, reset immediately after.

Also recorded:
- `pg_stat_statements` top statements for the DAT functions;
- in-database duration separately from API round-trip time;
- the compute size.

**If hosted timings miss the target** (for example, 200,000-line validation above 4 s): stop and report. Any remedy
(smaller validation steps, a lower `lines_per_call`, a lower line limit) is a design change for your approval, then a
new migration, and the preflight is repeated.

## 6. Rollback strategy

### 6.1 Principle
The dev project holds only synthetic data, so the primary rollback is **delete the dev project and recreate it**.
Nothing there needs preserving, and recreation guarantees a clean state. Production and pilot are untouched because
they do not exist and are not involved.

### 6.2 Layers
| Situation | Action |
|---|---|
| a migration fails part-way | nothing to undo: each file runs in one transaction. Record the error, stop |
| 0013 installed but must come out (e.g. a hosted-only defect) | `rollback_0013_dev_only.sql`, prepared and tested locally first: drops the DAT functions and the four DAT tables, removes the added batch columns and indexes, and restores the 0010 unique constraint, `company_refs` trigger, `bio_read` policy and grant exactly as 0010 left them. Verified by running `verify_hosted.sql` for the 0012 state. Dev only; guarded by a dev-marker check |
| any other doubt about the dev database's state | delete and recreate the dev project, re-apply 0001–0013 |
| test data left behind | the synthetic companies are removed with the existing `delete_company.sql`, or the project is deleted |
| keys possibly exposed | rotate the dev project's keys (Settings → API) and the database password; delete test logins |

For later, not part of this preflight: for a **company** database the rule is **roll forward with a new migration**,
backed by the pilot rollback runbook (`docs/pilot/05-ROLLBACK.md`). The dev-only rollback script is never used
there.

### 6.3 Abort criteria (stop immediately, report, do nothing further on the project)
- any `ok = false` in V1/V2;
- any permission-matrix cell that differs from local;
- any call over 8 s;
- any unexpected error in the logs;
- any sign that real personal data reached the project;
- any change outside the DAT import tables during V7.

## 7. Execution sequence with gates (nothing starts without your go-ahead at G0)

| Gate | Step | Who | Output |
|---|---|---|---|
| **G0** | you approve this plan and decide D1–D7 | owner | written approval |
| G1 | local preparation (§4.3), tested against the local stack | Claude | commit (scripts and docs only) + local test report; you review |
| **G2** | you create the dev project, enable extensions, set Auth, create test logins | owner | project ready (no secrets shared) |
| G3 | prerequisite checks (V1) | per D3 | outputs reviewed; revoke CREATE on `public` if D5 says so |
| **G4** | apply 0001–0013 + verify (V2) | per D3 | outputs; stop rule applies |
| G5 | synthetic seed, V3–V10 | per D3 | outputs |
| G6 | performance S1–S7, C1–C3 | per D3 | timings |
| G7 | preflight report: pass or fail per item, timings, deviations from local, recommendation | Claude | report for your review |
| **G8** | you decide: keep the dev project for later, pause it or delete it; rotate keys | owner | — |

Passing this preflight **does not** authorise migrating any company or pilot database, deploying, merging or
releasing. Each of those stays a separate decision.

## 8. Decisions needed (with recommendations)

| # | Decision | Recommendation |
|---|---|---|
| D1 | dev compute size | the size planned for the pilot |
| D2 | real X2008 export on the dev project? | **No.** Synthetic files only (the real file holds other employees' records) |
| D3 | how steps are executed (§3) | Option A for the first run |
| D4 | dev project lifetime | keep until the report is accepted, then pause or delete |
| D5 | if `authenticated` / `anon` can CREATE on `public`: revoke before 0001? | **Yes**, on the dev project; record it for the pilot runbook |
| D6 | 0013 frozen once run on dev? | **Yes**: later changes as 0014+ |
| D7 | run the B3.3 / B3.4 HTTP suites on dev (synthetic gateway data)? | Yes; projection stays off for real companies (none exist) |

## 9. Outstanding owner dependencies (unchanged; not resolved by this preflight)
1. A **fresh, complete, unopened X2008 USB export**: full-history coverage (151 vs 31,207), provenance, field-1 width,
   device clock zone; fields 3–6 meanings from HR/eSSL.
2. **HR's written confirmation** of the code 10 → WR198 effective date and any earlier use of code 10. Until then no
   real mapping is created anywhere.
3. Pre-existing test failures, kept documented (BIOMETRIC_IMPLEMENTATION_STATUS.md, "Known pre-existing test
   failures"):
   - the intermittent B3.3 gateway key-audit check;
   - the B4 Sunday timeline check.
