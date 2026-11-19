# Builds the local review/demo database and serves it with PostgREST (Supabase-style REST).
# Needs a local Postgres (PGHOST/PGPORT/PGUSER) and the postgrest binary. Never point this at a real company database.
python3 seed.py
export PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres
pkill -f "postgrest postgrest.conf"; sleep 1
dropdb --if-exists attendos_demo && createdb attendos_demo && psql -q -v ON_ERROR_STOP=1 -d attendos_demo -f auth_stub.sql -f ../migrations/0001_attendance_core.sql -f ../migrations/0002_refinement.sql -f ../migrations/0003_multi_tenant.sql -f ../migrations/0004_employees.sql -f ../migrations/0005_verification.sql -f seed.sql -f corrections.sql 2>&1 | grep -E "ERROR|CONTEXT"
(nohup postgrest postgrest.conf > pgrst.log 2>&1 &); sleep 2
