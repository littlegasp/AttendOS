#!/bin/sh
# 0012 preflight (design test P1): on a clean database at 0011 holding an attendance row with an unexpected source,
# migration 0012 applied as one transaction must stop before changing anything, name the value and its row count,
# and leave the row intact. After the row is corrected by the owner, the same migration applies.
# Usage: PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres sh supabase/tests/preflight_test.sh
cd "$(dirname "$0")"
DB=preflight_test
check() { if [ "$1" = "$2" ]; then echo "ok - $3"; else echo "FAILED: $3 (got '$1', expected '$2')"; exit 1; fi; }
dropdb --if-exists $DB 2>/dev/null; createdb $DB || exit 1
for f in auth_stub.sql ../migrations/0001_attendance_core.sql ../migrations/0002_refinement.sql ../migrations/0003_multi_tenant.sql \
         ../migrations/0004_employees.sql ../migrations/0005_verification.sql ../migrations/0006_leave_register_reports.sql \
         ../migrations/0007_invitations.sql ../migrations/0008_hardening.sql ../migrations/0009_link_on_reactivation.sql \
         supabase_defaults_stub.sql ../migrations/0010_biometric_core.sql ../migrations/0011_biometric_gateway.sql; do
  case $f in supabase_defaults_stub.sql) sed '/pg_temp.expect/,$d' $f > /tmp/stub_noexpect.sql; f=/tmp/stub_noexpect.sql;; esac
  psql -X -q -v ON_ERROR_STOP=1 -d $DB -f $f > /dev/null 2>&1 || { echo "FAILED: building 0001–0011 ($f)"; exit 1; }
done
psql -X -q -v ON_ERROR_STOP=1 -d $DB > /dev/null <<'SQL'
select create_company('Pre Co', 'pre', 'Asia/Kolkata', 'admin@pre.co', 'Pre Admin');
insert into attendance_events (employee_id, kind, at, work_mode, verified, work_date, source)
  select id, 'in', now() - interval '1 day', 'office', false, current_date - 1, 'web' from employees where email = 'admin@pre.co';
insert into attendance_events (employee_id, kind, at, work_mode, verified, work_date, source)
  select id, 'in', now() - interval '2 day', 'office', false, current_date - 2, 'kiosk' from employees where email = 'admin@pre.co';
SQL
BEFORE=$(psql -X -At -d $DB -c "select md5(string_agg(to_jsonb(e)::text, '|' order by id)) || '/' || (select count(*) from pg_attribute where attrelid = 'attendance_events'::regclass and attnum > 0 and not attisdropped) || '/' || (select count(*) from pg_proc where proname like 'biometric_project%') from attendance_events e")
OUT=$(psql -X -q -v ON_ERROR_STOP=1 --single-transaction -d $DB -f ../migrations/0012_biometric_projection.sql 2>&1); RC=$?
echo "   psql exit status: $RC"
echo "$OUT" | grep -E "ERROR|HINT" | sed 's/^/   /'
check "$RC" 3 "0012 refuses to run (psql stops with an error)"
echo "$OUT" | grep -q "Migration 0012 stopped before any change: unexpected attendance_events.source values: 'kiosk' (1 rows)" \
  && echo "ok - the message names the value and its row count" || { echo "FAILED: message"; exit 1; }
AFTER=$(psql -X -At -d $DB -c "select md5(string_agg(to_jsonb(e)::text, '|' order by id)) || '/' || (select count(*) from pg_attribute where attrelid = 'attendance_events'::regclass and attnum > 0 and not attisdropped) || '/' || (select count(*) from pg_proc where proname like 'biometric_project%') from attendance_events e")
check "$AFTER" "$BEFORE" "nothing changed: same rows (the kiosk row intact), same columns, no projection functions"
psql -X -q -d $DB -c "update attendance_events set source = 'web' where source = 'kiosk'" > /dev/null
psql -X -q -v ON_ERROR_STOP=1 --single-transaction -d $DB -f ../migrations/0012_biometric_projection.sql > /dev/null 2>&1; RC=$?
check "$RC" 0 "after the owner corrects the row, 0012 applies"
check "$(psql -X -At -d $DB -c "select count(*) from pg_constraint where conname in ('attendance_events_source_check', 'attendance_events_external_shape') and convalidated")" 2 \
  "source and shape checks validated on existing rows"
dropdb $DB
echo "ALL PREFLIGHT TESTS PASSED"
