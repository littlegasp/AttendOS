# Development-Supabase preflight: G1 local preparation report

Status: **G1 complete, local only, awaiting owner approval before G2.**
- Date: 23 Nov 2026. Branch `feature/biometric-b1`. Commit: see §9.
- Authorisation used: *G1 local preparation only* (owner, 23 Nov 2026), with D1–D7 as approved.
- **Not done, by instruction:** no Supabase project was created or contacted, no hosted SQL or migration was run, and
  no production credentials or connection strings were used. Also no real employee data, X2008 export or mapping; no
  pg_cron, projection or Cloudflare deployment; no merge, tag or force-push.

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
| `npm run check` (unchanged app) | 85 tests: 84 pass, 1 skipped (real-file unit check, needs the export path) |

### 3.1 Local rehearsal of the whole owner sequence (G3–G6, rollback, freeze)

The Supabase-like local stack:
- PostgreSQL 16 with Supabase's API roles;
- **worst-case** grants: CREATE on `public` and default privileges for anon/authenticated;
- an 8 s signed-in timeout;
- the **real Supabase Auth server** (release binary), with tokens issued as `https://<fake ref>.supabase.co/auth/v1`;
- PostgREST 12 behind a gateway that, like Supabase's, serves `/auth/v1` and `/rest/v1` and requires `apikey`;
- the fake reference `attendosrehearsalabc`, migration user `postgres.attendosrehearsalabc`.

The tools ran exactly as the owner will run them.

**Result: 35/35 checks passed** (final run on the G1 commit; report kept outside the repository).

| Gate | Check | Result |
|---|---|---|
| guard | before the marker, even a read-only script is refused | pass |
| G3 | marker written for exactly the given reference; cannot be rewritten for another | pass |
| G3 | prerequisites flag only rows 13–14 (worst-case CREATE on `public`) and 6–7 (pg_cron, not needed yet) | pass |
| G3 | D5 revoke, verified; prerequisites afterwards flag only 6–7 | pass |
| G4 | apply tool refuses a commit other than the checkout | pass |
| G4 | 0001–0009, then 0010–0012, then 0013, each migration in one transaction with guard + SHA-256 check; `verify_hosted.sql` all 21 items ok after **each** stage | pass |
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
| rollback | removes 0013 in one transaction; the schema then **equals a fresh 0001–0012 database exactly** (tables, columns, constraints, indexes, triggers, policies, grants, function bodies); verify all ok | pass |
| re-apply | frozen 0013 (same SHA-256) applies again; verify all ok | pass |
| D6 | a recorded migration with a different SHA-256, and an edited migration file, are both refused | pass |
| secrets | no database password, JWT secret, anon/service key or test password in any of 29 reports or the output | pass |

Local timings (8 s signed-in limit; the plan's targets are ≤ 4 s per call):

| Scenario | Slowest call |
|---|---|
| API, 32,000 lines by HR (23 calls) | 1,157 ms |
| API, 200,000 lines by HR (115 calls) | 3,006 ms |
| S1 32k, autovacuum normal | parse 797 ms |
| S2 32k, autovacuum off | parse 941 ms |
| S3 200k, autovacuum normal | **validate 3,880 ms** |
| S4 200k, autovacuum off | validate 2,820 ms |
| S6 delete / housekeeping | 374 ms / 356 ms |
| S7 retention expiry (4 calls) | 414 ms |

All within 4 s locally, but S3's whole-file validation at 200,000 lines is the closest (3.9 s). On Micro this
call is the one most likely to exceed 4 s; per the plan that is reported as a design question, not fixed on the
hosted project.

## 4. Defects found and fixed during G1 (local; nothing hosted was ever affected)

| # | Where | Problem | Fix |
|---|---|---|---|
| 1 | `verify_hosted.sql`, **pre-existing since B3.4** (`9d25d12`) | item 14's detail read `public.biometric_settings` directly, so the whole script errored on a database with 0001–0009 only (the pilot runbook runs it there) | the detail reads it via `query_to_xml` only when 0012 is installed. Verified after 0009, after 0012 and after 0013 |
| 2 | `verify_hosted.sql`, my new items 15 and 19 | `'public.…'::regclass` literals are resolved at parse time, so the script errored wherever 0013 was absent (found by the rollback check) | `to_regclass(…)` |
| 3 | `check_biometric_prereqs.sql`, row 12 | read `public.attendance_events`, which doesn't exist on a fresh project (before 0001) | read only when the table exists |
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
7. **B3.3/B3.4 hosted suites (D7): not prepared.** The existing HTTP suites read the database directly, sign tokens
   with the local secret, and (gateway) read server logs. Adapting them for hosted use is extra preparation, proposed
   as **G1b**. It is not part of the seven G1 items you authorised.
8. **Unchanged by design.**
   - `audit_log` entries written by 0013 stay after a dev rollback (append-only).
   - The two pre-existing test failures (B3.3 intermittent key-audit check; B4 Sunday timeline) are unchanged.

## 7. Exact owner actions (details in `supabase/deploy/dev_preflight/README.md`)

**Before G2, on your computer:**
- `psql` 15+, Python 3.11+, `pip install "psycopg[binary]"`.
- This repository at the approved commit, `git status` clean.
- `~/.attendos-dev.env` copied from `dev.env.example`, `chmod 600`.

**G2 (needs your approval; cost first):**
- Create `attendos-dev` in Mumbai at the approved compute.
- Note the Reference ID.
- Confirm `btree_gist` is available; do not enable `pg_cron`.
- Auth: email on, confirm on, sign-ups off, no hook.
- Fill `~/.attendos-dev.env`, load it, then run `python3 devguard.py`.

**G3:**
- `python3 dev_sql.py --mark`
- `python3 dev_sql.py check_biometric_prereqs.sql`
- if rows 13–14 are false: `python3 dev_sql.py dev_revoke_public_create.sql`, then the check again
- row 15 false = STOP

**G4:**
- `python3 dev_apply_migrations.py --commit <approved> --through 0009`, then `verify_hosted.sql`
- the same `--through 0012`, then `verify_hosted.sql`
- the same `--through 0013`, then `verify_hosted.sql`
- every item must be `t`

**G5:**
- `python3 dev_sql.py dev_seed_synthetic.sql`
- create the 8 test logins (Dashboard → Add user → Auto confirm)
- write `~/.attendos-dev-logins.json` (`chmod 600`)
- `python3 dat_hosted_matrix.py --scale`

**G6:** `python3 dat_hosted_scale.py`

**After each step:** share the redacted report file from `~/attendos-dev-reports/`. Any STOP or FAIL: do nothing
further.

## 8. Decisions needed before G2
1. **D1 cost:** approve the dev project at **Micro**, about **$25/month** if it's the organisation's only project (or
   +$10/month next to another), and confirm Micro as the intended pilot size. Or choose Small (about $30 / +$15).
2. **G1b:** prepare hosted versions of the B3.3/B3.4 HTTP suites (D7), synthetic data only, before G5. Or run G2–G6
   without them and add them later.
3. **G2 go-ahead:** you create the project and fill your local environment. I do nothing on it until you share the
   first report.

## 9. Commit
G1 is the range after `1df5e8f` on `feature/biometric-b1`, starting at `149d3bc` and ending with the commit that
adds this report (its hash is in the handover message and `git log`). Nothing in the range is merged, tagged or
deployed. Earlier commits were not rewritten.
