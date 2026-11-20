"""
B3.4 projection end to end over real HTTP (design §12.4, database side): PostgREST in front of the local demo database
with migrations 0001–0012. A test company is created in the DEMO database only (projection is switched on for that
company there, nowhere else). Path: agent → anonymous POST /rpc/biometric_ingest → the queue procedure (called directly:
pg_cron is not installed locally) → what the signed-in employee and HR read over HTTP (my_today, day_events,
biometric_day_pending, attendance_register, attendance_day_sources, verification_log) and what they may NOT call.
Usage: python3 e2e/biometric_projection_http.py http://127.0.0.1:3001
"""
import base64, hashlib, hmac, json, subprocess, sys, time, urllib.error, urllib.request, uuid

API = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:3001"
SECRET = b"demo-secret-demo-secret-demo-secret-32"
results = []
def check(ok, what):
    results.append((bool(ok), what)); print(("PASS " if ok else "FAIL ") + what)
def db(q):
    r = subprocess.run(["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-h", "/tmp/pg", "-p", "5433", "-U", "postgres", "-d", "attendos_demo", "-c", q],
                       capture_output=True, text=True)
    if r.returncode: raise SystemExit(r.stderr)
    return r.stdout.strip()
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def token(sub):
    h = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    p = b64(json.dumps({"sub": sub, "role": "authenticated", "aud": "authenticated", "exp": int(time.time()) + 3600}).encode())
    return f"{h}.{p}." + b64(hmac.new(SECRET, f"{h}.{p}".encode(), hashlib.sha256).digest())
def rpc(fn, body, sub=None):
    headers = {"Content-Type": "application/json"}
    if sub: headers["Authorization"] = "Bearer " + token(sub)
    req = urllib.request.Request(f"{API}/rpc/{fn}", data=json.dumps(body).encode(), method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as r: return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        raw = e.read(); return e.code, (json.loads(raw) if raw[:1] in (b"{", b"[") else raw.decode())

# ------------------------------------------------------------ test company in the demo database (local noon, like the SQL suite)
off = 12 - int(db("select extract(hour from now() at time zone 'UTC')::int"))
tz = "Etc/GMT" if off == 0 else (f"Etc/GMT-{off}" if off > 0 else f"Etc/GMT+{-off}")
slug = "e2e-" + uuid.uuid4().hex[:6]
emp_uid, hr_uid = str(uuid.uuid4()), str(uuid.uuid4())
cid = db(f"insert into companies (name, slug, timezone, weekly_off) values ('E2E Projection', '{slug}', '{tz}', '{{}}') returning id")
db(f"""insert into shifts (company_id, name, start_time, end_time) values ('{cid}', 'Day', '08:00', '16:00');
  update companies set default_shift_id = (select id from shifts where company_id = '{cid}') where id = '{cid}';
  insert into locations (company_id, name, lat, lng, radius_m) values ('{cid}', 'E2E Plant', 19.1, 72.9, 150);
  insert into auth.users (id, email, email_confirmed_at) values ('{emp_uid}', 'emp@{slug}.co', now()), ('{hr_uid}', 'hr@{slug}.co', now());
  insert into employees (company_id, full_name, email, role, user_id, home_location_id, joining_date)
    select '{cid}', x.n, x.e, x.r, x.u::uuid, (select id from locations where company_id = '{cid}'), current_date - 30
      from (values ('E2E Worker', 'emp@{slug}.co', 'employee', '{emp_uid}'), ('E2E HR', 'hr@{slug}.co', 'hr', '{hr_uid}')) x(n, e, r, u);""")
emp = db(f"select id from employees where email = 'emp@{slug}.co'")
key, agent = db(f"""with k as (select * from biometric_new_key()),
  a as (insert into biometric_agents (company_id, name, agent_identifier) values ('{cid}', 'E2E agent', 'e2e-{slug}') returning id),
  c as (insert into biometric_agent_credentials (company_id, agent_id, key_prefix, key_hash) select '{cid}', a.id, k.key_prefix, k.key_hash from a, k returning agent_id)
  select k.agent_key || '|' || c.agent_id from k, c""").split("|")
serial = "E2E" + uuid.uuid4().hex[:6].upper()
db(f"""insert into biometric_devices (company_id, location_id, name, manufacturer, model, serial_number, integration_method, agent_id, timezone, device_auth)
  values ('{cid}', (select id from locations where company_id = '{cid}'), 'E2E gate', 'zkteco', 'MB160', '{serial}', 'sdk_pull', '{agent}', '{tz}', 'comm_key');
  insert into biometric_employee_mappings (company_id, employee_id, employee_device_code, valid_from) values ('{cid}', '{emp}', '0042', now() - interval '7 days');""")
today = db(f"select local_today('{cid}')")
def local(t): return f"{today} {t}"

# ------------------------------------------------------------ 1. projection off (default): ingest stores, nothing is projected
st, r = rpc("biometric_ingest", {"p_key": key, "p_batch": {"batch_id": str(uuid.uuid4()), "agent_version": "e2e", "events": [
    {"manufacturer": "zkteco", "serial": serial, "employee_code": "0042", "local_time": local("08:50:00"), "record_seq": 1},
    {"manufacturer": "zkteco", "serial": serial, "employee_code": "0042", "local_time": local("11:00:00"), "record_seq": 2}]}})
check(st == 200 and r["ok"] and r["stored"] == 2, "anonymous ingest over HTTP stores the two punches")
db("call biometric_run_projection()")
check(db(f"select count(*) from attendance_events where employee_id = '{emp}'") == "0", "projection is off by default: the queue projects nothing for this company")

# ------------------------------------------------------------ 2. switched on for this demo company only
db(f"insert into biometric_settings (company_id, projection_enabled) values ('{cid}', true)")
check(db("select count(*) from biometric_settings where projection_enabled") == "1", "only the E2E demo company has projection on")
db("call biometric_run_projection()")
st, t = rpc("my_today", {}, emp_uid)
ev = (t or {}).get("events", [])
check(st == 200 and len(ev) == 1 and ev[0]["source"] == "biometric" and ev[0]["verified"] is False and ev[0]["kind"] == "in",
      f"my_today over HTTP: one biometric check-in, not location-verified ({ev})")
check(t["summary"]["status"] == "working" and t["summary"]["overtime_min"] == 0 and t["summary"]["early_min"] == 0,
      "my_today: the day is open (working); no overtime or early leaving from the provisional punch")
st, p = rpc("biometric_day_pending", {"p_emp": emp, "p_day": today}, emp_uid)
check(st == 200 and p["pending_checkout"] is True and p["provisional_out_at"] and p["final_at"], f"biometric_day_pending over HTTP: pending check-out ({p})")
st, d = rpc("day_events", {"p_emp": emp, "p_day": today}, emp_uid)
labels = sorted((x["label"], x["counted"]) for x in d) if st == 200 else d
check(st == 200 and ("Provisional Out", False) in labels and ("Biometric · inferred", True) in labels and all("payload" not in x for x in d),
      f"day_events over HTTP: counted check-in and an uncounted Provisional Out; no payload ({labels})")
st, reg = rpc("attendance_register", {"p_from": today, "p_to": today, "p_employee": emp}, hr_uid)
check(st == 200 and len(reg) == 1 and reg[0]["status"] == "working" and reg[0]["last_out"] is None, "attendance_register over HTTP (HR): working, no check-out yet")
st, src = rpc("attendance_day_sources", {"p_from": today, "p_to": today, "p_employee": emp}, hr_uid)
check(st == 200 and src[0]["sources"] == ["biometric"] and src[0]["pending_checkout"] is True, f"attendance_day_sources over HTTP (CSV Source column): {src}")
st, vl = rpc("verification_log", {"p_limit": 20}, hr_uid)
check(st == 200 and any(v["outcome"] == "biometric" for v in vl) and not any(v["outcome"] == "verified" for v in vl), "verification_log over HTTP: Biometric, never verified")

# ------------------------------------------------------------ 3. what clients may not call
for fn, body in [("biometric_project_day", {"p_emp": emp, "p_day": today}), ("biometric_set_role", {"p_raw": 1, "p_status": "projected"}),
                 ("biometric_write_slot", {"p_emp": emp, "p_day": today, "p_slot": "in", "p_kind": "in", "p_raw": 1, "p_basis": "device"}),
                 ("decide_correction_core", {"p_id": 1, "p_approve": True})]:
    st_e, _ = rpc(fn, body, emp_uid); st_h, _ = rpc(fn, body, hr_uid); st_a, _ = rpc(fn, body)
    check(st_e in (401, 403, 404) and st_h in (401, 403, 404) and st_a in (401, 403, 404), f"{fn}: refused for employee ({st_e}), HR ({st_h}) and anonymous ({st_a})")
st, _ = rpc("biometric_project_now", {"p_emp": emp, "p_day": today}, emp_uid)
check(st in (400, 403), f"biometric_project_now: refused for the employee ({st})")
st, r = rpc("biometric_project_now", {"p_emp": emp, "p_day": today}, hr_uid)
check(st == 200 and r["ok"], "biometric_project_now: allowed for HR of the company")
check(db("select count(*) from pg_proc p where p.proname in ('biometric_run_projection') and has_function_privilege('anon', p.oid, 'execute')") == "0",
      "the queue procedure is not callable over the API (anon)")

passed = sum(1 for ok, _ in results if ok)
print(f"{passed}/{len(results)} passed")
sys.exit(0 if passed == len(results) else 1)
