-- AttendOS: are logins (Supabase Auth) and employee records consistent?  READ-ONLY.
-- Run after any restore, data repair or company deletion, and weekly during the pilot.
-- Every row should show 0. If not, see docs/pilot/05-ROLLBACK.md §2.4 (relink_logins.sql fixes 2, 3 and 4).
with checks(n, item, problems) as (
  select 1, 'employee linked to a login that no longer exists',
         (select count(*) from public.employees e where e.user_id is not null and not exists (select 1 from auth.users u where u.id = e.user_id))
  union all
  select 2, 'employee linked to a login whose e-mail differs from the work e-mail',
         (select count(*) from public.employees e join auth.users u on u.id = e.user_id where lower(u.email) <> lower(e.email))
  union all
  select 3, 'employee linked to a login that is not confirmed',
         (select count(*) from public.employees e join auth.users u on u.id = e.user_id where u.email_confirmed_at is null)
  union all
  select 4, 'active employee not linked although a confirmed login with the work e-mail exists',
         (select count(*) from public.employees e join auth.users u on lower(u.email) = lower(e.email)
           where e.user_id is null and e.active and u.email_confirmed_at is not null
             and not exists (select 1 from public.employees x where x.user_id = u.id))
  union all
  select 5, 'login linked to more than one employee',
         (select count(*) from (select user_id from public.employees where user_id is not null group by 1 having count(*) > 1) d)
  union all
  select 6, 'login with no employee record using its e-mail (left over; review, then delete in Authentication → Users)',
         (select count(*) from auth.users u where not exists (select 1 from public.employees e where e.user_id = u.id or lower(e.email) = lower(u.email)))
)
select n, item, problems, case when problems = 0 then 'ok' else 'CHECK' end as result from checks order by n;
