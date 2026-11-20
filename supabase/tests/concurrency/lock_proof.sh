#!/bin/sh
# Concurrency proofs on throwaway copies of the test database (run after supabase/tests/run.sh).
#  1-2: 0010 mapping and review races (as migrated).
#  3-5: correction locking — the PROPOSED 0012 wrapper (proposed_correction_lock.sql) against a simulated projection
#       that takes lock 7 like the real one will; each scenario runs on a fresh copy, with and without the wrapper.
# Usage: PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres sh supabase/tests/concurrency/lock_proof.sh
set -e
cd "$(dirname "$0")"
HR=00000000-0000-0000-0000-00000000000b
ADMIN=00000000-0000-0000-0000-00000000000a
P=00000000-0000-0000-0000-0000000000f1
PASS=0; FAIL=0
ok() { echo "ok - $1"; PASS=$((PASS+1)); }
bad() { echo "FAILED - $1"; FAIL=$((FAIL+1)); }
fresh() { dropdb --if-exists "$1"; createdb -T attendos_test "$1"; }
q() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
as_user() { printf "set role authenticated; select set_config('request.jwt.claim.sub', '%s', false);\n" "$1"; }

# ------------------------------------------------------------ 1. two HR users map the same code at the same moment
DB=bio_race_map; fresh $DB
DEV=$(q $DB "select id from biometric_devices where serial_number = 'ES002'")
E4=$(q $DB "select id from employees where email = 'readback@acme.in'")
E5=$(q $DB "select id from employees where email = 'second@acme.in'")
( { as_user $HR; echo "begin; select biometric_save_mapping('RACE1', '$DEV', '$E4', now()) ->> 'ok'; select pg_sleep(2); commit;"; } | psql -X -q -At -d $DB > /tmp/race_a.txt 2>&1 ) &
sleep 0.5
START=$(date +%s.%N)
R2=$( { as_user $HR; echo "select biometric_save_mapping('RACE1', '$DEV', '$E5', now()) ->> 'message';"; } | psql -X -q -At -d $DB 2>&1 | tail -1)
WAIT=$(echo "$(date +%s.%N) - $START" | bc); wait
N=$(q $DB "select count(*) from biometric_employee_mappings where employee_device_code = 'RACE1'")
case "$R2" in *"already mapped"*) [ "$N" = 1 ] && [ "$(echo "$WAIT > 1.0" | bc)" = 1 ] && ok "mapping race: second save waited ${WAIT}s for the first, then was refused ('already mapped'); 1 mapping" || bad "mapping race (n=$N wait=$WAIT)";; *) bad "mapping race: second save returned '$R2'";; esac
# same race below the functions: two direct inserts for two people without a code on this device — the exclusion constraint decides
E6=$(q $DB "select e.id from employees e where e.company_id = (select company_id from biometric_devices where id = '$DEV') and e.active
  and not exists (select 1 from biometric_employee_mappings m where m.employee_id = e.id and m.device_id = '$DEV') order by e.email limit 1")
E7=$(q $DB "select e.id from employees e where e.company_id = (select company_id from biometric_devices where id = '$DEV') and e.active
  and not exists (select 1 from biometric_employee_mappings m where m.employee_id = e.id and m.device_id = '$DEV') order by e.email offset 1 limit 1")
( echo "begin; insert into biometric_employee_mappings (company_id, device_id, employee_id, employee_device_code, valid_from) select company_id, id, '$E6', 'RACE2', now() from biometric_devices where id = '$DEV'; select pg_sleep(2); commit;" | psql -X -q -d $DB > /tmp/race_ins.txt 2>&1 ) &
sleep 0.5
R3=$(echo "insert into biometric_employee_mappings (company_id, device_id, employee_id, employee_device_code, valid_from) select company_id, id, '$E7', 'RACE2', now() - interval '1 hour' from biometric_devices where id = '$DEV';" | psql -X -q -d $DB 2>&1 | head -1); wait
N=$(q $DB "select count(*) from biometric_employee_mappings where employee_device_code = 'RACE2'")
case "$R3" in *"exclusion constraint"*) [ "$N" = 1 ] && ok "direct concurrent inserts: the second waited, then the exclusion constraint refused it (1 row)" || bad "direct race n=$N";; *) bad "direct insert race: '$R3' / $(cat /tmp/race_ins.txt)";; esac

# ------------------------------------------------------------ 2. HR and Admin decide the same punch at the same moment
DB=bio_race_review; fresh $DB
RID=$(q $DB "with d as (select id, company_id, agent_id from biometric_devices where serial_number = 'ZK001' and agent_id is not null limit 1)
  insert into biometric_raw_events (company_id, device_id, agent_id, employee_device_code, device_local_time, device_timezone, punch_at, source_auth, dedupe_key, dedupe_basis)
  select company_id, id, agent_id, '0101', to_char(date_trunc('second', now() - interval '1 minute') at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS'), 'Asia/Kolkata',
         date_trunc('second', now() - interval '1 minute'), 'authenticated', 'seq:9001', 'record_seq' from d returning id")
q $DB "insert into biometric_event_state (raw_event_id, company_id, employee_id, mapping_id, status)
  select r.id, r.company_id, m.employee_id, m.id, 'possible_duplicate' from biometric_raw_events r
    join biometric_employee_mappings m on m.device_id = r.device_id and m.employee_device_code = '0101' and m.valid_to is null where r.id = $RID" > /dev/null
( { as_user $HR; echo "begin; select biometric_review_event($RID, 'confirm_duplicate', null, 1) ->> 'ok'; select pg_sleep(2); commit;"; } | psql -X -q -At -d $DB > /tmp/race_r.txt 2>&1 ) &
sleep 0.5
R4=$( { as_user $ADMIN; echo "select biometric_review_event($RID, 'not_duplicate', 'Two genuine punches', 1) ->> 'message';"; } | psql -X -q -At -d $DB 2>&1 | tail -1); wait
N=$(q $DB "select count(*) from biometric_event_reviews where raw_event_id = $RID")
S=$(q $DB "select status || ',' || decided from biometric_event_state where raw_event_id = $RID")
case "$R4" in *"already been decided"*) [ "$N" = 1 ] && [ "$S" = "rejected,true" ] && ok "review race: second decision waited and was refused; exactly 1 review, state $S" || bad "review race (n=$N state=$S)";; *) bad "review race: '$R4'";; esac

# ------------------------------------------------------------ 3-5. correction locking (proposed 0012 wrapper)
setup_p() { # person P with a login, office roster today at Andheri, pending missing-in correction for yesterday
  q $1 "insert into auth.users (id, email) values ('$P', 'proof@acme.in');
        insert into employees (company_id, full_name, email, role, home_location_id)
          select company_id, 'Proof Person', 'proof@acme.in', 'employee', '11111111-1111-1111-1111-111111111111' from employees where id = '$ADMIN';
        insert into roster_day (employee_id, day, work_mode, location_id) select id, local_today(company_id), 'office', '11111111-1111-1111-1111-111111111111' from employees where email = 'proof@acme.in';
        -- stand-in for 0012 projection: takes lock 7 (when asked), then inserts a biometric check-in only if the day has none
        create function public.proof_project_in(emp uuid, d date, t timestamptz, use_lock boolean) returns text language plpgsql as \$\$
        begin
          if use_lock then perform pg_advisory_xact_lock(hashtextextended(emp::text, 7)); end if;
          if exists (select 1 from attendance_events where employee_id = emp and work_date = d and kind = 'in' and superseded_by is null) then return 'not projected (day already has a check-in)'; end if;
          insert into attendance_events (employee_id, kind, at, work_mode, verified, source, work_date) values (emp, 'in', t, 'office', false, 'biometric', d);
          return 'projected';
        end \$\$;" > /dev/null
  PE=$(q $1 "select id from employees where email = 'proof@acme.in'")
  { as_user $P; echo "select request_correction(local_today((select company_id from employees where id = '$PE')) - 1, 'missing_in', at_local((select company_id from employees where id = '$PE'), local_today((select company_id from employees where id = '$PE')) - 1, '09:00'), null, 'Forgot to check in');"; } | psql -X -q -At -d $1 > /dev/null
  CID=$(q $1 "select id from attendance_corrections where employee_id = '$PE' and status = 'pending'")
}
ins_count() { q $1 "select count(*) from attendance_events where employee_id = '$PE' and work_date = $2 and kind = 'in' and superseded_by is null"; }

for MODE in without with; do
  # 3. correction approval vs biometric projection for the same day
  DB=bio_lock_$MODE; fresh $DB; setup_p $DB
  [ $MODE = with ] && psql -X -q -v ON_ERROR_STOP=1 -d $DB -f proposed_correction_lock.sql > /dev/null
  D="local_today((select company_id from employees where id = '$PE')) - 1"
  ( { as_user $HR; echo "begin; select decide_correction($CID, true) ->> 'ok'; select pg_sleep(2); commit;"; } | psql -X -q -At -d $DB > /tmp/corr_$MODE.txt 2>&1 ) &
  sleep 0.5
  START=$(date +%s.%N)
  OUT=$(q $DB "select proof_project_in('$PE', $D, at_local((select company_id from employees where id = '$PE'), $D, '09:05'), true)")
  WAIT=$(echo "$(date +%s.%N) - $START" | bc); wait
  N=$(ins_count $DB "$D")
  echo "   [$MODE wrapper] correction vs projection: projection waited ${WAIT}s -> '$OUT'; live check-ins for the day: $N"
  if [ $MODE = without ]; then [ "$N" = 2 ] && ok "WITHOUT the wrapper the race is real: correction and projection both inserted a check-in (2 live 'in' rows)" || bad "expected the unprotected race to show 2 rows, got $N"
  else [ "$N" = 1 ] && [ "$(echo "$WAIT > 1.0" | bc)" = 1 ] && ok "WITH the wrapper: projection waited for the approval, then saw the corrected check-in and did not add another (1 live 'in')" || bad "wrapper scenario: n=$N wait=$WAIT"; fi

  # 4. web punch vs correction approval (today) — punch must wait for the approval when the wrapper is in place
  q $DB "update roster_day set work_mode = 'office' where employee_id = '$PE'" > /dev/null
  { as_user $P; echo "select request_correction(local_today((select company_id from employees where id = '$PE')), 'wrong_time', now() - interval '3 hours', null, 'Gate was closed');"; } | psql -X -q -At -d $DB > /dev/null
  C2=$(q $DB "select id from attendance_corrections where employee_id = '$PE' and status = 'pending'")
  if [ -n "$C2" ]; then
    ( { as_user $HR; echo "begin; select decide_correction($C2, true) ->> 'ok'; select pg_sleep(2); commit;"; } | psql -X -q -At -d $DB > /dev/null 2>&1 ) &
    sleep 0.5
    START=$(date +%s.%N)
    PO=$( { as_user $P; echo "select coalesce(x ->> 'code', 'ok') from punch('in', 19.1105, 72.8801, 25) x;"; } | psql -X -q -At -d $DB 2>&1 | tail -1)
    WAIT=$(echo "$(date +%s.%N) - $START" | bc); wait
    echo "   [$MODE wrapper] punch vs correction: punch waited ${WAIT}s -> '$PO'"
    if [ $MODE = with ]; then [ "$(echo "$WAIT > 1.0" | bc)" = 1 ] && ok "WITH the wrapper a web punch waits for a correction approval of the same person" || bad "punch did not wait ($WAIT)"
    else [ "$(echo "$WAIT < 1.0" | bc)" = 1 ] && ok "WITHOUT the wrapper a web punch does not wait for the approval (unserialised today)" || bad "unexpected wait $WAIT"; fi
  fi
done

# 5. web punch vs projection — both already use lock 7, so they serialise (with or without the wrapper)
DB=bio_lock_punch; fresh $DB; setup_p $DB
T="local_today((select company_id from employees where id = '$PE'))"
( { as_user $P; echo "begin; select punch('in', 19.1105, 72.8801, 25) ->> 'ok'; select pg_sleep(2); commit;"; } | psql -X -q -At -d $DB > /tmp/punch.txt 2>&1 ) &
sleep 0.5
START=$(date +%s.%N)
OUT=$(q $DB "select proof_project_in('$PE', $T, now(), true)")
WAIT=$(echo "$(date +%s.%N) - $START" | bc); wait
N=$(ins_count $DB "$T")
echo "   web punch vs projection: projection waited ${WAIT}s -> '$OUT'; live check-ins: $N; punch: $(tr '\n' ' ' < /tmp/punch.txt)"
[ "$N" = 1 ] && [ "$(echo "$WAIT > 1.0" | bc)" = 1 ] && ok "web punch and projection serialise on lock 7: one check-in, no duplicate" || bad "punch vs projection n=$N wait=$WAIT"
DB=bio_lock_punch_nolock; fresh $DB; setup_p $DB
( { as_user $P; echo "begin; select punch('in', 19.1105, 72.8801, 25) ->> 'ok'; select pg_sleep(2); commit;"; } | psql -X -q -At -d $DB > /dev/null 2>&1 ) &
sleep 0.5
OUT=$(q $DB "select proof_project_in('$PE', $T, now(), false)"); wait
N=$(ins_count $DB "$T")
[ "$N" = 2 ] && ok "control: a projection that skipped lock 7 would duplicate the check-in (2 rows) — so 0012 must take it" || bad "control expected 2, got $N"

# 6. existing correction behaviour is unchanged with the wrapper (approve, reject rules, own request, other company, audit)
DB=bio_lock_regress; fresh $DB; setup_p $DB
psql -X -q -v ON_ERROR_STOP=1 -d $DB -f proposed_correction_lock.sql > /dev/null
R=$( { as_user $P; echo "select decide_correction($CID, true) ->> 'message';"; } | psql -X -q -At -d $DB 2>&1 | tail -1)
case "$R" in *"own request"*|*"Not allowed"*) ok "wrapper: an employee still cannot decide (own request refused)";; *) bad "own request: $R";; esac
R=$( { as_user 00000000-0000-0000-0000-0000000000b0; echo "select decide_correction($CID, true);"; } | psql -X -q -At -d $DB 2>&1 | grep -m1 "ERROR")
case "$R" in *"Not allowed"*) ok "wrapper: another company's Admin is refused";; *) bad "cross-company: $R";; esac
R=$( { as_user $HR; echo "select decide_correction($CID, false, 'no') ->> 'message';"; } | psql -X -q -At -d $DB 2>&1 | tail -1)
case "$R" in *"reason"*) ok "wrapper: rejecting still needs a reason";; *) bad "reject rule: $R";; esac
R=$( { as_user $HR; echo "select decide_correction($CID, true) ->> 'ok';"; } | psql -X -q -At -d $DB 2>&1 | tail -1)
N=$(q $DB "select count(*) from attendance_events where correction_id = $CID")
A=$(q $DB "select count(*) from audit_log where target = 'attendance_corrections' and target_id = '$CID' and action = 'approve'")
[ "$R" = true ] && [ "$N" = 1 ] && [ "$A" = 1 ] && ok "wrapper: HR approval works as before (corrected event + audit entry)" || bad "approve: r=$R n=$N a=$A"
R=$( { as_user $HR; echo "select decide_correction($CID, true) ->> 'message';"; } | psql -X -q -At -d $DB 2>&1 | tail -1)
case "$R" in *"no longer pending"*) ok "wrapper: a decided correction cannot be decided again";; *) bad "again: $R";; esac
X=$(q $DB "select has_function_privilege('authenticated', 'decide_correction_core(bigint,boolean,text)', 'execute')")
[ "$X" = f ] && ok "wrapper: the inner function cannot be called directly (lock cannot be bypassed)" || bad "core callable"

for d in bio_lock_regress bio_race_map bio_race_review bio_lock_without bio_lock_with bio_lock_punch bio_lock_punch_nolock; do dropdb --if-exists $d; done
echo "$PASS passed, $FAIL failed"
[ $FAIL = 0 ]
