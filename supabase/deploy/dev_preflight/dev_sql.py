"""Run SQL files on the AttendOS DEVELOPMENT Supabase project only (owner-run, Option A).

  python3 dev_sql.py --mark                         # once: write the development marker (dev_mark_project.sql)
  python3 dev_sql.py FILE.sql [FILE2.sql …] [-v name=value …]

What it does, in order:
  1. devguard.db_env(): the connection string must name exactly ATTENDOS_DEV_PROJECT_REF (and no forbidden reference);
  2. runs psql with ON_ERROR_STOP and --single-transaction: dev_guard.sql first (the database must carry the
     development marker for that reference), then the given files — if anything fails, nothing is committed;
  3. prints the output, redacted, and keeps a copy in the report folder (outside the repository).
The password is passed in PGPASSWORD, never on a command line; nothing secret is printed.
"""
import argparse
import datetime
import sys
from pathlib import Path

import devguard as g


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--mark", action="store_true", help="write the development marker (once, on a new empty project)")
    ap.add_argument("-v", "--var", action="append", default=[], help="psql variable name=value")
    a = ap.parse_args()
    try:
        ref, env = g.db_env()
    except g.Stop as e:
        print(e)
        return 2
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    names = ["mark"] if a.mark else [Path(f).stem for f in a.files]
    log = g.Log(f"{stamp}-sql-{'-'.join(names)[:80]}.txt")
    log(f"AttendOS dev preflight · project {ref} · {datetime.datetime.now().isoformat(timespec='seconds')}")
    if not a.mark and not a.files:
        log("STOP: no file given")
        return 2
    args = ["--single-transaction", "-v", f"dev_ref={ref}"]
    for v in a.var:
        if "=" not in v:
            log(f"STOP: bad variable {v}")
            return 2
        args += ["-v", v]
    if a.mark:
        args += ["-f", g.here("dev_mark_project.sql")]
    else:
        args += ["-f", g.here("dev_guard.sql")]
        for f in a.files:
            p = Path(f).resolve()
            for cand in (Path(f), Path(g.here(f)), Path(g.here("..", f))):   # bare names: this folder, then supabase/deploy
                if cand.is_file():
                    p = cand.resolve()
                    break
            if not p.is_file():
                log(f"STOP: no such file {f}")
                return 2
            args += ["-f", str(p)]
    log("files: " + ", ".join(["dev_mark_project.sql"] if a.mark else ["dev_guard.sql"] + [Path(f).name for f in a.files]))
    rc, _ = g.psql(env, args, log)
    log(f"psql exit status {rc} — {'committed' if rc == 0 else 'NOTHING COMMITTED (single transaction)'}")
    log(f"report: {log.path}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
