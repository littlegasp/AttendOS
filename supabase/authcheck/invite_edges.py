"""
Invitation edge cases against the REAL Supabase Auth server + PostgREST started by start.sh (run start.sh first;
it resets the local attendos_auth database). No browser: the app's calls are made directly
(rpc prepare_invitation, then POST /otp exactly as signInWithOtp does). Usage: python3 invite_edges.py
"""
import glob, json, os, re, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
MAIL = os.path.join(HERE, "mail")
ANON = open("/tmp/anon.jwt").read().strip()
APP = "http://127.0.0.1:4175"
results = []


def check(ok, what):
    results.append((bool(ok), what))
    print(("PASS " if ok else "FAIL ") + what, flush=True)


def sql(q):
    r = subprocess.run(["psql", "-h", "/tmp/pg", "-p", os.environ.get("PGPORT", "5433"), "-U", "postgres", "-d", "attendos_auth",
                        "-Atc", q], capture_output=True, text=True)
    return (r.stdout.strip() or r.stderr.strip())


def mails(to):
    return [json.load(open(f)) for f in sorted(glob.glob(os.path.join(MAIL, "*.json")))
            if any(to.lower() == r.lower() for r in json.load(open(f))["to"])]


def wait_mail(to, n, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        if len(mails(to)) >= n:
            return mails(to)[n - 1]
        time.sleep(0.3)
    return None


def link_in(m):
    u = (re.search(r'href="([^"]+/verify\?[^"]+)"', m["body"]) or re.search(r'(https?://\S+/verify\?\S+)', m["body"])).group(1)
    return "http://127.0.0.1:9999/verify?" + u.replace("&amp;", "&").split("/verify?", 1)[1]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def open_link(url):
    """Open an e-mailed link like a browser would; returns (redirect target, access token or None, error or None)."""
    try:
        urllib.request.build_opener(NoRedirect).open(url)
        return None, None, "no redirect"
    except urllib.error.HTTPError as e:
        loc = e.headers.get("Location", "")
        frag = urllib.parse.parse_qs(urllib.parse.urlparse(loc).fragment)
        q = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)
        err = (frag.get("error_code") or q.get("error_code") or frag.get("error") or q.get("error") or [None])[0]
        return loc, (frag.get("access_token") or [None])[0], err


def call(base, path, body=None, token=None, method=None, extra=None):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
                                 method=method or ("POST" if body is not None else "GET"),
                                 headers={"Content-Type": "application/json", "apikey": ANON,
                                          "Authorization": "Bearer " + (token or ANON), **(extra or {})})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"null")
        except ValueError:
            return e.code, raw.decode()


auth = lambda *a, **k: call("http://127.0.0.1:9999", *a, **k)
rest = lambda *a, **k: call("http://127.0.0.1:3002", *a, **k)


def admin_login(email, slug):
    st, _ = auth(f"/signup?redirect_to={APP}/login", {"email": email, "password": "Admin-pass-123"})
    _, tok, _ = open_link(link_in(wait_mail(email, 1)))
    st, s = auth("/token?grant_type=password", {"email": email, "password": "Admin-pass-123"})
    return s.get("access_token")


def invite(token, emp_id, email_expected=None):
    """What the app's Send invite button does."""
    st, r = rest("/rpc/prepare_invitation", {"p_employee": emp_id}, token)
    if st != 200:
        return st, r.get("message") if isinstance(r, dict) else r
    st2, r2 = auth(f"/otp?redirect_to={urllib.parse.quote(APP + '/reset-password?welcome=1')}",
                   {"email": r["email"], "create_user": True})
    return st2, r["email"]


def emp(email):
    return sql(f"select id from employees where email = '{email}'")


def backdate(emp_id, minutes=11):
    sql(f"alter table employee_invitations disable trigger all; update employee_invitations set invited_at = invited_at - interval '{minutes} minutes' where employee_id = '{emp_id}'; alter table employee_invitations enable trigger all")


# ------------------------------------------------------------------ setup: two companies, staff added by HR
sql("select public.create_company('Beta Works', 'beta', 'Asia/Kolkata', 'admin@beta.test', 'Bina Admin')")
for name, mail_ in [("Exp Iry", "expiry@acme.test"), ("Old Mail", "old@acme.test"), ("Off Line", "offline@acme.test")]:
    sql(f"insert into employees (company_id, full_name, email) select id, '{name}', '{mail_}' from companies where slug = 'acme'")
A = admin_login("admin@acme.test", "acme")
B = admin_login("admin@beta.test", "beta")
check(A and B, "both company Admins signed in through the real Auth server")

# ------------------------------------------------------------------ 1. expired invitation
e1 = emp("expiry@acme.test")
st, to = invite(A, e1)
m1 = wait_mail("expiry@acme.test", 1)
check(st == 200 and m1 is not None, "invitation e-mailed to the work address")
# Age the link past the 24-hour expiry (what Supabase checks: when the e-mail was sent).
sql("update auth.users set confirmation_sent_at = now() - interval '25 hours' where email = 'expiry@acme.test'")
loc, tok, err = open_link(link_in(m1))
check(tok is None and err is not None, f"expired invitation link signs no one in (Auth answered: {err})")
check(sql(f"select user_id is null from employees where id = '{e1}'") == "t", "expired link links nothing")
st, msg = invite(A, e1)
check(st != 200 and "10 minutes" in str(msg), "re-invite inside 10 minutes is refused (no duplicate e-mail)")
check(len(mails("expiry@acme.test")) == 1, "still exactly one e-mail")
backdate(e1)
st, _ = invite(A, e1)
m2 = wait_mail("expiry@acme.test", 2)
check(st == 200 and m2 is not None and link_in(m2) != link_in(m1), "after 10 minutes a fresh invitation goes to the same existing (unconfirmed) login")
loc, tok, err = open_link(link_in(m2))
check(tok is not None and "/reset-password?welcome=1" in loc, "the fresh link works and opens the welcome page")
check(sql(f"select c.slug from employees e join companies c on c.id = e.company_id join auth.users u on u.id = e.user_id where e.id = '{e1}'") == "acme",
      "linked to the employee record in the inviting company")
check(sql(f"select string_agg(status, ',' order by id) from employee_invitations where employee_id = '{e1}'") == "accepted,accepted",
      "both invitation rows show accepted")
check(sql("select count(*) from auth.users where lower(email) = 'expiry@acme.test'") == "1", "one login for the address (no duplicate user)")

# ------------------------------------------------------------------ 2. already linked
st, msg = invite(A, e1)
check(st != 200 and "already has a login" in str(msg), "inviting an already-linked person is refused")
st, r = rest(f"/employees?id=eq.{e1}", {"email": "other@acme.test"}, A, "PATCH", {"Prefer": "return=minimal"})
check(st >= 400 and "linked to a login" in json.dumps(r), "a linked person's work e-mail can't be changed from the app")

# ------------------------------------------------------------------ 3. work e-mail changed while an invitation is open
e2 = emp("old@acme.test")
invite(A, e2)
mo = wait_mail("old@acme.test", 1)
st, r = rest(f"/employees?id=eq.{e2}", {"email": "new@acme.test"}, A, "PATCH", {"Prefer": "return=minimal"})
check(st in (200, 204), "HR corrects the work e-mail before the invitation is opened")
loc, tok_old, err = open_link(link_in(mo))
check(sql(f"select user_id is null from employees where id = '{e2}'") == "t", "the link sent to the OLD address no longer links to this person")
if tok_old:
    st, rows = rest("/employees?select=id", None, tok_old)
    check(rows == [], "the old address's login sees no company data at all")
else:
    check(True, f"the old link signed no one in ({err})")
backdate(e2)
st, sent_to = invite(A, e2)
check(sent_to == "new@acme.test" and wait_mail("new@acme.test", 1) is not None and len(mails("old@acme.test")) == 1,
      "the next invitation goes only to the corrected address")
loc, tok, err = open_link(link_in(mails("new@acme.test")[0]))
check(sql(f"select u.email from employees e join auth.users u on u.id = e.user_id where e.id = '{e2}'") == "new@acme.test",
      "the corrected address links; the old one stays unlinked")

# ------------------------------------------------------------------ 4. existing CONFIRMED login that is not linked
e3 = emp("offline@acme.test")
invite(A, e3)
mf = wait_mail("offline@acme.test", 1)
rest(f"/employees?id=eq.{e3}", {"active": False}, A, "PATCH", {"Prefer": "return=minimal"})
open_link(link_in(mf))  # opened while switched off: confirmed, not linked (access is off)
check(sql(f"select (select user_id is null from employees where id = '{e3}') and (select email_confirmed_at is not null from auth.users where email = 'offline@acme.test')") == "t",
      "a link opened while the person is switched off confirms the address but grants nothing")
rest(f"/employees?id=eq.{e3}", {"active": True}, A, "PATCH", {"Prefer": "return=minimal"})
linked_on_reactivate = sql(f"select user_id is not null from employees where id = '{e3}'") == "t"
print(f"INFO reactivation links the confirmed login: {linked_on_reactivate}")
backdate(e3)
st, _ = invite(A, e3)
ml = wait_mail("offline@acme.test", 2)
loc, tok, err = open_link(link_in(ml)) if ml else (None, None, "no mail")
check(sql(f"select user_id is not null from employees where id = '{e3}'") == "t",
      "after reactivation, the person is linked (re-invite of an existing confirmed login works)")

# ------------------------------------------------------------------ 5. company boundaries
acme_mail = "expiry@acme.test"
st, r = rest("/employees", {"full_name": "Copy Cat", "email": acme_mail}, B, "POST", {"Prefer": "return=minimal"})
check(st >= 400, "another company can't add a person with an e-mail already used in AttendOS (one e-mail = one company)")
st, msg = invite(B, e2)
check(st != 200, "another company's HR can't invite this company's employee")
st, rows = rest("/employee_invitations?select=id", None, B)
check(rows == [], "another company's HR sees none of this company's invitations")
sql("insert into employees (company_id, full_name, email) select id, 'Beta Person', 'bp@beta.test' from companies where slug = 'beta'")
st, _ = invite(B, emp("bp@beta.test"))
open_link(link_in(wait_mail("bp@beta.test", 1)))
check(sql("select c.slug from employees e join companies c on c.id = e.company_id where e.email = 'bp@beta.test' and e.user_id is not null") == "beta",
      "a Beta invitation links only to the Beta record")
st, n = rest("/rpc/prepare_invitation", {"p_employee": emp("bp@beta.test")}, A)
check(st != 200, "and Acme's Admin can't invite Beta's people")
check(sql("select count(*) from employees e join auth.users u on u.id = e.user_id where lower(u.email) <> lower(e.email)") == "0",
      "every linked login's e-mail equals its employee record's work e-mail")

fails = [w for ok, w in results if not ok]
print(f"\n{len(results) - len(fails)}/{len(results)} passed")
sys.exit(1 if fails else 0)
