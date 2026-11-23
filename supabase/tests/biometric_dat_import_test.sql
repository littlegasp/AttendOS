\set ON_ERROR_STOP on
-- 0013 DAT import (B5 Stage 1 + 2). Runs after 0013 in the same session as the earlier biometric tests
-- (helpers pg_temp.expect / fails / act and settings t.ca, t.cb, t.agent, t.locb come from them).
--
-- Fixtures: synthetic files in tests/fixtures/dat (README there lists the expected results). The real X2008 export
-- is NEVER in the repository: it is read from $ATTENDOS_REAL_DAT when that variable points at the file; otherwise the
-- real-file tests are reported as SKIPPED (not passed).
reset role; select pg_temp.as_user('');

\set fx '../../tests/fixtures/dat'
\set f01 `base64 -w0 ../../tests/fixtures/dat/f01_six_field_crlf.dat`
\set f02 `base64 -w0 ../../tests/fixtures/dat/f02_codes_10_010_0010.dat`
\set f03 `base64 -w0 ../../tests/fixtures/dat/f03_no_final_newline.dat`
\set f04 `base64 -w0 ../../tests/fixtures/dat/f04_lf_only.dat`
\set f05 `base64 -w0 ../../tests/fixtures/dat/f05_missing_and_extra_field.dat`
\set f06 `base64 -w0 ../../tests/fixtures/dat/f06_malformed_over_threshold.dat`
\set f07 `base64 -w0 ../../tests/fixtures/dat/f07_invalid_timestamps.dat`
\set f07b `base64 -w0 ../../tests/fixtures/dat/f07b_timestamp_bad_format.dat`
\set f08 `base64 -w0 ../../tests/fixtures/dat/f08_invalid_utf8.dat`
\set f08b `base64 -w0 ../../tests/fixtures/dat/f08b_utf16_bom.dat`
\set f08c `base64 -w0 ../../tests/fixtures/dat/f08c_utf8_bom.dat`
\set f09 `base64 -w0 ../../tests/fixtures/dat/f09_one_blank_row.dat`
\set f09b `base64 -w0 ../../tests/fixtures/dat/f09b_blank_rows_over_threshold.dat`
\set f10 `base64 -w0 ../../tests/fixtures/dat/f10_exact_duplicates.dat`
\set f11 `base64 -w0 ../../tests/fixtures/dat/f11_same_code_time_other_fields.dat`
\set f12 `base64 -w0 ../../tests/fixtures/dat/f12_out_of_order.dat`
\set f13 `base64 -w0 ../../tests/fixtures/dat/f13_unknown_field_values.dat`
\set f14 `base64 -w0 ../../tests/fixtures/dat/f14_code_field_variants.dat`
\set f15 `base64 -w0 ../../tests/fixtures/dat/f15_header_line.dat`
\set f16 `base64 -w0 ../../tests/fixtures/dat/f16_binary.dat`
\set f17 `base64 -w0 ../../tests/fixtures/dat/f17_line_too_long.dat`
\set f17b `base64 -w0 ../../tests/fixtures/dat/f17b_too_many_fields.dat`
\set realdat `f="$ATTENDOS_REAL_DAT"; if [ -n "$f" ] && [ -r "$f" ]; then base64 -w0 "$f"; fi`

-- ---------------------------------------------------------------- helpers
create function pg_temp.b(t text) returns bytea language sql as $$ select decode(t, 'base64') $$;
create function pg_temp.chunks(raw bytea) returns text[] language sql as $$
  select array(select encode(sha256(substring(raw from i * 262144 + 1 for 262144)), 'hex')
                 from generate_series(0, ((octet_length(raw) + 262143) / 262144) - 1) i order by i) $$;
-- full upload + processing as the current role; returns the batch id (its state tells success or failure)
create function pg_temp.dat_up(raw bytea, dev uuid, tz text default 'Asia/Kolkata') returns uuid language plpgsql as $$
declare n int := (octet_length(raw) + 262143) / 262144; r jsonb; bid uuid; tok text; i int;
begin
  r := biometric_dat_begin(dev, tz, octet_length(raw), encode(sha256(raw), 'hex'), pg_temp.chunks(raw));
  if not (r ->> 'ok')::boolean then raise exception 'begin refused: %', r; end if;
  bid := (r ->> 'batch_id')::uuid; tok := r ->> 'upload_token';
  for i in 0 .. n - 1 loop
    r := biometric_dat_chunk(bid, tok, i, replace(encode(substring(raw from i * 262144 + 1 for 262144), 'base64'), E'\n', ''));
    if not (r ->> 'ok')::boolean then raise exception 'chunk refused: %', r; end if;
  end loop;
  r := biometric_dat_finish(bid, tok);
  if (r ->> 'ok')::boolean then
    loop r := biometric_dat_process(bid); exit when r ->> 'state' in ('ready_for_review', 'reviewed', 'failed'); end loop;
  end if;
  return bid;
end $$;
create function pg_temp.st(bid uuid) returns text language sql security definer as $$ select state from public.biometric_import_batches where id = bid $$;
create function pg_temp.why(bid uuid) returns text language sql security definer as $$ select fail_reason || coalesce(':' || fail_line, '') from public.biometric_import_batches where id = bid $$;
create function pg_temp.nrows(bid uuid) returns bigint language sql security definer as $$ select count(*) from public.biometric_import_rows where batch_id = bid $$;
create function pg_temp.row(bid uuid, n int) returns public.biometric_import_rows language sql security definer as $$ select * from public.biometric_import_rows where batch_id = bid and line_no = n $$;
create function pg_temp.bat(bid uuid) returns public.biometric_import_batches language sql security definer as $$ select * from public.biometric_import_batches where id = bid $$;
-- the newest batch of these exact bytes (the server names batches itself; the uploaded name is never stored)
create function pg_temp.bid_of(raw bytea) returns uuid language sql security definer as $$
  select id from public.biometric_import_batches where file_sha256 = sha256(raw) order by created_at desc limit 1 $$;
create function pg_temp.lim() returns jsonb language sql security definer as $$ select public.biometric_dat_limits() $$;
create function pg_temp.nchunks(bid uuid) returns bigint language sql security definer as $$ select count(*) from public.biometric_import_chunks where batch_id = bid $$;
create function pg_temp.nothing_kept(bid uuid) returns boolean language sql security definer as $$
  select not exists (select 1 from public.biometric_import_rows where batch_id = bid) and not exists (select 1 from public.biometric_import_files where batch_id = bid)
     and not exists (select 1 from public.biometric_import_chunks where batch_id = bid) $$;
-- the original file is reproduced from the rows exactly (raw lines + recorded terminators), and the stored bytes equal the upload
create function pg_temp.roundtrip(bid uuid, raw bytea) returns boolean language sql security definer as $$
  select (select original from public.biometric_import_files where batch_id = bid) = raw
     and convert_to((select string_agg(raw_line || case terminator when 'crlf' then E'\r\n' else '' end, '' order by line_no)
                       from public.biometric_import_rows where batch_id = bid), 'UTF8')
         = case when substring(raw from 1 for 3) = '\xefbbbf'::bytea then substring(raw from 4) else raw end $$;
-- fields[] are exactly the TAB-separated pieces of the raw line, for every non-blank row
create function pg_temp.fields_exact(bid uuid) returns boolean language sql security definer as $$
  select bool_and(fields = string_to_array(raw_line, E'\t')) from public.biometric_import_rows where batch_id = bid and raw_line <> '' $$;
-- everything outside import staging, audit and mappings (which the tests change on purpose)
create function pg_temp.snap() returns text language plpgsql as $$
declare t text; r text; acc text := '';
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r'
              and c.relname not in ('biometric_import_batches', 'biometric_import_chunks', 'biometric_import_files', 'biometric_import_rows',
                                    'audit_log', 'biometric_employee_mappings', 'biometric_device_import_formats') order by 1 loop
    execute format('select coalesce(md5(string_agg(x::text, ''|'' order by x::text)), ''-'') from public.%I x', t) into r;
    acc := acc || t || ':' || r || ';';
  end loop;
  return md5(acc);
end $$;
create function pg_temp.snapd() returns jsonb language plpgsql as $$
declare t text; r text; acc jsonb := '{}';
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r'
              and c.relname not in ('biometric_import_batches', 'biometric_import_chunks', 'biometric_import_files', 'biometric_import_rows',
                                    'audit_log', 'biometric_employee_mappings', 'biometric_device_import_formats') order by 1 loop
    execute format('select coalesce(md5(string_agg(x::text, ''|'' order by x::text)), ''-'') from public.%I x', t) into r;
    acc := acc || jsonb_build_object(t, r);
  end loop;
  return acc;
end $$;
create function pg_temp.dat_audit_clean() returns boolean language sql as $$
  select coalesce(bool_and(
           (select bool_and(k in ('state', 'reason', 'line', 'size', 'sha256', 'chunk_count', 'lines', 'counts', 'source_device_id', 'format_version', 'rows_removed'))
              from jsonb_object_keys(after) k)
           and (after ->> 'format_version') is not distinct from case when after ? 'format_version' then 'essl.x2008.attlog/1' end
           and (after - 'format_version')::text !~ '(\.dat|attlog|synthetic|2030-0|2026-11-|\\t|WR198| 10\b)'), true)
    from public.audit_log where action like 'dat\_import.%' $$;

-- ---------------------------------------------------------------- setup (before the regression snapshot)
select pg_temp.act('owner');
insert into employees (company_id, full_name, email, role, emp_code)
  values (current_setting('t.ca')::uuid, 'Test Person WR198', 'wr198@acme.in', 'employee', 'WR198'),
         (current_setting('t.ca')::uuid, 'Test Person Other', 'other10@acme.in', 'employee', 'WR777'),
         (current_setting('t.ca')::uuid, 'Test Person Leaver', 'leaver@acme.in', 'employee', 'WR555');
select set_config('d.wr198', (select id::text from employees where emp_code = 'WR198'), false);
select set_config('d.wr777', (select id::text from employees where emp_code = 'WR777'), false);
select set_config('d.wr555', (select id::text from employees where emp_code = 'WR555'), false);
select pg_temp.act('A admin');
-- a company-wide mapping made while the person was active; they leave afterwards (setup, before the snapshot)
select biometric_save_mapping('44', null, current_setting('d.wr555')::uuid, '2026-10-01 00:00:00+05:30', true);
select pg_temp.act('owner');
update employees set active = false where emp_code = 'WR555';
select pg_temp.act('A admin');
select set_config('d.x2008', biometric_save_device(null, jsonb_build_object('name', 'X2008 (test)', 'manufacturer', 'essl', 'model', 'X2008',
  'serial_number', 'TEST-X2008', 'integration_method', 'file_import', 'timezone', 'Asia/Kolkata')) ->> 'device_id', false);
select set_config('d.x2008r', biometric_save_device(null, jsonb_build_object('name', 'X2008 real-file test', 'manufacturer', 'essl', 'model', 'X2008',
  'serial_number', 'TEST-X2008-REAL', 'integration_method', 'file_import', 'timezone', 'Asia/Kolkata')) ->> 'device_id', false);
select set_config('d.fx', biometric_save_device(null, jsonb_build_object('name', 'Fixture device', 'manufacturer', 'essl', 'model', 'X2008',
  'serial_number', 'TEST-FIXTURE', 'integration_method', 'file_import', 'timezone', 'Asia/Kolkata')) ->> 'device_id', false);
select set_config('d.other', biometric_save_device(null, jsonb_build_object('name', 'Second X2008 (test)', 'manufacturer', 'essl', 'model', 'X2008',
  'serial_number', 'TEST-X2008-B', 'integration_method', 'file_import', 'timezone', 'Asia/Kolkata')) ->> 'device_id', false);
select set_config('d.pull', biometric_save_device(null, jsonb_build_object('name', 'eSSL pulled (test)', 'manufacturer', 'essl', 'model', 'X2008',
  'serial_number', 'TEST-PULL', 'integration_method', 'sdk_pull', 'agent_id', current_setting('t.agent'))) ->> 'device_id', false);
select set_config('d.zk', current_setting('t.dev1'), false);   -- a ZKTeco device of company A
-- F4 fixtures: an eSSL device of another model, an X2008 never assigned a format, an X2008 whose model is changed after assignment
select set_config('d.k21', biometric_save_device(null, jsonb_build_object('name', 'eSSL K21 (test)', 'manufacturer', 'essl', 'model', 'K21',
  'serial_number', 'TEST-K21', 'integration_method', 'file_import', 'timezone', 'Asia/Kolkata')) ->> 'device_id', false);
select set_config('d.unassigned', biometric_save_device(null, jsonb_build_object('name', 'X2008 without format (test)', 'manufacturer', 'essl', 'model', 'X2008',
  'serial_number', 'TEST-X2008-NOFMT', 'integration_method', 'file_import', 'timezone', 'Asia/Kolkata')) ->> 'device_id', false);
select set_config('d.remodel', biometric_save_device(null, jsonb_build_object('name', 'Re-modelled device (test)', 'manufacturer', 'essl', 'model', 'X2008',
  'serial_number', 'TEST-REMODEL', 'firmware_version', '8.0.4.2-20180530', 'integration_method', 'file_import', 'timezone', 'Asia/Kolkata')) ->> 'device_id', false);
-- the Admin assigns the verified X2008 profile to the devices used below (an explicit per-device decision)
select set_config('d.fmt_ok', (select bool_and((biometric_dat_set_device_format(x::uuid, 'essl.x2008.attlog/1') ->> 'ok')::boolean)::text
  from unnest(array[current_setting('d.x2008'), current_setting('d.x2008r'), current_setting('d.fx'), current_setting('d.other'),
                    current_setting('d.pull'), current_setting('d.remodel')]) x), false);
select set_config('d.fmt_k21', biometric_dat_set_device_format(current_setting('d.k21')::uuid, 'essl.x2008.attlog/1')::text, false);
select set_config('d.fmt_zk', biometric_dat_set_device_format(current_setting('d.zk')::uuid, 'essl.x2008.attlog/1')::text, false);
select set_config('d.fmt_bad', biometric_dat_set_device_format(current_setting('d.fx')::uuid, 'essl.other/1')::text, false);
select biometric_save_device(current_setting('d.remodel')::uuid, jsonb_build_object('model', 'X990'));
-- SDK-path raw events on the pulled eSSL device (code 55, two at the same second, one at another time) — for cross-path duplicates
select pg_temp.act('owner');
select set_config('d.base', to_char(date_trunc('second', now() - interval '3 hours') at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS'), false);
select set_config('d.raw1', pg_temp.raw(current_setting('d.pull')::uuid, current_setting('t.agent')::uuid, current_setting('t.run')::bigint, '55',
  (current_setting('d.base')::timestamp at time zone 'Asia/Kolkata'), 990001)::text, false);
select set_config('d.raw2', pg_temp.raw(current_setting('d.pull')::uuid, current_setting('t.agent')::uuid, current_setting('t.run')::bigint, '55',
  (current_setting('d.base')::timestamp at time zone 'Asia/Kolkata'), 990002)::text, false);

insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000d9', 'datadmin2@x.in');
insert into employees (company_id, full_name, email, role) values (current_setting('t.ca')::uuid, 'Second Admin', 'datadmin2@x.in', 'admin');
select set_config('d.snap', pg_temp.snap(), false);
select set_config('d.snapd', pg_temp.snapd()::text, false);
select set_config('d.audit0', (select count(*) from audit_log)::text, false);

-- ================================================================ 1. catalog: locked down
select pg_temp.expect((select bool_and(c.relrowsecurity) from pg_class c where c.relname in ('biometric_import_chunks', 'biometric_import_files', 'biometric_import_rows')),
  'C1 the three new tables have row level security on');
select pg_temp.expect(not exists (select 1 from information_schema.role_table_grants where table_name in ('biometric_import_chunks', 'biometric_import_files', 'biometric_import_rows',
  'biometric_import_batches', 'biometric_device_import_formats') and grantee in ('anon', 'authenticated', 'PUBLIC')),
  'C2 no table grants to anon, authenticated or PUBLIC on any import table, the batch table included (functions only; F1)');
select pg_temp.expect(not exists (select 1 from information_schema.column_privileges where table_name in ('biometric_import_batches', 'biometric_device_import_formats')
  and grantee in ('anon', 'authenticated', 'PUBLIC'))
  and not exists (select 1 from unnest(array['anon', 'authenticated']) r, unnest(array['upload_token_hash', 'chunk_hashes', 'delete_reason', 'file_name',
                   'file_sha256', 'fail_reason', 'counts', 'uploaded_by']) c where has_column_privilege(r, 'public.biometric_import_batches', c, 'select'))
  and not exists (select 1 from pg_policies where tablename = 'biometric_import_batches'),
  'C2b F1: no API role can select any batch column (token hash, chunk hashes, delete reason, file name …); the 0010 read policy is gone');
select pg_temp.expect(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'biometric\_dat\_%'
  and (has_function_privilege('anon', p.oid, 'execute'))), 'C3 anon cannot execute any DAT function');
select pg_temp.expect(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'biometric\_dat\_%'
  and has_function_privilege('authenticated', p.oid, 'execute')
  and p.proname not in ('biometric_dat_begin', 'biometric_dat_chunk', 'biometric_dat_resume', 'biometric_dat_finish', 'biometric_dat_process', 'biometric_dat_status',
                        'biometric_dat_batches', 'biometric_dat_codes', 'biometric_dat_rows', 'biometric_dat_cancel', 'biometric_dat_housekeeping',
                        'biometric_dat_mark_reviewed', 'biometric_dat_delete', 'biometric_dat_download', 'biometric_dat_set_device_format')),
  'C4 only the 15 checked functions are callable by signed-in users; every helper (purge, expire, end, audit, lock, parse …) is not');
select pg_temp.expect(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosecdef
  and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')),
  'C6 every security-definer function in the schema has a fixed search_path');
select pg_temp.expect(current_setting('d.fmt_ok')::boolean
  and current_setting('d.fmt_k21')::jsonb ->> 'error' = 'model_not_supported' and current_setting('d.fmt_zk')::jsonb ->> 'error' = 'model_not_supported'
  and current_setting('d.fmt_bad')::jsonb ->> 'error' = 'unknown_format',
  'F4a the X2008 profile can be assigned only to eSSL X2008 devices (an eSSL K21 and a ZKTeco device are refused; unknown profiles refused)');
select pg_temp.expect(not exists (select 1 from pg_trigger t where t.tgrelid in ('public.biometric_import_rows'::regclass, 'public.biometric_import_files'::regclass,
  'public.biometric_import_chunks'::regclass, 'public.biometric_import_batches'::regclass) and t.tgfoid = 'public.audit'::regproc),
  'C5 the whole-row audit() trigger is not attached to any import table');

-- ================================================================ 2. the real X2008 export (local only; never committed)
select pg_temp.act('A admin');
select (:'realdat' <> '') as have_real \gset
\if :have_real
select pg_temp.expect(encode(sha256(pg_temp.b(:'realdat')), 'hex') = '6f0115361bbb2f51c92c3424b3edf14ea07fd68643dbfc96670a3d7122192476',
  'R0 the file under test is the verified X2008 export (SHA-256 6f0115…2476)');
select set_config('d.real', pg_temp.dat_up(pg_temp.b(:'realdat'), current_setting('d.x2008r')::uuid, 'Asia/Kolkata')::text, false);
select pg_temp.act('owner');
select pg_temp.expect(pg_temp.st(current_setting('d.real')::uuid) = 'ready_for_review', 'R1 the real export is accepted and ready for review');
select pg_temp.expect(pg_temp.nrows(current_setting('d.real')::uuid) = 151
  and (select count(*) from biometric_import_rows where batch_id = current_setting('d.real')::uuid and parse_status = 'ok') = 151,
  'R2 151 rows, every one parsed (no blank, no malformed row)');
select pg_temp.expect(pg_temp.roundtrip(current_setting('d.real')::uuid, pg_temp.b(:'realdat')),
  'R3 the stored original is byte-identical, and raw lines + terminators rebuild the file exactly');
select pg_temp.expect(pg_temp.fields_exact(current_setting('d.real')::uuid)
  and (select bool_and(cardinality(fields) = 6 and line_bytes = 39 and terminator = 'crlf' and length(raw_code_field) = 9)
         from biometric_import_rows where batch_id = current_setting('d.real')::uuid),
  'R4 six exact fields per row; every line 39 bytes + CRLF; field 1 nine characters wide');
select pg_temp.expect((select final_terminator = 'crlf' and bom = 'none' and line_count = 151 and format_version = 'essl.x2008.attlog/1'
  from biometric_import_batches where id = current_setting('d.real')::uuid), 'R5 final CRLF, no BOM, format profile essl.x2008.attlog/1 recorded');
select pg_temp.expect((select device_model = 'X2008' and file_name ~ '^x2008-[0-9a-f]{8}-[0-9]{8}-[0-9]{4}-6f011536\.dat$' and file_name !~* 'attlog'
  from biometric_import_batches where id = current_setting('d.real')::uuid),
  'R5b device model recorded; the batch name is server-generated (model, device reference, time, hash start) — the uploaded name is never stored');
select pg_temp.expect((select bool_and(local_time_text = fields[2] and raw_code_field = fields[1] and time_status = 'ok'
    and instant = (local_time_text::timestamp at time zone 'Asia/Kolkata'))
  from biometric_import_rows where batch_id = current_setting('d.real')::uuid),
  'R6 timestamps kept as the exact strings; the separate instant is the string read in Asia/Kolkata');
select pg_temp.expect((select count(distinct employee_code) from biometric_import_rows where batch_id = current_setting('d.real')::uuid) = 17
  and (select bool_and(employee_code = ltrim(raw_code_field, ' ')) from biometric_import_rows where batch_id = current_setting('d.real')::uuid),
  'R7 17 distinct codes, each = field 1 without its left-padding spaces');
select pg_temp.expect((select string_agg(line_no || '=' || local_time_text, ',' order by line_no) from biometric_import_rows
   where batch_id = current_setting('d.real')::uuid and employee_code = '10')
  = '24=2026-11-04 09:26:53,95=2026-11-16 09:25:04,150=2026-11-21 15:49:16,151=2026-11-21 15:53:01',
  'R8 code 10 is on lines 24, 95, 150, 151 with the exact timestamps');
select pg_temp.expect((select count(*) from biometric_import_rows where batch_id = current_setting('d.real')::uuid and employee_code = '10'
   and local_time_text like '2026-11-21 %' and dup_class = 'new' and parse_status = 'ok') = 2,
  'R9 21 Nov: BOTH records (15:49:16 and 15:53:01) are kept as separate new raw rows — no pairing, nothing dropped');
select pg_temp.expect((select bool_and(dup_class = 'new') from biometric_import_rows where batch_id = current_setting('d.real')::uuid)
  and (select counts ->> 'exact_in_file' = '0' and counts ->> 'same_code_time_other_fields' = '0' and counts ->> 'out_of_order' = '0'
         from biometric_import_batches where id = current_setting('d.real')::uuid),
  'R10 no duplicates in the real file; chronological (no out_of_order note)');
select pg_temp.expect(not exists (select 1 from information_schema.columns where table_name = 'biometric_import_rows'
   and column_name ~ '(direction|in_out|status_meaning|verify|session)'), 'R11 the row has no direction, verification or session column at all');
select pg_temp.act('A admin');
select pg_temp.expect((biometric_dat_codes(current_setting('d.real')::uuid) -> 'totals' ->> 'unmapped')::int = 151,
  'R12 before any mapping, all 151 records are unmapped (no mapping inferred)');
-- TEST MAPPING ONLY: 10 → WR198 from 1 Nov 2026 is an assumption for this local test. HR has not confirmed the effective date or any
-- earlier use of code 10; no real company mapping is created from this.
select biometric_save_mapping('10', current_setting('d.x2008r')::uuid, current_setting('d.wr198')::uuid, '2026-11-01 00:00:00+05:30', false);
select set_config('d.codes', biometric_dat_codes(current_setting('d.real')::uuid)::text, false);
select pg_temp.expect((current_setting('d.codes')::jsonb -> 'totals' ->> 'mapped')::int = 4
  and (current_setting('d.codes')::jsonb -> 'totals' ->> 'unmapped')::int = 147,
  'R13 with the TEST device mapping 10 → WR198 (assumed from 1 Nov 2026), exactly the 4 code-10 records are mapped; 147 stay unmapped');
select pg_temp.expect((select (c -> 'employees' -> 0 ->> 'emp_code') = 'WR198' and (c -> 'employees' -> 0 ->> 'scope') = 'device' and (c ->> 'records')::int = 4
  from jsonb_array_elements(current_setting('d.codes')::jsonb -> 'codes') c where c ->> 'code' = '10'),
  'R14 code 10 resolves to WR198 through the X2008 device mapping');
select pg_temp.expect((select count(*) from jsonb_array_elements(current_setting('d.codes')::jsonb -> 'codes') c where jsonb_array_length(c -> 'employees') > 0) = 1,
  'R15 no other code is mapped');
select pg_temp.expect((biometric_dat_begin(current_setting('d.x2008r')::uuid, 'Asia/Kolkata', octet_length(pg_temp.b(:'realdat')),
   encode(sha256(pg_temp.b(:'realdat')), 'hex'), pg_temp.chunks(pg_temp.b(:'realdat')))) ->> 'error' = 'already_imported',
  'R16 uploading the same file again is refused as already imported');
select pg_temp.expect((biometric_dat_rows(current_setting('d.real')::uuid, 'code', '10', 0, 100) ->> 'total')::int = 4
  and (biometric_dat_rows(current_setting('d.real')::uuid, 'all', null, 140, 100) ->> 'total')::int = 151
  and jsonb_array_length(biometric_dat_rows(current_setting('d.real')::uuid, 'all', null, 140, 100) -> 'rows') = 11,
  'R17 paged rows: code filter and offset work');
\else
\echo 'SKIPPED - R0–R17 real X2008 file: set ATTENDOS_REAL_DAT to the verified export to run them (they are NOT counted as passed)'
\endif

-- ================================================================ 3. synthetic parser fixtures (P1–P23)
select pg_temp.act('A admin');
select set_config('d.p01', pg_temp.dat_up(pg_temp.b(:'f01'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p02', pg_temp.dat_up(pg_temp.b(:'f02'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p03', pg_temp.dat_up(pg_temp.b(:'f03'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p04', pg_temp.dat_up(pg_temp.b(:'f04'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p05', pg_temp.dat_up(pg_temp.b(:'f05'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p06', pg_temp.dat_up(pg_temp.b(:'f06'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p07', pg_temp.dat_up(pg_temp.b(:'f07'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p07b', pg_temp.dat_up(pg_temp.b(:'f07b'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p08', pg_temp.dat_up(pg_temp.b(:'f08'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p08b', pg_temp.dat_up(pg_temp.b(:'f08b'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p08c', pg_temp.dat_up(pg_temp.b(:'f08c'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p09', pg_temp.dat_up(pg_temp.b(:'f09'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p09b', pg_temp.dat_up(pg_temp.b(:'f09b'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p10', pg_temp.dat_up(pg_temp.b(:'f10'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p11', pg_temp.dat_up(pg_temp.b(:'f11'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p12', pg_temp.dat_up(pg_temp.b(:'f12'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p13', pg_temp.dat_up(pg_temp.b(:'f13'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p14', pg_temp.dat_up(pg_temp.b(:'f14'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p15', pg_temp.dat_up(pg_temp.b(:'f15'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p16', pg_temp.dat_up(pg_temp.b(:'f16'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p17', pg_temp.dat_up(pg_temp.b(:'f17'), current_setting('d.fx')::uuid)::text, false);
select set_config('d.p17b', pg_temp.dat_up(pg_temp.b(:'f17b'), current_setting('d.fx')::uuid)::text, false);
select pg_temp.act('owner');

select pg_temp.expect(pg_temp.st(current_setting('d.p01')::uuid) = 'ready_for_review' and pg_temp.nrows(current_setting('d.p01')::uuid) = 100
  and (select bool_and(parse_status = 'ok' and cardinality(fields) = 6 and local_time_text = fields[2]) from biometric_import_rows where batch_id = current_setting('d.p01')::uuid)
  and (select count(*) from biometric_import_rows where batch_id = current_setting('d.p01')::uuid and employee_code = '10') = 8,
  'P1 observed six-field structure: 100 rows ok, six exact fields, 8 rows with code 10');
select pg_temp.expect((select bool_and(length(raw_code_field) = 9 and raw_code_field ~ '^ +' and employee_code !~ ' ' and raw_code_field = lpad(employee_code, 9, ' '))
   from biometric_import_rows where batch_id = current_setting('d.p01')::uuid), 'P2 field 1 kept with its padding; the extracted code has no leading spaces');
select pg_temp.expect((select array_agg(employee_code order by line_no) from biometric_import_rows where batch_id = current_setting('d.p02')::uuid) = array['10', '010', '0010'],
  'P3 codes 10, 010 and 0010 stay three different strings (no number conversion)');
select pg_temp.expect(pg_temp.fields_exact(current_setting('d.p01')::uuid) and pg_temp.fields_exact(current_setting('d.p07')::uuid)
  and (select bool_and(local_time_text = fields[2]) from biometric_import_rows where batch_id = current_setting('d.p07')::uuid and cardinality(fields) = 6),
  'P4 timestamp strings preserved exactly, including invalid ones');
select pg_temp.expect(pg_temp.roundtrip(current_setting('d.p01')::uuid, pg_temp.b(:'f01')) and pg_temp.roundtrip(current_setting('d.p03')::uuid, pg_temp.b(:'f03'))
  and (select terminator from biometric_import_rows where batch_id = current_setting('d.p03')::uuid and line_no = 20) = 'none'
  and (select final_terminator from biometric_import_batches where id = current_setting('d.p03')::uuid) = 'none',
  'P5 CRLF recorded per line; a missing final newline is recorded; originals byte-identical');
select pg_temp.expect(pg_temp.st(current_setting('d.p04')::uuid) = 'failed' and pg_temp.why(current_setting('d.p04')::uuid) = 'unexpected_line_endings'
  and pg_temp.nothing_kept(current_setting('d.p04')::uuid), 'P6 LF-only file refused (unexpected_line_endings); nothing kept');
select pg_temp.expect(pg_temp.st(current_setting('d.p05')::uuid) = 'ready_for_review'
  and (pg_temp.row(current_setting('d.p05')::uuid, 40)).parse_reason = 'field_count_5' and (pg_temp.row(current_setting('d.p05')::uuid, 70)).parse_reason = 'field_count_7'
  and (select count(*) from biometric_import_rows where batch_id = current_setting('d.p05')::uuid and parse_status = 'ok') = 98
  and pg_temp.nrows(current_setting('d.p05')::uuid) = 100,
  'P7 missing and extra field rows (2 %, at the limit) kept as unparsable with reasons; 98 ok; 100 rows retained');
select pg_temp.expect(pg_temp.st(current_setting('d.p06')::uuid) = 'failed' and pg_temp.why(current_setting('d.p06')::uuid) = 'too_many_malformed_rows'
  and pg_temp.nothing_kept(current_setting('d.p06')::uuid), 'P8 3 % malformed: whole file refused, nothing kept');
select pg_temp.expect((pg_temp.row(current_setting('d.p07')::uuid, 21)).time_status = 'impossible_date'
  and (pg_temp.row(current_setting('d.p07')::uuid, 21)).local_time_text = '2030-02-30 09:00:00'
  and (pg_temp.row(current_setting('d.p07')::uuid, 22)).time_status = 'impossible_date'
  and (pg_temp.row(current_setting('d.p07')::uuid, 21)).local_ts is null and (pg_temp.row(current_setting('d.p07')::uuid, 21)).instant is null
  and (pg_temp.row(current_setting('d.p07')::uuid, 21)).parse_status = 'ok' and pg_temp.nrows(current_setting('d.p07')::uuid) = 100,
  'P9 impossible dates kept with exact strings, no local time or instant, not counted as malformed');
select pg_temp.expect((pg_temp.row(current_setting('d.p07b')::uuid, 31)).time_status = 'bad_format'
  and (pg_temp.row(current_setting('d.p07b')::uuid, 31)).parse_status = 'unparsable'
  and (pg_temp.row(current_setting('d.p07b')::uuid, 31)).local_time_text = '05/03/2030 09:00', 'P10 wrong timestamp format kept as unparsable (1 %)');
select pg_temp.expect(pg_temp.why(current_setting('d.p08')::uuid) = 'unsupported_encoding' and pg_temp.why(current_setting('d.p08b')::uuid) = 'unsupported_encoding'
  and pg_temp.nothing_kept(current_setting('d.p08')::uuid) and pg_temp.nothing_kept(current_setting('d.p08b')::uuid),
  'P11 invalid UTF-8 and UTF-16 refused (unsupported_encoding); nothing kept');
select pg_temp.expect(pg_temp.st(current_setting('d.p08c')::uuid) = 'ready_for_review'
  and (select bom from biometric_import_batches where id = current_setting('d.p08c')::uuid) = 'utf8'
  and pg_temp.roundtrip(current_setting('d.p08c')::uuid, pg_temp.b(:'f08c')) and (pg_temp.row(current_setting('d.p08c')::uuid, 1)).code_status = 'ok',
  'P12 UTF-8 BOM accepted and recorded; the original keeps it; line 1 parses');
select pg_temp.expect((pg_temp.row(current_setting('d.p09')::uuid, 61)).parse_status = 'blank' and pg_temp.nrows(current_setting('d.p09')::uuid) = 121
  and pg_temp.why(current_setting('d.p09b')::uuid) = 'too_many_blank_rows', 'P13 one blank line kept as blank; too many blank lines refused');
select pg_temp.expect((pg_temp.row(current_setting('d.p10')::uuid, 16)).dup_class = 'exact_in_file' and (pg_temp.row(current_setting('d.p10')::uuid, 16)).dup_ref_line = 15
  and (pg_temp.row(current_setting('d.p10')::uuid, 26)).dup_ref_line = 6 and pg_temp.nrows(current_setting('d.p10')::uuid) = 32
  and (select count(*) from biometric_import_rows where batch_id = current_setting('d.p10')::uuid and dup_class = 'exact_in_file') = 2,
  'P14 exact duplicate lines labelled with pointers to lines 15 and 6; all 32 rows kept');
select pg_temp.expect((pg_temp.row(current_setting('d.p11')::uuid, 14)).dup_class = 'same_code_time_other_fields'
  and (pg_temp.row(current_setting('d.p11')::uuid, 14)).dup_ref_line = 13 and (pg_temp.row(current_setting('d.p11')::uuid, 13)).dup_class = 'new',
  'P15 same code and time with different raw fields: labelled, both kept');
select pg_temp.expect((select array_agg(line_no order by line_no) from biometric_import_rows where batch_id = current_setting('d.p12')::uuid and 'out_of_order' = any (flags)) = array[12, 21]
  and (select count(*) from biometric_import_rows where batch_id = current_setting('d.p01')::uuid and 'out_of_order' = any (flags)) = 0
  and (select bool_and(line_no = rn) from (select line_no, row_number() over (order by line_no) rn from biometric_import_rows where batch_id = current_setting('d.p12')::uuid) z),
  'P16 out-of-order records noted on lines 12 and 21; file order kept; chronological file has no note');
select pg_temp.expect((select array_agg(array_to_string(fields[3:6], '|') order by line_no) from biometric_import_rows where batch_id = current_setting('d.p13')::uuid)
  = array['9|999|7|3', '|255|1|0', '1|255|1|', 'x|-1|01|00', '2|0|200|1'] and pg_temp.st(current_setting('d.p13')::uuid) = 'ready_for_review',
  'P17 unknown field values (incl. empty, x, -1, 01, 00) stored exactly');
select pg_temp.expect((select string_agg(line_no || ':' || coalesce(employee_code, '-') || ':' || code_status || ':' || ('code_width_unexpected' = any (flags))::text, ',' order by line_no)
   from biometric_import_rows where batch_id = current_setting('d.p14')::uuid and line_no <= 7)
  = '1:10:ok:false,2:10:ok:true,3:10:ok:true,4:-:trailing_space:true,5:-:inner_space:false,6:-:empty_code:false,7:A-10:ok:false',
  'P18 code variants: padded/unpadded/wide → 10 (width noted); trailing (10 wide, noted), inner and empty → invalid; A-10 kept');
select pg_temp.expect(pg_temp.nrows(current_setting('d.p14')::uuid) = 157 and (select count(*) from biometric_import_rows where batch_id = current_setting('d.p14')::uuid and parse_status = 'unparsable') = 3,
  'P18b all 157 lines kept; the 3 invalid codes are unparsable rows (1.9 %, under the limit)');
select pg_temp.expect(pg_temp.why(current_setting('d.p15')::uuid) = 'unexpected_header:1', 'P19 header line refused (unexpected_header, line 1)');
select pg_temp.expect(pg_temp.why(current_setting('d.p16')::uuid) in ('not_a_text_file', 'unsupported_encoding') and pg_temp.nothing_kept(current_setting('d.p16')::uuid),
  'P20 binary file refused; nothing kept');
select pg_temp.expect(pg_temp.why(current_setting('d.p17')::uuid) = 'line_too_long:11' and pg_temp.why(current_setting('d.p17b')::uuid) = 'too_many_fields:11',
  'P21 limits: line too long / too many fields refused with line 11');

-- P23 mapping preview on the synthetic file: device mapping 10 → WR198 from a time between two code-10 rows
select set_config('d.mid', (select local_time_text from biometric_import_rows where batch_id = current_setting('d.p01')::uuid and employee_code = '10' order by line_no offset 3 limit 1), false);
select pg_temp.act('A hr');   -- HR maps device codes (existing permission pattern)
select biometric_save_mapping('10', current_setting('d.fx')::uuid, current_setting('d.wr198')::uuid, (current_setting('d.mid')::timestamp at time zone 'Asia/Kolkata'), false);
select pg_temp.act('A admin');
select set_config('d.c01', biometric_dat_codes(current_setting('d.p01')::uuid)::text, false);
select pg_temp.expect((select (c ->> 'mapped')::int = 5 and (c ->> 'unmapped')::int = 3 from jsonb_array_elements(current_setting('d.c01')::jsonb -> 'codes') c where c ->> 'code' = '10')
  and (select count(*) from jsonb_array_elements(current_setting('d.c01')::jsonb -> 'codes') c where (c ->> 'mapped')::int > 0) = 1,
  'P23 mapping preview: code-10 rows before valid_from unmapped (3), at/after it mapped (5); no other code mapped; nothing created by the import');
select pg_temp.expect((select count(*) from biometric_employee_mappings) = (select count(*) from biometric_employee_mappings), 'P23b (mapping count read)');
select pg_temp.act('owner');
select pg_temp.expect((select count(*) from biometric_employee_mappings where employee_device_code = '10' and device_id = current_setting('d.fx')::uuid) = 1,
  'P23c exactly one mapping exists for code 10 on the fixture device — the one created explicitly');

-- ================================================================ 4. upload protocol and recovery (T-UP)
select pg_temp.act('A admin');
-- a 3-chunk synthetic file (≈ 700 KB): f01's lines repeated with distinct codes
select set_config('d.big', encode(convert_to((select string_agg(lpad((1000 + g)::text, 9, ' ') || E'\t' || to_char(timestamp '2030-05-01 08:00:00' + g * interval '7 seconds', 'YYYY-MM-DD HH24:MI:SS') || E'\t1\t255\t1\t0\r\n', '' order by g)
  from generate_series(1, 17000) g), 'UTF8'), 'base64'), false);
select set_config('d.bigr', biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', octet_length(pg_temp.b(current_setting('d.big'))),
  encode(sha256(pg_temp.b(current_setting('d.big'))), 'hex'), pg_temp.chunks(pg_temp.b(current_setting('d.big'))))::text, false);
select set_config('d.bb', current_setting('d.bigr')::jsonb ->> 'batch_id', false);
select set_config('d.tok', current_setting('d.bigr')::jsonb ->> 'upload_token', false);
-- unbroken base64, as the browser sends it (Postgres's encoder adds a line break every 76 characters)
create function pg_temp.ch(i int) returns text language sql as $$ select replace(encode(substring(pg_temp.b(current_setting('d.big')) from i * 262144 + 1 for 262144), 'base64'), E'\n', '') $$;
select pg_temp.expect((current_setting('d.bigr')::jsonb ->> 'ok')::boolean and (pg_temp.bat(current_setting('d.bb')::uuid)).chunk_count = 3,
  'T-UP0 begin: three chunks declared');
select pg_temp.expect((biometric_dat_chunk(current_setting('d.bb')::uuid, current_setting('d.tok'), 1, pg_temp.ch(1)) ->> 'error') = 'wrong_order'
  and (biometric_dat_chunk(current_setting('d.bb')::uuid, current_setting('d.tok'), 1, pg_temp.ch(1)) ->> 'expected_index') = '0',
  'T-UP4 wrong chunk order refused with expected_index 0; nothing stored');
select pg_temp.expect((biometric_dat_chunk(current_setting('d.bb')::uuid, current_setting('d.tok'), 0, repeat('A', 349532)) ->> 'error') = 'invalid_chunk_data'
  and (biometric_dat_chunk(current_setting('d.bb')::uuid, current_setting('d.tok'), 0, '') ->> 'error') = 'invalid_chunk_data'
  and (biometric_dat_chunk(current_setting('d.bb')::uuid, current_setting('d.tok'), 0, '***not base64***') ->> 'error') = 'invalid_chunk_data'
  and pg_temp.nchunks(current_setting('d.bb')::uuid) = 0,
  'F6 an encoded chunk longer than a full chunk (349,528 characters), empty or not base64 is refused before decoding; nothing stored');
select pg_temp.expect(length(pg_temp.ch(0)) = 349528 and length(pg_temp.ch(0)) = (pg_temp.lim() ->> 'chunk_b64_max')::int,
  'F6b a real full chunk is exactly at the encoded limit (no valid chunk is refused)');
select pg_temp.expect((biometric_dat_chunk(current_setting('d.bb')::uuid, current_setting('d.tok'), 0, pg_temp.ch(1)) ->> 'error') = 'chunk_hash_mismatch',
  'T-UP5 wrong bytes for chunk 0 refused (chunk_hash_mismatch)');
select pg_temp.expect((biometric_dat_chunk(current_setting('d.bb')::uuid, current_setting('d.tok'), 0, pg_temp.ch(0)) ->> 'next_index') = '1', 'T-UP5b correct chunk 0 accepted');
select pg_temp.expect((biometric_dat_chunk(current_setting('d.bb')::uuid, current_setting('d.tok'), 0, pg_temp.ch(0)) ->> 'repeat') = 'true',
  'T-UP2 / T-UP8 resending chunk 0 (lost answer, retry) is an idempotent repeat');
select pg_temp.expect((biometric_dat_chunk(current_setting('d.bb')::uuid, current_setting('d.tok'), 0, pg_temp.ch(2)) ->> 'error') = 'chunk_conflict',
  'T-UP3 chunk 0 again with different bytes: chunk_conflict; stored chunk unchanged');
select pg_temp.expect((biometric_dat_finish(current_setting('d.bb')::uuid, current_setting('d.tok')) ->> 'error') = 'missing_chunks'
  and pg_temp.st(current_setting('d.bb')::uuid) = 'uploading', 'T-UP1 partial upload cannot finish (missing_chunks) and stays uploading');
select pg_temp.expect(not exists (select 1 from jsonb_array_elements(biometric_dat_batches() -> 'batches') x where x ->> 'id' = current_setting('d.bb') and x ->> 'state' in ('ready_for_review', 'reviewed')),
  'T-UP1b an incomplete batch is never listed as reviewable');
select pg_temp.fails(format($$ select biometric_dat_codes(%L) $$, current_setting('d.bb')), 'not ready for review', 'T-UP1c an incomplete batch has no review data (codes)');
select pg_temp.fails(format($$ select biometric_dat_rows(%L, 'all', null, 0, 10) $$, current_setting('d.bb')), 'not ready for review', 'T-UP1d … and no rows');
select pg_temp.expect((biometric_dat_mark_reviewed(current_setting('d.bb')::uuid, 0) ->> 'error') = 'not_ready', 'T-UP1e an incomplete batch cannot be marked reviewed');
-- resume after refresh: status lists received chunk hashes; take-over issues a new token, the old one stops working
select pg_temp.expect((biometric_dat_status(current_setting('d.bb')::uuid) ->> 'next_index') = '1'
  and (biometric_dat_status(current_setting('d.bb')::uuid) -> 'received' ->> 0) = (pg_temp.chunks(pg_temp.b(current_setting('d.big'))))[1],
  'T-UP9 status after a refresh: next_index 1 and the received chunk''s hash');
select set_config('d.tok2', biometric_dat_resume(current_setting('d.bb')::uuid) ->> 'upload_token', false);
select pg_temp.expect((biometric_dat_chunk(current_setting('d.bb')::uuid, current_setting('d.tok'), 1, pg_temp.ch(1)) ->> 'error') = 'taken_over',
  'T-UP11 the old tab''s token is refused after a take-over (taken_over)');
select pg_temp.expect((biometric_dat_chunk(current_setting('d.bb')::uuid, current_setting('d.tok2'), 1, pg_temp.ch(1)) ->> 'ok') = 'true'
  and (biometric_dat_chunk(current_setting('d.bb')::uuid, current_setting('d.tok2'), 2, pg_temp.ch(2)) ->> 'ok') = 'true', 'T-UP9b the new token continues');
select pg_temp.act('A hr');
select pg_temp.fails(format($$ select biometric_dat_chunk(%L, %L, 2, 'AA==') $$, current_setting('d.bb'), current_setting('d.tok2')), 'Not allowed',
  'T-SEC2a HR cannot send chunks to someone else''s upload (even with its token)');
select pg_temp.act('A admin');
select pg_temp.expect((biometric_dat_finish(current_setting('d.bb')::uuid, current_setting('d.tok2')) ->> 'state') = 'uploaded', 'T-UP finish: verified, uploaded');
select pg_temp.expect(pg_temp.nchunks(current_setting('d.bb')::uuid) = 0, 'T-UP chunks are removed once joined');
create function pg_temp.drain(bid uuid) returns int language plpgsql as $$ declare r jsonb; n int := 0;
begin loop r := biometric_dat_process(bid); n := n + 1; exit when r ->> 'state' in ('ready_for_review', 'failed'); end loop; return n; end $$;
select pg_temp.expect(pg_temp.drain(current_setting('d.bb')::uuid) >= 8 and pg_temp.st(current_setting('d.bb')::uuid) = 'ready_for_review'
  and pg_temp.nrows(current_setting('d.bb')::uuid) = 17000, 'T-UP large file processed in ≤ 5,000-line steps: 17,000 rows');
select pg_temp.expect((biometric_dat_status(current_setting('d.bb')::uuid) ->> 'lines')::int = 17000, 'T-UP line count recorded');

-- final hash / size mismatch: declare a hash that is not the file's
select set_config('d.mm', biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', octet_length(pg_temp.b(:'f02')),
  encode(sha256('x'::bytea), 'hex'), pg_temp.chunks(pg_temp.b(:'f02')))::text, false);
select biometric_dat_chunk((current_setting('d.mm')::jsonb ->> 'batch_id')::uuid, current_setting('d.mm')::jsonb ->> 'upload_token', 0, encode(pg_temp.b(:'f02'), 'base64'));
select pg_temp.expect((biometric_dat_finish((current_setting('d.mm')::jsonb ->> 'batch_id')::uuid, current_setting('d.mm')::jsonb ->> 'upload_token') ->> 'error') = 'hash_mismatch'
  and pg_temp.nothing_kept((current_setting('d.mm')::jsonb ->> 'batch_id')::uuid), 'T-UP6 final SHA-256 mismatch: failed, chunks deleted, no rows');
-- oversized
select pg_temp.expect((biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', 16777217, repeat('a', 64), array[]::text[]) ->> 'error') = 'file_too_large',
  'T-FM1 a file over 16 MiB is refused at begin');
-- same file twice, being uploaded by another Admin, and after failure
select set_config('d.dupr', biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', octet_length(pg_temp.b(:'f01')),
  encode(sha256(pg_temp.b(:'f01')), 'hex'), pg_temp.chunks(pg_temp.b(:'f01')))::text, false);
select pg_temp.expect(current_setting('d.dupr')::jsonb ->> 'error' = 'already_imported', 'T-UP15 the same file again: refused as already imported');
select pg_temp.expect((biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', octet_length(pg_temp.b(:'f04')),
  encode(sha256(pg_temp.b(:'f04')), 'hex'), pg_temp.chunks(pg_temp.b(:'f04'))) ->> 'ok') = 'true', 'T-UP16 a file whose earlier batch failed can be begun again');
select set_config('d.open', pg_temp.bid_of(pg_temp.b(:'f04'))::text, false);
select pg_temp.act('owner');
set role authenticated; select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d9', false);
select pg_temp.expect((biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', octet_length(pg_temp.b(:'f04')),
  encode(sha256(pg_temp.b(:'f04')), 'hex'), pg_temp.chunks(pg_temp.b(:'f04'))) ->> 'error') = 'being_uploaded',
  'T-UP12 the same file being uploaded by another Admin is refused (being_uploaded)');
select pg_temp.fails(format($$ select biometric_dat_resume(%L) $$, current_setting('d.open')), 'Not allowed', 'T-UP12b another Admin cannot take over someone''s upload');
select pg_temp.expect((biometric_dat_cancel(current_setting('d.open')::uuid) ->> 'state') = 'cancelled' and pg_temp.nothing_kept(current_setting('d.open')::uuid),
  'T-DEL3 another Admin can cancel an upload in progress; nothing kept');
select pg_temp.act('A admin');
-- open-batch limit: three uploads in progress, the fourth refused
select (biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', 10, encode(sha256(convert_to('o' || g, 'UTF8')), 'hex'),
        array[encode(sha256(convert_to('o' || g, 'UTF8')), 'hex')]) ->> 'ok') from generate_series(1, 3) g;
select pg_temp.expect((biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', 10, encode(sha256('o4'::bytea), 'hex'),
  array[encode(sha256('o4'::bytea), 'hex')]) ->> 'error') = 'too_many_open_batches', 'T-UP17 a fourth batch in progress is refused');
-- expiry (clock moved back on the batches as owner): idle uploads expire on the next list call, chunks deleted, metadata kept
select pg_temp.act('owner');
create function pg_temp.ohash() returns bytea[] language sql as $$ select array[sha256('o1'::bytea), sha256('o2'::bytea), sha256('o3'::bytea)] $$;
update biometric_import_batches set last_activity_at = now() - interval '25 hours' where file_sha256 = any (pg_temp.ohash()) and state = 'uploading';
select pg_temp.act('A admin');
select biometric_dat_batches();
select pg_temp.act('owner');
select pg_temp.expect((select count(*) = 3 and bool_and(state = 'expired' and fail_reason = 'upload_idle' and ended_at is not null and upload_token_hash is null)
     from biometric_import_batches where file_sha256 = any (pg_temp.ohash()))
  and not exists (select 1 from biometric_import_chunks c join biometric_import_batches b on b.id = c.batch_id where b.file_sha256 = any (pg_temp.ohash())),
  'T-UP13 idle uploads expire lazily on the next list call; chunks removed; batch metadata kept');
-- stalled processing
select pg_temp.act('A admin');
select set_config('d.stallf', encode(convert_to('      901' || E'\t2030-06-01 08:00:00\t1\t255\t1\t0\r\n', 'UTF8'), 'base64'), false);
select set_config('d.stall', biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', octet_length(pg_temp.b(current_setting('d.stallf'))),
  encode(sha256(pg_temp.b(current_setting('d.stallf'))), 'hex'), pg_temp.chunks(pg_temp.b(current_setting('d.stallf'))))::text, false);
select pg_temp.expect((current_setting('d.stall')::jsonb ->> 'ok')::boolean, 'T-UP14a stall test batch begun');
select biometric_dat_chunk((current_setting('d.stall')::jsonb ->> 'batch_id')::uuid, current_setting('d.stall')::jsonb ->> 'upload_token', 0, current_setting('d.stallf'));
select biometric_dat_finish((current_setting('d.stall')::jsonb ->> 'batch_id')::uuid, current_setting('d.stall')::jsonb ->> 'upload_token');
select pg_temp.act('owner');
update biometric_import_batches set last_activity_at = now() - interval '3 hours' where id = (current_setting('d.stall')::jsonb ->> 'batch_id')::uuid;
select pg_temp.act('A admin');
select biometric_dat_batches();
select pg_temp.act('owner');
select pg_temp.expect(pg_temp.why((current_setting('d.stall')::jsonb ->> 'batch_id')::uuid) = 'processing_stalled'
  and pg_temp.nothing_kept((current_setting('d.stall')::jsonb ->> 'batch_id')::uuid), 'T-UP14 processing stalled for > 2 h fails; bytes deleted');

-- ================================================================ 5. security (T-SEC)
select pg_temp.act('B admin');
select pg_temp.fails(format($$ select biometric_dat_status(%L) $$, current_setting('d.p01')), 'not found', 'T-SEC1a B Admin: A''s batch is "not found" (status)');
select pg_temp.fails(format($$ select biometric_dat_rows(%L, 'all', null, 0, 10) $$, current_setting('d.p01')), 'not found', 'T-SEC1b … rows');
select pg_temp.fails(format($$ select biometric_dat_codes(%L) $$, current_setting('d.p01')), 'not found', 'T-SEC1c … codes');
select pg_temp.fails(format($$ select biometric_dat_download(%L) $$, current_setting('d.p01')), 'not found', 'T-SEC1d … download');
select pg_temp.fails(format($$ select biometric_dat_delete(%L, 'not mine at all') $$, current_setting('d.p01')), 'not found', 'T-SEC1e … delete');
select pg_temp.fails(format($$ select biometric_dat_process(%L) $$, current_setting('d.p01')), 'not found', 'T-SEC1f … process');
select pg_temp.expect(jsonb_array_length(biometric_dat_batches() -> 'batches') = 0, 'T-SEC1g B Admin lists no batches of A');
select pg_temp.expect((biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', 10, repeat('a', 64), array[repeat('a', 64)]) ->> 'error') = 'device_not_found',
  'T-SEC4 B Admin cannot import against A''s device');
select pg_temp.act('A hr');
select pg_temp.expect(exists (select 1 from jsonb_array_elements(biometric_dat_batches() -> 'batches') x where x ->> 'id' = current_setting('d.p01')),
  'T-SEC2b HR lists the company''s import batches (HR prepares imports)');
select pg_temp.expect((biometric_dat_rows(current_setting('d.p01')::uuid, 'all', null, 0, 10) ->> 'total')::int = 100
  and jsonb_array_length(biometric_dat_codes(current_setting('d.p01')::uuid) -> 'codes') > 0,
  'T-SEC2c HR reads records, duplicate labels and mapping previews');
select pg_temp.act('A employee');
select pg_temp.fails($$ select biometric_dat_batches() $$, 'Not allowed', 'T-SEC2d an employee cannot list imports');
select pg_temp.fails($$ select * from biometric_import_rows $$, 'permission denied', 'T-SEC3a direct table read refused (rows)');
select pg_temp.fails($$ select * from biometric_import_files $$, 'permission denied', 'T-SEC3b direct table read refused (files)');
select pg_temp.act('A admin');
select pg_temp.fails($$ select * from biometric_import_rows $$, 'permission denied', 'T-SEC3c even an Admin cannot read the table directly');
select pg_temp.fails($$ insert into biometric_import_rows (batch_id, source_device_id, line_no, raw_line, terminator, line_bytes, fields, parse_status, line_hash) values (gen_random_uuid(), gen_random_uuid(), 1, 'x', 'crlf', 1, '{}', 'ok', sha256('x')) $$,
  'permission denied', 'T-SEC3d direct insert refused');
select pg_temp.expect((biometric_dat_begin(current_setting('d.zk')::uuid, 'Asia/Kolkata', 10, repeat('a', 64), array[repeat('a', 64)]) ->> 'error') = 'no_import_format'
  and (biometric_dat_begin(current_setting('d.k21')::uuid, 'Asia/Kolkata', 10, repeat('a', 64), array[repeat('a', 64)]) ->> 'error') = 'no_import_format'
  and (biometric_dat_begin(current_setting('d.unassigned')::uuid, 'Asia/Kolkata', 10, repeat('a', 64), array[repeat('a', 64)]) ->> 'error') = 'no_import_format',
  'T-SEC5 / F4b a ZKTeco device, an eSSL K21 and an X2008 without an assigned format cannot import');
select pg_temp.expect((biometric_dat_begin(current_setting('d.remodel')::uuid, 'Asia/Kolkata', 10, repeat('a', 64), array[repeat('a', 64)]) ->> 'error') = 'model_not_supported',
  'F4c a device whose model was changed away from X2008 after the format was assigned is refused at import time');
select pg_temp.expect((select (d ->> 'eligible')::boolean and d ->> 'format_version' = 'essl.x2008.attlog/1' from jsonb_array_elements(biometric_dat_batches() -> 'devices') d where d ->> 'id' = current_setting('d.fx'))
  and (select not (d ->> 'eligible')::boolean and d ->> 'format_version' is null from jsonb_array_elements(biometric_dat_batches() -> 'devices') d where d ->> 'id' = current_setting('d.k21'))
  and not exists (select 1 from jsonb_array_elements(biometric_dat_batches() -> 'devices') d where d ->> 'id' = current_setting('d.zk')),
  'F4d the device list shows eSSL devices with their assigned format and whether the X2008 profile is allowed; non-eSSL devices are not listed');
select pg_temp.expect((select device_model = 'X2008' and device_firmware is null and format_version = 'essl.x2008.attlog/1' from pg_temp.bat(current_setting('d.p01')::uuid)),
  'F4e each batch records the device model, firmware and format profile used');
reset role; select pg_temp.as_user('');
set role anon;
select pg_temp.fails($$ select biometric_dat_batches() $$, 'permission denied', 'T-SEC2e anon cannot call DAT functions');
reset role;

-- ================================================================ 6. mapping resolution (T-MAP)
-- a small file on the X2008 test device around a mapping boundary (local Asia/Kolkata strings)
select pg_temp.act('A admin');
create function pg_temp.datfile(lines text[]) returns bytea language sql as $$ select convert_to(array_to_string(lines, E'\r\n') || E'\r\n', 'UTF8') $$;
select set_config('d.m1', pg_temp.dat_up(pg_temp.datfile(array[
  '       10' || E'\t2026-10-31 23:59:59\t1\t255\t1\t0',
  '       10' || E'\t2026-11-01 00:00:00\t1\t255\t1\t0',
  '       10' || E'\t2026-11-10 09:00:00\t1\t255\t1\t0',
  '       10' || E'\t2026-11-10 09:00:01\t1\t255\t1\t0',
  '       44' || E'\t2026-11-10 09:05:00\t1\t255\t1\t0']), current_setting('d.x2008')::uuid, 'Asia/Kolkata')::text, false);
select set_config('d.m2', pg_temp.dat_up(pg_temp.datfile(array[
  '       10' || E'\t2026-11-10 09:30:00\t1\t255\t1\t0', '       44' || E'\t2026-11-10 09:35:00\t1\t255\t1\t0']), current_setting('d.other')::uuid, 'Asia/Kolkata')::text, false);
select biometric_save_mapping('10', current_setting('d.x2008')::uuid, current_setting('d.wr198')::uuid, '2026-11-01 00:00:00+05:30', false);
select biometric_save_mapping('10', current_setting('d.other')::uuid, current_setting('d.wr777')::uuid, '2026-11-01 00:00:00+05:30', false);
create function pg_temp.mapst(bid uuid, n int) returns text language sql as $$
  select coalesce(r ->> 'mapping_status', '') || coalesce(':' || (r -> 'employee' ->> 'emp_code'), '') || coalesce(':' || (r ->> 'scope'), '')
    from jsonb_array_elements(biometric_dat_rows(bid, 'all', null, 0, 500) -> 'rows') r where (r ->> 'line')::int = n $$;
select pg_temp.expect(pg_temp.mapst(current_setting('d.m1')::uuid, 1) = 'unmapped' and pg_temp.mapst(current_setting('d.m1')::uuid, 2) = 'mapped:WR198:device',
  'T-MAP1 effective-from boundary: 23:59:59 the day before → unmapped; exactly 00:00:00 → mapped');
-- end the mapping at 2026-11-10 09:00:01 IST: the punch 1 s earlier stays mapped, the punch exactly at the end does not
select biometric_end_mapping((select id from biometric_employee_mappings where device_id = current_setting('d.x2008')::uuid and employee_device_code = '10' and valid_to is null),
  '2026-11-10 09:00:01+05:30', 'boundary test');
select pg_temp.expect(pg_temp.mapst(current_setting('d.m1')::uuid, 3) = 'mapped:WR198:device' and pg_temp.mapst(current_setting('d.m1')::uuid, 4) = 'unmapped',
  'T-MAP2 effective-to boundary: 1 s before the end mapped; exactly at the end not mapped');
select pg_temp.expect(pg_temp.mapst(current_setting('d.m2')::uuid, 1) = 'mapped:WR777:device',
  'T-MAP3 the same code 10 on a different device resolves to that device''s own mapping (WR777), never crossed');
select pg_temp.expect((biometric_save_mapping('44', current_setting('d.other')::uuid, current_setting('d.wr198')::uuid, '2026-10-01 00:00:00+05:30', false) ->> 'ok')::boolean,
  'T-MAP4a device mapping 44 → WR198 on the second device saved');
select pg_temp.expect(pg_temp.mapst(current_setting('d.m2')::uuid, 2) = 'mapped:WR198:device'
  and pg_temp.mapst(current_setting('d.m1')::uuid, 5) = 'mapped_employee_inactive:WR555:company',
  'T-MAP4/6 device mapping wins on its device; company-wide applies elsewhere; an inactive employee is shown as such');
select pg_temp.expect((select (c ->> 'unmapped')::int from jsonb_array_elements(biometric_dat_codes(current_setting('d.m1')::uuid) -> 'codes') c where c ->> 'code' = '10') = 2,
  'T-MAP5 unmapped records are counted per code; no mapping was created by the import');

-- ================================================================ 7. time zone and timestamps (T-TZ)
select set_config('d.tz', pg_temp.dat_up(pg_temp.datfile(array[
  '        1' || E'\t2026-03-29 01:30:00\t1\t255\t1\t0',     -- does not exist in Europe/London (clocks go forward)
  '        1' || E'\t2026-10-25 01:30:00\t1\t255\t1\t0',     -- happens twice in Europe/London (clocks go back)
  '        1' || E'\t2026-11-10 09:00:00\t1\t255\t1\t0']), current_setting('d.fx')::uuid, 'Europe/London')::text, false);
select pg_temp.act('owner');
select pg_temp.expect((pg_temp.row(current_setting('d.tz')::uuid, 1)).time_status = 'nonexistent_local_time' and (pg_temp.row(current_setting('d.tz')::uuid, 1)).instant is null
  and (pg_temp.row(current_setting('d.tz')::uuid, 2)).time_status = 'ambiguous_local_time' and (pg_temp.row(current_setting('d.tz')::uuid, 2)).instant is null
  and (pg_temp.row(current_setting('d.tz')::uuid, 3)).instant = timestamptz '2026-11-10 09:00:00+00'
  and (pg_temp.row(current_setting('d.tz')::uuid, 1)).local_time_text = '2026-03-29 01:30:00',
  'T-TZ1/2/3 gap and overlap times are never guessed (no instant); a normal time converts by the declared zone; strings unchanged');
select pg_temp.act('A admin');
select pg_temp.expect(pg_temp.mapst(current_setting('d.tz')::uuid, 1) = 'undetermined_time', 'T-TZ4 a record without an instant cannot be mapped (undetermined_time)');

-- ================================================================ 8. duplicates across imports and paths (T-DUP)
-- overlapping second export of the fixture device: the first 60 lines of f01 plus 10 new lines
select pg_temp.act('owner');
select set_config('d.over_b64', encode(convert_to(
  (select string_agg(raw_line || E'\r\n', '' order by line_no) from biometric_import_rows where batch_id = current_setting('d.p01')::uuid and line_no <= 60)
  || (select string_agg(lpad((2000 + g)::text, 9, ' ') || E'\t' || to_char(timestamp '2030-04-01 08:00:00' + g * interval '1 minute', 'YYYY-MM-DD HH24:MI:SS') || E'\t1\t255\t1\t0\r\n', '' order by g)
        from generate_series(1, 10) g), 'UTF8'), 'base64'), false);
select pg_temp.act('A admin');
select set_config('d.over', pg_temp.dat_up(pg_temp.b(current_setting('d.over_b64')), current_setting('d.fx')::uuid, 'Asia/Kolkata')::text, false);
select pg_temp.act('owner');
select pg_temp.expect((select count(*) from biometric_import_rows where batch_id = current_setting('d.over')::uuid and dup_class = 'exact_in_earlier_import'
   and dup_ref_batch = current_setting('d.p01')::uuid) = 60
  and (select count(*) from biometric_import_rows where batch_id = current_setting('d.over')::uuid and dup_class = 'new') = 10
  and pg_temp.nrows(current_setting('d.over')::uuid) = 70,
  'T-DUP2 overlapping second export: 60 repeated lines labelled with pointers to the first batch, 10 new; all 70 kept');
-- duplicate import versus SDK events: two raw events of code 55 at the same second on the pulled eSSL device; the file has three
select pg_temp.act('A admin');
select set_config('d.sdk', pg_temp.dat_up(pg_temp.datfile(array[
  '       55' || E'\t' || current_setting('d.base') || E'\t1\t255\t1\t0',
  '       55' || E'\t' || current_setting('d.base') || E'\t1\t255\t3\t0',
  '       55' || E'\t' || current_setting('d.base') || E'\t1\t255\t1\t0',
  '       56' || E'\t' || current_setting('d.base') || E'\t1\t255\t1\t0']), current_setting('d.pull')::uuid, 'Asia/Kolkata')::text, false);
select pg_temp.act('owner');
select pg_temp.expect((pg_temp.row(current_setting('d.sdk')::uuid, 1)).dup_class = 'already_from_device'
  and (pg_temp.row(current_setting('d.sdk')::uuid, 1)).dup_ref_raw_event = least(current_setting('d.raw1')::bigint, current_setting('d.raw2')::bigint)
  and (pg_temp.row(current_setting('d.sdk')::uuid, 2)).dup_class = 'same_code_time_other_fields'
  and (pg_temp.row(current_setting('d.sdk')::uuid, 3)).dup_class = 'exact_in_file'
  and (pg_temp.row(current_setting('d.sdk')::uuid, 4)).dup_class = 'new',
  'T-DUP3/6 vs SDK raw events: first file row already_from_device (pointer to the raw event); precedence keeps other labels; other code new');
select pg_temp.expect((select count(*) from biometric_raw_events where device_id = current_setting('d.pull')::uuid) = 2,
  'T-DUP3b the SDK raw events are untouched (still 2) and no raw event was created by the import');
select pg_temp.act('A admin');
select set_config('d.sdk5', pg_temp.dat_up(pg_temp.datfile(array['       55' || E'\t' || current_setting('d.base') || E'\t1\t255\t1\t0']),
  current_setting('d.x2008')::uuid, 'Asia/Kolkata')::text, false);
select pg_temp.act('owner');
select pg_temp.expect((pg_temp.row(current_setting('d.sdk5')::uuid, 1)).dup_class = 'new', 'T-DUP5 same code and time from a different device is not a duplicate');

-- ================================================================ 9. review, download, deletion, audit (T-DEL, T-AU)
select pg_temp.act('A admin');
select pg_temp.expect((biometric_dat_mark_reviewed(current_setting('d.p01')::uuid, 99) ->> 'error') = 'changed_meanwhile',
  'T-REV1 mark reviewed with a stale version is refused');
select pg_temp.expect((biometric_dat_mark_reviewed(current_setting('d.p01')::uuid, (biometric_dat_status(current_setting('d.p01')::uuid) ->> 'version')::int) ->> 'state') = 'reviewed',
  'T-REV2 mark reviewed (nothing else is written)');
select pg_temp.expect(decode(biometric_dat_download(current_setting('d.p01')::uuid) ->> 'data', 'base64') = pg_temp.b(:'f01'), 'T-DL the original downloads byte-identical');
select pg_temp.expect((biometric_dat_delete(current_setting('d.p01')::uuid, 'no') ->> 'error') = 'reason_required', 'T-DEL0 delete needs a reason');
select pg_temp.act('owner');
select set_config('d.audit_before_delete', (select count(*) from audit_log where target_id = current_setting('d.p01'))::text, false);
select pg_temp.act('A admin');
select pg_temp.expect((biometric_dat_delete(current_setting('d.p01')::uuid, 'test deletion of a reviewed batch') ->> 'state') = 'deleted', 'T-DEL1 delete a reviewed batch');
select pg_temp.act('owner');
select pg_temp.expect(pg_temp.nothing_kept(current_setting('d.p01')::uuid)
  and (select state = 'deleted' and file_name ~ '^x2008-' and delete_reason is not null and counts ->> 'lines' = '100' and file_sha256 is not null
              and ended_at is not null and not purge_pending
         from biometric_import_batches where id = current_setting('d.p01')::uuid)
  and (select count(*) from audit_log where target_id = current_setting('d.p01')) = current_setting('d.audit_before_delete')::int + 1,
  'T-DEL1b bytes and rows gone; tombstone keeps the generated name, counts and hash; every earlier audit entry still there, plus the deletion');
select pg_temp.act('A admin');
select pg_temp.expect((biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', octet_length(pg_temp.b(:'f01')),
  encode(sha256(pg_temp.b(:'f01')), 'hex'), pg_temp.chunks(pg_temp.b(:'f01'))) ->> 'ok') = 'true', 'T-UP16b after deletion the same file may be imported again');
select pg_temp.act('owner');
select pg_temp.expect(pg_temp.dat_audit_clean(), 'T-AU every DAT audit entry holds only allowed keys and no file name, code, time, line text or tab');
select pg_temp.expect((select count(*) from audit_log where action like 'dat\_import.%') > 20, 'T-AU2 actions are audited (begin, uploaded, ready, failed, expired, cancelled, reviewed, downloaded, deleted)');

-- ================================================================ 11. ownership: HR prepares, Admin approves (T-OWN)
select pg_temp.act('A hr');
select set_config('d.fh1', encode(pg_temp.datfile(array['      301' || E'\t2030-07-01 08:00:00\t1\t255\t1\t0', '      302' || E'\t2030-07-01 08:05:00\t1\t255\t1\t0']), 'base64'), false);
select set_config('d.fh1r', biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', octet_length(pg_temp.b(current_setting('d.fh1'))),
  encode(sha256(pg_temp.b(current_setting('d.fh1'))), 'hex'), pg_temp.chunks(pg_temp.b(current_setting('d.fh1'))))::text, false);
select set_config('d.hb', current_setting('d.fh1r')::jsonb ->> 'batch_id', false);
select pg_temp.expect((current_setting('d.fh1r')::jsonb ->> 'ok')::boolean
  and (biometric_dat_chunk(current_setting('d.hb')::uuid, current_setting('d.fh1r')::jsonb ->> 'upload_token', 0, current_setting('d.fh1')) ->> 'ok')::boolean
  and (biometric_dat_finish(current_setting('d.hb')::uuid, current_setting('d.fh1r')::jsonb ->> 'upload_token') ->> 'state') = 'uploaded',
  'T-OWN1 HR uploads a file (begin, chunk, finish)');
select pg_temp.act('A admin');
select pg_temp.fails(format($$ select biometric_dat_process(%L) $$, current_setting('d.hb')), 'Not allowed',
  'T-OWN2 an Admin cannot drive processing of HR''s upload (the uploader continues it)');
select pg_temp.expect((biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', octet_length(pg_temp.b(current_setting('d.fh1'))),
  encode(sha256(pg_temp.b(current_setting('d.fh1'))), 'hex'), pg_temp.chunks(pg_temp.b(current_setting('d.fh1')))) ->> 'error') = 'being_processed',
  'T-OWN3 someone else choosing the same file while it is processed is told it is being processed');
select pg_temp.act('A hr');
select pg_temp.expect((biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', octet_length(pg_temp.b(current_setting('d.fh1'))),
  encode(sha256(pg_temp.b(current_setting('d.fh1'))), 'hex'), pg_temp.chunks(pg_temp.b(current_setting('d.fh1'))))) ->> 'batch_id' = current_setting('d.hb')
  and (biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', octet_length(pg_temp.b(current_setting('d.fh1'))),
  encode(sha256(pg_temp.b(current_setting('d.fh1'))), 'hex'), pg_temp.chunks(pg_temp.b(current_setting('d.fh1'))))) ->> 'error' = 'continue_processing',
  'T-OWN4 / F3 the uploader choosing the same file again is offered "continue processing" for the interrupted batch');
select pg_temp.expect((biometric_dat_process(current_setting('d.hb')::uuid) ->> 'state') = 'parsing' and pg_temp.drain(current_setting('d.hb')::uuid) >= 1
  and pg_temp.st(current_setting('d.hb')::uuid) = 'ready_for_review' and pg_temp.nrows(current_setting('d.hb')::uuid) = 2,
  'T-OWN5 / F3 the uploader (HR) continues processing to ready for review; nothing lost or repeated');
select pg_temp.fails(format($$ select biometric_dat_mark_reviewed(%L, %s) $$, current_setting('d.hb'), (biometric_dat_status(current_setting('d.hb')::uuid) ->> 'version')),
  'Not allowed', 'T-OWN6 HR cannot mark a batch reviewed (Admin approves)');
select pg_temp.fails(format($$ select biometric_dat_delete(%L, 'not allowed for HR') $$, current_setting('d.hb')), 'Not allowed', 'T-OWN7 HR cannot delete a batch');
select pg_temp.fails(format($$ select biometric_dat_download(%L) $$, current_setting('d.hb')), 'Not allowed', 'T-OWN8 HR cannot download the original file');
select pg_temp.fails(format($$ select biometric_dat_set_device_format(%L, 'essl.x2008.attlog/1') $$, current_setting('d.unassigned')), 'Not allowed',
  'T-OWN9 HR cannot assign a device''s import format');
select pg_temp.act('A admin');
select pg_temp.expect((biometric_dat_mark_reviewed(current_setting('d.hb')::uuid, (biometric_dat_status(current_setting('d.hb')::uuid) ->> 'version')::int) ->> 'state') = 'reviewed',
  'T-OWN10 an Admin marks HR''s prepared batch reviewed');
-- cancelling: own upload (HR or Admin), someone else's only as Admin
select set_config('d.fa1', biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', 10, encode(sha256('own-a1'::bytea), 'hex'), array[encode(sha256('own-a1'::bytea), 'hex')]) ->> 'batch_id', false);
select pg_temp.act('A hr');
select set_config('d.fh2', biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', 10, encode(sha256('own-h2'::bytea), 'hex'), array[encode(sha256('own-h2'::bytea), 'hex')]) ->> 'batch_id', false);
select pg_temp.fails(format($$ select biometric_dat_cancel(%L) $$, current_setting('d.fa1')), 'Not allowed', 'T-OWN11 HR cannot cancel someone else''s upload');
select pg_temp.expect((biometric_dat_cancel(current_setting('d.fh2')::uuid) ->> 'state') = 'cancelled', 'T-OWN12 HR cancels their own upload');
select set_config('d.fh3', biometric_dat_begin(current_setting('d.fx')::uuid, 'Asia/Kolkata', 10, encode(sha256('own-h3'::bytea), 'hex'), array[encode(sha256('own-h3'::bytea), 'hex')]) ->> 'batch_id', false);
select pg_temp.act('A admin');
select pg_temp.expect((biometric_dat_cancel(current_setting('d.fh3')::uuid) ->> 'state') = 'cancelled' and (biometric_dat_cancel(current_setting('d.fa1')::uuid) ->> 'state') = 'cancelled',
  'T-OWN13 an Admin cancels someone else''s upload, and their own');

-- ================================================================ 12. permission matrix (T-PERM): every function and table, every role
create temp table dat_perm (who text, fn text, outcome text);
grant all on dat_perm to authenticated, anon;
create function pg_temp.try(q text) returns text language plpgsql as $$
declare r jsonb;
begin
  execute q into r;
  if r ->> 'error' = 'device_not_found' then return 'not_found'; end if;
  return 'allowed';
exception when others then
  if sqlerrm ~* 'not found' then return 'not_found';
  elsif sqlerrm ~* 'not allowed|permission denied' then return 'denied';
  else return 'error: ' || left(sqlerrm, 80); end if;
end $$;
create function pg_temp.try_table(t text) returns text language plpgsql as $$
begin
  execute format('select count(*) from public.%I', t);
  return 'allowed';
exception when insufficient_privilege then return 'denied';
end $$;
grant execute on function pg_temp.try(text), pg_temp.try_table(text) to anon;
do $$
declare who text; m text := current_setting('d.p05'); dev text := current_setting('d.fx'); q record;
begin
  foreach who in array array['A admin', 'A hr', 'A manager', 'A employee', 'B admin', 'B hr', 'B employee', 'anon'] loop
    if who = 'anon' then reset role; perform set_config('request.jwt.claim.sub', '', false); set role anon;
    else perform pg_temp.act(who); end if;
    for q in select * from (values
        ('begin', format('select biometric_dat_begin(%L, %L, 10, %L, array[%L])', dev, 'Asia/Kolkata', 'bad', 'bad')),
        ('chunk', format('select biometric_dat_chunk(%L, %L, 0, %L)', m, 'x', 'AA==')),
        ('resume', format('select biometric_dat_resume(%L)', m)),
        ('finish', format('select biometric_dat_finish(%L, %L)', m, 'x')),
        ('process', format('select biometric_dat_process(%L)', m)),
        ('status', format('select biometric_dat_status(%L)', m)),
        ('batches', 'select biometric_dat_batches()'),
        ('codes', format('select biometric_dat_codes(%L)', m)),
        ('rows', format('select biometric_dat_rows(%L, %L, null, 0, 5)', m, 'all')),
        ('housekeeping', 'select biometric_dat_housekeeping()'),
        ('cancel_others', format('select biometric_dat_cancel(%L)', m)),
        ('mark_reviewed', format('select biometric_dat_mark_reviewed(%L, -1)', m)),
        ('delete', format('select biometric_dat_delete(%L, %L)', m, 'x')),
        ('download', format('select biometric_dat_download(%L)', m)),
        ('set_device_format', format('select biometric_dat_set_device_format(%L, %L)', dev, 'nope'))) v(fn, sql) loop
      insert into dat_perm values (who, q.fn, pg_temp.try(q.sql));
    end loop;
    insert into dat_perm select who, 'table:' || t, pg_temp.try_table(t)
      from unnest(array['biometric_import_batches', 'biometric_import_chunks', 'biometric_import_files', 'biometric_import_rows', 'biometric_device_import_formats']) t;
  end loop;
  reset role;
end $$;
select pg_temp.act('owner');
create temp table dat_perm_expected (who text, fn text, outcome text);
insert into dat_perm_expected
select w.who, f.fn,
       case
         when f.fn like 'table:%' then 'denied'
         when w.who in ('A manager', 'A employee', 'B employee', 'anon') then 'denied'
         when w.who = 'A admin' then 'allowed'
         when w.who = 'A hr' then case when f.fn in ('cancel_others', 'mark_reviewed', 'delete', 'download', 'set_device_format') then 'denied' else 'allowed' end
         when w.who = 'B admin' then case when f.fn in ('batches', 'housekeeping') then 'allowed' else 'not_found' end
         when w.who = 'B hr' then case when f.fn in ('batches', 'housekeeping') then 'allowed'
                                       when f.fn in ('mark_reviewed', 'delete', 'download', 'set_device_format') then 'denied' else 'not_found' end
       end
  from (values ('A admin'), ('A hr'), ('A manager'), ('A employee'), ('B admin'), ('B hr'), ('B employee'), ('anon')) w(who)
  cross join (select distinct fn from dat_perm) f;
\echo 'Permission matrix (rows: function or table; columns: role) — allowed / denied / not_found (another company''s batch or device):'
select fn,
       max(outcome) filter (where who = 'A admin') as "A admin", max(outcome) filter (where who = 'A hr') as "A hr",
       max(outcome) filter (where who = 'A manager') as "A manager", max(outcome) filter (where who = 'A employee') as "A employee",
       max(outcome) filter (where who = 'B admin') as "B admin", max(outcome) filter (where who = 'B hr') as "B hr",
       max(outcome) filter (where who = 'B employee') as "B employee", max(outcome) filter (where who = 'anon') as "anon"
  from dat_perm group by fn order by fn;
select a.who, a.fn, a.outcome as got, e.outcome as expected from dat_perm a join dat_perm_expected e using (who, fn) where a.outcome is distinct from e.outcome;
select pg_temp.expect((select count(*) from dat_perm) = 8 * 20 and not exists (select 1 from dat_perm a join dat_perm_expected e using (who, fn) where a.outcome is distinct from e.outcome),
  'T-PERM 160 role × operation checks match the approved matrix (HR prepares and reads; Admin alone approves, deletes, downloads, cancels others, assigns formats; other company: not found; manager, employee, anon: denied; no role reads any import table directly)');
select pg_temp.act('B admin');
select pg_temp.expect(jsonb_array_length(biometric_dat_batches() -> 'batches') = 0 and jsonb_array_length(biometric_dat_batches() -> 'devices') = 0,
  'T-PERM2 another company''s Admin lists none of company A''s batches or devices');
select pg_temp.act('B hr');
select pg_temp.expect(jsonb_array_length(biometric_dat_batches() -> 'batches') = 0, 'T-PERM3 another company''s HR lists none of company A''s batches');

-- ================================================================ 13. retention and bounded deletion (T-RET)
select pg_temp.act('A admin');
select set_config('d.ret_list', biometric_dat_batches()::text, false);
select pg_temp.expect((select (x -> 'retention' ->> 'data_until')::timestamptz = (pg_temp.bat(current_setting('d.p02')::uuid)).ready_at + interval '30 days'
     from jsonb_array_elements(current_setting('d.ret_list')::jsonb -> 'batches') x where x ->> 'id' = current_setting('d.p02'))
  and (select (x -> 'retention' ->> 'data_until')::timestamptz = (pg_temp.bat(current_setting('d.hb')::uuid)).reviewed_at + interval '90 days'
     from jsonb_array_elements(current_setting('d.ret_list')::jsonb -> 'batches') x where x ->> 'id' = current_setting('d.hb'))
  and (select (x -> 'retention' ->> 'record_until')::timestamptz = (pg_temp.bat(current_setting('d.p04')::uuid)).ended_at + interval '3 years'
     from jsonb_array_elements(current_setting('d.ret_list')::jsonb -> 'batches') x where x ->> 'id' = current_setting('d.p04')),
  'T-RET1 the list shows the retention date: ready 30 days, reviewed 90 days after review, ended batches'' record 3 years');
select pg_temp.act('owner');
update biometric_import_batches set ready_at = now() - interval '31 days' where id = current_setting('d.p02')::uuid;
update biometric_import_batches set reviewed_at = now() - interval '91 days' where id = current_setting('d.hb')::uuid;
update biometric_import_batches set ended_at = now() - interval '3 years 1 day' where id = current_setting('d.p04')::uuid;
select set_config('d.audit_p04', (select count(*) from audit_log where target_id = current_setting('d.p04'))::text, false);
select pg_temp.act('A hr');
select pg_temp.expect((biometric_dat_housekeeping() ->> 'ok')::boolean, 'T-RET2 HR opening Biometric runs the bounded housekeeping');
select pg_temp.act('owner');
select pg_temp.expect(pg_temp.st(current_setting('d.p02')::uuid) = 'expired' and pg_temp.why(current_setting('d.p02')::uuid) = 'review_timeout'
  and pg_temp.nothing_kept(current_setting('d.p02')::uuid),
  'T-RET3 ready for review but not reviewed for 30 days: expired (review_timeout), file and rows removed, record kept');
select pg_temp.expect(pg_temp.st(current_setting('d.hb')::uuid) = 'expired' and pg_temp.why(current_setting('d.hb')::uuid) = 'retention_period'
  and pg_temp.nothing_kept(current_setting('d.hb')::uuid) and (pg_temp.bat(current_setting('d.hb')::uuid)).reviewed_at is not null,
  'T-RET4 reviewed 90 days ago: expired (retention_period), file and rows removed; who reviewed and when is kept');
select pg_temp.expect(pg_temp.bat(current_setting('d.p04')::uuid) is null
  and (select count(*) from audit_log where target_id = current_setting('d.p04')) = current_setting('d.audit_p04')::int + 1,
  'T-RET5 an ended batch''s non-personal record is removed 3 years after its data; its audit history stays (plus one removal entry)');
-- bounded deletion: a 17,000-row batch removed 5,000 rows per call; unreadable from the first call
select set_config('d.purge_n1', biometric_dat_end(current_setting('d.bb')::uuid, 'deleted', null, null, 5000)::text, false);
select pg_temp.expect(current_setting('d.purge_n1')::int = 5000 and pg_temp.nrows(current_setting('d.bb')::uuid) = 12000
  and (pg_temp.bat(current_setting('d.bb')::uuid)).purge_pending and pg_temp.st(current_setting('d.bb')::uuid) = 'deleted'
  and not exists (select 1 from biometric_import_files where batch_id = current_setting('d.bb')::uuid),
  'T-RET6 deletion removes the file at once and rows in bounded steps (5,000 of 17,000 in the first call)');
select pg_temp.act('A admin');
select pg_temp.fails(format($$ select biometric_dat_rows(%L, 'all', null, 0, 5) $$, current_setting('d.bb')), 'not ready for review',
  'T-RET7 a batch being removed is never readable (rows refused from the first step)');
select pg_temp.expect((biometric_dat_download(current_setting('d.bb')::uuid) ->> 'error') = 'no_file', 'T-RET7b … and has no file to download');
select pg_temp.act('owner');
select biometric_dat_expire(current_setting('t.ca')::uuid, 5000);
select biometric_dat_expire(current_setting('t.ca')::uuid, 5000);
select pg_temp.expect(pg_temp.nrows(current_setting('d.bb')::uuid) = 2000 and (pg_temp.bat(current_setting('d.bb')::uuid)).purge_pending,
  'T-RET8 each housekeeping call removes at most its budget (2,000 left after two more calls)');
select biometric_dat_expire(current_setting('t.ca')::uuid, 5000);
select pg_temp.expect(pg_temp.nrows(current_setting('d.bb')::uuid) = 0 and not (pg_temp.bat(current_setting('d.bb')::uuid)).purge_pending,
  'T-RET9 the next call finishes the removal and clears the pending flag');

-- ================================================================ 10. nothing outside import staging changed
select key as changed_table from jsonb_each_text(pg_temp.snapd()) n where n.value is distinct from (current_setting('d.snapd')::jsonb ->> n.key);
select pg_temp.expect(pg_temp.snap() = current_setting('d.snap'),
  'T-NO1 attendance events, sessions, register inputs, raw events, event state, sync runs, devices and employees are byte-for-byte unchanged by every import above');
select pg_temp.expect(not exists (select 1 from biometric_raw_events r join biometric_import_batches b on b.id = r.import_batch_id where b.state <> 'legacy')
  and not exists (select 1 from attendance_events a join biometric_import_batches b on b.id = a.import_batch_id where b.state <> 'legacy'),
  'T-NO2 no raw event and no attendance event came from an import');

\echo ALL BIOMETRIC DAT IMPORT TESTS PASSED
