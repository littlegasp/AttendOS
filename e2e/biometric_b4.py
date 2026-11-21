"""
B4 browser tests: biometric attendance in the application, against the LOCAL demo stack only
(supabase/demo: PostgreSQL + PostgREST on :3001 with biometric_demo.sql; the static app built with the demo URL).
Never point this at a hosted project.

Covers: role-by-role access and actions (Admin, HR, Manager, Employee) with the database checked after each action;
source labels (Web / Biometric / Imported / Correction); biometric verification wording; provisional check-out kept
out of final hours; CSV Source column; day timeline and history; dark/light; 390 / 820 / 1440 px; empty, loading and
error states; raw-payload privacy (every network request recorded).

Usage: python3 e2e/biometric_b4.py http://localhost:4174 out-dir     (rebuild the demo first: supabase/demo/rebuild.sh)
"""
import csv
import io
import json
import os
import re
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
_src = open(os.path.join(HERE, "regression.py")).read().split("with sync_playwright() as p:")[0]
exec(compile(_src, "regression_helpers", "exec"))  # sql, rpc, jwt, U, Ctx, check, results, APP, OUT, API, REMOTE

SHOTS = os.path.join(OUT, "b4")
os.makedirs(SHOTS, exist_ok=True)
CID = "cccccccc-0000-0000-0000-00000000000a"
TODAY = sql(f"select local_today('{CID}')")
D = lambda n: sql(f"select (local_today('{CID}') - {n})::text")
NAMES = {"a1": "Admin", "b2": "HR", "c3": "Manager", "d4": "Employee", "c7": "Employee (Deepak, biometric)", "a4": "Employee (Suresh, biometric)", "b6": "Employee (Anita)"}


def api(method, path, who, body=None):
    """Direct REST call as a person (the same thing a modified browser could send)."""
    req = urllib.request.Request(f"{API}/{path}", method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + jwt(U(who)), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or "null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or "null")


def shot(pg, name, full=True):
    pg.screenshot(path=os.path.join(SHOTS, f"{name}.png"), full_page=full)


def no_sideways(pg):
    return pg.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1")


class Rec:
    """Records every request a page makes to the API and every response body (privacy checks)."""
    def __init__(self, ctx):
        self.urls, self.bodies, self.writes = [], [], []
        ctx.page.on("request", self.on_req)
        ctx.page.on("response", self.on_res)

    def on_req(self, req):
        if REMOTE in req.url:
            self.urls.append(req.url)
            if req.method in ("POST", "PATCH", "PUT", "DELETE"):
                self.writes.append((req.method, req.url.split("/rest/v1/")[-1].split("?")[0]))

    def on_res(self, res):
        if REMOTE in res.url:
            try:
                self.bodies.append(res.text())
            except Exception:
                pass


def tabs_of(pg):
    return [t.strip() for t in pg.locator(".bio-tabs .tab-btn").all_inner_texts()]


with sync_playwright() as p:
    br = p.chromium.launch(executable_path="/usr/bin/google-chrome", args=["--no-sandbox"])

    # ================================================================ 1. Admin: full module, device management, company-wide codes
    c = Ctx(br, "a1")
    rec = Rec(c)
    pg = c.go("/biometric")
    pg.get_by_text("Company records — changes here are saved and audited.").wait_for()
    body = pg.inner_text("main")
    check("demo" not in body.lower() and "Demonstration" not in body, "Admin: live module, no demonstration wording or '· demo' labels")
    check([re.sub(r"\s*\d+$", "", t.split("\n")[0]) for t in tabs_of(pg)] == ["Overview", "Devices", "Employee mapping", "Sync activity", "Review queue"], f"Admin: the five approved B2 tabs ({tabs_of(pg)})")
    check(pg.get_by_text("Pune Plant reception PC").count() > 0 and pg.get_by_text("Not reported").count() >= 1, "Admin: Sync Agents are real records; the queue depth is shown as Not reported (never invented)")
    shot(pg, "admin-overview-dark")
    pg = c.go("/biometric?tab=devices")
    check(pg.get_by_role("button", name="Add device").count() == 1, "Admin: Add device is offered")
    pg.get_by_role("button", name="Plant gate (In/Out keys)").first.click()
    pg.wait_for_timeout(800)
    check(pg.locator("#bio-dir").count() == 1 and pg.locator("#bio-dir").is_enabled(), "Admin: device direction can be changed")
    check(pg.get_by_role("button", name="Test connection").is_disabled() and pg.get_by_role("button", name="Sync now").is_disabled(), "Admin: hardware actions stay disabled (no device is contacted)")
    shot(pg, "admin-device-detail")
    dev = sql("select id from biometric_devices where serial_number = 'AF8K2311000457'")
    pg.get_by_role("button", name="Disable device").click()
    pg.get_by_role("button", name="Disable device").last.click()
    pg.wait_for_timeout(1200)
    check(sql(f"select status from biometric_devices where id = '{dev}'") == "disabled", "Admin: Disable device (with confirmation) is saved in the database")
    pg.get_by_role("button", name="Enable device").click()
    pg.wait_for_timeout(1200)
    check(sql(f"select status from biometric_devices where id = '{dev}'") == "active", "Admin: Enable device is saved in the database")
    audit = sql(f"select count(*) from audit_log where target = 'biometric_devices' and target_id = '{dev}' and at > now() - interval '2 minutes'")
    check(int(audit) >= 2, f"Admin: both device changes are in the audit history ({audit} entries)")
    # add a device through the 8-step wizard
    pg = c.go("/biometric?tab=devices")
    pg.get_by_role("button", name="Add device").click()
    dlg = pg.locator("dialog[open]")
    dlg.get_by_text("ZKTeco", exact=True).click(); dlg.get_by_role("button", name="Next").click()
    dlg.get_by_label("Device name").fill("B4 test door"); dlg.get_by_label("Model").fill("MB160"); dlg.get_by_label("Serial number").fill("B4TEST0001"); dlg.get_by_role("button", name="Next").click()
    dlg.get_by_label("Office / location").select_option(label="Pune Plant"); dlg.get_by_role("button", name="Next").click()
    dlg.locator("input[type=radio]").first.check(); dlg.get_by_role("button", name="Next").click()
    dlg.get_by_label("Device IP address (office network)").fill("10.20.0.77"); dlg.get_by_role("button", name="Next").click()
    dlg.get_by_label("Sync Agent").select_option(label=[o for o in dlg.get_by_label("Sync Agent").locator("option").all_inner_texts() if "Pune Plant reception PC" in o][0]); dlg.get_by_role("button", name="Next").click()
    dlg.get_by_role("button", name="Next").click()
    shot(pg, "admin-add-device-review")
    dlg.get_by_role("button", name="Save device").click()
    pg.wait_for_timeout(1500)
    row = sql("select name || '|' || integration_method || '|' || status || '|' || (location_id = '22222222-2222-2222-2222-222222222222') from biometric_devices where serial_number = 'B4TEST0001'")
    check(row.startswith("B4 test door|sdk_pull|active|t"), f"Admin: the wizard registers the device in the database ({row})")
    check(pg.get_by_text("B4 test door").count() > 0, "Admin: the new device's detail opens after saving")
    # company-wide option offered to Admin
    pg = c.go("/biometric?tab=mapping")
    pg.get_by_role("button", name="Map a code").click()
    opts = pg.locator("dialog[open] select").first.locator("option").all_inner_texts()
    check(any("company-wide" in o for o in opts), "Admin: company-wide mapping is offered")
    pg.keyboard.press("Escape")
    check(pg.get_by_text("Company-wide").count() > 0, "Admin: the company-wide code E0121 is listed as Company-wide")
    shot(pg, "admin-mapping")
    pg = c.go("/biometric?tab=review")
    shot(pg, "admin-review-queue")
    pg = c.go("/biometric?tab=sync")
    shot(pg, "admin-sync")
    admin_rec = rec
    c.close()

    # ================================================================ 2. HR: restricted configuration, mapping, review
    c = Ctx(br, "b2")
    rec = Rec(c)
    pg = c.go("/biometric?tab=devices")
    check(pg.get_by_role("button", name="Add device").count() == 0, "HR: no Add device")
    pg.get_by_role("button", name="Plant gate (In/Out keys)").first.click()
    pg.wait_for_timeout(800)
    check(pg.locator("#bio-dir").count() == 0 and pg.get_by_text("(changed by Admin)").count() == 1, "HR: device direction is read-only")
    check(pg.get_by_role("button", name="Disable device").count() == 0, "HR: cannot disable a device")
    shot(pg, "hr-device-detail")
    # map the unmatched code 299 on the plant gate from the review queue
    pg = c.go("/biometric?tab=mapping")
    pg.get_by_role("button", name="Map this code").first.click()
    dlg = pg.locator("dialog[open]")
    opts = dlg.locator("select").first.locator("option").all_inner_texts()
    check(not any("company-wide" in o for o in opts), "HR: company-wide mapping is not offered")
    code = dlg.get_by_label("Device employee code").input_value()
    dlg.get_by_label("AttendOS employee").select_option(label=[o for o in dlg.get_by_label("AttendOS employee").locator("option").all_inner_texts() if "Neha Gupta" in o][0])
    pg.wait_for_timeout(300)
    shot(pg, "hr-map-code")
    dlg.get_by_role("button", name="Save mapping").click()
    pg.wait_for_timeout(1500)
    m = sql(f"select count(*) from biometric_employee_mappings where employee_device_code = '{code}' and employee_id = '{U('f3')}' and created_by = '{U('b2')}'")
    att = sql(f"select string_agg(s.status || ':' || coalesce(s.employee_id::text, '-'), ',') from biometric_event_state s join biometric_raw_events r on r.id = s.raw_event_id where r.employee_device_code = '{code}' and r.device_id = (select device_id from biometric_employee_mappings where employee_device_code = '{code}' and employee_id = '{U('f3')}')")
    check(m == "1" and U("f3") in att and "unmatched" not in att, f"HR: device-specific mapping of code {code} saved; the waiting punch is attributed at its own time ({att})")
    # review: dismiss an unauthenticated warehouse punch with a reason
    pg = c.go("/biometric?tab=review")
    item = pg.locator(".bio-review-item", has_text="ARGO-FA-0091337").first
    rid = item.get_attribute("data-review").replace("raw-", "")
    ver = sql(f"select version from biometric_event_state where raw_event_id = {rid}")
    item.get_by_role("button", name="Dismiss").click()
    dlg = pg.locator("dialog[open]")
    dlg.get_by_label("Reason").fill("no")
    dlg.get_by_role("button", name="Dismiss").click()
    pg.wait_for_timeout(1000)
    blocked = dlg.locator("textarea").evaluate("t => !t.checkValidity()") or dlg.get_by_role("alert").count() == 1
    sc, rr = api("POST", "rpc/biometric_review_event", "b2", {"p_raw": int(rid), "p_action": "dismiss", "p_reason": "no", "p_expected_version": int(ver)})
    check(blocked and rr.get("ok") is False and "reason" in rr.get("message", "") and sql(f"select status from biometric_event_state where raw_event_id = {rid}") == "flagged",
          f"HR: a too-short reason is stopped in the form and refused by the database; nothing changes ({rr})")
    dlg.get_by_label("Reason").fill("Visitor badge test at the warehouse")
    dlg.get_by_role("button", name="Dismiss").click()
    pg.wait_for_timeout(1500)
    st = sql(f"select status || '|' || decided || '|' || version from biometric_event_state where raw_event_id = {rid}")
    rv = sql(f"select action || '|' || decided_role || '|' || reason from biometric_event_reviews where raw_event_id = {rid}")
    check(st == f"dismissed|true|{int(ver) + 1}" and rv == "dismiss|hr|Visitor badge test at the warehouse", f"HR: Dismiss saved with HR role, reason and a new version ({st}; {rv})")
    pg.get_by_label("Show").select_option("closed")
    pg.wait_for_timeout(400)
    it = pg.locator(f".bio-review-item[data-review='raw-{rid}']")
    it.get_by_role("button", name=re.compile("History")).click()
    hist = pg.locator("dialog[open]").inner_text()
    check("Hema Kulkarni · HR" in hist and "Visitor badge test at the warehouse" in hist, "HR: review history shows who decided, the role, and the reason")
    pg.keyboard.press("Escape")
    # a correction_needed punch can only be dismissed; the queue says why
    pg.get_by_label("Show").select_option("open")
    cn = pg.locator(".bio-review-item", has_text="Needs an attendance correction").first
    check(cn.get_by_role("button", name="Accept time as recorded").count() == 0 and "request an attendance correction" in cn.inner_text(), "HR: a correction_needed punch offers only Dismiss and points to the correction workflow")
    shot(pg, "hr-review-queue")
    # the database refuses Admin-only actions for HR even when called directly
    s1, r1 = api("POST", "rpc/biometric_save_device", "b2", {"p_id": None, "p": {"name": "x", "manufacturer": "zkteco", "model": "m", "serial_number": "HRTRY001", "integration_method": "sdk_pull"}})
    s2, r2 = api("POST", "rpc/biometric_set_direction_mode", "b2", {"p_id": dev, "p_mode": "device"})
    s3, r3 = api("POST", "rpc/biometric_save_mapping", "b2", {"p_code": "HR99", "p_device": None, "p_employee": U("f3"), "p_valid_from": "2026-11-21T00:00:00Z", "p_confirm_company_wide": True})
    check(s1 == 403 and s2 == 403 and s3 == 403 and sql("select count(*) from biometric_devices where serial_number = 'HRTRY001'") == "0",
          f"HR: direct calls to add a device, change direction or map company-wide are refused by the database ({s1}, {s2}, {s3})")
    hr_rec = rec
    c.close()

    # ================================================================ 3. Manager and Employee: no biometric module
    for who in ("c3", "d4"):
        c = Ctx(br, who)
        pg = c.go("/biometric")
        check(pg.get_by_text("You don't have access to Biometric Devices").count() == 1 and pg.get_by_role("link", name="Biometric Devices").count() == 0, f"{NAMES[who]}: permission denied, no menu item")
        st1, rows = api("GET", "biometric_devices?select=id", who)
        st2, raw = api("GET", "biometric_raw_events_safe?select=id", who)
        st3, _ = api("POST", "rpc/biometric_review_event", who, {"p_raw": 1, "p_action": "dismiss", "p_reason": "trying", "p_expected_version": 1})
        st4, _ = api("POST", "rpc/biometric_raw_payload", who, {"p_raw": 1})
        check(rows == [] and raw == [] and st3 == 403 and st4 in (401, 403, 404), f"{NAMES[who]}: database returns no biometric rows and refuses review/payload calls (devices {st1} {rows}, raw {st2} {raw}, review {st3}, payload {st4})")
        if who == "d4":
            shot(pg, "employee-denied")
        c.close()

    # ================================================================ 4–6. Sources, verification wording, provisional check-out
    c = Ctx(br, "a1")
    rec = Rec(c)
    pg = c.go("/attendance")
    pg.get_by_label("Date").fill(TODAY)
    pg.wait_for_timeout(1500)
    deepak = pg.locator("tr", has_text="Deepak More")
    suresh = pg.locator("tr", has_text="Suresh Pawar")
    esha = pg.locator("tr", has_text="Esha Patil")
    check(deepak.locator("[data-source=biometric]").count() == 1 and esha.locator("[data-source=web]").count() == 1, "Register: Biometric and Web source labels on today's rows")
    check(deepak.get_by_test_id("provisional-out").count() == 1, "Register: Deepak's provisional check-out shown in the Check-out column")
    deep_db = sql(f"set role authenticated; select set_config('request.jwt.claim.sub', '{U('a1')}', false); select last_out is null and overtime_min = 0 and early_min = 0 and status = 'working' from attendance_register('{TODAY}', '{TODAY}', null, '{U('c7')}', null, null, 10, 0)").splitlines()[-1]
    check(deep_db == "t", "Engine: the provisional check-out is not a final check-out — no last out, no overtime, no early leaving, still working")
    check(sql(f"select count(*) from attendance_events where employee_id = '{U('c7')}' and work_date = '{TODAY}' and kind = 'out'") == "0", "Engine: no attendance row was created for the provisional check-out")
    fits = pg.locator("table").first.evaluate("t => t.closest('.table-wrap').scrollWidth <= t.closest('.table-wrap').clientWidth + 1")
    check(fits, "Register (1440 px): with the Source column the table still fits without scrolling inside the card")
    shot(pg, "register-daily-dark")
    # CSV
    with pg.expect_download() as dl:
        pg.get_by_role("button", name="Export CSV").click()
    path = os.path.join(SHOTS, "register-daily-sample.csv")
    dl.value.save_as(path)
    rows = list(csv.reader(io.StringIO(open(path, encoding="utf-8-sig").read())))
    head = rows[0]
    check(head[:15] == ["Employee", "Employee ID", "Department", "Date", "Shift", "Work location", "Check-in", "Check-out", "Working hours", "Break (min)", "Late (min)", "Early leave (min)", "Overtime (min)", "Status", "Note"] and head[15:] == ["Source"],
          f"CSV: existing 15 columns unchanged, Source added last ({head})")
    by = {r[0]: r for r in rows[1:]}
    check(by["Deepak More"][15] == "Biometric" and by["Esha Patil"][15] == "Web" and by["Kiran Rao"][15] == "" and by["Deepak More"][7] == "",
          f"CSV: Source values (Deepak {by['Deepak More'][15]!r}, Esha {by['Esha Patil'][15]!r}, absent {by['Kiran Rao'][15]!r}); provisional check-out not exported as a check-out")
    # Employee detail view for Deepak: Correction + Biometric on the corrected day
    pg.get_by_role("tab", name="Employee detail").click()
    pg.locator("label.filter-chip", has_text="Employee").locator("select").select_option(label="Deepak More")
    pg.locator("[data-source=correction]").first.wait_for(timeout=10000)
    import datetime as _dt
    row2 = pg.locator("tbody tr", has_text=_dt.date.fromisoformat(D(2)).strftime("%d %b %Y"))
    srcs = sorted(row2.first.locator("[data-source]").evaluate_all("els => els.map(e => e.dataset.source)"))
    check(srcs == ["biometric", "correction"], f"Register: the corrected day shows Biometric + Correction ({srcs})")
    with pg.expect_download() as dl:
        pg.get_by_role("button", name="Export CSV").click()
    path2 = os.path.join(SHOTS, "register-person-sample.csv")
    dl.value.save_as(path2)
    rows2 = list(csv.reader(io.StringIO(open(path2, encoding="utf-8-sig").read())))
    vals = {r[15] for r in rows2[1:]}
    check("Biometric + Correction" in vals and "Biometric" in vals, f"CSV: person month export has Source values {sorted(vals)}")
    shot(pg, "register-person")
    # timeline: yesterday for Deepak (counted rows + extra punch + possible duplicate), corrected day, Anita's imported punch
    pg.get_by_role("button", name=re.compile("Timeline for Deepak More")).first.click()
    pg.locator("dialog[open] .timeline-table, dialog[open] .state").first.wait_for()
    pg.wait_for_timeout(500)
    c.close()

    c = Ctx(br, "b2")
    pg = c.go("/attendance")
    pg.get_by_label("Date").fill(D(1))
    pg.wait_for_timeout(1200)
    pg.get_by_role("button", name="Timeline for Deepak More").click()
    dlg = pg.locator("dialog[open]")
    dlg.locator(".timeline-table").wait_for()
    t = dlg.inner_text()
    counted = dlg.locator("tr[data-counted=yes][data-source=biometric]").count()
    check(counted == 2 and "Extra punch" in t and "Possible duplicate" in t and "Biometric device record" in t and "GPS-verified" in t and "Location verified" not in t,
          f"Timeline: 2 counted biometric rows, the extra punch and the possible duplicate shown as not counted; biometric never 'Location verified' ({counted})")
    check("HQ main entrance" in t, "Timeline: device name shown")
    shot(pg, "timeline-hr-yesterday")
    pg.keyboard.press("Escape")
    pg.get_by_label("Date").fill(D(2))
    pg.wait_for_timeout(1200)
    pg.get_by_role("button", name="Timeline for Deepak More").click()
    dlg = pg.locator("dialog[open]")
    dlg.locator(".timeline-table").wait_for()
    t = dlg.inner_text()
    check(dlg.locator("tr[data-source=correction][data-counted=yes]").count() == 1 and "Replaced by a correction" in t, "Timeline: the correction counts; the biometric check-in it replaced stays on record")
    pg.keyboard.press("Escape")
    pg.get_by_label("Date").fill(D(5))
    pg.wait_for_timeout(1200)
    pg.get_by_role("button", name="Timeline for Anita Kale").click()
    dlg = pg.locator("dialog[open]")
    dlg.locator(".timeline-table").wait_for()
    t = dlg.inner_text()
    check(dlg.locator("tr[data-source=import]").count() == 1 and "Imported" in t and "Waiting for HR" in t and "IN (device key)" in t, "Timeline: imported punch labelled Imported, waiting (imports are not counted automatically), direction shown to HR")
    shot(pg, "timeline-imported")
    pg.keyboard.press("Escape")
    # verification history (Settings → Locations & GPS): biometric rows never 'Verified'
    pg = c.go("/settings")
    pg.get_by_role("tab", name="Verification history").click()
    pg.wait_for_timeout(1500)
    vh = pg.locator("text=Biometric · not GPS-verified")
    check(vh.count() >= 1, f"Verification history: biometric rows say 'Biometric · not GPS-verified' ({vh.count()})")
    c.close()

    # ================================================================ employee view: own today, history, timeline (no module access)
    c = Ctx(br, "c7")
    rec_emp = Rec(c)
    pg = c.go("/my-attendance")
    pg.get_by_test_id("today-provisional").wait_for()
    tl = pg.locator(".timeline").inner_text()
    check("Biometric device record · not GPS-verified" in tl and "location verified" not in tl, "Employee today: biometric check-in labelled 'Biometric device record · not GPS-verified'")
    check("not counted in your hours yet" in pg.get_by_test_id("today-provisional").inner_text(), "Employee today: provisional check-out explained, not in hours")
    shot(pg, "employee-today-dark")
    pg.get_by_role("tab", name="History").click()
    pg.wait_for_timeout(1500)
    hist = pg.locator(".history-table")
    check(hist.locator("[data-source=biometric]").count() >= 2 and hist.locator("[data-source=correction]").count() >= 1, "Employee history: Source column with Biometric and Correction")
    check(hist.get_by_test_id("provisional-out").count() == 1, "Employee history: today's provisional check-out shown, not as a final time")
    fits = pg.locator(".history-table").evaluate("w => w.scrollWidth <= w.clientWidth + 1")
    check(fits, "Employee history (1440 px): the table with the new Source column fits without scrolling inside the card")
    shot(pg, "employee-history")
    pg.get_by_role("button", name=re.compile(f"Timeline for")).first.click()
    pg.locator("dialog[open]").get_by_text("Day timeline").first.wait_for()
    pg.wait_for_timeout(800)
    dtext = pg.locator("dialog[open]").inner_text()
    check(pg.get_by_test_id("provisional-note").count() == 1 and "OUT (provisional)" in dtext, "Employee timeline: provisional note and an OUT (provisional) row")
    shot(pg, "employee-timeline-today")
    check(not any("biometric_raw_events_safe" in u for u in rec_emp.urls), "Employee: never asks for raw device records (direction lookup is HR/Admin only)")
    c.close()

    # ================================================================ 9–10. themes and sizes (visual regression after the badge colours)
    import datetime as _dt
    sizes = {"phone": (390, 844), "tablet": (820, 1180), "desktop": (1440, 900)}
    SCREENS = [  # (who, path, name, action)
        ("a1", "/biometric", "overview", None), ("a1", "/biometric?tab=devices", "devices", None), ("a1", "/biometric?tab=mapping", "mapping", None),
        ("a1", "/biometric?tab=sync", "sync", None), ("a1", "/biometric?tab=review", "review", None), ("b2", "/attendance", "register", None),
        ("c7", "/my-attendance", "my-attendance", None), ("c7", "/my-attendance", "timeline", "timeline"), ("b2", "/settings", "verification-history", "verification"),
    ]
    FOCUS_JS = """() => { const e = document.activeElement; if (!e || e === document.body) return null; const cs = getComputedStyle(e);
      return (cs.outlineStyle !== 'none' && parseFloat(cs.outlineWidth) > 0) || (cs.boxShadow && cs.boxShadow !== 'none'); }"""
    matrix, focus_ok = [], []
    for theme in ("dark", "light"):
        for label, (w, h) in sizes.items():
            for who, path, name, action in SCREENS:
                c = Ctx(br, who, theme=theme)
                c.page.set_viewport_size({"width": w, "height": h})
                pg = c.go(path)
                pg.wait_for_timeout(700)
                if action == "timeline":
                    pg.get_by_role("tab", name="History").click()
                    pg.wait_for_timeout(1200)
                    pg.locator("button:visible", has_text=re.compile(r"^(Timeline|\w{3}, \d+ \w{3})$")).first.click()
                    pg.locator("dialog[open]").get_by_text("Day timeline").first.wait_for()
                    pg.wait_for_timeout(600)
                elif action == "verification":
                    pg.get_by_role("tab", name="Verification history").click()
                    pg.wait_for_timeout(1500)
                ok = no_sideways(pg) and not c.errors
                if action == "timeline":
                    ok = ok and pg.locator("dialog[open]").evaluate("d => d.scrollWidth <= d.clientWidth + 1")
                if name == "review" and label == "desktop":
                    pg.keyboard.press("Tab"); pg.keyboard.press("Tab"); pg.keyboard.press("Tab")
                    focus_ok.append((theme, pg.evaluate(FOCUS_JS)))
                shot(pg, f"{name}-{label}-{theme}", full=False)
                matrix.append((f"{name}-{label}-{theme}", ok, c.errors[:2]))
                c.close()
    bad = [m for m in matrix if not m[1]]
    check(not bad, f"Visual regression: {len(matrix)} screen loads (9 screens incl. day timeline and verification history × dark/light × 390/820/1440) without sideways scrolling or console errors {bad}")
    check(all(f[1] for f in focus_ok) and len(focus_ok) == 2, f"Keyboard focus stays visible in both themes ({focus_ok})")

    # source badge contrast as painted in the browser (WCAG AA ≥ 4.5:1), every source, both themes
    RATIO_JS = r"""() => {
      const rgba = (s) => { const n = s.match(/[\d.]+/g).map(Number); return s.startsWith('color(') ? [n[0]*255, n[1]*255, n[2]*255, n[3] ?? 1] : [n[0], n[1], n[2], n[3] ?? 1]; };
      const lum = ([r,g,b]) => { const f = v => { v/=255; return v <= .03928 ? v/12.92 : ((v+.055)/1.055)**2.4 }; return .2126*f(r)+.7152*f(g)+.0722*f(b); };
      const under = (el) => { let e = el.parentElement; while (e) { const c = rgba(getComputedStyle(e).backgroundColor); if (c[3] > 0.5) return c; e = e.parentElement; } return document.documentElement.dataset.theme === 'light' ? [255,255,255,1] : [9,14,23,1]; };
      return [...document.querySelectorAll('.src-badge[data-source]')].filter(b => b.offsetParent !== null).map(b => { const cs = getComputedStyle(b); const fg = rgba(cs.color); const bg = rgba(cs.backgroundColor); const base = under(b);
        const mix = [0,1,2].map(i => base[i]*(1-bg[3]) + bg[i]*bg[3]); const m = (cs.filter.match(/brightness\(([\d.]+)\)/) || [0, 1])[1] * 1;
        const a = lum(fg.map(v => v*m)), x = lum(mix.map(v => v*m)); return [b.dataset.source, (Math.max(a,x)+.05)/(Math.min(a,x)+.05)]; });
    }"""
    painted = {}
    for theme in ("light", "dark"):
        got = {}
        def take(pg):
            for src, r in pg.evaluate(RATIO_JS):
                got.setdefault(src, []).append(r)
        c = Ctx(br, "b2", theme=theme)
        pg = c.go("/attendance"); pg.locator(".src-badge[data-source=web]").first.wait_for(); take(pg)
        pg.get_by_role("tab", name="Employee detail").click()
        pg.locator("label.filter-chip", has_text="Employee").locator("select").select_option(label="Deepak More")
        pg.locator(".src-badge[data-source=correction]").first.wait_for(); take(pg)
        pg.get_by_role("tab", name="Daily").click()
        pg.locator("label.filter-chip", has_text="Employee").locator("select").select_option(value="")
        pg.get_by_label("Date").fill(D(5)); pg.wait_for_timeout(1200)
        pg.get_by_role("button", name="Timeline for Anita Kale").click()
        pg.locator("dialog[open] .src-badge[data-source=import]").first.wait_for(); take(pg)
        shot(pg, f"contrast-imported-{theme}", full=False)
        pg.keyboard.press("Escape")
        pg = c.go("/settings"); pg.get_by_role("tab", name="Verification history").click(); pg.wait_for_timeout(1500); take(pg)
        c.close()
        painted[theme] = {k: round(min(v), 2) for k, v in got.items()}
        check(set(painted[theme]) >= {"web", "biometric", "import", "correction"} and min(painted[theme].values()) >= 4.5,
              f"{theme} theme: every source badge meets WCAG AA as painted (lowest per source {painted[theme]})")
    json.dump(painted, open(os.path.join(OUT, "b4-contrast.json"), "w"), indent=1)

    # ================================================================ 14. empty, loading and error states
    c = Ctx(br, "a1", block="biometric_devices")
    pg = c.go("/biometric")
    pg.get_by_text("Couldn't load the biometric records").wait_for(timeout=15000)
    check(pg.get_by_text("Couldn't load the biometric records").count() == 1 and pg.get_by_role("button", name="Try again").count() >= 1, "Error state: API failure shows a message and Try again")
    shot(pg, "state-error")
    c.close()
    c = Ctx(br, "b2", block="attendance_day_sources")
    pg = c.go("/attendance")
    pg.wait_for_timeout(1500)
    check(pg.locator("table").count() >= 1 and pg.get_by_text("Deepak More").count() >= 1, "Error state: if sources cannot load, the register still shows (Source left blank)")
    c.close()
    c = Ctx(br, "a1")
    c.page.route(REMOTE + "/rpc/day_events*", lambda route, req: (__import__("time").sleep(2.5), c._route(route, req)))
    pg = c.go("/attendance")
    pg.wait_for_timeout(800)
    pg.get_by_role("button", name=re.compile("Timeline for")).first.click()
    loading = pg.locator("dialog[open]").get_by_label("Loading the day").count() + pg.locator("dialog[open] .skeleton, dialog[open] [aria-busy=true]").count()
    check(loading >= 1, "Loading state: the timeline shows a loading placeholder while the day loads")
    pg.locator("dialog[open] .timeline-table, dialog[open] .state").first.wait_for(timeout=15000)  # let the slowed request finish before closing
    c.close()
    # empty module: a company with no biometric records (Beta); make its employee an Admin for this check only
    beta = sql("select id from employees where email = 'ben@beta.co'")
    sql(f"insert into auth.users (id, email) values ('{beta}', 'ben@beta.co') on conflict do nothing; update employees set role = 'admin', user_id = '{beta}' where id = '{beta}'")
    import types
    c = Ctx.__new__(Ctx)
    c.ctx = br.new_context(viewport={"width": 1440, "height": 900}, timezone_id="Asia/Kolkata")
    tok = jwt(beta)
    sess = dict(access_token=tok, refresh_token="r", token_type="bearer", expires_in=86400, expires_at=int(time.time()) + 86400, user=dict(id=beta, aud="authenticated", role="authenticated", email="ben@beta.co", app_metadata={}, user_metadata={}, created_at="2026-01-01T00:00:00Z"))
    c.ctx.add_init_script(f"localStorage.setItem('attendos.theme','dark');localStorage.setItem('attendos-auth',{json.dumps(json.dumps(sess))});")
    c.errors, c.block = [], None
    c.page = c.ctx.new_page()
    c.page.route(REMOTE + "/**", c._route)
    pg = c.go("/biometric")
    pg.wait_for_timeout(800)
    check(pg.get_by_text("No biometric devices yet").count() == 1, "Empty state: a company with no devices sees the first-time screen")
    shot(pg, "state-empty")
    pg = c.go("/biometric?tab=review")
    check(pg.get_by_text("Nothing waiting for review").count() == 1, "Empty state: review queue")
    c.close()
    sql(f"update employees set role = 'employee' where id = '{beta}'")

    # ================================================================ 15. raw-payload privacy across the recorded sessions
    allrec = [admin_rec, hr_rec, rec, rec_emp]
    urls = [u for r in allrec for u in r.urls]
    bodies = " ".join(b for r in allrec for b in r.bodies)
    check(not any(re.search(r"biometric_raw_payload|biometric_error_payload|/biometric_raw_events\?|biometric_agent_credentials", u) for u in urls), f"Privacy: no request for raw payloads, the raw table or agent credentials ({len(urls)} requests)")
    check(not re.search(r'"raw_payload"|"payload"\s*:|"key_hash"|"agent_key"', bodies), "Privacy: no payload, key hash or agent key in any response")
    writes = sorted(set(w for r in (admin_rec, hr_rec) for w in r.writes))
    allowed = {"rpc/biometric_set_device_status", "rpc/biometric_save_device", "rpc/biometric_save_mapping", "rpc/biometric_review_event", "rpc/biometric_end_mapping", "rpc/biometric_set_direction_mode"}
    reads = {w for w in writes if w[1] not in allowed}
    check(all(w[0] == "POST" and (w[1] in allowed or w[1].startswith("rpc/")) for w in writes) and not any(w[0] in ("PATCH", "DELETE", "PUT") for w in writes),
          f"Privacy/permissions: changes go only through checked functions; no direct table writes ({[w[1] for w in writes]})")
    check(sql("select count(*) from biometric_settings where projection_enabled") == "0", "Projection is off for every company after the tests")

    br.close()

passed = sum(1 for ok, _ in results if ok)
print(f"\n{passed}/{len(results)} B4 checks passed")
json.dump([{"ok": ok, "check": w} for ok, w in results], open(os.path.join(OUT, "b4-results.json"), "w"), indent=1)
sys.exit(0 if passed == len(results) else 1)
