"""AttendOS development-Supabase preflight — shared guard for every owner-run tool in this folder.

Every hosted operation goes through here first. It refuses to do anything unless ALL of these hold:
  * ATTENDOS_DEV_PROJECT_REF is a Supabase project reference (20 lowercase letters) and is not in
    ATTENDOS_FORBIDDEN_PROJECT_REFS (list the pilot/production references there once they exist);
  * the database connection string names exactly that reference — direct host db.<ref>.supabase.co with user
    postgres, or the Supavisor pooler host *.pooler.supabase.com with user postgres.<ref> — and no other reference;
  * the API URL is exactly https://<ref>.supabase.co, the anon key (when it is a JWT) carries "ref": "<ref>" and
    role anon, and every access token issued by Auth has iss https://<ref>.supabase.co/auth/v1;
  * no service-role key is ever given to these tools;
  * the logins file and the report folder are outside the Git repository.
The database side is guarded again by dev_guard.sql: the database must carry the AttendOS development marker
(attendos_dev.environment_marker) for exactly this reference, written once by dev_mark_project.sql.

Secrets (database password, keys, test passwords, tokens) are read from the owner's local environment / a local
file only, never printed: every line of output and every report passes through redact().

Local rehearsal (ATTENDOS_DEV_LOCAL_REHEARSAL=1) is only for testing these tools on this machine: the database host
must be a local socket or localhost (with user postgres.<ref>) and the API URL http://127.0.0.1:<port>. All other
checks, including the in-database marker, still apply. It can never reach a hosted project.
"""
import base64
import json
import os
import re
import subprocess
import sys
import urllib.parse
from pathlib import Path

REF_RE = re.compile(r"^[a-z]{20}$")
REPO = Path(__file__).resolve().parents[3]
_SECRETS: set[str] = set()


class Stop(SystemExit):
    """A guard refused: nothing was sent to any database or API."""

    def __init__(self, msg):
        super().__init__(f"STOP: {msg}")


def secret(value):
    if value and len(value) >= 4:
        _SECRETS.add(value)
    return value


def redact(text):
    s = str(text)
    for v in sorted(_SECRETS, key=len, reverse=True):
        s = s.replace(v, "<redacted>")
    s = re.sub(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}", "<redacted-jwt>", s)
    s = re.sub(r"sb_(secret|publishable)_[A-Za-z0-9_-]+", "<redacted-key>", s)
    s = re.sub(r"(postgres(?:ql)?://[^:/@\s]+:)[^@\s]+@", r"\1<redacted>@", s)
    return s


def local_rehearsal():
    return os.environ.get("ATTENDOS_DEV_LOCAL_REHEARSAL") == "1"


def project_ref():
    ref = os.environ.get("ATTENDOS_DEV_PROJECT_REF", "")
    if not REF_RE.match(ref):
        raise Stop("ATTENDOS_DEV_PROJECT_REF must be the development project's reference ID (20 lowercase letters, "
                   "Dashboard → Project Settings → General → Reference ID)")
    forbidden = {r.strip() for r in os.environ.get("ATTENDOS_FORBIDDEN_PROJECT_REFS", "").split(",") if r.strip()}
    if ref in forbidden:
        raise Stop("ATTENDOS_DEV_PROJECT_REF is on the forbidden list (a pilot or production project)")
    return ref, forbidden


def outside_repo(path, what):
    p = Path(path).expanduser().resolve()
    if p == REPO or REPO in p.parents:
        raise Stop(f"{what} must be outside the Git repository ({REPO}) so it can never be committed")
    return p


def db_env():
    """PG* variables for psql/psycopg from ATTENDOS_DEV_DB_URL, after checking it names exactly the dev reference."""
    ref, forbidden = project_ref()
    url = os.environ.get("ATTENDOS_DEV_DB_URL", "")
    if not url:
        raise Stop("ATTENDOS_DEV_DB_URL is not set (the development project's session-pooler or direct connection string)")
    secret(url)
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("postgres", "postgresql"):
        raise Stop("ATTENDOS_DEV_DB_URL must be a postgresql:// connection string")
    user = urllib.parse.unquote(u.username or "")
    password = urllib.parse.unquote(u.password or "")
    secret(password)
    q = urllib.parse.parse_qs(u.query)
    host = u.hostname or (q.get("host", [""])[0])
    port = str(u.port or q.get("port", ["5432"])[0])
    dbname = (u.path or "/postgres").lstrip("/") or "postgres"
    for f in forbidden:
        if f in url:
            raise Stop("the connection string contains a forbidden (pilot/production) project reference")
    other_refs = set(re.findall(r"(?<![a-z])[a-z]{20}(?![a-z])", f"{user} {host}")) - {ref}
    other_refs = {r for r in other_refs if r not in ("supabase",)}
    if local_rehearsal():
        if not (host.startswith("/") or host in ("localhost", "127.0.0.1")):
            raise Stop("local rehearsal mode only connects to a local database")
        if user != f"postgres.{ref}":
            raise Stop("local rehearsal: the user must be postgres.<ref>, exactly like the Supabase pooler")
    else:
        direct = host == f"db.{ref}.supabase.co" and user == "postgres"
        pooler = host.endswith(".pooler.supabase.com") and user == f"postgres.{ref}"
        if not (direct or pooler):
            raise Stop("the connection string does not name the development project reference exactly "
                       "(expected host db.<ref>.supabase.co with user postgres, or a *.pooler.supabase.com host with user postgres.<ref>)")
        if other_refs:
            raise Stop("the connection string names another project reference")
    env = dict(os.environ)
    for k in ("ATTENDOS_DEV_DB_URL", "PGSERVICE", "PGPASSFILE"):
        env.pop(k, None)
    env.update(PGHOST=host, PGPORT=port, PGUSER=user, PGDATABASE=dbname, PGAPPNAME="attendos-dev-preflight")
    if password:
        env["PGPASSWORD"] = password
    if not local_rehearsal():
        env["PGSSLMODE"] = "require"
    return ref, env


def _jwt_payload(tok):
    try:
        p = tok.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
    except Exception:  # noqa: BLE001
        return None


def api_params():
    ref, _ = project_ref()
    url = os.environ.get("ATTENDOS_DEV_SUPABASE_URL", "").rstrip("/")
    key = secret(os.environ.get("ATTENDOS_DEV_ANON_KEY", ""))
    if local_rehearsal():
        if not re.match(r"^http://127\.0\.0\.1:\d+$", url):
            raise Stop("local rehearsal: the API URL must be http://127.0.0.1:<port>")
    elif url != f"https://{ref}.supabase.co":
        raise Stop("ATTENDOS_DEV_SUPABASE_URL must be exactly https://<dev project ref>.supabase.co")
    if not key:
        raise Stop("ATTENDOS_DEV_ANON_KEY is not set (the dev project's anon / publishable key — never the service-role key)")
    if key.startswith("sb_secret_"):
        raise Stop("a secret (service-role) key was given; these tools only use the anon / publishable key")
    pl = _jwt_payload(key) if key.startswith("eyJ") else None
    if key.startswith("eyJ"):
        if not pl or pl.get("role") != "anon":
            raise Stop("the API key is not an anon key (a service-role key must never be used here)")
        if pl.get("ref") != ref:
            raise Stop("the anon key belongs to another project (its ref claim differs)")
    elif not key.startswith("sb_publishable_"):
        raise Stop("the API key is neither an anon JWT nor a publishable key")
    logins_path = os.environ.get("ATTENDOS_DEV_LOGINS_FILE", "")
    if not logins_path:
        raise Stop("ATTENDOS_DEV_LOGINS_FILE is not set (local JSON file with the synthetic test logins)")
    lp = outside_repo(logins_path, "the logins file")
    logins = json.loads(lp.read_text())
    for who, v in logins.items():
        secret(v.get("password", ""))
    return ref, url, key, logins


def check_token(ref, tok):
    secret(tok)
    pl = _jwt_payload(tok) or {}
    if pl.get("iss") != f"https://{ref}.supabase.co/auth/v1":
        raise Stop("an access token was not issued by the development project's Auth (iss differs)")
    if pl.get("role") == "service_role":
        raise Stop("a service-role token was received; refusing")
    return pl


def report_dir():
    d = outside_repo(os.environ.get("ATTENDOS_DEV_REPORT_DIR", "~/attendos-dev-reports"), "the report folder")
    d.mkdir(parents=True, exist_ok=True)
    return d


class Log:
    """Prints and records lines, always redacted."""

    def __init__(self, name):
        self.path = report_dir() / name
        self.f = open(self.path, "w")

    def __call__(self, *parts):
        line = redact(" ".join(str(p) for p in parts))
        print(line, flush=True)
        self.f.write(line + "\n")
        self.f.flush()


def psql(env, args, log=None):
    """psql with the guarded environment; password via PGPASSWORD (never on the command line); output redacted."""
    r = subprocess.run(["psql", "-X", "-v", "ON_ERROR_STOP=1", *args], env=env, capture_output=True, text=True)
    out = redact(r.stdout) + (redact(r.stderr) if r.stderr else "")
    if log:
        for line in out.rstrip("\n").split("\n"):
            log(line)
    return r.returncode, out


def here(*p):
    return str(Path(__file__).resolve().parent.joinpath(*p))


if __name__ == "__main__":
    try:
        ref, env = db_env()
        print(f"database guard ok for project {ref} (host {env['PGHOST']}, user {env['PGUSER']})")
    except Stop as e:
        print(e)
        sys.exit(2)
