"""Apply AttendOS migrations 0001–0013 to the DEVELOPMENT Supabase project only (owner-run, Option A).

  python3 dev_apply_migrations.py --commit <approved commit> [--through 0012]

Refuses unless:
  * the connection names exactly ATTENDOS_DEV_PROJECT_REF (devguard) and the database carries its development marker
    (dev_guard.sql runs inside every migration's transaction);
  * this checkout is exactly the approved commit, and the migration files are unchanged from it;
  * every migration file's SHA-256 equals migrations.sha256 (the reviewed manifest).
Each migration runs in ONE transaction together with the guard and its record in attendos_dev.applied_migrations;
a failure leaves that migration entirely unapplied and stops the run (nothing later is attempted).
Already-applied migrations are skipped only if their recorded SHA-256 is identical. A recorded migration whose file
has changed is refused: once applied on the development project a migration is frozen (owner decision D6) — any
change must come as a new numbered migration.
"""
import argparse
import datetime
import hashlib
import subprocess
import sys
from pathlib import Path

import devguard as g

MANIFEST = Path(g.here("migrations.sha256"))


def manifest():
    out = []
    for line in MANIFEST.read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            h, name = line.split()
            out.append((name, h))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", required=True, help="the owner-approved commit (full or short hash)")
    ap.add_argument("--through", default="0013", help="apply up to this migration number")
    a = ap.parse_args()
    try:
        ref, env = g.db_env()
    except g.Stop as e:
        print(e)
        return 2
    log = g.Log(f"{datetime.datetime.now():%Y%m%d-%H%M%S-%f}-apply-migrations.txt")
    log(f"AttendOS dev preflight · apply migrations · project {ref}")
    head = subprocess.run(["git", "-C", str(g.REPO), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    want = subprocess.run(["git", "-C", str(g.REPO), "rev-parse", a.commit], capture_output=True, text=True).stdout.strip()
    if not want or head != want:
        log(f"STOP: this checkout is {head[:12]}, not the approved commit {a.commit}")
        return 2
    dirty = subprocess.run(["git", "-C", str(g.REPO), "status", "--porcelain", "--", "supabase/migrations", str(MANIFEST)],
                           capture_output=True, text=True).stdout.strip()
    if dirty:
        log("STOP: migration files or the manifest differ from the approved commit:\n" + dirty)
        return 2
    plan = [(n, h) for (n, h) in manifest() if Path(n).name[:4] <= a.through]
    for name, h in plan:
        actual = hashlib.sha256((g.REPO / name).read_bytes()).hexdigest()
        if actual != h:
            log(f"STOP: {name} does not match the manifest")
            return 2
    log(f"commit {head[:12]}; {len(plan)} migrations through {a.through}; every file matches the manifest")
    rc, out = g.psql(env, ["-At", "-v", f"dev_ref={ref}", "-f", g.here("dev_guard.sql"),
                           "-c", "select 'APPLIED:' || coalesce(string_agg(file || ' ' || sha256, ',' order by file), '') from attendos_dev.applied_migrations"])
    if rc != 0:
        log(out)
        log("STOP: the guard refused this database (see above)")
        return 2
    applied = {}
    last = next((ln[len("APPLIED:"):] for ln in out.splitlines() if ln.startswith("APPLIED:")), None)
    if last is None:
        log("STOP: could not read the list of applied migrations")
        return 2
    for item in filter(None, last.split(",")):
        f, s = item.split(" ")
        applied[f] = s
    for name, h in plan:
        base = Path(name).name
        if base in applied:
            if applied[base] != h:
                log(f"STOP: {base} was applied with a different SHA-256 — applied migrations are frozen; use a new numbered migration")
                return 2
            log(f"skip {base} (already applied, identical)")
            continue
        log(f"apply {base} …")
        t0 = datetime.datetime.now()
        rc, out = g.psql(env, ["-q", "--single-transaction", "-v", f"dev_ref={ref}", "-f", g.here("dev_guard.sql"), "-f", str(g.REPO / name),
                               "-c", f"insert into attendos_dev.applied_migrations (file, sha256, git_commit) values ('{base}', '{h}', '{head}')"])
        for line in out.strip().splitlines():
            if line.strip():
                log("   " + line)
        if rc != 0:
            log(f"STOP: {base} failed — nothing of it was applied (one transaction). Later migrations were not attempted.")
            return 3
        log(f"   ok ({(datetime.datetime.now() - t0).total_seconds():.1f} s)")
    log(f"done. report: {log.path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
