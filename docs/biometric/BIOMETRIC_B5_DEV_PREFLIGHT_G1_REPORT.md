# Development-Supabase preflight: G1 local preparation report

Status: **G1 complete with the owner-requested correction (27 Nov 2026), local only. G2 NOT approved; awaiting owner review.**
- Date: 23 Nov 2026, corrected 27 Nov 2026 (§0). Branch `feature/biometric-b1`. Commit: see §9.
- Authorisation used: *G1 local preparation only* (owner, 23 Nov 2026), with D1–D7 as approved.
- **Not done, by instruction:** no Supabase project was created or contacted, no hosted SQL or migration was run, and
  no production credentials or connection strings were used. Also no real employee data, X2008 export or mapping; no
  pg_cron, projection or Cloudflare deployment; no merge, tag or force-push.

## 0. Correction pass, 27 Nov 2026 (owner review of G1)

The owner did not approve G2 and asked for five corrections first. My earlier wording "row 12 crashed" meant one
check, row 12, not twelve checks. The checker was nevertheless reworked and tested in every state, as requested.

### 0.1 Prerequisite checker: any state, clear results, no SQL errors
`check_biometric_prereqs.sql` now gives every row a result of **PASS**, **FAIL**, **N/A** (not applicable in this
state) or **INFO** (for the record, never blocks). Row 21 shows which AttendOS migrations are present, and row 99 is
the summary (FAIL if any row failed, with the row numbers). Defects found while testing it:

| Defect | Effect | Fix |
|---|---|---|
| Row 12 used `query_to_xml(q, false, false, …)`: the third argument (`tableforest`) was false, so the `/row/v` path never matched. **Pre-existing since B3.4.** | Row 12 never actually evaluated `attendance_events.source`; it showed blank instead of a result. It never caused a false FAIL, but it would not have caught a bad value either | `tableforest = true`. Negative test: a stray value `kiosk` now gives FAIL |
| Rows 7–8 read `shared_preload_libraries` / supautils settings with `current_setting(…, true)` | For a **non-superuser** (Supabase's `postgres` is one) this raises *permission denied*, so the whole script would have stopped on the hosted project | read through `pg_settings`, which only lists what the role may see |
| Rows 13, 14, 16, 17 called `has_schema_privilege('anon', …)` / `pg_has_role(…, 'authenticated', …)` | an SQL error on any database without Supabase's roles | role existence checked first; FAIL with a reason |
| Row 12 could read `attendance_events` through row level security | a role that sees only some rows could get a false PASS | reads only if the role sees every row (owner or BYPASSRLS); otherwise FAIL with a reason |
| `verify_hosted.sql` item 14 had the same `query_to_xml` argument | detail text only ("projection enabled for: …"); the item's true/false was not affected | same fix |

Test `rehearsal/test_prereqs_states.py` (local only): a Supabase-like database built up step by step. Each state is
run twice, as superuser and as a non-superuser with BYPASSRLS (like Supabase's `postgres`), with
`ON_ERROR_STOP=1`. Result **17/17**:

| State | SQL errors | FAIL rows | Row 12 | Row 21 | Summary |
|---|---|---|---|---|---|
| brand-new project (Supabase roles, auth, empty `extensions`, worst-case CREATE on public) | none | 13, 14 (expected: D5 not yet applied) | N/A | none (fresh project) | FAIL (expected) |
| the same after the D5 revoke | none | none | N/A | none | PASS |
| extensions enabled (btree_gist, pgcrypto), no migrations | none | none | N/A | none | PASS |
| 0001–0009 | none | none | PASS | 0001–0009 | PASS |
| 0001–0012 | none | none | PASS | 0001–0012 | PASS |
| 0001–0013 | none | none | PASS | 0001–0013 | PASS |
| plain PostgreSQL, no Supabase roles/schemas (extra) | none | 4, 16, 17, 20, each with a reason | N/A | none | FAIL (expected) |
| row 12 negative cases (extra) | none | stray source value → FAIL; role without read access → FAIL; row level security would hide rows → FAIL | | | |

The full rehearsal also runs the checker through the guarded runner on the fresh project, after D5, and after the
0009, 0012 and 0013 stages (§3.1).

### 0.2 Performance: not established
The slowest local call was whole-file validation of a **200,000-line** file: **3,880 ms**. Local timings were measured
on this machine, which is not Supabase Micro. They say nothing reliable about the hosted margin, and this report does
**not** claim that 3.9 s, or any figure here, is a safe production margin. The real numbers come only from the hosted
G5/G6 runs. The plan's rule applies there: any call over 4 s is reported as a design question; over 8 s (the
signed-in timeout) is a STOP. Nothing is tuned on the hosted project.

### 0.3 B3.3/B3.4 hosted suites: deferred
They are not prepared and not run. Nothing in this report claims hosted verification of B3.3/B3.4. They are
prepared later (G1b) only with your approval, and count only once their results have been reviewed.

### 0.4 Security reconfirmation (27 Nov 2026)
| Statement | Evidence |
|---|---|
| The rollback cannot run against a company database | Four independent checks, any one of which stops it before anything changes (one transaction): (1) psql variables `dev_ref` and `confirm` must be given (an SQL editor fails on the first line); (2) the database must carry the development marker for exactly that reference, and a company database has none (`dev_mark_project.sql` refuses to mark any database that already holds a company); (3) the exact phrase `REMOVE-0013-FROM-DEVELOPMENT`; (4) **new:** the database may hold only the synthetic seed (companies `dev-alpha`/`dev-beta`, employees at `attendos-dev.example`). Rehearsal guards 1–6 prove each, including guard 4 (a database without the marker) and the new guard 6 (a marked project holding a non-synthetic company) |
| No production credentials or real employee data are in the repository | The tools read credentials only from your environment; `dev.env.example` holds variable names only. Repository scan: no keys, tokens or passwords with values in connection strings; no copy of the real X2008 file (SHA-256 compared against all 22 tracked `.dat` fixtures); no device serial. All seed people are invented, at the reserved domain `attendos-dev.example` |
| No hosted migration has been executed | Every migration run was against local PostgreSQL (`/tmp/pg`, port 5433). The guard's rehearsal mode refuses any non-local host |
| No Supabase project has been created or modified | No Supabase account, CLI, API or dashboard was used; no Supabase CLI, credentials or `ATTENDOS_DEV_*` variables exist in this environment |
| No Cloudflare deployment has occurred | Deploying AttendOS is a manual `npm run deploy` (`wrangler deploy`); it was not run in this work. No Cloudflare credentials or wrangler login exist in this environment, and the branch has not been merged |

Tools: `supabase/deploy/dev_preflight/`. Owner runbook: `supabase/deploy/dev_preflight/README.md`. Plan:
`BIOMETRIC_B5_DEV_SUPABASE_PREFLIGHT_PLAN.md`.

## 1. What was prepared (G1 items 1–7)

| # | Item | Files |
|---|---|---|
| 1 | Extended prerequisite check (read-only) | `supabase/deploy/check_biometric_prereqs.sql`. New rows 13–20: CREATE on `public` for anon / authenticated / PUBLIC (D5), signed-in statement_timeout at role **or database** level, whether the migration role may act as `authenticated`, BYPASSRLS (information), pg_cron not installed, Auth schema present. Row 12 now works on a fresh project (it used to fail before 0001) |
| 2 | `verify_hosted.sql` for 0013 (read-only) | items 1 and 13 updated for 0013's tables and 15 functions; new items 15–21 (DAT tables and RLS, no API privileges incl. columns and policy, exactly the 15 checked functions, no `audit()` trigger, ownership for the F2 `ANALYZE`, D5, no pg_cron). **Two defects fixed** (§4) |
| 3 | Synthetic seed | `dev_seed_synthetic.sql`: companies `dev-alpha`, `dev-beta` ("TEST … (synthetic)"); 10 invented people at the reserved domain `attendos-dev.example`; devices: an X2008, an eSSL K21 and a ZKTeco in Alpha, an X2008 in Beta (serials `TEST-DEV-…`). No mapping; refuses to run twice or on a database that already holds companies |
| 4 | Hosted test scripts | `dat_hosted_matrix.py`: V3/V4/V5 through the real API with real sign-ins; `--scale` adds API timings. `dat_hosted_scale.py`: S1–S7, C1–C3 and the V7 boundary snapshot inside the database as signed-in users, 8 s limit; it cleans up its synthetic batches and always resets autovacuum |
| 5 | Dev-only rollback | `rollback_0013_dev_only.sql`, guarded (§2), restoring exactly the 0012 state |
| 6 | Local tests | `rehearsal/test_devguard.py` (guard unit checks); `rehearsal/local_rehearsal.py` (the whole owner sequence on a Supabase-like local stack) |
| 7 | Revised report + owner actions | this report; `README.md` (exact owner steps by gate); `dev.env.example` (variable names only) |

Supporting tools:
- `devguard.py`: the shared guard.
- `dev_sql.py`: guarded SQL runner; `--mark` writes the marker.
- `dev_mark_project.sql`, `dev_guard.sql`: the marker and the in-database guard.
- `dev_apply_migrations.py`: exact commit, SHA-256 manifest `migrations.sha256`, one transaction per migration,
  freeze (D6).
- `dev_revoke_public_create.sql` (D5) and `dev_autovacuum.sql`.
- `.gitignore`: credential files, logins files, reports and `__pycache__` can't be committed.

## 2. How "exactly the development project" is enforced

Every hosted operation passes **all** of these checks. Each layer was tested (§3).

1. **Reference format and deny list.** `ATTENDOS_DEV_PROJECT_REF` must be a Supabase reference (20 lowercase
   letters). Any reference in `ATTENDOS_FORBIDDEN_PROJECT_REFS` is refused, as is any connection string that mentions
   one.
2. **Connection names exactly that reference.** Database: host `db.<ref>.supabase.co` with user `postgres`, or a
   `*.pooler.supabase.com` host with user `postgres.<ref>`, and no other reference. API: exactly
   `https://<ref>.supabase.co`. Anon key: a JWT anon key must carry `"ref": "<ref>"` and role anon. Service-role or
   secret keys are refused. Every Auth access token must have `iss = https://<ref>.supabase.co/auth/v1`.
3. **In-database marker.**
   - `dev_mark_project.sql` writes `attendos_dev.environment_marker` (environment `development`, the reference) once,
     only on an empty project.
   - `dev_guard.sql` runs first, in the same transaction as every later script.
   - No marker, or a marker for another reference, means STOP and nothing runs.
   - Dev-only scripts (seed, rollback, revoke, autovacuum) check the marker again themselves. Pasted into a SQL editor,
     they fail on the first line.
4. **Single transaction.** A failure anywhere leaves nothing behind.
5. **Secrets.**
   - Secrets are read only from the owner's environment and local files **outside the repository** (enforced for the
     logins file and the report folder).
   - The database password goes in `PGPASSWORD`, never on a command line.
   - All output and reports pass through redaction.

## 3. Test results (all run locally on 23 Nov 2026; nothing hosted)

| Test | Result |
|---|---|
| `python3 supabase/deploy/dev_preflight/rehearsal/test_devguard.py` (no network, no database) | **24/24.** Malformed, forbidden and other-project references refused; other-project pooler user, direct host, non-Supabase host refused; rehearsal mode can't reach a hosted host; look-alike URL, other-project anon key, service-role JWT, `sb_secret_` key refused; logins file and report folder inside the repo refused; foreign token issuer refused; redaction of password, URL, keys and tokens |
| `python3 supabase/deploy/dev_preflight/rehearsal/local_rehearsal.py --commit <HEAD>` | see §3.1 |
| `npm run check` (unchanged app) | 85 tests: 84 pass, 1 skipped (real-file unit check, needs the export path) — 23 Nov and again 27 Nov |

Corrected run, 27 Nov 2026 (commit `f9ef74f`, from the repository root, local only):

| Command | Result |
|---|---|
| `python3 supabase/deploy/dev_preflight/rehearsal/test_devguard.py` | 24/24 |
| `PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres python3 supabase/deploy/dev_preflight/rehearsal/test_prereqs_states.py` | 17/17 (§0.1) |
| `PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres python3 supabase/deploy/dev_preflight/rehearsal/local_rehearsal.py --commit f9ef74f…` | 39/39 (§3.1) |
| `npm run check` | 85 tests: 84 pass, 0 fail, 1 skipped |

### 3.1 Local rehearsal of the whole owner sequence (G3–G6, rollback, freeze)

The Supabase-like local stack:
- PostgreSQL 16 with Supabase's API roles;
- **worst-case** grants: CREATE on `public` and default privileges for anon/authenticated;
- an 8 s signed-in timeout;
- the **real Supabase Auth server** (release binary), with tokens issued as `https://<fake ref>.supabase.co/auth/v1`;
- PostgREST 12 behind a gateway that, like Supabase's, serves `/auth/v1` and `/rest/v1` and requires `apikey`;
- the fake reference `attendosrehearsalabc`, migration user `postgres.attendosrehearsalabc`.

The tools ran exactly as the owner will run them.

**Result: 39/39 checks passed** (corrected run, 27 Nov 2026, on commit `f9ef74f`; 35/35 on 23 Nov before the
correction added four checks). Command, from the repository root:
`PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres python3 supabase/deploy/dev_preflight/rehearsal/local_rehearsal.py --commit $(git rev-parse HEAD) --report <file outside the repo>`

| Gate | Check | Result |
|---|---|---|
| guard | before the marker, even a read-only script is refused | pass |
| G3 | marker written for exactly the given reference; cannot be rewritten for another | pass |
| G3 | prerequisites on the fresh project: 21 rows + summary; FAIL only rows 13–14 (worst-case CREATE on `public`) | pass |
| G3 | D5 revoke, verified; prerequisites afterwards: summary PASS, no FAIL | pass |
| G4 | apply tool refuses a commit other than the checkout | pass |
| G4 | 0001–0009, then 0010–0012, then 0013, each migration in one transaction with guard + SHA-256 check; `verify_hosted.sql` all 21 items ok **and** `check_biometric_prereqs.sql` summary PASS with row 21 detecting the stage, after **each** stage | pass |
| G4 | re-running the apply tool changes nothing | pass |
| G5 | seed: 2 synthetic companies, 10 employees, 4 devices, no mapping; refuses a second run | pass |
| G5 | 8 synthetic logins (auto-confirmed, like Dashboard → Add user) link to their records via 0005 | pass |
| G5 | `dat_hosted_matrix.py --scale`: permission matrix **160/160, 0 differences**; V5 16 MiB as 64 full chunks (slowest 297 ms) and the Admin download intact (≈ 22 MB, 459 ms, SHA-256 equal) | pass |
| G5 | the API tool refuses a service-role key | pass |
| G6 | `dat_hosted_scale.py`: S1–S7, C1–C3, V7 boundary snapshot | pass |
| rollback | guard 1: plain psql without `dev_ref` (SQL-editor case) refused, nothing changed | pass |
| rollback | guard 2: marked database with another reference refused | pass |
| rollback | guard 3: right project without the exact confirmation phrase refused | pass |
| rollback | guard 4: a database **without** the marker (stand-in for pilot/production) refused even with the right reference and phrase | pass |
| rollback | guard 5: a connection string naming another project refused before connecting | pass |
| rollback | **guard 6 (new):** the marked project holding a non-synthetic company refused, even with the right reference and phrase | pass |
| rollback | removes 0013 in one transaction; the schema then **equals a fresh 0001–0012 database exactly** (tables, columns, constraints, indexes, triggers, policies, grants, function bodies); verify all ok | pass |
| re-apply | frozen 0013 (same SHA-256) applies again; verify all ok | pass |
| D6 | a recorded migration with a different SHA-256, and an edited migration file, are both refused | pass |
| secrets | no database password, JWT secret, anon/service key or test password in any of 33 reports or the output | pass |

Local timings, slowest single call (8 s signed-in limit; the plan's per-call target is ≤ 4 s). Two runs on the same
machine, to show how much local figures vary:

| Scenario | 23 Nov run | 27 Nov run |
|---|---|---|
| API, 32,000 lines by HR (23 calls) | 1,157 ms | 828 ms |
| API, 200,000 lines by HR (115 calls) | 3,006 ms | 2,463 ms |
| S1 32k, autovacuum normal (slowest: parse) | 797 ms | 1,540 ms |
| S2 32k, autovacuum off (parse) | 941 ms | 626 ms |
| S3 200k, autovacuum normal (**validate**) | **3,880 ms** | 2,642 ms |
| S4 200k, autovacuum off (validate) | 2,820 ms | 2,579 ms |
| S6 delete / housekeeping | 374 / 356 ms | 406 / 343 ms |
| S7 retention expiry (4 calls) | 414 ms | 518 ms |

These are local figures only (see §0.2): they show that the tools and calls work end to end, not hosted
performance. The slowest recorded is S3 whole-file validation at 200,000 lines (3,880 ms on 23 Nov, close to the
4 s target; 2,642 ms on 27 Nov). The same call varied by about 1.2 s between runs on the same machine. It is
the call most likely to exceed 4 s on Micro. No safe production margin is claimed; hosted G5/G6 establishes it.

## 4. Defects found and fixed during G1 (local; nothing hosted was ever affected)

| # | Where | Problem | Fix |
|---|---|---|---|
| 1 | `verify_hosted.sql`, **pre-existing since B3.4** (`9d25d12`) | item 14's detail read `public.biometric_settings` directly, so the whole script errored on a database with 0001–0009 only (the pilot runbook runs it there) | the detail reads it via `query_to_xml` only when 0012 is installed. Verified after 0009, after 0012 and after 0013 |
| 2 | `verify_hosted.sql`, my new items 15 and 19 | `'public.…'::regclass` literals are resolved at parse time, so the script errored wherever 0013 was absent (found by the rollback check) | `to_regclass(…)` |
| 3 | `check_biometric_prereqs.sql`, row 12 | read `public.attendance_events`, which doesn't exist on a fresh project (before 0001) | read only when the table exists. Further any-state defects found on 27 Nov: §0.1 |
| 4 | tooling | marker script planning on a fresh project, script lookup, result parsing, report names colliding within one second | fixed; all re-tested in the final rehearsal |

## 5. D1: expected monthly cost (for your approval before project creation)

The pilot's compute size has not been decided anywhere in the repository. My proposal: **Micro for the pilot and
therefore for the dev project** (one company, up to about 300 people). Small is the fallback if the hosted timings
miss the 4 s target. Published Supabase prices, checked 23 Nov 2026, in USD, before taxes:

| Item | Price |
|---|---|
| Pro plan (per organisation; needed to choose a compute size; Free projects are Nano and pause) | $25/month, includes $10/month compute credits |
| Micro compute (1 GB, shared) | $0.01344/hour, about $10/month |
| Small compute (2 GB, shared) | $0.0206/hour, about $15/month |
| Medium compute (4 GB) | $0.0822/hour, about $60/month |

Expected bill for the dev project:
| Situation | Micro | Small |
|---|---|---|
| dev is the only project in a new Pro organisation | **$25/month** ($25 + $10 − $10 credit) | $30/month ($25 + $15 − $10) |
| dev added to a Pro organisation that already runs another project (e.g. the pilot) | +$10/month while it exists | +$15/month |
| compute only, if the dev project is deleted after about 2 weeks (compute is billed hourly) | about $4.50 | about $7 |

- The tests stay far inside the Pro quotas (8 GB disk, 250 GB egress).
- Taxes (for example GST on an Indian billing address) and currency conversion come on top.
- Confirm the figure in the dashboard's cost estimate when creating the project.

Sources: supabase.com/pricing; supabase.com/docs/guides/platform/manage-your-usage/compute.

## 6. Remaining risks (what the local rehearsal cannot prove)

1. **Supabase is not the local stand-in.**
   - Locally the migration role is a superuser. On Supabase, `postgres` isn't, and supautils restricts some actions.
     Row 17 (may it act as `authenticated`), item 19 (does it own the rows table, so the F2 `ANALYZE` is allowed) and
     the migrations themselves will show this at G3/G4.
   - If row 17 is false, `dat_hosted_scale.py` cannot run as designed. The API-level timings
     (`dat_hosted_matrix.py --scale`) would remain, and the next step would be your decision.
2. **Gateway limits.** Supabase's real API gateway may limit request or response size differently from the local
   gateway. V5 (full chunks, 16 MiB download) tests exactly this at G5.
3. **Hosted performance is unknown.** Micro is a 1 GB shared instance, and the local machine was faster. The plan's
   stop rule applies: any call over 4 s is reported as a design question; over 8 s is a STOP.
4. **Trust on first use of the marker.** The marker is only as right as the reference you confirm in the dashboard
   at G2 step 4. Layers 1–2 then keep every later step on that project.
5. **Publishable keys.** If the project issues `sb_publishable_…` keys instead of a JWT anon key, the key carries no
   `ref` claim. The URL check and the token-issuer check still apply.
6. **Connections.** Use the **Session** pooler. The tools rely on session settings (role and JWT claims), which the
   Transaction pooler does not keep. The direct host is IPv6-only on Supabase.
7. **B3.3/B3.4 hosted suites (D7): deferred, not prepared, not run** (§0.3). The existing HTTP suites read the
   database directly, sign tokens with the local secret, and (gateway) read server logs. Adapting them is G1b, only
   with your approval. No hosted B3.3/B3.4 verification is claimed.
9. **Hosted performance is not established** (§0.2). Local figures are not a production margin.
8. **Unchanged by design.**
   - `audit_log` entries written by 0013 stay after a dev rollback (append-only).
   - The two pre-existing test failures (B3.3 intermittent key-audit check; B4 Sunday timeline) are unchanged.

## 7. Exact owner commands (only after the matching gate is approved; details in the README)

Run on your own computer, in a terminal. `<approved-commit>` is the commit you approve; `<ref>` is the project's
Reference ID. **Any STOP, any unexpected FAIL, or any permission difference: stop, share the redacted report from
`~/attendos-dev-reports/`, do nothing further.**

**Before G2: one-time setup (no Supabase contact)**
```sh
git clone https://github.com/littlegasp/AttendOS.git attendos && cd attendos   # or: cd <your clone> && git fetch
git checkout <approved-commit>
git status                                   # must say: nothing to commit, working tree clean
psql --version                               # 15 or newer
python3 --version                            # 3.11 or newer
python3 -m pip install --user "psycopg[binary]"
cp supabase/deploy/dev_preflight/dev.env.example ~/.attendos-dev.env
chmod 600 ~/.attendos-dev.env
python3 supabase/deploy/dev_preflight/rehearsal/test_devguard.py   # must end: 24/24 guard checks passed
```

**G2: create the project in the Supabase dashboard (needs your approval and the D1 cost decision)**
- New project `attendos-dev`, region South Asia (Mumbai), compute as approved. Strong database password, kept in
  your password manager.
- Note the Reference ID (Project Settings → General).
- Database → Extensions: `btree_gist` is listed. Do not enable `pg_cron`.
- Authentication: Email provider on, Confirm email on, **Allow new users to sign up off**, no hooks.
- Edit `~/.attendos-dev.env` (an editor, never chat): the Reference ID, the **Session pooler** connection string,
  `https://<ref>.supabase.co`, the anon/publishable key, `ATTENDOS_DEV_LOGINS_FILE=~/.attendos-dev-logins.json`, and
  `ATTENDOS_FORBIDDEN_PROJECT_REFS` with every other project reference you have.
```sh
set -a; . ~/.attendos-dev.env; set +a
cd supabase/deploy/dev_preflight
python3 devguard.py                          # must print: database guard ok for project <ref>
```

**G3: marker, prerequisites, D5**
```sh
python3 dev_sql.py --mark                                  # shows: development | <ref>
python3 dev_sql.py check_biometric_prereqs.sql             # FAIL only in rows 13-14 allowed; row 15 FAIL = STOP
python3 dev_sql.py dev_revoke_public_create.sql            # only if row 13 or 14 is FAIL
python3 dev_sql.py check_biometric_prereqs.sql             # row 99 must be PASS
```

**G4: migrations in three stages, both checks after each**
```sh
python3 dev_apply_migrations.py --commit <approved-commit> --through 0009
python3 dev_sql.py verify_hosted.sql                       # every item t
python3 dev_sql.py check_biometric_prereqs.sql             # row 99 PASS, row 21 0001–0009
python3 dev_apply_migrations.py --commit <approved-commit> --through 0012
python3 dev_sql.py verify_hosted.sql
python3 dev_sql.py check_biometric_prereqs.sql             # row 21 0001–0012
python3 dev_apply_migrations.py --commit <approved-commit>
python3 dev_sql.py verify_hosted.sql
python3 dev_sql.py check_biometric_prereqs.sql             # row 21 0001–0013
```

**G5: synthetic data, logins, API checks**
```sh
python3 dev_sql.py dev_seed_synthetic.sql
```
- Dashboard → Authentication → Users → Add user → Create new user, "Auto Confirm User", for `a.admin@`,
  `a.admin2@`, `a.hr@`, `a.manager@`, `a.employee@`, `b.admin@`, `b.hr@`, `b.employee@` (all at
  `attendos-dev.example`), each with a long random password.
- Write `~/.attendos-dev-logins.json` in the README's format.
```sh
chmod 600 ~/.attendos-dev-logins.json
python3 dat_hosted_matrix.py --scale                       # must end: ALL API CHECKS PASSED
```

**G6: performance inside the database**
```sh
python3 dat_hosted_scale.py                                # must end: ALL DB-LEVEL CHECKS PASSED
```

B3.3/B3.4 hosted suites: deferred (§0.3); nothing to run.

## 8. Decisions needed before G2
1. **D1 cost:** approve the dev project at **Micro**, about **$25/month** if it's the organisation's only project (or
   +$10/month next to another), and confirm Micro as the intended pilot size. Or choose Small (about $30 / +$15).
2. **G1b (deferred by you, 27 Nov):** when you want them, approve preparing hosted versions of the B3.3/B3.4 HTTP
   suites (synthetic data only). Until then they are neither run nor claimed.
3. **G2 go-ahead:** you create the project and fill your local environment. I do nothing on it until you share the
   first report.

## 9. Commit
G1 is the range after `1df5e8f` on `feature/biometric-b1`: `149d3bc` … `6a5cb21` (23 Nov), then the correction
`1a2ba2e`, `f9ef74f` and the commit that updates this report (27 Nov; its hash is in the handover message and
`git log`). The rehearsal results above were produced on `f9ef74f`; the last commit changes documentation only. Nothing in the range is merged, tagged or
deployed. Earlier commits were not rewritten.
