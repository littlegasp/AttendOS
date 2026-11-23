"""AttendOS development preflight — G6 performance, retry, deletion, retention and concurrency (S1–S7, C1–C3) plus the
B5 boundary snapshot (V7), measured INSIDE the development database through the guarded connection.

  python3 dat_hosted_scale.py

Owner-run (Option A), DEVELOPMENT project only. devguard checks the connection names exactly
ATTENDOS_DEV_PROJECT_REF; every connection then runs the same marker check as dev_guard.sql before any statement.
Each test call runs as a signed-in synthetic user (role authenticated + that user's id), exactly like the API, with
statement_timeout 8 s. Files are generated here (synthetic, 2030 dates). For S2/S4 it switches autovacuum off for
public.biometric_import_rows and always switches it back (finally). The batches it creates are removed at the end.
Prerequisites: 0001–0013 applied, verify_hosted.sql all ok, dev_seed_synthetic.sql run, and the logins for
a.admin@, a.admin2@ and a.hr@attendos-dev.example created and confirmed (so they are linked to their records).
"""
import base64
import datetime
import hashlib
import sys
import threading
import time

import psycopg

import devguard as g

CHUNK = 262144
GUARD = """
do $$
declare want text := current_setting('attendos.dev_ref', true); m record;
begin
  if want is null or want !~ '^[a-z]{20}$' or to_regclass('attendos_dev.environment_marker') is null then
    raise exception 'STOP: not the AttendOS development project';
  end if;
  select * into m from attendos_dev.environment_marker;
  if m.environment <> 'development' or m.project_ref <> want then
    raise exception 'STOP: this database is marked for project %, not %', m.project_ref, want;
  end if;
end $$"""
BOUNDARY = """select md5(coalesce((select string_agg(md5(x::text), ',' order by x::text) from public.attendance_events x), '') || '|' ||
  coalesce((select string_agg(md5(x::text), ',' order by x::text) from public.biometric_raw_events x), '') || '|' ||
  coalesce((select string_agg(md5(x::text), ',' order by x::text) from public.biometric_event_state x), '') || '|' ||
  coalesce((select string_agg(md5(x::text), ',' order by x::text) from public.biometric_sync_runs x), '') || '|' ||
  coalesce((select string_agg(md5(x::text), ',' order by x::text) from public.biometric_event_reviews x), '') || '|' ||
  coalesce((select string_agg(md5(x::text), ',' order by x::text) from public.biometric_employee_mappings x), ''))"""


class Ctx:
    def __init__(self):
        self.ref, env = g.db_env()
        self.kw = dict(host=env["PGHOST"], port=env["PGPORT"], user=env["PGUSER"], dbname=env["PGDATABASE"],
                       password=env.get("PGPASSWORD"), sslmode=env.get("PGSSLMODE", "prefer"), application_name="attendos-dev-preflight")
        self.log = g.Log(f"{datetime.datetime.now():%Y%m%d-%H%M%S-%f}-dat-hosted-scale.txt")
        self.fails = []
        self.created = []

    def conn(self, autocommit=True):
        c = psycopg.connect(autocommit=autocommit, **self.kw)
        c.execute("select set_config('attendos.dev_ref', %s, false)", (self.ref,))
        c.execute(GUARD)
        if not autocommit:
            c.commit()
        return c

    def owner(self):
        return self.conn()

    def user(self, uid, timeout="8s", autocommit=True):
        c = self.conn(autocommit)
        c.execute("set role authenticated")
        c.execute("select set_config('request.jwt.claim.sub', %s, false), set_config('request.jwt.claims', %s, false)",
                  (uid, '{"sub": "%s", "role": "authenticated"}' % uid))
        c.execute(f"set statement_timeout = '{timeout}'")
        if not autocommit:
            c.commit()
        return c

    def check(self, ok, what):
        self.log(("PASS " if ok else "FAIL ") + what)
        if not ok:
            self.fails.append(what)


def rpc(c, fn, *args):
    t0 = time.perf_counter()
    r = c.execute(f"select public.{fn}({', '.join(['%s'] * len(args))})", args).fetchone()[0]
    return r, (time.perf_counter() - t0) * 1000


def make_file(n, seed):
    t = datetime.datetime(2030, 1, 1, 8, 0, 0)
    return "".join(f"{str(i % 400 + 1):>9}\t{(t + datetime.timedelta(seconds=37 * i + seed)).strftime('%Y-%m-%d %H:%M:%S')}\t1\t255\t1\t0\r\n"
                   for i in range(n)).encode()


def upload(x, c, dev, raw):
    chunks = [raw[i:i + CHUNK] for i in range(0, len(raw), CHUNK)]
    r, ms = rpc(c, "biometric_dat_begin", dev, "Asia/Kolkata", len(raw), hashlib.sha256(raw).hexdigest(), [hashlib.sha256(y).hexdigest() for y in chunks])
    if not r.get("ok"):
        raise g.Stop(f"begin refused: {r}")
    bid, tok, times = r["batch_id"], r["upload_token"], [ms]
    g.secret(tok)
    x.created.append(bid)
    for i, y in enumerate(chunks):
        r, ms = rpc(c, "biometric_dat_chunk", bid, tok, i, base64.b64encode(y).decode())
        if not r.get("ok"):
            raise g.Stop(f"chunk refused: {r}")
        times.append(ms)
    r, ms = rpc(c, "biometric_dat_finish", bid, tok)
    if r.get("state") != "uploaded":
        raise g.Stop(f"finish refused: {r}")
    times.append(ms)
    return bid, times


def process(c, bid, stop_after=None):
    ph = {"validate": [], "parse": [], "classify": []}
    calls = 0
    while True:
        st = c.execute("select public.biometric_dat_status(%s) ->> 'state'", (bid,)).fetchone()[0]
        if st in ("ready_for_review", "failed") or (stop_after and calls >= stop_after):
            return st, ph
        _, ms = rpc(c, "biometric_dat_process", bid)
        ph[{"uploaded": "validate", "parsing": "parse", "classifying": "classify"}[st]].append(ms)
        calls += 1


def verify(x, bid, n):
    with x.owner() as o:
        r = o.execute("select count(*), count(distinct line_no), count(*) filter (where dup_class is null and parse_status <> 'blank'), "
                      "(select state from public.biometric_import_batches where id = %s), (select (counts ->> 'lines')::int from public.biometric_import_batches where id = %s) "
                      "from public.biometric_import_rows where batch_id = %s", (bid, bid, bid)).fetchone()
    return r == (n, n, 0, "ready_for_review", n), r


def summary(ts):
    return f"{len(ts)} calls, max {max(ts):.0f} ms, total {sum(ts) / 1000:.1f} s" if ts else "0 calls"


def remove_created(x):
    if x.created:
        with x.owner() as o:
            o.execute("delete from public.biometric_import_batches where id = any(%s::uuid[])", (x.created,))
        x.created.clear()


def main():
    try:
        x = Ctx()
    except g.Stop as e:
        print(e)
        return 2
    log = x.log
    try:
        with x.owner() as o:
            log(f"AttendOS dev preflight · DB-level scale · project {x.ref} · {datetime.datetime.now().isoformat(timespec='seconds')}")
            ver = o.execute("show server_version").fetchone()[0]
            rolecfg = o.execute("select coalesce(array_to_string(rolconfig, ' '), 'default') || coalesce(' [this database: ' || (select array_to_string(s.setconfig, ' ') "
                                "from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase where d.datname = current_database() "
                                "and s.setrole = r.oid) || ']', '') from pg_roles r where rolname = 'authenticated'").fetchone()[0]
            log(f"server {ver}; authenticated role settings: {rolecfg}")
            ids = dict(o.execute("select email, user_id::text from public.employees where email in "
                                 "('a.admin@attendos-dev.example', 'a.admin2@attendos-dev.example', 'a.hr@attendos-dev.example')").fetchall())
            dev = o.execute("select id::text from public.biometric_devices where name = 'TEST X2008 Alpha (synthetic)'").fetchone()
            open_n = o.execute("select count(*) from public.biometric_import_batches where state in ('uploading','uploaded','parsing','classifying')").fetchone()[0]
            before = o.execute(BOUNDARY).fetchone()[0]
        if not dev:
            raise g.Stop("the synthetic X2008 Alpha device is missing — run dev_seed_synthetic.sql first")
        dev = dev[0]
        if len(ids) != 3 or not all(ids.values()):
            raise g.Stop("the logins for a.admin@, a.admin2@ and a.hr@attendos-dev.example are not created and linked yet")
        if open_n:
            raise g.Stop(f"{open_n} import(s) are still in progress on the development project; finish or cancel them first")
        ADMIN, ADMIN2, HR = ids["a.admin@attendos-dev.example"], ids["a.admin2@attendos-dev.example"], ids["a.hr@attendos-dev.example"]
        with x.user(ADMIN) as a:
            r, _ = rpc(a, "biometric_dat_set_device_format", dev, "essl.x2008.attlog/1")
            x.check(r.get("ok"), "setup: the synthetic X2008 Alpha may import files (assigned by A admin)")

        # ---------------------------------------------------- S1–S4
        def scale(n, off, label):
            with x.owner() as o:
                o.execute("alter table public.biometric_import_rows set (autovacuum_enabled = false)" if off
                          else "alter table public.biometric_import_rows reset (autovacuum_enabled)")
            try:
                with x.user(HR) as c:
                    bid, up = upload(x, c, dev, make_file(n, n + (1 if off else 0)))
                    st, ph = process(c, bid)
                ok, d = verify(x, bid, n)
                allc = up + ph["validate"] + ph["parse"] + ph["classify"]
                log(f"     {label}: upload {summary(up)}; validate {summary(ph['validate'])}; parse {summary(ph['parse'])}; classify {summary(ph['classify'])}")
                x.check(ok and max(allc) < 8000, f"{label}: ready, every call < 8 s (slowest {max(allc):.0f} ms; target < 4000 ms); {d}")
                return bid
            except psycopg.errors.QueryCanceled as e:
                x.check(False, f"{label}: a call exceeded the 8 s limit ({str(e).splitlines()[0]})")
            finally:
                with x.owner() as o:
                    o.execute("alter table public.biometric_import_rows reset (autovacuum_enabled)")

        scale(32000, False, "S1 32,000 lines, autovacuum normal")
        remove_created(x)
        scale(32000, True, "S2 32,000 lines, autovacuum OFF")
        remove_created(x)
        scale(200000, False, "S3 200,000 lines, autovacuum normal")
        remove_created(x)
        bid = scale(200000, True, "S4 200,000 lines, autovacuum OFF")

        # ---------------------------------------------------- S6 deletion of 200,000 rows
        if bid:
            with x.user(ADMIN) as a, x.user(HR) as h:
                rr, ms = rpc(a, "biometric_dat_delete", bid, "preflight S6 deletion test")
                times = [ms]
                while True:
                    with x.owner() as o:
                        left, pending = o.execute("select (select count(*) from public.biometric_import_rows where batch_id = %s), purge_pending "
                                                  "from public.biometric_import_batches where id = %s", (bid, bid)).fetchone()
                    if not pending:
                        break
                    _, ms = rpc(h, "biometric_dat_housekeeping")
                    times.append(ms)
            log(f"     S6 delete {times[0]:.0f} ms; housekeeping {summary(times[1:])}")
            x.check(left == 0 and max(times) < 8000 and rr.get("state") == "deleted",
                    f"S6 deleting 200,000 rows: bounded steps (slowest {max(times):.0f} ms); nothing left")
        remove_created(x)

        # ---------------------------------------------------- S7 retention expiry
        with x.user(ADMIN) as a:
            bid, _ = upload(x, a, dev, make_file(200000, 7))
            process(a, bid)
            v = a.execute("select (public.biometric_dat_status(%s) ->> 'version')::int", (bid,)).fetchone()[0]
            rpc(a, "biometric_dat_mark_reviewed", bid, v)
        with x.owner() as o:
            o.execute("update public.biometric_import_batches set reviewed_at = now() - interval '91 days' where id = %s", (bid,))
        times = []
        with x.user(HR) as h:
            while True:
                _, ms = rpc(h, "biometric_dat_housekeeping")
                times.append(ms)
                with x.owner() as o:
                    st, why, pending, left = o.execute("select state, fail_reason, purge_pending, (select count(*) from public.biometric_import_rows where batch_id = %s) "
                                                       "from public.biometric_import_batches where id = %s", (bid, bid)).fetchone()
                if not pending:
                    break
        log(f"     S7 retention expiry by HR housekeeping: {summary(times)}")
        x.check(st == "expired" and why == "retention_period" and left == 0 and max(times) < 8000,
                f"S7 reviewed 200,000-row batch past 90 days: expired and removed in {len(times)} bounded calls (slowest {max(times):.0f} ms)")
        remove_created(x)

        # ---------------------------------------------------- S5 retries after cancelled calls
        with x.owner() as o:
            o.execute("alter table public.biometric_import_rows set (autovacuum_enabled = false)")
        try:
            with x.user(ADMIN) as c:
                n = 32000
                bid, _ = upload(x, c, dev, make_file(n, 5))
                process(c, bid, stop_after=2)

                def progress():
                    with x.owner() as o:
                        return o.execute("select state, progress_line, (select count(*) from public.biometric_import_rows where batch_id = %s) "
                                         "from public.biometric_import_batches where id = %s", (bid, bid)).fetchone()

                for label, ms_limit in (("parse", "40ms"), ("classify", "20ms")):
                    while label == "classify" and progress()[0] == "parsing":
                        rpc(c, "biometric_dat_process", bid)
                    before_p = progress()
                    c.execute(f"set statement_timeout = '{ms_limit}'")
                    cancelled = False
                    try:
                        rpc(c, "biometric_dat_process", bid)
                    except psycopg.errors.QueryCanceled:
                        cancelled = True
                    c.execute("set statement_timeout = '8s'")
                    x.check(cancelled and progress() == before_p, f"S5 a {label} call cancelled mid-way changes nothing {before_p}")
                process(c, bid)
                ok, d = verify(x, bid, n)
                x.check(ok, f"S5 retried to the end: each line exactly once, every line labelled {d}")
        finally:
            with x.owner() as o:
                o.execute("alter table public.biometric_import_rows reset (autovacuum_enabled)")
        remove_created(x)

        # ---------------------------------------------------- C1 simultaneous starts
        out = {}

        def start(i):
            raw = f"race-{i}-{x.ref}".encode()
            c = x.user(ADMIN, autocommit=False)
            r = c.execute("select public.biometric_dat_begin(%s, 'Asia/Kolkata', %s, %s, %s)",
                          (dev, len(raw), hashlib.sha256(raw).hexdigest(), [hashlib.sha256(raw).hexdigest()])).fetchone()[0]
            time.sleep(1.5)
            c.commit()
            c.close()
            out[i] = r

        th = [threading.Thread(target=start, args=(i,)) for i in range(4)]
        [t.start() for t in th]
        [t.join() for t in th]
        x.created += [r["batch_id"] for r in out.values() if r.get("ok")]
        with x.owner() as o:
            open_n = o.execute("select count(*) from public.biometric_import_batches where state in ('uploading','uploaded','parsing','classifying')").fetchone()[0]
        refused = [r.get("error") for r in out.values() if not r.get("ok")]
        x.check(open_n == 3 and refused == ["too_many_open_batches"], f"C1 four simultaneous starts: {4 - len(refused)} begun, refused {refused}, {open_n} open (limit 3)")
        remove_created(x)

        # ---------------------------------------------------- C2 same file, two Admins
        out = {}

        def same(uid):
            raw = f"same-file-race-{x.ref}".encode()
            c = x.user(uid, autocommit=False)
            out[uid] = c.execute("select public.biometric_dat_begin(%s, 'Asia/Kolkata', %s, %s, %s)",
                                 (dev, len(raw), hashlib.sha256(raw).hexdigest(), [hashlib.sha256(raw).hexdigest()])).fetchone()[0]
            time.sleep(1.0)
            c.commit()
            c.close()

        th = [threading.Thread(target=same, args=(u,)) for u in (ADMIN, ADMIN2)]
        [t.start() for t in th]
        [t.join() for t in th]
        x.created += [r["batch_id"] for r in out.values() if r.get("ok")]
        res = sorted(("ok" if r.get("ok") else r.get("error")) for r in out.values())
        x.check(res == ["being_uploaded", "ok"], f"C2 the same file by two Admins at once: {res}")
        remove_created(x)

        # ---------------------------------------------------- C3 two browsers process one batch
        with x.user(ADMIN) as c:
            n = 12000
            bid, _ = upload(x, c, dev, make_file(n, 3))
        errs = []

        def drive():
            try:
                with x.user(ADMIN) as cn:
                    for _ in range(20):
                        if cn.execute("select public.biometric_dat_process(%s) ->> 'state'", (bid,)).fetchone()[0] == "ready_for_review":
                            break
            except Exception as e:  # noqa: BLE001
                errs.append(str(e).splitlines()[0])

        th = [threading.Thread(target=drive) for _ in range(2)]
        [t.start() for t in th]
        [t.join() for t in th]
        ok, d = verify(x, bid, n)
        x.check(ok and not errs, f"C3 two sessions processing one batch: serialised; {d}; errors {errs}")
        remove_created(x)

        # ---------------------------------------------------- V7 boundary
        with x.owner() as o:
            after = o.execute(BOUNDARY).fetchone()[0]
            cron = o.execute("select count(*) from pg_extension where extname = 'pg_cron'").fetchone()[0]
        x.check(after == before, "V7 attendance events, raw biometric events, event state, sync runs, reviews and mappings are byte-for-byte unchanged")
        x.check(cron == 0, "V7 pg_cron is not installed")
    except g.Stop as e:
        log(str(e))
        x.fails.append(str(e))
    except Exception as e:  # noqa: BLE001
        log(f"STOP: unexpected error: {g.redact(str(e).splitlines()[0])}")
        x.fails.append("unexpected error")
    finally:
        try:
            remove_created(x)
            with x.owner() as o:
                o.execute("alter table public.biometric_import_rows reset (autovacuum_enabled)")
        except Exception:  # noqa: BLE001
            log("WARNING: cleanup did not complete — check for leftover synthetic batches")
    log(f"{'ALL DB-LEVEL CHECKS PASSED' if not x.fails else 'STOP — ' + str(len(x.fails)) + ' check(s) failed; do not continue, report to the owner'}")
    log(f"report: {log.path}")
    return 1 if x.fails else 0


if __name__ == "__main__":
    sys.exit(main())
