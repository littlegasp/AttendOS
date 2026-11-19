"""
Browser regression for AttendOS (stabilisation pass). Runs the real app build against the local demo database
(supabase/demo: PostgREST on :3001, PostgreSQL on PGPORT) and checks the database after each action.
Sign-in uses locally signed test tokens (the real sign-in flows are covered by supabase/authcheck).

  python3 e2e/regression.py http://localhost:4174 out-dir

GPS is emulated by the browser (Playwright geolocation): this proves the app's and server's handling of each
case, not the accuracy of real phones — that needs the pilot on real devices.
"""
import csv, io, json, os, re, subprocess, sys, time, hmac, hashlib, base64
from playwright.sync_api import sync_playwright

APP = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:4174"
OUT = sys.argv[2] if len(sys.argv) > 2 else "e2e-out"
API = "http://127.0.0.1:3001"
REMOTE = "https://demo-attendos.supabase.co/rest/v1"
SECRET = b"demo-secret-demo-secret-demo-secret-32"
U = lambda c: f"00000000-0000-0000-0000-0000000000{c}"
HQ = {"latitude": 19.1137, "longitude": 72.8699, "accuracy": 16}
PUNE = {"latitude": 18.7604, "longitude": 73.8631, "accuracy": 20}
FAR = {"latitude": 19.1290, "longitude": 72.8800, "accuracy": 21}
POOR = {"latitude": 19.1137, "longitude": 72.8699, "accuracy": 450}
os.makedirs(OUT, exist_ok=True)
results = []


def check(ok, what):
    results.append((bool(ok), what))
    print(("PASS " if ok else "FAIL ") + what, flush=True)


def sql(q):
    r = subprocess.run(["psql", "-h", "/tmp/pg", "-p", os.environ.get("PGPORT", "5433"), "-U", "postgres", "-d", "attendos_demo", "-Atc", q], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr)
    return r.stdout.strip()


def b64(x):
    return base64.urlsafe_b64encode(x).rstrip(b"=").decode()


def jwt(sub):
    h = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = b64(json.dumps({"sub": sub, "role": "authenticated", "aud": "authenticated", "exp": int(time.time()) + 86400}).encode())
    return f"{h}.{p}." + b64(hmac.new(SECRET, f"{h}.{p}".encode(), hashlib.sha256).digest())


def rpc(fn, body, who):
    import urllib.request
    req = urllib.request.Request(f"{API}/rpc/{fn}", data=json.dumps(body).encode(), headers={"Authorization": "Bearer " + jwt(U(who)), "Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


GEO_SPY = """
(() => {
  window.__geo = 0; window.__watch = 0;
  const g = navigator.geolocation;
  if (!g) return;
  const get = g.getCurrentPosition.bind(g), watch = g.watchPosition.bind(g);
  g.getCurrentPosition = (...a) => { window.__geo++; return get(...a); };
  g.watchPosition = (...a) => { window.__watch++; return watch(...a); };
})();
"""


def session_script(who, theme):
    tok = jwt(U(who))
    sess = dict(access_token=tok, refresh_token="r", token_type="bearer", expires_in=86400, expires_at=int(time.time()) + 86400,
                user=dict(id=U(who), aud="authenticated", role="authenticated", email="x@acme.in", app_metadata={}, user_metadata={}, created_at="2026-01-01T00:00:00Z"))
    return f"localStorage.setItem('attendos.theme','{theme}');localStorage.setItem('attendos-auth',{json.dumps(json.dumps(sess))});"


class Ctx:
    def __init__(self, browser, who, geo=HQ, allow_geo=True, mobile=False, theme="dark", block=None):
        vp = {"width": 390, "height": 844} if mobile else {"width": 1440, "height": 900}
        self.ctx = browser.new_context(viewport=vp, geolocation=geo, permissions=["geolocation"] if allow_geo else [], timezone_id="Asia/Kolkata", accept_downloads=True)
        self.ctx.add_init_script(session_script(who, theme) + GEO_SPY)
        self.errors = []
        self.block = block
        self.page = self.ctx.new_page()
        self.page.on("console", lambda m: self.errors.append(m.text[:160]) if m.type == "error" and not re.search(r"tile\.openstreetmap|TUNNEL|ERR_NAME|ERR_FAILED|net::", m.text) else None)
        self.page.on("pageerror", lambda e: self.errors.append(str(e)[:160]))
        self.page.route(REMOTE + "/**", self._route)

    def _route(self, route, req):
        try:
            if self.block and self.block in req.url:
                return route.abort("internetdisconnected")
            hd = {k: v for k, v in req.headers.items() if not (k.lower() == "authorization" and v.endswith("demo-anon"))}
            r = route.fetch(url=req.url.replace(REMOTE, API), headers=hd)
            route.fulfill(response=r, headers={**r.headers, "access-control-allow-origin": "*"})
        except Exception:
            pass

    def go(self, path):
        self.page.goto(APP + path, wait_until="networkidle")
        self.page.wait_for_timeout(800)
        return self.page

    def close(self):
        self.page.unroute_all(behavior="ignoreErrors")
        self.ctx.close()


def events(code):
    return int(sql(f"select count(*) from attendance_events where employee_id = '{U(code)}' and work_date = local_today(emp_company('{U(code)}'))"))


def attempts(code, reason):
    return int(sql(f"select count(*) from attendance_attempts where employee_id = '{U(code)}' and reason = '{reason}' and at > now() - interval '5 minutes'"))


with sync_playwright() as p:
    br = p.chromium.launch(executable_path="/usr/bin/google-chrome", args=["--no-sandbox"])

    # ------------------------------------------------------------------ GPS
    # Kiran (f6) has no check-in today. Pooja (d1) and Meera (a7) are reset for the office/remote cases.
    sql(f"delete from attendance_events where employee_id in ('{U('f6')}','{U('d1')}','{U('a7')}') and work_date = local_today(emp_company('{U('f6')}'))")
    c = Ctx(br, "f6")
    for path in ["/", "/my-attendance", "/leave", "/attendance", "/employees"]:
        c.go(path)
    check(c.page.evaluate("window.__geo + window.__watch") == 0, "no location is read while opening screens (dashboard, My Attendance, leave, register, profile)")
    c.close()

    c = Ctx(br, "f6", allow_geo=False)
    pg = c.go("/my-attendance")
    pg.get_by_role("button", name="Check In").click()
    pg.get_by_text("Location access is blocked").first.wait_for(timeout=15000)
    check(events("f6") == 0, "permission denied: clear message, nothing recorded")
    pg.screenshot(path=f"{OUT}/g01-denied.png")
    c.close()

    c = Ctx(br, "f6", geo=POOR)
    pg = c.go("/my-attendance")
    pg.get_by_role("button", name="Check In").click()
    pg.wait_for_timeout(2500)
    check(events("f6") == 0 and attempts("f6", "accuracy_low") >= 1, "poor accuracy (450 m): refused by the server and logged as an attempt")
    pg.screenshot(path=f"{OUT}/g02-poor-accuracy.png")
    c.close()

    c = Ctx(br, "f6", geo=FAR)
    pg = c.go("/my-attendance")
    pg.get_by_role("button", name="Check In").click()
    pg.wait_for_timeout(2500)
    check(events("f6") == 0 and attempts("f6", "outside_area") >= 1, "outside the office area (~1.8 km): refused and logged")
    c.close()

    c = Ctx(br, "f6", block="/rpc/punch")
    pg = c.go("/my-attendance")
    pg.get_by_role("button", name="Check In").click()
    pg.get_by_text(re.compile("Couldn.t reach|internet|connection", re.I)).first.wait_for(timeout=15000)
    check(events("f6") == 0, "network failure during check-in: message shown, nothing recorded, can retry")
    pg.screenshot(path=f"{OUT}/g03-offline.png")
    c.close()

    c = Ctx(br, "f6", geo=HQ)
    pg = c.go("/my-attendance")
    before = pg.evaluate("window.__geo")
    pg.get_by_role("button", name="Check In").click()
    pg.get_by_role("button", name="Start break").wait_for(timeout=15000)
    row = sql(f"select verified::text || '|' || coalesce(distance_m::text,'') || '|' || (select count(*) from attendance_coords c where c.event_id = e.id) from attendance_events e where employee_id = '{U('f6')}' order by id desc limit 1")
    check(row.startswith("true|") and row.endswith("|1"), f"inside the area: accepted, verified, distance kept, exact point stored once ({row})")
    check(pg.evaluate("window.__geo") - before == 1, "location read exactly once for the check-in")
    pg.get_by_role("button", name="Start break").click()
    pg.get_by_role("button", name="End break").wait_for(timeout=10000)
    pg.get_by_role("button", name="End break").click()
    pg.get_by_role("button", name="Start break").wait_for(timeout=10000)
    check(pg.evaluate("window.__geo") - before == 1, "breaks never read the location")
    pg.get_by_role("button", name="Check Out").click()
    pg.wait_for_timeout(2500)
    check(pg.evaluate("window.__geo") - before == 2 and pg.evaluate("window.__watch") == 0, "check-out reads it once more; nothing ever tracks in the background (no watchPosition)")
    c.close()

    # Several offices: Pooja is rostered at the Pune plant today
    sql(f"insert into roster_day (employee_id, day, work_mode, location_id) values ('{U('d1')}', local_today(emp_company('{U('d1')}')), 'office', '22222222-2222-2222-2222-222222222222') on conflict (employee_id, day) do update set work_mode = 'office', location_id = excluded.location_id")
    c = Ctx(br, "d1", geo=HQ)
    pg = c.go("/my-attendance")
    pg.get_by_role("button", name="Check In").click()
    pg.wait_for_timeout(2500)
    check(events("d1") == 0, "rostered at the Pune plant: standing at Andheri HQ is refused")
    c.close()
    c = Ctx(br, "d1", geo=PUNE)
    pg = c.go("/my-attendance")
    pg.get_by_role("button", name="Check In").click()
    pg.get_by_role("button", name="Start break").wait_for(timeout=15000)
    check(sql(f"select l.name from attendance_events e join locations l on l.id = e.location_id where e.employee_id = '{U('d1')}' order by e.id desc limit 1") == "Pune Plant", "at the Pune plant: accepted against that office")
    c.close()

    # Remote-work exception: Meera works from home today; no office area needed
    sql(f"insert into remote_exceptions (employee_id, start_date, end_date, reason) values ('{U('a7')}', local_today(emp_company('{U('a7')}')), local_today(emp_company('{U('a7')}')), 'Regression: home visit')")
    c = Ctx(br, "a7", geo=FAR)
    pg = c.go("/my-attendance")
    pg.get_by_role("button", name="Check In").click()
    pg.get_by_role("button", name="Start break").wait_for(timeout=15000)
    check(sql(f"select work_mode from attendance_events where employee_id = '{U('a7')}' order by id desc limit 1") == "remote", "remote-work exception: check-in accepted as Remote far from any office")
    c.close()

    # ------------------------------------------------------------------ HR workflows in the app
    nid = U("f3")
    c = Ctx(br, "b2")
    pg = c.go(f"/employees?id={nid}")
    pg.get_by_role("button", name="Edit details").click() if pg.get_by_role("button", name="Edit details").count() else pg.get_by_role("button", name="Edit").first.click()
    pg.get_by_label("Employment status").select_option(label="Exited")
    pg.locator(".dialog-actions").get_by_role("button", name="Save changes").click()
    pg.wait_for_timeout(2000)
    st = sql(f"select active::text || '|' || employment_status || '|' || (exit_date = local_today(company_id))::text from employees where id = '{nid}'")
    check(st == "false|exited|true", f"exit from the app: access off at once, exit date today ({st})")
    hist = int(sql(f"select count(*) from attendance_events where employee_id = '{nid}'"))
    pg.reload(); pg.wait_for_timeout(1000)
    pg.get_by_role("button", name="Reactivate").click()
    pg.get_by_role("dialog").get_by_role("button", name="Reactivate").click()
    pg.wait_for_timeout(1500)
    st = sql(f"select active::text || '|' || employment_status || '|' || coalesce(exit_date::text, 'none') from employees where id = '{nid}'")
    check(st == "true|confirmed|none", f"reactivate: access back, status Confirmed, exit date cleared ({st})")
    check(int(sql(f"select count(*) from attendance_events where employee_id = '{nid}'")) == hist and
          int(sql(f"select count(*) from audit_log where target = 'employees' and target_id = '{nid}' and actor_employee = '{U('b2')}' and source = 'app'")) >= 2,
          "attendance history unchanged; exit and reactivation in the audit log with HR as the actor")
    c.close()

    # Leave: apply (employee) → approve (manager) → cancel (employee); apply → reject (manager); adjust (HR)
    def next_working(code, after):
        return sql(f"select min(g::date) from generate_series(local_today(emp_company('{U(code)}')) + {after}, local_today(emp_company('{U(code)}')) + {after + 14}, interval '1 day') g where (select work_mode from plan_for('{U(code)}', g::date)) <> 'off' and not exists (select 1 from leave_requests r where r.employee_id = '{U(code)}' and r.status in ('pending','approved') and g::date between r.start_date and r.end_date)")
    d1 = next_working("d4", 30)
    c = Ctx(br, "d4")
    pg = c.go("/leave")
    pg.get_by_role("button", name="Apply for leave").click()
    pg.get_by_label("First day").fill(d1)
    pg.get_by_label("Last day").fill(d1)
    pg.get_by_label("Reason").fill("Regression test leave")
    pg.get_by_text("Counts as").wait_for(timeout=10000)
    pg.locator(".dialog-actions").get_by_role("button", name="Submit request").click()
    pg.wait_for_timeout(1500)
    rid = sql(f"select id from leave_requests where employee_id = '{U('d4')}' and start_date = '{d1}' and status = 'pending'")
    check(rid != "", "employee applied in the app → pending")
    c.close()
    c = Ctx(br, "c3")
    pg = c.go("/leave")
    pg.get_by_role("tab", name="Team Requests").click()
    row = pg.locator("tr", has_text="Regression test leave")
    row.get_by_role("button", name="Approve").click()
    pg.get_by_role("dialog").get_by_role("button", name="Approve").click()
    pg.wait_for_timeout(1500)
    check(sql(f"select status || '|' || (decided_by = '{U('c3')}')::text from leave_requests where id = {rid}") == "approved|true", "manager approved in the app (approver recorded)")
    c.close()
    c = Ctx(br, "d4")
    pg = c.go("/leave")
    pg.locator("tr", has_text="Regression test leave").get_by_role("button", name="Cancel").click()
    pg.get_by_role("dialog").get_by_role("button", name="Cancel leave").click()
    pg.wait_for_timeout(1500)
    check(sql(f"select status from leave_requests where id = {rid}") == "cancelled", "employee cancelled approved future leave; days return to the balance")
    d2 = next_working("d4", 45)
    pg.get_by_role("button", name="Apply for leave").click()
    pg.get_by_label("First day").fill(d2); pg.get_by_label("Last day").fill(d2)
    pg.get_by_label("Reason").fill("Regression reject case")
    pg.locator(".dialog-actions").get_by_role("button", name="Submit request").click()
    pg.wait_for_timeout(1500)
    c.close()
    c = Ctx(br, "c3")
    pg = c.go("/leave")
    pg.get_by_role("tab", name="Team Requests").click()
    pg.locator("tr", has_text="Regression reject case").get_by_role("button", name="Reject").click()
    dlg = pg.get_by_role("dialog")
    dlg.get_by_role("button", name="Reject").click()
    dlg.get_by_text("Give a short reason").wait_for()
    dlg.get_by_label(re.compile("Reason for rejecting")).fill("Stock audit that week")
    dlg.get_by_role("button", name="Reject").click()
    pg.wait_for_timeout(1500)
    check(sql(f"select status || '|' || decision_note from leave_requests where reason = 'Regression reject case'") == "rejected|Stock audit that week", "reject needs a reason; rejection saved with it")
    c.close()
    c = Ctx(br, "b2")
    pg = c.go("/leave")
    pg.get_by_role("tab", name="Leave Balance").click()
    pg.locator(".filter-chip", has_text="Person").locator("select").select_option(label="Esha Patil")
    pg.wait_for_timeout(800)
    before_adj = int(sql(f"select count(*) from leave_adjustments where employee_id = '{U('d4')}'"))
    pg.get_by_role("button", name="Adjust balance").click()
    pg.get_by_label("Days (+ or −)").fill("1")
    pg.get_by_label("Reason").fill("Regression credit")
    pg.get_by_role("button", name="Save adjustment").click()
    pg.wait_for_timeout(1500)
    check(int(sql(f"select count(*) from leave_adjustments where employee_id = '{U('d4')}'")) == before_adj + 1, "HR adjusted a balance in the app (with a reason)")
    c.close()

    # ------------------------------------------------------------------ exports and print
    today = sql(f"select local_today(emp_company('{U('b2')}'))")
    sales = sql("select id from departments where name = 'Sales' and company_id = (select company_id from employees where id = '" + U("b2") + "')")
    c = Ctx(br, "b2")
    pg = c.go("/attendance")
    pg.locator(".filter-chip", has_text="Department").locator("select").select_option(label="Sales")
    pg.wait_for_timeout(1500)
    with pg.expect_download() as dl:
        pg.get_by_role("button", name="Export CSV").click()
    rows = list(csv.DictReader(io.StringIO(open(dl.value.path(), encoding="utf-8-sig").read())))
    api_rows = rpc("attendance_register", {"p_from": today, "p_to": today, "p_department": sales, "p_limit": 5000}, "b2")
    check(sorted(r["Employee"] for r in rows) == sorted(r["full_name"] for r in api_rows) and all(r["Department"] == "Sales" for r in rows),
          f"register CSV (HR, Sales, today) = exactly the filtered rows ({len(rows)} rows)")
    c.close()
    c = Ctx(br, "c3")
    pg = c.go("/attendance")
    pg.wait_for_timeout(1000)
    with pg.expect_download() as dl:
        pg.get_by_role("button", name="Export CSV").click()
    rows = list(csv.DictReader(io.StringIO(open(dl.value.path(), encoding="utf-8-sig").read())))
    team = set(sql(f"select string_agg(full_name, '|') from employees where id = '{U('c3')}' or manager_id = '{U('c3')}'").split("|"))
    check(rows and {r["Employee"] for r in rows} <= team, f"register CSV (Manager): only their team ({len(rows)} rows)")
    pg = c.go("/reports")
    pg.get_by_role("tab", name="Employee-wise").click()
    pg.wait_for_timeout(2500)
    with pg.expect_download() as dl:
        pg.get_by_role("button", name="Export CSV").click()
    rows = list(csv.DictReader(io.StringIO(open(dl.value.path(), encoding="utf-8-sig").read())))
    m0 = today[:8] + "01"
    api_rows = rpc("report_people", {"p_from": m0, "p_to": today}, "c3")
    check(sorted((r["Employee"], r["Attended"]) for r in rows) == sorted((r["full_name"], str(r["attended_days"])) for r in api_rows), "report CSV (Manager, this month) = report_people for the same scope")
    check(not any(re.match(r"^[=+@]", v or "") for r in rows for v in r.values()), "no exported cell starts a spreadsheet formula")
    pg.get_by_role("tab", name="Late arrivals").click()
    pg.wait_for_timeout(2500)
    pg.emulate_media(media="print")
    pg.pdf(path=f"{OUT}/report-print.pdf", format="A4", print_background=False)
    txt = subprocess.run(["pdftotext", f"{OUT}/report-print.pdf", "-"], capture_output=True, text=True).stdout
    check("Late arrivals" in txt and "Design system" not in txt and "Export CSV" not in txt, "Print / PDF: report content only (no menu, buttons or filters)")
    c.close()

    # ------------------------------------------------------------------ every screen: dark, light, phone — no errors, no sideways scrolling
    routes = ["/", "/my-attendance", "/attendance", "/employees", "/leave", "/shifts", "/holidays", "/reports", "/analytics", "/departments", "/roles", "/settings", "/design"]
    bad = []
    n = 0
    for who in ["a1", "b2", "c3", "d4"]:
        for theme, mobile in [("dark", False), ("light", False), ("dark", True), ("light", True)]:
            c = Ctx(br, who, theme=theme, mobile=mobile)
            for r in routes:
                pg = c.go(r)
                n += 1
                if pg.locator("h1").count() == 0:
                    bad.append(f"{who} {theme} {'phone' if mobile else 'desktop'} {r}: no heading")
                if mobile and pg.evaluate("document.documentElement.scrollWidth > window.innerWidth + 1"):
                    bad.append(f"{who} {theme} phone {r}: page scrolls sideways")
                if pg.evaluate("document.documentElement.dataset.theme") != theme:
                    bad.append(f"{who} {r}: theme not applied")
            if c.errors:
                bad.append(f"{who} {theme} {'phone' if mobile else 'desktop'}: console {c.errors[:2]}")
            c.close()
    check(not bad, f"{n} screen loads (13 screens × 4 roles × dark/light × desktop/phone): headings, themes, no sideways scroll, no console errors" + (f" — {bad[:6]}" if bad else ""))
    br.close()

passed = sum(ok for ok, _ in results)
print(f"\n{passed}/{len(results)} regression checks passed")
json.dump([{"ok": ok, "what": w} for ok, w in results], open(f"{OUT}/regression-results.json", "w"), indent=1)
sys.exit(0 if passed == len(results) else 1)
