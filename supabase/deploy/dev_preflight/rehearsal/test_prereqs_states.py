"""LOCAL test: check_biometric_prereqs.sql gives clear results, and never an SQL error, in every database state.

States (one Supabase-like database, built up step by step the way the owner's project will be):
  A   brand-new project: API roles, auth schema, empty "extensions" schema, worst-case CREATE on public; no extensions,
      no AttendOS objects
  A2  the same after the D5 revoke (dev_revoke_public_create.sql's statement)
  B   extensions enabled (btree_gist, pgcrypto in "extensions"), AttendOS migrations absent
  C   migrations 0001–0009 applied
  D   migrations 0001–0012 applied
  E   migrations 0001–0013 applied
plus BARE: a plain PostgreSQL database with none of Supabase's roles or schemas (all relevant rows must FAIL cleanly).

In every state the script is run twice: as the local superuser and as a NON-superuser login role (like Supabase's
postgres, which is not a superuser). Each run must exit 0 (ON_ERROR_STOP=1), print rows 1–21 plus the summary row 99,
use only PASS / FAIL / N/A / INFO, and match the expected FAIL set and the expected row-12 / row-21 results.

  PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres python3 supabase/deploy/dev_preflight/rehearsal/test_prereqs_states.py \
      [--auth-dir /home/claude/tools/gotrue] [--report FILE]
Touches no hosted system: local socket only; the test databases are dropped at the end.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import local_rehearsal as L   # noqa: E402  (build_db, sh, psql, PG — the same Supabase-like stand-in)

CHECK = L.REPO / "supabase/deploy/check_biometric_prereqs.sql"
MIG = sorted((L.REPO / "supabase/migrations").glob("00*.sql"))
DB, BARE = "attendos_prereq_states", "attendos_prereq_bare"
NONSU = "attendos_prereq_nonsuper"
VALID = {"PASS", "FAIL", "N/A", "INFO"}
out, results = [], []


def log(s):
    print(s, flush=True)
    out.append(s)


def check(ok, what):
    results.append(bool(ok))
    log(("PASS " if ok else "FAIL ") + what)


def run_checker(db, user):
    r = L.sh(["psql", "-X", "-q", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-d", db, "-f", str(CHECK)], {"PGUSER": user})
    rows = {}
    for line in r.stdout.splitlines():
        f = line.split("\t")
        if len(f) == 5 and f[0].isdigit():
            rows[int(f[0])] = (f[2], f[3])
    return r, rows


def apply(db, files):
    for f in files:
        r = L.sh(["psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "--single-transaction", "-d", db, "-f", str(f)])
        if r.returncode:
            raise SystemExit(f"setup: {f.name} failed: {r.stderr[-400:]}")


def state(name, db, fails, row12, row21_has):
    for user in (L.PG["PGUSER"], NONSU):
        who = "superuser" if user == L.PG["PGUSER"] else "non-superuser"
        r, rows = run_checker(db, user)
        got_fail = {n for n, (res, _) in rows.items() if res == "FAIL" and n != 99}
        bad = {n: res for n, (res, _) in rows.items() if res not in VALID}
        ok = (r.returncode == 0 and "ERROR" not in r.stderr and set(rows) == set(range(1, 22)) | {99} and not bad
              and got_fail == fails and rows[12][0] == row12 and row21_has in rows[21][1]
              and rows[99][0] == ("FAIL" if fails else "PASS"))
        detail = "" if ok else f" — exit {r.returncode}, stderr {r.stderr.strip()[:300]!r}, rows {sorted(rows)}, invalid {bad}, " \
                               f"FAIL {sorted(got_fail)} (expected {sorted(fails)}), row 12 {rows.get(12)}, row 21 {rows.get(21)}"
        check(ok, f"{name} [{who}]: no SQL error; rows 1–21 + summary; FAIL = {sorted(fails) or 'none'}; row 12 {row12}; "
                  f"summary {rows.get(99, ('?', '?'))[0]} ({rows.get(99, ('?', '?'))[1]}){detail}")
        if user == L.PG["PGUSER"]:
            out.append("      " + " | ".join(f"{n}:{res}" for n, (res, _) in sorted(rows.items())))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--auth-dir", default="/home/claude/tools/gotrue")
    ap.add_argument("--report")
    a = ap.parse_args()
    try:
        L.psql("postgres", f"""do $$ begin if not exists (select 1 from pg_roles where rolname = '{NONSU}')
                 then create role {NONSU} login nosuperuser; end if; end $$""")
        # like Supabase's postgres: not a superuser, but BYPASSRLS (set explicitly, the role may be left from a run)
        L.psql("postgres", f"alter role {NONSU} nosuperuser bypassrls")
        # ---- BARE: plain PostgreSQL, nothing from Supabase
        L.sh(["dropdb", "--if-exists", "--force", BARE]); L.sh(["createdb", BARE])
        L.psql(BARE, f"grant create on database {BARE} to {NONSU}")
        # roles are cluster-wide; on this local cluster anon/authenticated may exist from other tests, so BARE is
        # judged on the database-level rows only (extensions schema, auth.users, timeout setting for this database)
        r, rows = run_checker(BARE, NONSU)
        check(r.returncode == 0 and "ERROR" not in r.stderr and all(rows[n][0] == "FAIL" for n in (4, 16, 20))
              and rows[12][0] == "N/A" and rows[99][0] == "FAIL",
              f"BARE plain PostgreSQL [non-superuser]: no SQL error; rows 4, 16, 20 FAIL with a reason; row 12 N/A; summary "
              f"{rows.get(99, ('?', '?'))}")
        out.append("      " + " | ".join(f"{n}:{res}" for n, (res, _) in sorted(rows.items())))

        # ---- the Supabase-like project, state by state
        L.build_db(DB, a.auth_dir)
        L.psql(DB, f"grant create on database {DB} to {NONSU}; grant usage on schema auth to {NONSU}; grant authenticated to {NONSU}")
        state("A  brand-new project (worst-case grants)", DB, {13, 14}, "N/A", "none (fresh project)")
        L.psql(DB, "revoke create on schema public from anon, authenticated")
        state("A2 brand-new project after the D5 revoke", DB, set(), "N/A", "none (fresh project)")
        L.psql(DB, "create extension btree_gist schema extensions; create extension pgcrypto schema extensions")
        state("B  extensions enabled, no AttendOS migrations", DB, set(), "N/A", "none (fresh project)")
        apply(DB, [f for f in MIG if f.name < "0010"])
        # Supabase's postgres owns what it migrated and has BYPASSRLS; the non-superuser stand-in gets read access
        L.psql(DB, f"grant usage on schema public to {NONSU}; grant select on public.attendance_events to {NONSU}")
        state("C  migrations 0001–0009", DB, set(), "PASS", "0001–0009")
        apply(DB, [f for f in MIG if "0010" <= f.name < "0013"])
        state("D  migrations 0001–0012", DB, set(), "PASS", "0001–0012")
        apply(DB, [f for f in MIG if f.name.startswith("0013")])
        state("E  migrations 0001–0013", DB, set(), "PASS", "0001–0013")
        # negative case for row 12: a source value other than web/correction/biometric/import must FAIL (0012's
        # preflight rule), as a result row, not an SQL error. Minimal stand-in table on the BARE database.
        L.psql(BARE, "create table public.attendance_events (source text); insert into public.attendance_events values ('web'), ('kiosk')")
        r, rows = run_checker(BARE, L.PG["PGUSER"])
        check(r.returncode == 0 and rows[12][0] == "FAIL" and "kiosk 1" in rows[12][1],
              f"row 12 negative case: an unexpected source value is reported as FAIL ({rows.get(12)})")
        r, rows = run_checker(BARE, NONSU)
        check(r.returncode == 0 and "ERROR" not in r.stderr and rows[12][0] == "FAIL" and "cannot see" in rows[12][1],
              f"row 12: a role that cannot read the table gets FAIL with a reason, not an SQL error ({rows.get(12)})")
        L.psql(BARE, f"grant select on public.attendance_events to {NONSU}; alter role {NONSU} nobypassrls; "
                     "alter table public.attendance_events enable row level security")
        r, rows = run_checker(BARE, NONSU)
        check(r.returncode == 0 and rows[12][0] == "FAIL" and "cannot see" in rows[12][1],
              f"row 12: a role that row level security would limit is not given a partial PASS ({rows.get(12)})")
        L.psql("postgres", f"alter role {NONSU} bypassrls")
    finally:
        for d in (DB, BARE):
            L.sh(["dropdb", "--if-exists", "--force", d])
        check(not any(L.psql("postgres", f"select count(*) from pg_database where datname = '{d}'") != "0" for d in (DB, BARE)),
              "cleanup: both test databases dropped")
    n = sum(results)
    log(f"{n}/{len(results)} prerequisite-state checks passed")
    if a.report:
        Path(a.report).write_text("\n".join(out) + "\n")
    sys.exit(0 if n == len(results) else 1)


if __name__ == "__main__":
    main()
