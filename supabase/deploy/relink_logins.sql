-- AttendOS: repair the links between logins and employee records after a restore or data repair.
-- Owner only (SQL editor or psql). Run check_auth_links.sql before and after. One transaction.
-- It never creates or deletes logins and never changes passwords. It:
--   a) removes links to logins that no longer exist, whose e-mail differs from the work e-mail, or that are
--      not confirmed (the person simply opens a new invitation or signs in again after HR re-invites);
--   b) links each active, unlinked employee to the confirmed, unclaimed login with the same work e-mail —
--      the same rule the app uses when someone confirms their e-mail.
-- Each change is written to the Activity log as a system change.
begin;
create temp table relink_report (step text, employees int) on commit drop;

with gone as (
  update public.employees e set user_id = null
   where e.user_id is not null and (
         not exists (select 1 from auth.users u where u.id = e.user_id)
      or exists (select 1 from auth.users u where u.id = e.user_id and (lower(u.email) <> lower(e.email) or u.email_confirmed_at is null)))
  returning 1)
insert into relink_report select 'links removed (login missing, different e-mail or unconfirmed)', count(*) from gone;

with linked as (
  update public.employees e set user_id = u.id
    from auth.users u
   where e.user_id is null and e.active and lower(u.email) = lower(e.email) and u.email_confirmed_at is not null
     and not exists (select 1 from public.employees x where x.user_id = u.id)
  returning 1)
insert into relink_report select 'employees linked to their confirmed login', count(*) from linked;

select * from relink_report;
commit;
