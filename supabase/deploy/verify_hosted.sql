-- AttendOS: read-only checks to run on the hosted project AFTER migrations 0001–0009 (and 0010–0013 when installed).
-- Development preflight: run through supabase/deploy/dev_preflight/dev_sql.py (guarded). Items 15–21 cover 0013 (B5 DAT import).
-- Changes nothing. Every row should show ok = true. Safe to run any number of times.
with
tables as (
  select c.oid, c.relname, c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'),
fns as (
  select p.oid, p.proname, p.prosecdef, p.proconfig, p.proacl from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'),
checks(item, ok, detail) as (
  select '1. AttendOS tables exist (21; 32 with biometric 0010–0012; 36 with 0013)', (select count(*) from tables) = 21 + (select count(*) from tables where relname like 'biometric%')
           and (select count(*) from tables where relname like 'biometric%') in (0, 11, 15), (select string_agg(relname, ', ' order by relname) from tables)
  union all
  select '2. Row level security is on for every table', not exists (select 1 from tables where not relrowsecurity),
         coalesce((select string_agg(relname, ', ') from tables where not relrowsecurity), 'all on')
  union all
  select '3. Anonymous visitors have no table access',
         not exists (select 1 from tables t where has_table_privilege('anon', t.oid, 'select') or has_table_privilege('anon', t.oid, 'insert')
                     or has_table_privilege('anon', t.oid, 'update') or has_table_privilege('anon', t.oid, 'delete')), ''
  union all
  select '4. Anonymous visitors can call only company_brand (and the two device-gateway functions once 0011 is installed)',
         (select coalesce(array_agg(proname::text order by proname), '{}') from fns where has_function_privilege('anon', oid, 'execute'))
           = case when to_regprocedure('public.biometric_ingest(text, jsonb)') is null then array['company_brand']
                  else array['biometric_heartbeat', 'biometric_ingest', 'company_brand'] end,
         (select string_agg(proname, ', ') from fns where has_function_privilege('anon', oid, 'execute'))
  union all
  select '5. No function is callable by PUBLIC by default',
         not exists (select 1 from fns where proacl is null or exists (select 1 from aclexplode(proacl) a where a.grantee = 0)), ''
  union all
  select '6. Every SECURITY DEFINER function pins search_path',
         not exists (select 1 from fns where prosecdef and not exists (select 1 from unnest(proconfig) cfg where cfg like 'search_path=%')), ''
  union all
  select '7. Login-linking triggers on auth.users',
         (select count(*) from pg_trigger where tgrelid = 'auth.users'::regclass and tgname in ('on_auth_user_created', 'on_auth_user_confirmed')) = 2, ''
  union all
  select '8. Latest migrations present (0007 invitations, 0008 guarded roster, 0009 link on reactivation)',
         exists (select 1 from fns where proname = 'set_roster_pattern_core') and exists (select 1 from fns where proname = 'prepare_invitation')
         and exists (select 1 from pg_trigger where tgname = 'zz_link_existing_login' and pg_get_triggerdef(oid) like '%UPDATE OF email, active%'), ''
  union all
  select '9. Auth hook function exists and Auth may call it',
         exists (select 1 from fns where proname = 'hook_before_user_created')
         and coalesce((select has_function_privilege('supabase_auth_admin', 'public.hook_before_user_created(jsonb)', 'execute')
                       where exists (select 1 from pg_roles where rolname = 'supabase_auth_admin')), false), 'enable it in Authentication → Hooks'
  union all
  select '10. Signed-in API timeout left at the Supabase default (not raised)',
         coalesce((select not exists (select 1 from unnest(rolconfig) c where c like 'statement_timeout=%' and c not in ('statement_timeout=8s', 'statement_timeout=8000'))
                     from pg_roles where rolname = 'authenticated'), true),
         coalesce((select array_to_string(rolconfig, ' ') from pg_roles where rolname = 'authenticated'), 'default')
  union all
  select '11. Companies created', true, coalesce((select string_agg(slug || ' (' || timezone || case when active then '' else ', inactive' end || ')', ', ') from public.companies), 'none yet')
  union all
  select '12. No sample/demo data present', not exists (select 1 from public.companies where slug in ('acme', 'beta', 'gamma', 'perf'))
         and not exists (select 1 from public.audit_log where source = 'seed'), 'demo/perf scripts must never run here'
  union all
  select '13. Biometric (if installed): credentials unreadable, payload columns not granted, only the checked functions (12 from 0010, +1 with 0011, +4 with 0012, +15 DAT with 0013)',
         case when to_regclass('public.biometric_raw_events') is null then true else
           not has_table_privilege('authenticated', to_regclass('public.biometric_agent_credentials'), 'select')
           and not has_column_privilege('authenticated', to_regclass('public.biometric_raw_events'), 'raw_payload', 'select')
           and not has_column_privilege('authenticated', to_regclass('public.biometric_event_errors'), 'payload', 'select')
           -- 12 from 0010, + biometric_set_device_auth (0011), + project_now, day_pending, shift_gap_warnings, retry_day (0012)
           and (select count(*) from fns where proname like 'biometric\_%' and has_function_privilege('authenticated', oid, 'execute'))
               = 12 + case when exists (select 1 from fns where proname = 'biometric_ingest') then 1 else 0 end
                    + case when exists (select 1 from fns where proname = 'biometric_project_day') then 4 else 0 end
                    + case when exists (select 1 from fns where proname = 'biometric_dat_begin') then 15 else 0 end end,
         case when to_regclass('public.biometric_raw_events') is null then 'not installed' else 'installed' end
  union all
  select '14. Biometric 0012 (if installed): projection internals and decide_correction_core callable by no client role; guard present; projection off unless deliberately enabled',
         case when not exists (select 1 from fns where proname = 'biometric_project_day') then true else
           not exists (select 1 from fns where proname in ('biometric_project_day', 'biometric_run_projection', 'biometric_project_one', 'biometric_set_role',
                         'biometric_write_slot', 'biometric_work_date_at', 'biometric_day_close_at', 'biometric_hold_next_check', 'biometric_day_failures',
                         'attendance_external_guard', 'decide_correction_core')
                         and (has_function_privilege('anon', oid, 'execute') or has_function_privilege('authenticated', oid, 'execute')))
           and exists (select 1 from pg_trigger where tgname = 'external_guard' and tgrelid = 'public.attendance_events'::regclass and tgenabled = 'O')
           and not exists (select 1 from public.attendance_events where source not in ('web', 'correction', 'biometric', 'import')) end,
         case when not exists (select 1 from fns where proname = 'biometric_project_day') then 'not installed' else
           -- read through query_to_xml so this file also runs before 0010 (the table is resolved only when it exists)
           'installed; projection enabled for: ' || coalesce((xpath('/row/v/text()', query_to_xml($q$select string_agg(c.slug, ', ') as v
                      from public.biometric_settings b join public.companies c on c.id = b.company_id where b.projection_enabled$q$, false, true, '')))[1]::text,
                    'no company') end
  -- ---------------------------------------------------------------- 0013 B5 DAT import (each item is true when 0013 is not installed)
  union all
  select '15. DAT 0013 (if installed): the four new tables exist with row level security on; the batch table has the 0013 state columns',
         case when to_regclass('public.biometric_import_rows') is null then true else
           (select count(*) from tables where relname in ('biometric_import_chunks', 'biometric_import_files', 'biometric_import_rows', 'biometric_device_import_formats') and relrowsecurity) = 4
           and exists (select 1 from pg_attribute where attrelid = to_regclass('public.biometric_import_batches') and attname = 'purge_pending' and not attisdropped) end,
         case when to_regclass('public.biometric_import_rows') is null then 'not installed' else 'installed' end
  union all
  select '16. DAT 0013: no API role (anon, authenticated, PUBLIC) holds any table or column privilege on the five import tables; the batch table has no read policy (F1)',
         case when to_regclass('public.biometric_import_rows') is null then true else
           not exists (select 1 from information_schema.role_table_grants where table_schema = 'public'
                        and table_name in ('biometric_import_batches', 'biometric_import_chunks', 'biometric_import_files', 'biometric_import_rows', 'biometric_device_import_formats')
                        and grantee in ('anon', 'authenticated', 'PUBLIC'))
           and not exists (select 1 from information_schema.column_privileges where table_schema = 'public'
                        and table_name in ('biometric_import_batches', 'biometric_device_import_formats') and grantee in ('anon', 'authenticated', 'PUBLIC'))
           and not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'biometric_import_batches') end, ''
  union all
  select '17. DAT 0013: exactly the 15 checked functions are callable by signed-in users, none by anon; every helper by neither',
         case when to_regclass('public.biometric_import_rows') is null then true else
           (select coalesce(array_agg(proname::text order by proname), '{}') from fns where proname like 'biometric\_dat\_%' and has_function_privilege('authenticated', oid, 'execute'))
             = array['biometric_dat_batches', 'biometric_dat_begin', 'biometric_dat_cancel', 'biometric_dat_chunk', 'biometric_dat_codes', 'biometric_dat_delete',
                     'biometric_dat_download', 'biometric_dat_finish', 'biometric_dat_housekeeping', 'biometric_dat_mark_reviewed', 'biometric_dat_process',
                     'biometric_dat_resume', 'biometric_dat_rows', 'biometric_dat_set_device_format', 'biometric_dat_status']
           and not exists (select 1 from fns where proname like 'biometric\_dat\_%' and has_function_privilege('anon', oid, 'execute')) end,
         coalesce((select string_agg(proname, ', ' order by proname) from fns where proname like 'biometric\_dat\_%' and has_function_privilege('authenticated', oid, 'execute')), '')
  union all
  select '18. DAT 0013: the whole-row audit() trigger is not attached to any import table (audit entries carry ids, counts and hashes only)',
         case when to_regclass('public.biometric_import_rows') is null then true else
           not exists (select 1 from pg_trigger t join pg_proc p on p.oid = t.tgfoid
                        where t.tgrelid in (select oid from tables where relname like 'biometric\_import\_%' or relname = 'biometric_device_import_formats')
                          and p.proname = 'audit') end, ''
  union all
  select '19. DAT 0013: the migration role owns the import rows table (so the ANALYZE after parsing, fix F2, is permitted)',
         case when to_regclass('public.biometric_import_rows') is null then true else
           pg_has_role(current_user, (select relowner from pg_class where oid = to_regclass('public.biometric_import_rows')), 'MEMBER') end,
         case when to_regclass('public.biometric_import_rows') is null then '' else
           'owner ' || pg_get_userbyid((select relowner from pg_class where oid = to_regclass('public.biometric_import_rows'))) || ', checked as ' || current_user end
  union all
  select '20. CREATE on schema public refused for anon and authenticated (owner decision D5)',
         not has_schema_privilege('anon', 'public', 'CREATE') and not has_schema_privilege('authenticated', 'public', 'CREATE'),
         'anon=' || has_schema_privilege('anon', 'public', 'CREATE')::text || ', authenticated=' || has_schema_privilege('authenticated', 'public', 'CREATE')::text
  union all
  select '21. pg_cron not installed (no scheduled jobs; projection is never started by a schedule)',
         not exists (select 1 from pg_extension where extname = 'pg_cron'), ''
)
select item, ok, detail from checks order by split_part(item, '.', 1)::int;
