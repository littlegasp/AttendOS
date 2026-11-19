\set ON_ERROR_STOP on
-- Security matrix (stabilisation pass). Runs last. Checks the whole schema from the catalog, then every table and
-- callable function for Admin, HR, Manager and Employee of company A against company B (and B against A).
reset role; select pg_temp.as_user('');

-- ================================================================ 1. catalog rules (apply to tables added later too)
select pg_temp.expect(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity), 'row level security is on for every table');
select pg_temp.expect(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('anon', c.oid, 'insert')
    or has_table_privilege('anon', c.oid, 'update') or has_table_privilege('anon', c.oid, 'delete'))), 'anonymous visitors have no access to any table');
select pg_temp.expect((select array_agg(c.relname::text order by c.relname) from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and has_table_privilege('authenticated', c.oid, 'delete'))
  = array['holidays', 'remote_exceptions', 'roster_day', 'roster_pattern', 'shift_day', 'shift_pattern'],
  'hard delete exists only for holidays, exceptions and roster/shift entries (people, leave, attendance, audit are never deleted)');
select pg_temp.expect(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and c.relname in ('attendance_events', 'attendance_attempts', 'attendance_coords', 'attendance_corrections',
    'leave_requests', 'leave_adjustments', 'audit_log', 'employee_invitations')
    and (has_table_privilege('authenticated', c.oid, 'insert') or has_table_privilege('authenticated', c.oid, 'update'))),
  'attendance, corrections, leave, audit and invitations change only through checked functions');
select pg_temp.expect((select array_agg(p.proname::text) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')) = array['company_brand'], 'anonymous visitors can call only company_brand (sign-in page name)');
select pg_temp.expect(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0))), 'no function is callable by PUBLIC by default');
select pg_temp.expect(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef and not exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%')),
  'every SECURITY DEFINER function pins its search_path');
do $$ declare r record; begin
  for r in select p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute') order by 1 loop
    raise notice 'callable by signed-in users: %', r.f;
  end loop; end $$;

-- ================================================================ 2. test data in both companies
select set_config('test.ca', (select company_id::text from employees where id = '00000000-0000-0000-0000-00000000000a'), false);
select set_config('test.cb', (select company_id::text from employees where email = 'owner@beta.co'), false);
select set_config('test.ea', (select string_agg(id::text, ',') from employees where company_id = current_setting('test.ca')::uuid), false);
select set_config('test.eb', (select string_agg(id::text, ',') from employees where company_id = current_setting('test.cb')::uuid), false);
select set_config('test.ben', (select id::text from employees where email = 'ben@beta.co'), false);
-- B gets one of everything A has, so every table holds rows of both companies
insert into leave_requests (employee_id, leave_type_id, start_date, end_date, days, reason, status, requested_by)
  select current_setting('test.ben')::uuid, id, current_date + 30, current_date + 30, 1, 'B leave', 'pending', current_setting('test.ben')::uuid
    from leave_types where company_id = current_setting('test.cb')::uuid and code = 'CL';
insert into leave_adjustments (employee_id, leave_type_id, year_start, days, reason, created_by)
  select current_setting('test.ben')::uuid, id, date_trunc('year', current_date)::date, 1, 'B adj', current_setting('test.ben')::uuid from leave_types where company_id = current_setting('test.cb')::uuid and code = 'CL';
insert into attendance_corrections (employee_id, work_date, kind, requested_in, reason, requested_by)
  values (current_setting('test.ben')::uuid, current_date - 1, 'missing_in', now() - interval '1 day', 'B correction', current_setting('test.ben')::uuid);
insert into holidays (company_id, day, name) values (current_setting('test.cb')::uuid, current_date + 40, 'B holiday');
insert into shifts (company_id, name, start_time, end_time) values (current_setting('test.cb')::uuid, 'B day', '09:00', '18:00');
insert into designations (company_id, name) values (current_setting('test.cb')::uuid, 'B Driver');
insert into remote_exceptions (employee_id, start_date, end_date, reason) values (current_setting('test.ben')::uuid, current_date + 5, current_date + 6, 'B trip');
insert into roster_day (employee_id, day, work_mode) values (current_setting('test.ben')::uuid, current_date + 7, 'remote');
insert into employee_invitations (employee_id, email, invited_by) select id, email, id from employees where email = 'wes@beta.co';
select pg_temp.expect((select count(distinct emp_company(employee_id)) from leave_requests) = 2 and (select count(distinct company_id) from audit_log) >= 2
  and (select count(distinct emp_company(employee_id)) from attendance_events) = 2, 'both companies have leave, audit and attendance rows');
select set_config('test.evb', (select coalesce(string_agg(id::text, ','), '0') from attendance_events where employee_id::text = any(string_to_array(current_setting('test.eb'), ','))), false);
select set_config('test.eva', (select coalesce(string_agg(id::text, ','), '0') from attendance_events where employee_id::text = any(string_to_array(current_setting('test.ea'), ','))), false);

-- ================================================================ 3. reads: nobody sees the other company's rows, in any table
create function pg_temp.foreign_rows(other_company text, other_emps text, other_events text) returns text language plpgsql as $$
declare t record; n bigint; bad text := '';
begin
  for t in select c.relname,
                  exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'company_id' and not a.attisdropped) has_c,
                  exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'employee_id' and not a.attisdropped) has_e,
                  exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'event_id' and not a.attisdropped) has_v
             from pg_class c join pg_namespace s on s.oid = c.relnamespace where s.nspname = 'public' and c.relkind = 'r' loop
    if t.relname = 'companies' then execute 'select count(*) from public.companies where id::text = $1' into n using other_company;
    elsif t.has_c then execute format('select count(*) from public.%I where company_id::text = $1', t.relname) into n using other_company;
    elsif t.has_e then execute format('select count(*) from public.%I where employee_id::text = any(string_to_array($1, '',''))', t.relname) into n using other_emps;
    elsif t.has_v then execute format('select count(*) from public.%I where event_id::text = any(string_to_array($1, '',''))', t.relname) into n using other_events;
    else bad := bad || ' ' || t.relname || '(no company column)'; continue; end if;
    if n > 0 then bad := bad || ' ' || t.relname || '=' || n; end if;
  end loop;
  return bad;
end $$;
grant execute on function pg_temp.foreign_rows(text, text, text) to authenticated;
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select pg_temp.expect(pg_temp.foreign_rows(current_setting('test.cb'), current_setting('test.eb'), current_setting('test.evb')) = '', 'A Admin: no B rows in any of the ' || (select count(*) from pg_tables where schemaname = 'public') || ' tables');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select pg_temp.expect(pg_temp.foreign_rows(current_setting('test.cb'), current_setting('test.eb'), current_setting('test.evb')) = '', 'A HR: no B rows in any table');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select pg_temp.expect(pg_temp.foreign_rows(current_setting('test.cb'), current_setting('test.eb'), current_setting('test.evb')) = '', 'A Manager: no B rows in any table');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select pg_temp.expect(pg_temp.foreign_rows(current_setting('test.cb'), current_setting('test.eb'), current_setting('test.evb')) = '', 'A Employee: no B rows in any table');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b0');
select pg_temp.expect(pg_temp.foreign_rows(current_setting('test.ca'), current_setting('test.ea'), current_setting('test.eva')) = '', 'B Admin: no A rows in any table');
select pg_temp.as_user(current_setting('test.ben'));
select pg_temp.as_user((select '00000000-0000-0000-0000-0000000000b1'));
select pg_temp.expect(pg_temp.foreign_rows(current_setting('test.ca'), current_setting('test.ea'), current_setting('test.eva')) = '', 'B Employee: no A rows in any table');

-- ================================================================ 4. writes: updates and deletes of the other company's rows touch nothing
create function pg_temp.foreign_writes(other_company text, other_emps text) returns text language plpgsql as $$
declare t record; n bigint; bad text := ''; q text;
begin
  for t in select c.relname, exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'company_id') has_c,
                  has_table_privilege('authenticated', c.oid, 'update') can_upd, has_table_privilege('authenticated', c.oid, 'delete') can_del
             from pg_class c join pg_namespace s on s.oid = c.relnamespace
            where s.nspname = 'public' and c.relkind = 'r' and c.relname <> 'companies' loop
    q := case when t.has_c then 'company_id::text = $1' else 'employee_id::text = any(string_to_array($2, '',''))' end;
    if t.can_upd then
      begin
        execute format('update public.%I set %s where %s', t.relname, case when t.has_c then 'company_id = company_id' else 'employee_id = employee_id' end, q) using other_company, other_emps;
        get diagnostics n = row_count;
        if n > 0 then bad := bad || ' update ' || t.relname || '=' || n; end if;
      exception when insufficient_privilege or raise_exception then null; end;
    end if;
    if t.can_del then
      begin
        execute format('delete from public.%I where %s', t.relname, q) using other_company, other_emps;
        get diagnostics n = row_count;
        if n > 0 then bad := bad || ' delete ' || t.relname || '=' || n; end if;
      exception when insufficient_privilege or raise_exception then null; end;
    end if;
  end loop;
  update public.companies set name = name where id::text = other_company;
  get diagnostics n = row_count;
  if n > 0 then bad := bad || ' update companies'; end if;
  return bad;
end $$;
grant execute on function pg_temp.foreign_writes(text, text) to authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000a');
select pg_temp.expect(pg_temp.foreign_writes(current_setting('test.cb'), current_setting('test.eb')) = '', 'A Admin cannot update or delete any B row');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select pg_temp.expect(pg_temp.foreign_writes(current_setting('test.cb'), current_setting('test.eb')) = '', 'A HR cannot update or delete any B row');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b0');
select pg_temp.expect(pg_temp.foreign_writes(current_setting('test.ca'), current_setting('test.ea')) = '', 'B Admin cannot update or delete any A row');

-- Inserts pointing at the other company are refused, table by table
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
do $$ declare stmts text[] := array[
  format('insert into public.locations (company_id, name, lat, lng, radius_m) values (%L, ''X'', 1, 1, 100)', current_setting('test.cb')),
  format('insert into public.departments (company_id, name) values (%L, ''X dept'')', current_setting('test.cb')),
  format('insert into public.designations (company_id, name) values (%L, ''X desig'')', current_setting('test.cb')),
  format('insert into public.shifts (company_id, name, start_time, end_time) values (%L, ''X'', ''09:00'', ''17:00'')', current_setting('test.cb')),
  format('insert into public.holidays (company_id, day, name) values (%L, current_date + 50, ''X'')', current_setting('test.cb')),
  format('insert into public.leave_types (company_id, name, code) values (%L, ''X type'', ''XT'')', current_setting('test.cb')),
  format('insert into public.employees (company_id, full_name, email) values (%L, ''X Person'', ''x.person@beta.co'')', current_setting('test.cb')),
  format('insert into public.roster_day (employee_id, day, work_mode) values (%L, current_date + 9, ''off'')', current_setting('test.ben')),
  format('insert into public.roster_pattern (employee_id, weekday, work_mode) values (%L, 3, ''off'')', current_setting('test.ben')),
  format('insert into public.shift_day (employee_id, day, shift_id) values (%L, current_date + 9, null)', current_setting('test.ben')),
  format('insert into public.shift_pattern (employee_id, weekday, shift_id) values (%L, 3, null)', current_setting('test.ben')),
  format('insert into public.remote_exceptions (employee_id, start_date, end_date, reason) values (%L, current_date + 9, current_date + 9, ''X'')', current_setting('test.ben'))];
  s text; ok int := 0;
begin
  foreach s in array stmts loop
    begin execute s; raise exception 'FAILED: allowed: %', s;
    exception when insufficient_privilege or not_null_violation or check_violation then ok := ok + 1; end;
  end loop;
  raise notice 'ok - % cross-company inserts refused (offices, departments, designations, shifts, holidays, leave types, employees, roster, shifts per day/week, exceptions)', ok;
end $$;

-- ================================================================ 5. functions: other-company ids give an error or nothing
do $$ declare
  ben uuid := current_setting('test.ben')::uuid;
  bl bigint := (select id from public.leave_requests where employee_id = current_setting('test.ben')::uuid limit 1);
  bc bigint := (select id from public.attendance_corrections where employee_id = current_setting('test.ben')::uuid limit 1);
  btype uuid := (select id from public.leave_types limit 1);
  calls text[] := array[
    format('select public.attendance_history(%L, current_date - 3, current_date)', ben),
    format('select public.leave_balance_view(%L)', ben),
    format('select public.leave_preview(%L, current_date + 1, current_date + 1, null, %L)', btype, ben),
    format('select public.apply_leave(%L, current_date + 60, current_date + 60, null, ''x'', %L)', btype, ben),
    format('select public.adjust_leave(%L, %L, 1, ''xx'')', ben, btype),
    format('select public.decide_leave(%s, true)', coalesce(bl, 0)),
    format('select public.cancel_leave(%s)', coalesce(bl, 0)),
    format('select public.decide_correction(%s, true, null)', coalesce(bc, 0)),
    format('select public.prepare_invitation(%L)', ben),
    format('select public.set_roster_pattern(array[%L]::uuid[], ''[{"weekday":1,"work_mode":"off"}]'')', ben),
    format('select public.set_shift_pattern(array[%L]::uuid[], ''[]'')', ben)];
  s text; ok int := 0;
begin
  foreach s in array calls loop
    begin execute s; raise exception 'FAILED: allowed: %', s;
    exception when insufficient_privilege or raise_exception or check_violation or not_null_violation then
      if sqlerrm like 'FAILED%' then raise; end if; ok := ok + 1; end;
  end loop;
  raise notice 'ok - % functions refuse company B ids for A HR (history, balance, preview, apply, adjust, decide, cancel, corrections, invite, roster, shifts)', ok;
end $$;
select pg_temp.expect((select count(*) from attendance_register(current_date - 6, current_date, null, current_setting('test.ben')::uuid, null, null, 5000)) = 0
  and (select count(*) from report_people(current_date - 6, current_date, null, current_setting('test.ben')::uuid)) = 0
  and (select count(*) from attendance_register(current_date - 6, current_date, (select department_id from employees where email = 'ben@beta.co' and false), null, null, null, 5000)) >= 0
  and (select count(*) from leave_list(current_date - 400, current_date + 400) where employee_id = current_setting('test.ben')::uuid) = 0,
  'register, reports and leave list return nothing for a B employee');
select pg_temp.expect(company_tz(current_setting('test.cb')::uuid) is null and company_tz(my_company()) = 'Asia/Kolkata', 'time-zone lookup answers only for the own company');
select pg_temp.expect(not exists (select 1 from people_directory() where id::text = any(string_to_array(current_setting('test.eb'), ','))), 'people pickers list no B people');
select pg_temp.expect(position('Ben Staff' in dashboard_summary()::text) = 0, 'dashboard holds no B names');

-- ================================================================ 6. inside company A: each role sees exactly its scope
reset role; select pg_temp.as_user('');
select set_config('test.team', (select string_agg(id::text, ',') from employees where id = '00000000-0000-0000-0000-00000000000c' or manager_id = '00000000-0000-0000-0000-00000000000c'), false);
select set_config('test.n_ev_a', (select count(*)::text from attendance_events where employee_id::text = any(string_to_array(current_setting('test.ea'), ','))), false);
select set_config('test.n_ev_team', (select count(*)::text from attendance_events where employee_id::text = any(string_to_array(current_setting('test.team'), ','))), false);
select set_config('test.n_ev_d', (select count(*)::text from attendance_events where employee_id = '00000000-0000-0000-0000-00000000000d'), false);
select set_config('test.n_co_d', (select count(*)::text from attendance_coords c join attendance_events e on e.id = c.event_id where e.employee_id = '00000000-0000-0000-0000-00000000000d'), false);
select set_config('test.n_lr_team', (select count(*)::text from leave_requests where employee_id::text = any(string_to_array(current_setting('test.team'), ','))), false);
set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');
select pg_temp.expect((select count(*) from attendance_events) = current_setting('test.n_ev_a')::bigint, 'HR sees all of A''s attendance');
select pg_temp.expect((select count(*) from attendance_coords) > 0, 'HR can read exact coordinates (HR-only table)');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000c');
select pg_temp.expect((select count(*) from attendance_events) = current_setting('test.n_ev_team')::bigint, 'a Manager sees exactly their team''s attendance');
select pg_temp.expect((select count(*) from leave_requests) = current_setting('test.n_lr_team')::bigint, 'a Manager sees exactly their team''s leave');
select pg_temp.expect((select count(*) from attendance_coords) = 0 and (select count(*) from audit_log) = 0 and (select count(*) from employee_invitations) = 0,
  'a Manager sees no coordinates, audit log or invitations');
select pg_temp.as_user('00000000-0000-0000-0000-00000000000d');
select pg_temp.expect((select count(*) from attendance_events) = current_setting('test.n_ev_d')::bigint and (select count(distinct employee_id) from leave_requests) <= 1
  and (select count(*) from employees) = 1, 'an Employee sees only their own attendance, leave and record');
select pg_temp.expect((select count(*) from attendance_coords) = current_setting('test.n_co_d')::bigint and (select count(*) from audit_log) = 0,
  'an Employee sees only the coordinates of their own check-ins, and no audit log');
do $$ begin perform public.verification_log(10); if exists (select 1 from public.verification_log(10)) then raise exception 'FAILED: employee read verification history'; end if;
  raise notice 'ok - an Employee gets no verification history';
exception when insufficient_privilege then raise notice 'ok - an Employee gets no verification history'; end $$;
do $$ begin update public.companies set max_accuracy_m = 500; if found then raise exception 'FAILED: employee changed company rules'; end if;
  raise notice 'ok - an Employee cannot change company rules';
exception when raise_exception then if sqlerrm like 'FAILED%' then raise; end if; raise notice 'ok - an Employee cannot change company rules'; end $$;
reset role; select pg_temp.as_user('');
select 'ALL SECURITY MATRIX TESTS PASSED';
