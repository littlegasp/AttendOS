-- AttendOS biometric: READ-ONLY prerequisite check for the hosted project, before migrations 0010–0012.
-- Run in the Supabase SQL editor (role postgres). It changes nothing: no extension is created, no setting changed.
-- Every row shows what is needed, what the project has, and whether that is enough.
with
avail as (select name, default_version, installed_version from pg_available_extensions where name in ('btree_gist', 'pgcrypto', 'pg_cron')),
inst as (select e.extname, n.nspname as schema, e.extversion from pg_extension e join pg_namespace n on n.oid = e.extnamespace
          where e.extname in ('btree_gist', 'pgcrypto', 'pg_cron')),
roles as (select rolname, coalesce(array_to_string(rolconfig, ' '), '') as cfg from pg_roles where rolname in ('anon', 'authenticated', 'authenticator', 'postgres'))
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
       coalesce((select string_agg(coalesce(source, 'NULL') || ' ' || n, ', ' order by source) from (select source, count(*) n from public.attendance_events group by source) x), 'no rows'),
       not exists (select 1 from public.attendance_events where source is null or source not in ('web', 'correction', 'biometric', 'import')), '0012 preflight'
order by n;
