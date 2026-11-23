"""AttendOS development preflight — V3/V4/V5 (+ optional API timings) over the real API with real Auth sign-ins.

  python3 dat_hosted_matrix.py                # V3 permission matrix, V4 direct table reads, V5 request/response size
  python3 dat_hosted_matrix.py --scale        # … plus 32,000- and 200,000-line uploads timed end to end through the API

Owner-run (Option A) against the DEVELOPMENT project only. devguard checks, before anything is sent:
ATTENDOS_DEV_PROJECT_REF, the API URL (exactly https://<ref>.supabase.co), the anon key (never a service-role key;
its ref claim must match), the logins file (outside the repository); every access token's issuer must be the dev
project's Auth. Synthetic data only: the files are generated here (2030 dates); nothing real is uploaded.

The logins file (JSON, outside the repo) maps the 8 test roles of dev_seed_synthetic.sql to e-mail + password:
  {"A admin": {"email": "a.admin@attendos-dev.example", "password": "…"}, "A admin2": …, "A hr": …, "A manager": …,
   "A employee": …, "B admin": …, "B hr": …, "B employee": …}
Expected matrix (approved, identical to the local test T-PERM): see EXPECTED below. Any difference = STOP.
"""
import argparse
import base64
import datetime
import hashlib
import json
import sys
import time
import urllib.error
import urllib.request

import devguard as g

ROLES = ["A admin", "A hr", "A manager", "A employee", "B admin", "B hr", "B employee", "anon"]
FUNCS = ["begin", "chunk", "resume", "finish", "process", "status", "batches", "codes", "rows", "housekeeping",
         "cancel_others", "mark_reviewed", "delete", "download", "set_device_format"]
TABLES = ["biometric_import_batches", "biometric_import_chunks", "biometric_import_files", "biometric_import_rows", "biometric_device_import_formats"]
CHUNK = 262144


def expected(who, fn):
    if fn.startswith("table:") or who in ("A manager", "A employee", "B employee", "anon"):
        return "denied"
    if who == "A admin":
        return "allowed"
    if who == "A hr":
        return "denied" if fn in ("cancel_others", "mark_reviewed", "delete", "download", "set_device_format") else "allowed"
    if who == "B admin":
        return "allowed" if fn in ("batches", "housekeeping") else "not_found"
    if who == "B hr":
        if fn in ("batches", "housekeeping"):
            return "allowed"
        return "denied" if fn in ("mark_reviewed", "delete", "download", "set_device_format") else "not_found"


class Api:
    def __init__(self, log):
        self.ref, self.url, self.key, self.logins = g.api_params()
        self.log = log
        self.tokens = {}

    def _req(self, method, path, body=None, token=None, timeout=60):
        h = {"apikey": self.key, "Content-Type": "application/json"}
        if token:
            h["Authorization"] = "Bearer " + token
        elif self.key.startswith("eyJ"):
            h["Authorization"] = "Bearer " + self.key
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.url + path, data=data, method=method, headers=h)
        t0 = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else None), (time.perf_counter() - t0) * 1000
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw), (time.perf_counter() - t0) * 1000
            except Exception:  # noqa: BLE001
                return e.code, {"message": raw.decode(errors="replace")[:200]}, (time.perf_counter() - t0) * 1000

    def sign_in(self, who):
        if who == "anon":
            return None
        if who not in self.tokens:
            cred = self.logins.get(who)
            if not cred:
                raise g.Stop(f"the logins file has no entry for '{who}'")
            st, body, _ = self._req("POST", "/auth/v1/token?grant_type=password", {"email": cred["email"], "password": cred["password"]})
            if st != 200 or not body or "access_token" not in body:
                raise g.Stop(f"sign-in failed for '{who}' (HTTP {st})")
            g.check_token(self.ref, body["access_token"])
            self.tokens[who] = body["access_token"]
        return self.tokens[who]

    def rpc(self, who, fn, body, timeout=60):
        return self._req("POST", f"/rest/v1/rpc/{fn}", body, self.sign_in(who), timeout)

    def table(self, who, t):
        return self._req("GET", f"/rest/v1/{t}?select=*&limit=1", None, self.sign_in(who))


def outcome(status, body):
    msg = json.dumps(body) if body is not None else ""
    if 200 <= status < 300:
        return "not_found" if isinstance(body, dict) and body.get("error") == "device_not_found" else "allowed"
    if "not found" in msg.lower():
        return "not_found"
    if status in (401, 403) or "not allowed" in msg.lower() or "permission denied" in msg.lower():
        return "denied"
    return f"error {status}: {msg[:120]}"


def synthetic(n, seed=0, wide=0):
    t = datetime.datetime(2030, 1, 1, 8, 0, 0)
    pad = "x" * wide
    return "".join(f"{str(i % 400 + 1):>9}\t{(t + datetime.timedelta(seconds=37 * i + seed)).strftime('%Y-%m-%d %H:%M:%S')}\t1\t255\t1\t0{pad}\r\n"
                   for i in range(n)).encode()


def upload(api, who, dev, raw, times=None):
    chunks = [raw[i:i + CHUNK] for i in range(0, len(raw), CHUNK)]
    st, r, ms = api.rpc(who, "biometric_dat_begin", {"p_device": dev, "p_timezone": "Asia/Kolkata", "p_size": len(raw),
                                                     "p_sha256": hashlib.sha256(raw).hexdigest(), "p_chunk_hashes": [hashlib.sha256(c).hexdigest() for c in chunks]})
    if st != 200 or not r.get("ok"):
        raise g.Stop(f"begin refused: HTTP {st} {r}")
    times = times if times is not None else []
    times.append(("begin", ms))
    bid, tok = r["batch_id"], r["upload_token"]
    g.secret(tok)
    for i, c in enumerate(chunks):
        st, rr, ms = api.rpc(who, "biometric_dat_chunk", {"p_batch": bid, "p_token": tok, "p_index": i, "p_data": base64.b64encode(c).decode()})
        times.append(("chunk", ms))
        if st != 200 or not rr.get("ok"):
            raise g.Stop(f"chunk {i} refused: HTTP {st} {rr}")
    st, rr, ms = api.rpc(who, "biometric_dat_finish", {"p_batch": bid, "p_token": tok})
    times.append(("finish", ms))
    if st != 200 or rr.get("state") != "uploaded":
        raise g.Stop(f"finish refused: HTTP {st} {rr}")
    return bid


def process(api, who, bid, times):
    while True:
        st, r, ms = api.rpc(who, "biometric_dat_process", {"p_batch": bid}, timeout=30)
        if st != 200:
            raise g.Stop(f"process failed: HTTP {st} {r}")
        times.append((r.get("state"), ms))
        if r.get("state") in ("ready_for_review", "failed"):
            return r.get("state")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scale", action="store_true")
    a = ap.parse_args()
    try:
        log = g.Log(f"{datetime.datetime.now():%Y%m%d-%H%M%S}-dat-hosted-matrix.txt")
        api = Api(log)
    except g.Stop as e:
        print(e)
        return 2
    fails = []

    def check(ok, what):
        log(("PASS " if ok else "FAIL ") + what)
        if not ok:
            fails.append(what)

    try:
        log(f"AttendOS dev preflight · API checks · project {api.ref} · {datetime.datetime.now().isoformat(timespec='seconds')}")
        for who in ROLES:
            api.sign_in(who)
        log("signed in: " + ", ".join(w for w in ROLES if w != "anon") + " (every token issued by the dev project's Auth)")
        st, lst, _ = api.rpc("A admin", "biometric_dat_batches", {})
        devs = {d["name"]: d for d in (lst or {}).get("devices", [])}
        x2008 = devs.get("TEST X2008 Alpha (synthetic)")
        if not x2008:
            raise g.Stop("the synthetic X2008 Alpha device is missing — run dev_seed_synthetic.sql first")
        dev = x2008["id"]
        st, r, _ = api.rpc("A admin", "biometric_dat_set_device_format", {"p_device": dev, "p_format": "essl.x2008.attlog/1"})
        check(st == 200 and r.get("ok"), "setup: A admin allows X2008 file import for the synthetic X2008")
        st, r, _ = api.rpc("A admin", "biometric_dat_set_device_format", {"p_device": devs["TEST eSSL K21 Alpha (synthetic)"]["id"], "p_format": "essl.x2008.attlog/1"})
        check(st == 200 and r.get("error") == "model_not_supported", "F4: the X2008 profile is refused for the synthetic eSSL K21")
        times = []
        m = upload(api, "A admin", dev, synthetic(20, seed=7))
        check(process(api, "A admin", m, times) == "ready_for_review", "setup: A admin's 20-line synthetic batch is ready for review")

        # ------------------------------------------------------------ V3 / V4 permission matrix
        calls = {
            "begin": ("biometric_dat_begin", {"p_device": dev, "p_timezone": "Asia/Kolkata", "p_size": 10, "p_sha256": "bad", "p_chunk_hashes": ["bad"]}),
            "chunk": ("biometric_dat_chunk", {"p_batch": m, "p_token": "x", "p_index": 0, "p_data": "AA=="}),
            "resume": ("biometric_dat_resume", {"p_batch": m}),
            "finish": ("biometric_dat_finish", {"p_batch": m, "p_token": "x"}),
            "process": ("biometric_dat_process", {"p_batch": m}),
            "status": ("biometric_dat_status", {"p_batch": m}),
            "batches": ("biometric_dat_batches", {}),
            "codes": ("biometric_dat_codes", {"p_batch": m}),
            "rows": ("biometric_dat_rows", {"p_batch": m, "p_filter": "all", "p_code": None, "p_offset": 0, "p_limit": 5}),
            "housekeeping": ("biometric_dat_housekeeping", {}),
            "cancel_others": ("biometric_dat_cancel", {"p_batch": m}),
            "mark_reviewed": ("biometric_dat_mark_reviewed", {"p_batch": m, "p_version": -1}),
            "delete": ("biometric_dat_delete", {"p_batch": m, "p_reason": "x"}),
            "download": ("biometric_dat_download", {"p_batch": m}),
            "set_device_format": ("biometric_dat_set_device_format", {"p_device": dev, "p_format": "nope"}),
        }
        got = {}
        for who in ROLES:
            for k in FUNCS:
                fn, body = calls[k]
                st, r, _ = api.rpc(who, fn, body)
                got[(who, k)] = outcome(st, r)
            for t in TABLES:
                st, r, _ = api.table(who, t)
                got[(who, "table:" + t)] = "allowed" if 200 <= st < 300 else outcome(st, r)
        rows = FUNCS + ["table:" + t for t in TABLES]
        log("Permission matrix over the API (allowed / denied / not_found):")
        log(f"{'operation':40} " + " ".join(f"{w:10}" for w in ROLES))
        for k in rows:
            log(f"{k:40} " + " ".join(f"{got[(w, k)]:10}" for w in ROLES))
        diffs = [(w, k, got[(w, k)], expected(w, k)) for w in ROLES for k in rows if got[(w, k)] != expected(w, k)]
        for d in diffs:
            log(f"   DIFFERENT: {d[0]} / {d[1]}: got {d[2]}, expected {d[3]}")
        check(len(got) == 160 and not diffs, f"V3/V4 permission matrix over the API: 160 role × operation checks match the approved matrix ({len(diffs)} differences)")
        st, r, _ = api.rpc("B admin", "biometric_dat_batches", {})
        check(st == 200 and r.get("batches") == [] and r.get("devices") is not None and all(d["name"].endswith("Beta (synthetic)") for d in r["devices"]),
              "V3: company B's Admin lists none of company A's batches or devices")

        # ------------------------------------------------------------ V5 request and response size
        big = (synthetic(1, seed=99) * (16777216 // 41 + 1))[:16777216]  # exactly 16 MiB of record-shaped text
        t = []
        bid = upload(api, "A hr", dev, big, t)
        chunk_ms = [ms for (k, ms) in t if k == "chunk"]
        check(len(chunk_ms) == 64, f"V5 a 16 MiB file: 64 full 256 KiB chunks (≈ 342 KB of base64 each) accepted through the API "
                                   f"(slowest {max(chunk_ms):.0f} ms, total {sum(chunk_ms) / 1000:.1f} s)")
        st, r, ms = api.rpc("A admin", "biometric_dat_download", {"p_batch": bid}, timeout=120)
        ok = st == 200 and r.get("ok") and hashlib.sha256(base64.b64decode(r["data"])).hexdigest() == hashlib.sha256(big).hexdigest()
        check(ok, f"V5 the Admin downloads the 16 MiB original intact through the API (≈ 22 MB response, {ms:.0f} ms, SHA-256 equal)")
        st, r, _ = api.rpc("A hr", "biometric_dat_cancel", {"p_batch": bid})
        check(st == 200 and r.get("state") == "cancelled", "V5 cleanup: HR cancels their own 16 MiB upload (file removed)")

        # ------------------------------------------------------------ optional: end-to-end timings through the API
        if a.scale:
            for n in (32000, 200000):
                t = []
                b = upload(api, "A hr", dev, synthetic(n, seed=n), t)
                state = process(api, "A hr", b, t)
                slow = max(ms for (_, ms) in t)
                log(f"     API {n:,} lines by HR: {len(t)} calls, slowest {slow:.0f} ms, total {sum(ms for (_, ms) in t) / 1000:.1f} s")
                check(state == "ready_for_review" and slow < 8000, f"API scale {n:,} lines: ready for review, every call under 8 s (slowest {slow:.0f} ms; target < 4000 ms)")
                api.rpc("A admin", "biometric_dat_delete", {"p_batch": b, "p_reason": "preflight scale test cleanup"})
        st, r, _ = api.rpc("A admin", "biometric_dat_delete", {"p_batch": m, "p_reason": "preflight matrix test cleanup"})
        check(st == 200 and r.get("state") == "deleted", "cleanup: the matrix batch is deleted by the Admin")
    except g.Stop as e:
        log(str(e))
        fails.append(str(e))
    log(f"{'ALL API CHECKS PASSED' if not fails else 'STOP — ' + str(len(fails)) + ' check(s) failed; do not continue, report to the owner'}")
    log(f"report: {log.path}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
