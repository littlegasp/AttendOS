-- AttendOS: remove migration 0013 (B5 DAT import) from the DEVELOPMENT Supabase project ONLY, returning the schema to
-- exactly the state 0012 left. For a hosted-only defect found during the development preflight (plan §6.2).
--
--   python3 dev_sql.py rollback_0013_dev_only.sql -v confirm=REMOVE-0013-FROM-DEVELOPMENT
--
-- NEVER for a company, pilot or production database: there the rule is to roll forward with a new migration.
-- Protection (all must pass, or nothing happens — one transaction):
--   1. psql variables dev_ref and confirm must be given (pasting this into a SQL editor fails on the first line);
--   2. the database must carry the AttendOS development marker for exactly dev_ref (dev_guard.sql, and again here);
--   3. confirm must be exactly REMOVE-0013-FROM-DEVELOPMENT;
--   4. no raw biometric event or attendance row may reference a DAT import batch (they never should);
--   5. the database may hold ONLY the synthetic seed: companies dev-alpha / dev-beta and employees at the reserved
--      domain attendos-dev.example. Any other company or employee (a real company database, even one wrongly
--      marked) stops it. This check does not depend on the marker.
-- What it removes: the 0013 functions, the four DAT tables, the columns/indexes/trigger 0013 added to
-- biometric_import_batches, and every DAT batch row (synthetic test data). It restores the 0010 unique constraint,
-- company_refs trigger, read policy and SELECT grant. audit_log entries written by 0013 stay (append-only by design).
\if :{?dev_ref}
\else
select stop_dev_ref_not_set;
\endif
\if :{?confirm}
\else
select stop_confirm_not_set;
\endif
select set_config('attendos.dev_ref', :'dev_ref', false) is not null as dev_ref_received,
       set_config('attendos.rollback_confirm', :'confirm', false) is not null as confirm_received;
do $$
declare m record;
begin
  if to_regclass('attendos_dev.environment_marker') is null then
    raise exception 'STOP: no AttendOS development marker — this is not the development project; nothing was changed';
  end if;
  select * into m from attendos_dev.environment_marker;
  if m.environment <> 'development' or m.project_ref is distinct from current_setting('attendos.dev_ref', true) then
    raise exception 'STOP: the marker is for project %, not %; nothing was changed', m.project_ref, current_setting('attendos.dev_ref', true);
  end if;
  if current_setting('attendos.rollback_confirm') <> 'REMOVE-0013-FROM-DEVELOPMENT' then
    raise exception 'STOP: confirm must be exactly REMOVE-0013-FROM-DEVELOPMENT; nothing was changed';
  end if;
  if to_regclass('public.biometric_import_rows') is null then
    raise exception 'STOP: 0013 is not installed; nothing to remove';
  end if;
  if exists (select 1 from public.companies where slug not in ('dev-alpha', 'dev-beta'))
     or exists (select 1 from public.employees where email is null or email not like '%@attendos-dev.example') then
    raise exception 'STOP: this database holds a company or employee that is not the synthetic development seed — it may be a company database; nothing was changed';
  end if;
  if exists (select 1 from public.biometric_raw_events r join public.biometric_import_batches b on b.id = r.import_batch_id where b.state <> 'legacy')
     or exists (select 1 from public.attendance_events a join public.biometric_import_batches b on b.id = a.import_batch_id where b.state <> 'legacy') then
    raise exception 'STOP: a raw event or attendance row references a DAT import batch — must never happen; report it; nothing was changed';
  end if;
end $$;

-- 1. functions added by 0013 (all named biometric_dat_*; no earlier migration uses that prefix)
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'biometric\_dat\_%' loop
    execute format('drop function %s', f.sig);
  end loop;
end $$;

-- 2. DAT batch rows (synthetic); their chunks, files and rows go with them (on delete cascade)
delete from public.biometric_import_batches where state <> 'legacy';

-- 3. the four tables 0013 created
drop table public.biometric_import_rows;
drop table public.biometric_import_files;
drop table public.biometric_import_chunks;
drop table public.biometric_device_import_formats;

-- 4. biometric_import_batches back to its 0010 shape (dropping the columns also drops the 0013 indexes, the source
--    device foreign key and the chunk-count check that depend on them)
drop trigger company_refs on public.biometric_import_batches;
alter table public.biometric_import_batches
  drop column source_device_id, drop column device_model, drop column device_firmware, drop column declared_timezone,
  drop column declared_size, drop column chunk_count, drop column chunk_hashes, drop column format_version,
  drop column upload_token_hash, drop column state, drop column next_chunk, drop column progress_line, drop column line_count,
  drop column bom, drop column final_terminator, drop column fail_reason, drop column fail_line, drop column counts,
  drop column last_activity_at, drop column ready_at, drop column reviewed_by, drop column reviewed_at, drop column deleted_by,
  drop column deleted_at, drop column delete_reason, drop column ended_at, drop column purge_pending, drop column version;
alter table public.biometric_import_batches add constraint biometric_import_batches_company_id_file_sha256_key unique (company_id, file_sha256);
create trigger company_refs before insert or update on public.biometric_import_batches
  for each row execute function public.check_company_refs('uploaded_by:employees', 'approved_by:employees');
create policy bio_read on public.biometric_import_batches for select to authenticated using (company_id = public.my_company() and public.is_hr());
grant select on public.biometric_import_batches to authenticated;

-- 5. proof inside the same transaction: nothing of 0013 is left
do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'biometric\_dat\_%')
     or to_regclass('public.biometric_import_rows') is not null or to_regclass('public.biometric_device_import_formats') is not null
     or exists (select 1 from pg_attribute where attrelid = 'public.biometric_import_batches'::regclass and attname = 'state' and not attisdropped) then
    raise exception 'STOP: 0013 objects remain after removal; rolled back';
  end if;
end $$;
-- the record of what was applied: 0013 is no longer applied on this development project
delete from attendos_dev.applied_migrations where file = '0013_biometric_dat_import.sql';
select 'removed 0013 from the development project' as result;
