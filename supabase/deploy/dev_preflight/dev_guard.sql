-- AttendOS development-Supabase preflight: database-side guard. Prepended to EVERY hosted script by dev_sql.py /
-- dev_apply_migrations.py, inside the same transaction. It stops (and nothing after it runs) unless the database
-- carries the AttendOS development marker for exactly the project reference given as psql variable dev_ref.
-- Pasting it into the SQL editor without psql fails on purpose (:'dev_ref' is psql syntax).
\set ON_ERROR_STOP on
\if :{?dev_ref}
\else
\echo 'STOP: dev_ref is not set. Run hosted scripts only through dev_sql.py / dev_apply_migrations.py.'
select stop_dev_ref_not_set;
\endif
select set_config('attendos.dev_ref', :'dev_ref', false) is not null as dev_ref_received;
do $$
declare want text := current_setting('attendos.dev_ref', true); n int; m record;
begin
  if want is null or want !~ '^[a-z]{20}$' then
    raise exception 'STOP: invalid development project reference';
  end if;
  if to_regclass('attendos_dev.environment_marker') is null then
    raise exception 'STOP: this database has no AttendOS development marker — it is not the development project';
  end if;
  select count(*) into n from attendos_dev.environment_marker;
  if n <> 1 then raise exception 'STOP: the development marker is damaged (% rows)', n; end if;
  select * into m from attendos_dev.environment_marker;
  if m.environment <> 'development' or m.project_ref <> want then
    raise exception 'STOP: this database is marked for project % (%), not %', m.project_ref, m.environment, want;
  end if;
  raise notice 'guard ok: AttendOS development project %', want;
end $$;
