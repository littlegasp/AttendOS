/**
 * Attendance logic used by the browser. The database decides whether a check-in counts
 * (punch()); this file only reads the phone's location, talks to the database and works
 * out what to show.
 */

export type WorkMode = "office" | "remote" | "off";

export interface AttendanceEvent {
  kind: "in" | "out";
  at: string;
  work_mode: "office" | "remote";
  location: string | null;
  distance_m: number | null;
  verified: boolean;
}

export interface Today {
  ok: true;
  server_now: string;
  timezone: string;
  today: string;
  max_accuracy_m: number;
  remote_location_required: boolean;
  employee: { id: string; full_name: string; role: string };
  plan: { work_mode: WorkMode; source: "day" | "pattern" | "default"; location: { id: string; name: string; radius_m: number } | null };
  checked_in: boolean;
  open_since: string | null;
  events: AttendanceEvent[];
}

export type FailCode =
  | "location_required"
  | "accuracy_low"
  | "outside_area"
  | "already_in"
  | "not_checked_in"
  | "day_off"
  | "no_office"
  | "not_employee"
  | "bad_request";

export type PunchResult =
  | { ok: true; event: { kind: "in" | "out"; at: string; work_mode: string; location: string | null; distance_m: number | null }; today: Today }
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

/** Does this punch need a location under today's rules? */
export function needsLocation(t: Pick<Today, "plan" | "checked_in" | "events" | "remote_location_required">): boolean {
  const mode = t.checked_in ? [...t.events].reverse().find((e) => e.kind === "in")?.work_mode ?? t.plan.work_mode : t.plan.work_mode;
  return mode === "office" || (mode === "remote" && t.remote_location_required);
}

/* ---------------------------------------------------------------- time */

/** Milliseconds worked today: closed sessions plus the open one up to `now`. */
export function workedMs(events: Pick<AttendanceEvent, "kind" | "at">[], now: number): number {
  let total = 0;
  let start: number | null = null;
  for (const e of [...events].sort((a, b) => Date.parse(a.at) - Date.parse(b.at))) {
    const t = Date.parse(e.at);
    if (e.kind === "in") start = t;
    else if (start !== null) {
      total += Math.max(0, t - start);
      start = null;
    }
  }
  if (start !== null) total += Math.max(0, now - start);
  return total;
}

export function hhmmss(ms: number): string {
  const s = Math.floor(ms / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`;
}

export function clock(iso: string | number, timeZone: string, seconds = false): string {
  return new Date(iso).toLocaleTimeString("en-IN", { timeZone, hour: "2-digit", minute: "2-digit", ...(seconds ? { second: "2-digit" } : {}), hour12: true });
}

export function longDate(iso: string | number, timeZone: string): string {
  return new Date(iso).toLocaleDateString("en-IN", { timeZone, weekday: "long", day: "numeric", month: "long", year: "numeric" });
}

export const MODE_LABEL: Record<WorkMode, string> = { office: "Office", remote: "Remote", off: "Day off" };
export const SOURCE_LABEL: Record<Today["plan"]["source"], string> = {
  day: "set by HR for today",
  pattern: "from your weekly roster",
  default: "company default",
};
