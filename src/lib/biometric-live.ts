/**
 * Biometric Devices — LIVE company data (Phase B4).
 *
 * Reads the biometric tables of migrations 0010–0012 (row level security: Admin/HR of the signed-in company only)
 * and shapes them like the B2 demonstration state, so the approved B2 screens show real records without being
 * redesigned. Every change goes through the checked database functions (biometric_save_device,
 * biometric_set_device_status, biometric_set_direction_mode, biometric_save_mapping, biometric_end_mapping,
 * biometric_review_event); the database refuses anything the role may not do, whatever the screen shows.
 *
 * Never read here: raw device payloads (biometric_raw_payload / biometric_error_payload are not called; the raw
 * table is read only through the column-limited view biometric_raw_events_safe), agent keys or credentials.
 */
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Agent, AuditEntry, DemoState, Device, DeviceError, DirectionMode, Manufacturer, Mapping, MappingEvent, Method, Office, Person, RawPunch, ReviewItem, ReviewKind, SyncRun } from "./biometric-mock";
import { DECISION, type Decision } from "./biometric-mock";
import { roleLabel, type Role } from "./permissions";

const MIN = 60_000;
/** A device or agent counts as online when it reported within this time. */
export const ONLINE_WITHIN_MS = 15 * MIN;
const REVIEW_LIMIT = 500;
const SYNC_LIMIT = 200;

/* ------------------------------------------------------------------ wording for database reasons */

export const FLAG_TEXT: Record<string, string> = {
  unauthenticated_source: "The device's request was not authenticated (LAN push without device authentication).",
  source_auth_claim_rejected: "The agent claimed an authentication the device is not set up for; treated as not authenticated.",
  late_backfill: "Arrived later than the automatic window, so it needs an individual acceptance.",
  ambiguous_work_date: "The work date is ambiguous (close to a shift boundary).",
  clock_drift: "The device clock was off by more than the limit; the time is kept as recorded, never adjusted.",
  dst_ambiguous: "The device time falls in a daylight-saving change and is ambiguous.",
  offset_tz_mismatch: "The device's time offset does not match its time zone.",
  future_within_tolerance: "The time is slightly in the future (within the allowed tolerance).",
  inactive_employee: "The mapped employee is switched off.",
  double_press: "Pressed again within 60 seconds of a counted punch.",
  repeat_in: "A second IN shortly after a counted IN.",
  repeat_out: "A second OUT shortly after a counted OUT.",
  no_direction: "The device sent no In/Out direction.",
  out_of_order: "It is earlier than punches already counted on that day.",
  impossible_transition: "Its direction does not fit the day (for example an OUT with no IN, or an IN while a session is open).",
  would_open_closed_day: "Counting it would leave a finished day open: no OUT after it can safely close it.",
  mixed_direction_modes: "The day mixes devices with different direction modes.",
  replaced_by_earlier_punch: "An earlier punch now holds this slot.",
  before_app_checkin: "It is earlier than the person's app check-in.",
  after_day_close: "It arrived after the day was closed.",
};

export const HOLD_TEXT: Record<string, string> = {
  employee_inactive: "The employee is switched off.",
  after_exit: "The punch is after the employee's exit date.",
  before_joining: "The punch is before the employee's joining date.",
  non_working_day: "It is a day off or holiday on the roster.",
  on_leave: "The employee is on approved leave that day.",
  correction_pending: "An attendance correction for that day is waiting for a decision.",
  import_not_enabled: "Imported punches are not counted automatically yet.",
  device_without_office: "The device has no office assigned.",
};

const ERROR_TEXT: Record<string, string> = {
  unmatched_employee: "Unmatched employee code",
  unknown_device: "Unknown device",
  invalid_time: "Invalid time",
  future_time: "Future time",
  too_old: "Too old to accept",
  clock_drift: "Clock drift",
  tz_ambiguous: "Ambiguous time zone",
  unsupported_format: "Unsupported format",
  processing_failure: "Processing failure",
  inactive_employee: "Inactive employee",
  leave_or_day_off: "Leave or day off",
  conflict: "Conflicting record",
};

/* ------------------------------------------------------------------ rows as read */

interface AgentRow { id: string; name: string; agent_identifier: string; version: string | null; status: "active" | "revoked"; last_heartbeat_at: string | null }
interface DeviceRow {
  id: string; name: string; manufacturer: Manufacturer; model: string; serial_number: string; firmware_version: string | null; location_id: string | null;
  integration_method: Method; agent_id: string | null; direction_mode: DirectionMode; status: "active" | "disabled"; last_seen_at: string | null;
  last_successful_sync_at: string | null; clock_drift_s: number | null; connection: Record<string, unknown> | null; created_at: string; created_by: string | null;
}
interface MappingRow { id: string; device_id: string | null; employee_id: string; employee_device_code: string; valid_from: string; valid_to: string | null; end_reason: string | null; created_by: string | null; ended_by: string | null; created_at: string; updated_at: string }
interface SyncRow { id: number; agent_id: string; device_id: string | null; started_at: string; completed_at: string | null; status: SyncRun["status"]; received: number; stored: number; confirmed_duplicates: number; possible_duplicates: number; conflicts: number; rejected: number; error_summary: string | null }
interface StateRow { raw_event_id: number; employee_id: string | null; status: string; flag_reasons: string[]; hold_reason: string | null; decided: boolean; version: number; processed_at: string | null; next_check_at: string | null; work_date: string | null }
interface RawRow { id: number; device_id: string | null; import_batch_id: string | null; sync_run_id: number | null; employee_device_code: string; device_local_time: string; device_timezone: string; punch_at: string; received_at: string; time_flags: string[] }
interface ReviewRow { id: number; raw_event_id: number; action: Decision; reason: string | null; decided_by: string; decided_role: string; decided_at: string; state_before: { status?: string } | null }
interface ErrorRow { id: number; device_id: string | null; kind: string; detail: Record<string, unknown> | null; created_at: string; resolved_at: string | null }

/** Thrown by loadLive when this database does not have the biometric tables (migration 0010 not applied). */
export class NotInstalled extends Error {}

function missingTable(e: { code?: string; message?: string } | null): boolean {
  return Boolean(e && (e.code === "42P01" || e.code === "PGRST205" || /does not exist|could not find the table/i.test(e.message ?? "")));
}

async function rows<T>(q: PromiseLike<{ data: unknown; error: { code?: string; message: string } | null }>): Promise<T[]> {
  const { data, error } = await q;
  if (error) {
    if (missingTable(error)) throw new NotInstalled(error.message);
    throw error;
  }
  return (data ?? []) as T[];
}

async function inChunks<T>(ids: number[], load: (part: number[]) => Promise<T[]>): Promise<T[]> {
  const out: T[] = [];
  for (let i = 0; i < ids.length; i += 150) out.push(...(await load(ids.slice(i, i + 150))));
  return out;
}

/* ------------------------------------------------------------------ mapping rows to the B2 screen shapes */

function connOf(lastSeen: string | null, now: number): Device["conn"] {
  if (!lastSeen) return "never";
  return now - Date.parse(lastSeen) <= ONLINE_WITHIN_MS ? "online" : "offline";
}

function kindOf(status: string, flags: string[], timeFlags: string[]): ReviewKind {
  switch (status) {
    case "unmatched": return "unmatched";
    case "possible_duplicate": case "rejected": return "possible_duplicate";
    case "extra": return "extra";
    case "after_correction": return "after_correction";
    case "correction_needed": return "correction_needed";
    case "held": return "held";
    case "flagged": return timeFlags.length || flags.some((f) => ["clock_drift", "late_backfill", "dst_ambiguous", "offset_tz_mismatch", "future_within_tolerance"].includes(f)) ? "timestamp" : "flagged";
    default: return "flagged";
  }
}

function reasonOf(st: StateRow, raw: RawRow, deviceName: string): string {
  if (st.status === "unmatched") return `No AttendOS employee is mapped to device code ${raw.employee_device_code} on ${deviceName} at the punch time.`;
  if (st.status === "possible_duplicate") return "Looks like a punch that is already stored (same person, device and time window).";
  if (st.status === "extra" && !(st.flag_reasons ?? []).length) return "Neither the first nor the last punch of the day (first in / last out), so it is kept as an extra punch and not counted.";
  if (st.status === "after_correction") return "An approved HR correction already covers this slot; the punch stays visible.";
  if (st.status === "held") return `${HOLD_TEXT[st.hold_reason ?? ""] ?? "Waiting for a condition to clear."}${st.next_check_at ? " Looked at again automatically." : ""}`;
  const parts = [...new Set([...(st.flag_reasons ?? []), ...(raw.time_flags ?? [])])].map((f) => FLAG_TEXT[f] ?? f.replace(/_/g, " "));
  if (st.status === "correction_needed") parts.push("Only an attendance correction (requested by the employee, approved by HR or the manager) can change the day; this punch can only be dismissed here.");
  return parts.join(" ") || "Needs a decision.";
}

const OPEN_STATES = ["unmatched", "flagged", "possible_duplicate", "extra", "after_correction", "correction_needed", "held"];

/** Loads the company's biometric records (as the signed-in Admin/HR) into the B2 screen shape. */
export async function loadLive(sb: SupabaseClient, people: Person[], _offices: Office[], now = Date.now()): Promise<DemoState> {
  void _offices;
  const name = (id: string | null | undefined) => (id ? people.find((p) => p.id === id)?.full_name ?? "a former employee" : "System");

  const [agentRows, deviceRows, mappingRows, syncRows, errorRows, reviewRows, openStates] = await Promise.all([
    rows<AgentRow>(sb.from("biometric_agents").select("id, name, agent_identifier, version, status, last_heartbeat_at").order("name")),
    rows<DeviceRow>(sb.from("biometric_devices").select("id, name, manufacturer, model, serial_number, firmware_version, location_id, integration_method, agent_id, direction_mode, status, last_seen_at, last_successful_sync_at, clock_drift_s, connection, created_at, created_by").order("name")),
    rows<MappingRow>(sb.from("biometric_employee_mappings").select("id, device_id, employee_id, employee_device_code, valid_from, valid_to, end_reason, created_by, ended_by, created_at, updated_at").order("valid_from")),
    rows<SyncRow>(sb.from("biometric_sync_runs").select("id, agent_id, device_id, started_at, completed_at, status, received, stored, confirmed_duplicates, possible_duplicates, conflicts, rejected, error_summary").order("started_at", { ascending: false }).limit(SYNC_LIMIT)),
    rows<ErrorRow>(sb.from("biometric_event_errors").select("id, device_id, kind, detail, created_at, resolved_at").order("created_at", { ascending: false }).limit(200)),
    rows<ReviewRow>(sb.from("biometric_event_reviews").select("id, raw_event_id, action, reason, decided_by, decided_role, decided_at, state_before").order("decided_at", { ascending: false }).limit(REVIEW_LIMIT)),
    rows<StateRow>(sb.from("biometric_event_state").select("raw_event_id, employee_id, status, flag_reasons, hold_reason, decided, version, processed_at, next_check_at, work_date").in("status", OPEN_STATES).order("updated_at", { ascending: false }).limit(REVIEW_LIMIT)),
  ]);

  // Punches HR already decided on (any state now) are listed as closed items with their history.
  const reviewedIds = [...new Set(reviewRows.map((r) => r.raw_event_id))].filter((id) => !openStates.some((s) => s.raw_event_id === id));
  const closedStates = await inChunks(reviewedIds, (part) =>
    rows<StateRow>(sb.from("biometric_event_state").select("raw_event_id, employee_id, status, flag_reasons, hold_reason, decided, version, processed_at, next_check_at, work_date").in("raw_event_id", part)),
  );
  const states = [...openStates, ...closedStates];
  const raws = await inChunks(states.map((s) => s.raw_event_id), (part) =>
    rows<RawRow>(sb.from("biometric_raw_events_safe").select("id, device_id, import_batch_id, sync_run_id, employee_device_code, device_local_time, device_timezone, punch_at, received_at, time_flags").in("id", part)),
  );
  const rawById = new Map(raws.map((r) => [r.id, r]));

  const agents: Agent[] = agentRows.map((a) => ({
    id: a.id,
    name: a.name,
    host: a.agent_identifier,
    version: a.version ?? "not reported",
    status: a.status === "revoked" ? "revoked" : a.last_heartbeat_at && now - Date.parse(a.last_heartbeat_at) <= ONLINE_WITHIN_MS ? "online" : "offline",
    lastHeartbeat: a.last_heartbeat_at,
    queueDepth: null,
    keyPrefix: "",
  }));

  const devices: Device[] = deviceRows.map((d) => ({
    id: d.id,
    name: d.name,
    manufacturer: d.manufacturer,
    model: d.model,
    serial: d.serial_number,
    firmware: d.firmware_version ?? "",
    officeId: d.location_id,
    method: d.integration_method,
    agentId: d.agent_id,
    direction: d.direction_mode,
    disabled: d.status === "disabled",
    conn: connOf(d.last_seen_at, now),
    lastSeen: d.last_seen_at,
    lastSync: d.last_successful_sync_at,
    driftS: d.clock_drift_s,
    connection: Object.fromEntries(Object.entries(d.connection ?? {}).map(([k, v]) => [k, String(v)])),
    createdAt: d.created_at,
    createdBy: name(d.created_by),
  }));
  const deviceName = (id: string | null) => (id ? devices.find((d) => d.id === id)?.name ?? "a removed device" : "an imported file");

  const mappings: Mapping[] = mappingRows.map((m) => ({
    id: m.id, code: m.employee_device_code, deviceId: m.device_id, employeeId: m.employee_id, validFrom: m.valid_from, validTo: m.valid_to, createdBy: name(m.created_by), createdAt: m.created_at,
  }));
  const mappingHistory: MappingEvent[] = [];
  for (const m of mappingRows) {
    const scope = m.device_id ? `on ${deviceName(m.device_id)}` : "company-wide";
    mappingHistory.push({ at: m.created_at, by: name(m.created_by), code: m.employee_device_code, deviceId: m.device_id, action: `Mapped to ${name(m.employee_id)} (${scope})`, effective: m.valid_from });
    if (m.valid_to) mappingHistory.push({ at: m.updated_at, by: m.ended_by ? name(m.ended_by) : "System", code: m.employee_device_code, deviceId: m.device_id, action: `Mapping to ${name(m.employee_id)} ended — punches before the end stay with them`, reason: m.end_reason ?? undefined, effective: m.valid_to });
  }
  mappingHistory.sort((a, b) => b.at.localeCompare(a.at));

  const unmatchedBySync = new Map<number, number>();
  for (const s of openStates) {
    const r = rawById.get(s.raw_event_id);
    if (s.status === "unmatched" && r?.sync_run_id) unmatchedBySync.set(r.sync_run_id, (unmatchedBySync.get(r.sync_run_id) ?? 0) + 1);
  }
  const syncs: SyncRun[] = syncRows.map((r) => ({
    id: String(r.id), deviceId: r.device_id ?? "", agentId: r.agent_id, started: r.started_at, completed: r.completed_at, status: r.status,
    received: r.received, stored: r.stored, confirmedDup: r.confirmed_duplicates, possibleDup: r.possible_duplicates, unmatched: unmatchedBySync.get(r.id) ?? 0,
    rejected: r.rejected, error: r.error_summary ?? (r.conflicts ? `${r.conflicts} conflicting record${r.conflicts === 1 ? "" : "s"}` : null), retry: null,
  }));

  const reviewsByRaw = new Map<number, ReviewRow[]>();
  for (const v of [...reviewRows].reverse()) reviewsByRaw.set(v.raw_event_id, [...(reviewsByRaw.get(v.raw_event_id) ?? []), v]);
  const reviews: ReviewItem[] = [];
  for (const st of states) {
    const r = rawById.get(st.raw_event_id);
    if (!r) continue;
    const decided = reviewsByRaw.get(st.raw_event_id) ?? [];
    const first = decided[0]?.state_before?.status ?? st.status;
    // An extra punch or a punch after a correction that HR kept is settled; everything else in OPEN_STATES still waits.
    const open = OPEN_STATES.includes(st.status) && !(st.decided && (st.status === "extra" || st.status === "after_correction"));
    const dev = devices.find((d) => d.id === r.device_id);
    const raw: RawPunch = Object.freeze({
      deviceId: r.device_id ?? "", deviceSerial: dev?.serial ?? (r.import_batch_id ? "import" : "—"), code: r.employee_device_code,
      deviceLocalTime: r.device_local_time, deviceTimezone: r.device_timezone, punchAt: r.punch_at, receivedAt: r.received_at,
    });
    const history: AuditEntry[] = [{ at: r.received_at, by: r.import_batch_id ? "File import" : "Gateway", action: "Received and stored (the device record is never edited)" }];
    if (st.processed_at && !decided.length && st.status !== "unmatched") history.push({ at: st.processed_at, by: "Projection", action: `Checked: ${st.status.replace(/_/g, " ")}` });
    for (const v of decided) {
      history.push({ at: v.decided_at, by: `${name(v.decided_by)} · ${roleLabel(v.decided_role as Role)}`, action: DECISION[v.action]?.label ?? v.action, note: v.reason ?? undefined });
    }
    reviews.push({
      id: `raw-${st.raw_event_id}`,
      kind: kindOf(open ? st.status : first, st.flag_reasons ?? [], r.time_flags ?? []),
      raw,
      reason: reasonOf(open ? st : { ...st, status: first }, r, deviceName(r.device_id)),
      status: open ? "open" : st.status === "dismissed" ? "dismissed" : "resolved",
      history,
      rawId: st.raw_event_id,
      version: st.version,
      employeeId: st.employee_id,
    });
  }

  const errors: DeviceError[] = errorRows.map((e) => ({
    id: String(e.id), deviceId: e.device_id ?? "", at: e.created_at, kind: ERROR_TEXT[e.kind] ?? e.kind,
    detail: typeof e.detail?.message === "string" ? e.detail.message : typeof e.detail?.reason === "string" ? e.detail.reason : ERROR_TEXT[e.kind] ?? e.kind,
    resolved: Boolean(e.resolved_at),
  }));

  return { agents, devices, mappings, mappingHistory, syncs, reviews, errors, seq: 0 };
}

/* ------------------------------------------------------------------ actions through the checked database functions */

type Rpc = { data: unknown; error: { code?: string; message: string } | null };

function answer(r: Rpc): string | null {
  if (r.error) return r.error.code === "42501" || /not allowed|permission/i.test(r.error.message) ? `Not allowed: ${r.error.message}` : r.error.message;
  const d = r.data as { ok?: boolean; message?: string } | null;
  if (d && d.ok === false) return d.message ?? "The database refused this change.";
  return null;
}

export interface NewDevice {
  name: string; manufacturer: Manufacturer; model: string; serial: string; officeId: string | null; method: Method; agentId: string | null; direction: DirectionMode; connection: Record<string, string>;
}

export async function liveAddDevice(sb: SupabaseClient, d: NewDevice): Promise<{ error: string | null; id?: string }> {
  const r = await sb.rpc("biometric_save_device", {
    p_id: null,
    p: { name: d.name, manufacturer: d.manufacturer, model: d.model, serial_number: d.serial, location_id: d.officeId, integration_method: d.method, agent_id: d.agentId, direction_mode: d.direction, connection: d.connection },
  });
  const err = answer(r);
  return err ? { error: err } : { error: null, id: (r.data as { device_id?: string } | null)?.device_id };
}

export type LiveAction =
  | { type: "setDisabled"; deviceId: string; disabled: boolean }
  | { type: "setDirection"; deviceId: string; direction: DirectionMode }
  | { type: "addMapping"; code: string; deviceId: string | null; employeeId: string; validFrom: string; confirmCompanyWide?: boolean }
  | { type: "endMapping"; mappingId: string; at: string; reason: string }
  | { type: "review"; reviewId: string; decision: Decision; note: string };

export async function liveAction(sb: SupabaseClient, s: DemoState, a: LiveAction): Promise<string | null> {
  switch (a.type) {
    case "setDisabled":
      return answer(await sb.rpc("biometric_set_device_status", { p_id: a.deviceId, p_status: a.disabled ? "disabled" : "active" }));
    case "setDirection":
      return answer(await sb.rpc("biometric_set_direction_mode", { p_id: a.deviceId, p_mode: a.direction }));
    case "addMapping":
      return answer(await sb.rpc("biometric_save_mapping", { p_code: a.code.trim(), p_device: a.deviceId, p_employee: a.employeeId, p_valid_from: a.validFrom, p_confirm_company_wide: Boolean(a.confirmCompanyWide) }));
    case "endMapping":
      return answer(await sb.rpc("biometric_end_mapping", { p_id: a.mappingId, p_at: a.at, p_reason: a.reason.trim() }));
    case "review": {
      const item = s.reviews.find((r) => r.id === a.reviewId);
      if (!item?.rawId) return "This review item no longer exists. Reload the page.";
      return answer(await sb.rpc("biometric_review_event", { p_raw: item.rawId, p_action: a.decision, p_reason: a.note.trim() || null, p_expected_version: item.version ?? null }));
    }
  }
}
