"""
Phase B2 browser checks — Biometric Devices (demonstration data).
Uses the same local demo stack as regression.py (PostgREST :3001 on the demo database) and its signed-in contexts.
Usage: python3 e2e/biometric_b2.py http://127.0.0.1:4176 /tmp/b2-shots
"""
import os, re, subprocess, sys

APP = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:4176"
SHOTS = sys.argv[2] if len(sys.argv) > 2 else "/tmp/b2-shots"
os.makedirs(SHOTS, exist_ok=True)
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "regression.py")).read()
sys.argv = ["x", APP]
exec(src.split("\ndef events(")[0])  # APP, Ctx, check(), results, jwt …
from playwright.sync_api import sync_playwright

def db(q):
    return subprocess.run(["psql", "-h", "/tmp/pg", "-p", os.environ.get("PGPORT", "5433"), "-U", "postgres", "-d", "attendos_demo", "-Atc", q], capture_output=True, text=True).stdout.strip()

FINGERPRINT = "select (select count(*) from attendance_events)||'/'||(select count(*) from audit_log)||'/'||(select count(*) from employees)||'/'||(select count(*) from locations)"
before = db(FINGERPRINT)

def no_overflow(pg):
    return pg.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1")

def shot(pg, name, full=True):
    pg.wait_for_timeout(400)
    pg.screenshot(path=f"{SHOTS}/{name}.png", full_page=full)

with sync_playwright() as p:
    br = p.chromium.launch()

    # ---------------- access
    for who, role in [("c3", "manager"), ("d1", "employee")]:
        c = Ctx(br, who)
        pg = c.go("/biometric")
        pg.wait_for_timeout(800)
        txt = pg.inner_text("main")
        check("Permission denied" in txt or "don't have access" in txt.lower() or "do not have access" in txt.lower(), f"{role}: /biometric shows permission denied")
        check(pg.locator("nav a[href='/biometric'], nav a[href='/biometric/']").count() == 0, f"{role}: no Biometric Devices menu item")
        c.close()

    writes = []
    for theme in ["light", "dark"]:
        c = Ctx(br, "a1", theme=theme)
        c.page.on("request", lambda r: writes.append(f"{r.method} {r.url}") if r.method not in ("GET", "HEAD", "OPTIONS") else None)
        pg = c.go("/biometric")
        pg.get_by_text("Demonstration data — no biometric device").first.wait_for(timeout=15000)
        if theme == "light":
            check(pg.locator("nav a[href*='/biometric']").count() >= 1, "admin: Biometric Devices in the Configuration menu")
            check(pg.get_by_text("Total devices").count() == 1 and pg.get_by_text("Unmatched punches").count() == 1, "overview shows device and review counters")
            check("real records" in pg.inner_text("main"), "banner says people and offices are real (read-only) when connected")
        shot(pg, f"01-overview-{theme}")

        pg.get_by_role("tab", name=re.compile("^Devices")).click()
        pg.get_by_text("Main entrance").first.wait_for()
        shot(pg, f"02-devices-{theme}")
        if theme == "light":
            pg.fill("#bio-q", "X990")
            pg.wait_for_timeout(300)
            check(pg.locator(".emp-table tbody tr").count() == 1, "device search narrows the list")
            pg.fill("#bio-q", "")
            pg.locator(".filter-chip select").first.select_option("matrix")
            pg.wait_for_timeout(300)
            check(pg.locator(".emp-table tbody tr").count() == 1 and "Warehouse door" in pg.inner_text(".emp-table"), "manufacturer filter works")
            pg.get_by_role("button", name="Clear filters").click()
            pg.fill("#bio-q", "no such device")
            pg.wait_for_timeout(300)
            check(pg.get_by_text("No devices match").count() == 1, "empty state when nothing matches")
            pg.fill("#bio-q", "")

        pg.get_by_role("button", name="Staff gate").first.click()
        pg.get_by_text("Device information").wait_for()
        shot(pg, f"03-device-detail-{theme}")
        if theme == "light":
            check(pg.get_by_role("button", name=re.compile("Test connection")).is_disabled() and pg.get_by_role("button", name=re.compile("Sync now")).is_disabled(), "hardware actions are visible but disabled (later phases)")
            check("behind the agent" in pg.inner_text("main") and "over the 5-minute limit" in pg.inner_text("main"), "clock drift shown and flagged")
            pg.select_option("#bio-dir", "first_last")
            check(pg.locator("#bio-dir").input_value() == "first_last", "direction mode changes locally")
            pg.get_by_role("button", name="Disable device").click()
            pg.get_by_role("dialog").get_by_role("button", name="Disable device").click()
            pg.wait_for_timeout(300)
            check(pg.get_by_role("button", name="Enable device").count() == 1 and "Disabled" in pg.inner_text(".profile-head-card"), "disable needs confirmation and updates the status")
            pg.get_by_role("button", name="Enable device").click()

        # ---------------- wizard
        pg.get_by_role("button", name="‹ All devices").click()
        pg.get_by_role("button", name="Add device").first.click()
        dlg = pg.get_by_role("dialog")
        dlg.get_by_text("Demonstration only.").wait_for()
        if theme == "light":
            dlg.get_by_role("button", name="Next").click()
            check(dlg.get_by_text("Choose the manufacturer.").count() == 1, "wizard validates each step")
        dlg.locator("input[name=maker][value=essl]").check()
        dlg.get_by_role("button", name="Next").click()
        dlg.get_by_label("Device name").fill("Lobby kiosk")
        dlg.locator("#bio-model").fill("uFace 302")
        dlg.get_by_label("Serial number").fill("UF302B24110042")
        dlg.get_by_role("button", name="Next").click()
        dlg.get_by_label("Office / location").select_option(index=1)
        dlg.get_by_role("button", name="Next").click()
        dlg.locator("input[name=method][value=local_push]").check()
        dlg.get_by_role("button", name="Next").click()
        shot(pg, f"04-wizard-connection-{theme}", full=False)
        if theme == "light":
            dlg.get_by_label("Device IP address (office network)").fill("203.0.113.7")
            dlg.get_by_role("button", name="Next").click()
            check(dlg.get_by_text(re.compile("private office-network address")).count() == 1, "public IP refused — devices are never reached over the internet")
        dlg.get_by_label("Device IP address (office network)").fill("192.168.10.50")
        dlg.get_by_role("button", name="Next").click()
        dlg.get_by_label("Sync Agent").select_option("agt-1")
        dlg.get_by_role("button", name="Next").click()
        dlg.get_by_role("button", name="Next").click()
        shot(pg, f"05-wizard-review-{theme}", full=False)
        dlg.get_by_role("button", name="Save sample device").click()
        pg.get_by_text("Device information").wait_for()
        if theme == "light":
            check("Lobby kiosk" in pg.inner_text(".profile-head-card") and "Not connected" in pg.inner_text(".profile-head-card"), "saved sample device opens as Not connected")

        # ---------------- mapping
        pg.get_by_role("tab", name=re.compile("^Employee mapping")).click()
        pg.get_by_text("Unmapped device codes").wait_for()
        shot(pg, f"06-mapping-{theme}")
        if theme == "light":
            pg.get_by_role("button", name="Map this code").first.click()
            md = pg.get_by_role("dialog", name="Map a device code")
            check(md.get_by_label("Device employee code").input_value() in ("117", "205"), "unmapped code pre-filled")
            dev_opts = md.locator("select").first.locator("option").all_inner_texts()
            check(md.locator("select").first.input_value() in ("dev-1", "dev-3"), "device-specific by default: the device that sent the code is pre-selected")
            check(any("company-wide" in o for o in dev_opts), "admin: company-wide is an explicit extra option")
            save = md.get_by_role("button", name="Save mapping")
            check(save.is_disabled(), "no employee chosen → Save disabled (no guessing)")
            opts = md.get_by_label("AttendOS employee").locator("option").all_inner_texts()
            chosen = None
            for o in reversed(opts[1:]):
                if "switched off" in o: continue
                md.get_by_label("AttendOS employee").select_option(label=o)
                pg.wait_for_timeout(150)
                if not save.is_disabled(): chosen = o; break
            check(chosen is not None and md.get_by_text("Before you save").count() == 1, "conflict panel shown before saving")
            check("waiting punch" in md.inner_text(), "panel says which waiting punches the mapping will attribute")
            check("only this browser tab changes" in md.inner_text(), "dialog states it is a demonstration")
            save.click()
            pg.wait_for_timeout(400)
            check(not pg.get_by_role("dialog", name="Map a device code").is_visible(), "valid mapping saved locally")
            check("not saved" in pg.locator(".toasts").inner_text(), "toast says demonstration — not saved")
            pg.get_by_role("button", name="Map a code").click()
            md = pg.get_by_role("dialog", name="Map a device code")
            md.locator("select").first.select_option("dev-1")
            md.get_by_label("Device employee code").fill("101")
            md.get_by_label("AttendOS employee").select_option(index=len(opts) - 2)
            pg.wait_for_timeout(200)
            check(md.locator(".alert.danger").count() >= 1 and "already mapped" in md.inner_text() and md.get_by_role("button", name="Save mapping").is_disabled(), "conflict (code already mapped on this device) blocks saving and explains why")
            md.locator("select").first.select_option("dev-2")
            pg.wait_for_timeout(200)
            check("already mapped" not in md.inner_text(), "the same code on another device is not a conflict")
            md.locator("select").first.select_option("__company__")
            pg.wait_for_timeout(200)
            t = md.inner_text()
            check("keeps precedence" in t and md.get_by_role("button", name="Save mapping").is_disabled(), "company-wide: warns devices keep their own mapping; needs confirmation")
            md.locator(".check-row input").check()
            check(not md.get_by_role("button", name="Save mapping").is_disabled(), "company-wide enabled only after explicit confirmation")
            shot(pg, "06b-mapping-conflicts-light", full=False)
            md.get_by_role("button", name="Cancel").click()
            # who had code 107 on Main entrance: the leaver before the re-use, the new person after
            w = pg.locator("section, .card").filter(has_text="Who had this code?").last
            w.get_by_label("Device", exact=True).select_option("dev-1")
            w.get_by_label("Device code").fill("107")
            pg.wait_for_timeout(200)
            now_who = pg.get_by_test_id("who-result").inner_text()
            import datetime
            past = (datetime.datetime.now() - datetime.timedelta(days=100)).strftime("%Y-%m-%dT10:00")
            w.locator("input[type=datetime-local]").fill(past)
            pg.wait_for_timeout(200)
            past_who = pg.get_by_test_id("who-result").inner_text()
            who = lambda t: (re.search(r"(?:am|pm): (.+?) \(", t) or [None, None])[1]
            check("device mapping" in now_who and "device mapping" in past_who and who(now_who) and who(past_who) and who(now_who) != who(past_who), "historical punches keep the mapping in force at that time (code re-used)")
            # end a mapping: reason required, history keeps it
            pg.get_by_role("button", name="End mapping").first.click()
            ed = pg.get_by_role("dialog")
            ed.get_by_role("button", name="End mapping").click()
            check(ed.is_visible() and ed.get_by_label("Reason").evaluate("e => !e.checkValidity()"), "ending a mapping needs a reason")
            ed.get_by_label("Reason").fill("Moved to the plant")
            ed.get_by_role("button", name="End mapping").click()
            pg.wait_for_timeout(300)
            check("Moved to the plant" in pg.inner_text("main"), "mapping history records the reason and effective time")

        # ---------------- sync
        pg.get_by_role("tab", name=re.compile("^Sync activity")).click()
        pg.get_by_text("Confirmed duplicates had the same identity").wait_for()
        shot(pg, f"07-sync-{theme}")
        if theme == "light":
            t = pg.inner_text("main")
            check(all(k in t for k in ["Retrying", "Failed", "Partly stored", "Completed", "next try"]), "sync history shows success, partial, failed and retry states")

        # ---------------- review
        pg.get_by_role("tab", name=re.compile("^Review queue")).click()
        pg.locator(".bio-review-item").first.wait_for()
        shot(pg, f"08-review-{theme}")
        if theme == "light":
            t = pg.inner_text("main")
            check(all(k in t for k in ["Ambiguous punch direction", "Possible duplicate", "Punch after an HR correction", "Invalid or suspicious time"]), "review queue shows every review type")
            first = pg.locator(".bio-review-item").first.inner_text()
            check(all(k in first for k in ["Employee", "device code", "Device", "serial", "Original device time", "device clock", "Received", "Reason for review", "Status"]), "review item shows employee + code, device + serial, original time, received time, reason and status")
            item = pg.locator(".bio-review-item").filter(has_text="Invalid or suspicious time").first
            item.get_by_role("button", name="Dismiss").click()
            ad = pg.get_by_role("dialog", name="Dismiss")
            ad.get_by_role("button", name="Dismiss").click()
            check(ad.is_visible() and ad.get_by_label("Reason").evaluate("e => !e.checkValidity()"), "dismiss needs a reason")
            check("only this browser tab changes" in ad.inner_text(), "decision dialog says it is a demonstration")
            ad.get_by_label("Reason").fill("Device clock was set wrong that day")
            ad.get_by_role("button", name="Dismiss").click()
            pg.wait_for_timeout(300)
            check("demonstration only" in pg.locator(".toasts").inner_text(), "decision toast says demonstration only")
            pg.locator(".filter-chip select").nth(1).select_option("closed")
            closed = pg.locator(".bio-review-item").filter(has_text="Dismissed").first
            closed.get_by_role("button", name=re.compile("History")).click()
            hd = pg.get_by_role("dialog", name="Review history")
            check("Device clock was set wrong that day" in hd.inner_text() and "demonstration" in hd.inner_text(), "decision recorded in the item's history with who and why")
            shot(pg, "09-review-history-light", full=False)
            hd.get_by_role("button", name="Close").click()
            # empty module and reset
            pg.get_by_role("button", name="Show the empty module").click()
            pg.wait_for_timeout(300)
            check(pg.get_by_text("No biometric devices yet").count() >= 1, "empty module shows the first-time state")
            shot(pg, "12-empty-light", full=False)
            pg.get_by_role("tab", name=re.compile("^Review queue")).click()
            pg.wait_for_timeout(400)
            check(pg.get_by_text("Nothing waiting for review").count() >= 1, "empty review queue" + ("" if pg.get_by_text("Nothing waiting for review").count() else " — " + pg.inner_text("main")[-300:]))
            pg.get_by_role("button", name="Reset sample data").click()
            pg.wait_for_timeout(300)
            check(pg.get_by_text("Total devices").count() == 1, "reset restores the sample data")
        check(not c.errors, f"{theme}: no console errors" + (f" — {c.errors[:2]}" if c.errors else ""))
        c.close()

    # ---------------- phones and tablets
    for theme in ["light", "dark"]:
        c = Ctx(br, "a1", theme=theme, mobile=True)
        for tab, name in [("", "overview"), ("devices", "devices"), ("mapping", "mapping"), ("sync", "sync"), ("review", "review")]:
            pg = c.go("/biometric" + (f"?tab={tab}" if tab else ""))
            pg.get_by_text("Demonstration data — no biometric device").first.wait_for(timeout=15000)
            pg.wait_for_timeout(500)
            check(no_overflow(pg), f"phone {theme}: {name} has no sideways scrolling")
            if name in ("overview", "devices", "review"):
                shot(pg, f"10-phone-{name}-{theme}")
        c.close()
    c = Ctx(br, "a1", theme="light")
    c.page.set_viewport_size({"width": 820, "height": 1180})
    pg = c.go("/biometric?tab=devices")
    pg.get_by_text("Main entrance").first.wait_for()
    check(no_overflow(pg), "tablet: devices fit the width")
    shot(pg, "11-tablet-devices-light")
    c.close()

    # ---------------- HR: maps device codes and reviews; no device configuration, no company-wide codes
    c = Ctx(br, "b2", theme="light")
    pg = c.go("/biometric?tab=devices")
    pg.get_by_text("Main entrance").first.wait_for(timeout=15000)
    check(pg.get_by_role("button", name="Add device").count() == 0, "hr: no Add device button")
    pg.get_by_role("button", name="Staff gate").first.click()
    pg.get_by_text("Device information").wait_for()
    check(pg.get_by_role("button", name=re.compile("Disable device|Enable device")).count() == 0 and pg.locator("#bio-dir").count() == 0, "hr: no disable/enable or direction controls")
    check("changed by Admin" in pg.inner_text("main"), "hr: direction shown read-only")
    shot(pg, "13-hr-device-detail-light")
    pg.get_by_role("tab", name=re.compile("^Employee mapping")).click()
    pg.get_by_role("button", name="Map a code").click()
    md = pg.get_by_role("dialog", name="Map a device code")
    check(not any("company-wide" in o for o in md.locator("select").first.locator("option").all_inner_texts()), "hr: no company-wide option")
    md.locator("select").first.select_option("dev-2")
    md.get_by_label("Device employee code").fill("HR77")
    for o in reversed(md.get_by_label("AttendOS employee").locator("option").all_inner_texts()[1:]):
        if "switched off" in o: continue
        md.get_by_label("AttendOS employee").select_option(label=o)
        pg.wait_for_timeout(120)
        if not md.get_by_role("button", name="Save mapping").is_disabled(): break
    md.get_by_role("button", name="Save mapping").click()
    pg.wait_for_timeout(300)
    check(not md.is_visible() and "HR77" in pg.inner_text("main"), "hr: can map a code on one device")
    cw_row = pg.locator("tbody tr").filter(has_text="Company-wide").first
    check(cw_row.count() == 1 and cw_row.get_by_role("button", name="End mapping").count() == 0, "hr: cannot end a company-wide mapping")
    pg.get_by_role("tab", name=re.compile("^Review queue")).click()
    pg.locator(".bio-review-item").first.wait_for()
    check(pg.locator(".bio-review-item").first.get_by_role("button").count() >= 2, "hr: can review")
    check(not c.errors, "hr: no console errors")
    c.close()

    # ---------------- loading and error states (people list slow / failing)
    import time as _t
    c = Ctx(br, "a1", theme="light")
    def slow(route, req):
        _t.sleep(2.5); c._route(route, req)
    c.page.route("**/rpc/people_directory*", slow)
    c.page.goto(APP + "/biometric", wait_until="commit")
    c.page.locator(".skel[aria-busy=true]").first.wait_for(timeout=8000)
    check(True, "loading state shown while people and offices load")
    shot(c.page, "14-loading-light", full=False)
    c.page.get_by_text("Demonstration data — no biometric device").first.wait_for(timeout=15000)
    c.page.unroute("**/rpc/people_directory*")
    c.page.route("**/rpc/people_directory*", lambda route, req: route.fulfill(status=500, body='{"message":"demo failure"}', headers={"content-type": "application/json", "access-control-allow-origin": "*"}))
    pg = c.go("/biometric")
    check(pg.get_by_text("Couldn't load people and offices").count() == 1 and pg.get_by_role("button", name="Try again").count() == 1, "error state with Try again")
    shot(pg, "15-error-light", full=False)
    pg.unroute("**/rpc/people_directory*")
    pg.get_by_role("button", name="Try again").click()
    pg.get_by_text("Demonstration data — no biometric device").first.wait_for(timeout=15000)
    check(True, "Try again recovers")
    c.close()

    # ---------------- phone 390 px: tab bar scrolls sideways, every section reachable, page still scrolls vertically; long names wrap
    LONG = "Venkatanarasimharajuvaripeta Subrahmanyam Lakshminarayana Chakravarthy"  # ~70 characters
    for theme in ["light", "dark"]:
        c = Ctx(br, "a1", theme=theme, mobile=True)
        def longnames(route, req):
            hd = {k: v for k, v in req.headers.items() if not (k.lower() == "authorization" and v.endswith("demo-anon"))}
            r = route.fetch(url=req.url.replace(REMOTE, API), headers=hd)
            data = r.json()
            for row in data:
                if row.get("active"):
                    row["full_name"] = LONG; break
            route.fulfill(response=r, json=data, headers={**r.headers, "access-control-allow-origin": "*"})
        c.page.route("**/rpc/people_directory*", longnames)
        pg = c.go("/biometric")
        pg.get_by_text("Demonstration data — no biometric device").first.wait_for(timeout=15000)
        bar = pg.locator(".bio-tabs .tabs")
        m = bar.evaluate("b => ({sw: b.scrollWidth, cw: b.clientWidth})")
        check(m["sw"] > m["cw"], f"phone {theme}: tab bar is wider than the screen and scrolls sideways")
        check(pg.locator(".bio-tabs.fade-r").count() == 1 and pg.locator(".bio-tabs-more").count() == 1, f"phone {theme}: edge fade and › hint show more tabs")
        if theme == "light": shot(pg, "16-phone-tabs-start-light", full=False)
        for name in ["Devices", "Employee mapping", "Sync activity", "Review queue", "Overview"]:
            t = pg.get_by_role("tab", name=re.compile("^" + name))
            t.click()
            pg.wait_for_timeout(350)
            box = t.bounding_box()
            check(t.get_attribute("aria-selected") == "true" and box["x"] >= 0 and box["x"] + box["width"] <= 391, f"phone {theme}: {name} reachable, selected and fully visible")
        pg.get_by_role("tab", name=re.compile("^Review queue")).click()
        pg.wait_for_timeout(350)
        check(bar.evaluate("b => b.scrollLeft") > 0 and pg.locator(".bio-tabs.fade-l").count() == 1, f"phone {theme}: bar scrolled to the last tab; left fade shows tabs before it")
        if theme == "light": shot(pg, "17-phone-tabs-review-light", full=False)
        pg.evaluate("window.scrollTo(0, 0)")
        bb = bar.bounding_box()
        pg.mouse.move(bb["x"] + 40, bb["y"] + bb["height"] / 2)
        pg.mouse.wheel(0, 600)
        pg.wait_for_timeout(400)
        check(pg.evaluate("window.scrollY") > 100, f"phone {theme}: vertical scrolling over the tab bar still scrolls the page")
        # long names: mapping, review and a 60-character device name
        pg.get_by_role("tab", name=re.compile("^Employee mapping")).click()
        pg.wait_for_timeout(300)
        check(LONG in pg.inner_text("main") and no_overflow(pg), f"phone {theme}: 70-character employee name wraps without sideways scrolling")
        pg.get_by_role("tab", name=re.compile("^Review queue")).click()
        pg.wait_for_timeout(300)
        check(no_overflow(pg), f"phone {theme}: review queue fits with long names")
        if theme == "light":
            pg.get_by_role("tab", name=re.compile("^Devices")).click()
            pg.get_by_role("button", name="Add device").first.click()
            dlg = pg.get_by_role("dialog")
            dlg.locator("input[name=maker][value=zkteco]").check()
            dlg.get_by_role("button", name="Next").click()
            dlg.get_by_label("Device name").fill("N" * 75)
            check(len(dlg.get_by_label("Device name").input_value()) == 60, "device name limited to 60 characters")
            name60 = "Ground floor north wing staff entrance beside the main lift"[:60]
            dlg.get_by_label("Device name").fill(name60)
            dlg.locator("#bio-model").fill("MB160")
            dlg.get_by_label("Serial number").fill("LONGNAME0001")
            dlg.get_by_role("button", name="Next").click()
            dlg.get_by_label("Office / location").select_option(index=1)
            dlg.get_by_role("button", name="Next").click()
            dlg.locator("input[name=method]").first.check()
            for _ in range(5):
                if dlg.get_by_role("button", name="Save sample device").count(): break
                dlg.get_by_role("button", name="Next").click()
                pg.wait_for_timeout(200)
                ip = dlg.get_by_label("Device IP address (office network)")
                if ip.count(): ip.fill("192.168.10.60")
                ag = dlg.get_by_label("Sync Agent")
                if ag.count(): ag.select_option("agt-1")
            dlg.get_by_role("button", name="Save sample device").click()
            pg.get_by_text("Device information").wait_for()
            check(no_overflow(pg), "phone: device detail with a 60-character name fits")
            shot(pg, "18-phone-long-device-light", full=False)
            pg.get_by_role("button", name="‹ All devices").click()
            pg.wait_for_timeout(300)
            check(no_overflow(pg), "phone: device list with a 60-character name fits")
        check(not c.errors, f"phone {theme}: no console errors" + (f" — {c.errors[:2]}" if c.errors else ""))
        c.close()

    # ---------------- other screens unaffected (quick smoke)
    c = Ctx(br, "a1", theme="light")
    for path in ["/", "/employees", "/attendance", "/settings"]:
        pg = c.go(path)
        check(pg.locator("main").count() == 1 and pg.locator(".state.error").count() == 0, f"{path} still loads")
    check(not c.errors, "other screens: no console errors")
    c.close()
    br.close()

check(before == db(FINGERPRINT), "database unchanged (attendance events, audit log, employees, offices)")
check(not [w for w in writes if "3001" in w and "people_directory" not in w], "no write requests to the database API" + (f": {writes[:3]}" if writes else ""))

fails = [w for ok, w in results if not ok]
print(f"\n{len(results) - len(fails)}/{len(results)} passed")
sys.exit(1 if fails else 0)
