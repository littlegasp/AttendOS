"""
SUPERSEDED for connected mode by B4 (e2e/biometric_b4.py): since B4 a connected app shows the company's real
biometric records, so the demonstration banner and the in-tab demonstration data this script checks exist only in
preview mode (no database). Kept for the record of the B2 sign-off.

Phase B2 sign-off checks — Biometric Devices (demonstration data), run against the local demo stack.
  1. Role matrix in the interface, for Admin (a1), HR (b2), Manager (c3) and Employee (d1) separately.
  2. Demonstration mode: every network request during a full Admin session that performs every action is recorded;
     only the app's own files and read-only lookups may appear. A fingerprint of every public table is compared.
  3. Responsive and theme matrix: 1440 / 820 / 390 px × light / dark × every tab, device detail and dialogs.
Writes /tmp/b2-signoff/matrix.json with the observed role matrix.
Usage: python3 e2e/biometric_b2_signoff.py http://127.0.0.1:4176 /tmp/b2-signoff
"""
import json, os, re, subprocess, sys
from urllib.parse import urlparse

APP = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:4176"
OUT = OUT_SIGNOFF = sys.argv[2] if len(sys.argv) > 2 else "/tmp/b2-signoff"
os.makedirs(OUT, exist_ok=True)
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "regression.py")).read()
sys.argv = ["x", APP]
exec(src.split("\ndef events(")[0])  # APP, API, REMOTE, Ctx, check(), results (it also sets OUT; ours is restored below)
OUT = OUT_SIGNOFF
from playwright.sync_api import sync_playwright


def db(q):
    return subprocess.run(["psql", "-h", "/tmp/pg", "-p", os.environ.get("PGPORT", "5433"), "-U", "postgres", "-d", "attendos_demo", "-Atc", q], capture_output=True, text=True).stdout.strip()


def fingerprint():
    tables = db("select tablename from pg_tables where schemaname = 'public' order by 1").split()
    return {t: db(f"select count(*) || ':' || coalesce(md5(string_agg(x::text, '|' order by x::text)), '-') from public.{t} x") for t in tables}


def no_overflow(pg):
    return pg.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1")


before = fingerprint()
matrix = {}
TABS = ["Overview", "Devices", "Employee mapping", "Sync activity", "Review queue"]

with sync_playwright() as p:
    br = p.chromium.launch()

    # ------------------------------------------------------------ 1. role matrix (interface)
    for who, role in [("a1", "Admin"), ("b2", "HR"), ("c3", "Manager"), ("d1", "Employee")]:
        c = Ctx(br, who, theme="light")
        lookups = []
        c.page.on("request", lambda r: lookups.append(r.url) if "people_directory" in r.url or "/locations" in r.url else None)
        row = {}
        pg = c.go("/biometric")
        if role in ("Manager", "Employee"):
            denied = lambda: pg.get_by_text(re.compile("permission|don.t have access|do not have access", re.I)).count() > 0
            ok = denied()
            for q in ["?tab=devices", "?tab=review", "?tab=mapping", "?device=dev-1"]:
                pg = c.go("/biometric" + q)
                ok = ok and denied() and pg.locator(".bio-tabs, .bio-review-item, .emp-table").count() == 0
            check(ok, f"{role}: every biometric address shows permission denied (tabs and device detail included)")
            check(pg.locator("nav a[href*='/biometric']").count() == 0, f"{role}: no menu item")
            check(not [u for u in lookups if "people_directory" in u], f"{role}: the module loads no people data")
            for k in ["View devices", "Add / edit devices", "Disable devices", "Change punch direction", "Map device-specific codes", "Map company-wide codes",
                      "End mappings", "View sync activity", "Retry sync", "Review unmatched events", "Accept time / dismiss / duplicate decisions", "View review history", "View mapping history"]:
                row[k] = "no access"
            matrix[role] = row
            c.close()
            continue
        pg.get_by_text("Demonstration data — no biometric device").first.wait_for(timeout=15000)
        pg.get_by_role("tab", name=re.compile("^Devices")).click()
        pg.locator("#bio-q").wait_for()
        pg.locator(".emp-table tbody tr").first.wait_for()
        row["View devices"] = "yes" if pg.locator(".emp-table tbody tr").count() >= 5 else "NO"
        row["Add / edit devices"] = "yes" if pg.get_by_role("button", name="Add device").count() else "no (button absent)"
        pg.get_by_role("button", name="Staff gate").first.click()
        pg.get_by_text("Device information").wait_for()
        row["Disable devices"] = "yes" if pg.get_by_role("button", name="Disable device").count() else "no (button absent)"
        row["Change punch direction"] = "yes" if pg.locator("#bio-dir").count() else ("no (read-only text)" if "changed by Admin" in pg.inner_text("main") else "NO TEXT")
        retry_now = pg.get_by_role("button", name=re.compile("Sync now"))
        row["Retry sync"] = ("shown disabled (Phase B4)" if retry_now.count() and retry_now.is_disabled() else "absent")
        pg.get_by_role("tab", name=re.compile("^Employee mapping")).click()
        pg.get_by_text("Unmapped device codes").wait_for()
        row["Map device-specific codes"] = "yes" if pg.get_by_role("button", name="Map a code").count() else "no"
        pg.get_by_role("button", name="Map a code").click()
        dlg = pg.get_by_role("dialog", name="Map a device code")
        row["Map company-wide codes"] = "yes (with confirmation)" if any("company-wide" in o for o in dlg.locator("select").first.locator("option").all_inner_texts()) else "no (option absent)"
        dlg.get_by_role("button", name="Cancel").click()
        cw = pg.locator("tbody tr").filter(has_text="Company-wide").first
        dev_end = pg.locator("tbody tr").filter(has_text="Main entrance").get_by_role("button", name="End mapping")
        row["End mappings"] = f"device: {'yes' if dev_end.count() else 'no'}; company-wide: {'yes' if cw.get_by_role('button', name='End mapping').count() else 'no'}"
        row["View mapping history"] = "yes" if pg.get_by_text("Mapping history").count() else "no"
        pg.get_by_role("tab", name=re.compile("^Sync activity")).click()
        pg.get_by_text("Confirmed duplicates had the same identity").wait_for()
        row["View sync activity"] = "yes"
        rb = pg.get_by_role("button", name=re.compile("Retry failed syncs"))
        row["Retry sync"] += "; retry failed syncs: " + ("shown disabled (Phase B3–B4)" if rb.count() and rb.is_disabled() else "absent")
        pg.get_by_role("tab", name=re.compile("^Review queue")).click()
        pg.locator(".bio-review-item").first.wait_for()
        un = pg.locator(".bio-review-item").filter(has_text="Unmatched employee code").first
        row["Review unmatched events"] = "yes" if un.get_by_role("button", name="Map employee").count() else "no"
        ts = pg.locator(".bio-review-item").filter(has_text="Invalid or suspicious time").first
        du = pg.locator(".bio-review-item").filter(has_text="Possible duplicate").first
        row["Accept time / dismiss / duplicate decisions"] = "yes" if ts.get_by_role("button", name="Accept time as recorded").count() and ts.get_by_role("button", name="Dismiss").count() and du.get_by_role("button", name="Confirm duplicate").count() else "no"
        ts.get_by_role("button", name=re.compile("History")).click()
        hd = pg.get_by_role("dialog", name="Review history")
        row["View review history"] = "yes" if hd.locator("li").count() >= 1 else "no"
        hd.get_by_role("button", name="Close").click()
        matrix[role] = row
        check(not c.errors, f"{role}: no console errors")
        c.close()

    expected = {
        "Admin": {"Add / edit devices": "yes", "Disable devices": "yes", "Change punch direction": "yes", "Map company-wide codes": "yes (with confirmation)", "End mappings": "device: yes; company-wide: yes"},
        "HR": {"Add / edit devices": "no (button absent)", "Disable devices": "no (button absent)", "Change punch direction": "no (read-only text)", "Map company-wide codes": "no (option absent)", "End mappings": "device: yes; company-wide: no"},
    }
    for role, exp in expected.items():
        for k, v in exp.items():
            check(matrix[role][k] == v, f"{role}: {k} = {v} (observed {matrix[role][k]})")
        for k in ["View devices", "Map device-specific codes", "View sync activity", "Review unmatched events", "Accept time / dismiss / duplicate decisions", "View review history", "View mapping history"]:
            check(matrix[role][k] == "yes", f"{role}: {k}")
        check("disabled" in matrix[role]["Retry sync"], f"{role}: retry sync shown but disabled (later phase)")
    json.dump(matrix, open(f"{OUT}/matrix.json", "w"), indent=1)

    # ------------------------------------------------------------ 2. demonstration mode: full Admin session, every action
    reqs = []
    c = Ctx(br, "a1", theme="dark")
    c.page.on("request", lambda r: reqs.append((r.method, r.url, r.resource_type)))
    c.page.on("websocket", lambda ws: reqs.append(("WS", ws.url, "websocket")))
    pg = c.go("/biometric?tab=devices")
    pg.get_by_text("Main entrance").first.wait_for(timeout=15000)
    toasts = []
    def toast_text():
        pg.wait_for_timeout(250)
        t = pg.locator(".toasts").inner_text()
        toasts.append(t)
        return t
    # add device
    pg.get_by_role("button", name="Add device").first.click()
    d = pg.get_by_role("dialog")
    d.locator("input[name=maker][value=zkteco]").check(); d.get_by_role("button", name="Next").click()
    d.get_by_label("Device name").fill("Sign-off kiosk"); d.locator("#bio-model").fill("MB160"); d.get_by_label("Serial number").fill("SIGNOFF0001")
    d.get_by_role("button", name="Next").click(); d.get_by_label("Office / location").select_option(index=1); d.get_by_role("button", name="Next").click()
    d.locator("input[name=method][value=sdk_pull]").check()
    for _ in range(6):
        if d.get_by_role("button", name="Save sample device").count(): break
        d.get_by_role("button", name="Next").click(); pg.wait_for_timeout(150)
        if d.get_by_label("Device IP address (office network)").count(): d.get_by_label("Device IP address (office network)").fill("192.168.10.77")
        if d.get_by_label("Sync Agent").count(): d.get_by_label("Sync Agent").select_option("agt-1")
    d.get_by_role("button", name="Save sample device").click()
    pg.get_by_text("Device information").wait_for()
    check("not saved" in toast_text(), "toast: add device says demonstration — not saved")
    check(pg.get_by_role("button", name=re.compile("Test connection")).is_disabled(), "Test connection cannot be pressed (no device contact)")
    pg.select_option("#bio-dir", "device")
    check("not saved" in toast_text(), "toast: direction change says not saved")
    pg.get_by_role("button", name="Disable device").click(); pg.get_by_role("dialog").get_by_role("button", name="Disable device").click()
    check("not saved" in toast_text(), "toast: disable says not saved")
    # mapping, end mapping
    pg.get_by_role("tab", name=re.compile("^Employee mapping")).click()
    pg.get_by_role("button", name="Map this code").first.click()
    md = pg.get_by_role("dialog", name="Map a device code")
    for o in reversed(md.get_by_label("AttendOS employee").locator("option").all_inner_texts()[1:]):
        if "switched off" in o: continue
        md.get_by_label("AttendOS employee").select_option(label=o); pg.wait_for_timeout(100)
        if not md.get_by_role("button", name="Save mapping").is_disabled(): break
    md.get_by_role("button", name="Save mapping").click()
    check("not saved" in toast_text(), "toast: mapping says not saved")
    pg.get_by_role("button", name="End mapping").first.click()
    ed = pg.get_by_role("dialog"); ed.get_by_label("Reason").fill("Sign-off check"); ed.get_by_role("button", name="End mapping").click()
    check("not saved" in toast_text(), "toast: end mapping says not saved")
    # back-dated end over a processed punch: explained and blocked before saving
    row105 = pg.locator("tbody tr").filter(has_text="Main entrance").filter(has=pg.locator("th", has_text=re.compile("^105$")))
    row105.get_by_role("button", name="End mapping").click()
    ed = pg.get_by_role("dialog")
    import datetime
    ed.locator("input[type=datetime-local]").fill((datetime.datetime.now() - datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M"))
    ed.get_by_label("Reason").fill("Back-dated end")
    pg.wait_for_timeout(200)
    check("already processed punch" in ed.inner_text() and ed.get_by_role("button", name="End mapping").is_disabled(), "back-dated end that would move a processed punch is explained and blocked")
    pg.screenshot(path=f"{OUT}/limit-01-backdated-end-blocked.png")
    ed.get_by_role("button", name="Cancel").click()
    # review decisions
    pg.get_by_role("tab", name=re.compile("^Review queue")).click()
    pg.locator(".bio-review-item").first.wait_for()
    du = pg.locator(".bio-review-item").filter(has_text="Possible duplicate").first
    du.get_by_role("button", name="Confirm duplicate").click()
    dd = pg.get_by_role("dialog"); dd.get_by_role("button", name="Confirm duplicate").dblclick()
    check("demonstration only" in toast_text(), "toast: review decision says demonstration only")
    pg.locator(".filter-chip select").nth(1).select_option("closed")
    pg.wait_for_timeout(200)
    items = pg.locator(".bio-review-item").filter(has_text="Possible duplicate").filter(has_text="Confirm duplicate by")
    items.first.get_by_role("button", name=re.compile("History")).click()
    h = pg.get_by_role("dialog", name="Review history").inner_text()
    check(h.count("Confirm duplicate") >= 1 and h.count("Rohan Mehta (demonstration) · Admin") == 1, "double-click recorded exactly one decision, with actor and role")
    pg.get_by_role("dialog", name="Review history").get_by_role("button", name="Close").click()
    # empty + reset
    pg.get_by_role("button", name="Show the empty module").click(); pg.wait_for_timeout(200)
    pg.get_by_role("button", name="Reset sample data").click(); pg.wait_for_timeout(300)
    check(pg.get_by_text("Total devices").count() == 1, "reset restores sample data")
    pg = c.go("/biometric?tab=devices")
    check("Sign-off kiosk" not in pg.inner_text("main"), "reload discards every demonstration change")
    check(not c.errors, "demonstration session: no console errors")
    c.close()

    app_host = urlparse(APP).netloc
    # The app-wide Inter web-font stylesheet (pre-existing, every screen) is listed separately, not hidden.
    fonts = sorted({urlparse(u).netloc for m, u, t in reqs if urlparse(u).netloc in ("fonts.googleapis.com", "fonts.gstatic.com")})
    print("app-wide font requests:", fonts)
    other = [(m, u) for m, u, t in reqs if urlparse(u).netloc not in (app_host, "demo-attendos.supabase.co", "fonts.googleapis.com", "fonts.gstatic.com")]
    check(not other, "no request to any other host (no device IP, Sync Agent, gateway or outside service)" + (f": {other[:3]}" if other else ""))
    check(not [r for r in reqs if r[0] == "WS"], "no websocket opened")
    api = sorted({(m, urlparse(u).path) for m, u, t in reqs if "supabase.co" in u})
    writes = [a for a in api if a[0] not in ("GET", "HEAD", "OPTIONS") and not a[1].startswith("/rest/v1/rpc/")]
    rpcs = sorted({a[1] for a in api if a[1].startswith("/rest/v1/rpc/")})
    check(not writes, "no insert/update/delete request to the database API" + (f": {writes}" if writes else ""))
    json.dump({"api_calls": api, "rpcs": rpcs, "toasts": toasts}, open(f"{OUT}/network.json", "w"), indent=1)
    print("API calls during the session:", api)

    # ------------------------------------------------------------ 3. responsive × theme matrix
    for theme in ["light", "dark"]:
        for w, h_ in [(1440, 900), (820, 1180), (390, 844)]:
            c = Ctx(br, "a1", theme=theme, mobile=(w == 390))
            c.page.set_viewport_size({"width": w, "height": h_})
            pg = c.go("/biometric")
            pg.get_by_text("Demonstration data — no biometric device").first.wait_for(timeout=15000)
            bad = []
            for name in TABS:
                t = pg.get_by_role("tab", name=re.compile("^" + name))
                t.click(); pg.wait_for_timeout(350)
                b = t.bounding_box()
                if t.get_attribute("aria-selected") != "true" or b["x"] < 0 or b["x"] + b["width"] > w + 1: bad.append(f"tab {name} not visible")
                if not no_overflow(pg): bad.append(f"{name} overflows")
            # vertical scroll still works with the pointer over the tab bar
            pg.evaluate("window.scrollTo(0,0)")
            bb = pg.locator(".bio-tabs .tabs").bounding_box()
            pg.mouse.move(bb["x"] + 30, bb["y"] + bb["height"] / 2); pg.mouse.wheel(0, 500); pg.wait_for_timeout(350)
            if pg.evaluate("window.scrollY") < 100: bad.append("wheel over tab bar did not scroll the page")
            # device detail
            pg.get_by_role("tab", name=re.compile("^Devices")).click()
            pg.get_by_role("button", name="Warehouse door").first.click()
            pg.get_by_text("Device information").wait_for()
            if not no_overflow(pg): bad.append("device detail overflows")
            # dialogs: map a code + wizard — inside the viewport, every field and dropdown visible and reachable
            pg.get_by_role("tab", name=re.compile("^Employee mapping")).click()
            pg.get_by_role("button", name="Map a code").click()
            dlg = pg.get_by_role("dialog", name="Map a device code")
            db_ = dlg.bounding_box()
            if db_["x"] < 0 or db_["x"] + db_["width"] > w + 1: bad.append("mapping dialog wider than the screen")
            for i in range(dlg.locator("select").count()):
                s = dlg.locator("select").nth(i)
                s.scroll_into_view_if_needed()
                sb = s.bounding_box()
                if sb["x"] < 0 or sb["x"] + sb["width"] > w + 1 or s.locator("option").count() < 2: bad.append(f"dropdown {i} clipped or empty")
            dlg.get_by_role("button", name="Save mapping").scroll_into_view_if_needed()
            if not dlg.get_by_role("button", name="Save mapping").is_visible(): bad.append("mapping Save not reachable")
            pg.screenshot(path=f"{OUT}/dialog-map-{w}-{theme}.png")
            dlg.get_by_role("button", name="Cancel").click()
            pg.get_by_role("tab", name=re.compile("^Devices")).click()
            pg.get_by_role("button", name="Add device").first.click()
            wz = pg.get_by_role("dialog"); wb = wz.bounding_box()
            if wb["x"] < 0 or wb["x"] + wb["width"] > w + 1: bad.append("wizard wider than the screen")
            wz.get_by_role("button", name="Cancel").click()
            pg.get_by_role("tab", name=re.compile("^Review queue")).click()
            pg.locator(".bio-review-item").first.get_by_role("button", name="Dismiss").click()
            rd = pg.get_by_role("dialog"); rb_ = rd.bounding_box()
            if rb_["x"] < 0 or rb_["x"] + rb_["width"] > w + 1: bad.append("decision dialog wider than the screen")
            rd.get_by_role("button", name="Cancel").click()
            # empty state
            pg.get_by_role("button", name="Show the empty module").click(); pg.wait_for_timeout(250)
            if pg.get_by_text("No biometric devices yet").count() < 1 or not no_overflow(pg): bad.append("empty module")
            check(not bad and not c.errors, f"{w} px {theme}: 5 tabs, device detail, 3 dialogs, dropdowns, vertical scroll, empty state" + (f" — {bad} {c.errors[:2]}" if bad or c.errors else ""))
            c.close()

    # page-bottom screenshot: shows the dark sidebar is full height in a real viewport (full-page captures cut it)
    c = Ctx(br, "a1", theme="dark")
    pg = c.go("/biometric?tab=review")
    pg.locator(".bio-review-item").first.wait_for()
    pg.evaluate("window.scrollTo(0, document.body.scrollHeight)"); pg.wait_for_timeout(300)
    pg.screenshot(path=f"{OUT}/limit-02-dark-page-bottom-viewport.png")
    pg.goto(APP + "/biometric?tab=devices", wait_until="networkidle"); pg.wait_for_timeout(500)
    pg.get_by_role("button", name="Staff gate").first.click(); pg.get_by_text("Device information").wait_for()
    pg.screenshot(path=f"{OUT}/limit-03-hardware-actions-disabled.png")
    c.close()
    br.close()

after = fingerprint()
changed = [t for t in before if before[t] != after.get(t)]
check(not changed, f"every public table unchanged ({len(before)} tables, row count + content hash)" + (f": {changed}" if changed else ""))

fails = [w for ok, w in results if not ok]
print(json.dumps(matrix, indent=1))
print(f"\n{len(results) - len(fails)}/{len(results)} passed")
sys.exit(1 if fails else 0)
