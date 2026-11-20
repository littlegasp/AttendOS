-- AttendOS: permanently delete ONE company's data (owner only, SQL editor or psql, never from the app).
-- Follow docs/pilot/07-DATA-RETENTION.md first: written instruction, exports delivered, owner approval.
--
-- Two passes:
--   1. Dry run  — leave del.confirm as 'DRY RUN'. Shows what would be deleted; changes nothing.
--   2. Delete   — set del.confirm to exactly 'DELETE <slug>' and run again. Everything happens in one
--                 transaction: if any check fails, nothing is deleted.
-- Safety checks: the slug and the company id must both match the same company; every other company's row
-- counts (all 32 tables and their logins) are compared before and after, and the transaction is aborted if
-- any of them changed. Save the result grid (the deletion evidence) with the deletion record.
-- Note: tables are locked for a few seconds while this runs; run it in a quiet hour.

begin;
select set_config('del.slug',       'REPLACE_slug',        true),  -- e.g. 'pilot-co'
       set_config('del.company_id', 'REPLACE_company_id',  true),  -- the uuid shown by the dry run's first row
       set_config('del.confirm',    'DRY RUN',             true);  -- or 'DELETE <slug>'

create temp table deletion_report (ord int, item text, this_company bigint, other_companies_before bigint,
                                   other_companies_after bigint, note text) on commit drop;

do $$
declare
  v_slug text := lower(current_setting('del.slug'));
  v_id   text := current_setting('del.company_id');
  v_conf text := current_setting('del.confirm');
  cid uuid;
  t text;
  n_this bigint; n_other bigint;
  i int := 0;
  doit boolean;
  tables text[] := array['companies','employees','departments','designations','locations','shifts','holidays',
    'leave_types','leave_requests','leave_adjustments','attendance_events','attendance_coords','attendance_attempts',
    'attendance_corrections','roster_day','roster_pattern','shift_day','shift_pattern','remote_exceptions',
    'employee_invitations','audit_log',
    'biometric_event_state','biometric_event_reviews','biometric_event_errors','biometric_raw_events','biometric_sync_runs',
    'biometric_employee_mappings','biometric_devices','biometric_agent_credentials','biometric_agents','biometric_import_batches',
    'biometric_settings'];
  -- how each table reaches its company
  scope jsonb := jsonb_build_object(
    'companies', 'id = $1',
    'attendance_coords', 'event_id in (select e.id from public.attendance_events e join public.employees p on p.id = e.employee_id where p.company_id = $1)',
    'employees', 'company_id = $1', 'departments', 'company_id = $1', 'designations', 'company_id = $1',
    'locations', 'company_id = $1', 'shifts', 'company_id = $1', 'holidays', 'company_id = $1',
    'leave_types', 'company_id = $1', 'audit_log', 'company_id = $1',
    'biometric_event_state', 'company_id = $1', 'biometric_event_reviews', 'company_id = $1', 'biometric_event_errors', 'company_id = $1',
    'biometric_raw_events', 'company_id = $1', 'biometric_sync_runs', 'company_id = $1', 'biometric_employee_mappings', 'company_id = $1',
    'biometric_devices', 'company_id = $1', 'biometric_agent_credentials', 'company_id = $1', 'biometric_agents', 'company_id = $1',
    'biometric_import_batches', 'company_id = $1', 'biometric_settings', 'company_id = $1');
  cond text;
  logins uuid[];
begin
  if v_slug like 'replace%' then raise exception 'Fill in del.slug first'; end if;
  -- tables of modules not installed on this database (e.g. biometric before 0010) are skipped
  tables := array(select x from unnest(tables) x where to_regclass('public.' || x) is not null);
  select id into cid from public.companies where slug = v_slug;
  if cid is null then raise exception 'No company with the address "%"', v_slug; end if;
  doit := v_conf = 'DELETE ' || v_slug;
  if v_conf <> 'DRY RUN' and not doit then raise exception 'del.confirm must be ''DRY RUN'' or exactly ''DELETE %''', v_slug; end if;
  if doit and v_id <> cid::text then raise exception 'del.company_id does not match the company "%" (%)', v_slug, cid; end if;

  -- Logins that belong to this company: linked to its people, or not yet linked but using one of its work e-mails
  -- (e-mails are unique across AttendOS, so no other company can share them).
  select coalesce(array_agg(distinct u.id), '{}') into logins
    from auth.users u join public.employees e on e.company_id = cid and (e.user_id = u.id or lower(u.email) = lower(e.email));

  insert into deletion_report values (0, 'company', null, null, null,
    format('%s (%s), id %s — %s', (select name from public.companies where id = cid), v_slug, cid, case when doit then 'DELETING' else 'dry run: nothing changed' end));

  foreach t in array tables loop
    i := i + 1;
    cond := coalesce(scope ->> t, 'employee_id in (select id from public.employees where company_id = $1)');
    execute format('select count(*) from public.%I where %s', t, cond) into n_this using cid;
    execute format('select count(*) from public.%I', t) into n_other;
    insert into deletion_report values (i, t, n_this, n_other - n_this, null, null);
  end loop;
  insert into deletion_report values (100, 'auth.users (logins)', cardinality(logins),
    (select count(*) from auth.users) - cardinality(logins), null, 'Supabase Auth; sessions and identities go with them');

  if not doit then return; end if;

  -- Delete. Triggers that guard or audit single changes are switched off for these tables inside this
  -- transaction only (foreign keys stay on); they are switched back on before commit.
  foreach t in array tables loop execute format('alter table public.%I disable trigger user', t); end loop;

  update public.departments set head_id = null where company_id = cid;
  update public.employees set manager_id = null where company_id = cid;
  update public.companies set default_shift_id = null where id = cid;
  -- biometric (0010, when installed): children before parents; processing state first (it points at attendance events)
  if to_regclass('public.biometric_raw_events') is not null then
  delete from public.biometric_event_state where company_id = cid;
  delete from public.biometric_event_reviews where company_id = cid;
  delete from public.biometric_event_errors where company_id = cid;
  -- 0012: projected attendance rows point at raw events and devices (on delete restrict), so attendance goes first
  delete from public.attendance_coords where event_id in (select e.id from public.attendance_events e join public.employees p on p.id = e.employee_id where p.company_id = cid);
  delete from public.attendance_events where employee_id in (select id from public.employees where company_id = cid);
  delete from public.biometric_raw_events where company_id = cid;
  delete from public.biometric_sync_runs where company_id = cid;
  delete from public.biometric_employee_mappings where company_id = cid;
  delete from public.biometric_devices where company_id = cid;
  delete from public.biometric_agent_credentials where company_id = cid;
  delete from public.biometric_agents where company_id = cid;
  delete from public.biometric_import_batches where company_id = cid;
  delete from public.biometric_settings where company_id = cid;
  end if;
  delete from public.attendance_coords where event_id in (select e.id from public.attendance_events e join public.employees p on p.id = e.employee_id where p.company_id = cid);
  delete from public.attendance_events where employee_id in (select id from public.employees where company_id = cid);
  delete from public.attendance_attempts where employee_id in (select id from public.employees where company_id = cid);
  delete from public.attendance_corrections where employee_id in (select id from public.employees where company_id = cid);
  delete from public.leave_adjustments where employee_id in (select id from public.employees where company_id = cid);
  delete from public.leave_requests where employee_id in (select id from public.employees where company_id = cid);
  delete from public.remote_exceptions where employee_id in (select id from public.employees where company_id = cid);
  delete from public.roster_day where employee_id in (select id from public.employees where company_id = cid);
  delete from public.roster_pattern where employee_id in (select id from public.employees where company_id = cid);
  delete from public.shift_day where employee_id in (select id from public.employees where company_id = cid);
  delete from public.shift_pattern where employee_id in (select id from public.employees where company_id = cid);
  delete from public.employee_invitations where employee_id in (select id from public.employees where company_id = cid);
  delete from public.employees where company_id = cid;
  delete from public.departments where company_id = cid;
  delete from public.designations where company_id = cid;
  delete from public.holidays where company_id = cid;
  delete from public.leave_types where company_id = cid;
  delete from public.locations where company_id = cid;
  delete from public.shifts where company_id = cid;
  delete from public.audit_log where company_id = cid;
  delete from public.companies where id = cid;
  delete from auth.users where id = any(logins);

  foreach t in array tables loop execute format('alter table public.%I enable trigger user', t); end loop;

  -- Verify: nothing of this company is left, and no other company lost or gained a row.
  i := 0;
  foreach t in array tables loop
    i := i + 1;
    execute format('select count(*) from public.%I', t) into n_other;
    update deletion_report set other_companies_after = n_other where ord = i;
  end loop;
  update deletion_report set other_companies_after = (select count(*) from auth.users) where ord = 100;
  if exists (select 1 from deletion_report where ord > 0 and other_companies_after is distinct from other_companies_before) then
    raise exception 'Another company''s data changed — nothing has been deleted (transaction rolled back)';
  end if;
  if exists (select 1 from public.employees where company_id = cid) or exists (select 1 from public.companies where id = cid) then
    raise exception 'Company rows remain — nothing has been deleted (transaction rolled back)';
  end if;
  update deletion_report set note = 'deleted' where ord between 1 and 100;
  insert into deletion_report values (101, 'completed at', null, null, null, to_char(now() at time zone 'Asia/Kolkata', 'DD-Mon-YYYY HH24:MI:SS "IST"'));
end $$;

select item, this_company as "rows of this company", other_companies_before as "other companies (before)",
       other_companies_after as "other companies (after)", note
  from deletion_report order by ord;
commit;
