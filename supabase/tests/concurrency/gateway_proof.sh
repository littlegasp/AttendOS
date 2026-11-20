#!/bin/sh
# Concurrency proofs for the 0011 gateway with real biometric_ingest calls in parallel database sessions
# (run after supabase/tests/run.sh; each scenario on a throwaway copy of the test database).
# Usage: PGHOST=/tmp/pg PGPORT=5433 PGUSER=postgres sh supabase/tests/concurrency/gateway_proof.sh
set -e
cd "$(dirname "$0")"
HR=00000000-0000-0000-0000-00000000000b
ADMIN=00000000-0000-0000-0000-00000000000a
PASS=0; FAIL=0
ok() { echo "ok - $1"; PASS=$((PASS+1)); }
bad() { echo "FAILED - $1"; FAIL=$((FAIL+1)); }
q() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
anon() { { echo "set role anon;"; echo "$2"; } | psql -X -q -At -d "$1" 2>&1; }
hr() { { echo "set role authenticated; select set_config('request.jwt.claim.sub', '$HR', false);"; echo "$2"; } | psql -X -q -At -d "$1" 2>&1; }
invariant() {
  q $1 "select (select count(*) from biometric_event_state s join biometric_raw_events r on r.id = s.raw_event_id join biometric_employee_mappings m on m.id = s.mapping_id
                 where r.punch_at < m.valid_from or (m.valid_to is not null and r.punch_at >= m.valid_to))
              + (select coalesce(sum((biometric_reassigned_count(c.company_id, c.code)).n), 0) from (select distinct company_id, employee_device_code code from biometric_raw_events) c)"
}
fresh() {
  dropdb --if-exists "$1"; createdb -T attendos_test "$1"
  # an event builder for the shell (throwaway copy only)
  q $1 "create function public.gw_ev(code text, mins_ago int, seq bigint) returns jsonb language sql as \$\$
          select jsonb_build_object('manufacturer', 'zkteco', 'serial', 'ZK001', 'employee_code', code, 'record_seq', seq,
                   'local_time', to_char(date_trunc('minute', now()) at time zone 'Asia/Kolkata' - make_interval(mins => mins_ago), 'YYYY-MM-DD HH24:MI:SS')) \$\$;
        grant execute on function public.gw_ev(text, int, bigint) to anon;
        update biometric_agents set ingest_window_start = null, ingest_window_count = 0;" > /dev/null
  KEY=$( { echo "set role authenticated; select set_config('request.jwt.claim.sub', '$ADMIN', false);";
           echo "select biometric_rotate_agent_key(id) ->> 'agent_key' from biometric_agents where agent_identifier = 'office-pc-01';"; } | psql -X -q -At -d $1 | tail -1)
  DV=$(q $1 "select id from biometric_devices where serial_number = 'ZK001' and agent_id = (select id from biometric_agents where agent_identifier = 'office-pc-01')")
  P1=$(q $1 "select e.id from employees e where e.company_id = (select company_id from biometric_devices where id = '$DV') and e.active and not exists (select 1 from biometric_employee_mappings m where m.employee_id = e.id and m.device_id = '$DV') order by e.email limit 1")
  P2=$(q $1 "select e.id from employees e where e.company_id = (select company_id from biometric_devices where id = '$DV') and e.active and not exists (select 1 from biometric_employee_mappings m where m.employee_id = e.id and m.device_id = '$DV') order by e.email offset 1 limit 1")
}

# G1. the same batch sent twice at the same moment (agent retry while the first is still in flight)
DB=gw_replay; fresh $DB
BATCH=$(q $DB "select jsonb_build_object('batch_id', gen_random_uuid(), 'events', jsonb_build_array(gw_ev('0101', 15, 91001), gw_ev('4242', 14, 91002)))")
( anon $DB "begin; select biometric_ingest('$KEY', '$BATCH') ->> 'stored'; select pg_sleep(2); commit;" > /tmp/gw1a.txt ) &
sleep 0.5; START=$(date +%s.%N)
R=$(anon $DB "select biometric_ingest('$KEY', '$BATCH')" | tail -1)
WAIT=$(echo "$(date +%s.%N) - $START" | bc); wait
N=$(q $DB "select count(*) from biometric_raw_events where record_seq in (91001, 91002)")
RUNS=$(q $DB "select count(*) from biometric_sync_runs where batch_id = ('$BATCH'::jsonb ->> 'batch_id')::uuid")
SAME=$(q $DB "select (response || '{\"replay\": true}') = '$R'::jsonb from biometric_sync_runs where batch_id = ('$BATCH'::jsonb ->> 'batch_id')::uuid")
echo "   same batch twice: second call waited ${WAIT}s; raw rows $N; sync runs $RUNS; second answer = stored answer + replay: $SAME"
[ "$N" = 2 ] && [ "$RUNS" = 1 ] && [ "$SAME" = t ] && ok "concurrent replay: stored once, the second call returned the first call's stored answer" || bad "replay N=$N runs=$RUNS same=$SAME"

# G2. two different batches carrying the same punches at the same moment
B1=$(q $DB "select jsonb_build_object('batch_id', gen_random_uuid(), 'events', jsonb_build_array(gw_ev('0101', 25, 92001), gw_ev('0101', 24, 92002)))")
B2=$(q $DB "select jsonb_build_object('batch_id', gen_random_uuid(), 'events', jsonb_build_array(gw_ev('0101', 25, 92001), gw_ev('0101', 24, 92002)))")
( anon $DB "begin; select biometric_ingest('$KEY', '$B1') ->> 'stored'; select pg_sleep(2); commit;" > /tmp/gw2a.txt ) &
sleep 0.5
R=$(anon $DB "select biometric_ingest('$KEY', '$B2') ->> 'confirmed_duplicates'" | tail -1); wait
N=$(q $DB "select count(*) from biometric_raw_events where record_seq in (92001, 92002)")
[ "$N" = 2 ] && [ "$R" = 2 ] && ok "overlapping batches: punches stored once, the later batch reports 2 confirmed duplicates" || bad "overlap N=$N dup=$R"

# G3. a batch in flight while HR ends the mapping before its punch
DB=gw_end; fresh $DB
M=$(hr $DB "select biometric_save_mapping('GW1', '$DV', '$P1', now() - interval '1 day') ->> 'mapping_id';" | tail -1)
B=$(q $DB "select jsonb_build_object('batch_id', gen_random_uuid(), 'events', jsonb_build_array(gw_ev('GW1', 10, 93001)))")
( anon $DB "begin; select biometric_ingest('$KEY', '$B') ->> 'stored'; select pg_sleep(2); commit;" > /tmp/gw3a.txt ) &
sleep 0.5; START=$(date +%s.%N)
R=$(hr $DB "select biometric_end_mapping('$M', now() - interval '20 minutes', 'Left the company') ->> 'message';" | tail -1)
WAIT=$(echo "$(date +%s.%N) - $START" | bc); wait
INV=$(invariant $DB); ST=$(q $DB "select s.status || '/' || (s.mapping_id = '$M') from biometric_event_state s join biometric_raw_events r on r.id = s.raw_event_id where r.record_seq = 93001")
echo "   batch in flight vs end-mapping: end waited ${WAIT}s -> '$R'; punch $ST; invariant violations $INV"
case "$R" in *"already processed"*) [ "$INV" = 0 ] && [ "$ST" = "stored/true" ] && [ "$(echo "$WAIT > 1.0" | bc)" = 1 ] && ok "end-mapping waited for the in-flight batch, then refused to move its punch" || bad "G3 inv=$INV st=$ST";; *) bad "G3 '$R'";; esac

# G4. HR saves a back-dated mapping while a batch with that code arrives
DB=gw_map; fresh $DB
B=$(q $DB "select jsonb_build_object('batch_id', gen_random_uuid(), 'events', jsonb_build_array(gw_ev('GW2', 60, 94001)))")
( hr $DB "begin; select biometric_save_mapping('GW2', '$DV', '$P2', now() - interval '3 hours') ->> 'ok'; select pg_sleep(2); commit;" > /tmp/gw4a.txt ) &
sleep 0.5; START=$(date +%s.%N)
R=$(anon $DB "select biometric_ingest('$KEY', '$B') -> 'outcomes' -> 0 ->> 'status'" | tail -1)
WAIT=$(echo "$(date +%s.%N) - $START" | bc); wait
INV=$(invariant $DB); EMP=$(q $DB "select s.employee_id = '$P2' from biometric_event_state s join biometric_raw_events r on r.id = s.raw_event_id where r.record_seq = 94001")
echo "   mapping in progress vs batch: batch waited ${WAIT}s -> status '$R'; attributed to the new mapping: $EMP; invariant violations $INV"
[ "$R" = stored ] && [ "$EMP" = t ] && [ "$INV" = 0 ] && [ "$(echo "$WAIT > 1.0" | bc)" = 1 ] && ok "the batch waited for the mapping change and attributed its punch with the committed mapping" || bad "G4 r=$R emp=$EMP inv=$INV"

# G5. 40 batches from one agent at once: exactly 30 accepted in the window, 10 throttled
DB=gw_throttle; fresh $DB
T0=$(q $DB "select clock_timestamp()")
for i in $(seq 1 40); do ( anon $DB "select biometric_ingest('$KEY', jsonb_build_object('batch_id', gen_random_uuid(), 'events', '[]'::jsonb)) ->> 'code'" | tail -1 > /tmp/gw5_$i.txt ) & done; wait
OKN=$(cat /tmp/gw5_*.txt | grep -c '^$' || true); TH=$(cat /tmp/gw5_*.txt | grep -c throttled || true)
RUNS=$(q $DB "select count(*) from biometric_sync_runs where agent_id = (select id from biometric_agents where agent_identifier = 'office-pc-01') and started_at > '$T0'")
rm -f /tmp/gw5_*.txt
[ "$OKN" = 30 ] && [ "$TH" = 10 ] && [ "$RUNS" = 30 ] && ok "40 simultaneous batches: 30 accepted, 10 throttled (the per-agent lock makes the count exact)" || bad "throttle ok=$OKN throttled=$TH runs=$RUNS"

# G6. no deadlock: batches with codes in different orders + a mapping change + a review, 5 rounds in parallel
DB=gw_deadlock; fresh $DB
hr $DB "select biometric_save_mapping('DA', '$DV', '$P1', now() - interval '2 days');" > /dev/null
DL=0; ERRS=0
for i in 1 2 3 4 5; do
  q $DB "update biometric_agents set ingest_window_start = null, ingest_window_count = 0" > /dev/null
  Z=$(anon $DB "select biometric_ingest('$KEY', jsonb_build_object('batch_id', gen_random_uuid(), 'events', jsonb_build_array(gw_ev('DA', 300 + $i, 95000 + $i * 10)))) -> 'outcomes' -> 0 ->> 'raw_event_id'" | tail -1)
  q $DB "update biometric_event_state set status = 'flagged' where raw_event_id = $Z" > /dev/null
  ( anon $DB "select biometric_ingest('$KEY', jsonb_build_object('batch_id', gen_random_uuid(), 'events', jsonb_build_array(gw_ev('DB', $i, 95001 + $i * 10), gw_ev('DA', $i, 95002 + $i * 10))))" > /tmp/gw6a.txt ) &
  ( anon $DB "select biometric_ingest('$KEY', jsonb_build_object('batch_id', gen_random_uuid(), 'events', jsonb_build_array(gw_ev('DA', 100 + $i, 95003 + $i * 10), gw_ev('DB', 100 + $i, 95004 + $i * 10))))" > /tmp/gw6b.txt ) &
  ( hr $DB "select biometric_save_mapping('DB', '$DV', '$P2', now() - interval '$i hours') ->> 'ok';" > /tmp/gw6c.txt ) &
  ( hr $DB "select biometric_review_event($Z, 'dismiss', 'Deadlock round test', 1) ->> 'ok';" > /tmp/gw6d.txt ) &
  wait
  cat /tmp/gw6?.txt | grep -qi deadlock && DL=$((DL+1))
  cat /tmp/gw6a.txt /tmp/gw6b.txt | grep -q '"ok": true' || ERRS=$((ERRS+1))
  hr $DB "select biometric_end_mapping(id, now(), 'reset for next round') from biometric_employee_mappings where employee_device_code = 'DB' and valid_to is null;" > /dev/null
done
INV=$(invariant $DB)
[ "$DL" = 0 ] && [ "$ERRS" = 0 ] && [ "$INV" = 0 ] && ok "5 rounds of crossing batches + mapping change + review: no deadlock, batches succeeded, attribution consistent" || bad "deadlocks=$DL errors=$ERRS inv=$INV"

for d in gw_replay gw_end gw_map gw_throttle gw_deadlock; do dropdb --if-exists $d; done
echo "$PASS passed, $FAIL failed"
[ $FAIL = 0 ]
