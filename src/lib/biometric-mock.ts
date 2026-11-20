/**
 * Biometric Devices — DEMONSTRATION DATA (Phase B2).
 *
 * Everything in this file lives only in the browser tab. Nothing is read from or written to the
 * database, no device or Sync Agent is contacted, and a reload resets it. The shapes follow the
 * B1 design (docs/biometric/BIOMETRIC_DATABASE_SCHEMA.md) so the screens can later switch to real
 * data without being redesigned. People and offices are the company's real records when the app is
 * connected (read-only); only devices, agents, mappings, syncs and review items are invented.
 *
 * Every change goes through `reducer`, which checks the caller's role (`can`) before anything else —
 * hiding a button is never the only protection. In Phase B3 the same rules move into database functions.
 */

import { can, type Capability, type Role, roleLabel } from "./permissions";

export type Manufacturer = "zkteco" | "essl" | "matrix" | "other";
export type Method = "sdk_pull" | "local_push" | "vendor_software" | "file_import";
export type DirectionMode = "first_last" | "device";
export type Conn = "online" | "offline" | "error" | "never" | "disabled";
export type PushAuth = "authenticated" | "pull_instead" | "unauthenticated_lan";

export interface Person { id: string; full_name: string; emp_code: string | null; active: boolean }
export interface Office { id: string; name: string }

export interface Agent {
  id: string;
  name: string;
  host: string;
  version: string;
  status: "online" | "offline";
  lastHeartbeat: string | null;
  queueDepth: number;
  keyPrefix: string;
}

export interface Device {
  id: string;
  name: string;
  manufacturer: Manufacturer;
  model: string;
  serial: string;
  firmware: string;
  officeId: string | null;
  method: Method;
  agentId: string | null;
  direction: DirectionMode;
  disabled: boolean;
  conn: Exclude<Conn, "disabled">;
  lastSeen: string | null;
  lastSync: string | null;
  driftS: number | null;
  connection: Record<string, string>;
  createdAt: string;
  createdBy: string;
}

export interface Mapping {
  id: string;
  code: string;
  /** The device this code belongs to. null = company-wide (an explicit Admin choice). */
  deviceId: string | null;
  employeeId: string;
  /** Effective from (inclusive) … to (exclusive). Punches map by their own time. */
  validFrom: string;
  validTo: string | null;
  createdBy: string;
  createdAt: string;
}

export interface MappingEvent { at: string; by: string; code: string; deviceId: string | null; action: string; reason?: string; effective?: string }

export interface SyncRun {
  id: string;
  deviceId: string;
  agentId: string | null;
  started: string;
  completed: string | null;
  status: "ok" | "partial" | "failed" | "retrying";
  received: number;
  stored: number;
  confirmedDup: number;
  possibleDup: number;
  unmatched: number;
  rejected: number;
  error: string | null;
  retry: { attempt: number; nextAt: string } | null;
}

export type ReviewKind = "unmatched" | "ambiguous" | "possible_duplicate" | "after_correction" | "timestamp";
export type Decision = "accept_time" | "dismiss" | "confirm_duplicate" | "not_duplicate" | "keep_extra" | "keep_correction";

export interface AuditEntry { at: string; by: string; action: string; note?: string }

/** The punch exactly as the device sent it. Frozen: no action ever changes it. */
export interface RawPunch {
  readonly deviceId: string;
  readonly deviceSerial: string;
  readonly code: string;
  readonly deviceLocalTime: string;
  readonly deviceTimezone: string;
  readonly punchAt: string;
  readonly receivedAt: string;
}

export interface ReviewItem {
  id: string;
  kind: ReviewKind;
  raw: RawPunch;
  reason: string;
  status: "open" | "resolved" | "dismissed";
  history: AuditEntry[];
}

export interface DeviceError { id: string; deviceId: string; at: string; kind: string; detail: string; resolved: boolean }

export interface DemoState {
  agents: Agent[];
  devices: Device[];
  mappings: Mapping[];
  mappingHistory: MappingEvent[];
  syncs: SyncRun[];
  reviews: ReviewItem[];
  errors: DeviceError[];
  seq: number;
}

export const MANUFACTURER_LABEL: Record<Manufacturer, string> = { zkteco: "ZKTeco", essl: "eSSL", matrix: "Matrix", other: "Other" };
export const METHOD_LABEL: Record<Method, string> = {
  sdk_pull: "Agent reads the device (SDK pull)",
  local_push: "Device pushes to the agent (LAN)",
  vendor_software: "Agent reads vendor software",
  file_import: "File import (CSV / Excel)",
};
export const METHOD_SHORT: Record<Method, string> = { sdk_pull: "SDK pull", local_push: "LAN push", vendor_software: "Vendor software", file_import: "File import" };
export const DIRECTION_LABEL: Record<DirectionMode, string> = { first_last: "First in / last out (inferred)", device: "Device In/Out keys" };
export const CONN_LABEL: Record<Conn, string> = { online: "Online", offline: "Offline", error: "Error", never: "Not connected", disabled: "Disabled" };
export const REVIEW_LABEL: Record<ReviewKind, string> = {
  unmatched: "Unmatched employee code",
  ambiguous: "Ambiguous punch direction",
  possible_duplicate: "Possible duplicate",
  after_correction: "Punch after an HR correction",
  timestamp: "Invalid or suspicious time",
};
export const PUSH_AUTH_LABEL: Record<PushAuth, string> = {
  authenticated: "Device authenticates each request (secret / signature / TLS)",
  pull_instead: "Use pull instead (agent signs in with the device communication key)",
  unauthenticated_lan: "Unauthenticated push on an isolated device network (Admin acceptance needed)",
};

/** Review decisions: label, what it does, and whether a reason is required. */
export const DECISION: Record<Decision, { label: string; effect: string; reasonRequired: boolean }> = {
  accept_time: { label: "Accept time as recorded", effect: "The punch will be counted at the time the device recorded. Use only when you have checked the time is right.", reasonRequired: true },
  dismiss: { label: "Dismiss", effect: "The punch will not be counted. It stays stored and visible in the review history.", reasonRequired: true },
  confirm_duplicate: { label: "Confirm duplicate", effect: "Only the first punch is counted; this one stays stored as a duplicate.", reasonRequired: false },
  not_duplicate: { label: "Not a duplicate", effect: "Both punches will be considered separately. This can change the day's check-in or check-out.", reasonRequired: true },
  keep_extra: { label: "Keep as extra punch", effect: "The punch stays visible as an extra punch and is not counted as a check-in or check-out.", reasonRequired: false },
  keep_correction: { label: "Keep HR correction", effect: "The approved HR correction stays in force; this punch stays visible as an extra punch.", reasonRequired: false },
};
export const DECISIONS_FOR: Record<ReviewKind, Decision[]> = {
  unmatched: ["dismiss"],
  ambiguous: ["keep_extra", "dismiss"],
  possible_duplicate: ["confirm_duplicate", "not_duplicate"],
  after_correction: ["keep_correction", "dismiss"],
  timestamp: ["dismiss", "accept_time"],
};

/** Methods documented for each manufacturer in BIOMETRIC_HARDWARE_COMPATIBILITY.md — none hardware-verified. */
export const METHODS_FOR: Record<Manufacturer, Method[]> = {
  zkteco: ["sdk_pull", "local_push"],
  essl: ["local_push", "sdk_pull", "vendor_software"],
  matrix: ["local_push", "vendor_software"],
  other: ["file_import", "local_push", "sdk_pull"],
};

export const MODELS_FOR: Record<Manufacturer, string[]> = {
  zkteco: ["SpeedFace-V5L", "ProFace X", "MB160", "F22", "K40"],
  essl: ["AiFace Mars", "uFace 302", "X990", "K90 Pro", "F22"],
  matrix: ["COSEC ARGO FACE", "COSEC VEGA FAX", "COSEC PATH DCFE"],
  other: [],
};

export function connOf(d: Device): Conn {
  return d.disabled ? "disabled" : d.conn;
}

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

/** A device needs attention when it is in error, offline for over an hour, its clock is off by over 5 minutes, or its last sync failed. */
export function needsAttention(d: Device, s: DemoState, now: number): string[] {
  if (d.disabled) return [];
  const why: string[] = [];
  if (d.conn === "error") why.push("Connection error");
  if (d.conn === "offline" && (!d.lastSeen || now - Date.parse(d.lastSeen) > HOUR)) why.push("Offline for over an hour");
  if (d.driftS !== null && Math.abs(d.driftS) > 300) why.push(`Clock off by ${Math.round(Math.abs(d.driftS) / 60)} min`);
  const last = s.syncs.filter((r) => r.deviceId === d.id).sort((a, b) => b.started.localeCompare(a.started))[0];
  if (last && (last.status === "failed" || last.status === "retrying")) why.push("Last sync failed");
  return why;
}

export function mappingLive(m: Mapping, at: string): boolean {
  return m.validFrom <= at && (m.validTo === null || at < m.validTo);
}

/**
 * Which mapping applies to a code on a device at the moment of a punch: the device's own mapping first,
 * then a company-wide one. Exact code match only; the punch's own time decides, so history never moves.
 */
export function resolveMapping(s: DemoState, deviceId: string, code: string, at: string): Mapping | null {
  return (
    s.mappings.find((m) => m.deviceId === deviceId && m.code === code && mappingLive(m, at)) ??
    s.mappings.find((m) => m.deviceId === null && m.code === code && mappingLive(m, at)) ??
    null
  );
}

/* ------------------------------------------------------------------ permissions */

export class DemoRuleError extends Error {}

const NEEDS: Record<Action["type"], Capability> = {
  addDevice: "manageBiometricDevices",
  setDisabled: "manageBiometricDevices",
  setDirection: "manageBiometricDevices",
  addMapping: "mapBiometricCodes",
  endMapping: "mapBiometricCodes",
  review: "reviewBiometric",
  reset: "biometric",
};

const ACTION_TEXT: Record<Action["type"], string> = {
  addDevice: "add devices",
  setDisabled: "enable or disable devices",
  setDirection: "change a device's direction mode",
  addMapping: "map employee codes",
  endMapping: "end employee code mappings",
  review: "make review decisions",
  reset: "use this module",
};

/** Throws when the role may not perform the action. Called first in every action — not only in the interface. */
export function assertAllowed(role: Role, a: Action): void {
  if (!can(role, "biometric") || !can(role, NEEDS[a.type])) {
    throw new DemoRuleError(`${roleLabel(role)} users cannot ${ACTION_TEXT[a.type]}.`);
  }
  if (a.type === "addMapping" && a.deviceId === null && !can(role, "mapBiometricCompanyWide")) {
    throw new DemoRuleError(`Company-wide mappings are an Admin decision. ${roleLabel(role)} users can map codes on one device.`);
  }
}

/* ------------------------------------------------------------------ mapping conflicts */

export interface MappingDraft { code: string; deviceId: string | null; employeeId: string; validFrom: string }
export interface Conflict { level: "block" | "notice"; text: string }

function overlaps(a: { validFrom: string; validTo: string | null }, b: { validFrom: string; validTo: string | null }): boolean {
  return a.validFrom < (b.validTo ?? "9999") && b.validFrom < (a.validTo ?? "9999");
}

/** Explains every conflict before saving: blocking problems and notices the person should know about. */
export function mappingConflicts(s: DemoState, people: Person[], m: MappingDraft): Conflict[] {
  const out: Conflict[] = [];
  const code = m.code.trim();
  const name = (id: string) => people.find((p) => p.id === id)?.full_name ?? "a former employee";
  const dev = (id: string | null) => (id ? s.devices.find((d) => d.id === id)?.name ?? "this device" : "all devices");
  if (!code) out.push({ level: "block", text: "Enter the employee code exactly as the device shows it." });
  else if (!/^[A-Za-z0-9_-]{1,20}$/.test(code)) out.push({ level: "block", text: "Device codes are letters, digits, - or _ (up to 20)." });
  const person = people.find((p) => p.id === m.employeeId);
  if (!m.employeeId) out.push({ level: "block", text: "Choose the AttendOS employee from the list." });
  else if (!person) out.push({ level: "block", text: "That employee is not in this company." });
  else if (!person.active) out.push({ level: "block", text: `${person.full_name} is switched off; codes can only be mapped to active employees.` });
  if (!m.validFrom || Number.isNaN(Date.parse(m.validFrom))) out.push({ level: "block", text: "Choose when the mapping takes effect." });
  if (out.some((c) => c.level === "block")) return out;

  const win = { validFrom: m.validFrom, validTo: null };
  for (const x of s.mappings.filter((x) => overlaps(x, win))) {
    if (x.code === code && x.deviceId === m.deviceId) {
      out.push({ level: "block", text: `Code ${code} is already mapped to ${name(x.employeeId)} on ${dev(x.deviceId)} for this period. End that mapping first (its earlier punches stay with ${name(x.employeeId)}).` });
    }
    if (x.employeeId === m.employeeId && x.deviceId === m.deviceId && x.code !== code) {
      out.push({ level: "block", text: `${person!.full_name} already has code ${x.code} on ${dev(x.deviceId)} for this period. One person has one code per device at a time.` });
    }
  }
  const draft: Mapping = { id: "__draft__", code, deviceId: m.deviceId, employeeId: m.employeeId, validFrom: m.validFrom, validTo: null, createdBy: "", createdAt: "" };
  const moved = reassignedPunches(s, [...s.mappings, draft]);
  if (moved.length) out.push(reassignBlock(moved));
  if (m.deviceId !== null) {
    const cw = s.mappings.find((x) => x.deviceId === null && x.code === code && overlaps(x, win));
    if (cw && cw.employeeId !== m.employeeId) out.push({ level: "notice", text: `A company-wide mapping sends code ${code} to ${name(cw.employeeId)}. On ${dev(m.deviceId)} this device mapping will take precedence.` });
  } else {
    const local = s.mappings.filter((x) => x.deviceId !== null && x.code === code && x.employeeId !== m.employeeId && overlaps(x, win));
    for (const x of local) out.push({ level: "notice", text: `On ${dev(x.deviceId)}, code ${code} belongs to ${name(x.employeeId)}; that device mapping keeps precedence there.` });
    out.push({ level: "notice", text: `Company-wide: code ${code} will mean ${person!.full_name} on every device without its own mapping for this code. Codes are often reused across devices — check each device first.` });
  }
  const pending = s.reviews.filter((r) => r.status === "open" && r.kind === "unmatched" && r.raw.code === code && (m.deviceId === null || r.raw.deviceId === m.deviceId));
  const covered = pending.filter((r) => r.raw.punchAt >= m.validFrom);
  const before = pending.length - covered.length;
  if (covered.length) out.push({ level: "notice", text: `${covered.length} waiting punch${covered.length === 1 ? "" : "es"} with this code will be attributed to ${person!.full_name} at the original time.` });
  if (before) out.push({ level: "notice", text: `${before} waiting punch${before === 1 ? " is" : "es are"} earlier than the effective date and will stay unmatched.` });
  return out;
}

/* ------------------------------------------------------------------ processed punches are never silently reassigned */

/** Punches already processed: every review item except an open unmatched one (those are waiting for a mapping). */
function processed(r: ReviewItem): boolean {
  return !(r.status === "open" && r.kind === "unmatched");
}

/** Processed punches whose employee would change if the mappings were replaced by `next`. */
export function reassignedPunches(s: DemoState, next: Mapping[]): ReviewItem[] {
  const after: DemoState = { ...s, mappings: next };
  return s.reviews.filter((r) => processed(r) && resolveMapping(s, r.raw.deviceId, r.raw.code, r.raw.punchAt)?.id !== resolveMapping(after, r.raw.deviceId, r.raw.code, r.raw.punchAt)?.id);
}

function reassignBlock(items: ReviewItem[]): Conflict {
  const last = [...items].sort((a, b) => b.raw.punchAt.localeCompare(a.raw.punchAt))[0]!;
  return {
    level: "block",
    text: `This would move ${items.length} already processed punch${items.length === 1 ? "" : "es"} to a different person (latest: device time ${last.raw.deviceLocalTime}). Choose an effective time after it — processed punches keep the mapping they were processed with; correcting them is a separate HR correction.`,
  };
}

/** Problems with ending a mapping at `at`, shown before saving and enforced by the reducer. */
export function endMappingConflicts(s: DemoState, mappingId: string, at: string): Conflict[] {
  const m = s.mappings.find((x) => x.id === mappingId);
  if (!m) return [{ level: "block", text: "This mapping no longer exists." }];
  if (m.validTo) return [{ level: "block", text: "This mapping has already ended." }];
  if (!at || Number.isNaN(Date.parse(at)) || at <= m.validFrom) return [{ level: "block", text: "The end must be after the mapping started." }];
  const moved = reassignedPunches(s, s.mappings.map((x) => (x.id === mappingId ? { ...x, validTo: at } : x)));
  return moved.length ? [reassignBlock(moved)] : [];
}

/* ------------------------------------------------------------------ actions */

export type Action =
  | { type: "addDevice"; role: Role; by: string; device: Omit<Device, "id" | "createdAt" | "conn" | "lastSeen" | "lastSync" | "driftS" | "disabled"> }
  | { type: "setDisabled"; role: Role; by: string; deviceId: string; disabled: boolean }
  | { type: "setDirection"; role: Role; by: string; deviceId: string; direction: DirectionMode }
  | { type: "addMapping"; role: Role; by: string; code: string; deviceId: string | null; employeeId: string; validFrom: string; confirmCompanyWide?: boolean }
  | { type: "endMapping"; role: Role; by: string; mappingId: string; at: string; reason: string }
  | { type: "review"; role: Role; by: string; reviewId: string; decision: Decision; note: string }
  | { type: "reset"; role: Role; state: DemoState };

export function reducer(people: Person[], now: () => string = () => new Date().toISOString()) {
  return function reduce(s: DemoState, a: Action): DemoState {
    assertAllowed(a.role, a);
    const t = now();
    const id = (p: string) => `${p}-${s.seq + 1}`;
    const who = `${a.type === "reset" ? "" : a.by} · ${roleLabel(a.role)}`;
    switch (a.type) {
      case "reset":
        return a.state;
      case "addDevice": {
        if (!a.device.name.trim() || a.device.name.trim().length > 60) throw new DemoRuleError("Device names are 1–60 characters.");
        const dup = s.devices.some((d) => d.manufacturer === a.device.manufacturer && d.serial.toLowerCase() === a.device.serial.trim().toLowerCase());
        if (dup) throw new DemoRuleError("A device with this manufacturer and serial number is already registered.");
        const d: Device = { ...a.device, name: a.device.name.trim(), serial: a.device.serial.trim(), createdBy: who, id: id("dev"), createdAt: t, conn: "never", lastSeen: null, lastSync: null, driftS: null, disabled: false };
        return { ...s, seq: s.seq + 1, devices: [...s.devices, d] };
      }
      case "setDisabled":
        return { ...s, devices: s.devices.map((d) => (d.id === a.deviceId ? { ...d, disabled: a.disabled } : d)) };
      case "setDirection":
        return { ...s, devices: s.devices.map((d) => (d.id === a.deviceId ? { ...d, direction: a.direction } : d)) };
      case "addMapping": {
        const m: MappingDraft = { code: a.code.trim(), deviceId: a.deviceId, employeeId: a.employeeId, validFrom: a.validFrom };
        const blocks = mappingConflicts(s, people, m).filter((c) => c.level === "block");
        if (blocks.length) throw new DemoRuleError(blocks[0]!.text);
        if (a.deviceId === null && !a.confirmCompanyWide) throw new DemoRuleError("Confirm that this code means the same person on every device.");
        const person = people.find((p) => p.id === a.employeeId)!;
        const scope = a.deviceId ? `on ${s.devices.find((d) => d.id === a.deviceId)?.name ?? "device"}` : "company-wide";
        const mapping: Mapping = { ...m, id: id("map"), validTo: null, createdBy: who, createdAt: t };
        const next: DemoState = { ...s, seq: s.seq + 1, mappings: [...s.mappings, mapping] };
        // Waiting unmatched punches are re-checked by their own time; only those the new mapping covers are resolved.
        const reviews = s.reviews.map((r) =>
          r.status === "open" && r.kind === "unmatched" && resolveMapping(next, r.raw.deviceId, r.raw.code, r.raw.punchAt)?.id === mapping.id
            ? { ...r, status: "resolved" as const, history: [...r.history, { at: t, by: who, action: `Code ${m.code} mapped to ${person.full_name} (${scope})`, note: "Attributed at the original punch time (demonstration — nothing saved)" }] }
            : r,
        );
        return {
          ...next,
          mappingHistory: [{ at: t, by: who, code: m.code, deviceId: a.deviceId, action: `Mapped to ${person.full_name} (${scope})`, effective: m.validFrom }, ...s.mappingHistory],
          reviews,
        };
      }
      case "endMapping": {
        const m = s.mappings.find((x) => x.id === a.mappingId);
        if (!m) throw new DemoRuleError("This mapping no longer exists.");
        if (m.deviceId === null && !can(a.role, "mapBiometricCompanyWide")) throw new DemoRuleError("Company-wide mappings are an Admin decision.");
        if (a.reason.trim().length < 5) throw new DemoRuleError("Give a reason (at least 5 characters).");
        const problem = endMappingConflicts(s, a.mappingId, a.at)[0];
        if (problem) throw new DemoRuleError(problem.text);
        const person = people.find((p) => p.id === m.employeeId);
        return {
          ...s,
          mappings: s.mappings.map((x) => (x.id === a.mappingId ? { ...x, validTo: a.at } : x)),
          mappingHistory: [{ at: t, by: who, code: m.code, deviceId: m.deviceId, action: `Mapping to ${person?.full_name ?? "a former employee"} ended — punches before the end stay with them`, reason: a.reason.trim(), effective: a.at }, ...s.mappingHistory],
        };
      }
      case "review": {
        const r = s.reviews.find((x) => x.id === a.reviewId);
        if (!r) throw new DemoRuleError("This review item no longer exists.");
        if (r.status !== "open") throw new DemoRuleError("This item has already been decided.");
        if (!DECISIONS_FOR[r.kind].includes(a.decision)) throw new DemoRuleError("That decision does not apply to this kind of item.");
        const d = DECISION[a.decision];
        if (d.reasonRequired && a.note.trim().length < 5) throw new DemoRuleError(`A reason is required for “${d.label}” (at least 5 characters).`);
        return {
          ...s,
          reviews: s.reviews.map((x) =>
            x.id === a.reviewId
              ? { ...x, status: a.decision === "dismiss" ? ("dismissed" as const) : ("resolved" as const), history: [...x.history, { at: t, by: who, action: d.label, note: a.note.trim() || undefined }] }
              : x,
          ),
        };
      }
    }
  };
}

/* ------------------------------------------------------------------ seed */

const ago = (now: number, ms: number) => new Date(now - ms).toISOString();
const ahead = (now: number, ms: number) => new Date(now + ms).toISOString();
/** Local date-time as a device would print it (no zone), in India time. */
function deviceTime(iso: string): string {
  return new Date(Date.parse(iso) + 330 * MIN).toISOString().slice(0, 19).replace("T", " ");
}

/** An empty module (for showing the first-time screens). */
export function emptyState(): DemoState {
  return { agents: [], devices: [], mappings: [], mappingHistory: [], syncs: [], reviews: [], errors: [], seq: 0 };
}

/**
 * Builds the demonstration data. People and offices are passed in (real records when connected) so
 * mappings point at real, active employees chosen by exact ID — never by name. Codes are per device:
 * the same code on two devices can belong to two different people.
 */
export function seed(people: Person[], offices: Office[], now = Date.now(), by = "Sample setup · Admin"): DemoState {
  const active = people.filter((p) => p.active).sort((a, b) => (a.emp_code ?? a.full_name).localeCompare(b.emp_code ?? b.full_name));
  const off = (i: number) => offices[i % Math.max(1, offices.length)]?.id ?? null;

  const agents: Agent[] = [
    { id: "agt-1", name: "Head office server", host: "HO-SRV-01 (Windows Server 2022)", version: "0.0.0-demo", status: "online", lastHeartbeat: ago(now, 2 * MIN), queueDepth: 0, keyPrefix: "aos_7Kq2" },
    { id: "agt-2", name: "Plant reception PC", host: "PLANT-RCP-02 (Windows 11)", version: "0.0.0-demo", status: "offline", lastHeartbeat: ago(now, 3 * HOUR), queueDepth: 148, keyPrefix: "aos_Pm9x" },
  ];

  const devices: Device[] = [
    { id: "dev-1", name: "Main entrance", manufacturer: "zkteco", model: "SpeedFace-V5L", serial: "CKUH201960123", firmware: "ZAM180-NF-VER 6.4.1", officeId: off(0), method: "local_push", agentId: "agt-1", direction: "first_last", disabled: false, conn: "online", lastSeen: ago(now, MIN), lastSync: ago(now, 4 * MIN), driftS: 12, connection: { deviceIp: "192.168.10.21", receiverPort: "8081", pushAuth: "unauthenticated_lan" }, createdAt: ago(now, 40 * DAY), createdBy: by },
    { id: "dev-2", name: "Staff gate", manufacturer: "essl", model: "AiFace Mars", serial: "AF8K2311000457", firmware: "Ver 8.0.4.3-20231107", officeId: off(0), method: "sdk_pull", agentId: "agt-1", direction: "device", disabled: false, conn: "online", lastSeen: ago(now, 2 * MIN), lastSync: ago(now, 6 * MIN), driftS: -428, connection: { deviceIp: "192.168.10.22", port: "4370" }, createdAt: ago(now, 31 * DAY), createdBy: by },
    { id: "dev-3", name: "Plant shop floor", manufacturer: "essl", model: "X990", serial: "X990A22070883", firmware: "Ver 6.60 Apr 28 2022", officeId: off(1), method: "local_push", agentId: "agt-2", direction: "first_last", disabled: false, conn: "offline", lastSeen: ago(now, 3 * HOUR), lastSync: ago(now, 3 * HOUR + 5 * MIN), driftS: 30, connection: { deviceIp: "10.20.0.15", receiverPort: "8081", pushAuth: "unauthenticated_lan" }, createdAt: ago(now, 25 * DAY), createdBy: by },
    { id: "dev-4", name: "Warehouse door", manufacturer: "matrix", model: "COSEC ARGO FACE", serial: "ARGO-FA-0091337", firmware: "V2R5", officeId: off(1), method: "local_push", agentId: "agt-2", direction: "device", disabled: false, conn: "error", lastSeen: ago(now, 26 * MIN), lastSync: ago(now, 26 * HOUR), driftS: null, connection: { deviceIp: "10.20.0.31", receiverPort: "8082", pushAuth: "authenticated" }, createdAt: ago(now, 12 * DAY), createdBy: by },
    { id: "dev-5", name: "Old canteen terminal", manufacturer: "zkteco", model: "K40", serial: "OIN7030057012", firmware: "Ver 6.60 Dec 3 2014", officeId: off(0), method: "sdk_pull", agentId: "agt-1", direction: "first_last", disabled: true, conn: "offline", lastSeen: ago(now, 9 * DAY), lastSync: ago(now, 9 * DAY), driftS: 1510, connection: { deviceIp: "192.168.10.40", port: "4370" }, createdAt: ago(now, 60 * DAY), createdBy: by },
  ];

  const mappings: Mapping[] = [];
  const mappingHistory: MappingEvent[] = [];
  let n = 0;
  const add = (code: string, deviceId: string | null, p: Person | undefined, fromAgo: number, toAgo: number | null = null) => {
    if (!p) return;
    n += 1;
    const m: Mapping = { id: `map-${n}`, code, deviceId, employeeId: p.id, validFrom: ago(now, fromAgo), validTo: toAgo === null ? null : ago(now, toAgo), createdBy: by, createdAt: ago(now, fromAgo) };
    mappings.push(m);
    const scope = deviceId ? `on ${devices.find((d) => d.id === deviceId)!.name}` : "company-wide";
    mappingHistory.push({ at: m.createdAt, by, code, deviceId, action: `Mapped to ${p.full_name} (${scope})`, effective: m.validFrom });
    if (m.validTo) mappingHistory.push({ at: m.validTo, by, code, deviceId, action: `Mapping to ${p.full_name} ended — punches before the end stay with them`, reason: "Left the company; device user ID re-used", effective: m.validTo });
  };
  // Head office devices: each device has its own user list.
  for (let i = 0; i < 6; i++) add(String(101 + i), "dev-1", active[i], (40 - i) * DAY);
  for (let i = 0; i < 4; i++) add(String(201 + i), "dev-2", active[i], 31 * DAY);
  // Plant device re-uses codes 101–103 for different people — codes are not unique across devices.
  for (let i = 0; i < 3; i++) add(String(101 + i), "dev-3", active[6 + i], 25 * DAY);
  add("7001", "dev-4", active[4], 12 * DAY);
  add("7002", "dev-4", active[5], 12 * DAY);
  // Code 107 on Main entrance: used by a person who left, then re-used for someone else.
  const leaver = people.find((p) => !p.active);
  if (leaver) add("107", "dev-1", leaver, 200 * DAY, 45 * DAY);
  add("107", "dev-1", active[6], 30 * DAY);
  // One company-wide mapping: a contractor card accepted on every device (explicit Admin decision).
  add("C5521", null, active[9] ?? active[0], 20 * DAY);
  mappingHistory.sort((a, b) => b.at.localeCompare(a.at));

  const run = (i: number, deviceId: string, agentId: string, startedAgo: number, rest: Partial<SyncRun>): SyncRun => ({
    id: `sync-${i}`, deviceId, agentId, started: ago(now, startedAgo), completed: ago(now, startedAgo - 20_000), status: "ok",
    received: 0, stored: 0, confirmedDup: 0, possibleDup: 0, unmatched: 0, rejected: 0, error: null, retry: null, ...rest,
  });
  const syncs: SyncRun[] = [
    run(1, "dev-1", "agt-1", 4 * MIN, { received: 37, stored: 35, confirmedDup: 1, possibleDup: 1, unmatched: 1 }),
    run(2, "dev-2", "agt-1", 6 * MIN, { received: 22, stored: 22 }),
    run(3, "dev-1", "agt-1", 64 * MIN, { received: 58, stored: 52, confirmedDup: 6 }),
    run(4, "dev-2", "agt-1", 66 * MIN, { received: 19, stored: 18, rejected: 1, error: "1 record with a time 3 hours in the future" }),
    run(5, "dev-4", "agt-2", 26 * MIN, { status: "retrying", completed: null, error: "Device refused the connection (authentication failed)", retry: { attempt: 3, nextAt: ahead(now, 4 * MIN) } }),
    run(6, "dev-3", "agt-2", 3 * HOUR + 5 * MIN, { status: "partial", received: 140, stored: 131, unmatched: 2, rejected: 7, error: "Upload interrupted: internet connection lost; 148 punches waiting in the agent queue" }),
    run(7, "dev-1", "agt-1", 26 * HOUR, { received: 412, stored: 409, confirmedDup: 3 }),
    run(8, "dev-4", "agt-2", 26 * HOUR + 10 * MIN, { received: 64, stored: 63, possibleDup: 1 }),
    run(9, "dev-5", "agt-1", 9 * DAY, { status: "failed", completed: ago(now, 9 * DAY - 30_000), error: "Device not reachable at 192.168.10.40:4370" }),
  ];

  const raw = (deviceId: string, code: string, punchAgo: number, receivedAgo: number, future = false): RawPunch => {
    const punchAt = future ? ahead(now, punchAgo) : ago(now, punchAgo);
    return Object.freeze({ deviceId, deviceSerial: devices.find((d) => d.id === deviceId)!.serial, code, deviceLocalTime: deviceTime(punchAt), deviceTimezone: "Asia/Kolkata", punchAt, receivedAt: ago(now, receivedAgo) });
  };
  const item = (id: string, kind: ReviewKind, r: RawPunch, reason: string, by2: string, action: string, status: ReviewItem["status"] = "open", extra: AuditEntry[] = []): ReviewItem => ({
    id, kind, raw: r, reason, status, history: [{ at: r.receivedAt, by: by2, action }, ...extra],
  });
  const reviews: ReviewItem[] = [
    item("rev-1", "unmatched", raw("dev-1", "117", 5 * MIN, 4 * MIN), "No AttendOS employee is mapped to device code 117 on Main entrance.", "Gateway (demonstration)", "Received and stored; no mapping for this code on this device"),
    item("rev-2", "unmatched", raw("dev-3", "205", 3 * HOUR + 40 * MIN, 3 * HOUR + 5 * MIN), "No AttendOS employee is mapped to device code 205 on Plant shop floor.", "Gateway (demonstration)", "Received and stored; no mapping for this code on this device"),
    item("rev-3", "ambiguous", raw("dev-1", "103", 50 * MIN, 48 * MIN), "Checked in through the app at 09:31; this machine punch is more than 5 minutes later and cannot be placed as in or out.", "Projection (demonstration)", "Flagged: does not reconcile with the app check-in"),
    item("rev-4", "possible_duplicate", raw("dev-1", "105", 5 * MIN, 4 * MIN), "Second punch 38 seconds after the first on the same device (double-press window 60 s).", "Gateway (demonstration)", "Stored; marked as a possible duplicate"),
    item("rev-5", "after_correction", raw("dev-3", "102", 27 * HOUR, 3 * HOUR + 5 * MIN), "Yesterday's check-in was corrected by HR to 09:00; this earlier machine punch arrived after the correction.", "Projection (demonstration)", "Slot locked by HR correction; punch kept as after-correction"),
    item("rev-6", "timestamp", raw("dev-2", "202", 3 * HOUR, 66 * MIN, true), "Punch time is 3 hours after it was received — not explained by the device's 7-minute clock drift.", "Gateway (demonstration)", "Flagged: future time; not counted"),
    item("rev-7", "timestamp", raw("dev-2", "204", 6 * MIN, 6 * MIN), "Device clock is 7 min 8 s behind the agent (over the 5-minute limit). Time kept as recorded, not adjusted.", "Gateway (demonstration)", "Flagged: clock drift above 5 minutes"),
    item("rev-8", "possible_duplicate", raw("dev-4", "7001", 26 * HOUR, 26 * HOUR), "Two punches 12 seconds apart.", "Gateway (demonstration)", "Stored; marked as a possible duplicate", "resolved", [{ at: ago(now, 25 * HOUR), by: "Sample HR · HR", action: "Confirm duplicate", note: "Double press at the door" }]),
  ];

  const errors: DeviceError[] = [
    { id: "err-1", deviceId: "dev-4", at: ago(now, 26 * MIN), kind: "Authentication failed", detail: "The device rejected the agent's credentials. Check the device communication settings on the agent PC.", resolved: false },
    { id: "err-2", deviceId: "dev-3", at: ago(now, 3 * HOUR), kind: "Agent offline", detail: "Plant reception PC stopped sending heartbeats; 148 punches are waiting in its queue.", resolved: false },
    { id: "err-3", deviceId: "dev-2", at: ago(now, 66 * MIN), kind: "Future time", detail: "1 record rejected: time 3 hours after receipt.", resolved: false },
    { id: "err-4", deviceId: "dev-2", at: ago(now, 6 * MIN), kind: "Clock drift", detail: "Device clock 428 s behind the agent.", resolved: false },
    { id: "err-5", deviceId: "dev-5", at: ago(now, 9 * DAY), kind: "Unreachable", detail: "No response at 192.168.10.40:4370.", resolved: false },
    { id: "err-6", deviceId: "dev-1", at: ago(now, 5 * DAY), kind: "Rejected request", detail: "Push from 192.168.10.99 claimed serial CKUH201960123; the IP does not match. Request rejected and logged.", resolved: true },
  ];

  return { agents, devices, mappings, mappingHistory, syncs, reviews, errors, seq: 100 };
}

/** Who a review item's punch belongs to, by the mapping in force at the punch time. */
export function reviewEmployee(s: DemoState, r: ReviewItem): Mapping | null {
  return resolveMapping(s, r.raw.deviceId, r.raw.code, r.raw.punchAt);
}

/** Sample people and offices used only in preview mode (no company database). */
export const PREVIEW_PEOPLE: Person[] = [
  ["Aarav Sharma", "E0001"], ["Diya Patel", "E0002"], ["Kabir Iyer", "E0003"], ["Meera Nair", "E0004"], ["Rohan Gupta", "E0005"],
  ["Sara Khan", "E0006"], ["Vikram Rao", "E0007"], ["Ananya Das", "E0008"], ["Ishaan Joshi", "E0009"], ["Nisha Menon", "E0010"],
].map(([full_name, emp_code], i) => ({ id: `preview-${i + 1}`, full_name: `${full_name} (sample)`, emp_code, active: true }))
  .concat([{ id: "preview-11", full_name: "Former Employee (sample)", emp_code: "E0011", active: false }]);
export const PREVIEW_OFFICES: Office[] = [{ id: "preview-ho", name: "Head Office (sample)" }, { id: "preview-plant", name: "Plant (sample)" }];

/** Converts a "YYYY-MM-DDTHH:mm" wall-clock value in a time zone to an ISO instant. */
export function zonedToIso(local: string, tz: string): string {
  const guess = Date.parse(`${local}:00Z`);
  if (Number.isNaN(guess)) return "";
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }).formatToParts(new Date(guess)).map((p) => [p.type, p.value]));
  const shown = Date.parse(`${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}:00Z`);
  return new Date(guess - (shown - guess)).toISOString();
}

/** The reverse: an ISO instant as a "YYYY-MM-DDTHH:mm" wall-clock value in a time zone. */
export function isoToZoned(iso: string, tz: string): string {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }).formatToParts(new Date(iso)).map((x) => [x.type, x.value]));
  return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}`;
}
