/**
 * Biometric Devices — DEMONSTRATION DATA (Phase B2).
 *
 * Everything in this file lives only in the browser tab. Nothing is read from or written to the
 * database, no device or Sync Agent is contacted, and a reload resets it. The shapes follow the
 * B1 design (docs/biometric/BIOMETRIC_DATABASE_SCHEMA.md) so the screens can later switch to real
 * data without being redesigned. People and offices are the company's real records when the app is
 * connected (read-only); only devices, agents, mappings, syncs and review items are invented.
 */

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
  deviceId: string | null; // null = company-wide
  employeeId: string;
  validFrom: string;
  validTo: string | null;
  disabled: boolean;
}

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

export interface AuditEntry { at: string; by: string; action: string; note?: string }

export interface ReviewItem {
  id: string;
  kind: ReviewKind;
  deviceId: string;
  code: string;
  employeeId: string | null;
  deviceLocalTime: string;
  receivedAt: string;
  detail: string;
  status: "open" | "resolved" | "dismissed";
  history: AuditEntry[];
}

export interface DeviceError { id: string; deviceId: string; at: string; kind: string; detail: string; resolved: boolean }

export interface DemoState {
  agents: Agent[];
  devices: Device[];
  mappings: Mapping[];
  mappingHistory: (AuditEntry & { code: string })[];
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

/** Which mapping applies to a code on a device at a time: device-specific first, then company-wide. Exact code match only. */
export function resolveMapping(s: DemoState, deviceId: string, code: string, at: string): Mapping | null {
  const live = (m: Mapping) => !m.disabled && m.code === code && m.validFrom <= at && (m.validTo === null || at < m.validTo);
  return s.mappings.find((m) => m.deviceId === deviceId && live(m)) ?? s.mappings.find((m) => m.deviceId === null && live(m)) ?? null;
}

/* ------------------------------------------------------------------ actions */

export type Action =
  | { type: "addDevice"; device: Omit<Device, "id" | "createdAt" | "conn" | "lastSeen" | "lastSync" | "driftS" | "disabled">; by: string }
  | { type: "setDisabled"; deviceId: string; disabled: boolean; by: string }
  | { type: "setDirection"; deviceId: string; direction: DirectionMode; by: string }
  | { type: "addMapping"; code: string; deviceId: string | null; employeeId: string; by: string; reviewId?: string }
  | { type: "endMapping"; mappingId: string; by: string }
  | { type: "review"; reviewId: string; action: "accept" | "dismiss" | "confirm_duplicate" | "not_duplicate" | "keep_correction"; note: string; by: string }
  | { type: "reset"; state: DemoState };

export class DemoRuleError extends Error {}

function overlaps(a: Mapping, b: { validFrom: string; validTo: string | null }): boolean {
  return a.validFrom < (b.validTo ?? "9999") && b.validFrom < (a.validTo ?? "9999");
}

/** Mapping rules from the B1 design. Throws DemoRuleError with a plain message when a rule is broken. */
export function checkMapping(s: DemoState, people: Person[], m: { code: string; deviceId: string | null; employeeId: string; validFrom: string }): void {
  const code = m.code.trim();
  if (!code) throw new DemoRuleError("Enter the employee code exactly as the device shows it.");
  if (!/^[A-Za-z0-9_-]{1,20}$/.test(code)) throw new DemoRuleError("Device codes are letters, digits, - or _ (up to 20).");
  const person = people.find((p) => p.id === m.employeeId);
  if (!person) throw new DemoRuleError("Choose the AttendOS employee from the list.");
  if (!person.active) throw new DemoRuleError(`${person.full_name} is switched off; codes can only be mapped to active employees.`);
  const live = s.mappings.filter((x) => !x.disabled && overlaps(x, { validFrom: m.validFrom, validTo: null }));
  if (live.some((x) => x.code === code && x.deviceId === m.deviceId)) {
    throw new DemoRuleError(m.deviceId ? `Code ${code} is already mapped on this device. End that mapping first.` : `Code ${code} already has a company-wide mapping. End it first.`);
  }
  if (m.deviceId === null && live.some((x) => x.deviceId === null && x.employeeId === m.employeeId)) {
    throw new DemoRuleError(`${person.full_name} already has a company-wide code. End it first.`);
  }
  if (m.deviceId !== null && live.some((x) => x.deviceId === m.deviceId && x.employeeId === m.employeeId)) {
    throw new DemoRuleError(`${person.full_name} already has a code on this device.`);
  }
}

export function reducer(people: Person[]) {
  return function reduce(s: DemoState, a: Action): DemoState {
    const now = new Date().toISOString();
    const id = (p: string) => `${p}-${s.seq + 1}`;
    switch (a.type) {
      case "reset":
        return a.state;
      case "addDevice": {
        const dup = s.devices.some((d) => d.manufacturer === a.device.manufacturer && d.serial.toLowerCase() === a.device.serial.trim().toLowerCase());
        if (dup) throw new DemoRuleError("A device with this manufacturer and serial number is already registered.");
        const d: Device = { ...a.device, serial: a.device.serial.trim(), id: id("dev"), createdAt: now, conn: "never", lastSeen: null, lastSync: null, driftS: null, disabled: false };
        return { ...s, seq: s.seq + 1, devices: [...s.devices, d] };
      }
      case "setDisabled":
        return { ...s, devices: s.devices.map((d) => (d.id === a.deviceId ? { ...d, disabled: a.disabled } : d)) };
      case "setDirection":
        return { ...s, devices: s.devices.map((d) => (d.id === a.deviceId ? { ...d, direction: a.direction } : d)) };
      case "addMapping": {
        const m = { code: a.code.trim(), deviceId: a.deviceId, employeeId: a.employeeId, validFrom: now };
        checkMapping(s, people, m);
        const person = people.find((p) => p.id === a.employeeId)!;
        const scope = a.deviceId ? `on ${s.devices.find((d) => d.id === a.deviceId)?.name ?? "device"}` : "company-wide";
        const mapping: Mapping = { ...m, id: id("map"), validTo: null, disabled: false };
        // Unmatched punches with this exact code (on this device, or any device for a company-wide mapping) are re-checked.
        const reviews = s.reviews.map((r) =>
          r.status === "open" && r.kind === "unmatched" && r.code === m.code && (a.deviceId === null || r.deviceId === a.deviceId)
            ? { ...r, status: "resolved" as const, employeeId: a.employeeId, history: [...r.history, { at: now, by: a.by, action: `Mapped ${m.code} → ${person.full_name} (${scope})`, note: "Punch re-processed with its original time (demonstration)" }] }
            : r,
        );
        return {
          ...s,
          seq: s.seq + 1,
          mappings: [...s.mappings, mapping],
          mappingHistory: [{ at: now, by: a.by, code: m.code, action: `Mapped to ${person.full_name} (${scope})` }, ...s.mappingHistory],
          reviews,
        };
      }
      case "endMapping": {
        const m = s.mappings.find((x) => x.id === a.mappingId);
        if (!m || m.validTo) return s;
        const person = people.find((p) => p.id === m.employeeId);
        return {
          ...s,
          mappings: s.mappings.map((x) => (x.id === a.mappingId ? { ...x, validTo: now } : x)),
          mappingHistory: [{ at: now, by: a.by, code: m.code, action: `Mapping to ${person?.full_name ?? "a former employee"} ended (earlier punches stay with them)` }, ...s.mappingHistory],
        };
      }
      case "review": {
        const r = s.reviews.find((x) => x.id === a.reviewId);
        if (!r || r.status !== "open") return s;
        if (a.action === "dismiss" && a.note.trim().length < 5) throw new DemoRuleError("Give a reason (at least 5 characters) to dismiss a punch.");
        const label = { accept: "Accepted as recorded", dismiss: "Dismissed", confirm_duplicate: "Confirmed as duplicate", not_duplicate: "Kept as a separate punch", keep_correction: "HR correction kept; punch stays as extra" }[a.action];
        return {
          ...s,
          reviews: s.reviews.map((x) =>
            x.id === a.reviewId ? { ...x, status: a.action === "dismiss" ? ("dismissed" as const) : ("resolved" as const), history: [...x.history, { at: now, by: a.by, action: label, note: a.note.trim() || undefined }] } : x,
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
  const d = new Date(Date.parse(iso) + 330 * MIN);
  return d.toISOString().slice(0, 19).replace("T", " ");
}

/**
 * Builds the demonstration data. People and offices are passed in (real records when connected) so
 * mappings point at real, active employees chosen by exact ID — never by name.
 */
export function seed(people: Person[], offices: Office[], now = Date.now(), by = "Demonstration data"): DemoState {
  const active = people.filter((p) => p.active).sort((a, b) => (a.emp_code ?? a.full_name).localeCompare(b.emp_code ?? b.full_name));
  const off = (i: number) => offices[i % Math.max(1, offices.length)]?.id ?? null;

  const agents: Agent[] = [
    { id: "agt-1", name: "Head office server", host: "HO-SRV-01 (Windows Server 2022)", version: "0.0.0-demo", status: "online", lastHeartbeat: ago(now, 2 * MIN), queueDepth: 0, keyPrefix: "aos_7Kq2" },
    { id: "agt-2", name: "Plant reception PC", host: "PLANT-RCP-02 (Windows 11)", version: "0.0.0-demo", status: "offline", lastHeartbeat: ago(now, 3 * HOUR), queueDepth: 148, keyPrefix: "aos_Pm9x" },
  ];

  const devices: Device[] = [
    { id: "dev-1", name: "Main entrance", manufacturer: "zkteco", model: "SpeedFace-V5L", serial: "CKUH201960123", firmware: "ZAM180-NF-VER 6.4.1", officeId: off(0), method: "local_push", agentId: "agt-1", direction: "first_last", disabled: false, conn: "online", lastSeen: ago(now, 1 * MIN), lastSync: ago(now, 4 * MIN), driftS: 12, connection: { deviceIp: "192.168.10.21", receiverPort: "8081", pushAuth: "unauthenticated_lan" }, createdAt: ago(now, 40 * 24 * HOUR), createdBy: by },
    { id: "dev-2", name: "Staff gate", manufacturer: "essl", model: "AiFace Mars", serial: "AF8K2311000457", firmware: "Ver 8.0.4.3-20231107", officeId: off(0), method: "sdk_pull", agentId: "agt-1", direction: "device", disabled: false, conn: "online", lastSeen: ago(now, 2 * MIN), lastSync: ago(now, 6 * MIN), driftS: -428, connection: { deviceIp: "192.168.10.22", port: "4370" }, createdAt: ago(now, 31 * 24 * HOUR), createdBy: by },
    { id: "dev-3", name: "Plant shop floor", manufacturer: "essl", model: "X990", serial: "X990A22070883", firmware: "Ver 6.60 Apr 28 2022", officeId: off(1), method: "local_push", agentId: "agt-2", direction: "first_last", disabled: false, conn: "offline", lastSeen: ago(now, 3 * HOUR), lastSync: ago(now, 3 * HOUR + 5 * MIN), driftS: 30, connection: { deviceIp: "10.20.0.15", receiverPort: "8081", pushAuth: "unauthenticated_lan" }, createdAt: ago(now, 25 * 24 * HOUR), createdBy: by },
    { id: "dev-4", name: "Warehouse door", manufacturer: "matrix", model: "COSEC ARGO FACE", serial: "ARGO-FA-0091337", firmware: "V2R5", officeId: off(1), method: "local_push", agentId: "agt-2", direction: "device", disabled: false, conn: "error", lastSeen: ago(now, 26 * MIN), lastSync: ago(now, 26 * HOUR), driftS: null, connection: { deviceIp: "10.20.0.31", receiverPort: "8082", pushAuth: "authenticated" }, createdAt: ago(now, 12 * 24 * HOUR), createdBy: by },
    { id: "dev-5", name: "Old canteen terminal", manufacturer: "zkteco", model: "K40", serial: "OIN7030057012", firmware: "Ver 6.60 Dec 3 2014", officeId: off(0), method: "sdk_pull", agentId: "agt-1", direction: "first_last", disabled: true, conn: "offline", lastSeen: ago(now, 9 * 24 * HOUR), lastSync: ago(now, 9 * 24 * HOUR), driftS: 1510, connection: { deviceIp: "192.168.10.40", port: "4370" }, createdAt: ago(now, 60 * 24 * HOUR), createdBy: by },
  ];

  // Mappings to real people, by exact ID, in order of employee ID. Codes are the device user IDs.
  const mappings: Mapping[] = [];
  const mappingHistory: DemoState["mappingHistory"] = [];
  active.slice(0, 8).forEach((p, i) => {
    const code = String(101 + i);
    mappings.push({ id: `map-${i + 1}`, code, deviceId: null, employeeId: p.id, validFrom: ago(now, (30 - i) * 24 * HOUR), validTo: null, disabled: false });
    mappingHistory.push({ at: ago(now, (30 - i) * 24 * HOUR), by, code, action: `Mapped to ${p.full_name} (company-wide)` });
  });
  if (active[8]) {
    // Device-specific override: on the plant device this person enrolled under a different user ID.
    mappings.push({ id: "map-9", code: "5009", deviceId: "dev-3", employeeId: active[8].id, validFrom: ago(now, 20 * 24 * HOUR), validTo: null, disabled: false });
    mappingHistory.push({ at: ago(now, 20 * 24 * HOUR), by, code: "5009", action: `Mapped to ${active[8].full_name} (on Plant shop floor)` });
  }
  const leaver = people.find((p) => !p.active);
  if (leaver) {
    mappings.push({ id: "map-10", code: "099", deviceId: null, employeeId: leaver.id, validFrom: ago(now, 200 * 24 * HOUR), validTo: ago(now, 45 * 24 * HOUR), disabled: false });
    mappingHistory.push({ at: ago(now, 45 * 24 * HOUR), by, code: "099", action: `Mapping to ${leaver.full_name} ended (earlier punches stay with them)` });
  }
  mappingHistory.sort((a, b) => b.at.localeCompare(a.at));

  const run = (i: number, deviceId: string, agentId: string, startedAgo: number, rest: Partial<SyncRun>): SyncRun => ({
    id: `sync-${i}`, deviceId, agentId, started: ago(now, startedAgo), completed: ago(now, startedAgo - 20_000), status: "ok",
    received: 0, stored: 0, confirmedDup: 0, possibleDup: 0, unmatched: 0, rejected: 0, error: null, retry: null, ...rest,
  });
  const syncs: SyncRun[] = [
    run(1, "dev-1", "agt-1", 4 * MIN, { received: 37, stored: 35, confirmedDup: 1, possibleDup: 1, unmatched: 1 }),
    run(2, "dev-2", "agt-1", 6 * MIN, { received: 22, stored: 22, possibleDup: 0, unmatched: 0 }),
    run(3, "dev-1", "agt-1", 64 * MIN, { received: 58, stored: 52, confirmedDup: 6 }),
    run(4, "dev-2", "agt-1", 66 * MIN, { received: 19, stored: 18, rejected: 1, error: "1 record with a time 3 hours in the future" }),
    run(5, "dev-4", "agt-2", 26 * MIN, { status: "retrying", completed: null, error: "Device refused the connection (authentication failed)", retry: { attempt: 3, nextAt: ahead(now, 4 * MIN) } }),
    run(6, "dev-3", "agt-2", 3 * HOUR + 5 * MIN, { status: "partial", received: 140, stored: 131, unmatched: 2, rejected: 7, error: "Upload interrupted: internet connection lost; 148 punches waiting in the agent queue" }),
    run(7, "dev-1", "agt-1", 26 * HOUR, { received: 412, stored: 409, confirmedDup: 3 }),
    run(8, "dev-4", "agt-2", 26 * HOUR + 10 * MIN, { received: 64, stored: 63, possibleDup: 1 }),
    run(9, "dev-5", "agt-1", 9 * 24 * HOUR, { status: "failed", completed: ago(now, 9 * 24 * HOUR - 30_000), error: "Device not reachable at 192.168.10.40:4370" }),
  ];

  const at = (ms: number) => ago(now, ms);
  const person = (i: number) => active[i] ?? null;
  const reviews: ReviewItem[] = [
    { id: "rev-1", kind: "unmatched", deviceId: "dev-1", code: "117", employeeId: null, deviceLocalTime: deviceTime(at(5 * MIN)), receivedAt: at(4 * MIN), detail: "No AttendOS employee is mapped to device code 117.", status: "open", history: [{ at: at(4 * MIN), by: "Gateway (demonstration)", action: "Received and stored; no mapping for this code" }] },
    { id: "rev-2", kind: "unmatched", deviceId: "dev-3", code: "205", employeeId: null, deviceLocalTime: deviceTime(at(3 * HOUR + 40 * MIN)), receivedAt: at(3 * HOUR + 5 * MIN), detail: "No AttendOS employee is mapped to device code 205 (2 punches).", status: "open", history: [{ at: at(3 * HOUR + 5 * MIN), by: "Gateway (demonstration)", action: "Received and stored; no mapping for this code" }] },
    { id: "rev-3", kind: "ambiguous", deviceId: "dev-1", code: "103", employeeId: person(2)?.id ?? null, deviceLocalTime: deviceTime(at(50 * MIN)), receivedAt: at(48 * MIN), detail: "Checked in through the app at 09:31; the machine punch at 09:48 is more than 5 minutes later and cannot be placed as in or out.", status: "open", history: [{ at: at(48 * MIN), by: "Projection (demonstration)", action: "Flagged: does not reconcile with the app check-in" }] },
    { id: "rev-4", kind: "possible_duplicate", deviceId: "dev-1", code: "105", employeeId: person(4)?.id ?? null, deviceLocalTime: deviceTime(at(5 * MIN)), receivedAt: at(4 * MIN), detail: "Second punch 38 seconds after the first on the same device.", status: "open", history: [{ at: at(4 * MIN), by: "Gateway (demonstration)", action: "Stored; marked as a possible duplicate (double-press window 60 s)" }] },
    { id: "rev-5", kind: "after_correction", deviceId: "dev-3", code: "107", employeeId: person(6)?.id ?? null, deviceLocalTime: deviceTime(at(27 * HOUR)), receivedAt: at(3 * HOUR + 5 * MIN), detail: "Yesterday's check-in was corrected by HR to 09:00; this earlier machine punch (08:52) arrived after the correction.", status: "open", history: [{ at: at(3 * HOUR + 5 * MIN), by: "Projection (demonstration)", action: "Slot locked by HR correction; punch kept as after-correction" }] },
    { id: "rev-6", kind: "timestamp", deviceId: "dev-2", code: "102", employeeId: person(1)?.id ?? null, deviceLocalTime: deviceTime(ahead(now, 3 * HOUR)), receivedAt: at(66 * MIN), detail: "Punch time is 3 hours after it was received (device clock is about 7 minutes slow, so this is not drift).", status: "open", history: [{ at: at(66 * MIN), by: "Gateway (demonstration)", action: "Flagged: future time; not counted" }] },
    { id: "rev-7", kind: "timestamp", deviceId: "dev-2", code: "104", employeeId: person(3)?.id ?? null, deviceLocalTime: deviceTime(at(6 * MIN)), receivedAt: at(6 * MIN), detail: "Device clock is 7 min 8 s behind the agent (over the 5-minute limit). Time kept as recorded; not adjusted.", status: "open", history: [{ at: at(6 * MIN), by: "Gateway (demonstration)", action: "Flagged: clock drift above 5 minutes" }] },
    { id: "rev-8", kind: "possible_duplicate", deviceId: "dev-4", code: "106", employeeId: person(5)?.id ?? null, deviceLocalTime: deviceTime(at(26 * HOUR)), receivedAt: at(26 * HOUR), detail: "Two punches 12 seconds apart.", status: "resolved", history: [{ at: at(26 * HOUR), by: "Gateway (demonstration)", action: "Stored; marked as a possible duplicate" }, { at: at(25 * HOUR), by: "HR (demonstration)", action: "Confirmed as duplicate", note: "Double press at the door" }] },
  ];

  const errors: DeviceError[] = [
    { id: "err-1", deviceId: "dev-4", at: at(26 * MIN), kind: "Authentication failed", detail: "The device rejected the agent's credentials. Check the device communication settings on the agent PC.", resolved: false },
    { id: "err-2", deviceId: "dev-3", at: at(3 * HOUR), kind: "Agent offline", detail: "Plant reception PC stopped sending heartbeats; 148 punches are waiting in its queue.", resolved: false },
    { id: "err-3", deviceId: "dev-2", at: at(66 * MIN), kind: "Future time", detail: "1 record rejected: time 3 hours after receipt.", resolved: false },
    { id: "err-4", deviceId: "dev-2", at: at(6 * MIN), kind: "Clock drift", detail: "Device clock 428 s behind the agent.", resolved: false },
    { id: "err-5", deviceId: "dev-5", at: at(9 * 24 * HOUR), kind: "Unreachable", detail: "No response at 192.168.10.40:4370.", resolved: false },
    { id: "err-6", deviceId: "dev-1", at: at(5 * 24 * HOUR), kind: "Rejected request", detail: "Push from 192.168.10.99 claimed serial CKUH201960123; the IP does not match. Request rejected and logged.", resolved: true },
  ];

  return { agents, devices, mappings, mappingHistory, syncs, reviews, errors, seq: 100 };
}

/** Sample people and offices used only in preview mode (no company database). */
export const PREVIEW_PEOPLE: Person[] = [
  ["Aarav Sharma", "E0001"], ["Diya Patel", "E0002"], ["Kabir Iyer", "E0003"], ["Meera Nair", "E0004"], ["Rohan Gupta", "E0005"],
  ["Sara Khan", "E0006"], ["Vikram Rao", "E0007"], ["Ananya Das", "E0008"], ["Ishaan Joshi", "E0009"], ["Nisha Menon", "E0010"],
].map(([full_name, emp_code], i) => ({ id: `preview-${i + 1}`, full_name: `${full_name} (sample)`, emp_code, active: true }))
  .concat([{ id: "preview-11", full_name: "Former Employee (sample)", emp_code: "E0011", active: false }]);
export const PREVIEW_OFFICES: Office[] = [{ id: "preview-ho", name: "Head Office (sample)" }, { id: "preview-plant", name: "Plant (sample)" }];
