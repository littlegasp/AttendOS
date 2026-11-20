"""
B3.3 gateway over real HTTP: PostgREST (the same server Supabase uses for /rest/v1) in front of the local demo database
with migrations 0001–0011. The agent calls POST /rpc/biometric_ingest and /rpc/biometric_heartbeat with no login — the
anonymous role — and its key in the JSON body. Checks the answers, what is stored, the client address taken from
X-Forwarded-For, that a key is never accepted in the URL, and that no key appears in the PostgREST or Postgres logs.
Usage: python3 e2e/biometric_gateway_http.py http://127.0.0.1:3001
"""
import json, os, subprocess, sys, urllib.parse, urllib.request, urllib.error, uuid, datetime

API = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:3001"
results = []
def check(ok, what):
    results.append((bool(ok), what)); print(("PASS " if ok else "FAIL ") + what)
def db(q):
    r = subprocess.run(["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-h", "/tmp/pg", "-p", "5433", "-U", "postgres", "-d", "attendos_demo", "-c", q], capture_output=True, text=True)
    if r.returncode: raise SystemExit(r.stderr)
    return r.stdout.strip()
def post(fn, body, headers=None, raw=None):
    data = raw if raw is not None else json.dumps(body).encode()
    req = urllib.request.Request(f"{API}/rpc/{fn}", data=data, method="POST",
                                 headers={"Content-Type": "application/json", "X-Forwarded-For": "203.0.113.7", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=20) as r: return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, (json.loads(e.read() or b"null") if e.headers.get("content-type", "").startswith("application/json") else None)

# ------------------------------------------------------------ setup in the demo database (as the database owner)
cid = db("select id from companies order by created_at limit 1")
key = db(f"""with k as (select * from biometric_new_key()),
  a as (insert into biometric_agents (company_id, name, agent_identifier) values ('{cid}', 'HTTP test agent', 'http-test-{uuid.uuid4().hex[:6]}') returning id),
  c as (insert into biometric_agent_credentials (company_id, agent_id, key_prefix, key_hash) select '{cid}', a.id, k.key_prefix, k.key_hash from a, k returning agent_id)
  select k.agent_key || '|' || c.agent_id from k, c""")
key, agent = key.split("|")
loc = db(f"select id from locations where company_id = '{cid}' and active order by name limit 1")
serial = "HTTP" + uuid.uuid4().hex[:6].upper()
dev = db(f"""insert into biometric_devices (company_id, location_id, name, manufacturer, model, serial_number, integration_method, agent_id, timezone)
  values ('{cid}', '{loc}', 'HTTP test door', 'zkteco', 'MB160', '{serial}', 'sdk_pull', '{agent}', (select timezone from companies where id = '{cid}')) returning id""")
emp = db(f"select id from employees where company_id = '{cid}' and active order by email limit 1")
db(f"insert into biometric_employee_mappings (company_id, device_id, employee_id, employee_device_code, valid_from) values ('{cid}', '{dev}', '{emp}', '0101', now() - interval '7 days')")
tz = db(f"select timezone from companies where id = '{cid}'")
def local(mins_ago):
    return db(f"select to_char(date_trunc('second', now()) at time zone '{tz}' - interval '{mins_ago} minutes', 'YYYY-MM-DD HH24:MI:SS')")
secret = key.split("_", 2)[2]

# ------------------------------------------------------------ ingest
batch = {"batch_id": str(uuid.uuid4()), "agent_version": "0.1.0-http",
         "devices": [{"manufacturer": "zkteco", "serial": serial, "clock_drift_s": 4}],
         "events": [{"manufacturer": "zkteco", "serial": serial, "employee_code": "0101", "local_time": local(20), "record_seq": 1, "direction": "in", "payload": {"uid": "0101"}},
                    {"manufacturer": "zkteco", "serial": serial, "employee_code": "0777", "local_time": local(19), "record_seq": 2},
                    {"manufacturer": "zkteco", "serial": serial, "employee_code": "0101", "local_time": local(-10), "record_seq": 3}]}
st, r = post("biometric_ingest", {"p_key": key, "p_batch": batch})
check(st == 200 and r["ok"] and r["stored"] == 2 and r["rejected"] == 1 and [o.get("status") or o.get("reason") for o in r["outcomes"]] == ["stored", "unmatched", "future_time"],
      "HTTP ingest without a login (anon) with the key in the body: 2 stored (mapped + unmatched), 1 future punch rejected")
ip_run = db(f"select host(client_ip) from biometric_sync_runs where batch_id = '{batch['batch_id']}'"); ip_agent = db(f"select host(last_ip) from biometric_agents where id = '{agent}'")
check(ip_run == "203.0.113.7" and ip_agent == "203.0.113.7", f"the client address comes from X-Forwarded-For (sync run {ip_run}, agent {ip_agent})")
check(db(f"select count(*) from attendance_events e join employees p on p.id = e.employee_id where p.company_id = '{cid}' and e.at > now() - interval '1 hour' and e.source <> 'web'") == "0",
      "nothing reached attendance")
st2, r2 = post("biometric_ingest", {"p_key": key, "p_batch": batch})
check(st2 == 200 and r2.get("replay") is True and {k: v for k, v in r2.items() if k != "replay"} == r, "resending the batch over HTTP returns the stored answer (replay)")
bad_answers = [post("biometric_ingest", {"p_key": k, "p_batch": batch})[1] for k in
               ["bak_x", key[:-1] + ("A" if key[-1] != "A" else "B"), "bak_000000000000_" + "A" * 43, "", key + "x"]]
check(all(a == {"ok": False, "code": "not_accepted", "message": "Not accepted."} for a in bad_answers), "five kinds of wrong key get the identical answer over HTTP")
st3, r3 = post("biometric_ingest", {"p_key": key, "p_batch": {"batch_id": str(uuid.uuid4()), "events": [], "pad": "x" * 270000}})
check(st3 == 200 and r3["code"] == "too_large", "a body over 256 KB is refused")
before_runs = db(f"select count(*) from biometric_sync_runs where agent_id = '{agent}'")
gst = urllib.request.Request(f"{API}/rpc/biometric_ingest?p_key={key}&p_batch=" + urllib.parse.quote(json.dumps({"batch_id": str(uuid.uuid4()), "events": []})), method="GET")
try:
    with urllib.request.urlopen(gst, timeout=20) as resp: gcode, gbody = resp.status, json.loads(resp.read() or b"null")
except urllib.error.HTTPError as e: gcode, gbody = e.code, None
check((gcode >= 400 or (gbody or {}).get("code") == "use_post") and db(f"select count(*) from biometric_sync_runs where agent_id = '{agent}'") == before_runs,
      f"a key in a URL is never accepted: GET is refused before the key is checked (HTTP {gcode}, {gbody})")
gh = urllib.request.Request(f"{API}/rpc/biometric_heartbeat?p_key={key}&p_status=%7B%7D", method="GET")
try:
    with urllib.request.urlopen(gh, timeout=20) as resp: hbody = json.loads(resp.read() or b"null")
except urllib.error.HTTPError as e: hbody = {"code": f"http {e.code}"}
check(hbody.get("code") in ("use_post",) or hbody.get("code", "").startswith("http"), f"the same for heartbeat ({hbody})")

# ------------------------------------------------------------ heartbeat
st4, h = post("biometric_heartbeat", {"p_key": key, "p_status": {"agent_version": "0.1.0-http", "devices": [{"manufacturer": "zkteco", "serial": serial, "reachable": True, "clock_drift_s": 6}]}})
check(st4 == 200 and h["ok"] and [d["serial"] for d in h["devices"]] == [serial], "heartbeat over HTTP returns the agent's device list")
st5, h2 = post("biometric_heartbeat", {"p_key": key, "p_status": {}})
check(h2.get("code") == "throttled", "a second heartbeat within 30 s is throttled")
st6, h3 = post("biometric_heartbeat", {"p_key": "bak_x", "p_status": {}})
check(h3 == {"ok": False, "code": "not_accepted", "message": "Not accepted."}, "heartbeat with a wrong key: the same generic answer")

# ------------------------------------------------------------ the key in logs
logs = ""
for f in ["supabase/demo/pgrst.log", "/tmp/pg/log"]:
    try: logs += open(f, errors="replace").read()
    except FileNotFoundError: pass
check(secret not in logs and key not in logs, f"the key (or its secret part) is in neither the PostgREST log nor the Postgres server log ({len(logs)} bytes checked)")
check(secret not in db("select coalesce(string_agg(coalesce(before::text,'') || coalesce(after::text,''), ''), '') from audit_log")
      and secret not in db("select coalesce(string_agg(response::text, ''), '') from biometric_sync_runs")
      and secret not in db("select coalesce(string_agg(detail::text, ''), '') from biometric_event_errors"), "nor in the audit log, sync-run answers or error records")

fails = [w for ok, w in results if not ok]
print(f"\n{len(results) - len(fails)}/{len(results)} passed")
sys.exit(1 if fails else 0)
