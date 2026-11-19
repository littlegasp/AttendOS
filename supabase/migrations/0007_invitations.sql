-- AttendOS 0007: employee invitations (no service key needed).
-- HR asks the database to prepare an invitation; the app then asks Supabase Auth to e-mail a one-time sign-in
-- link to that work e-mail (signInWithOtp). Opening the link confirms the address, which links the login to
-- this employee record (0005 rules), and the person chooses a password. Only work e-mails HR added can create a
-- login (Before User Created hook), so the link is useless to anyone but the inbox owner.

create table public.employee_invitations (
  id bigint generated always as identity primary key,
  employee_id uuid not null references public.employees (id) on delete cascade,
  email text not null,
  invited_by uuid not null,            -- employee who sent it
  invited_at timestamptz not null default now(),
  status text not null default 'sent' check (status in ('sent', 'failed', 'accepted')),
  error text check (error is null or length(error) <= 300),
  accepted_at timestamptz
);
create index on public.employee_invitations (employee_id, invited_at desc);

-- Rules: HR/Admin of the same company; not yourself; the person is active, not past their last day and has no
-- login yet; at most one invitation per 10 minutes and 5 per day per person (e-mail providers and Supabase
-- also rate-limit). Returns the e-mail the app must send to — never an address supplied by the caller.
create function public.prepare_invitation(p_employee uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  e public.employees;
  me uuid := public.my_employee_id();
  last timestamptz;
  n int;
  id_ bigint;
begin
  if me is null or not public.hr_of(p_employee) then raise exception 'Only HR or an administrator of this company can send invitations' using errcode = '42501'; end if;
  if p_employee = me then raise exception 'You already have a login'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_employee::text, 31));
  select * into e from public.employees where id = p_employee;
  if not e.active then raise exception 'Switch this person''s access on before inviting them'; end if;
  if e.exit_date is not null and e.exit_date < public.local_today(e.company_id) then raise exception 'This person''s last working day has passed'; end if;
  if e.user_id is not null then raise exception 'This person already has a login; no invitation needed'; end if;
  select max(invited_at), count(*) filter (where invited_at > now() - interval '24 hours') into last, n
    from public.employee_invitations where employee_id = p_employee and status <> 'failed';
  if last > now() - interval '10 minutes' then
    raise exception 'An invitation was sent at % — wait 10 minutes before sending another', to_char(last at time zone public.company_tz(e.company_id), 'HH24:MI');
  end if;
  if n >= 5 then raise exception 'Five invitations were sent in the last 24 hours; try again tomorrow'; end if;
  insert into public.employee_invitations (employee_id, email, invited_by) values (p_employee, e.email, me) returning id into id_;
  return jsonb_build_object('ok', true, 'id', id_, 'email', e.email);
end $$;

-- If Supabase Auth refused to send the e-mail, the app records why (only the person who sent it).
create function public.invitation_failed(p_id bigint, p_error text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.employee_invitations set status = 'failed', error = left(coalesce(p_error, 'Unknown error'), 300)
   where id = p_id and invited_by = public.my_employee_id() and status = 'sent';
end $$;

-- When the login is linked (the person opened the link), the open invitation is marked accepted.
create function public.invitation_accepted() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.employee_invitations set status = 'accepted', accepted_at = now()
   where employee_id = new.id and status = 'sent';
  return new;
end $$;
create trigger invitation_accepted after update of user_id on public.employees
  for each row when (old.user_id is null and new.user_id is not null) execute function public.invitation_accepted();

alter table public.employee_invitations enable row level security;
revoke all on public.employee_invitations from anon, public, authenticated;
grant select on public.employee_invitations to authenticated;
create policy inv_read on public.employee_invitations for select to authenticated using (public.hr_of(employee_id));
create trigger audit_invitations after insert or update on public.employee_invitations for each row execute function public.audit();

revoke all on all functions in schema public from anon, public;
revoke execute on function public.invitation_accepted() from authenticated;
grant execute on function public.prepare_invitation(uuid), public.invitation_failed(bigint, text) to authenticated;
grant execute on function public.company_brand(text) to anon, authenticated;
