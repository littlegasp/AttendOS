-- AttendOS development preflight, owner decision D5: revoke CREATE on schema public from anon and authenticated.
-- Run through dev_sql.py (guarded). Revokes nothing else. If CREATE still remains afterwards (for example through a
-- grant to PUBLIC), it STOPS and the transaction is rolled back: report to the owner, do not improvise.
do $$ begin
  if to_regclass('attendos_dev.environment_marker') is null
     or not exists (select 1 from attendos_dev.environment_marker where environment = 'development'
                    and project_ref = current_setting('attendos.dev_ref', true)) then
    raise exception 'STOP: not the AttendOS development project (run through dev_sql.py)';
  end if;
end $$;
select 'before' as at, has_schema_privilege('anon', 'public', 'CREATE') as anon_create, has_schema_privilege('authenticated', 'public', 'CREATE') as authenticated_create;
revoke create on schema public from anon, authenticated;
do $$ begin
  if has_schema_privilege('anon', 'public', 'CREATE') or has_schema_privilege('authenticated', 'public', 'CREATE') then
    raise exception 'STOP: CREATE on schema public is still granted to anon or authenticated after the revoke (probably via PUBLIC). Nothing was changed. Report to the owner.';
  end if;
end $$;
select 'after' as at, has_schema_privilege('anon', 'public', 'CREATE') as anon_create, has_schema_privilege('authenticated', 'public', 'CREATE') as authenticated_create;
