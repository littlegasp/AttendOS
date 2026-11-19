-- AttendOS 0008: hardening found by the security matrix test (stabilisation pass).
-- company_tz() is callable by signed-in users (local_today/at_local and triggers need it). It used to answer for
-- any company id; now a signed-in user only gets their own company's time zone (other ids → null). Database
-- setup, Supabase Auth and owner scripts (no signed-in user) are unchanged.
create or replace function public.company_tz(c uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    -- (checked against the login's own record directly: my_company() itself calls this function)
    when auth.uid() is not null and not exists (select 1 from public.employees e where e.user_id = auth.uid() and e.company_id = c) then null
    else coalesce((select timezone from public.companies where id = c), 'Asia/Kolkata') end
$$;

-- Weekly roster / shift patterns: row level security already stopped writes to other companies' people (the
-- functions run as the caller), but a call naming them succeeded silently. Now any person outside the caller's
-- HR scope makes the whole call fail, so the screen says so instead of "saved".
alter function public.set_roster_pattern(uuid[], jsonb) rename to set_roster_pattern_core;
alter function public.set_shift_pattern(uuid[], jsonb) rename to set_shift_pattern_core;
create function public.set_roster_pattern(p_employees uuid[], p_rows jsonb) returns void
language plpgsql security invoker set search_path = public as $$
begin
  if exists (select 1 from unnest(p_employees) e where not public.hr_of(e)) then
    raise exception 'Only HR or an administrator can set the roster for these people' using errcode = '42501';
  end if;
  perform public.set_roster_pattern_core(p_employees, p_rows);
end $$;
create function public.set_shift_pattern(p_employees uuid[], p_rows jsonb) returns void
language plpgsql security invoker set search_path = public as $$
begin
  if exists (select 1 from unnest(p_employees) e where not public.hr_of(e)) then
    raise exception 'Only HR or an administrator can set shifts for these people' using errcode = '42501';
  end if;
  perform public.set_shift_pattern_core(p_employees, p_rows);
end $$;
revoke all on function public.set_roster_pattern(uuid[], jsonb), public.set_shift_pattern(uuid[], jsonb) from public, anon;
grant execute on function public.set_roster_pattern(uuid[], jsonb), public.set_shift_pattern(uuid[], jsonb) to authenticated;
