"""LOCAL rehearsal of the whole development-Supabase preflight (G1 evidence). Touches no hosted system.

Builds a Supabase-like stack on this machine and runs every owner step with the real tools, in owner order:
  local PostgreSQL 16 (database attendos_dev_rehearsal) with Supabase's API roles, its worst-case grants (CREATE on
  schema public and default privileges for anon/authenticated), statement_timeout 8 s for signed-in calls; the real
  Supabase Auth server (release binary) issuing tokens as https://<fake ref>.supabase.co/auth/v1; PostgREST 12; a small
  gateway that, like Supabase's, serves /auth/v1 and /rest/v1 on one address and requires the apikey header.
The fake project reference is attendosrehearsalabc; the migration role is "postgres.attendosrehearsalabc" (the
Supabase pooler user form). Nothing here can reach a hosted project (devguard rehearsal mode refuses non-local hosts).

  python3 supabase/deploy/dev_preflight/rehearsal/local_rehearsal.py --commit <HEAD> [--auth-dir DIR] [--report FILE]

Needs: PGHOST/PGPORT/PGUSER (local superuser), postgrest on PATH (or --postgrest), the Auth binary (--auth-dir, with
migrations/), python psycopg 3. The commit must be HEAD with the migrations and manifest committed (dev_apply checks).
"""
import argparse
import base64
import hashlib
import hmac
import http.server
import json
import os
import re
import secrets
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
PRE = HERE.parent
REPO = PRE.parents[2]
REF = "attendosrehearsalabc"
OTHER_REF = "otherprojectrefabcde"
DB, REFDB = "attendos_dev_rehearsal", "attendos_dev_rehearsal_ref0012"
ROLE = f"postgres.{REF}"
AUTH_PORT, REST_PORT, GW_PORT = 9998, 3004, 54329
PG = dict(PGHOST=os.environ.get("PGHOST", "/tmp/pg"), PGPORT=os.environ.get("PGPORT", "5433"), PGUSER=os.environ.get("PGUSER", "postgres"))
results, secrets_used, procs = [], [], []
OUT = Path(tempfile.mkdtemp(prefix="attendos-dev-rehearsal-"))   # outside the repository
REPORTS = OUT / "reports"
transcript = []


def log(s):
    print(s, flush=True)
    transcript.append(s)


def check(ok, what):
    results.append((bool(ok), what))
    log(("PASS " if ok else "FAIL ") + what)
    return ok


def sh(args, env=None, input=None):
    r = subprocess.run(args, env={**os.environ, **PG, **(env or {})}, capture_output=True, text=True, input=input)
    transcript.append(f"$ {' '.join(a if 'postgres' not in a or '@' not in a else '<conn>' for a in args)}\n{r.stdout}{r.stderr}")
    return r


def psql(db, sql, user=None):
    env = {"PGUSER": user} if user else {}
    r = sh(["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-d", db, "-c", sql], env)
    if r.returncode:
        raise SystemExit(f"setup SQL failed on {db}: {r.stderr}")
    return r.stdout.strip()


def b64(d):
    return base64.urlsafe_b64encode(d).rstrip(b"=").decode()


def jwt(payload, secret):
    h, p = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()), b64(json.dumps(payload).encode())
    return f"{h}.{p}.{b64(hmac.new(secret.encode(), f'{h}.{p}'.encode(), hashlib.sha256).digest())}"


# ---------------------------------------------------------------- the Supabase-like local stack
def build_db(name, auth_dir):
    sh(["dropdb", "--if-exists", "--force", name])
    if sh(["createdb", name]).returncode:
        raise SystemExit(f"createdb {name} failed")
    psql(name, f"""
      do $$ begin
        if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
        if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
        if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
        if not exists (select 1 from pg_roles where rolname = 'authenticator') then create role authenticator login noinherit; end if;
        if not exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then create role supabase_auth_admin nologin; end if;
        if not exists (select 1 from pg_roles where rolname = '{ROLE}') then create role "{ROLE}" login superuser; end if;
      end $$;
      grant anon, authenticated, service_role to authenticator;
      alter role authenticated in database {name} set statement_timeout = '8s';
      alter role anon in database {name} set statement_timeout = '3s';
      create schema auth;
      create schema extensions;   -- present on every Supabase project
      grant usage on schema auth, public, extensions to anon, authenticated, service_role;
      -- worst case for owner decision D5 and the explicit revokes: API roles may CREATE in public, and new objects
      -- are granted to them automatically (Supabase default privileges)
      grant create on schema public to anon, authenticated;
      alter default privileges for role "{ROLE}" in schema public grant all on tables to anon, authenticated, service_role;
      alter default privileges for role "{ROLE}" in schema public grant all on sequences to anon, authenticated, service_role;
      alter default privileges for role "{ROLE}" in schema public grant all on functions to anon, authenticated, service_role;""")
    env = dict(GOTRUE_DB_DRIVER="postgres", DB_NAMESPACE="auth",
               DATABASE_URL=f"postgres://postgres@127.0.0.1:{PG['PGPORT']}/{name}?sslmode=disable&search_path=auth",
               GOTRUE_DB_MIGRATIONS_PATH=f"{auth_dir}/migrations", API_EXTERNAL_URL=f"https://{REF}.supabase.co/auth/v1",
               GOTRUE_SITE_URL="http://127.0.0.1:4175", GOTRUE_JWT_SECRET="migrate-only-" + secrets.token_urlsafe(24))
    r = subprocess.run(["./auth", "migrate"], cwd=auth_dir, env={**os.environ, **env}, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit("auth migrate failed: " + r.stderr[-500:])
    psql(name, "grant execute on function auth.uid(), auth.role() to anon, authenticated")


def tool_env(db, pw, extra=None):
    e = {"ATTENDOS_DEV_LOCAL_REHEARSAL": "1", "ATTENDOS_DEV_PROJECT_REF": REF, "ATTENDOS_FORBIDDEN_PROJECT_REFS": OTHER_REF,
         "ATTENDOS_DEV_DB_URL": f"postgresql://{ROLE}:{pw}@/{db}?host={PG['PGHOST']}&port={PG['PGPORT']}",
         "ATTENDOS_DEV_REPORT_DIR": str(REPORTS)}
    e.update(extra or {})
    return e


def tool(args, env):
    r = subprocess.run([sys.executable, *args], cwd=PRE, env={k: v for k, v in {**os.environ, **env}.items() if not k.startswith("PG")},
                       capture_output=True, text=True)
    transcript.append(f"$ python3 {' '.join(args)}\n{r.stdout}{r.stderr}")
    return r


def not_ok_rows(out):
    """rows of a psql table (item | ok | …) whose ok column is f"""
    return [l for l in out.splitlines() if re.search(r"\|\s*f\s*\|", l) or re.search(r"\|\s*f\s*$", l)]


class Gateway(http.server.BaseHTTPRequestHandler):
    anon = None

    def log_message(self, *a):
        pass

    def _go(self):
        if self.headers.get("apikey") != Gateway.anon:
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b'{"message":"Invalid API key"}')
            return
        if self.path.startswith("/auth/v1/"):
            target = f"http://127.0.0.1:{AUTH_PORT}" + self.path[len("/auth/v1"):]
        elif self.path.startswith("/rest/v1/"):
            target = f"http://127.0.0.1:{REST_PORT}" + self.path[len("/rest/v1"):]
        else:
            self.send_response(404)
            self.end_headers()
            return
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        h = {k: v for k, v in self.headers.items() if k.lower() in ("authorization", "content-type", "prefer", "accept")}
        req = urllib.request.Request(target, data=body, method=self.command, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                code, data, ctype = r.status, r.read(), r.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as e:
            code, data, ctype = e.code, e.read(), e.headers.get("Content-Type", "application/json")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PATCH = do_DELETE = _go


def start_api(auth_dir, postgrest, secret, anon):
    env = {**os.environ, "GOTRUE_DB_DRIVER": "postgres", "DB_NAMESPACE": "auth",
           "DATABASE_URL": f"postgres://postgres@127.0.0.1:{PG['PGPORT']}/{DB}?sslmode=disable&search_path=auth",
           "API_EXTERNAL_URL": f"https://{REF}.supabase.co/auth/v1", "GOTRUE_JWT_ISSUER": f"https://{REF}.supabase.co/auth/v1",
           "GOTRUE_API_HOST": "127.0.0.1", "PORT": str(AUTH_PORT), "GOTRUE_SITE_URL": "http://127.0.0.1:4175",
           "GOTRUE_JWT_SECRET": secret, "GOTRUE_JWT_EXP": "3600", "GOTRUE_JWT_AUD": "authenticated",
           "GOTRUE_JWT_DEFAULT_GROUP_NAME": "authenticated", "GOTRUE_JWT_ADMIN_ROLES": "service_role",
           "GOTRUE_DISABLE_SIGNUP": "true", "GOTRUE_EXTERNAL_EMAIL_ENABLED": "true", "GOTRUE_MAILER_AUTOCONFIRM": "true",
           "GOTRUE_RATE_LIMIT_TOKEN_REFRESH": "10000", "GOTRUE_LOG_LEVEL": "warn"}
    procs.append(subprocess.Popen(["./auth", "serve"], cwd=auth_dir, env=env, stdout=open(OUT / "auth.log", "w"), stderr=subprocess.STDOUT))
    conf = OUT / "postgrest.conf"   # holds the local rehearsal secret: outside the repository, deleted at the end
    conf.write_text(f'db-uri = "postgres://authenticator@/{DB}?host={PG["PGHOST"]}&port={PG["PGPORT"]}"\ndb-schemas = "public"\n'
                    f'db-anon-role = "anon"\njwt-secret = "{secret}"\nserver-port = {REST_PORT}\nserver-host = "127.0.0.1"\n')
    procs.append(subprocess.Popen([postgrest, str(conf)], stdout=open(OUT / "postgrest.log", "w"), stderr=subprocess.STDOUT))
    Gateway.anon = anon
    srv = socketserver.ThreadingTCPServer(("127.0.0.1", GW_PORT), Gateway)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    for _ in range(40):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{AUTH_PORT}/health", timeout=1)
            urllib.request.urlopen(f"http://127.0.0.1:{REST_PORT}/", timeout=1)
            return srv
        except Exception:  # noqa: BLE001
            time.sleep(0.5)
    raise SystemExit("Auth or PostgREST did not start (see auth.log / postgrest.log in " + str(OUT) + ")")


SNAP = """
select 'rel ' || c.relkind::text || ' ' || c.relname, coalesce(array_to_string(c.relacl, ','), '') || ' rls=' || c.relrowsecurity
  from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v', 'S')
union all select 'col ' || c.relname || '.' || a.attname, format_type(a.atttypid, a.atttypmod) || ' nn=' || a.attnotnull || ' def=' ||
       coalesce(pg_get_expr(d.adbin, d.adrelid), '') || ' acl=' || coalesce(array_to_string(a.attacl, ','), '')
  from pg_attribute a join pg_class c on c.oid = a.attrelid left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
 where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v') and a.attnum > 0 and not a.attisdropped
union all select 'con ' || conrelid::regclass || '.' || conname, pg_get_constraintdef(oid) from pg_constraint where connamespace = 'public'::regnamespace
union all select 'idx ' || i.indexrelid::regclass, pg_get_indexdef(i.indexrelid) from pg_index i join pg_class c on c.oid = i.indrelid where c.relnamespace = 'public'::regnamespace
union all select 'trg ' || tgrelid::regclass || '.' || tgname, pg_get_triggerdef(oid) || ' en=' || tgenabled::text from pg_trigger
 where not tgisinternal and tgrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace)
union all select 'pol ' || tablename || '.' || policyname, cmd || ' ' || coalesce(qual, '') || ' ' || coalesce(with_check, '') || ' ' || array_to_string(roles, ',')
  from pg_policies where schemaname = 'public'
union all select 'fn ' || p.oid::regprocedure, md5(p.prosrc) || ' acl=' || coalesce(array_to_string(p.proacl, ','), '') || ' sd=' || p.prosecdef || ' cfg=' ||
       coalesce(array_to_string(p.proconfig, ','), '') from pg_proc p where p.pronamespace = 'public'::regnamespace
union all select 'nsp public', coalesce(array_to_string(nspacl, ','), '') from pg_namespace where nspname = 'public'
union all select 'ext ' || extname, extversion from pg_extension
order by 1"""


def snapshot(db):
    return psql(db, f"select string_agg(a || ' :: ' || b, E'\\n') from ({SNAP}) s(a, b)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", required=True)
    ap.add_argument("--auth-dir", default="/home/claude/tools/gotrue")
    ap.add_argument("--postgrest", default=shutil.which("postgrest") or "/home/claude/tools/pgrst/postgrest")
    ap.add_argument("--report", default=str(OUT / "rehearsal-report.txt"))
    a = ap.parse_args()
    REPORTS.mkdir(parents=True, exist_ok=True)
    pw = "Rehearsal-DB-Password-" + secrets.token_urlsafe(18)
    jwt_secret = "rehearsal-jwt-secret-" + secrets.token_urlsafe(24)
    anon = jwt({"role": "anon", "ref": REF, "iss": "supabase"}, jwt_secret)
    service = jwt({"role": "service_role", "ref": REF, "iss": "supabase"}, jwt_secret)
    secrets_used.extend([pw, jwt_secret, anon, service])
    log(f"AttendOS development-Supabase preflight — LOCAL REHEARSAL · commit {a.commit[:12]} · fake project ref {REF} · {time.strftime('%Y-%m-%d %H:%M:%S')}")
    log(f"working folder (outside the repository): {OUT}")
    try:
        # ------------------------------------------------------------ build the Supabase-like database
        build_db(DB, a.auth_dir)
        env = tool_env(DB, pw)
        log("built: Supabase-like database with API roles, worst-case CREATE/default grants, 8 s signed-in timeout, real Auth schema")

        # ------------------------------------------------------------ G3 marker, prerequisites, D5
        r = tool(["dev_sql.py", "check_biometric_prereqs.sql"], env)
        check(r.returncode != 0 and "no AttendOS development marker" in r.stdout,
              "guard: before the marker exists, even a read-only script is refused (not the development project)")
        r = tool(["dev_sql.py", "--mark"], env)
        check(r.returncode == 0 and REF in r.stdout, "G3 dev_sql.py --mark writes the development marker for exactly the given reference")
        r = tool(["dev_sql.py", "--mark"], tool_env(DB, pw, {"ATTENDOS_DEV_PROJECT_REF": "differentprojectrefa", "ATTENDOS_DEV_DB_URL":
                  f"postgresql://postgres.differentprojectrefa:{pw}@/{DB}?host={PG['PGHOST']}&port={PG['PGPORT']}"}))
        check(r.returncode != 0, "the marker cannot be rewritten for another reference")
        r = tool(["dev_sql.py", "check_biometric_prereqs.sql"], env)
        bad = not_ok_rows(r.stdout)
        flagged = {int(m.group(1)) for l in bad for m in [re.match(r"\s*(\d+)\s*\|", l)] if m}
        check(r.returncode == 0 and {13, 14} <= flagged and not (flagged - {6, 7, 13, 14}),
              f"G3 prerequisites: only CREATE-on-public (13, 14) and the not-yet-needed pg_cron rows (6, 7) are flagged (flagged: {sorted(flagged)})")
        r = tool(["dev_sql.py", "dev_revoke_public_create.sql"], env)
        check(r.returncode == 0 and psql(DB, "select has_schema_privilege('anon','public','CREATE') or has_schema_privilege('authenticated','public','CREATE')") == "f",
              "G3 D5: dev_revoke_public_create.sql revokes CREATE on public from anon and authenticated (verified afterwards)")
        r = tool(["dev_sql.py", "check_biometric_prereqs.sql"], env)
        flagged = {int(m.group(1)) for l in not_ok_rows(r.stdout) for m in [re.match(r"\s*(\d+)\s*\|", l)] if m}
        check(r.returncode == 0 and not (flagged - {6, 7}), f"G3 prerequisites after D5: nothing flagged except the later pg_cron rows ({sorted(flagged)})")

        # ------------------------------------------------------------ G4 migrations + verify
        r = tool(["dev_apply_migrations.py", "--commit", "0000000"], env)
        check(r.returncode != 0 and "not the approved commit" in r.stdout, "G4 dev_apply_migrations.py refuses a commit other than this checkout")
        r = tool(["dev_apply_migrations.py", "--commit", a.commit], env)
        check(r.returncode == 0 and r.stdout.count("   ok (") == 13, "G4 0001–0013 applied, each in one transaction with the guard and the manifest check")
        r = tool(["dev_sql.py", str(REPO / "supabase/deploy/verify_hosted.sql")], env)
        check(r.returncode == 0 and not not_ok_rows(r.stdout) and r.stdout.count("| t") >= 21, "G4 verify_hosted.sql: all 21 items ok after 0013 (incl. new items 15–21)")
        r = tool(["dev_apply_migrations.py", "--commit", a.commit], env)
        check(r.returncode == 0 and r.stdout.count("skip ") == 13, "G4 re-running the apply tool changes nothing (all 13 recorded, identical)")

        # ------------------------------------------------------------ G5 seed, logins, API checks
        r = tool(["dev_sql.py", "dev_seed_synthetic.sql"], env)
        check(r.returncode == 0 and psql(DB, "select count(*) from companies where slug in ('dev-alpha', 'dev-beta')") == "2"
              and psql(DB, "select count(*) from employees") == "10" and psql(DB, "select count(*) from biometric_devices") == "4",
              "G5 dev_seed_synthetic.sql: two synthetic companies, 10 employees, 4 devices")
        check(psql(DB, "select count(*) from biometric_employee_mappings") == "0", "G5 no employee mapping exists")
        r = tool(["dev_sql.py", "dev_seed_synthetic.sql"], env)
        check(r.returncode != 0 and "already exist" in r.stdout, "G5 the seed refuses to run twice")
        srv = start_api(a.auth_dir, a.postgrest, jwt_secret, anon)
        logins = {}
        for who, email in [("A admin", "a.admin"), ("A admin2", "a.admin2"), ("A hr", "a.hr"), ("A manager", "a.manager"), ("A employee", "a.employee"),
                           ("B admin", "b.admin"), ("B hr", "b.hr"), ("B employee", "b.employee")]:
            pwd = "Login-" + secrets.token_urlsafe(16)
            secrets_used.append(pwd)
            logins[who] = {"email": f"{email}@attendos-dev.example", "password": pwd}
            req = urllib.request.Request(f"http://127.0.0.1:{AUTH_PORT}/admin/users", method="POST",
                                         data=json.dumps({"email": logins[who]["email"], "password": pwd, "email_confirm": True}).encode(),
                                         headers={"Authorization": "Bearer " + service, "Content-Type": "application/json"})
            urllib.request.urlopen(req, timeout=10).read()
        lf = OUT / "logins.json"
        lf.write_text(json.dumps(logins))
        os.chmod(lf, 0o600)
        check(psql(DB, "select count(*) from employees where email like '%@attendos-dev.example' and user_id is not null") == "8",
              "G5 the 8 synthetic logins (created like Dashboard → Add user, auto-confirmed) are linked to their records by 0005")
        api_env = tool_env(DB, pw, {"ATTENDOS_DEV_SUPABASE_URL": f"http://127.0.0.1:{GW_PORT}", "ATTENDOS_DEV_ANON_KEY": anon, "ATTENDOS_DEV_LOGINS_FILE": str(lf)})
        r = tool(["dat_hosted_matrix.py", "--scale"], api_env)
        for l in r.stdout.splitlines():
            if l.startswith(("PASS", "FAIL", "     API", "   DIFFERENT")):
                log("   | " + l)
        check(r.returncode == 0 and "ALL API CHECKS PASSED" in r.stdout, "G5 dat_hosted_matrix.py --scale: permission matrix (160), V4, V5 (16 MiB both ways), 32k/200k through the API")
        r = tool(["dat_hosted_matrix.py"], {**api_env, "ATTENDOS_DEV_ANON_KEY": service})
        check(r.returncode != 0 and "service-role" in r.stdout, "the API tool refuses to run with a service-role key")

        # ------------------------------------------------------------ G6 DB-level performance
        r = tool(["dat_hosted_scale.py"], env)
        for l in r.stdout.splitlines():
            if l.startswith(("PASS", "FAIL", "     S", "server", "STOP")):
                log("   | " + l)
        check(r.returncode == 0 and "ALL DB-LEVEL CHECKS PASSED" in r.stdout, "G6 dat_hosted_scale.py: S1–S7, C1–C3 and the V7 boundary snapshot")
        srv.shutdown()

        # ------------------------------------------------------------ rollback protection (must be proven before any use)
        snap_before = snapshot(DB)
        r = sh(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-d", DB, "-f", str(PRE / "rollback_0013_dev_only.sql")])
        check(r.returncode != 0 and snapshot(DB) == snap_before, "rollback guard 1: plain psql without dev_ref (as in an SQL editor) is refused; nothing changed")
        r = sh(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-d", DB, "-v", f"dev_ref={OTHER_REF}", "-v", "confirm=REMOVE-0013-FROM-DEVELOPMENT",
                "--single-transaction", "-f", str(PRE / "rollback_0013_dev_only.sql")])
        check(r.returncode != 0 and "marker is for project" in r.stderr and snapshot(DB) == snap_before,
              "rollback guard 2: the marked database with ANOTHER reference is refused; nothing changed")
        r = tool(["dev_sql.py", "rollback_0013_dev_only.sql", "-v", "confirm=yes"], env)
        check(r.returncode != 0 and "confirm must be exactly" in r.stdout and snapshot(DB) == snap_before,
              "rollback guard 3: the right project without the exact confirmation phrase is refused; nothing changed")
        demo_before = snapshot("attendos_demo") if psql("postgres", "select count(*) from pg_database where datname = 'attendos_demo'") == "1" else None
        if demo_before is not None:
            r = sh(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-d", "attendos_demo", "-v", f"dev_ref={REF}", "-v", "confirm=REMOVE-0013-FROM-DEVELOPMENT",
                    "--single-transaction", "-f", str(PRE / "dev_guard.sql"), "-f", str(PRE / "rollback_0013_dev_only.sql")])
            check(r.returncode != 0 and "no AttendOS development marker" in r.stderr and snapshot("attendos_demo") == demo_before,
                  "rollback guard 4: a database WITHOUT the marker (stand-in for a company/pilot/production database) is refused, even with the right reference and phrase; nothing changed")
        r = tool(["dev_sql.py", "rollback_0013_dev_only.sql", "-v", "confirm=REMOVE-0013-FROM-DEVELOPMENT"],
                 tool_env(DB, pw, {"ATTENDOS_DEV_DB_URL": f"postgresql://postgres.{OTHER_REF}:{pw}@/{DB}?host={PG['PGHOST']}&port={PG['PGPORT']}"}))
        check(r.returncode != 0 and "STOP" in r.stdout and snapshot(DB) == snap_before,
              "rollback guard 5: a connection string naming another project is refused before connecting")

        # ------------------------------------------------------------ rollback works: exactly the 0012 state
        build_db(REFDB, a.auth_dir)
        renv = tool_env(REFDB, pw)
        tool(["dev_sql.py", "--mark"], renv)
        tool(["dev_sql.py", "dev_revoke_public_create.sql"], renv)
        r = tool(["dev_apply_migrations.py", "--commit", a.commit, "--through", "0012"], renv)
        check(r.returncode == 0 and r.stdout.count("   ok (") == 12, "reference: a fresh database with 0001–0012 only (same roles and D5)")
        r = tool(["dev_sql.py", "rollback_0013_dev_only.sql", "-v", "confirm=REMOVE-0013-FROM-DEVELOPMENT"], env)
        check(r.returncode == 0 and "removed 0013" in r.stdout, "rollback: with the marker, the exact reference and the phrase, 0013 is removed in one transaction")
        a_snap, b_snap = snapshot(DB), snapshot(REFDB)
        diff = sorted(set(a_snap.splitlines()) ^ set(b_snap.splitlines()))
        for d in diff[:20]:
            log("   catalog difference: " + d[:220])
        check(not diff, f"rollback: the schema equals a fresh 0012 database exactly — tables, columns, constraints, indexes, triggers, policies, grants, "
                        f"function bodies and privileges ({len(a_snap.splitlines())} catalog entries compared, {len(diff)} differences)")
        r = tool(["dev_sql.py", str(REPO / "supabase/deploy/verify_hosted.sql")], env)
        for l in not_ok_rows(r.stdout):
            log("   not ok: " + l[:240])
        check(r.returncode == 0 and not not_ok_rows(r.stdout), "rollback: verify_hosted.sql is all ok for the 0012 state")
        r = tool(["dev_apply_migrations.py", "--commit", a.commit], env)
        check(r.returncode == 0 and r.stdout.count("   ok (") == 1 and r.stdout.count("skip ") == 12, "re-apply: the frozen 0013 (same SHA-256) applies again after the rollback")
        r = tool(["dev_sql.py", str(REPO / "supabase/deploy/verify_hosted.sql")], env)
        check(r.returncode == 0 and not not_ok_rows(r.stdout), "re-apply: verify_hosted.sql all ok again")

        # ------------------------------------------------------------ D6 freeze
        psql(DB, "update attendos_dev.applied_migrations set sha256 = repeat('0', 64) where file = '0013_biometric_dat_import.sql'")
        r = tool(["dev_apply_migrations.py", "--commit", a.commit], env)
        check(r.returncode != 0 and "frozen" in r.stdout, "D6: a migration recorded with a different SHA-256 is refused as frozen (changes must be a new migration)")
        mig = REPO / "supabase/migrations/0013_biometric_dat_import.sql"
        original = mig.read_bytes()
        try:
            mig.write_bytes(original + b"\n-- edited\n")
            r = tool(["dev_apply_migrations.py", "--commit", a.commit], env)
            check(r.returncode != 0 and "differ from the approved commit" in r.stdout, "D6: an edited migration file is refused before anything is sent")
        finally:
            mig.write_bytes(original)
    finally:
        for p in procs:
            p.terminate()
        for p in procs:
            try:
                p.wait(timeout=5)
            except Exception:  # noqa: BLE001
                p.kill()
        (OUT / "postgrest.conf").unlink(missing_ok=True)

    # ---------------------------------------------------------------- no secret in any output
    texts = [p.read_text(errors="replace") for p in REPORTS.glob("*.txt")] + ["\n".join(transcript)]
    leaked = [s for s in secrets_used if any(s in t for t in texts)]
    check(not leaked and len(list(REPORTS.glob("*.txt"))) >= 15,
          f"no database password, JWT secret, anon or service key, or test password appears in any of {len(list(REPORTS.glob('*.txt')))} tool reports or the tool output")
    (OUT / "logins.json").unlink(missing_ok=True)
    for d in (DB, REFDB):
        sh(["dropdb", "--if-exists", "--force", d])
    passed = sum(1 for ok, _ in results if ok)
    log(f"\n{passed}/{len(results)} rehearsal checks passed")
    Path(a.report).write_text("\n".join(l for l in transcript if not l.startswith("$ ")) + "\n")
    print(f"report: {a.report}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
