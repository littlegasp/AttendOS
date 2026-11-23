-- AttendOS biometric: READ-ONLY prerequisite check for the hosted project, before migrations 0001–0013.
-- Development preflight (G3): run through supabase/deploy/dev_preflight/dev_sql.py (guarded: development marker and
-- exact project reference) — never in the SQL editor of another project. Role postgres. It changes nothing: no
-- extension is created, no setting or privilege changed. Every row shows what is needed, what the project has, and
-- whether that is enough. Rows 13–20 were added for 0013 and the development preflight (23 Nov 2026).
with
avail as (select name, default_version, installed_version from pg_available_extensions where name in ('btree_gist', 'pgcrypto', 'pg_cron')),
inst as (select e.extname, n.nspname as schema, e.extversion from pg_extension e join pg_namespace n on n.oid = e.extnamespace
          where e.extname in ('btree_gist', 'pgcrypto', 'pg_cron')),
roles as (select rolname, coalesce(array_to_string(rolconfig, ' '), '') as cfg from pg_roles where rolname in ('anon', 'authenticated', 'authenticator', 'postgres')),
pub as (select oid from pg_namespace where nspname = 'public')
select 1 as n, 'PostgreSQL version (15+ needed: UNIQUE … NULLS NOT DISTINCT)' as item,
       current_setting('server_version') as found, current_setting('server_version_num')::int >= 150000 as ok, '0010' as needed_by
union all
select 2, 'btree_gist available (exclusion constraints on mapping validity)',
       coalesce((select 'available ' || default_version || coalesce(', installed ' || installed_version, ', not installed') from avail where name = 'btree_gist'), 'NOT AVAILABLE'),
       exists (select 1 from avail where name = 'btree_gist'), '0010 (required)'
union all
select 3, 'btree_gist installed — and in which schema',
       coalesce((select schema || ' ' || extversion from inst where extname = 'btree_gist'), 'not installed (0010 installs it in schema "extensions")'),
       true, '0010'
union all
select 4, 'schema "extensions" exists (Supabase standard)',
       case when to_regnamespace('extensions') is null then 'missing' else 'present' end, to_regnamespace('extensions') is not null, '0010'
union all
select 5, 'pgcrypto (not required: 0010 uses core gen_random_uuid() and sha256())',
       coalesce((select 'available ' || default_version || coalesce(', installed ' || installed_version, ', not installed') from avail where name = 'pgcrypto'), 'not available'),
       true, 'none'
union all
select 6, 'pg_cron available (scheduled projection)',
       coalesce((select 'available ' || default_version || coalesce(', installed ' || installed_version, ', not installed') from avail where name = 'pg_cron'), 'NOT AVAILABLE'),
       exists (select 1 from avail where name = 'pg_cron'), '0012 (later)'
union all
select 7, 'pg_cron preloaded (shared_preload_libraries)',
       coalesce(current_setting('shared_preload_libraries', true), '(not readable by this role)'),
       coalesce(current_setting('shared_preload_libraries', true), '') like '%pg_cron%', '0012 (later)'
union all
select 8, 'Extensions this role may install (Supabase supautils allow-list)',
       coalesce(nullif(current_setting('supautils.privileged_extensions', true), ''), '(setting not visible — install from Dashboard → Database → Extensions)'),
       coalesce(current_setting('supautils.privileged_extensions', true), '') ~ 'btree_gist' or current_setting('supautils.privileged_extensions', true) is null, '0010'
union all
select 9, 'Current role and CREATE on the database',
       current_user || ' / create=' || has_database_privilege(current_database(), 'CREATE')::text, has_database_privilege(current_database(), 'CREATE'), '0010'
union all
select 10, 'API role timeouts (read only — must not be raised)',
       (select string_agg(rolname || ': ' || coalesce(nullif(cfg, ''), 'default'), '; ' order by rolname) from roles), true, 'gateway sizing (0011)'
union all
select 11, 'Default privileges in public (does Supabase auto-grant new tables/functions?)',
       coalesce((select string_agg(pg_get_userbyid(d.defaclrole) || ' ' || d.defaclobjtype::text || ': ' || array_to_string(d.defaclacl, ','), ' | ')
                   from pg_default_acl d join pg_namespace n on n.oid = d.defaclnamespace where n.nspname = 'public'), 'none'),
       true, 'information — 0010 revokes explicitly either way'
union all
select 12, 'attendance_events.source values before 0012 (0012 stops unless only web/correction exist; history is never edited)',
       case when to_regclass('public.attendance_events') is null then 'table not created yet (fresh project, before 0001)'
            else (xpath('/row/v/text()', query_to_xml($q$select coalesce(string_agg(coalesce(source, 'NULL') || ' ' || n, ', ' order by source), 'no rows') as v
                   from (select source, count(*) n from public.attendance_events group by source) x$q$, false, false, '')))[1]::text end,
       case when to_regclass('public.attendance_events') is null then true
            else (xpath('/row/v/text()', query_to_xml($q$select not exists (select 1 from public.attendance_events
                   where source is null or source not in ('web', 'correction', 'biometric', 'import')) as v$q$, false, false, '')))[1]::text::boolean end,
       '0012 preflight'
union all
select 13, 'CREATE on schema public for anon (owner decision D5: must be refused; revoke with dev_revoke_public_create.sql)',
       'anon create=' || has_schema_privilege('anon', 'public', 'CREATE')::text, not has_schema_privilege('anon', 'public', 'CREATE'), 'D5 / review F7'
union all
select 14, 'CREATE on schema public for authenticated (D5: must be refused)',
       'authenticated create=' || has_schema_privilege('authenticated', 'public', 'CREATE')::text, not has_schema_privilege('authenticated', 'public', 'CREATE'), 'D5 / review F7'
union all
select 15, 'CREATE on schema public granted to PUBLIC (if true, revoking from anon/authenticated alone is not enough: STOP and report)',
       coalesce((select string_agg(case when a.grantee = 0 then 'PUBLIC' else pg_get_userbyid(a.grantee) end || ':' || a.privilege_type, ', ')
                   from pub, aclexplode((select nspacl from pg_namespace where oid = pub.oid)) a where a.privilege_type = 'CREATE'), 'none'),
       not exists (select 1 from pub, aclexplode((select nspacl from pg_namespace where oid = pub.oid)) a where a.privilege_type = 'CREATE' and a.grantee = 0),
       'D5'
union all
select 16, 'Signed-in API role statement_timeout (DAT calls were designed and measured against 8 s; role or database level)',
       coalesce((select nullif(cfg, '') from roles where rolname = 'authenticated'), '') || coalesce(' [this database: ' ||
         (select array_to_string(s.setconfig, ' ') from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase
           where d.datname = current_database() and s.setrole = (select oid from pg_roles where rolname = 'authenticated')) || ']', ''),
       coalesce((select cfg from roles where rolname = 'authenticated'), '') ~ 'statement_timeout='
         or exists (select 1 from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase, unnest(s.setconfig) c
                     where d.datname = current_database() and s.setrole = (select oid from pg_roles where rolname = 'authenticated') and c like 'statement_timeout=%'),
       '0013 performance'
union all
select 17, 'This role may act as authenticated (needed by the guarded DB-level performance test, which sets role authenticated)',
       current_user || ' member of authenticated=' || pg_has_role(current_user, 'authenticated', 'MEMBER')::text,
       pg_has_role(current_user, 'authenticated', 'MEMBER'), 'G6 dat_hosted_scale.py'
union all
select 18, 'This role bypasses row level security? (information: the DAT functions filter by company explicitly)',
       current_user || ' bypassrls=' || (select rolbypassrls from pg_roles where rolname = current_user)::text, true, 'information'
union all
select 19, 'pg_cron NOT installed (no scheduled jobs in this preflight; projection stays off)',
       coalesce((select 'installed in ' || schema from inst where extname = 'pg_cron'), 'not installed'),
       not exists (select 1 from inst where extname = 'pg_cron'), 'owner boundary'
union all
select 20, 'Supabase Auth schema present (auth.users) — logins for the synthetic test users',
       case when to_regclass('auth.users') is null then 'missing' else 'present' end, to_regclass('auth.users') is not null, '0001 / 0005'
order by n;
