-- AttendOS development-Supabase preflight: mark the database ONCE as the AttendOS development project.
-- Run only through `python3 dev_sql.py --mark` after confirming the Reference ID in the dashboard. The wrapper has
-- already checked that the connection string names exactly this reference. The marker lives in its own schema
-- (not exposed by the API, no grants) and is what every later script's guard checks. A pilot or production
-- database never gets this marker, so no dev-only script can run there.
\set ON_ERROR_STOP on
\if :{?dev_ref}
\else
select stop_dev_ref_not_set;
\endif
select set_config('attendos.dev_ref', :'dev_ref', false) is not null as dev_ref_received;
do $$
declare want text := current_setting('attendos.dev_ref'); m record;
begin
  if want !~ '^[a-z]{20}$' then raise exception 'STOP: invalid development project reference'; end if;
  if to_regclass('public.companies') is not null and exists (select 1 from public.companies) then
    raise exception 'STOP: this database already holds AttendOS companies; a development marker is only written on an empty, new project';
  end if;
  if to_regclass('attendos_dev.environment_marker') is not null then
    select * into m from attendos_dev.environment_marker limit 1;
    if found and m.project_ref <> want then
      raise exception 'STOP: this database is already marked for project %, not %', m.project_ref, want;
    end if;
  end if;
end $$;
create schema if not exists attendos_dev;
revoke all on schema attendos_dev from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on schema attendos_dev from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on schema attendos_dev from authenticated'; end if;
end $$;
create table if not exists attendos_dev.environment_marker (
  singleton boolean primary key default true check (singleton),
  environment text not null check (environment = 'development'),
  project_ref text not null check (project_ref ~ '^[a-z]{20}$'),
  marked_at timestamptz not null default now(),
  marked_by text not null default current_user);
create table if not exists attendos_dev.applied_migrations (
  file text primary key, sha256 text not null, git_commit text not null, applied_at timestamptz not null default now());
revoke all on all tables in schema attendos_dev from public;
insert into attendos_dev.environment_marker (environment, project_ref)
  values ('development', current_setting('attendos.dev_ref'))
  on conflict (singleton) do nothing;
select environment, project_ref, marked_at from attendos_dev.environment_marker;
