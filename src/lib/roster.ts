/**
 * Work roster: which days each person works from the office, remotely, or is off.
 * Mirrors public.plan_for() in the database (date change > weekly pattern > company default)
 * so the roster grid shows exactly what check-in will enforce.
 */
import type { WorkMode } from "./attendance";

export interface Org {
  timezone: string;
  max_accuracy_m: number;
  remote_location_required: boolean;
  default_work_mode: "office" | "remote";
  weekly_off: number[];
}

export interface Location {
  id: string;
  name: string;
  address: string | null;
  lat: number;
  lng: number;
  radius_m: number;
  active: boolean;
}

export interface Employee {
  id: string;
  full_name: string;
  emp_code: string | null;
  role: string;
  active: boolean;
  home_location_id: string | null;
}

export interface PatternRow {
  employee_id: string;
  weekday: number;
  work_mode: WorkMode;
  location_id: string | null;
}

export interface DayRow {
  employee_id: string;
  day: string; // YYYY-MM-DD
  work_mode: WorkMode;
  location_id: string | null;
  note: string | null;
}

export interface Plan {
  work_mode: WorkMode;
  location_id: string | null;
  source: "day" | "pattern" | "default";
}

/** Weekday 0 (Sunday) … 6 for a YYYY-MM-DD date, independent of the device's time zone. */
export function weekday(day: string): number {
  return new Date(`${day}T12:00:00Z`).getUTCDay();
}

export function addDays(day: string, n: number): string {
  const d = new Date(`${day}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** Monday of the week containing `day`. */
export function mondayOf(day: string): string {
  return addDays(day, -((weekday(day) + 6) % 7));
}

export function weekDays(monday: string): string[] {
  return Array.from({ length: 7 }, (_, i) => addDays(monday, i));
}

/** Today's date in the company's time zone. */
export function todayIn(timeZone: string, now = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
}

export function planFor(emp: Pick<Employee, "id" | "home_location_id">, day: string, org: Pick<Org, "default_work_mode" | "weekly_off">, days: DayRow[], pattern: PatternRow[]): Plan {
  const d = days.find((r) => r.employee_id === emp.id && r.day === day);
  if (d) return { work_mode: d.work_mode, location_id: d.location_id, source: "day" };
  const wd = weekday(day);
  const p = pattern.find((r) => r.employee_id === emp.id && r.weekday === wd);
  if (p) return { work_mode: p.work_mode, location_id: p.location_id, source: "pattern" };
  if (org.weekly_off.includes(wd)) return { work_mode: "off", location_id: null, source: "default" };
  return { work_mode: org.default_work_mode, location_id: org.default_work_mode === "office" ? emp.home_location_id : null, source: "default" };
}

export const WEEKDAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
/** Monday-first order used on screen. */
export const WEEK_ORDER = [1, 2, 3, 4, 5, 6, 0];
