/**
 * Where an attendance record came from, and what was (and was not) verified about it. Used by every
 * attendance view and export so the wording is the same everywhere (B4).
 *
 * The database decides everything here (migration 0012: attendance_events.source, day_events,
 * attendance_day_sources, biometric_day_pending). This file only turns its answers into words.
 * Nothing is calculated: worked hours, overtime and early leaving always come from the engine.
 */
import type { SupabaseClient } from "@supabase/supabase-js";

export type Source = "web" | "biometric" | "import" | "correction";
export type Tone = "success" | "warning" | "danger" | "info" | "neutral";

/** The four source labels, exactly as shown on screen and written to CSV. */
export const SOURCE_LABEL: Record<Source, string> = { web: "Web", biometric: "Biometric", import: "Imported", correction: "Correction" };
const ORDER: Source[] = ["web", "biometric", "import", "correction"];
export const SOURCE_TONE: Record<Source, Tone> = { web: "neutral", biometric: "info", import: "info", correction: "warning" };

export function isSource(s: unknown): s is Source {
  return typeof s === "string" && (ORDER as string[]).includes(s);
}

export function sourceLabel(s: string | null | undefined): string {
  return isSource(s) ? SOURCE_LABEL[s] : s ? s : "";
}

/** A day's counted sources in a fixed order, e.g. "Web + Correction". Empty when nothing was counted. */
export function sourcesLabel(list: readonly string[] | null | undefined): string {
  if (!list || list.length === 0) return "";
  const known = ORDER.filter((s) => list.includes(s)).map((s) => SOURCE_LABEL[s]);
  const other = list.filter((s) => !isSource(s));
  return [...known, ...other].join(" + ");
}

export interface VerifiableEvent {
  source?: string | null;
  verified?: boolean | null;
  work_mode?: string | null;
  kind?: string | null;
}

/**
 * What the record proves. Only a web punch can be GPS-verified. A biometric or imported record says which device
 * (or file) recorded which device code; it does not prove who physically pressed it, so the wording never says
 * "verified" or "authenticated".
 */
export function verificationOf(e: VerifiableEvent): { label: string; tone: Tone; detail: string } {
  if (e.kind === "break_start" || e.kind === "break_end") return { label: "No location for breaks", tone: "neutral", detail: "Breaks never read a location." };
  switch (e.source) {
    case "biometric":
      return { label: "Biometric device record", tone: "info", detail: "Recorded by a biometric device for the employee code mapped to this person. Not GPS-verified." };
    case "import":
      return { label: "Imported record", tone: "info", detail: "Taken from an imported device file. Not GPS-verified." };
    case "correction":
      return { label: "Approved correction", tone: "warning", detail: "Added by an approved attendance correction." };
    default:
      if (e.verified) return { label: "Location verified (GPS)", tone: "success", detail: "Checked against the office location when the person checked in or out." };
      if (e.work_mode === "remote") return { label: "Remote · no location check", tone: "neutral", detail: "Remote work day: no office location was required." };
      return { label: "No location check", tone: "neutral", detail: "No GPS location was recorded for this punch." };
  }
}

/** One row of day_events (0012): counted rows and the biometric/import punches that were not counted. */
export interface DayEvent {
  at: string;
  kind: "in" | "out" | "break_start" | "break_end" | null;
  counted: boolean;
  source: Source;
  label: string;
  device: string | null;
  role: string | null;
  attendance_event_id: number | null;
  raw_event_id: number | null;
  replaced_by_correction: number | null;
}

/** Biometric/import punches that are waiting or need someone to act, as opposed to settled ones. */
export function punchTone(role: string | null): Tone {
  switch (role) {
    case "provisional_out":
    case "held":
    case "flagged":
    case "possible_duplicate":
    case "correction_needed":
    case "stored":
    case "unmatched":
      return "warning";
    case "rejected":
    case "dismissed":
      return "neutral";
    default:
      return "info";
  }
}

/** Plain wording for a punch state, used where day_events gives no label of its own (e.g. correction_needed). */
export const PUNCH_STATE_LABEL: Record<string, string> = {
  stored: "Waiting to be processed",
  unmatched: "Employee code not mapped",
  flagged: "Needs review",
  projected: "Counted",
  provisional_out: "Provisional Out",
  extra: "Extra punch",
  possible_duplicate: "Possible duplicate",
  reconciled: "Matched with app punch",
  after_correction: "After correction",
  rejected: "Duplicate",
  dismissed: "Dismissed",
  held: "Waiting for HR",
  correction_needed: "Needs an attendance correction",
};

export function punchLabel(e: Pick<DayEvent, "label" | "role">): string {
  if (e.role && e.role !== "projected" && (e.label === "Waiting to be processed" || !e.label)) return PUNCH_STATE_LABEL[e.role] ?? e.label;
  return e.label;
}

/** A day's sources and whether a provisional check-out is waiting (attendance_day_sources). */
export interface DaySources {
  sources: string[];
  pending: boolean;
}
export type DaySourceMap = Map<string, DaySources>;
export const daySourceKey = (employeeId: string, day: string) => `${employeeId}:${day}`;

/** The function is not installed on this database (migration 0012 not applied): show sources as unknown, never fail the screen. */
export function missingFunction(e: { code?: string; message?: string } | null | undefined): boolean {
  if (!e) return false;
  return e.code === "PGRST202" || e.code === "42883" || /could not find the function|does not exist/i.test(e.message ?? "");
}

function addDays(d: string, n: number): string {
  return new Date(Date.parse(`${d}T00:00:00Z`) + n * 86_400_000).toISOString().slice(0, 10);
}

/**
 * Sources for every person-day in a range, in calls of up to 93 days (the function's limit).
 * Returns null when the database does not have the function yet — callers then leave the Source column empty.
 */
export async function loadDaySources(sb: SupabaseClient, from: string, to: string, department?: string | null, employee?: string | null): Promise<DaySourceMap | null> {
  const out: DaySourceMap = new Map();
  if (!from || !to || to < from) return out;
  for (let start = from; start <= to; start = addDays(start, 93)) {
    const end = addDays(start, 92) < to ? addDays(start, 92) : to;
    const { data, error } = await sb.rpc("attendance_day_sources", { p_from: start, p_to: end, p_department: department || null, p_employee: employee || null });
    if (error) {
      if (missingFunction(error)) return null;
      throw error;
    }
    for (const r of (data ?? []) as { employee_id: string; work_date: string; sources: string[]; pending_checkout: boolean }[]) {
      out.set(daySourceKey(r.employee_id, r.work_date), { sources: r.sources ?? [], pending: Boolean(r.pending_checkout) });
    }
  }
  return out;
}

/** The value written to the CSV Source column (blank when sources are unknown or nothing was counted). */
export function csvSource(map: DaySourceMap | null | undefined, employeeId: string, day: string): string {
  return sourcesLabel(map?.get(daySourceKey(employeeId, day))?.sources);
}
