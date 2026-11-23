"""B5 DAT import — scale, retry, deletion-timing and concurrency tests (LOCAL ONLY, synthetic data only).

Run after `npm run test:db` (it copies the database that run leaves behind, `attendos_test`, into a throwaway
`attendos_dat_scale`, which is dropped again at the end). Needs a local Postgres (PGHOST/PGPORT/PGUSER) and psycopg 3
(`pip install "psycopg[binary]"`). Never point it at a hosted or company database.

Every call is made as a signed-in user (role `authenticated` + JWT subject), exactly like the app, with
`statement_timeout = 8s` (the Supabase signed-in limit). A call that hits the limit fails the run.

Scenarios
  S1/S2  32,000 lines (≈ the 31,207 records the X2008 reported) — autovacuum normal / OFF for the rows table
  S3/S4  200,000 lines (the file limit) — autovacuum normal / OFF
  S5     retries: a parse call and a classify call are cancelled mid-way (timeout forced); progress and rows are unchanged,
         the retried run completes with every line exactly once
  S6     deletion of a 200,000-row batch: the Admin's delete call, then bounded housekeeping calls until nothing is left
  S7     retention expiry of a reviewed 200,000-row batch (90 days passed): housekeeping calls until nothing is left
  C1     four simultaneous starts of different files: the three-open-batch limit is never exceeded (F5)
  C2     the same file started by two Admins at once: one upload, the other told it is being uploaded
  C3     two browsers processing the same batch at once: every line exactly once, labels complete

Usage: python3 supabase/tests/dat_scale_test.py [report-path]
"""
import base64
import datetime
import hashlib
import json
import os
import subprocess
import sys
import threading
import time

import psycopg

PG = dict(host=os.environ.get("PGHOST", "/tmp/pg"), port=os.environ.get("PGPORT", "5433"), user=os.environ.get("PGUSER", "postgres"))
SRC, DB = "attendos_test", "attendos_dat_scale"
ADMIN, HR, ADMIN2 = "00000000-0000-0000-0000-00000000000a", "00000000-0000-0000-0000-00000000000b", "00000000-0000-0000-0000-0000000000d9"
CHUNK = 262144
REPORT = sys.argv[1] if len(sys.argv) > 1 else None
results, failures = [], []


def log(msg):
    print(msg, flush=True)
    results.append(msg)


def check(ok, what):
    log(("PASS " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def owner():
    return psycopg.connect(dbname=DB, autocommit=True, **PG)


def user(uid, timeout="8s"):
    c = psycopg.connect(dbname=DB, autocommit=True, **PG)
    c.execute("set role authenticated")
    c.execute("select set_config('request.jwt.claim.sub', %s, false)", (uid,))
    c.execute(f"set statement_timeout = '{timeout}'")
    return c


def rpc(c, fn, *args):
    t0 = time.perf_counter()
    r = c.execute(f"select public.{fn}({', '.join(['%s'] * len(args))})", args).fetchone()[0]
    return r, (time.perf_counter() - t0) * 1000


def fresh_db():
    subprocess.run(["dropdb", "--if-exists", "--force", DB], check=True, env={**os.environ})
    subprocess.run(["createdb", "-T", SRC, DB], check=True, env={**os.environ})
    with owner() as o:  # nothing left open from the functional tests
        o.execute("update biometric_import_batches set state = 'cancelled', ended_at = now(), upload_token_hash = null "
                  "where state in ('uploading', 'uploaded', 'parsing', 'classifying')")


def device():
    with owner() as o:
        return str(o.execute("select device_id from biometric_device_import_formats f join biometric_devices d on d.id = f.device_id "
                             "where d.name = 'Fixture device'").fetchone()[0])


def make_file(n, seed):
    t = datetime.datetime(2030, 1, 1, 8, 0, 0)
    return "".join(f"{str(i % 400 + 1):>9}\t{(t + datetime.timedelta(seconds=37 * i + seed)).strftime('%Y-%m-%d %H:%M:%S')}\t1\t255\t1\t0\r\n"
                   for i in range(n)).encode()


def upload(c, dev, raw):
    chunks = [raw[i:i + CHUNK] for i in range(0, len(raw), CHUNK)]
    r, ms = rpc(c, "biometric_dat_begin", dev, "Asia/Kolkata", len(raw), hashlib.sha256(raw).hexdigest(),
                [hashlib.sha256(x).hexdigest() for x in chunks])
    assert r["ok"], r
    bid, tok, times = r["batch_id"], r["upload_token"], [ms]
    for i, x in enumerate(chunks):
        r, ms = rpc(c, "biometric_dat_chunk", bid, tok, i, base64.b64encode(x).decode())
        assert r["ok"], r
        times.append(ms)
    r, ms = rpc(c, "biometric_dat_finish", bid, tok)
    assert r["state"] == "uploaded", r
    times.append(ms)
    return bid, times


def process(c, bid, stop_after=None):
    phases = {"validate": [], "parse": [], "classify": []}
    calls = 0
    while True:
        st = c.execute("select public.biometric_dat_status(%s) ->> 'state'", (bid,)).fetchone()[0]
        if st in ("ready_for_review", "failed") or (stop_after and calls >= stop_after):
            return st, phases
        r, ms = rpc(c, "biometric_dat_process", bid)
        phases[{"uploaded": "validate", "parsing": "parse", "classifying": "classify"}[st]].append(ms)
        calls += 1


def verify(bid, n):
    with owner() as o:
        cnt, dist, unl, st, lines = o.execute(
            "select count(*), count(distinct line_no), count(*) filter (where dup_class is null and parse_status <> 'blank'), "
            "(select state from biometric_import_batches where id = %s), (select (counts ->> 'lines')::int from biometric_import_batches where id = %s) "
            "from biometric_import_rows where batch_id = %s", (bid, bid, bid)).fetchone()
    return cnt == n and dist == n and unl == 0 and st == "ready_for_review" and lines == n, (cnt, dist, unl, st, lines)


def summary(ts):
    return f"{len(ts)} calls, max {max(ts):.0f} ms, total {sum(ts) / 1000:.1f} s" if ts else "0 calls"


def scale(n, autovac_off, label):
    fresh_db()
    if autovac_off:
        with owner() as o:
            o.execute("alter table biometric_import_rows set (autovacuum_enabled = false)")
    dev = device()
    c = user(ADMIN)
    raw = make_file(n, 0)
    try:
        bid, up = upload(c, dev, raw)
        st, ph = process(c, bid)
    except psycopg.errors.QueryCanceled as e:
        check(False, f"{label}: a call exceeded the 8 s limit ({e})")
        return None
    ok, detail = verify(bid, n)
    log(f"     {label}: {len(raw):,} bytes — upload {summary(up)}; validate {summary(ph['validate'])}; parse {summary(ph['parse'])}; classify {summary(ph['classify'])}")
    allcalls = up + ph["validate"] + ph["parse"] + ph["classify"]
    check(ok and max(allcalls) < 8000, f"{label}: ready for review within the 8 s limit on every call (slowest {max(allcalls):.0f} ms); "
          f"{n:,} rows, each line once, every line labelled {detail}")
    return c, bid


def main():
    log(f"B5 DAT scale / retry / deletion / concurrency tests — {datetime.datetime.now().isoformat(timespec='seconds')} — local database copy of {SRC}")

    # ------------------------------------------------------------ S1–S4 performance at the limits
    scale(32000, False, "S1 32,000 lines, autovacuum normal")
    scale(32000, True, "S2 32,000 lines, autovacuum OFF")
    scale(200000, False, "S3 200,000 lines, autovacuum normal")
    r = scale(200000, True, "S4 200,000 lines, autovacuum OFF")

    # ------------------------------------------------------------ S6 deletion of 200,000 rows (bounded)
    if r:
        c, bid = r
        rr, ms = rpc(c, "biometric_dat_delete", bid, "scale test deletion")
        times, left = [ms], None
        while True:
            with owner() as o:
                left, pending = o.execute("select (select count(*) from biometric_import_rows where batch_id = %s), purge_pending "
                                          "from biometric_import_batches where id = %s", (bid, bid)).fetchone()
            if not pending:
                break
            _, ms = rpc(c, "biometric_dat_housekeeping")
            times.append(ms)
        log(f"     S6 delete call {times[0]:.0f} ms (file and the first 50,000 rows); housekeeping {summary(times[1:])}")
        check(left == 0 and max(times) < 8000 and rr.get("state") == "deleted",
              f"S6 deleting 200,000 rows: unreadable at once, removed in bounded steps (delete call {times[0]:.0f} ms, then {len(times) - 1} housekeeping "
              f"calls, slowest {max(times):.0f} ms, total {sum(times) / 1000:.1f} s); nothing left")

    # ------------------------------------------------------------ S7 retention expiry of a reviewed 200,000-row batch
    fresh_db()
    dev = device()
    c = user(ADMIN)
    bid, _ = upload(c, dev, make_file(200000, 1))
    process(c, bid)
    v = c.execute("select (public.biometric_dat_status(%s) ->> 'version')::int", (bid,)).fetchone()[0]
    rpc(c, "biometric_dat_mark_reviewed", bid, v)
    with owner() as o:
        o.execute("update biometric_import_batches set reviewed_at = now() - interval '91 days' where id = %s", (bid,))
    h = user(HR)
    times = []
    while True:
        _, ms = rpc(h, "biometric_dat_housekeeping")
        times.append(ms)
        with owner() as o:
            st, why, pending, left = o.execute("select state, fail_reason, purge_pending, (select count(*) from biometric_import_rows where batch_id = %s) "
                                               "from biometric_import_batches where id = %s", (bid, bid)).fetchone()
        if not pending:
            break
    log(f"     S7 retention expiry by HR housekeeping: {summary(times)}")
    check(st == "expired" and why == "retention_period" and left == 0 and max(times) < 8000,
          f"S7 a reviewed 200,000-row batch past 90 days expires on the first housekeeping call and is removed in {len(times)} bounded calls "
          f"(slowest {max(times):.0f} ms)")

    # ------------------------------------------------------------ S5 retries after cancelled calls
    fresh_db()
    with owner() as o:
        o.execute("alter table biometric_import_rows set (autovacuum_enabled = false)")
    dev = device()
    c = user(ADMIN)
    n = 32000
    bid, _ = upload(c, dev, make_file(n, 2))
    process(c, bid, stop_after=2)  # validate + first parse slice

    def progress():
        with owner() as o:
            return o.execute("select state, progress_line, (select count(*) from biometric_import_rows where batch_id = %s) "
                             "from biometric_import_batches where id = %s", (bid, bid)).fetchone()

    before = progress()
    c.execute("set statement_timeout = '40ms'")
    cancelled = False
    try:
        rpc(c, "biometric_dat_process", bid)
    except psycopg.errors.QueryCanceled:
        cancelled = True
    c.execute("set statement_timeout = '8s'")
    check(cancelled and progress() == before, f"S5a a parse call cancelled mid-way changes nothing (state, progress, rows {before})")
    while progress()[0] == "parsing":
        rpc(c, "biometric_dat_process", bid)
    before = progress()
    c.execute("set statement_timeout = '20ms'")
    cancelled = False
    try:
        rpc(c, "biometric_dat_process", bid)
    except psycopg.errors.QueryCanceled:
        cancelled = True
    c.execute("set statement_timeout = '8s'")
    with owner() as o:
        labelled = o.execute("select count(*) from biometric_import_rows where batch_id = %s and dup_class is not null", (bid,)).fetchone()[0]
    check(cancelled and progress() == before and labelled == 0, f"S5b a classify call cancelled mid-way changes nothing (no label written, progress {before[1]})")
    process(c, bid)
    ok, detail = verify(bid, n)
    check(ok, f"S5c retried to the end: {n:,} rows, each line exactly once, every line labelled {detail}")

    # ------------------------------------------------------------ C1 simultaneous starts vs the open-batch limit (F5)
    fresh_db()
    dev = device()
    out = {}

    def start(i):
        raw = f"race-{i}".encode()
        cn = psycopg.connect(dbname=DB, autocommit=False, **PG)
        cn.execute("set role authenticated")
        cn.execute("select set_config('request.jwt.claim.sub', %s, false)", (ADMIN,))
        r = cn.execute("select public.biometric_dat_begin(%s, 'Asia/Kolkata', %s, %s, %s)",
                       (dev, len(raw), hashlib.sha256(raw).hexdigest(), [hashlib.sha256(raw).hexdigest()])).fetchone()[0]
        time.sleep(1.5)  # hold the transaction open: without the company lock the others would not see this batch yet
        cn.commit()
        cn.close()
        out[i] = r

    th = [threading.Thread(target=start, args=(i,)) for i in range(4)]
    t0 = time.perf_counter()
    [t.start() for t in th]
    [t.join() for t in th]
    el = time.perf_counter() - t0
    with owner() as o:
        open_n = o.execute("select count(*) from biometric_import_batches where state in ('uploading', 'uploaded', 'parsing', 'classifying')").fetchone()[0]
    oks = sum(1 for r in out.values() if r.get("ok"))
    refused = [r.get("error") for r in out.values() if not r.get("ok")]
    check(open_n == 3 and oks == 3 and refused == ["too_many_open_batches"],
          f"C1 four simultaneous starts: {oks} begun, refused {refused}, {open_n} open afterwards (limit 3); starts serialised ({el:.1f} s for 4 × 1.5 s)")

    # ------------------------------------------------------------ C2 the same file by two Admins at once
    fresh_db()
    dev = device()
    out = {}

    def start_same(uid):
        raw = b"same-file-race"
        cn = psycopg.connect(dbname=DB, autocommit=False, **PG)
        cn.execute("set role authenticated")
        cn.execute("select set_config('request.jwt.claim.sub', %s, false)", (uid,))
        out[uid] = cn.execute("select public.biometric_dat_begin(%s, 'Asia/Kolkata', %s, %s, %s)",
                              (dev, len(raw), hashlib.sha256(raw).hexdigest(), [hashlib.sha256(raw).hexdigest()])).fetchone()[0]
        time.sleep(1.0)
        cn.commit()
        cn.close()

    th = [threading.Thread(target=start_same, args=(u,)) for u in (ADMIN, ADMIN2)]
    [t.start() for t in th]
    [t.join() for t in th]
    with owner() as o:
        nb = o.execute("select count(*) from biometric_import_batches where file_sha256 = sha256('same-file-race'::bytea)").fetchone()[0]
    res = sorted(("ok" if r.get("ok") else r.get("error")) for r in out.values())
    check(nb == 1 and res == ["being_uploaded", "ok"], f"C2 the same file by two Admins at once: {res}, {nb} batch")

    # ------------------------------------------------------------ C3 two browsers process the same batch at once
    fresh_db()
    dev = device()
    c = user(ADMIN)
    n = 12000
    bid, _ = upload(c, dev, make_file(n, 3))
    errs = []

    def drive():
        cn = user(ADMIN)
        try:
            for _ in range(20):
                st = cn.execute("select public.biometric_dat_process(%s) ->> 'state'", (bid,)).fetchone()[0]
                if st == "ready_for_review":
                    break
        except Exception as e:  # noqa: BLE001
            errs.append(str(e))

    th = [threading.Thread(target=drive) for _ in range(2)]
    [t.start() for t in th]
    [t.join() for t in th]
    ok, detail = verify(bid, n)
    check(ok and not errs, f"C3 two browsers processing one batch at once: serialised by the batch lock; {detail}; errors {errs}")

    subprocess.run(["dropdb", "--if-exists", "--force", DB], check=True, env={**os.environ})
    log(f"{len([x for x in results if x.startswith('PASS')])} passed, {len(failures)} failed")
    if REPORT:
        with open(REPORT, "w") as f:
            f.write("\n".join(results) + "\n")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
