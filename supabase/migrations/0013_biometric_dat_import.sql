-- AttendOS 0013 — B5 offline DAT import, Stage 1 (versioned reader) and Stage 2 (mapping preview, import preparation).
--
-- What this migration does:
--   * keeps an uploaded eSSL X2008 attendance export (USB `.dat` file) byte-for-byte;
--   * parses it on the server with the versioned profile `essl.x2008.attlog/1` (docs/biometric/BIOMETRIC_DAT_FORMAT.md);
--   * keeps every line as one row in file order — raw text, all six raw fields, exact timestamp string — including
--     malformed, blank and duplicate lines;
--   * labels duplicates and shows, on read, which approved employee mapping applies to each record.
--
-- What it never does:
--   * writes attendance, sessions or register rows; creates biometric_raw_events; calls or triggers projection;
--   * infers IN/OUT or gives fields 3–6 any meaning; creates or guesses an employee mapping.
--   Staging tables only. Nothing here runs on a schedule; stale uploads expire lazily when an Admin uses the screen.
--
-- Every function is Admin-only (biometric_require(true)) and limited to the caller's company. The new tables have row
-- level security on and no grants: they are reached only through these functions. The generic audit() trigger is NOT
-- attached to them (it copies whole rows into the append-only audit_log); explicit audit entries carry ids, counts and
-- hashes only — never file names, codes, times or line text.

-- ================================================================ limits (one place; the app reads them from the list call)
create function public.biometric_dat_limits() returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'format_version', 'essl.x2008.attlog/1',
    'chunk_bytes', 262144,          -- 256 KiB of original bytes per upload call
    'max_file_bytes', 16777216,     -- 16 MiB
    'max_lines', 200000,
    'max_line_bytes', 512,
    'max_fields', 16,
    'expected_fields', 6,
    'lines_per_call', 5000,         -- parse / classify work per call (well inside the 8 s signed-in timeout)
    'max_blank_pct', 1,
    'max_malformed_pct', 2,
    'idle_hours', 24,               -- an upload with no new chunk for this long expires
    'stall_hours', 2,               -- processing with no progress for this long fails
    'max_open_batches', 3)
$$;

-- ================================================================ batches: the 0010 table gains the upload/processing state
alter table public.biometric_import_batches
  add column source_device_id uuid,
  add column declared_timezone text check (declared_timezone is null or public.valid_timezone(declared_timezone)),
  add column declared_size bigint check (declared_size is null or declared_size between 1 and 16777216),
  add column chunk_count int check (chunk_count is null or chunk_count between 1 and 64),
  add column chunk_hashes bytea[],
  add column format_version text,
  add column upload_token_hash bytea,
  add column state text not null default 'legacy'
    check (state in ('legacy', 'uploading', 'uploaded', 'parsing', 'classifying', 'ready_for_review', 'reviewed',
                     'failed', 'expired', 'cancelled', 'deleted')),
  add column next_chunk int not null default 0,
  add column progress_line int not null default 0,
  add column line_count int,
  add column bom text check (bom is null or bom in ('none', 'utf8')),
  add column final_terminator text check (final_terminator is null or final_terminator in ('crlf', 'none')),
  add column fail_reason text,
  add column fail_line int,
  add column counts jsonb not null default '{}',
  add column last_activity_at timestamptz not null default now(),
  add column reviewed_by uuid references public.employees (id),
  add column reviewed_at timestamptz,
  add column deleted_by uuid references public.employees (id),
  add column deleted_at timestamptz,
  add column delete_reason text,
  add column version int not null default 0,
  add constraint biometric_import_batches_source_device_fk foreign key (company_id, source_device_id)
    references public.biometric_devices (company_id, id),
  add constraint biometric_import_batches_chunks_ck check (chunk_hashes is null or cardinality(chunk_hashes) = chunk_count);

-- The same file may be imported again only after its earlier batch failed, expired, was cancelled or was deleted.
alter table public.biometric_import_batches drop constraint biometric_import_batches_company_id_file_sha256_key;
create unique index biometric_import_batches_active_file on public.biometric_import_batches (company_id, file_sha256)
  where state not in ('failed', 'expired', 'cancelled', 'deleted');
create index on public.biometric_import_batches (company_id, state, last_activity_at);

drop trigger company_refs on public.biometric_import_batches;
create trigger company_refs before insert or update on public.biometric_import_batches
  for each row execute function public.check_company_refs('uploaded_by:employees', 'approved_by:employees', 'reviewed_by:employees',
                                                          'deleted_by:employees', 'source_device_id:biometric_devices');

-- ================================================================ staging tables
-- Chunks of an upload in progress; joined into the original at finish and then deleted.
create table public.biometric_import_chunks (
  company_id uuid not null default public.my_company() references public.companies (id),
  batch_id uuid not null,
  idx int not null check (idx between 0 and 63),
  bytes bytea not null check (octet_length(bytes) between 1 and 262144),
  sha256 bytea not null check (octet_length(sha256) = 32),
  primary key (batch_id, idx),
  foreign key (company_id, batch_id) references public.biometric_import_batches (company_id, id) on delete cascade
);

-- The original file, byte-for-byte (including any BOM and the exact line terminators).
create table public.biometric_import_files (
  company_id uuid not null default public.my_company() references public.companies (id),
  batch_id uuid primary key,
  original bytea not null check (octet_length(original) between 1 and 16777216),
  created_at timestamptz not null default now(),
  foreign key (company_id, batch_id) references public.biometric_import_batches (company_id, id) on delete cascade
);

-- One row per line of the file, in file order. Nothing is normalised in place: raw_line and fields[] are the exact
-- text; employee_code and local_ts are separate derived values with documented rules.
create table public.biometric_import_rows (
  company_id uuid not null default public.my_company() references public.companies (id),
  batch_id uuid not null,
  source_device_id uuid not null,
  line_no int not null check (line_no >= 1),
  raw_line text not null,                                   -- exact line without its terminator (and without a BOM)
  terminator text not null check (terminator in ('crlf', 'none')),
  line_bytes int not null,
  fields text[] not null,                                   -- exact substrings between TABs; no trimming
  parse_status text not null check (parse_status in ('ok', 'blank', 'unparsable')),
  parse_reason text,
  raw_code_field text,                                      -- field 1 exactly as written
  employee_code text,                                       -- field 1 without its left-padding spaces (only those)
  code_status text check (code_status is null or code_status in ('ok', 'empty_code', 'trailing_space', 'inner_space', 'too_long', 'invalid_character')),
  local_time_text text,                                     -- field 2 exactly as written
  local_ts timestamp,                                       -- separate parsed value; null when not a real device time
  time_status text check (time_status is null or time_status in ('ok', 'bad_format', 'impossible_date', 'out_of_range',
                                                                    'nonexistent_local_time', 'ambiguous_local_time')),
  instant timestamptz,                                      -- local_ts in the batch's declared zone; never guessed
  flags text[] not null default '{}',                       -- information only: code_width_unexpected, out_of_order, future, older_than_backfill
  line_hash bytea not null check (octet_length(line_hash) = 32),
  dup_class text check (dup_class is null or dup_class in ('new', 'exact_in_file', 'exact_in_earlier_import',
                                                            'same_code_time_other_fields', 'already_from_device')),
  dup_ref_batch uuid,
  dup_ref_line int,
  dup_ref_raw_event bigint,
  primary key (batch_id, line_no),
  foreign key (company_id, batch_id) references public.biometric_import_batches (company_id, id) on delete cascade
);
create index on public.biometric_import_rows (batch_id, line_hash, line_no);
create index on public.biometric_import_rows (batch_id, employee_code, local_ts, line_no);
create index on public.biometric_import_rows (company_id, source_device_id, line_hash);
create index on public.biometric_import_rows (company_id, source_device_id, employee_code, local_ts);

create trigger freeze_company before update on public.biometric_import_chunks for each row execute function public.freeze_company_id();
create trigger freeze_company before update on public.biometric_import_files for each row execute function public.freeze_company_id();
create trigger freeze_company before update on public.biometric_import_rows for each row execute function public.freeze_company_id();

do $$
declare t text;
begin
  foreach t in array array['biometric_import_chunks', 'biometric_import_files', 'biometric_import_rows'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
  end loop;
end $$;

-- ================================================================ helpers (not callable by users)
-- Audit entry with ids, counts and hashes only. Never a file name, code, time, line text or byte.
create function public.biometric_dat_audit(cid uuid, act text, bid uuid, info jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.audit_log (company_id, action, target, target_id, after)
  values (cid, act, 'biometric_import_batches', bid::text,
          (select coalesce(jsonb_object_agg(k, v), '{}') from jsonb_each(info) e(k, v)
            where k in ('state', 'reason', 'line', 'size', 'sha256', 'chunk_count', 'lines', 'counts', 'source_device_id', 'format_version')))
$$;

-- Split one line by TAB and derive the code and the timestamp shape (profile essl.x2008.attlog/1). Immutable, no lookups.
create function public.biometric_dat_split(l text)
returns table (fields text[], nfields int, raw_code text, code text, code_status text, ts_text text, ts_shape_ok boolean, width_ok boolean)
language sql immutable as $$
  select a.f, cardinality(a.f),
         case when cardinality(a.f) = 6 then a.f[1] end,
         case when cardinality(a.f) = 6 then b.c end,
         case when cardinality(a.f) <> 6 then null
              when b.c = '' then 'empty_code'
              when b.c ~ ' $' then 'trailing_space'
              when b.c ~ ' ' then 'inner_space'
              when length(b.c) > 32 then 'too_long'
              when b.c !~ '^[A-Za-z0-9_-]+$' then 'invalid_character'
              else 'ok' end,
         case when cardinality(a.f) = 6 then a.f[2] end,
         case when cardinality(a.f) = 6 then a.f[2] ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$' end,
         case when cardinality(a.f) = 6 then length(a.f[1]) = 9 end
    from (select case when l = '' then '{}'::text[] else string_to_array(l, E'\t') end as f) a,
         lateral (select case when cardinality(a.f) = 6 then regexp_replace(a.f[1], '^ +', '') end as c) b
$$;

-- Local device time → instant in zone tz. Ambiguous (clock goes back) and non-existent (clock goes forward) local times
-- are reported, never resolved: Postgres alone would silently pick an offset.
create function public.biometric_dat_instant(lt timestamp, tz text, out instant timestamptz, out status text)
language plpgsql stable set search_path = public as $$
declare c timestamptz; o1 interval; o2 interval; i1 timestamptz; i2 timestamptz; ok1 boolean; ok2 boolean;
begin
  if lt is null then return; end if;
  c := lt at time zone tz;
  o1 := ((c - interval '3 hours') at time zone tz) - ((c - interval '3 hours') at time zone 'UTC');
  o2 := ((c + interval '3 hours') at time zone tz) - ((c + interval '3 hours') at time zone 'UTC');
  if o1 = o2 then instant := c; status := 'ok'; return; end if;
  i1 := (lt - o1) at time zone 'UTC';
  i2 := (lt - o2) at time zone 'UTC';
  ok1 := (i1 at time zone tz) = lt;
  ok2 := (i2 at time zone tz) = lt;
  if ok1 and ok2 then status := 'ambiguous_local_time';
  elsif not ok1 and not ok2 then status := 'nonexistent_local_time';
  else instant := case when ok1 then i1 else i2 end; status := 'ok';
  end if;
end $$;

-- Remove the stored bytes and rows of a batch (same transaction as its state change).
create function public.biometric_dat_purge(bid uuid) returns void
language sql security definer set search_path = public as $$
  delete from public.biometric_import_chunks where batch_id = bid;
  delete from public.biometric_import_files where batch_id = bid;
  delete from public.biometric_import_rows where batch_id = bid;
$$;

-- Lazy expiry (no scheduler): uploads idle 24 h expire; processing with no progress for 2 h fails. At most 10 per call.
create function public.biometric_dat_expire(cid uuid) returns int
language plpgsql security definer set search_path = public as $$
declare b record; n int := 0;
begin
  for b in select id, state from public.biometric_import_batches
            where company_id = cid
              and ((state = 'uploading' and last_activity_at < now() - interval '24 hours')
                or (state in ('uploaded', 'parsing', 'classifying') and last_activity_at < now() - interval '2 hours'))
            order by last_activity_at limit 10 for update skip locked loop
    perform public.biometric_dat_purge(b.id);
    if b.state = 'uploading' then
      update public.biometric_import_batches set state = 'expired', fail_reason = 'upload_idle', upload_token_hash = null, updated_at = now() where id = b.id;
      perform public.biometric_dat_audit(cid, 'dat_import.expired', b.id, jsonb_build_object('state', 'expired', 'reason', 'upload_idle'));
    else
      update public.biometric_import_batches set state = 'failed', fail_reason = 'processing_stalled', upload_token_hash = null, updated_at = now() where id = b.id;
      perform public.biometric_dat_audit(cid, 'dat_import.failed', b.id, jsonb_build_object('state', 'failed', 'reason', 'processing_stalled'));
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- The batch, locked, for the caller's company; any other id (incl. another company's) answers "not found".
create function public.biometric_dat_lock(cid uuid, bid uuid) returns public.biometric_import_batches
language plpgsql security definer set search_path = public as $$
declare b public.biometric_import_batches;
begin
  select * into b from public.biometric_import_batches where id = bid and company_id = cid and state <> 'legacy' for update;
  if not found then raise exception 'Import batch not found' using errcode = 'P0002'; end if;
  return b;
end $$;

create function public.biometric_dat_fail(b public.biometric_import_batches, reason text, line int) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.biometric_dat_purge(b.id);
  update public.biometric_import_batches set state = 'failed', fail_reason = reason, fail_line = line, upload_token_hash = null,
         last_activity_at = now(), updated_at = now(), version = version + 1 where id = b.id;
  perform public.biometric_dat_audit(b.company_id, 'dat_import.failed', b.id, jsonb_build_object('state', 'failed', 'reason', reason, 'line', line));
  return jsonb_build_object('ok', false, 'state', 'failed', 'error', reason, 'line', line);
end $$;

create function public.biometric_dat_hex(h bytea[]) returns text[]
language sql immutable as $$ select array(select encode(x, 'hex') from unnest(h) with ordinality u(x, i) order by i) $$;

-- ================================================================ upload
create function public.biometric_dat_begin(p_device uuid, p_timezone text, p_file_name text, p_size bigint, p_sha256 text, p_chunk_hashes text[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); lim jsonb := public.biometric_dat_limits(); me uuid := public.my_employee_id();
        dev public.biometric_devices; h bytea; hashes bytea[]; existing record; token text; bid uuid; nchunks int;
begin
  perform public.biometric_dat_expire(cid);
  select * into dev from public.biometric_devices where id = p_device and company_id = cid;
  if not found then return jsonb_build_object('ok', false, 'error', 'device_not_found'); end if;
  if dev.manufacturer <> 'essl' then return jsonb_build_object('ok', false, 'error', 'device_not_essl'); end if;
  if p_timezone is null or not public.valid_timezone(p_timezone) then return jsonb_build_object('ok', false, 'error', 'invalid_timezone'); end if;
  if p_file_name is null or length(p_file_name) not between 1 and 200 then return jsonb_build_object('ok', false, 'error', 'invalid_file_name'); end if;
  if p_size is null or p_size < 1 then return jsonb_build_object('ok', false, 'error', 'empty_file'); end if;
  if p_size > (lim ->> 'max_file_bytes')::bigint then return jsonb_build_object('ok', false, 'error', 'file_too_large'); end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', false, 'error', 'invalid_sha256'); end if;
  nchunks := ((p_size + (lim ->> 'chunk_bytes')::bigint - 1) / (lim ->> 'chunk_bytes')::bigint)::int;
  if p_chunk_hashes is null or cardinality(p_chunk_hashes) <> nchunks
     or exists (select 1 from unnest(p_chunk_hashes) x where x is null or x !~ '^[0-9a-f]{64}$') then
    return jsonb_build_object('ok', false, 'error', 'invalid_chunk_hashes', 'expected_chunks', nchunks);
  end if;
  h := decode(p_sha256, 'hex');
  hashes := array(select decode(x, 'hex') from unnest(p_chunk_hashes) with ordinality u(x, i) order by i);

  select b.id, b.state, b.uploaded_by, b.created_at, e.full_name into existing
    from public.biometric_import_batches b left join public.employees e on e.id = b.uploaded_by
   where b.company_id = cid and b.file_sha256 = h and b.state not in ('failed', 'expired', 'cancelled', 'deleted') limit 1;
  if found then
    if existing.state = 'uploading' and existing.uploaded_by = me then
      return jsonb_build_object('ok', false, 'error', 'resume_available', 'batch_id', existing.id);
    elsif existing.state = 'uploading' then
      return jsonb_build_object('ok', false, 'error', 'being_uploaded', 'by', existing.full_name);
    else
      return jsonb_build_object('ok', false, 'error', 'already_imported', 'batch_id', existing.id, 'at', existing.created_at);
    end if;
  end if;
  if (select count(*) from public.biometric_import_batches where company_id = cid
       and state in ('uploading', 'uploaded', 'parsing', 'classifying')) >= (lim ->> 'max_open_batches')::int then
    return jsonb_build_object('ok', false, 'error', 'too_many_open_batches');
  end if;

  token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  begin
    insert into public.biometric_import_batches (company_id, file_name, file_sha256, uploaded_by, source_device_id, declared_timezone,
                                                 declared_size, chunk_count, chunk_hashes, format_version, upload_token_hash, state)
    values (cid, p_file_name, h, me, dev.id, p_timezone, p_size, nchunks, hashes, lim ->> 'format_version',
            sha256(convert_to(token, 'UTF8')), 'uploading')
    returning id into bid;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'being_uploaded');
  end;
  perform public.biometric_dat_audit(cid, 'dat_import.begin', bid, jsonb_build_object('state', 'uploading', 'size', p_size, 'sha256', p_sha256,
                                     'chunk_count', nchunks, 'source_device_id', dev.id, 'format_version', lim ->> 'format_version'));
  return jsonb_build_object('ok', true, 'batch_id', bid, 'upload_token', token, 'next_index', 0, 'chunk_bytes', lim -> 'chunk_bytes');
end $$;

create function public.biometric_dat_chunk(p_batch uuid, p_token text, p_index int, p_data text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); lim jsonb := public.biometric_dat_limits(); b public.biometric_import_batches;
        bytes bytea; hh bytea; expected int; stored bytea; cb int := (lim ->> 'chunk_bytes')::int;
begin
  b := public.biometric_dat_lock(cid, p_batch);
  if b.state <> 'uploading' then return jsonb_build_object('ok', false, 'error', 'not_uploading', 'state', b.state); end if;
  if b.uploaded_by is distinct from public.my_employee_id() then raise exception 'Not allowed' using errcode = '42501'; end if;
  if b.upload_token_hash is null or p_token is null or sha256(convert_to(p_token, 'UTF8')) <> b.upload_token_hash then
    return jsonb_build_object('ok', false, 'error', 'taken_over');
  end if;
  if p_index is null or p_index < 0 or p_index >= b.chunk_count then return jsonb_build_object('ok', false, 'error', 'invalid_index'); end if;
  begin bytes := decode(p_data, 'base64');
  exception when others then return jsonb_build_object('ok', false, 'error', 'invalid_chunk_data'); end;
  hh := sha256(bytes);
  if p_index < b.next_chunk then
    select sha256 into stored from public.biometric_import_chunks where batch_id = b.id and idx = p_index;
    if stored = hh then return jsonb_build_object('ok', true, 'repeat', true, 'next_index', b.next_chunk); end if;
    return jsonb_build_object('ok', false, 'error', 'chunk_conflict', 'next_index', b.next_chunk);
  end if;
  if p_index > b.next_chunk then return jsonb_build_object('ok', false, 'error', 'wrong_order', 'expected_index', b.next_chunk); end if;
  expected := case when p_index < b.chunk_count - 1 then cb else (b.declared_size - cb::bigint * (b.chunk_count - 1))::int end;
  if octet_length(bytes) <> expected or hh <> b.chunk_hashes[p_index + 1] then
    return jsonb_build_object('ok', false, 'error', 'chunk_hash_mismatch', 'expected_index', b.next_chunk);
  end if;
  insert into public.biometric_import_chunks (company_id, batch_id, idx, bytes, sha256) values (cid, b.id, p_index, bytes, hh);
  update public.biometric_import_batches set next_chunk = next_chunk + 1, last_activity_at = now(), updated_at = now() where id = b.id;
  return jsonb_build_object('ok', true, 'next_index', b.next_chunk + 1);
end $$;

-- The uploader takes the upload over (new browser tab, refresh): a new token; chunks already received are kept.
create function public.biometric_dat_resume(p_batch uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); b public.biometric_import_batches; token text;
begin
  b := public.biometric_dat_lock(cid, p_batch);
  if b.state <> 'uploading' then return jsonb_build_object('ok', false, 'error', 'not_uploading', 'state', b.state); end if;
  if b.uploaded_by is distinct from public.my_employee_id() then raise exception 'Not allowed' using errcode = '42501'; end if;
  token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  update public.biometric_import_batches set upload_token_hash = sha256(convert_to(token, 'UTF8')), last_activity_at = now(), updated_at = now() where id = b.id;
  return jsonb_build_object('ok', true, 'upload_token', token, 'next_index', b.next_chunk,
    'received', (select coalesce(jsonb_agg(encode(sha256, 'hex') order by idx), '[]') from public.biometric_import_chunks where batch_id = b.id),
    'declared_sha256', encode(b.file_sha256, 'hex'), 'declared_size', b.declared_size, 'chunk_hashes', to_jsonb(public.biometric_dat_hex(b.chunk_hashes)));
end $$;

create function public.biometric_dat_finish(p_batch uuid, p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); b public.biometric_import_batches; whole bytea;
begin
  b := public.biometric_dat_lock(cid, p_batch);
  if b.state <> 'uploading' then return jsonb_build_object('ok', false, 'error', 'not_uploading', 'state', b.state); end if;
  if b.uploaded_by is distinct from public.my_employee_id() then raise exception 'Not allowed' using errcode = '42501'; end if;
  if b.upload_token_hash is null or p_token is null or sha256(convert_to(p_token, 'UTF8')) <> b.upload_token_hash then
    return jsonb_build_object('ok', false, 'error', 'taken_over');
  end if;
  if b.next_chunk < b.chunk_count then
    return jsonb_build_object('ok', false, 'error', 'missing_chunks',
      'missing', (select jsonb_agg(i) from generate_series(b.next_chunk, b.chunk_count - 1) i));
  end if;
  select string_agg(bytes, ''::bytea order by idx) into whole from public.biometric_import_chunks where batch_id = b.id;
  if octet_length(whole) <> b.declared_size then return public.biometric_dat_fail(b, 'size_mismatch', null); end if;
  if sha256(whole) <> b.file_sha256 then return public.biometric_dat_fail(b, 'hash_mismatch', null); end if;
  insert into public.biometric_import_files (company_id, batch_id, original) values (cid, b.id, whole);
  delete from public.biometric_import_chunks where batch_id = b.id;
  update public.biometric_import_batches set state = 'uploaded', upload_token_hash = null, last_activity_at = now(), updated_at = now(),
         version = version + 1 where id = b.id;
  perform public.biometric_dat_audit(cid, 'dat_import.uploaded', b.id, jsonb_build_object('state', 'uploaded', 'size', b.declared_size,
                                     'sha256', encode(b.file_sha256, 'hex')));
  return jsonb_build_object('ok', true, 'state', 'uploaded');
end $$;

-- ================================================================ processing: validate, parse, classify (one unit of work per call)
create function public.biometric_dat_text(b public.biometric_import_batches, out t text, out lines text[], out final_crlf boolean)
language plpgsql stable security definer set search_path = public as $$
declare raw bytea;
begin
  select original into raw from public.biometric_import_files where batch_id = b.id;
  t := convert_from(raw, 'UTF8');
  if left(t, 1) = chr(65279) then t := substr(t, 2); end if;
  final_crlf := right(t, 2) = E'\r\n';
  lines := string_to_array(case when final_crlf then left(t, -2) else t end, E'\r\n');
end $$;

create function public.biometric_dat_validate(b public.biometric_import_batches) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lim jsonb := public.biometric_dat_limits(); raw bytea; t text; n_lf int; n_cr int; n_crlf int; lines text[]; final_crlf boolean;
        v_bom text := 'none'; s record; first_bad int;
begin
  select original into raw from public.biometric_import_files where batch_id = b.id;
  -- UTF-16/32 byte-order marks, then binary content, then UTF-8
  if substring(raw from 1 for 2) in ('\xfffe'::bytea, '\xfeff'::bytea) or substring(raw from 1 for 4) in ('\x0000feff'::bytea, '\xfffe0000'::bytea) then
    return public.biometric_dat_fail(b, 'unsupported_encoding', null);
  end if;
  if position('\x00'::bytea in raw) > 0 then return public.biometric_dat_fail(b, 'not_a_text_file', null); end if;
  begin t := convert_from(raw, 'UTF8');
  exception when others then return public.biometric_dat_fail(b, 'unsupported_encoding', null); end;
  if left(t, 1) = chr(65279) then v_bom := 'utf8'; t := substr(t, 2); end if;
  if t ~ '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]' then return public.biometric_dat_fail(b, 'not_a_text_file', null); end if;
  n_lf := length(t) - length(replace(t, E'\n', ''));
  n_cr := length(t) - length(replace(t, E'\r', ''));
  n_crlf := (length(t) - length(replace(t, E'\r\n', ''))) / 2;
  if n_lf <> n_crlf or n_cr <> n_crlf then return public.biometric_dat_fail(b, 'unexpected_line_endings', null); end if;
  final_crlf := right(t, 2) = E'\r\n';
  lines := string_to_array(case when final_crlf then left(t, -2) else t end, E'\r\n');
  if t = '' or lines is null or cardinality(lines) = 0 then return public.biometric_dat_fail(b, 'empty_file', null); end if;
  if cardinality(lines) > (lim ->> 'max_lines')::int then return public.biometric_dat_fail(b, 'too_many_rows', null); end if;

  select count(*) as total,
         min(k) filter (where octet_length(l) > (lim ->> 'max_line_bytes')::int) as long_line,
         min(k) filter (where x.nfields > (lim ->> 'max_fields')::int) as wide_line,
         count(*) filter (where l = '') as blanks,
         count(*) filter (where l <> '' and (x.nfields <> 6 or x.code_status <> 'ok' or not x.ts_shape_ok)) as malformed,
         min(k) filter (where l <> '') as first_line,
         min(k) filter (where l <> '' and position(E'\t' in l) = 0) as no_tab_line
    into s
    from unnest(lines) with ordinality u(l, k) cross join lateral public.biometric_dat_split(l) x;

  if s.long_line is not null then return public.biometric_dat_fail(b, 'line_too_long', s.long_line::int); end if;
  if s.wide_line is not null then return public.biometric_dat_fail(b, 'too_many_fields', s.wide_line::int); end if;
  if s.first_line is null then return public.biometric_dat_fail(b, 'empty_file', null); end if;
  -- header / delimiter: the first record must look like a record; the first 100 non-blank lines must contain TABs
  select k into first_bad from unnest(lines) with ordinality u(l, k)
   where k = s.first_line and (position(E'\t' in l) = 0 or coalesce(split_part(l, E'\t', 2), '') !~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$');
  if first_bad is not null then
    if position(E'\t' in lines[first_bad]) = 0 then return public.biometric_dat_fail(b, 'unexpected_delimiter', first_bad); end if;
    return public.biometric_dat_fail(b, 'unexpected_header', first_bad);
  end if;
  select min(k) into first_bad from (select k, l from unnest(lines) with ordinality u(l, k) where l <> '' order by k limit 100) f
   where position(E'\t' in l) = 0;
  if first_bad is not null then return public.biometric_dat_fail(b, 'unexpected_delimiter', first_bad); end if;
  if s.blanks * 100 > s.total * (lim ->> 'max_blank_pct')::int then return public.biometric_dat_fail(b, 'too_many_blank_rows', null); end if;
  if s.malformed * 100 > (s.total - s.blanks) * (lim ->> 'max_malformed_pct')::int then
    return public.biometric_dat_fail(b, 'too_many_malformed_rows', null);
  end if;

  update public.biometric_import_batches set state = 'parsing', line_count = cardinality(lines), progress_line = 0, bom = v_bom,
         final_terminator = case when final_crlf then 'crlf' else 'none' end, last_activity_at = now(), updated_at = now(), version = version + 1
   where id = b.id;
  return jsonb_build_object('ok', true, 'state', 'parsing', 'lines', cardinality(lines));
end $$;

create function public.biometric_dat_parse(b public.biometric_import_batches) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lim jsonb := public.biometric_dat_limits(); x record; st public.biometric_settings := public.biometric_settings_for(b.company_id);
        from_line int := b.progress_line + 1; to_line int;
begin
  x := public.biometric_dat_text(b);
  to_line := least(b.line_count, b.progress_line + (lim ->> 'lines_per_call')::int);
  insert into public.biometric_import_rows (company_id, batch_id, source_device_id, line_no, raw_line, terminator, line_bytes, fields, parse_status,
              parse_reason, raw_code_field, employee_code, code_status, local_time_text, local_ts, time_status, instant, flags, line_hash)
  select b.company_id, b.id, b.source_device_id, k::int, l,
         case when k < b.line_count or x.final_crlf then 'crlf' else 'none' end, octet_length(l), s.fields,
         case when l = '' then 'blank'
              when s.nfields <> 6 or s.code_status <> 'ok' or not s.ts_shape_ok then 'unparsable' else 'ok' end,
         case when l = '' then null
              when s.nfields <> 6 then 'field_count_' || s.nfields
              when s.code_status <> 'ok' then 'code_' || s.code_status
              when not s.ts_shape_ok then 'time_bad_format' end,
         s.raw_code, case when s.code_status = 'ok' then s.code end, s.code_status, s.ts_text, p.lt,
         case when s.ts_text is null then null when not s.ts_shape_ok then 'bad_format'
              when p.lt is null and substr(s.ts_text, 1, 4)::int not between 2000 and 2100 then 'out_of_range'
              when p.lt is null then 'impossible_date' else i.status end,
         i.instant,
         array_remove(array[
           case when s.width_ok = false then 'code_width_unexpected' end,
           case when i.instant > now() + make_interval(secs => st.future_tolerance_s) then 'future' end,
           case when i.instant < now() - make_interval(days => st.backfill_days) then 'older_than_backfill' end], null),
         sha256(convert_to(l, 'UTF8'))
    from unnest(x.lines[from_line:to_line]) with ordinality u(l, j)
    cross join lateral (select (from_line + j - 1) as k) kk
    cross join lateral public.biometric_dat_split(l) s
    cross join lateral (select case when s.ts_shape_ok then public.biometric_parse_local(s.ts_text) end as lt) p
    cross join lateral public.biometric_dat_instant(p.lt, b.declared_timezone) i;
  update public.biometric_import_batches set progress_line = to_line, last_activity_at = now(), updated_at = now(),
         state = case when to_line >= b.line_count then 'classifying' else 'parsing' end,
         version = version + 1 where id = b.id;
  if to_line >= b.line_count then
    update public.biometric_import_batches set progress_line = 0 where id = b.id;
    return jsonb_build_object('ok', true, 'state', 'classifying', 'progress_line', 0, 'lines', b.line_count);
  end if;
  return jsonb_build_object('ok', true, 'state', 'parsing', 'progress_line', to_line, 'lines', b.line_count);
end $$;

-- Duplicate labels (first match wins): exact_in_file → exact_in_earlier_import → same_code_time_other_fields →
-- already_from_device → new. Every row stays; a label points at the earlier evidence.
create function public.biometric_dat_classify(b public.biometric_import_batches) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lim jsonb := public.biometric_dat_limits(); from_line int := b.progress_line + 1;
        to_line int := least(b.line_count, b.progress_line + (lim ->> 'lines_per_call')::int);
begin
  update public.biometric_import_rows r set
         dup_class = c.cls, dup_ref_batch = c.ref_batch, dup_ref_line = c.ref_line, dup_ref_raw_event = c.ref_raw,
         flags = case when c.out_of_order and not ('out_of_order' = any (r.flags)) then r.flags || 'out_of_order'::text else r.flags end
    from (
      select r2.batch_id, r2.line_no,
             case when r2.parse_status = 'blank' then null
                  when f.line_no is not null then 'exact_in_file'
                  when e.batch_id is not null then 'exact_in_earlier_import'
                  when sf.line_no is not null or se.batch_id is not null then 'same_code_time_other_fields'
                  when d.n >= rk.n then 'already_from_device'
                  else 'new' end as cls,
             case when r2.parse_status = 'blank' then null when f.line_no is not null then r2.batch_id when e.batch_id is not null then e.batch_id
                  when sf.line_no is not null then r2.batch_id when se.batch_id is not null then se.batch_id end as ref_batch,
             case when r2.parse_status = 'blank' then null else coalesce(f.line_no, e.line_no, sf.line_no, se.line_no) end as ref_line,
             case when r2.parse_status <> 'blank' and f.line_no is null and e.batch_id is null and sf.line_no is null and se.batch_id is null
                       and d.n >= rk.n then d.first_id end as ref_raw,
             (r2.local_ts is not null and prev.local_ts is not null and r2.local_ts < prev.local_ts) as out_of_order
        from public.biometric_import_rows r2
        left join lateral (select x.line_no from public.biometric_import_rows x
                            where x.batch_id = r2.batch_id and x.line_hash = r2.line_hash and x.line_no < r2.line_no and r2.parse_status <> 'blank'
                            order by x.line_no limit 1) f on true
        left join lateral (select x.batch_id, x.line_no from public.biometric_import_rows x join public.biometric_import_batches bb on bb.id = x.batch_id
                            where x.company_id = r2.company_id and x.source_device_id = r2.source_device_id and x.line_hash = r2.line_hash
                              and x.batch_id <> r2.batch_id and bb.state in ('ready_for_review', 'reviewed') and r2.parse_status <> 'blank'
                            order by bb.created_at, x.line_no limit 1) e on true
        left join lateral (select x.line_no from public.biometric_import_rows x
                            where x.batch_id = r2.batch_id and r2.local_ts is not null and r2.employee_code is not null
                              and x.employee_code = r2.employee_code and x.local_ts = r2.local_ts and x.line_no < r2.line_no and x.line_hash <> r2.line_hash
                            order by x.line_no limit 1) sf on true
        left join lateral (select x.batch_id, x.line_no from public.biometric_import_rows x join public.biometric_import_batches bb on bb.id = x.batch_id
                            where x.company_id = r2.company_id and x.source_device_id = r2.source_device_id and r2.local_ts is not null
                              and r2.employee_code is not null and x.employee_code = r2.employee_code and x.local_ts = r2.local_ts
                              and x.line_hash <> r2.line_hash and x.batch_id <> r2.batch_id and bb.state in ('ready_for_review', 'reviewed')
                            order by bb.created_at, x.line_no limit 1) se on true
        left join lateral (select count(*) + 1 as n from public.biometric_import_rows x
                            where x.batch_id = r2.batch_id and x.employee_code = r2.employee_code and x.local_ts = r2.local_ts
                              and x.line_no < r2.line_no) rk on true
        left join lateral (select count(*) as n, min(ev.id) as first_id from public.biometric_raw_events ev
                            where r2.local_ts is not null and r2.employee_code is not null and ev.company_id = r2.company_id
                              and ev.device_id = r2.source_device_id and ev.employee_device_code = r2.employee_code
                              and public.biometric_parse_local(ev.device_local_time) = r2.local_ts) d on true
        left join lateral (select x.local_ts from public.biometric_import_rows x
                            where x.batch_id = r2.batch_id and x.line_no < r2.line_no and x.local_ts is not null
                            order by x.line_no desc limit 1) prev on true
       where r2.batch_id = b.id and r2.line_no between from_line and to_line
    ) c
   where r.batch_id = c.batch_id and r.line_no = c.line_no;

  if to_line < b.line_count then
    update public.biometric_import_batches set progress_line = to_line, last_activity_at = now(), updated_at = now(), version = version + 1 where id = b.id;
    return jsonb_build_object('ok', true, 'state', 'classifying', 'progress_line', to_line, 'lines', b.line_count);
  end if;
  update public.biometric_import_batches set state = 'ready_for_review', progress_line = b.line_count, last_activity_at = now(), updated_at = now(),
         rows = b.line_count, version = version + 1,
         counts = (select jsonb_build_object(
                     'lines', count(*),
                     'ok', count(*) filter (where parse_status = 'ok'),
                     'blank', count(*) filter (where parse_status = 'blank'),
                     'unparsable', count(*) filter (where parse_status = 'unparsable'),
                     'codes', count(distinct employee_code) filter (where code_status = 'ok'),
                     'time_problems', count(*) filter (where time_status is not null and time_status <> 'ok'),
                     'new', count(*) filter (where dup_class = 'new'),
                     'exact_in_file', count(*) filter (where dup_class = 'exact_in_file'),
                     'exact_in_earlier_import', count(*) filter (where dup_class = 'exact_in_earlier_import'),
                     'same_code_time_other_fields', count(*) filter (where dup_class = 'same_code_time_other_fields'),
                     'already_from_device', count(*) filter (where dup_class = 'already_from_device'),
                     'out_of_order', count(*) filter (where 'out_of_order' = any (flags)),
                     'code_width_unexpected', count(*) filter (where 'code_width_unexpected' = any (flags)),
                     'future', count(*) filter (where 'future' = any (flags)),
                     'older_than_backfill', count(*) filter (where 'older_than_backfill' = any (flags)))
                     from public.biometric_import_rows where batch_id = b.id)
   where id = b.id;
  perform public.biometric_dat_audit(b.company_id, 'dat_import.ready', b.id, jsonb_build_object('state', 'ready_for_review', 'lines', b.line_count,
           'counts', (select counts from public.biometric_import_batches where id = b.id)));
  return jsonb_build_object('ok', true, 'state', 'ready_for_review', 'progress_line', b.line_count, 'lines', b.line_count);
end $$;

-- One unit of work. The client calls it until the state is ready_for_review or failed.
create function public.biometric_dat_process(p_batch uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); b public.biometric_import_batches;
begin
  b := public.biometric_dat_lock(cid, p_batch);
  if b.state = 'uploaded' then return public.biometric_dat_validate(b);
  elsif b.state = 'parsing' then return public.biometric_dat_parse(b);
  elsif b.state = 'classifying' then return public.biometric_dat_classify(b);
  end if;
  return jsonb_build_object('ok', b.state in ('ready_for_review', 'reviewed'), 'state', b.state, 'error', b.fail_reason, 'line', b.fail_line);
end $$;

-- ================================================================ reading
create function public.biometric_dat_status(p_batch uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); b public.biometric_import_batches;
begin
  perform public.biometric_dat_expire(cid);
  select * into b from public.biometric_import_batches where id = p_batch and company_id = cid and state <> 'legacy';
  if not found then raise exception 'Import batch not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('batch_id', b.id, 'state', b.state, 'next_index', b.next_chunk, 'chunk_count', b.chunk_count,
    'received', (select coalesce(jsonb_agg(encode(sha256, 'hex') order by idx), '[]') from public.biometric_import_chunks where batch_id = b.id),
    'declared_sha256', encode(b.file_sha256, 'hex'), 'declared_size', b.declared_size, 'progress_line', b.progress_line,
    'lines', b.line_count, 'fail_reason', b.fail_reason, 'fail_line', b.fail_line, 'counts', b.counts, 'version', b.version,
    'mine', b.uploaded_by = public.my_employee_id());
end $$;

create function public.biometric_dat_batches() returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true);
begin
  perform public.biometric_dat_expire(cid);
  return jsonb_build_object('limits', public.biometric_dat_limits(), 'batches', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', b.id, 'state', b.state, 'file_name', b.file_name, 'size', b.declared_size, 'sha256', encode(b.file_sha256, 'hex'),
      'source_device_id', b.source_device_id, 'device_name', d.name, 'timezone', b.declared_timezone, 'format_version', b.format_version,
      'lines', b.line_count, 'counts', b.counts, 'next_index', b.next_chunk, 'chunk_count', b.chunk_count, 'progress_line', b.progress_line,
      'fail_reason', b.fail_reason, 'fail_line', b.fail_line, 'bom', b.bom, 'final_terminator', b.final_terminator,
      'uploaded_by', e.full_name, 'mine', b.uploaded_by = public.my_employee_id(), 'created_at', b.created_at,
      'last_activity_at', b.last_activity_at, 'reviewed_by', r.full_name, 'reviewed_at', b.reviewed_at,
      'deleted_at', b.deleted_at, 'delete_reason', b.delete_reason, 'version', b.version) order by b.created_at desc), '[]')
      from public.biometric_import_batches b
      left join public.biometric_devices d on d.id = b.source_device_id
      left join public.employees e on e.id = b.uploaded_by
      left join public.employees r on r.id = b.reviewed_by
     where b.company_id = cid and b.state <> 'legacy'));
end $$;

-- Mapping applied to each row, computed on read with the same rules as biometric_resolve_mapping: a device mapping of
-- the batch's source device valid at the record's instant, else a company-wide mapping valid then, else none.
create function public.biometric_dat_row_mapping(cid uuid, bid uuid)
returns table (line_no int, mapping_status text, mapping_id uuid, employee_id uuid, scope text)
language sql stable security definer set search_path = public as $$
  select r.line_no,
         case when r.parse_status = 'blank' then null
              when r.code_status is distinct from 'ok' then 'code_invalid'
              when r.instant is null then 'undetermined_time'
              when m.id is null then 'unmapped'
              when not coalesce(e.active, false) then 'mapped_employee_inactive'
              else 'mapped' end,
         m.id, m.employee_id, case when m.id is null then null when m.device_id is null then 'company' else 'device' end
    from public.biometric_import_rows r
    left join lateral (select mm.* from public.biometric_employee_mappings mm
                        where r.code_status = 'ok' and r.instant is not null and mm.company_id = cid
                          and mm.employee_device_code = r.employee_code
                          and (mm.device_id = r.source_device_id or mm.device_id is null)
                          and mm.valid_from <= r.instant and (mm.valid_to is null or mm.valid_to > r.instant)
                        order by (mm.device_id is null) limit 1) m on true
    left join public.employees e on e.id = m.employee_id
   where r.batch_id = bid and r.company_id = cid
$$;

create function public.biometric_dat_codes(p_batch uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); out jsonb;
begin
  if not exists (select 1 from public.biometric_import_batches where id = p_batch and company_id = cid and state in ('ready_for_review', 'reviewed')) then
    raise exception 'Import batch not found or not ready for review' using errcode = 'P0002';
  end if;
  with m as (select r.employee_code, r.code_status, r.local_ts, r.local_time_text, x.mapping_status, x.employee_id, x.scope
               from public.biometric_import_rows r join public.biometric_dat_row_mapping(cid, p_batch) x on x.line_no = r.line_no
              where r.batch_id = p_batch),
       per_emp as (select employee_code, employee_id, scope, count(*) as n from m where employee_id is not null group by 1, 2, 3),
       per_code as (select employee_code, count(*) as records, min(local_time_text) as first, max(local_time_text) as last,
                           count(*) filter (where mapping_status = 'mapped') as mapped,
                           count(*) filter (where mapping_status = 'mapped_employee_inactive') as inactive,
                           count(*) filter (where mapping_status = 'unmapped') as unmapped,
                           count(*) filter (where mapping_status = 'undetermined_time') as undetermined
                      from m where code_status = 'ok' group by 1)
  select jsonb_build_object(
    'codes', coalesce((select jsonb_agg(jsonb_build_object('code', c.employee_code, 'records', c.records, 'first', c.first, 'last', c.last,
                         'mapped', c.mapped, 'inactive', c.inactive, 'unmapped', c.unmapped, 'undetermined', c.undetermined,
                         'employees', coalesce((select jsonb_agg(jsonb_build_object('employee_id', e.id, 'full_name', e.full_name, 'emp_code', e.emp_code,
                                                  'active', e.active, 'scope', pe.scope, 'records', pe.n) order by e.full_name)
                                                  from per_emp pe join public.employees e on e.id = pe.employee_id
                                                 where pe.employee_code = c.employee_code), '[]'))
                         order by lpad(c.employee_code, 32, ' '))
                       from per_code c), '[]'),
    'invalid_codes', (select count(*) from m where code_status is not null and code_status <> 'ok'),
    'totals', (select jsonb_build_object(
                 'mapped', count(*) filter (where mapping_status = 'mapped'),
                 'inactive', count(*) filter (where mapping_status = 'mapped_employee_inactive'),
                 'unmapped', count(*) filter (where mapping_status = 'unmapped'),
                 'undetermined', count(*) filter (where mapping_status = 'undetermined_time'),
                 'code_invalid', count(*) filter (where mapping_status = 'code_invalid')) from m))
    into out;
  return out;
end $$;

-- Paged rows. Filters: all, problems (unparsable, blank, time or code issues, flags), duplicates, unmapped, code:<exact>.
create function public.biometric_dat_rows(p_batch uuid, p_filter text, p_code text, p_offset int, p_limit int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); lim int := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  if not exists (select 1 from public.biometric_import_batches where id = p_batch and company_id = cid and state in ('ready_for_review', 'reviewed')) then
    raise exception 'Import batch not found or not ready for review' using errcode = 'P0002';
  end if;
  return (
    with m as (select * from public.biometric_dat_row_mapping(cid, p_batch)),
    f as (
      select r.*, m.mapping_status, m.employee_id, m.scope
        from public.biometric_import_rows r join m on m.line_no = r.line_no
       where r.batch_id = p_batch
         and case coalesce(p_filter, 'all')
               when 'all' then true
               when 'problems' then r.parse_status <> 'ok' or coalesce(r.time_status, 'ok') <> 'ok' or cardinality(r.flags) > 0
               when 'duplicates' then r.dup_class is not null and r.dup_class <> 'new'
               when 'unmapped' then m.mapping_status in ('unmapped', 'undetermined_time', 'code_invalid')
               when 'code' then r.employee_code = p_code
               else false end)
    select jsonb_build_object('total', (select count(*) from f), 'offset', coalesce(p_offset, 0), 'limit', lim, 'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'line', f.line_no, 'raw_line', f.raw_line, 'terminator', f.terminator, 'fields', to_jsonb(f.fields),
        'parse_status', f.parse_status, 'parse_reason', f.parse_reason, 'raw_code_field', f.raw_code_field, 'code', f.employee_code,
        'code_status', f.code_status, 'local_time_text', f.local_time_text, 'time_status', f.time_status, 'instant', f.instant,
        'flags', to_jsonb(f.flags), 'dup_class', f.dup_class, 'dup_ref_batch', f.dup_ref_batch, 'dup_ref_line', f.dup_ref_line,
        'dup_ref_raw_event', f.dup_ref_raw_event, 'mapping_status', f.mapping_status, 'scope', f.scope,
        'employee', case when e.id is null then null else jsonb_build_object('id', e.id, 'full_name', e.full_name, 'emp_code', e.emp_code, 'active', e.active) end)
        order by f.line_no)
        from (select * from f order by line_no offset coalesce(p_offset, 0) limit lim) f
        left join public.employees e on e.id = f.employee_id), '[]'))
  );
end $$;

-- ================================================================ review, cancel, delete, download
create function public.biometric_dat_mark_reviewed(p_batch uuid, p_version int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); b public.biometric_import_batches;
begin
  b := public.biometric_dat_lock(cid, p_batch);
  if b.state <> 'ready_for_review' then return jsonb_build_object('ok', false, 'error', 'not_ready', 'state', b.state); end if;
  if p_version is distinct from b.version then return jsonb_build_object('ok', false, 'error', 'changed_meanwhile'); end if;
  update public.biometric_import_batches set state = 'reviewed', reviewed_by = public.my_employee_id(), reviewed_at = now(),
         last_activity_at = now(), updated_at = now(), version = version + 1 where id = b.id;
  perform public.biometric_dat_audit(cid, 'dat_import.reviewed', b.id, jsonb_build_object('state', 'reviewed'));
  return jsonb_build_object('ok', true, 'state', 'reviewed');
end $$;

create function public.biometric_dat_cancel(p_batch uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); b public.biometric_import_batches;
begin
  b := public.biometric_dat_lock(cid, p_batch);
  if b.state not in ('uploading', 'uploaded', 'parsing', 'classifying') then
    return jsonb_build_object('ok', false, 'error', 'not_in_progress', 'state', b.state);
  end if;
  perform public.biometric_dat_purge(b.id);
  update public.biometric_import_batches set state = 'cancelled', upload_token_hash = null, last_activity_at = now(), updated_at = now(),
         version = version + 1 where id = b.id;
  perform public.biometric_dat_audit(cid, 'dat_import.cancelled', b.id, jsonb_build_object('state', 'cancelled'));
  return jsonb_build_object('ok', true, 'state', 'cancelled');
end $$;

-- Delete a finished or ended batch: bytes and rows go, the batch stays as a tombstone (counts, hash, who, when, why);
-- the file name is removed because it may contain the device serial. Audit history is never touched.
create function public.biometric_dat_delete(p_batch uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); b public.biometric_import_batches;
begin
  if p_reason is null or length(trim(p_reason)) < 5 then return jsonb_build_object('ok', false, 'error', 'reason_required'); end if;
  b := public.biometric_dat_lock(cid, p_batch);
  if b.state not in ('ready_for_review', 'reviewed', 'failed', 'expired', 'cancelled') then
    return jsonb_build_object('ok', false, 'error', 'cannot_delete', 'state', b.state);
  end if;
  perform public.biometric_dat_purge(b.id);
  update public.biometric_import_batches set state = 'deleted', file_name = 'deleted', deleted_by = public.my_employee_id(), deleted_at = now(),
         delete_reason = trim(p_reason), upload_token_hash = null, updated_at = now(), version = version + 1 where id = b.id;
  perform public.biometric_dat_audit(cid, 'dat_import.deleted', b.id, jsonb_build_object('state', 'deleted', 'reason', 'admin_delete'));
  return jsonb_build_object('ok', true, 'state', 'deleted');
end $$;

create function public.biometric_dat_download(p_batch uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid := public.biometric_require(true); b public.biometric_import_batches; raw bytea;
begin
  select * into b from public.biometric_import_batches where id = p_batch and company_id = cid and state <> 'legacy';
  if not found then raise exception 'Import batch not found' using errcode = 'P0002'; end if;
  select original into raw from public.biometric_import_files where batch_id = b.id;
  if raw is null then return jsonb_build_object('ok', false, 'error', 'no_file'); end if;
  perform public.biometric_dat_audit(cid, 'dat_import.downloaded', b.id, jsonb_build_object('size', octet_length(raw), 'sha256', encode(sha256(raw), 'hex')));
  return jsonb_build_object('ok', true, 'file_name', b.file_name, 'sha256', encode(sha256(raw), 'hex'), 'data', replace(encode(raw, 'base64'), E'\n', ''));
end $$;

-- ================================================================ grants: nothing for PUBLIC or anon; Admin functions for signed-in users
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'biometric\_dat\_%' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
grant execute on function public.biometric_dat_begin(uuid, text, text, bigint, text, text[]), public.biometric_dat_chunk(uuid, text, int, text),
  public.biometric_dat_resume(uuid), public.biometric_dat_finish(uuid, text), public.biometric_dat_process(uuid),
  public.biometric_dat_status(uuid), public.biometric_dat_batches(), public.biometric_dat_codes(uuid),
  public.biometric_dat_rows(uuid, text, text, int, int), public.biometric_dat_mark_reviewed(uuid, int), public.biometric_dat_cancel(uuid),
  public.biometric_dat_delete(uuid, text), public.biometric_dat_download(uuid) to authenticated;
