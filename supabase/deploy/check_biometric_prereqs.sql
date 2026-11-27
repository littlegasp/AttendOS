-- AttendOS biometric: READ-ONLY prerequisite check for the hosted project, before and between migrations 0001–0013.
-- Development preflight (G3): run through supabase/deploy/dev_preflight/dev_sql.py (guarded: development marker and
-- exact project reference) — never in the SQL editor of another project. Role postgres. It changes nothing: no
-- extension is created, no setting or privilege changed.
--
-- Every row has a result:
--   PASS  the requirement is met            FAIL  it is not met (the row says what to do or that it is a STOP)
--   N/A   not applicable in this state      INFO  shown for the record, never blocks
-- The last row (99) is the summary: FAIL if any row failed.
--
-- Safe on any state: a brand-new database (no extensions, no AttendOS tables), extensions only, and after 0001–0009,
-- 0001–0012 or 0001–0013. Nothing assumes that an AttendOS table, column, the API roles or the Auth schema exists:
-- objects that may be missing are tested first (to_regclass / to_regrole / catalogs) and only then read, through
-- query_to_xml, so a missing object can never stop the script with an SQL error. (Rows 13–20 added 23 Nov 2026; the
-- result column and the any-state guarantees 27 Nov 2026, tested by rehearsal/test_prereqs_states.py.)
with
avail as (select name, default_version, installed_version from pg_available_extensions where name in ('btree_gist', 'pgcrypto', 'pg_cron')),
inst as (select e.extname, n.nspname as schema, e.extversion from pg_extension e join pg_namespace n on n.oid = e.extnamespace
          where e.extname in ('btree_gist', 'pgcrypto', 'pg_cron')),
roles as (select rolname, coalesce(array_to_string(rolconfig, ' '), '') as cfg from pg_roles where rolname in ('anon', 'authenticated', 'authenticator', 'postgres')),
pub as (select oid, nspacl from pg_namespace where nspname = 'public'),
-- settings through pg_settings, which lists only what this role may see: current_setting() raises "permission denied"
-- for restricted settings even with missing_ok (Supabase's postgres is not a superuser)
gs as (select (select setting from pg_settings where name = 'shared_preload_libraries') as preload,
              (select setting from pg_settings where name = 'supautils.privileged_extensions') as supautils_ext),
-- which AttendOS migrations are present, from the objects they create (works without the development marker)
mig as (select to_regclass('public.attendance_events') is not null as m0001,
               to_regclass('public.biometric_devices') is not null as m0010,
               exists (select 1 from pg_proc where proname = 'biometric_heartbeat' and pronamespace = to_regnamespace('public')) as m0011,
               exists (select 1 from pg_proc where proname = 'biometric_project_day' and pronamespace = to_regnamespace('public')) as m0012,
               to_regclass('public.biometric_import_rows') is not null as m0013,
               exists (select 1 from pg_attribute where attrelid = to_regclass('public.attendance_events')
                        and attname = 'source' and not attisdropped) as has_source,
               -- row 12 may read the table only if this role can see every row (owner or BYPASSRLS, as Supabase's
               -- postgres); otherwise it reports FAIL instead of an error or a partial answer
               coalesce((select has_table_privilege(c.oid, 'SELECT')
                           and (not c.relrowsecurity or (select rolbypassrls from pg_roles where rolname = current_user)
                                or (pg_has_role(c.relowner, 'USAGE') and not c.relforcerowsecurity))
                           from pg_class c where c.oid = to_regclass('public.attendance_events')), false) as can_read_events),
r as (
select 1 as n, 'PostgreSQL version (15+ needed: UNIQUE … NULLS NOT DISTINCT)' as item,
       case when current_setting('server_version_num')::int >= 150000 then 'PASS' else 'FAIL' end as result,
       current_setting('server_version') as found, '0010' as needed_by
union all
select 2, 'btree_gist available (exclusion constraints on mapping validity)',
       case when exists (select 1 from avail where name = 'btree_gist') then 'PASS' else 'FAIL' end,
       coalesce((select 'available ' || default_version || coalesce(', installed ' || installed_version, ', not installed') from avail where name = 'btree_gist'), 'NOT AVAILABLE — STOP'),
       '0010 (required)'
union all
select 3, 'btree_gist installed — and in which schema',
       'INFO',
       coalesce((select schema || ' ' || extversion from inst where extname = 'btree_gist'), 'not installed (0010 installs it in schema "extensions")'),
       '0010'
union all
select 4, 'schema "extensions" exists (Supabase standard)',
       case when to_regnamespace('extensions') is not null then 'PASS' else 'FAIL' end,
       case when to_regnamespace('extensions') is null then 'missing — not a standard Supabase project' else 'present' end, '0010'
union all
select 5, 'pgcrypto (not required: 0010 uses core gen_random_uuid() and sha256())',
       'INFO',
       coalesce((select 'available ' || default_version || coalesce(', installed ' || installed_version, ', not installed') from avail where name = 'pgcrypto'), 'not available'),
       'none'
union all
select 6, 'pg_cron available (scheduled projection — not used in this preflight)',
       'INFO',
       coalesce((select 'available ' || default_version || coalesce(', installed ' || installed_version, ', not installed') from avail where name = 'pg_cron'), 'not available'),
       'later stage, not authorised'
union all
select 7, 'pg_cron preloaded (shared_preload_libraries — not used in this preflight)',
       'INFO',
       coalesce(nullif((select preload from gs), ''), '(empty or not visible to this role)'),
       'later stage, not authorised'
union all
select 8, 'Extensions this role may install (Supabase supautils allow-list)',
       case when exists (select 1 from inst where extname = 'btree_gist') then 'PASS'
            when (select supautils_ext from gs) is null then 'INFO'
            when (select supautils_ext from gs) ~ 'btree_gist' then 'PASS' else 'FAIL' end,
       case when exists (select 1 from inst where extname = 'btree_gist') then 'btree_gist already installed'
            else coalesce(nullif((select supautils_ext from gs), ''),
                          '(setting not visible — if 0010 cannot install btree_gist, enable it in Dashboard → Database → Extensions)') end,
       '0010'
union all
select 9, 'Current role and CREATE on the database',
       case when has_database_privilege(current_database(), 'CREATE') then 'PASS' else 'FAIL' end,
       current_user || ' / create=' || has_database_privilege(current_database(), 'CREATE')::text, '0010'
union all
select 10, 'API role timeouts (read only — must not be raised)',
       'INFO',
       coalesce((select string_agg(rolname || ': ' || coalesce(nullif(cfg, ''), 'default'), '; ' order by rolname) from roles), 'no API roles found'),
       'gateway sizing (0011)'
union all
select 11, 'Default privileges in public (does Supabase auto-grant new tables/functions?)',
       'INFO',
       coalesce((select string_agg(pg_get_userbyid(d.defaclrole) || ' ' || d.defaclobjtype::text || ': ' || array_to_string(d.defaclacl, ','), ' | ')
                   from pg_default_acl d join pg_namespace n on n.oid = d.defaclnamespace where n.nspname = 'public'), 'none'),
       'information — 0010 revokes explicitly either way'
union all
select 12, 'attendance_events.source values (0012 stops unless only web/correction exist; history is never edited)',
       case when not (select m0001 from mig) or not (select has_source from mig) then 'N/A'
            when not (select can_read_events from mig) then 'FAIL'
            when (xpath('/row/v/text()', query_to_xml($q$select not exists (select 1 from public.attendance_events
                   where source is null or source not in ('web', 'correction', 'biometric', 'import')) as v$q$, false, true, '')))[1]::text = 'true'
            then 'PASS' else 'FAIL' end,
       case when not (select m0001 from mig) then 'table not created yet (before 0001)'
            when not (select has_source from mig) then 'column source not present'
            when not (select can_read_events from mig) then 'this role cannot see every row — run as the project''s postgres role'
            else (xpath('/row/v/text()', query_to_xml($q$select coalesce(string_agg(coalesce(source, 'NULL') || ' ' || n, ', ' order by source), 'no rows') as v
                   from (select source, count(*) n from public.attendance_events group by source) x$q$, false, true, '')))[1]::text end,
       '0012 preflight'
union all
select 13, 'CREATE on schema public for anon (owner decision D5: must be refused; revoke with dev_revoke_public_create.sql)',
       case when to_regrole('anon') is null then 'FAIL' when has_schema_privilege('anon', 'public', 'CREATE') then 'FAIL' else 'PASS' end,
       case when to_regrole('anon') is null then 'role anon missing — not a Supabase project'
            else 'anon create=' || has_schema_privilege('anon', 'public', 'CREATE')::text end,
       'D5 / review F7'
union all
select 14, 'CREATE on schema public for authenticated (D5: must be refused)',
       case when to_regrole('authenticated') is null then 'FAIL' when has_schema_privilege('authenticated', 'public', 'CREATE') then 'FAIL' else 'PASS' end,
       case when to_regrole('authenticated') is null then 'role authenticated missing — not a Supabase project'
            else 'authenticated create=' || has_schema_privilege('authenticated', 'public', 'CREATE')::text end,
       'D5 / review F7'
union all
select 15, 'CREATE on schema public granted to PUBLIC (if FAIL: revoking from anon/authenticated alone is not enough — STOP and report)',
       case when exists (select 1 from pub, aclexplode(pub.nspacl) a where a.privilege_type = 'CREATE' and a.grantee = 0) then 'FAIL' else 'PASS' end,
       coalesce((select string_agg(case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end || ':' || a.privilege_type, ', ')
                   from pub, aclexplode(pub.nspacl) a where a.privilege_type = 'CREATE'), 'none'),
       'D5'
union all
select 16, 'Signed-in API role statement_timeout (DAT calls were designed and measured against 8 s; role or database level)',
       case when to_regrole('authenticated') is null then 'FAIL'
            when coalesce((select cfg from roles where rolname = 'authenticated'), '') ~ 'statement_timeout='
              or exists (select 1 from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase, unnest(s.setconfig) c
                          where d.datname = current_database() and s.setrole = to_regrole('authenticated') and c like 'statement_timeout=%')
            then 'PASS' else 'FAIL' end,
       case when to_regrole('authenticated') is null then 'role authenticated missing'
            else coalesce(nullif((select cfg from roles where rolname = 'authenticated'), ''), 'no role-level setting') || coalesce(' [this database: ' ||
                 (select array_to_string(s.setconfig, ' ') from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase
                   where d.datname = current_database() and s.setrole = to_regrole('authenticated')) || ']', '') end,
       '0013 performance'
union all
select 17, 'This role may act as authenticated (needed by the guarded DB-level performance test, which sets role authenticated)',
       case when to_regrole('authenticated') is null then 'FAIL' when pg_has_role(current_user, 'authenticated', 'MEMBER') then 'PASS' else 'FAIL' end,
       case when to_regrole('authenticated') is null then 'role authenticated missing'
            else current_user || ' member of authenticated=' || pg_has_role(current_user, 'authenticated', 'MEMBER')::text end,
       'G6 dat_hosted_scale.py'
union all
select 18, 'This role bypasses row level security? (information: the DAT functions filter by company explicitly)',
       'INFO',
       current_user || ' bypassrls=' || (select rolbypassrls from pg_roles where rolname = current_user)::text, 'information'
union all
select 19, 'pg_cron NOT installed (no scheduled jobs in this preflight; projection stays off)',
       case when exists (select 1 from inst where extname = 'pg_cron') then 'FAIL' else 'PASS' end,
       coalesce((select 'installed in ' || schema || ' — STOP' from inst where extname = 'pg_cron'), 'not installed'),
       'owner boundary'
union all
select 20, 'Supabase Auth schema present (auth.users) — logins for the synthetic test users',
       case when to_regclass('auth.users') is not null then 'PASS' else 'FAIL' end,
       case when to_regclass('auth.users') is null then 'missing — not a Supabase project' else 'present' end, '0001 / 0005'
union all
select 21, 'AttendOS migrations present (detected from their objects)',
       'INFO',
       (select case when m0013 then '0001–0013' when m0012 then '0001–0012' when m0011 then '0001–0011' when m0010 then '0001–0010'
                    when m0001 then '0001–0009 (no biometric tables)' else 'none (fresh project)' end from mig),
       'information'
)
select n, item, result, found, needed_by from r
union all
select 99, 'SUMMARY',
       case when exists (select 1 from r where result = 'FAIL') then 'FAIL' else 'PASS' end,
       (select count(*) filter (where result = 'PASS') || ' pass, ' || count(*) filter (where result = 'FAIL') || ' fail'
               || coalesce(' (' || string_agg(n::text, ', ' order by n) filter (where result = 'FAIL') || ')', '') || ', '
               || count(*) filter (where result = 'N/A') || ' n/a, ' || count(*) filter (where result = 'INFO') || ' info' from r),
       ''
order by n;
