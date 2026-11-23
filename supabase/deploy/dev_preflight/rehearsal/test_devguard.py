"""Unit checks for devguard.py — no network, no database. Every refusal must happen before anything is sent.
Run: python3 supabase/deploy/dev_preflight/rehearsal/test_devguard.py
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import devguard as g  # noqa: E402

REF = "abcdefghijklmnopqrst"
OTHER = "zyxwvutsrqponmlkjihg"
results = []


def check(ok, what):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + what)


def jwt(payload):
    b = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()  # noqa: E731
    head, body = b({"alg": "HS256", "typ": "JWT"}), b(payload)
    sig = base64.urlsafe_b64encode(hmac.new(b"test-only", f"{head}.{body}".encode(), hashlib.sha256).digest()).rstrip(b"=").decode()
    return f"{head}.{body}.{sig}"


def env(**kw):
    for k in [k for k in os.environ if k.startswith("ATTENDOS_")]:
        del os.environ[k]
    os.environ.update({k: v for k, v in kw.items() if v is not None})


def refused(fn, needle=""):
    try:
        fn()
        return False
    except g.Stop as e:
        return needle.lower() in str(e).lower()


PW = "S3cr3t-Pa55word-For-Redaction-Test"
POOLER = f"postgresql://postgres.{REF}:{PW}@aws-0-ap-south-1.pooler.supabase.com:5432/postgres"
DIRECT = f"postgresql://postgres:{PW}@db.{REF}.supabase.co:5432/postgres"

# ---------------------------------------------------------------- project reference
env(ATTENDOS_DEV_PROJECT_REF="dev-project", ATTENDOS_DEV_DB_URL=POOLER)
check(refused(g.db_env, "reference"), "a malformed project reference is refused")
env(ATTENDOS_DEV_DB_URL=POOLER)
check(refused(g.db_env, "reference"), "no project reference set: refused")
env(ATTENDOS_DEV_PROJECT_REF=REF, ATTENDOS_FORBIDDEN_PROJECT_REFS=f"{OTHER}, {REF}", ATTENDOS_DEV_DB_URL=POOLER)
check(refused(g.db_env, "forbidden"), "a reference on the forbidden (pilot/production) list is refused")

# ---------------------------------------------------------------- database connection must name exactly the reference
env(ATTENDOS_DEV_PROJECT_REF=REF, ATTENDOS_DEV_DB_URL=POOLER)
ref, e = g.db_env()
check(ref == REF and e["PGUSER"] == f"postgres.{REF}" and e["PGPASSWORD"] == PW and e["PGSSLMODE"] == "require" and "ATTENDOS_DEV_DB_URL" not in e,
      "pooler connection for exactly the dev reference: accepted; password moved to PGPASSWORD; TLS required; the URL itself is not passed on")
env(ATTENDOS_DEV_PROJECT_REF=REF, ATTENDOS_DEV_DB_URL=DIRECT)
check(g.db_env()[0] == REF, "direct connection db.<ref>.supabase.co with user postgres: accepted")
env(ATTENDOS_DEV_PROJECT_REF=REF, ATTENDOS_DEV_DB_URL=POOLER.replace(f"postgres.{REF}", f"postgres.{OTHER}"))
check(refused(g.db_env, "does not name"), "pooler user of ANOTHER project: refused")
env(ATTENDOS_DEV_PROJECT_REF=REF, ATTENDOS_DEV_DB_URL=DIRECT.replace(f"db.{REF}", f"db.{OTHER}"))
check(refused(g.db_env, "does not name"), "direct host of ANOTHER project: refused")
env(ATTENDOS_DEV_PROJECT_REF=REF, ATTENDOS_DEV_DB_URL=f"postgresql://postgres:{PW}@db.example.com:5432/postgres")
check(refused(g.db_env, "does not name"), "a non-Supabase host: refused")
env(ATTENDOS_DEV_PROJECT_REF=REF, ATTENDOS_FORBIDDEN_PROJECT_REFS=OTHER,
    ATTENDOS_DEV_DB_URL=f"postgresql://postgres.{REF}:{PW}@aws-0-ap-south-1.pooler.supabase.com:5432/postgres?options={OTHER}")
check(refused(g.db_env, "forbidden"), "a connection string that mentions a forbidden reference anywhere: refused")
env(ATTENDOS_DEV_PROJECT_REF=REF, ATTENDOS_DEV_DB_URL=f"postgresql://postgres.{REF}@/x?host=/tmp/pg&port=5433")
check(refused(g.db_env, "does not name"), "outside rehearsal mode a local socket is refused")
env(ATTENDOS_DEV_PROJECT_REF=REF, ATTENDOS_DEV_LOCAL_REHEARSAL="1", ATTENDOS_DEV_DB_URL=POOLER)
check(refused(g.db_env, "local"), "rehearsal mode can never connect to a hosted database")
env(ATTENDOS_DEV_PROJECT_REF=REF, ATTENDOS_DEV_LOCAL_REHEARSAL="1", ATTENDOS_DEV_DB_URL="postgresql://postgres@/x?host=/tmp/pg&port=5433")
check(refused(g.db_env, "postgres.<ref>"), "rehearsal mode still requires the user postgres.<ref>")
env(ATTENDOS_DEV_PROJECT_REF=REF, ATTENDOS_DEV_DB_URL="mysql://x@y/z")
check(refused(g.db_env, "postgresql://"), "a non-PostgreSQL URL is refused")

# ---------------------------------------------------------------- API: URL, key, logins file, token issuer
tmp = Path(tempfile.mkdtemp())
lf = tmp / "logins.json"
lf.write_text(json.dumps({"A admin": {"email": "a.admin@attendos-dev.example", "password": "Test-Login-Password-123456"}}))
anon = jwt({"role": "anon", "ref": REF, "iss": "supabase"})
base = dict(ATTENDOS_DEV_PROJECT_REF=REF, ATTENDOS_DEV_SUPABASE_URL=f"https://{REF}.supabase.co", ATTENDOS_DEV_ANON_KEY=anon, ATTENDOS_DEV_LOGINS_FILE=str(lf))
env(**base)
r = g.api_params()
check(r[0] == REF and r[1] == f"https://{REF}.supabase.co", "API: exact dev URL, anon key of this project, logins outside the repo: accepted")
env(**{**base, "ATTENDOS_DEV_SUPABASE_URL": f"https://{OTHER}.supabase.co"})
check(refused(g.api_params, "exactly"), "API URL of another project: refused")
env(**{**base, "ATTENDOS_DEV_SUPABASE_URL": f"https://{REF}.supabase.co.evil.example"})
check(refused(g.api_params, "exactly"), "a look-alike API URL: refused")
env(**{**base, "ATTENDOS_DEV_ANON_KEY": jwt({"role": "service_role", "ref": REF})})
check(refused(g.api_params, "service-role"), "a service-role JWT is refused")
env(**{**base, "ATTENDOS_DEV_ANON_KEY": "sb_secret_abcdefghijklmnop"})
check(refused(g.api_params, "service-role"), "a secret (sb_secret_) key is refused")
env(**{**base, "ATTENDOS_DEV_ANON_KEY": jwt({"role": "anon", "ref": OTHER})})
check(refused(g.api_params, "another project"), "an anon key of another project is refused")
env(**{**base, "ATTENDOS_DEV_LOGINS_FILE": str(g.REPO / "logins.json")})
check(refused(g.api_params, "outside the Git repository"), "a logins file inside the repository is refused")
env(**{**base, "ATTENDOS_DEV_REPORT_DIR": str(g.REPO / "reports")})
check(refused(g.report_dir, "outside the Git repository"), "a report folder inside the repository is refused")
check(refused(lambda: g.check_token(REF, jwt({"iss": f"https://{OTHER}.supabase.co/auth/v1", "role": "authenticated"})), "iss"),
      "a sign-in token issued by another project's Auth is refused")
check(not refused(lambda: g.check_token(REF, jwt({"iss": f"https://{REF}.supabase.co/auth/v1", "role": "authenticated"}))),
      "a token issued by the dev project's Auth is accepted")

# ---------------------------------------------------------------- redaction
env(ATTENDOS_DEV_PROJECT_REF=REF, ATTENDOS_DEV_DB_URL=POOLER)
g.db_env()
txt = g.redact(f"connect {POOLER} pw={PW} key={anon} tok={jwt({'a': 1})} sb_secret_abcdefgh123")
check(PW not in txt and anon not in txt and "sb_secret_abcdefgh123" not in txt and "eyJ" not in txt,
      "redaction: password, connection string, anon key, tokens and secret keys never appear in output")

print(f"\n{sum(results)}/{len(results)} guard checks passed")
sys.exit(0 if all(results) else 1)
