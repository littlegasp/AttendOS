-- AttendOS development preflight: switch autovacuum for public.biometric_import_rows off/on for performance
-- scenarios S2 and S4 (stale statistics, the worst case). DEVELOPMENT PROJECT ONLY, through dev_sql.py:
--   python3 dev_sql.py dev_autovacuum.sql -v mode=off      … then …      -v mode=on
\if :{?mode}
\else
select stop_mode_not_set;
\endif
select set_config('attendos.av_mode', :'mode', false) is not null as mode_received;
do $$ begin
  if to_regclass('attendos_dev.environment_marker') is null
     or not exists (select 1 from attendos_dev.environment_marker where environment = 'development'
                    and project_ref = current_setting('attendos.dev_ref', true)) then
    raise exception 'STOP: not the AttendOS development project (run through dev_sql.py)';
  end if;
  if current_setting('attendos.av_mode') = 'off' then
    execute 'alter table public.biometric_import_rows set (autovacuum_enabled = false)';
  elsif current_setting('attendos.av_mode') = 'on' then
    execute 'alter table public.biometric_import_rows reset (autovacuum_enabled)';
  else
    raise exception 'STOP: mode must be on or off';
  end if;
end $$;
select relname, coalesce(array_to_string(reloptions, ','), '(defaults)') as options from pg_class where oid = 'public.biometric_import_rows'::regclass;
