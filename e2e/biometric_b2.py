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
            md.get_by_role("button", name="Save mapping").click()
            check(md.is_visible() and md.get_by_label("AttendOS employee").evaluate("e => !e.checkValidity()"), "no employee chosen → form refuses to save (no guessing)")
            opts = md.get_by_label("AttendOS employee").locator("option").all_inner_texts()
            free = [o for o in opts[1:] if "switched off" not in o][-1]
            md.get_by_label("AttendOS employee").select_option(label=free)
            md.get_by_role("button", name="Save mapping").click()
            pg.wait_for_timeout(400)
            check(pg.get_by_role("dialog", name="Map a device code").count() == 0 or not pg.get_by_role("dialog", name="Map a device code").is_visible(), "valid mapping saved locally")
            pg.get_by_role("button", name="Map a code").click()
            md = pg.get_by_role("dialog", name="Map a device code")
            md.get_by_label("Device employee code").fill("101")
            md.get_by_label("AttendOS employee").select_option(index=len(opts) - 1)
            md.get_by_role("button", name="Save mapping").click()
            check(md.get_by_role("alert").count() == 1, "overlapping or invalid mapping refused with a reason")
            md.get_by_role("button", name="Cancel").click()

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
            item = pg.locator(".bio-review-item").filter(has_text="Invalid or suspicious time").first
            item.get_by_role("button", name="Dismiss").click()
            ad = pg.get_by_role("dialog", name="Dismiss")
            ad.get_by_role("button", name="Dismiss").click()
            check(ad.is_visible() and ad.get_by_label("Reason").evaluate("e => !e.checkValidity()"), "dismiss needs a reason")
            ad.get_by_label("Reason").fill("Device clock was set wrong that day")
            ad.get_by_role("button", name="Dismiss").click()
            pg.wait_for_timeout(300)
            pg.locator(".filter-chip select").nth(1).select_option("closed")
            closed = pg.locator(".bio-review-item").filter(has_text="Dismissed").first
            closed.get_by_role("button", name=re.compile("History")).click()
            hd = pg.get_by_role("dialog", name="Review history")
            check("Device clock was set wrong that day" in hd.inner_text() and "demonstration" in hd.inner_text(), "decision recorded in the item's history with who and why")
            shot(pg, "09-review-history-light", full=False)
            hd.get_by_role("button", name="Close").click()
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
    br.close()

check(before == db(FINGERPRINT), "database unchanged (attendance events, audit log, employees, offices)")
check(not [w for w in writes if "3001" in w and "people_directory" not in w], "no write requests to the database API" + (f": {writes[:3]}" if writes else ""))

fails = [w for ok, w in results if not ok]
print(f"\n{len(results) - len(fails)}/{len(results)} passed")
sys.exit(1 if fails else 0)
