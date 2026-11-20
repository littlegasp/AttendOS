-- Emulates Supabase's default privileges for objects created in the public schema (a project where
-- "Grant API access to new tables automatically" is on, and the function/sequence defaults every project has).
-- Applied just before 0010 so the biometric migration is proven safe even when Supabase would grant
-- everything to anon and authenticated: its explicit revokes must win. Test-only; never run on a project.
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;
select pg_temp.expect((select count(*) from pg_default_acl d join pg_namespace n on n.oid = d.defaclnamespace where n.nspname = 'public') = 3,
  'Supabase-style default grants to anon/authenticated are active for what 0010 creates');
