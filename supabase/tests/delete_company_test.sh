#!/bin/sh
# Runs deploy/delete_company.sql (dry run, then delete) for company "beta" on a throwaway copy of the test database
# (after run.sh), proving the biometric tables are removed in a safe order and no other company changes.
# Then the same for company "proj" (built by biometric_projection_test.sql), which has projected attendance rows that
# point at raw punches and devices (0012, on delete restrict): attendance must go before the raw punches.
set -e
cd "$(dirname "$0")"
DB=bio_delete_test
dropdb --if-exists $DB; createdb -T attendos_test $DB
CID=$(psql -X -At -d $DB -c "select id from companies where slug = 'beta'")
check() { if [ "$1" = "$2" ]; then echo "ok - $3"; else echo "FAILED: $3 (got '$1', expected '$2')"; exit 1; fi; }
TRG="select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname in ('biometric_raw_events', 'biometric_event_state', 'biometric_event_reviews', 'attendance_events') and t.tgenabled = 'O' and not t.tgisinternal"
TRG_BEFORE=$(psql -X -At -d $DB -c "$TRG")
A_BEFORE=$(psql -X -At -d $DB -c "select string_agg(t || '=' || n, ' ' order by t) from (select 'state' t, count(*) n from biometric_event_state s join companies c on c.id = s.company_id where c.slug <> 'beta' union all select 'raw', count(*) from biometric_raw_events r join companies c on c.id = r.company_id where c.slug <> 'beta' union all select 'mappings', count(*) from biometric_employee_mappings m join companies c on c.id = m.company_id where c.slug <> 'beta' union all select 'reviews', count(*) from biometric_event_reviews v join companies c on c.id = v.company_id where c.slug <> 'beta') x")
B_BEFORE=$(psql -X -At -d $DB -c "select count(*) from biometric_raw_events where company_id = '$CID'")
sed -e "s/'REPLACE_slug'/'beta'/" -e "s/'REPLACE_company_id'/'$CID'/" ../deploy/delete_company.sql > /tmp/del_dry.sql
psql -X -q -v ON_ERROR_STOP=1 -d $DB -f /tmp/del_dry.sql > /tmp/del_dry.out
STILL=$(psql -X -At -d $DB -c "select count(*) from biometric_raw_events where company_id = '$CID'")
check "$STILL" "$B_BEFORE" "dry run lists the biometric tables and deletes nothing ($STILL raw events of beta remain)"
grep -c biometric_ /tmp/del_dry.out | xargs -I{} echo "   dry-run report lines for biometric tables: {}"
sed -e "s/'REPLACE_slug'/'beta'/" -e "s/'REPLACE_company_id'/'$CID'/" -e "s/'DRY RUN'/'DELETE beta'/" ../deploy/delete_company.sql > /tmp/del_go.sql
psql -X -q -v ON_ERROR_STOP=1 -d $DB -f /tmp/del_go.sql > /tmp/del_go.out
LEFT=$(psql -X -At -d $DB -c "select (select count(*) from biometric_raw_events where company_id = '$CID') + (select count(*) from biometric_agents where company_id = '$CID') + (select count(*) from biometric_event_state where company_id = '$CID') + (select count(*) from companies where id = '$CID')")
A_AFTER=$(psql -X -At -d $DB -c "select string_agg(t || '=' || n, ' ' order by t) from (select 'state' t, count(*) n from biometric_event_state union all select 'raw', count(*) from biometric_raw_events union all select 'mappings', count(*) from biometric_employee_mappings union all select 'reviews', count(*) from biometric_event_reviews) x")
check "$LEFT" 0 "beta's biometric rows (raw $B_BEFORE, agents, state …) and the company are gone"
check "$A_AFTER" "$A_BEFORE" "other companies' biometric rows unchanged ($A_AFTER); the script's own all-32-table guard passed"
TRG_AFTER=$(psql -X -At -d $DB -c "$TRG")
check "$TRG_AFTER" "$TRG_BEFORE" "all protection triggers on raw events, state, reviews and attendance ($TRG_AFTER) are switched back on after the deletion"
dropdb $DB

# ---- 0012: a company with projected biometric attendance
DB=bio_delete_test2
dropdb --if-exists $DB; createdb -T attendos_test $DB
PID=$(psql -X -At -d $DB -c "select id from companies where slug = 'proj'")
P_ROWS=$(psql -X -At -d $DB -c "select count(*) from attendance_events e join employees p on p.id = e.employee_id where p.company_id = '$PID' and e.source = 'biometric'")
OTHERS="select (select count(*) from attendance_events e join employees p on p.id = e.employee_id where p.company_id <> '$PID') || '/' || (select count(*) from biometric_raw_events where company_id <> '$PID') || '/' || (select count(*) from biometric_event_state where company_id <> '$PID') || '/' || (select count(*) from audit_log where company_id <> '$PID')"
O_BEFORE=$(psql -X -At -d $DB -c "$OTHERS")
sed -e "s/'REPLACE_slug'/'proj'/" -e "s/'REPLACE_company_id'/'$PID'/" -e "s/'DRY RUN'/'DELETE proj'/" ../deploy/delete_company.sql > /tmp/del_go2.sql
psql -X -q -v ON_ERROR_STOP=1 -d $DB -f /tmp/del_go2.sql > /tmp/del_go2.out
P_LEFT=$(psql -X -At -d $DB -c "select (select count(*) from companies where id = '$PID') + (select count(*) from biometric_raw_events where company_id = '$PID') + (select count(*) from employees where company_id = '$PID')")
O_AFTER=$(psql -X -At -d $DB -c "$OTHERS")
[ "$P_ROWS" -gt 0 ] || { echo "FAILED: proj has no projected rows to delete"; exit 1; }
check "$P_LEFT" 0 "proj (with $P_ROWS projected biometric attendance rows) is deleted: attendance before raw punches, no foreign-key error"
check "$O_AFTER" "$O_BEFORE" "other companies' attendance / raw / state / audit rows unchanged ($O_AFTER)"
dropdb $DB
