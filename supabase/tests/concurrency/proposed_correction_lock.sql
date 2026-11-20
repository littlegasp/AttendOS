-- PROPOSAL for migration 0012 (not a migration; not applied by run.sh). Applied only to throwaway copies by
-- lock_proof.sh to prove the locking design. Same rename-and-wrap pattern as 0006/0008.
-- decide_correction() takes the per-person lock used by punch() (key 7) before anything else, so a correction
-- approval, a web punch and biometric projection for the same person run one after another, never interleaved.
-- Lock order everywhere: advisory lock 7 first, then row locks — so these three paths cannot deadlock each other.
alter function public.decide_correction(bigint, boolean, text) rename to decide_correction_core;
create function public.decide_correction(p_id bigint, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare emp uuid;
begin
  select employee_id into emp from public.attendance_corrections where id = p_id;
  if emp is null or not public.in_my_company(emp) then raise exception 'Not allowed' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(emp::text, 7));
  return public.decide_correction_core(p_id, p_approve, p_note);
end $$;
revoke all on function public.decide_correction_core(bigint, boolean, text) from public, anon, authenticated;
revoke all on function public.decide_correction(bigint, boolean, text) from public, anon;
grant execute on function public.decide_correction(bigint, boolean, text) to authenticated;
