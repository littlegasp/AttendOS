"""
Drives the real sign-in flows in a browser against the local Supabase Auth + PostgREST started by start.sh.
Prints PASS/FAIL per check and saves screenshots. Usage:
  python3 flows.py APP_URL SHOT_DIR      (APP_URL = connected build served on 127.0.0.1:4175)
The app was built with NEXT_PUBLIC_SUPABASE_URL=https://demo-attendos.supabase.co; requests to that address are
routed to the local Auth (:9999) and PostgREST (:3002). E-mails are read from ./mail (mailsink.py).
"""
import glob, json, os, re, subprocess, sys, time, urllib.request, urllib.error
from playwright.sync_api import sync_playwright

APP = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:4175"
SHOTS = sys.argv[2] if len(sys.argv) > 2 else "shots"
HERE = os.path.dirname(os.path.abspath(__file__))
MAIL = os.path.join(HERE, "mail")
ANON = open("/tmp/anon.jwt").read().strip() if os.path.exists("/tmp/anon.jwt") else os.environ["ANON_KEY"]
REMOTE = "https://demo-attendos.supabase.co"
os.makedirs(SHOTS, exist_ok=True)
results = []


def check(ok, what):
    results.append((bool(ok), what))
    print(("PASS " if ok else "FAIL ") + what, flush=True)


def sql(q):
    return subprocess.run(["psql", "-h", "/tmp/pg", "-p", os.environ.get("PGPORT", "5433"), "-U", "postgres", "-d", "attendos_auth", "-Atc", q],
                          capture_output=True, text=True).stdout.strip()


def mails(to):
    out = []
    for f in sorted(glob.glob(os.path.join(MAIL, "*.json"))):
        m = json.load(open(f))
        if any(to.lower() == r.lower() for r in m["to"]):
            out.append(m)
    return out


def wait_mail(to, n, timeout=15):
    end = time.time() + timeout
    while time.time() < end:
        m = mails(to)
        if len(m) >= n:
            return m[n - 1]
        time.sleep(0.3)
    raise RuntimeError(f"no mail #{n} for {to}")


def link_in(m):
    url = re.search(r'href="([^"]+/verify\?[^"]+)"', m["body"]) or re.search(r'(https?://\S+/verify\?\S+)', m["body"])
    return url.group(1).replace("&amp;", "&")


def api(path, body=None, token=None, method=None):
    req = urllib.request.Request("http://127.0.0.1:9999" + path, data=json.dumps(body).encode() if body is not None else None,
                                 method=method or ("POST" if body is not None else "GET"),
                                 headers={"Content-Type": "application/json", "apikey": ANON, **({"Authorization": "Bearer " + token} if token else {})})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def rest(path, token):
    req = urllib.request.Request("http://127.0.0.1:3002" + path, headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


CORS = {"access-control-allow-origin": APP, "access-control-allow-credentials": "true",
        "access-control-allow-headers": "*", "access-control-allow-methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
        "access-control-expose-headers": "*"}


def route(r, req):
  try:
    _route(r, req)
  except Exception:
    pass  # page closed while a request was in flight


def _route(r, req):
    url = req.url
    if req.method == "OPTIONS":
        return r.fulfill(status=204, headers=CORS)
    if url.startswith(REMOTE + "/auth/v1/"):
        target = "http://127.0.0.1:9999/" + url[len(REMOTE + "/auth/v1/"):]
    elif url.startswith(REMOTE + "/verify"):  # links in Auth e-mails
        target = "http://127.0.0.1:9999/" + url[len(REMOTE + "/"):]
    elif url.startswith(REMOTE + "/rest/v1/"):
        target = "http://127.0.0.1:3002/" + url[len(REMOTE + "/rest/v1/"):]
    else:
        return r.continue_()
    resp = r.fetch(url=target, max_redirects=0)
    headers = {k: v for k, v in resp.headers.items() if k.lower() not in ("content-encoding", "content-length", "transfer-encoding")}
    headers.update(CORS)
    r.fulfill(status=resp.status, headers=headers, body=resp.body())


def new_page(browser, mobile=False):
    ctx = browser.new_context(viewport={"width": 390, "height": 844} if mobile else {"width": 1280, "height": 860},
                              device_scale_factor=2 if mobile else 1)
    ctx.add_init_script("try{localStorage.setItem('attendos.theme','dark')}catch(e){}")
    ctx.route(REMOTE + "/**", route)
    return ctx, ctx.new_page()


def wait_home(page, timeout=20000):
    page.wait_for_url(lambda u: u.startswith(APP) and "/login" not in u and "/reset-password" not in u, timeout=timeout)
    page.locator("main, .app-main, h1").first.wait_for(timeout=timeout)


def stored_session(page):
    raw = page.evaluate("localStorage.getItem('attendos-auth')")
    return json.loads(raw) if raw else None


def shot(page, name):
    page.wait_for_timeout(600)
    page.screenshot(path=os.path.join(SHOTS, name + ".png"))


exp_ms = int(os.environ.get("JWT_EXP", "3600")) * 1000

with sync_playwright() as p:
    browser = p.chromium.launch()

    # ------------------------------------------------------------- 1. a stranger cannot create a login
    ctx, pg = new_page(browser)
    pg.goto(APP + "/login?company=acme")
    pg.get_by_text("Acme Industries").first.wait_for()
    check(True, "company sign-in page shows the company name (anonymous key, real PostgREST)")
    shot(pg, "a01-login")
    pg.get_by_role("button", name="First time here? Create your login").click()
    pg.get_by_label("Work email").fill("stranger@gmail.com")
    pg.get_by_label("Choose a password").fill("Stranger#2026")
    pg.get_by_label("Type it again").fill("Stranger#2026")
    pg.get_by_role("button", name="Create login").click()
    pg.get_by_text("isn't set up in AttendOS yet").wait_for()
    check(sql("select count(*) from auth.users where email = 'stranger@gmail.com'") == "0", "unknown e-mail refused by the Auth hook; no login created")
    shot(pg, "a02-signup-refused")

    # ------------------------------------------------------------- 2. first Admin signs up and confirms
    pg.get_by_label("Work email").fill("Admin@Acme.test")
    pg.get_by_role("button", name="Create login").click()
    pg.get_by_text("We sent a confirmation link").wait_for()
    shot(pg, "a03-signup-sent")
    m1 = wait_mail("admin@acme.test", 1)
    check("Confirm" in m1["subject"], f"confirmation e-mail sent ({m1['subject']})")
    check(sql("select count(*) from employees where email = 'admin@acme.test' and user_id is not null") == "0", "not linked before the e-mail is confirmed")
    pg.goto(APP + "/login?company=acme")
    pg.get_by_label("Work email").fill("admin@acme.test")
    pg.get_by_label("Password").fill("Stranger#2026")
    pg.get_by_role("button", name="Sign in").click()
    pg.get_by_text("hasn't been confirmed yet").wait_for()
    check(True, "sign-in refused until the e-mail is confirmed")
    pg.get_by_role("button", name="Send the confirmation e-mail again").click()
    pg.get_by_text("A new confirmation link is on its way").wait_for()
    shot(pg, "a04-unconfirmed-resend")
    m2 = wait_mail("admin@acme.test", 2)
    check(link_in(m2) != link_in(m1), "a fresh confirmation link was sent")
    pg.goto(link_in(m2))
    wait_home(pg)
    check(sql("select count(*) from employees e join auth.users u on u.id = e.user_id where e.email = 'admin@acme.test' and u.email_confirmed_at is not null") == "1",
          "confirmation link signs in and links the login to the Admin record")
    shot(pg, "a05-admin-dashboard")
    octx, old = new_page(browser)
    old.goto(link_in(m1))
    old.wait_for_url(re.compile(r".*/login.*"), timeout=20000)
    old.get_by_text("link has expired or was already used").wait_for()
    check(stored_session(old) is None, "an old/used confirmation link is refused with a clear message and signs no one in")
    shot(old, "a06-link-expired")
    octx.close()
    admin_ctx, admin = ctx, pg
    admin.goto(APP + "/")
    admin.get_by_role("heading").first.wait_for()

    # ------------------------------------------------------------- 3. Admin adds an employee in the app
    admin.goto(APP + "/employees")
    admin.get_by_role("button", name="Add employee").first.click()
    admin.get_by_label("Full name").fill("Esha Patil")
    admin.get_by_label("Work e-mail").fill("esha@acme.test")
    admin.locator(".dialog-actions").get_by_role("button", name="Add employee").click()
    admin.wait_for_timeout(2500)
    row = sql("select emp_code || '|' || coalesce(user_id::text,'') from employees where email = 'esha@acme.test'")
    check(row.startswith("E") and row.endswith("|"), f"Admin added Esha in the app ({row.split('|')[0]}); no login yet")
    actor = sql("select a.source || '|' || u.email from audit_log a join employees e on e.id = a.actor_employee join auth.users u on u.id = a.actor "
                "where a.target = 'employees' and a.action = 'insert' and a.after ->> 'email' = 'esha@acme.test'")
    check(actor == "app|admin@acme.test", "audit entry records the real signed-in Admin (from the Auth token)")

    # ------------------------------------------------------------- 3b. invitation e-mail from the profile
    admin.goto(APP + "/employees")
    admin.get_by_role("button", name="Add employee").first.click()
    admin.get_by_label("Full name").fill("Ravi Kumar")
    admin.get_by_label("Work e-mail").fill("ravi@acme.test")
    admin.locator(".dialog-actions").get_by_role("button", name="Add employee").click()
    admin.wait_for_timeout(1500)
    rid = sql("select id from employees where email = 'ravi@acme.test'")
    admin.goto(APP + f"/employees?id={rid}")
    admin.get_by_role("button", name="Send invite").click()
    admin.get_by_text("Invitation sent").first.wait_for()
    shot(admin, "a14-invite-sent")
    im = wait_mail("ravi@acme.test", 1)
    check(sql("select status || '|' || email from employee_invitations") == "sent|ravi@acme.test", f"invitation recorded and e-mailed only to the work address ({im['subject']})")
    check(stored_session(admin)["user"]["email"] == "admin@acme.test", "sending the invitation leaves the Admin signed in as themselves")
    admin.get_by_role("button", name="Send invite").click()
    admin.get_by_text("wait 10 minutes").first.wait_for()
    check(len(mails("ravi@acme.test")) == 1, "a second invitation within 10 minutes is refused (no duplicate e-mail)")
    ictx, inv = new_page(browser, mobile=True)
    inv.goto(link_in(im))
    inv.wait_for_url(re.compile(r".*/reset-password\?welcome=1.*"), timeout=20000)
    inv.get_by_text("Welcome — choose your password").wait_for()
    inv.get_by_label("New password").fill("Ravi#start1")
    inv.get_by_label("Type it again").fill("Ravi#start1")
    shot(inv, "a15-invite-welcome")
    inv.get_by_role("button", name="Save password").click()
    wait_home(inv)
    check(sql("select e.company_id = c.id and e.user_id = u.id from employees e join auth.users u on lower(u.email) = e.email join companies c on c.slug = 'acme' where e.email = 'ravi@acme.test'") == "t",
          "invited person is linked to the right employee record and company")
    check(sql("select status from employee_invitations order by id desc limit 1") == "accepted", "invitation marked accepted")
    st, _ = api("/token?grant_type=password", {"email": "ravi@acme.test", "password": "Ravi#start1"})
    check(st == 200, "the password chosen on the welcome page works")
    inv.unroute_all(behavior="ignoreErrors"); ictx.close()
    admin.goto(APP + f"/employees?id={rid}")
    admin.get_by_text("Signs in with this e-mail").wait_for()
    check(admin.get_by_role("button", name="Send invite").count() == 0, "once linked, the profile offers no further invitations")

    # ------------------------------------------------------------- 4. employee signs up on a phone and is linked
    ectx, emp = new_page(browser, mobile=True)
    emp.goto(APP + "/login?company=acme&mode=signup")
    emp.get_by_label("Work email").fill("esha@acme.test")
    emp.get_by_label("Choose a password").fill("Esha#first1")
    emp.get_by_label("Type it again").fill("Esha#first1")
    emp.get_by_role("button", name="Create login").click()
    emp.get_by_text("We sent a confirmation link").wait_for()
    emp.goto(link_in(wait_mail("esha@acme.test", 1)))
    wait_home(emp)
    check(sql("select role from employees where email = 'esha@acme.test' and user_id is not null") == "employee", "employee confirmed and linked as Employee")
    shot(emp, "a07-employee-mobile")

    # Duplicate: the same work e-mail (different case) can't create a second login or a second link.
    dctx, dup = new_page(browser)
    dup.goto(APP + "/login?mode=signup")
    dup.get_by_label("Work email").fill("ESHA@ACME.TEST")
    dup.get_by_label("Choose a password").fill("Other#pass1")
    dup.get_by_label("Type it again").fill("Other#pass1")
    dup.get_by_role("button", name="Create login").click()
    dup.wait_for_timeout(1500)
    check(sql("select count(*) from auth.users where lower(email) = 'esha@acme.test'") == "1"
          and sql("select count(*) from employees where user_id = (select id from auth.users where email = 'esha@acme.test')") == "1",
          "second sign-up with the same work e-mail creates no second login or link")
    shot(dup, "a08-duplicate-signup")
    dctx.close()

    # ------------------------------------------------------------- 5. password reset
    rctx, rp = new_page(browser)
    rp.goto(APP + "/login")
    rp.get_by_role("button", name="Forgot password?").click()
    rp.get_by_label("Work email").fill("esha@acme.test")
    rp.get_by_role("button", name="Send reset link").click()
    rp.get_by_text("reset link is on its way").wait_for()
    shot(rp, "a09-reset-sent")
    rm = wait_mail("esha@acme.test", 2)
    check("Reset" in rm["subject"], f"reset e-mail sent ({rm['subject']})")
    rp.goto(link_in(rm))
    rp.wait_for_url(re.compile(r".*/reset-password.*"), timeout=20000)
    rp.get_by_label("New password").wait_for()
    rp.get_by_label("New password").fill("Esha#second2")
    rp.get_by_label("Type it again").fill("Esha#second2")
    shot(rp, "a10-reset-form")
    rp.get_by_role("button", name="Save password").click()
    wait_home(rp)
    check(True, "reset link → new password → signed in")
    check(sql("select count(*) from auth.sessions s join auth.users u on u.id = s.user_id where u.email = 'esha@acme.test'") == "1",
          "the new password signed out every other session (only this one remains)")
    st, _ = api("/token?grant_type=password", {"email": "esha@acme.test", "password": "Esha#first1"})
    check(st == 400, "old password no longer works")
    st, body = api("/token?grant_type=password", {"email": "esha@acme.test", "password": "Esha#second2"})
    check(st == 200, "new password works")
    api("/logout?scope=local", {}, body.get("access_token"))
    t0 = time.time()
    emp.goto(APP + "/employees")
    emp.wait_for_url(re.compile(r".*/login.*"), timeout=exp_ms + 60000)
    check(True, f"the phone is sent back to sign-in when its session can't be renewed ({time.time() - t0:.0f}s; up to the token lifetime)")
    shot(emp, "a11-other-device-signed-out")

    # ------------------------------------------------------------- 6. logout
    before = stored_session(rp)
    rp.get_by_role("button", name=re.compile("Account menu")).click()
    rp.get_by_role("button", name="Sign out").click()
    rp.wait_for_url(re.compile(r".*/login.*"), timeout=15000)
    check(stored_session(rp) is None, "sign out clears the session in the browser")
    st, _ = api("/token?grant_type=refresh_token", {"refresh_token": before["refresh_token"]})
    check(st == 400, "sign out revokes the session on the server (refresh refused)")
    rp.goto(APP + "/")
    rp.wait_for_url(re.compile(r".*/login.*"), timeout=15000)
    check(True, "after sign out, app screens redirect to sign-in")

    # ------------------------------------------------------------- 7. session renewal and deactivation mid-session
    rp.get_by_label("Work email").fill("esha@acme.test")
    rp.get_by_label("Password").fill("Esha#second2")
    rp.get_by_role("button", name="Sign in").click()
    wait_home(rp)
    s1 = stored_session(rp)
    exp = int(os.environ.get("JWT_EXP", "3600"))
    if exp <= 120:
        rp.wait_for_timeout((exp + 15) * 1000)
        rp.goto(APP + "/my-attendance")
        wait_home(rp)
        rp.get_by_role("heading", name="My Attendance").first.wait_for(timeout=20000)
        rp.wait_for_timeout(1500)
        check("/login" not in rp.url, "still signed in after the first token expired")
        s2 = stored_session(rp)
        check(s2 and s2["access_token"] != s1["access_token"], f"session renewed automatically after the {exp}s token expired; screens keep working")
    token = stored_session(rp)["access_token"]
    eid = sql("select id from employees where email = 'esha@acme.test'")
    admin.goto(APP + f"/employees?id={eid}")
    admin.get_by_role("button", name="Deactivate").click()
    admin.get_by_role("dialog").get_by_role("button", name="Deactivate").click()
    admin.wait_for_timeout(1200)
    check(sql(f"select active from employees where id = '{eid}'") == "f", "Admin deactivated Esha in the app")
    check(rest("/employees?select=id", token) == [], "her still-unexpired token returns no data at once (database check, not the token)")
    rp.goto(APP + "/my-attendance")
    rp.wait_for_url(re.compile(r".*/login\?error=inactive.*"), timeout=20000)
    rp.get_by_text("Your login is switched off").wait_for()
    check(True, "the app signs her out with the 'switched off' message on the next screen")
    shot(rp, "a12-deactivated")
    rp.get_by_label("Work email").fill("esha@acme.test")
    rp.get_by_label("Password").fill("Esha#second2")
    rp.get_by_role("button", name="Sign in").click()
    rp.get_by_text("Your login is switched off").wait_for()
    check(stored_session(rp) is None, "signing in again is refused while switched off")
    admin.reload()
    admin.get_by_role("button", name="Reactivate").click()
    admin.get_by_role("dialog").get_by_role("button", name="Reactivate").click()
    admin.wait_for_timeout(1200)
    rp.get_by_role("button", name="Sign in").click()
    wait_home(rp)
    check(True, "after reactivation the same login works again")

    # Activity log shows the real Admin for each change
    admin.goto(APP + "/settings")
    admin.get_by_role("tab", name="Activity log").click()
    admin.get_by_text("Esha Patil").first.wait_for()
    shot(admin, "a13-activity-log")
    srcs = sql("select string_agg(distinct source, ',' order by source) from audit_log where target = 'employees'")
    check("app" in srcs and "system" in srcs, f"activity log separates people's actions from automatic sign-in linking ({srcs})")
    browser.close()

passed = sum(ok for ok, _ in results)
print(f"\n{passed}/{len(results)} sign-in checks passed")
json.dump([{"ok": ok, "what": w} for ok, w in results], open(os.path.join(SHOTS, "authcheck-results.json"), "w"), indent=1)
sys.exit(0 if passed == len(results) else 1)
