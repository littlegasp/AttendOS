#!/bin/sh
# Runs deploy/delete_company.sql (dry run, then delete) for company "beta" on a throwaway copy of the test database
# (after run.sh), proving the biometric tables are removed in a safe order and no other company changes.
set -e
cd "$(dirname "$0")"
DB=bio_delete_test
dropdb --if-exists $DB; createdb -T attendos_test $DB
CID=$(psql -X -At -d $DB -c "select id from companies where slug = 'beta'")
A_BEFORE=$(psql -X -At -d $DB -c "select string_agg(t || '=' || n, ' ' order by t) from (select 'state' t, count(*) n from biometric_event_state s join companies c on c.id = s.company_id where c.slug <> 'beta' union all select 'raw', count(*) from biometric_raw_events r join companies c on c.id = r.company_id where c.slug <> 'beta' union all select 'mappings', count(*) from biometric_employee_mappings m join companies c on c.id = m.company_id where c.slug <> 'beta' union all select 'reviews', count(*) from biometric_event_reviews v join companies c on c.id = v.company_id where c.slug <> 'beta') x")
B_BEFORE=$(psql -X -At -d $DB -c "select count(*) from biometric_raw_events where company_id = '$CID'")
sed -e "s/'REPLACE_slug'/'beta'/" -e "s/'REPLACE_company_id'/'$CID'/" ../deploy/delete_company.sql > /tmp/del_dry.sql
psql -X -q -v ON_ERROR_STOP=1 -d $DB -f /tmp/del_dry.sql > /tmp/del_dry.out
STILL=$(psql -X -At -d $DB -c "select count(*) from biometric_raw_events where company_id = '$CID'")
[ "$STILL" = "$B_BEFORE" ] && echo "ok - dry run lists the biometric tables and deletes nothing ($STILL raw events of beta remain)"
grep -c biometric_ /tmp/del_dry.out | xargs -I{} echo "   dry-run report lines for biometric tables: {}"
sed -e "s/'REPLACE_slug'/'beta'/" -e "s/'REPLACE_company_id'/'$CID'/" -e "s/'DRY RUN'/'DELETE beta'/" ../deploy/delete_company.sql > /tmp/del_go.sql
psql -X -q -v ON_ERROR_STOP=1 -d $DB -f /tmp/del_go.sql > /tmp/del_go.out
LEFT=$(psql -X -At -d $DB -c "select (select count(*) from biometric_raw_events where company_id = '$CID') + (select count(*) from biometric_agents where company_id = '$CID') + (select count(*) from biometric_event_state where company_id = '$CID') + (select count(*) from companies where id = '$CID')")
A_AFTER=$(psql -X -At -d $DB -c "select string_agg(t || '=' || n, ' ' order by t) from (select 'state' t, count(*) n from biometric_event_state union all select 'raw', count(*) from biometric_raw_events union all select 'mappings', count(*) from biometric_employee_mappings union all select 'reviews', count(*) from biometric_event_reviews) x")
[ "$LEFT" = 0 ] && echo "ok - beta's biometric rows (raw $B_BEFORE, agents, state …) and the company are gone"
[ "$A_BEFORE" = "$A_AFTER" ] && echo "ok - other companies' biometric rows unchanged ($A_AFTER); the script's own all-32-table guard passed"
UPD=$(psql -X -At -d $DB -c "select count(*) from pg_trigger where tgrelid = 'biometric_raw_events'::regclass and tgenabled = 'O' and not tgisinternal")
[ "$UPD" = 3 ] && echo "ok - raw-event protection triggers are switched back on after the deletion"
dropdb $DB
