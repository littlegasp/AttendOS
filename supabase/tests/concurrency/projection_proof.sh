#!/bin/sh
# 0012 projection concurrency proofs (design §12.3, H8, Q1, Q5) on throwaway copies of the test database (after run.sh).
# Each scenario uses two real sessions; one holds its transaction open with pg_sleep so the other must wait or interleave.
# People, devices and the time zone come from company "proj" built by biometric_projection_test.sql.
# Usage: PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres sh supabase/tests/concurrency/projection_proof.sh
cd "$(dirname "$0")"
PASS=0; FAIL=0
ok() { echo "ok - $1"; PASS=$((PASS+1)); }
bad() { echo "FAILED - $1"; FAIL=$((FAIL+1)); }
fresh() { dropdb --if-exists "$1" 2>/dev/null; createdb -T attendos_test "$1"; setup "$1"; }
q() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
as_email() { printf "select set_config('request.jwt.claim.sub', (select user_id::text from employees where email = '%s'), false); set role authenticated;\n" "$1"; }
# helpers in a scratch schema: local instant, a punch as the gateway stores it, a person's id, live counts
setup() {
  q $1 "create schema proof;
  create function proof.c() returns uuid language sql as \$\$ select id from companies where slug = 'proj' \$\$;
  create function proof.e(email text) returns uuid language sql as \$\$ select id from employees where employees.email = \$1 \$\$;
  create function proof.at(n int, t time) returns timestamptz language sql as \$\$ select at_local(proof.c(), local_today(proof.c()) - n, t) \$\$;
  create sequence proof.seq start 900000;
  create function proof.punch(serial text, code text, ts timestamptz, auth text default 'authenticated', dir text default null) returns bigint language plpgsql as \$f\$
  declare d biometric_devices; rid bigint; mid uuid; s bigint := nextval('proof.seq'); fl text[];
  begin
    select * into d from biometric_devices where serial_number = serial;
    insert into biometric_raw_events (company_id, device_id, agent_id, employee_device_code, device_local_time, device_timezone, punch_at, source_auth, dedupe_key, dedupe_basis, direction, direction_source)
      values (d.company_id, d.id, d.agent_id, code, to_char(date_trunc('second', ts) at time zone d.timezone, 'YYYY-MM-DD HH24:MI:SS'), d.timezone, date_trunc('second', ts),
              auth, 'seq:' || s, 'record_seq', dir, case when dir is null then 'none' else 'device' end) returning id, time_flags into rid, fl;
    mid := biometric_resolve_mapping(d.company_id, d.id, code, date_trunc('second', ts));
    if auth <> 'authenticated' then fl := array_append(fl, 'unauthenticated_source'); end if;
    insert into biometric_event_state (raw_event_id, company_id, employee_id, mapping_id, status, flag_reasons)
      values (rid, d.company_id, (select employee_id from biometric_employee_mappings where id = mid), mid, case when cardinality(fl) > 0 then 'flagged' else 'stored' end, fl);
    update biometric_event_state s2 set work_date = (biometric_work_date_at(s2.employee_id, r.punch_at, r.direction)).work_date
      from biometric_raw_events r where r.id = s2.raw_event_id and s2.raw_event_id = rid;
    return rid;
  end \$f\$;
  create function proof.live(emp uuid, n int, k text) returns bigint language sql as \$\$
    select count(*) from attendance_events where employee_id = emp and work_date = local_today(proof.c()) - n and kind = k and superseded_by is null \$\$;
  create function proof.fresh_person(tag text) returns uuid language plpgsql as \$f\$
  declare uid uuid := gen_random_uuid(); eid uuid;
  begin
    insert into auth.users (id, email, email_confirmed_at) values (uid, tag || '@proof.co', now());
    insert into employees (company_id, full_name, email, role, user_id, home_location_id, joining_date)
      values (proof.c(), 'Proof ' || tag, tag || '@proof.co', 'employee', uid, (select id from locations where name = 'Proj Plant'), current_date - 60) returning id into eid;
    insert into biometric_employee_mappings (company_id, employee_id, employee_device_code, valid_from) values (proof.c(), eid, upper(tag), now() - interval '30 days');
    return eid;
  end \$f\$;
  grant usage on schema proof to authenticated; grant execute on all functions in schema proof to authenticated;" > /dev/null
}
DEADLOCKS=0
sess() { # run SQL as a person (email) or as owner ('-') in its own session; output to file $3
  if [ "$1" = - ]; then echo "$2" | psql -X -q -At -d $DB > "$3" 2>&1; else { as_email "$1"; echo "$2"; } | psql -X -q -At -d $DB > "$3" 2>&1; fi
  grep -q "deadlock detected" "$3" && DEADLOCKS=$((DEADLOCKS+1)); true
}

# ------------------------------------------------------------ 1. web check-in vs projection of the same morning (both orders, 10 rounds each)
DB=proj_race_1; fresh $DB; : > /tmp/p1_outcomes.txt
BAD=0
for R in $(seq 1 20); do
  E=$(q $DB "select proof.fresh_person('r1p$R')")
  q $DB "select proof.punch('PFL001', 'R1P$R', least(now() - interval '1 minute', proof.at(0, '11:00')))" > /dev/null
  if [ $((R % 2)) = 0 ]; then
    ( sess "r1p$R@proof.co" "begin; select punch('in', 19.1000, 72.9000, 10) ->> 'ok'; select pg_sleep(0.6); commit;" /tmp/p1a.txt ) &
    sleep 0.2; sess - "select biometric_project_day('$E', local_today(proof.c()))" /tmp/p1b.txt; wait
  else
    ( sess - "begin; select biometric_project_day('$E', local_today(proof.c())); select pg_sleep(0.6); commit;" /tmp/p1b.txt ) &
    sleep 0.2; sess "r1p$R@proof.co" "select punch('in', 19.1000, 72.9000, 10) ->> 'code'" /tmp/p1a.txt; wait
  fi
  N=$(q $DB "select proof.live('$E', 0, 'in')"); W=$(grep -v '^$' /tmp/p1a.txt | tail -1)
  # the web call really ran: it either checked in (ok/true) or was refused because the machine check-in came first
  case "$W" in true|already_in) ;; *) BAD=$((BAD+1)); echo "   round $R: web call did not run as expected: $W";; esac
  [ "$N" = 1 ] || { BAD=$((BAD+1)); echo "   round $R: $N live check-ins ($(tr '\n' ' ' < /tmp/p1a.txt) / $(tr '\n' ' ' < /tmp/p1b.txt))"; }
  echo "$W" >> /tmp/p1_outcomes.txt
done
echo "   web outcomes: $(sort /tmp/p1_outcomes.txt | uniq -c | tr '\n' ' ')"
[ $BAD = 0 ] && ok "1. web check-in vs projection, 20 rounds (both orders): always exactly one counted check-in; deadlocks: $DEADLOCKS" || bad "1. $BAD rounds with a wrong count"

# ------------------------------------------------------------ 2. correction approval vs projection (both orders)
DB=proj_race_2; fresh $DB
for ORDER in approval_first projection_first; do
  E=$(q $DB "select proof.fresh_person('r2$ORDER')"); T=$(echo r2$ORDER | tr a-z A-Z)
  q $DB "select proof.punch('PFL001', '$T', proof.at(1, '08:30')); select proof.punch('PFL001', '$T', proof.at(1, '17:00'));" > /dev/null
  [ $ORDER = projection_first ] && q $DB "select biometric_project_day('$E', local_today(proof.c()) - 1)" > /dev/null
  sess "r2$ORDER@proof.co" "select request_correction(local_today(proof.c()) - 1, 'wrong_time', proof.at(1, '09:00'), null, 'Gate machine early')" /tmp/p2r.txt
  CID=$(q $DB "select id from attendance_corrections where employee_id = '$E' and status = 'pending'")
  if [ $ORDER = approval_first ]; then
    ( sess hr@proj.co "begin; select decide_correction($CID, true) ->> 'ok'; select pg_sleep(1); commit;" /tmp/p2a.txt ) &
    sleep 0.3; START=$(date +%s.%N); sess - "select biometric_project_day('$E', local_today(proof.c()) - 1)" /tmp/p2b.txt; WAIT=$(echo "$(date +%s.%N) - $START" | bc); wait
  else
    q $DB "update biometric_event_state set status = status where employee_id = '$E'" > /dev/null
    ( sess - "begin; select biometric_project_day('$E', local_today(proof.c()) - 1); select pg_sleep(1); commit;" /tmp/p2b.txt ) &
    sleep 0.3; START=$(date +%s.%N); sess hr@proj.co "select decide_correction($CID, true) ->> 'ok'" /tmp/p2a.txt; WAIT=$(echo "$(date +%s.%N) - $START" | bc); wait
  fi
  q $DB "select biometric_project_day('$E', local_today(proof.c()) - 1)" > /dev/null
  N=$(q $DB "select proof.live('$E', 1, 'in')"); SRC=$(q $DB "select string_agg(source, ',') from attendance_events where employee_id = '$E' and work_date = local_today(proof.c()) - 1 and kind = 'in' and superseded_by is null")
  echo "   [$ORDER] second session waited ${WAIT}s; live check-ins: $N ($SRC)"
  [ "$N" = 1 ] && [ "$SRC" = correction ] && [ "$(echo "$WAIT > 0.5" | bc)" = 1 ] && ok "2. correction vs projection ($ORDER): serialised on lock 7; only the correction's check-in counts" || bad "2. $ORDER n=$N src=$SRC wait=$WAIT"
done

# ------------------------------------------------------------ 3. web check-out vs day-close finalisation
DB=proj_race_3; fresh $DB
q $DB "insert into shifts (company_id, name, start_time, end_time) values (proof.c(), 'Short', '06:00', '07:00')" > /dev/null
BAD=0
for R in 1 2 3 4; do
  E=$(q $DB "select proof.fresh_person('r3p$R')"); T=R3P$R
  q $DB "select proof.punch('PFL001', '$T', least(now() - interval '2 hours', proof.at(0, '09:00'))); select proof.punch('PFL001', '$T', now() - interval '20 minutes');
         select biometric_project_day('$E', local_today(proof.c()));" > /dev/null
  PRE=$(q $DB "select string_agg(status, ',' order by raw_event_id) from biometric_event_state where employee_id = '$E'")
  q $DB "insert into shift_day (employee_id, day, shift_id) values ('$E', local_today(proof.c()), (select id from shifts where name = 'Short' and company_id = proof.c()))" > /dev/null
  if [ $((R % 2)) = 0 ]; then
    ( sess "r3p$R@proof.co" "begin; select coalesce(punch('out', 19.1000, 72.9000, 10) ->> 'code', 'ok'); select pg_sleep(0.6); commit;" /tmp/p3a.txt ) &
    sleep 0.2; sess - "select biometric_project_day('$E', local_today(proof.c()))" /tmp/p3b.txt; wait
  else
    ( sess - "begin; select biometric_project_day('$E', local_today(proof.c())); select pg_sleep(0.6); commit;" /tmp/p3b.txt ) &
    sleep 0.2; sess "r3p$R@proof.co" "select coalesce(punch('out', 19.1000, 72.9000, 10) ->> 'code', 'ok')" /tmp/p3a.txt; wait
  fi
  N=$(q $DB "select proof.live('$E', 0, 'out')")
  echo "   round $R (before: $PRE): web -> $(grep -v '^$' /tmp/p3a.txt | tail -1); live check-outs: $N ($(q $DB "select string_agg(source, ',') from attendance_events where employee_id = '$E' and kind = 'out' and superseded_by is null"))"
  [ "$N" = 1 ] || BAD=$((BAD+1))
done
[ $BAD = 0 ] && ok "3. web check-out vs finalisation of a provisional check-out (both orders): never two counted check-outs" || bad "3. $BAD rounds wrong"

# ------------------------------------------------------------ 4. two queue runs at once = one run (H8, Q5)
DB=proj_race_4; fresh $DB
q $DB "select proof.fresh_person('q4p' || g) from generate_series(1, 30) g;
       select proof.punch('PFL001', 'Q4P' || g, least(now() - interval '1 minute', proof.at(0, '09:00'))) from generate_series(1, 30) g;" > /dev/null
q $DB "select proof.fresh_person('q4h' || g) from generate_series(1, 30) g" > /dev/null
q $DB "insert into roster_day (employee_id, day, work_mode) select proof.e('q4h' || g || '@proof.co'), local_today(proof.c()) - 1, 'off' from generate_series(1, 30) g;
       select proof.punch('PFL001', 'Q4H' || g, proof.at(1, '09:00')) from generate_series(1, 30) g;
       select biometric_project_day(proof.e('q4h' || g || '@proof.co'), local_today(proof.c()) - 1) from generate_series(1, 30) g;
       update biometric_event_state set next_check_at = now() - interval '1 second' where status = 'held' and employee_id in (select proof.e('q4h' || g || '@proof.co') from generate_series(1, 30) g);" > /dev/null
dropdb --if-exists proj_race_4b 2>/dev/null; createdb -T $DB proj_race_4b
AUD0=$(q $DB "select count(*) from audit_log"); V0=$(q $DB "select sum(version) from biometric_event_state")
( echo "call biometric_run_projection();" | psql -X -q -d $DB > /tmp/p4a.txt 2>&1 ) &
( echo "call biometric_run_projection();" | psql -X -q -d $DB > /tmp/p4b.txt 2>&1 ) &
wait
echo "call biometric_run_projection();" | psql -X -q -d proj_race_4b > /dev/null 2>&1
SIG="select md5(string_agg(x, '|' order by x)) from (select e.email || ':' || s.status || ':' || coalesce(s.hold_reason, '') x from biometric_event_state s join employees e on e.id = s.employee_id where e.email like 'q4%' union all select e.email || ':' || a.kind || ':' || a.at from attendance_events a join employees e on e.id = a.employee_id where e.email like 'q4%') y"
A=$(q $DB "$SIG"); B=$(q proj_race_4b "$SIG")
AUD_A=$(($(q $DB "select count(*) from audit_log") - AUD0)); AUD_B=$(($(q proj_race_4b "select count(*) from audit_log") - AUD0))
VA=$(($(q $DB "select sum(version) from biometric_event_state") - V0)); VB=$(($(q proj_race_4b "select sum(version) from biometric_event_state") - V0))
ERR=$(cat /tmp/p4a.txt /tmp/p4b.txt | grep -c ERROR)
echo "   two runs: audit +$AUD_A, versions +$VA, errors $ERR; single run: audit +$AUD_B, versions +$VB"
[ "$A" = "$B" ] && [ "$AUD_A" = "$AUD_B" ] && [ "$VA" = "$VB" ] && [ "$ERR" = 0 ] && ok "4. two queue runs at once give exactly the single-run result: each due held punch and each new punch handled once" || bad "4. differs"
dropdb --if-exists proj_race_4b

# ------------------------------------------------------------ 5. HR acceptance / mapping change / ingest vs projection
DB=proj_race_5; fresh $DB
E=$(q $DB "select proof.fresh_person('r5a')")
R1=$(q $DB "select proof.punch('PFL001', 'R5A', least(now() - interval '1 minute', proof.at(0, '09:00')), 'unauthenticated_lan')")
VER=$(q $DB "select version from biometric_event_state where raw_event_id = $R1")
( sess hr@proj.co "begin; select biometric_review_event($R1, 'accept_time', 'Checked on CCTV', $VER) ->> 'status'; select pg_sleep(1); commit;" /tmp/p5a.txt ) &
sleep 0.3; sess - "select biometric_project_day('$E', local_today(proof.c()))" /tmp/p5b.txt; wait
ST1=$(q $DB "select status || '/' || decided from biometric_event_state where raw_event_id = $R1")
q $DB "select biometric_project_day('$E', local_today(proof.c()))" > /dev/null
ST=$(q $DB "select status from biometric_event_state where raw_event_id = $R1"); N=$(q $DB "select proof.live('$E', 0, 'in')")
echo "   acceptance vs projection: after the race the punch is $ST1 (decision kept); after the next run: $ST, counted $N"
[ "$ST1" = "stored/true" ] && [ "$ST" = projected ] && [ "$N" = 1 ] && ok "5a. HR acceptance during a projection is never overwritten; the next run projects the accepted punch" || bad "5a. st1=$ST1 st=$ST n=$N"
# a review of a punch the projection DOES lock (an extra punch): the review waits, then sees the new version and does not act on stale data
E4=$(q $DB "select proof.fresh_person('r5d')")
q $DB "select proof.punch('PFL001', 'R5D', least(now() - interval '3 hours', proof.at(0, '08:00'))); select proof.punch('PFL001', 'R5D', least(now() - interval '170 minutes', proof.at(0, '08:10')));
       select proof.punch('PFL001', 'R5D', least(now() - interval '160 minutes', proof.at(0, '08:20'))); select biometric_project_day('$E4', local_today(proof.c()));" > /dev/null
X=$(q $DB "select s.raw_event_id from biometric_event_state s where s.employee_id = '$E4' and s.status = 'extra' order by raw_event_id limit 1")
VX=$(q $DB "select version from biometric_event_state where raw_event_id = $X")
q $DB "select proof.punch('PFL001', 'R5D', least(now() - interval '1 minute', proof.at(0, '11:00')))" > /dev/null
( sess - "begin; select biometric_project_day('$E4', local_today(proof.c())); select pg_sleep(1); commit;" /tmp/p5h.txt ) &
sleep 0.3; START=$(date +%s.%N); sess hr@proj.co "select biometric_review_event($X, 'dismiss', 'Test press', $VX) ->> 'message'" /tmp/p5i.txt; WAIT=$(echo "$(date +%s.%N) - $START" | bc); wait
RV=$(tail -1 /tmp/p5i.txt); SX=$(q $DB "select status from biometric_event_state where raw_event_id = $X")
q $DB "select biometric_project_day('$E4', local_today(proof.c()))" > /dev/null; SX2=$(q $DB "select status from biometric_event_state where raw_event_id = $X")
echo "   dismiss vs projection of the same day: review waited ${WAIT}s -> '${RV:-applied}'; punch now $SX; after another projection: $SX2"
# either outcome is safe: the review sees the version the projection left (applies if the projection did not change
# that punch, refuses if it did); what must never happen is a decision lost or reverted
if [ "$(echo "$WAIT > 0.5" | bc)" = 1 ] && { { [ -z "$RV" ] && [ "$SX" = dismissed ] && [ "$SX2" = dismissed ]; } || { echo "$RV" | grep -q "changed since you opened it"; }; }; then
  ok "5a'. a review of a punch locked by a running projection waits for it, then acts on the current version; a dismissal is never reverted"
else bad "5a'. wait=$WAIT rv='$RV' $SX/$SX2"; fi
E2=$(q $DB "select proof.fresh_person('r5b')")
q $DB "select proof.punch('PFL001', 'R5B', least(now() - interval '1 minute', proof.at(0, '09:00')))" > /dev/null
MID=$(q $DB "select id from biometric_employee_mappings where employee_device_code = 'R5B'")
( sess - "begin; select biometric_project_day('$E2', local_today(proof.c())); select pg_sleep(1); commit;" /tmp/p5c.txt ) &
sleep 0.3; sess admin@proj.co "select biometric_end_mapping('$MID', now() - interval '1 hour', 'Card lost') ->> 'message'" /tmp/p5d.txt; wait
INV=$(q $DB "select count(*) from biometric_event_state s join biometric_raw_events r on r.id = s.raw_event_id join biometric_employee_mappings m on m.id = s.mapping_id where r.punch_at < m.valid_from or (m.valid_to is not null and r.punch_at >= m.valid_to)")
echo "   mapping end vs projection: mapping -> '$(tail -1 /tmp/p5d.txt)'; attribution violations: $INV"
[ "$INV" = 0 ] && ok "5b. ending a mapping while its punch is being projected never leaves a punch outside its mapping" || bad "5b. inv=$INV"
E3=$(q $DB "select proof.fresh_person('r5c')")
( sess - "begin; select proof.punch('PFL001', 'R5C', least(now() - interval '2 minutes', proof.at(0, '09:00'))); select pg_sleep(1); commit;" /tmp/p5e.txt ) &
sleep 0.3; sess - "select biometric_project_day('$E3', local_today(proof.c()))" /tmp/p5f.txt; wait
sess - "select biometric_project_day('$E3', local_today(proof.c()))" /tmp/p5g.txt
N=$(q $DB "select proof.live('$E3', 0, 'in')")
[ "$N" = 1 ] && ok "5c. a punch committed during a projection is projected by the next run (not lost, not doubled)" || bad "5c. n=$N"

# ------------------------------------------------------------ 6. accepted historical punch vs a web check-in under load (S19)
DB=proj_race_6; fresh $DB
BAD=0
for R in $(seq 1 6); do
  E=$(q $DB "select proof.fresh_person('r6p$R')")
  RID=$(q $DB "select proof.punch('PFL001', 'R6P$R', proof.at(3, '09:00'), 'unauthenticated_lan')")
  VER=$(q $DB "select version from biometric_event_state where raw_event_id = $RID")
  sess hr@proj.co "select biometric_review_event($RID, 'accept_time', 'Checked on CCTV', $VER) ->> 'status'" /tmp/p6r.txt
  ( sess - "begin; select biometric_project_day('$E', local_today(proof.c()) - 3); select pg_sleep(0.4); commit;" /tmp/p6b.txt ) &
  sleep 0.1; sess "r6p$R@proof.co" "select punch('in', 19.1000, 72.9000, 10) ->> 'ok'" /tmp/p6a.txt; wait
  [ "$(tail -1 /tmp/p6a.txt)" = true ] && [ "$(q $DB "select status from biometric_event_state where raw_event_id = $RID")" = correction_needed ] || BAD=$((BAD+1))
done
[ $BAD = 0 ] && ok "6. accepted historical lone check-in projected while the person checks in on the web: web check-in always succeeds, the punch is correction_needed" || bad "6. $BAD rounds"

# ------------------------------------------------------------ 7. a not-due held punch is not locked by a projection of its day (Q1)
DB=proj_race_7; fresh $DB
E=$(q $DB "select proof.fresh_person('r7')")
q $DB "insert into biometric_devices (company_id, location_id, name, manufacturer, model, serial_number, integration_method, agent_id, timezone, direction_mode)
       select company_id, null, 'No office', 'zkteco', 'K40', 'PNO777', 'sdk_pull', agent_id, timezone, 'first_last' from biometric_devices where serial_number = 'PFL001'" > /dev/null
H=$(q $DB "select proof.punch('PNO777', 'R7', least(now() - interval '3 minutes', proof.at(0, '08:00')))")
q $DB "select biometric_project_day('$E', local_today(proof.c())); select proof.punch('PFL001', 'R7', least(now() - interval '2 minutes', proof.at(0, '09:00')));" > /dev/null
( sess - "begin; select biometric_project_day('$E', local_today(proof.c())); select pg_sleep(1); commit;" /tmp/p7a.txt ) &
sleep 0.4; sess - "begin; select status from biometric_event_state where raw_event_id = $H for update nowait; rollback;" /tmp/p7b.txt; wait
grep -q "could not obtain lock" /tmp/p7b.txt && bad "7. the not-due held punch was locked" || { [ "$(head -1 /tmp/p7b.txt)" = held ] && ok "7. while its day is being projected, a not-due held punch stays unlocked (FOR UPDATE NOWAIT succeeds)" || bad "7. $(cat /tmp/p7b.txt)"; }

# ------------------------------------------------------------ 8. mixed load (the 'no biometric check-in beside an app one' count is limited to this proof's own
#    people: the projection test's fixtures include a legitimate split day, app morning + biometric afternoon), 5 rounds: punch, correction, review, ingest, queue at once
DB=proj_race_8; fresh $DB
for R in $(seq 1 5); do
  E=$(q $DB "select proof.fresh_person('m8p$R')"); F=$(q $DB "select proof.fresh_person('m8f$R')")
  q $DB "select proof.punch('PFL001', 'M8P$R', least(now() - interval '1 minute', proof.at(0, '09:00'))); select proof.punch('PFL001', 'M8F$R', proof.at(1, '09:00')); select proof.punch('PFL001', 'M8F$R', proof.at(1, '17:00'))" > /dev/null
  sess "m8f$R@proof.co" "select request_correction(local_today(proof.c()) - 1, 'wrong_time', proof.at(1, '08:45'), null, 'Early start')" /tmp/m.txt
  CID=$(q $DB "select id from attendance_corrections where employee_id = '$F' and status = 'pending'")
  RID=$(q $DB "select proof.punch('PFL001', 'M8P$R', least(now() - interval '30 seconds', proof.at(0, '09:30')), 'unauthenticated_lan')")
  VER=$(q $DB "select version from biometric_event_state where raw_event_id = $RID")
  ( sess - "call biometric_run_projection();" /tmp/m1.txt ) &
  ( sess hr@proj.co "select decide_correction($CID, true) ->> 'ok'" /tmp/m2.txt ) &
  ( sess hr@proj.co "select biometric_review_event($RID, 'dismiss', 'Visitor badge', $VER) ->> 'ok'" /tmp/m3.txt ) &
  ( sess "m8p$R@proof.co" "select punch('in', 19.1000, 72.9000, 10) ->> 'code'" /tmp/m4.txt ) &
  ( sess - "select proof.punch('PFL001', 'M8P$R', now() - interval '10 seconds')" /tmp/m5.txt ) &
  ( sess - "call biometric_run_projection();" /tmp/m6.txt ) &
  wait
done
q $DB "call biometric_run_projection()" > /dev/null 2>&1; echo "call biometric_run_projection();" | psql -X -q -d $DB > /dev/null 2>&1
INV=$(q $DB "select (select count(*) from attendance_events e join biometric_raw_events r on r.id = e.biometric_event_id join biometric_event_state s on s.raw_event_id = r.id
                       where e.at <> r.punch_at or s.employee_id <> e.employee_id or s.work_date <> e.work_date)
          + (select count(*) from (select 1 from attendance_events where projection_slot is not null group by employee_id, work_date, projection_slot having count(*) > 1) x)
          + (select count(*) from (select employee_id, work_date from attendance_events where superseded_by is null and kind = 'in'
                                     and employee_id in (select id from employees where email like '%@proof.co') group by 1, 2 having count(*) > 1
                                   and bool_or(source = 'biometric') and bool_or(source <> 'biometric')) y)")
echo "   mixed load: deadlocks $DEADLOCKS; invariant violations $INV"
[ "$DEADLOCKS" = 0 ] && [ "$INV" = 0 ] && ok "8. 5 rounds of queue + punch + correction + review + ingest at once: no deadlock, every biometric row matches its punch, no slot twice, no biometric check-in beside an app/correction one" || bad "8. deadlocks=$DEADLOCKS inv=$INV"

# ------------------------------------------------------------ 9. delayed device-mode IN + OUT pair (B3.4 final review) vs web check-in and vs correction approval
# day invariant: the day's live events alternate in/out and end with an out; the person is not left 'working' on that day; every biometric row matches
# its punch; a second projection changes nothing
pairinv() { q $DB "select (select count(*) from (select kind, lag(kind) over (order by at, id) pk, row_number() over (order by at desc, id desc) rn from attendance_events
                             where employee_id = '$1' and work_date = local_today(proof.c()) - 1 and superseded_by is null) x where kind = pk or (rn = 1 and kind <> 'out'))
                + (select count(*) from session_state('$1') where state = 'working' and work_date = local_today(proof.c()) - 1)
                + (select count(*) from attendance_events e join biometric_raw_events r on r.id = e.biometric_event_id join biometric_event_state st on st.raw_event_id = r.id
                    where e.employee_id = '$1' and (e.at <> r.punch_at or st.work_date <> e.work_date or e.source <> 'biometric'))
                + (select count(*) from biometric_event_state where employee_id = '$1' and status in ('stored') )"; }
snap() { q $DB "select md5(coalesce(string_agg(x, '|' order by x), '')) from (select id::text || kind || at::text || coalesce(superseded_by::text, '') x from attendance_events where employee_id = '$1'
                union all select raw_event_id::text || status || coalesce(flag_reasons::text, '') from biometric_event_state where employee_id = '$1') y"; }
DB=proj_race_9; fresh $DB
BAD=0
for R in $(seq 1 6); do
  E=$(q $DB "select proof.fresh_person('r9p$R')"); T=R9P$R
  q $DB "select proof.punch('PDV001', '$T', proof.at(1, '09:00'), 'authenticated', 'in'); select proof.punch('PDV002', '$T', proof.at(1, '17:00'), 'authenticated', 'out');" > /dev/null
  if [ $((R % 2)) = 0 ]; then
    ( sess "r9p$R@proof.co" "begin; select punch('in', 19.1000, 72.9000, 10) ->> 'ok'; select pg_sleep(0.6); commit;" /tmp/p9a.txt ) &
    sleep 0.2; sess - "select biometric_project_day('$E', local_today(proof.c()) - 1)" /tmp/p9b.txt; wait
  else
    ( sess - "begin; select biometric_project_day('$E', local_today(proof.c()) - 1); select pg_sleep(0.6); commit;" /tmp/p9b.txt ) &
    sleep 0.2; sess "r9p$R@proof.co" "select punch('in', 19.1000, 72.9000, 10) ->> 'ok'" /tmp/p9a.txt; wait
  fi
  W=$(grep -v '^$' /tmp/p9a.txt | tail -1); I=$(pairinv $E)
  PAIR=$(q $DB "select string_agg(kind || ':' || source, ',' order by at) from attendance_events where employee_id = '$E' and work_date = local_today(proof.c()) - 1 and superseded_by is null")
  ST=$(q $DB "select state || ':' || (work_date = local_today(proof.c())) from session_state('$E')")
  S1=$(snap $E); q $DB "select biometric_project_day('$E', local_today(proof.c()) - 1)" > /dev/null; S2=$(snap $E)
  BIO=$(q $DB "select string_agg(status || coalesce(':' || nullif(array_to_string(flag_reasons, '+'), ''), ''), ',' order by raw_event_id) from biometric_event_state where employee_id = '$E'")
  echo "   round $R: web -> $W; day-1: ${PAIR:-none}; punches: $BIO; now: $ST; invariant violations $I; rerun changed: $([ "$S1" = "$S2" ] && echo no || echo yes)"
  # two safe outcomes, decided by who takes lock 7 first: projection first -> the pair is written whole; web first -> the person is checked in now,
  # so an IN for yesterday is an impossible transition and BOTH punches go to HR (correction_needed). Never one without the other.
  case "$PAIR|$BIO" in "in:biometric,out:biometric|projected,projected"|"|correction_needed:impossible_transition,correction_needed:impossible_transition") ;; *) BAD=$((BAD+1));; esac
  [ "$W" = true ] && [ "$ST" = working:true ] && [ "$I" = 0 ] && [ "$S1" = "$S2" ] || BAD=$((BAD+1))
done
[ $BAD = 0 ] && ok "9a. delayed IN+OUT pair projected while the person checks in on the web (6 rounds, both orders): web check-in always succeeds; the pair is either written whole or sent whole to HR, never half; yesterday is never left open; a rerun changes nothing" || bad "9a. $BAD rounds"
for ORDER in approval_first projection_first; do
  E=$(q $DB "select proof.fresh_person('r9$ORDER')"); T=$(echo r9$ORDER | tr a-z A-Z)
  q $DB "select proof.punch('PDV001', '$T', proof.at(1, '09:00'), 'authenticated', 'in'); select proof.punch('PDV002', '$T', proof.at(1, '17:00'), 'authenticated', 'out');" > /dev/null
  sess "r9$ORDER@proof.co" "select request_correction(local_today(proof.c()) - 1, 'wrong_time', proof.at(1, '08:55'), proof.at(1, '17:02'), 'Machine was late')" /tmp/p9r.txt
  CID=$(q $DB "select id from attendance_corrections where employee_id = '$E' and status = 'pending'")
  if [ $ORDER = approval_first ]; then
    ( sess hr@proj.co "begin; select decide_correction($CID, true) ->> 'ok'; select pg_sleep(0.8); commit;" /tmp/p9c.txt ) &
    sleep 0.3; sess - "select biometric_project_day('$E', local_today(proof.c()) - 1)" /tmp/p9d.txt; wait
  else
    ( sess - "begin; select biometric_project_day('$E', local_today(proof.c()) - 1); select pg_sleep(0.8); commit;" /tmp/p9d.txt ) &
    sleep 0.3; sess hr@proj.co "select decide_correction($CID, true) ->> 'ok'" /tmp/p9c.txt; wait
  fi
  q $DB "select biometric_project_day('$E', local_today(proof.c()) - 1)" > /dev/null
  A=$(grep -v '^$' /tmp/p9c.txt | tail -1); I=$(pairinv $E)
  DAY=$(q $DB "select string_agg(kind || ':' || source, ',' order by at) from attendance_events where employee_id = '$E' and work_date = local_today(proof.c()) - 1 and superseded_by is null")
  BIO=$(q $DB "select string_agg(status, ',' order by raw_event_id) from biometric_event_state where employee_id = '$E'")
  S1=$(snap $E); q $DB "select biometric_project_day('$E', local_today(proof.c()) - 1)" > /dev/null; S2=$(snap $E)
  # a punch held while the correction was pending is looked at again when its next check is due; bring that forward and look again
  q $DB "update biometric_event_state set next_check_at = now() - interval '1 second' where employee_id = '$E' and status = 'held'; select biometric_project_day('$E', local_today(proof.c()) - 1);" > /dev/null
  BIO2=$(q $DB "select string_agg(status, ',' order by raw_event_id) from biometric_event_state where employee_id = '$E'"); I2=$(pairinv $E)
  echo "   [$ORDER] next due look: punches $BIO2; invariant violations $I2"
  [ "$BIO2" = "after_correction,after_correction" ] && [ "$I2" = 0 ] || I=$((I+1))
  echo "   [$ORDER] approval -> $A; day-1 live: $DAY; punches: $BIO; invariant violations $I; rerun changed: $([ "$S1" = "$S2" ] && echo no || echo yes)"
  [ "$A" = true ] && [ "$DAY" = "in:correction,out:correction" ] && [ "$I" = 0 ] && [ "$S1" = "$S2" ] && ok "9b. delayed pair vs correction approval ($ORDER): only the correction's in/out count, both punches are accounted for ($BIO, then after_correction), yesterday is closed, a rerun changes nothing" || bad "9b. $ORDER a=$A day=$DAY bio=$BIO inv=$I"
done

for d in proj_race_1 proj_race_2 proj_race_3 proj_race_4 proj_race_5 proj_race_6 proj_race_7 proj_race_8 proj_race_9; do dropdb --if-exists $d 2>/dev/null; done
echo "$PASS passed, $FAIL failed"
[ $FAIL = 0 ]
