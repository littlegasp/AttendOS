"""
B5 DAT import browser tests, against the LOCAL demo stack only (supabase/demo: PostgreSQL + PostgREST on :3001 with
0013 and biometric_demo.sql; the static app built with the demo URL). Never point this at a hosted project.

The real X2008 export is read from $ATTENDOS_REAL_DAT (outside the repository). Without it the script stops with
"SKIPPED" — nothing is reported as passed.

Covers: Admin uploads the real file through the screen; the database holds the exact bytes and 151 rows; the browser
sends only original bytes (no parsed rows); codes table; mapping 10 → WR198 created in the screen by an authorised
user; code 10's four records incl. both 21 Nov records; filters; mark reviewed; same file again refused; download
byte-identical; HR and Employee have no import access; light/dark at 1440 and 390 px; attendance, raw events and
projection state unchanged.

Usage: ATTENDOS_REAL_DAT=/path/to/export.dat python3 e2e/biometric_dat_import.py http://localhost:4175 out-dir
"""
import base64
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_src = open(os.path.join(HERE, "regression.py")).read().split("with sync_playwright() as p:")[0]
exec(compile(_src, "regression_helpers", "exec"))  # sql, rpc, jwt, U, Ctx, check, results, APP, OUT, API, REMOTE

REAL = os.environ.get("ATTENDOS_REAL_DAT", "")
if not REAL or not os.path.isfile(REAL):
    print("SKIPPED - ATTENDOS_REAL_DAT not set: the DAT browser tests need the real export (nothing was run or passed)")
    sys.exit(2)
RAW = open(REAL, "rb").read()
# the browser uploads a byte-identical temporary copy with a neutral name, so screenshots never show the device serial
import tempfile
TMP = os.path.join(tempfile.mkdtemp(), "x2008-usb-export.dat")
open(TMP, "wb").write(RAW)
REAL_NAME = os.path.basename(REAL)
SHA = hashlib.sha256(RAW).hexdigest()
SHOTS = os.path.join(OUT, "b5")
os.makedirs(SHOTS, exist_ok=True)
CID = "cccccccc-0000-0000-0000-00000000000a"

SNAP_SQL = """select md5(coalesce((select string_agg(md5(x::text), ',' order by x::text) from attendance_events x), '') || '|' ||
  coalesce((select string_agg(md5(x::text), ',' order by x::text) from biometric_raw_events x), '') || '|' ||
  coalesce((select string_agg(md5(x::text), ',' order by x::text) from biometric_event_state x), '') || '|' ||
  coalesce((select string_agg(md5(x::text), ',' order by x::text) from biometric_sync_runs x), '') || '|' ||
  coalesce((select string_agg(md5(x::text), ',' order by x::text) from biometric_event_reviews x), ''))"""


def shot(pg, name, full=True):
    pg.screenshot(path=os.path.join(SHOTS, f"{name}.png"), full_page=full)


def no_sideways(pg):
    return pg.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1")


class Rec:
    def __init__(self, ctx):
        self.calls = []
        ctx.page.on("request", self.on_req)

    def on_req(self, req):
        if "/rest/v1/" in req.url and req.method == "POST":
            try:
                body = json.loads(req.post_data or "null")
            except Exception:
                body = None
            self.calls.append((req.url.split("/rest/v1/")[1], body))


def batch_sql(col):
    return sql(f"select {col} from biometric_import_batches where company_id = '{CID}' and file_sha256 = decode('{SHA}', 'hex') and state not in ('failed','expired','cancelled','deleted')")


with sync_playwright() as p:
    br = p.chromium.launch(executable_path="/usr/bin/google-chrome", args=["--no-sandbox"])
    before = sql(SNAP_SQL)
    sql(f"delete from biometric_import_rows where company_id = '{CID}'; delete from biometric_import_files where company_id = '{CID}'; "
        f"delete from biometric_import_chunks where company_id = '{CID}'; delete from biometric_import_batches where company_id = '{CID}' and state <> 'legacy'")

    # ---------------------------------------------------------------- Admin, light, desktop: upload the real file
    a = Ctx(br, "a1", theme="light")
    rec = Rec(a)
    pg = a.go("/biometric?tab=import")
    check(pg.get_by_role("tab", name="File import").count() == 1, "Admin sees the File import tab")
    check(pg.get_by_text("Raw records only.").count() == 1, "the screen states it imports raw records only (no attendance, no IN/OUT)")
    check(pg.get_by_text("No files imported yet").count() == 1, "empty state before the first import")
    shot(pg, "01-import-empty-light")
    dev = pg.get_by_label("Device the file comes from")
    dev.select_option(label=[o for o in dev.locator("option").all_inner_texts() if "X2008" in o][0])
    pg.get_by_label("Original export file").set_input_files(TMP)
    pg.wait_for_selector(f"text={SHA}")
    check(pg.get_by_text(SHA).count() >= 1, "the browser shows the file's SHA-256 before upload (equals the verified value)" if SHA.startswith("6f0115") else "SHA-256 shown")
    shot(pg, "02-file-chosen-light")
    pg.get_by_role("button", name="Upload and check").click()
    pg.wait_for_selector("text=Import review", timeout=30000)
    pg.wait_for_timeout(800)
    check(batch_sql("state") == "ready_for_review", "after upload the batch is ready for review")
    check(batch_sql("(select count(*) from biometric_import_rows r where r.batch_id = biometric_import_batches.id)") == "151", "151 rows stored, one per line")
    check(sql(f"select encode(sha256(original), 'hex') from biometric_import_files f join biometric_import_batches b on b.id = f.batch_id where b.file_sha256 = decode('{SHA}', 'hex') and b.state = 'ready_for_review'") == SHA,
          "the stored original is byte-identical to the file (SHA-256 recomputed by the database)")
    chunk_calls = [b for (u, b) in rec.calls if u.startswith("rpc/biometric_dat_chunk")]
    sent = b"".join(base64.b64decode(c["p_data"]) for c in sorted(chunk_calls, key=lambda c: c["p_index"]))
    check(sent == RAW, "the browser sent exactly the original bytes (base64 chunks), nothing else")
    names = sorted({u.split("?")[0] for (u, _) in rec.calls})
    check(not any(("ingest" in n or "attendance" in n or "projection" in n or "check_in" in n or "raw_events" in n) for n in names),
          f"no ingest, attendance, projection or raw-event call was made (calls: {', '.join(sorted(n.replace('rpc/', '') for n in names))})")
    check(not any(isinstance(b, dict) and any(k in b for k in ("rows", "p_rows", "lines")) for (_, b) in rec.calls), "no parsed rows were sent by the browser (parsing is in the database)")
    check(pg.locator(".metric-card, .metric").filter(has_text="Lines").first.inner_text().find("151") >= 0, "review shows 151 lines")
    code10 = pg.locator("tr", has=pg.locator("th.mono", has_text="10")).filter(has=pg.get_by_role("button", name="Show records")).first
    check("4" in code10.inner_text() and "4 not mapped" in code10.inner_text(), "code 10: 4 records, all 4 not mapped before any mapping")
    check(pg.get_by_text("Amol Jadhav").count() == 0, "no employee is shown for any code before a mapping exists (nothing inferred)")
    shot(pg, "03-review-unmapped-light")

    # ---------------------------------------------------------------- mapping 10 → WR198 in the screen
    code10.get_by_role("button", name="Map code").click()
    dlg = pg.get_by_role("dialog")
    dlg.wait_for()
    check(dlg.get_by_label("Device employee code").input_value() == "10", "mapping form opens with code 10")
    check("X2008" in dlg.get_by_label("Device").locator("option:checked").inner_text(), "… and the X2008 device preselected (device-specific)")
    dlg.get_by_label("AttendOS employee").select_option(label="WR198 · Amol Jadhav")
    dlg.get_by_label("Effective from (Asia/Kolkata)").fill("2026-11-01T00:00")
    shot(pg, "04-map-code-10-light", full=False)
    dlg.get_by_role("button", name="Save mapping").click()
    pg.wait_for_selector("text=Amol Jadhav", timeout=15000)
    pg.wait_for_timeout(600)
    m = sql(f"select employee_device_code || '|' || (device_id is not null)::text || '|' || (select emp_code from employees where id = employee_id) || '|' || to_char(valid_from at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI') from biometric_employee_mappings where company_id = '{CID}' and employee_device_code = '10'")
    check(m == "10|true|WR198|2026-11-01 00:00", f"exactly one mapping for code 10: device-specific, WR198, from 1 Nov 2026 00:00 IST ({m})")
    code10 = pg.locator("tr", has=pg.locator("th.mono", has_text="10")).filter(has=pg.get_by_role("button", name="Show records")).first
    check("Amol Jadhav" in code10.inner_text() and "4 of 4" in code10.inner_text(), "code 10 now shows WR198 for 4 of 4 records")
    others_mapped = pg.locator("tbody tr").filter(has=pg.get_by_role("button", name="Show records")).filter(has_text="this device").count()
    check(others_mapped == 1, "no other code is mapped")
    code10.get_by_role("button", name="Show records").click()
    pg.wait_for_timeout(800)
    rows = pg.locator("table.bio-dat-rows tbody tr")
    texts = rows.all_inner_texts()
    check(rows.count() == 4, "Show records for code 10: 4 lines")
    want = [("24", "2026-11-04 09:26:53"), ("95", "2026-11-16 09:25:04"), ("150", "2026-11-21 15:49:16"), ("151", "2026-11-21 15:53:01")]
    check(all(t.startswith(n) and ts in t for (n, ts), t in zip(want, texts)), "lines 24, 95, 150, 151 with the exact original timestamps")
    check(sum("2026-11-21" in t for t in texts) == 2, "21 Nov: both records (15:49:16 and 15:53:01) are listed as separate raw records")
    check(all("·······10" in t for t in texts), "field 1 is shown exactly as written (left padding visible as ·)")
    check(not any(w in " ".join(texts) for w in ("IN", "OUT", "Check-in", "Check-out", "Present", "Absent")), "no IN/OUT, check-in/out or present/absent wording on the records")
    shot(pg, "05-code-10-records-light")
    pg.get_by_role("button", name="Repeated").click()
    pg.wait_for_timeout(600)
    check(pg.get_by_text("No line matches this view.").count() == 1, "no repeated records in the real file")
    pg.get_by_role("button", name="Needs a look").click()
    pg.wait_for_timeout(600)
    check(pg.get_by_text("No line matches this view.").count() == 1, "no line needs a look in the real file")
    pg.get_by_role("button", name="All lines").click()
    pg.wait_for_timeout(600)
    check("Lines 1–100 of 151" in pg.locator(".pager").inner_text(), "all lines, paged 100 at a time")

    # download, review
    with pg.expect_download() as d:
        pg.get_by_role("button", name="Download original").click()
    got = open(d.value.path(), "rb").read()
    check(got == RAW, "Download original returns the exact bytes")
    check(d.value.suggested_filename == "x2008-usb-export.dat", "… under the uploaded file name")
    pg.get_by_role("button", name="Mark as reviewed").first.click()
    pg.get_by_role("dialog").get_by_role("button", name="Mark as reviewed").click()
    pg.wait_for_timeout(1200)
    check(batch_sql("state") == "reviewed", "Mark as reviewed: state reviewed (nothing else written)")

    # the same file again
    pg = a.go("/biometric?tab=import")
    dev = pg.get_by_label("Device the file comes from")
    dev.select_option(label=[o for o in dev.locator("option").all_inner_texts() if "X2008" in o][0])
    pg.get_by_label("Original export file").set_input_files(TMP)
    pg.wait_for_selector(f"text={SHA}")
    pg.get_by_role("button", name="Upload and check").click()
    pg.wait_for_timeout(2500)
    check(int(sql(f"select count(*) from biometric_import_batches where company_id = '{CID}' and state <> 'legacy'")) == 1, "uploading the same file again creates no second batch")
    check(pg.get_by_text("Import review").count() == 1, "… and opens the earlier import instead")
    pg = a.go("/biometric?tab=import")
    shot(pg, "06-import-list-light")
    check(len(a.errors) == 0, f"no console errors (Admin light) {a.errors[:2]}")
    a.close()

    # ---------------------------------------------------------------- dark theme and mobile
    bid = sql(f"select id from biometric_import_batches where company_id = '{CID}' and state = 'reviewed'")
    for theme in ("dark", "light"):
        for mobile in (False, True):
            c = Ctx(br, "a1", theme=theme, mobile=mobile)
            pg = c.go("/biometric?tab=import")
            tag = f"{'390' if mobile else '1440'}-{theme}"
            check(no_sideways(pg), f"import list: no sideways page scroll ({tag})")
            shot(pg, f"07-list-{tag}")
            pg.get_by_role("button", name="Open", exact=True).first.click()
            pg.wait_for_selector("text=Import review")
            pg.wait_for_timeout(800)
            check(no_sideways(pg), f"import review: no sideways page scroll ({tag})")
            shot(pg, f"08-review-{tag}")
            c.close()

    # ---------------------------------------------------------------- HR and Employee
    h = Ctx(br, "b2", theme="light")
    pg = h.go("/biometric?tab=import")
    check(pg.get_by_role("tab", name="File import").count() == 0, "HR does not see the File import tab")
    check(pg.get_by_text("Raw records only.").count() == 0, "HR opening ?tab=import gets the overview, not the import screen")
    check(pg.get_by_role("tab", name="Employee mapping").count() == 1, "HR keeps Employee mapping (maps codes per device)")
    h.close()
    import urllib.request, urllib.error
    def call(who, fn, body):
        req = urllib.request.Request(f"{API}/rpc/{fn}", data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + jwt(U(who)), "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()
    s, b = call("b2", "biometric_dat_batches", {})
    check(s >= 400 and "Not allowed" in b, "HR calling the import list directly is refused")
    s, b = call("d4", "biometric_dat_rows", {"p_batch": bid, "p_filter": "all", "p_code": None, "p_offset": 0, "p_limit": 10})
    check(s >= 400, "an Employee calling the rows function directly is refused")
    req = urllib.request.Request(f"{API}/biometric_import_rows?select=raw_line&limit=1", headers={"Authorization": "Bearer " + jwt(U("a1"))})
    try:
        with urllib.request.urlopen(req) as r:
            st = r.status
    except urllib.error.HTTPError as e:
        st = e.code
    check(st in (401, 403), f"even an Admin cannot read the rows table directly over the API (HTTP {st})")

    # ---------------------------------------------------------------- nothing outside import staging changed
    check(sql(SNAP_SQL) == before, "attendance events, raw biometric events, event state, sync runs and review items are unchanged")
    check(sql(f"select count(*) from attendance_events where import_batch_id is not null") == "0", "no attendance row references an import")
    br.close()

passed = sum(1 for ok, _ in results if ok)
print(f"\n{passed}/{len(results)} checks passed")
sys.exit(0 if passed == len(results) else 1)
