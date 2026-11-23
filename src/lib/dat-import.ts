/**
 * B5 offline DAT import — browser side.
 *
 * The browser only hashes, chunks and uploads the ORIGINAL bytes; it never parses or changes them. Parsing,
 * duplicate labels and the mapping preview happen in the database (migration 0013), so what is stored always
 * derives from the stored original. Nothing here writes attendance, raw biometric events or projection.
 *
 * Upload protocol (all calls are Admin-only database functions):
 *   begin(declared size, SHA-256, per-chunk SHA-256) → chunk(i, bytes) × n → finish → process × k
 * Resending a chunk is harmless (same hash = idempotent repeat); a refresh resumes by taking the upload over.
 */

export const DAT_CHUNK_BYTES = 262144; // must equal biometric_dat_limits().chunk_bytes
export const DAT_MAX_BYTES = 16777216;

export interface RpcResult { data: unknown; error: { message: string } | null }
export interface RpcClient { rpc(fn: string, args?: Record<string, unknown>): PromiseLike<RpcResult> }

export type DatState =
  | "uploading" | "uploaded" | "parsing" | "classifying" | "ready_for_review" | "reviewed"
  | "failed" | "expired" | "cancelled" | "deleted";

export interface UploadProgress { phase: "hashing" | "uploading" | "checking" | "done"; done: number; total: number }

export interface UploadOutcome { batchId: string | null; state: DatState | null; error: string | null; detail?: Record<string, unknown> }

type J = Record<string, unknown>;

/** Hex SHA-256 of bytes (Web Crypto in browsers; Node's webcrypto in tests). */
export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", bytes as unknown as ArrayBuffer);
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
}

export function splitChunks(bytes: Uint8Array, size = DAT_CHUNK_BYTES): Uint8Array[] {
  const out: Uint8Array[] = [];
  for (let i = 0; i < bytes.length; i += size) out.push(bytes.subarray(i, Math.min(bytes.length, i + size)));
  return out;
}

export function toBase64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export function fromBase64(b64: string): Uint8Array {
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

export function fmtBytes(n: number): string {
  if (n < 1024) return `${n} bytes`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

/** Plain-language text for every refusal the database can give. */
export const DAT_ERROR_TEXT: Record<string, string> = {
  device_not_found: "Choose a device of this company.",
  device_not_essl: "This file format is for eSSL devices. Choose the eSSL device the file came from.",
  invalid_timezone: "Choose a valid time zone.",
  invalid_file_name: "The file name is too long or empty.",
  empty_file: "The file is empty.",
  file_too_large: "The file is larger than 16 MB, which is more than an X2008 export can be.",
  invalid_sha256: "The file could not be checked. Try again.",
  invalid_chunk_hashes: "The file could not be split for upload. Try again.",
  resume_available: "You were already uploading this file. It continues where it stopped.",
  being_uploaded: "Another Admin is uploading this file right now. Wait for them or ask them to cancel it.",
  already_imported: "This exact file has already been imported. Open the earlier import instead.",
  too_many_open_batches: "Three imports are still in progress. Finish or cancel one first.",
  not_uploading: "This upload is no longer in progress.",
  taken_over: "This upload was continued in another tab or window. Continue it there, or refresh.",
  invalid_index: "The upload got out of step. Refresh and try again.",
  wrong_order: "A part of the file arrived out of order. It is sent again in the right order.",
  invalid_chunk_data: "Part of the file could not be read. Try again.",
  chunk_conflict: "Part of the file differs from what was sent before. Choose the same file, or cancel this upload.",
  chunk_hash_mismatch: "Part of the file did not arrive intact. It will be sent again.",
  missing_chunks: "Some parts of the file have not arrived yet.",
  hash_mismatch: "The file that arrived is not the file that was chosen (check value differs). Nothing was kept. Try again.",
  size_mismatch: "The file that arrived has a different size from the file chosen. Nothing was kept. Try again.",
  unsupported_encoding: "The file is not in the expected text encoding. Nothing was kept.",
  not_a_text_file: "This is not a text attendance export (it contains binary data). Nothing was kept.",
  unexpected_line_endings: "The line endings differ from the X2008 export (expected Windows line endings). The file may have been re-saved. Nothing was kept.",
  too_many_rows: "The file has more than 200,000 lines. Nothing was kept.",
  line_too_long: "A line is longer than an attendance record can be. Nothing was kept.",
  too_many_fields: "A line has far more fields than an attendance record. Nothing was kept.",
  unexpected_header: "The first line is not an attendance record (a heading?). Nothing was kept.",
  unexpected_delimiter: "The fields are not separated by tabs as in the X2008 export. Nothing was kept.",
  too_many_blank_rows: "More than 1 % of the lines are empty. This does not look like an X2008 export. Nothing was kept.",
  too_many_malformed_rows: "More than 2 % of the lines are not valid records. This does not look like an X2008 export. Nothing was kept.",
  processing_stalled: "Checking the file stopped for more than 2 hours. Nothing was kept. Upload it again.",
  upload_idle: "The upload was left unfinished for more than 24 hours. Nothing was kept.",
  not_ready: "This import is not ready for review.",
  changed_meanwhile: "This import changed meanwhile. Refresh and try again.",
  reason_required: "Give a reason (at least 5 characters).",
  cannot_delete: "This import cannot be deleted in its current state.",
  not_in_progress: "This import is not in progress.",
  no_file: "The original file is no longer kept for this import.",
  network: "The connection dropped. Try again.",
};

export function datErrorText(code: string | null | undefined): string {
  if (!code) return "Something went wrong.";
  return DAT_ERROR_TEXT[code] ?? code;
}

async function call(sb: RpcClient, fn: string, args: J): Promise<J> {
  const r = await sb.rpc(fn, args);
  if (r.error) throw new Error(r.error.message);
  return (r.data ?? {}) as J;
}

/** Call with retries for network failures only (the server answers protocol errors as data, not exceptions). */
async function retrying<T>(f: () => Promise<T>, tries = 4, wait = (ms: number) => new Promise((r) => setTimeout(r, ms))): Promise<T> {
  let last: unknown;
  for (let i = 0; i < tries; i++) {
    try {
      return await f();
    } catch (e) {
      last = e;
      const msg = e instanceof Error ? e.message : String(e);
      if (/not allowed|not found|permission/i.test(msg)) throw e;
      await wait(250 * 2 ** i);
    }
  }
  throw last;
}

export interface UploadOptions {
  onProgress?: (p: UploadProgress) => void;
  /** test hook: replaces the retry delay */
  wait?: (ms: number) => Promise<void>;
}

/**
 * Upload the original bytes and have the database check them. Resumes automatically when this Admin already has an
 * unfinished upload of the same file. Returns the batch and its final state; never throws for protocol refusals.
 */
export async function uploadDat(sb: RpcClient, file: { name: string; bytes: Uint8Array }, deviceId: string, timezone: string, opts: UploadOptions = {}): Promise<UploadOutcome> {
  const progress = opts.onProgress ?? (() => {});
  const wait = opts.wait;
  const retry = <T,>(f: () => Promise<T>) => retrying(f, 4, wait);
  if (file.bytes.length === 0) return { batchId: null, state: null, error: "empty_file" };
  if (file.bytes.length > DAT_MAX_BYTES) return { batchId: null, state: null, error: "file_too_large" };

  progress({ phase: "hashing", done: 0, total: 1 });
  const chunks = splitChunks(file.bytes);
  const hashes = await Promise.all(chunks.map(sha256Hex));
  const whole = await sha256Hex(file.bytes);

  let begun = await retry(() => call(sb, "biometric_dat_begin", { p_device: deviceId, p_timezone: timezone, p_file_name: file.name, p_size: file.bytes.length, p_sha256: whole, p_chunk_hashes: hashes }));
  let batchId: string;
  let token: string;
  let next: number;
  if (begun.ok === true) {
    batchId = String(begun.batch_id);
    token = String(begun.upload_token);
    next = 0;
  } else if (begun.error === "resume_available") {
    batchId = String(begun.batch_id);
    const r = await retry(() => call(sb, "biometric_dat_resume", { p_batch: batchId }));
    if (r.ok !== true) return { batchId, state: (r.state as DatState) ?? null, error: String(r.error ?? "not_uploading") };
    // the server's declared values must be this file's, chunk by chunk, before anything more is sent
    const declared = r.chunk_hashes as string[];
    if (r.declared_sha256 !== whole || declared.length !== hashes.length || declared.some((h, i) => h !== hashes[i])) {
      return { batchId, state: "uploading", error: "chunk_conflict" };
    }
    token = String(r.upload_token);
    next = Number(r.next_index);
  } else {
    return { batchId: (begun.batch_id as string) ?? null, state: null, error: String(begun.error), detail: begun };
  }
  begun = {};

  // chunks: the server says which index it expects; repeats are harmless
  let guard = 0;
  while (next < chunks.length) {
    if (++guard > chunks.length * 6) return { batchId, state: "uploading", error: "invalid_index" };
    progress({ phase: "uploading", done: next, total: chunks.length });
    const i = next;
    const r = await retry(() => call(sb, "biometric_dat_chunk", { p_batch: batchId, p_token: token, p_index: i, p_data: toBase64(chunks[i]) }));
    if (r.ok === true) next = Number(r.next_index);
    else if (r.error === "wrong_order" || r.error === "chunk_hash_mismatch") next = Number(r.expected_index ?? next);
    else return { batchId, state: "uploading", error: String(r.error) };
  }
  progress({ phase: "uploading", done: chunks.length, total: chunks.length });

  const fin = await retry(() => call(sb, "biometric_dat_finish", { p_batch: batchId, p_token: token }));
  if (fin.ok !== true) return { batchId, state: (fin.state as DatState) ?? "uploading", error: String(fin.error) };

  // checking: one unit of work per call until ready or refused
  for (let steps = 0; steps < 200; steps++) {
    const p = await retry(() => call(sb, "biometric_dat_process", { p_batch: batchId }));
    const state = p.state as DatState;
    progress({ phase: "checking", done: Number(p.progress_line ?? 0), total: Number(p.lines ?? 0) });
    if (state === "ready_for_review" || state === "reviewed") {
      progress({ phase: "done", done: 1, total: 1 });
      return { batchId, state, error: null };
    }
    if (state === "failed" || state === "cancelled" || state === "expired") return { batchId, state, error: String(p.error ?? "failed"), detail: p };
  }
  return { batchId, state: "parsing", error: "processing_stalled" };
}

/* ---------------- read side ---------------- */

export interface DatBatch {
  id: string; state: DatState; file_name: string; size: number | null; sha256: string; source_device_id: string | null; device_name: string | null;
  timezone: string | null; format_version: string | null; lines: number | null; counts: Record<string, number>; next_index: number; chunk_count: number | null;
  progress_line: number; fail_reason: string | null; fail_line: number | null; bom: string | null; final_terminator: string | null;
  uploaded_by: string | null; mine: boolean; created_at: string; last_activity_at: string; reviewed_by: string | null; reviewed_at: string | null;
  deleted_at: string | null; delete_reason: string | null; version: number;
}

export interface DatCode {
  code: string; records: number; first: string; last: string; mapped: number; inactive: number; unmapped: number; undetermined: number;
  employees: { employee_id: string; full_name: string; emp_code: string | null; active: boolean; scope: "device" | "company"; records: number }[];
}

export interface DatRow {
  line: number; raw_line: string; terminator: "crlf" | "none"; fields: string[]; parse_status: "ok" | "blank" | "unparsable"; parse_reason: string | null;
  raw_code_field: string | null; code: string | null; code_status: string | null; local_time_text: string | null; time_status: string | null;
  instant: string | null; flags: string[]; dup_class: string | null; dup_ref_batch: string | null; dup_ref_line: number | null; dup_ref_raw_event: number | null;
  mapping_status: string | null; scope: "device" | "company" | null; employee: { id: string; full_name: string; emp_code: string | null; active: boolean } | null;
}

export type RowFilter = "all" | "problems" | "duplicates" | "unmapped" | "code";

export async function listBatches(sb: RpcClient): Promise<{ batches: DatBatch[]; limits: Record<string, unknown> }> {
  const r = await call(sb, "biometric_dat_batches", {});
  return { batches: (r.batches as DatBatch[]) ?? [], limits: (r.limits as Record<string, unknown>) ?? {} };
}

export async function loadCodes(sb: RpcClient, batchId: string): Promise<{ codes: DatCode[]; invalid_codes: number; totals: Record<string, number> }> {
  return (await call(sb, "biometric_dat_codes", { p_batch: batchId })) as unknown as { codes: DatCode[]; invalid_codes: number; totals: Record<string, number> };
}

export async function loadRows(sb: RpcClient, batchId: string, filter: RowFilter, code: string | null, offset: number, limit = 100): Promise<{ total: number; rows: DatRow[] }> {
  const r = await call(sb, "biometric_dat_rows", { p_batch: batchId, p_filter: filter, p_code: code, p_offset: offset, p_limit: limit });
  return { total: Number(r.total ?? 0), rows: (r.rows as DatRow[]) ?? [] };
}

export async function batchAction(sb: RpcClient, fn: "biometric_dat_mark_reviewed" | "biometric_dat_cancel" | "biometric_dat_delete", args: J): Promise<string | null> {
  const r = await call(sb, fn, args);
  return r.ok === true ? null : datErrorText(String(r.error));
}

export async function downloadOriginal(sb: RpcClient, batchId: string): Promise<{ name: string; bytes: Uint8Array; sha256: string } | { error: string }> {
  const r = await call(sb, "biometric_dat_download", { p_batch: batchId });
  if (r.ok !== true) return { error: datErrorText(String(r.error)) };
  return { name: String(r.file_name), bytes: fromBase64(String(r.data)), sha256: String(r.sha256) };
}

/* ---------------- display helpers (no interpretation of fields 3–6) ---------------- */

/** Spaces made visible, so left-padding in field 1 can be seen exactly. */
export function showSpaces(s: string | null): string {
  return s === null ? "" : s.replace(/ /g, "·");
}

export const STATE_TEXT: Record<DatState, string> = {
  uploading: "Uploading",
  uploaded: "Uploaded — checking",
  parsing: "Checking lines",
  classifying: "Looking for duplicates",
  ready_for_review: "Ready for review",
  reviewed: "Reviewed",
  failed: "Refused",
  expired: "Expired (unfinished)",
  cancelled: "Cancelled",
  deleted: "Deleted",
};

export const DUP_TEXT: Record<string, string> = {
  new: "New",
  exact_in_file: "Repeated line in this file",
  exact_in_earlier_import: "Already in an earlier import",
  same_code_time_other_fields: "Same code and time, other fields differ",
  already_from_device: "Already received from the device",
};

export const TIME_TEXT: Record<string, string> = {
  ok: "OK",
  bad_format: "Not a date-time in the expected form",
  impossible_date: "Not a real date or time",
  out_of_range: "Year outside 2000–2100",
  nonexistent_local_time: "Time does not exist in this time zone (clock change)",
  ambiguous_local_time: "Time happens twice in this time zone (clock change)",
};

export const CODE_TEXT: Record<string, string> = {
  ok: "OK",
  empty_code: "No code",
  trailing_space: "Space after the code",
  inner_space: "Space inside the code",
  too_long: "Code longer than 32 characters",
  invalid_character: "Character not allowed in a code",
};

export const MAP_TEXT: Record<string, string> = {
  mapped: "Mapped",
  mapped_employee_inactive: "Mapped (employee switched off)",
  unmapped: "Not mapped",
  undetermined_time: "Cannot check (time not usable)",
  code_invalid: "Code not usable",
};

export const FLAG_TEXT: Record<string, string> = {
  code_width_unexpected: "Code field not 9 characters wide",
  out_of_order: "Earlier than the line before",
  future: "In the future",
  older_than_backfill: "Older than 31 days",
};
