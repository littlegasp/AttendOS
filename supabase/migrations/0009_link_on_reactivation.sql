-- AttendOS 0009: defect fix found by the invitation edge-case check (supabase/authcheck/invite_edges.py).
-- If someone opened their invitation while HR had switched their access off, Supabase confirmed the address but
-- (correctly) linked nothing. Switching them back on never linked that confirmed login, and a new invitation
-- could not either (a magic-link sign-in confirms nothing new), so the person was stuck.
-- Now the confirmed, unclaimed login with the same work e-mail is linked when access is switched back on —
-- the same rule already used when HR adds the person or corrects their e-mail. Nothing else changes.

create or replace function public.link_existing_login() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.user_id is null and new.active
     and (tg_op = 'INSERT' or new.email is distinct from old.email or (new.active and not old.active)) then
    select u.id into new.user_id from auth.users u
     where lower(u.email) = lower(new.email) and u.email_confirmed_at is not null
       and not exists (select 1 from public.employees x where x.user_id = u.id)
     limit 1;
  end if;
  return new;
end $$;

drop trigger zz_link_existing_login on public.employees;
-- Still named to run after the guards, so callers can't set user_id themselves.
create trigger zz_link_existing_login before insert or update of email, active on public.employees
  for each row execute function public.link_existing_login();

revoke all on function public.link_existing_login() from anon, authenticated, public;
