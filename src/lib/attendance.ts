/**
 * Attendance logic used by the browser. The database decides whether a punch counts
 * (punch()) and works out late / early / overtime (day_for()); this file reads the
 * phone's location, talks to the database and works out what to show.
 */

export type WorkMode = "office" | "remote" | "off";
export type PunchKind = "in" | "out" | "break_start" | "break_end";
export type SessionState = "off" | "working" | "on_break";

export interface AttendanceEvent {
  kind: PunchKind;
  at: string;
  work_mode: "office" | "remote";
  location: string | null;
  distance_m: number | null;
  accuracy_m?: number | null;
  verified: boolean;
  source?: "web" | "correction";
}

export interface ShiftInfo {
  name: string;
  start: string;
  end: string;
  break_minutes: number;
  grace_minutes: number;
  overnight: boolean;
}

export type DayStatus =
  | "present"
  | "late"
  | "working"
  | "on_break"
  | "missing_checkout"
  | "absent"
  | "not_started"
  | "off"
  | "holiday"
  | "scheduled"
  | "on_leave";

export interface Today {
  ok: true;
  server_now: string;
  timezone: string;
  today: string;
  work_date: string;
  max_accuracy_m: number;
  remote_location_required: boolean;
  employee: { id: string; full_name: string; role: string };
  plan: {
    work_mode: WorkMode;
    source: "day" | "holiday" | "exception" | "pattern" | "default";
    note: string | null;
    location: { id: string; name: string; radius_m: number } | null;
  };
  shift: ShiftInfo | null;
  state: SessionState;
  checked_in: boolean;
  open_since: string | null;
  summary: { worked_min: number; break_min: number; late_min: number; early_min: number; overtime_min: number; status: DayStatus; pending_correction: boolean };
  events: AttendanceEvent[];
  /** Approved leave on this work date (from Phase 4). */
  leave?: { id: number; type: string; half_day: "first" | "second" | null; start: string; end: string } | null;
}

/** One row of attendance_history(): a worked-out day. */
export interface DayRow {
  employee_id: string;
  work_date: string;
  work_mode: WorkMode;
  plan_source: string;
  plan_note: string | null;
  shift_name: string | null;
  shift_start: string | null;
  shift_end: string | null;
  first_in: string | null;
  last_out: string | null;
  worked_min: number;
  break_min: number;
  late_min: number;
  early_min: number;
  overtime_min: number;
  status: DayStatus;
  open: boolean;
  pending_correction: boolean;
}

export type FailCode =
  | "location_required"
  | "accuracy_low"
  | "outside_area"
  | "already_in"
  | "not_checked_in"
  | "already_on_break"
  | "not_on_break"
  | "day_off"
  | "no_office"
  | "not_employee"
  | "bad_request";

export type PunchResult =
  | { ok: true; event: { kind: PunchKind; at: string; work_mode: string; location?: string | null; distance_m?: number | null }; today: Today }
  | { ok: false; code: FailCode; message: string; today?: Today; distance_m?: number; radius_m?: number; location?: string; accuracy_m?: number; max_accuracy_m?: number };

/* ---------------------------------------------------------------- location */

export interface Fix {
  lat: number;
  lng: number;
  accuracy: number;
}

export type LocateError = "denied" | "unavailable" | "timeout" | "insecure" | "unsupported";

export const LOCATE_MESSAGES: Record<LocateError, { title: string; body: string }> = {
  denied: {
    title: "Location access is blocked",
    body: "Allow location for this site in your browser settings (tap the lock icon next to the address), then try again.",
  },
  unavailable: { title: "Couldn't get your location", body: "Turn on location (GPS) on your device and try again." },
  timeout: { title: "Location took too long", body: "Move near a window or outdoors and try again." },
  insecure: { title: "Location needs a secure connection", body: "Open the app from its https:// address to use location." },
  unsupported: { title: "This browser can't share location", body: "Use a current version of Chrome, Safari or Edge." },
};

/** Ask the phone for one fresh position. Called only when the person presses Check in / Check out. */
export function locate(timeoutMs = 15000): Promise<Fix> {
  return new Promise((resolve, reject) => {
    if (typeof window !== "undefined" && !window.isSecureContext) return reject("insecure" satisfies LocateError);
    if (typeof navigator === "undefined" || !navigator.geolocation) return reject("unsupported" satisfies LocateError);
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ lat: p.coords.latitude, lng: p.coords.longitude, accuracy: p.coords.accuracy }),
      (e) => reject((e.code === 1 ? "denied" : e.code === 3 ? "timeout" : "unavailable") satisfies LocateError),
      { enableHighAccuracy: true, timeout: timeoutMs, maximumAge: 0 },
    );
  });
}

/** Whether the person has already allowed location (without asking). */
export async function permissionState(): Promise<"granted" | "prompt" | "denied" | "unknown"> {
  try {
    const p = await navigator.permissions?.query({ name: "geolocation" as PermissionName });
    return p ? (p.state as "granted" | "prompt" | "denied") : "unknown";
  } catch {
    return "unknown";
  }
}

/** Does a check-in / check-out need a location under today's rules? Breaks never do. */
export function needsLocation(t: Pick<Today, "plan" | "checked_in" | "events" | "remote_location_required">): boolean {
  const mode = t.checked_in ? [...t.events].reverse().find((e) => e.kind === "in")?.work_mode ?? t.plan.work_mode : t.plan.work_mode;
  return mode === "office" || (mode === "remote" && t.remote_location_required);
}

/** How close a reading is to the accuracy limit: ok, near (warn), or over (will be refused). */
export function accuracyLevel(accuracy: number, max: number): "ok" | "near" | "over" {
  if (accuracy > max) return "over";
  if (accuracy > max * 0.75) return "near";
  return "ok";
}

/* ---------------------------------------------------------------- time */

/** Worked and break milliseconds for one day's events, counting an open session up to `now`. */
export function timeSplit(events: Pick<AttendanceEvent, "kind" | "at">[], now: number): { worked: number; brk: number } {
  let worked = 0;
  let brk = 0;
  let seg: number | null = null;
  let br: number | null = null;
  for (const e of [...events].sort((a, b) => Date.parse(a.at) - Date.parse(b.at))) {
    const t = Date.parse(e.at);
    if (e.kind === "in") {
      seg = t;
      br = null;
    } else if (e.kind === "break_start" && seg !== null) {
      worked += t - seg;
      seg = null;
      br = t;
    } else if (e.kind === "break_end" && br !== null) {
      brk += t - br;
      br = null;
      seg = t;
    } else if (e.kind === "out") {
      if (seg !== null) worked += t - seg;
      if (br !== null) brk += t - br;
      seg = null;
      br = null;
    }
  }
  if (seg !== null) worked += Math.max(0, now - seg);
  if (br !== null) brk += Math.max(0, now - br);
  return { worked: Math.max(0, worked), brk: Math.max(0, brk) };
}

/** Kept for existing callers: worked time only. */
export function workedMs(events: Pick<AttendanceEvent, "kind" | "at">[], now: number): number {
  return timeSplit(events, now).worked;
}

export function hhmmss(ms: number): string {
  const s = Math.floor(ms / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

/** "1h 25m", "45m", "0m" */
export function hm(minutes: number): string {
  const m = Math.max(0, Math.round(minutes));
  const h = Math.floor(m / 60);
  return h ? `${h}h ${String(m % 60).padStart(2, "0")}m` : `${m}m`;
}

export function clock(iso: string | number, timeZone: string, seconds = false): string {
  return new Date(iso).toLocaleTimeString("en-IN", { timeZone, hour: "2-digit", minute: "2-digit", ...(seconds ? { second: "2-digit" } : {}), hour12: true });
}

export function longDate(iso: string | number, timeZone: string): string {
  return new Date(iso).toLocaleDateString("en-IN", { timeZone, weekday: "long", day: "numeric", month: "long", year: "numeric" });
}

/** "Thu, 19 Nov" for a YYYY-MM-DD date */
export function shortDate(day: string): string {
  return new Date(`${day}T12:00:00Z`).toLocaleDateString("en-IN", { weekday: "short", day: "numeric", month: "short", timeZone: "UTC" });
}

export function shiftRange(s: Pick<ShiftInfo, "start" | "end">, tz: string): string {
  return `${clock(s.start, tz)} – ${clock(s.end, tz)}`;
}

/** "09:00" → "9:00 am" (for times of day not tied to a date) */
export function timeOfDay(hhmm: string): string {
  const [h, m] = hhmm.split(":").map(Number);
  const hh = ((h! + 11) % 12) + 1;
  return `${hh}:${String(m).padStart(2, "0")} ${h! < 12 ? "am" : "pm"}`;
}

export const MODE_LABEL: Record<WorkMode, string> = { office: "Office", remote: "Remote", off: "Day off" };
export const SOURCE_LABEL: Record<Today["plan"]["source"], string> = {
  day: "set by HR for today",
  holiday: "holiday",
  exception: "remote-work exception",
  pattern: "from your weekly roster",
  default: "company default",
};

export const STATUS_LABEL: Record<DayStatus, string> = {
  present: "Present",
  late: "Late",
  working: "Working",
  on_break: "On break",
  missing_checkout: "Missing check-out",
  absent: "Absent",
  not_started: "Not started",
  off: "Day off",
  holiday: "Holiday",
  scheduled: "Scheduled",
  on_leave: "On leave",
};

/** Which badge style each day status uses (text is always shown too). */
export const STATUS_BADGE: Record<DayStatus, "present" | "late" | "absent" | "pending" | "holiday" | "weekly-off" | "verified" | "failed" | "leave"> = {
  present: "present",
  late: "late",
  working: "verified",
  on_break: "pending",
  missing_checkout: "failed",
  absent: "absent",
  not_started: "weekly-off",
  off: "weekly-off",
  holiday: "holiday",
  scheduled: "weekly-off",
  on_leave: "leave",
};

export const CORRECTION_KIND_LABEL: Record<string, string> = {
  missing_in: "Missing check-in",
  missing_out: "Missing check-out",
  wrong_time: "Wrong time",
  other: "Other",
};

/** Offset (ms) of a time zone from UTC at a given moment. */
function tzOffset(tz: string, at: number): number {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" })
      .formatToParts(new Date(at))
      .map((p) => [p.type, p.value]),
  );
  const asUtc = Date.UTC(+parts.year!, +parts.month! - 1, +parts.day!, +parts.hour!, +parts.minute!, +parts.second!);
  return asUtc - at;
}

/** A wall-clock time on a date in the company's time zone → ISO timestamp. */
export function localToIso(day: string, hhmm: string, tz: string, plusDays = 0): string {
  const [y, mo, d] = day.split("-").map(Number);
  const [h, mi] = hhmm.split(":").map(Number);
  const guess = Date.UTC(y!, mo! - 1, d! + plusDays, h!, mi!);
  const first = guess - tzOffset(tz, guess);
  return new Date(guess - tzOffset(tz, first)).toISOString();
}

/** ISO timestamp → "HH:MM" wall-clock in the company's time zone. */
export function isoToHhmm(iso: string, tz: string): string {
  return new Intl.DateTimeFormat("en-GB", { timeZone: tz, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date(iso));
}
