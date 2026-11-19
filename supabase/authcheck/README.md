# Sign-in check with the real Supabase Auth server

Runs the actual sign-in flows in a browser against **Supabase Auth** (the open-source `supabase/auth`
server that Supabase runs for every project), **PostgREST** and **PostgreSQL 16**, all on this machine.
E-mails are caught locally instead of being sent. Nothing touches the internet or a company database.

What it proves: sign-up only for work e-mails HR added (Auth hook), e-mail confirmation, linking to the
right employee, no duplicate links, resend, expired links, password reset, other devices signed out after a
reset, sign-out (browser and server), automatic session renewal, deactivation taking effect mid-session,
reactivation, and that audit entries carry the real signed-in user.

What it does not prove: Supabase's hosted settings (dashboard values, SMTP provider, rate limits, Kong
gateway in front of Auth/REST, custom domain). Those are checked on the real project — `docs/DEPLOYMENT.md`.

## Run
1. Local Postgres (`PGHOST`, `PGPORT`, `PGUSER`), `postgrest` on PATH, `pip install aiosmtpd playwright`.
2. Download the Auth server once (Linux x86-64):
   `curl -L -o auth.tgz https://github.com/supabase/auth/releases/download/v2.198.0/auth-v2.198.0-x86.tar.gz && tar xzf auth.tgz`
   into a folder of your choice → `AUTH_DIR`.
3. Build the app with `NEXT_PUBLIC_SUPABASE_URL=https://demo-attendos.supabase.co` and an anon key signed with the
   secret in `postgrest.conf` (role `anon`), serve `out/` on `127.0.0.1:4175` with clean URLs.
4. `JWT_EXP=60 AUTH_DIR=… sh start.sh` then `JWT_EXP=60 python3 flows.py http://127.0.0.1:4175 shots`.
   `JWT_EXP=60` makes access tokens expire after a minute so renewal and sign-out of other devices are tested.
5. Invitation edge cases (no browser; run `start.sh` again first, it resets the database):
   `python3 invite_edges.py` — expired link, re-invite, changed work e-mail, duplicate, already linked,
   confirmed-while-switched-off, other company. 26 checks.
