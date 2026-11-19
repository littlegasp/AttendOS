#!/bin/sh
# Local sign-in check with the REAL Supabase Auth server (supabase/auth release binary), a real PostgREST
# and PostgreSQL, and a mail catcher. Nothing here talks to the internet or to a company database.
# Needs: PGHOST/PGPORT/PGUSER for a local Postgres, the `auth` binary in $AUTH_DIR (with its migrations/),
# postgrest on PATH, python3 with aiosmtpd. See README.md.
set -e
cd "$(dirname "$0")"
: "${AUTH_DIR:?set AUTH_DIR to the folder holding the auth binary}"
SECRET="local-auth-check-secret-local-auth-check-32"
pkill -f "auth serve" 2>/dev/null || true; pkill -f "postgrest postgrest.conf" 2>/dev/null || true; pkill -f "mailsink.py" 2>/dev/null || true
sleep 1
rm -rf mail
dropdb --if-exists attendos_auth && createdb attendos_auth
psql -q -d attendos_auth -c "create schema auth" -c "do \$\$ begin create role anon nologin; exception when duplicate_object then null; end \$\$" \
  -c "do \$\$ begin create role authenticated nologin; exception when duplicate_object then null; end \$\$" \
  -c "do \$\$ begin create role authenticator login noinherit; exception when duplicate_object then null; end \$\$" \
  -c "grant anon, authenticated to authenticator" -c "grant usage on schema auth, public to anon, authenticated"
export GOTRUE_DB_DRIVER=postgres DB_NAMESPACE=auth
export DATABASE_URL="postgres://postgres@127.0.0.1:${PGPORT:-5432}/attendos_auth?sslmode=disable&search_path=auth"
export GOTRUE_DB_MIGRATIONS_PATH="$AUTH_DIR/migrations"
export API_EXTERNAL_URL="https://demo-attendos.supabase.co/auth/v1"
export GOTRUE_API_HOST=127.0.0.1 PORT=9999
export GOTRUE_SITE_URL="http://127.0.0.1:4175" GOTRUE_URI_ALLOW_LIST="http://127.0.0.1:4175/**"
export GOTRUE_JWT_SECRET="$SECRET" GOTRUE_JWT_EXP="${JWT_EXP:-3600}" GOTRUE_JWT_AUD=authenticated GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated GOTRUE_JWT_ADMIN_ROLES=service_role
export GOTRUE_DISABLE_SIGNUP=false GOTRUE_EXTERNAL_EMAIL_ENABLED=true GOTRUE_MAILER_AUTOCONFIRM=false GOTRUE_MAILER_SECURE_EMAIL_CHANGE_ENABLED=true
export GOTRUE_SMTP_HOST=127.0.0.1 GOTRUE_SMTP_PORT=2525 GOTRUE_SMTP_USER=x GOTRUE_SMTP_PASS=x GOTRUE_SMTP_ADMIN_EMAIL=noreply@attendos.test GOTRUE_SMTP_SENDER_NAME=AttendOS GOTRUE_SMTP_MAX_FREQUENCY=1s
export GOTRUE_RATE_LIMIT_EMAIL_SENT=1000 GOTRUE_PASSWORD_MIN_LENGTH=8
export GOTRUE_MAILER_URLPATHS_CONFIRMATION=/verify GOTRUE_MAILER_URLPATHS_RECOVERY=/verify GOTRUE_MAILER_URLPATHS_INVITE=/verify GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE=/verify
export GOTRUE_HOOK_BEFORE_USER_CREATED_ENABLED=true GOTRUE_HOOK_BEFORE_USER_CREATED_URI="pg-functions://postgres/public/hook_before_user_created"
export GOTRUE_LOG_LEVEL=info
( cd "$AUTH_DIR" && ./auth migrate ) > auth-migrate.log 2>&1
for f in ../migrations/0001_attendance_core.sql ../migrations/0002_refinement.sql ../migrations/0003_multi_tenant.sql \
         ../migrations/0004_employees.sql ../migrations/0005_verification.sql ../migrations/0006_leave_register_reports.sql ../migrations/0007_invitations.sql ../migrations/0008_hardening.sql ../migrations/0009_link_on_reactivation.sql setup.sql; do
  psql -q -v ON_ERROR_STOP=1 -d attendos_auth -f "$f" > /dev/null
done
psql -q -d attendos_auth -c "grant execute on function auth.uid(), auth.role() to anon, authenticated"
(nohup python3 mailsink.py 2525 > mailsink.log 2>&1 &)
(cd "$AUTH_DIR" && nohup ./auth serve > "$OLDPWD/auth.log" 2>&1 &)
(nohup postgrest postgrest.conf > postgrest.log 2>&1 &)
sleep 3
curl -sf http://127.0.0.1:9999/health > /dev/null && echo "Auth up" || { echo "Auth failed"; tail -20 auth.log; exit 1; }
curl -sf http://127.0.0.1:3002/ > /dev/null && echo "PostgREST up" || { echo "PostgREST failed"; tail postgrest.log; exit 1; }
