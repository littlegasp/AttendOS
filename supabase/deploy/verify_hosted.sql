-- AttendOS: read-only checks to run in the hosted Supabase SQL editor AFTER migrations 0001–0009 (and 0010/0011 when installed).
-- Changes nothing. Every row should show ok = true. Safe to run any number of times.
with
tables as (
  select c.oid, c.relname, c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'),
fns as (
  select p.oid, p.proname, p.prosecdef, p.proconfig, p.proacl from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'),
checks(item, ok, detail) as (
  select '1. AttendOS tables exist (21; 32 with biometric 0010)', (select count(*) from tables) = 21 + (select count(*) from tables where relname like 'biometric%')
           and (select count(*) from tables where relname like 'biometric%') in (0, 11), (select string_agg(relname, ', ' order by relname) from tables)
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
  select '13. Biometric 0010 (if installed): credentials unreadable, payload columns not granted, 12 checked functions only',
         case when to_regclass('public.biometric_raw_events') is null then true else
           not has_table_privilege('authenticated', to_regclass('public.biometric_agent_credentials'), 'select')
           and not has_column_privilege('authenticated', to_regclass('public.biometric_raw_events'), 'raw_payload', 'select')
           and not has_column_privilege('authenticated', to_regclass('public.biometric_event_errors'), 'payload', 'select')
           and (select count(*) from fns where proname like 'biometric\_%' and has_function_privilege('authenticated', oid, 'execute')) = 12 end,
         case when to_regclass('public.biometric_raw_events') is null then 'not installed' else 'installed' end
)
select item, ok, detail from checks order by split_part(item, '.', 1)::int;
