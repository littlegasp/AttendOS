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
  default_shift_id?: string | null;
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
  default_shift_id?: string | null;
}

export interface Shift {
  id: string;
  name: string;
  start_time: string; // "HH:MM:SS"
  end_time: string;
  break_minutes: number;
  grace_minutes: number;
  active: boolean;
}

export interface ShiftPatternRow {
  employee_id: string;
  weekday: number;
  shift_id: string;
}

export interface ShiftDayRow {
  employee_id: string;
  day: string;
  shift_id: string;
}

export interface Holiday {
  id: string;
  day: string;
  name: string;
  location_id: string | null;
}

export interface RemoteException {
  id: string;
  employee_id: string;
  start_date: string;
  end_date: string;
  reason: string;
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
  source: "day" | "holiday" | "exception" | "pattern" | "default";
  note?: string | null;
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

/** Mirrors public.plan_for(): date change > holiday > remote exception > weekly pattern > company default. */
export function planFor(
  emp: Pick<Employee, "id" | "home_location_id">,
  day: string,
  org: Pick<Org, "default_work_mode" | "weekly_off">,
  days: DayRow[],
  pattern: PatternRow[],
  holidays: Holiday[] = [],
  exceptions: RemoteException[] = [],
): Plan {
  const d = days.find((r) => r.employee_id === emp.id && r.day === day);
  if (d) return { work_mode: d.work_mode, location_id: d.location_id, source: "day", note: d.note };
  const hol = holidays.find((h) => h.day === day && (h.location_id === null || h.location_id === emp.home_location_id));
  if (hol) return { work_mode: "off", location_id: null, source: "holiday", note: hol.name };
  const wd = weekday(day);
  const p = pattern.find((r) => r.employee_id === emp.id && r.weekday === wd);
  const base: Plan = p
    ? { work_mode: p.work_mode, location_id: p.location_id, source: "pattern" }
    : org.weekly_off.includes(wd)
      ? { work_mode: "off", location_id: null, source: "default" }
      : { work_mode: org.default_work_mode, location_id: org.default_work_mode === "office" ? emp.home_location_id : null, source: "default" };
  const ex = exceptions.find((x) => x.employee_id === emp.id && day >= x.start_date && day <= x.end_date);
  if (ex && base.work_mode === "office") return { work_mode: "remote", location_id: null, source: "exception", note: ex.reason };
  return base;
}

/** Mirrors public.shift_for(): date change > weekly pattern > person's default > company default. */
export function shiftFor(
  emp: Pick<Employee, "id" | "default_shift_id">,
  day: string,
  org: Pick<Org, "default_shift_id">,
  days: ShiftDayRow[],
  pattern: ShiftPatternRow[],
): { shift_id: string | null; source: "day" | "pattern" | "employee" | "company" | "none" } {
  const d = days.find((r) => r.employee_id === emp.id && r.day === day);
  if (d) return { shift_id: d.shift_id, source: "day" };
  const p = pattern.find((r) => r.employee_id === emp.id && r.weekday === weekday(day));
  if (p) return { shift_id: p.shift_id, source: "pattern" };
  if (emp.default_shift_id) return { shift_id: emp.default_shift_id, source: "employee" };
  if (org.default_shift_id) return { shift_id: org.default_shift_id, source: "company" };
  return { shift_id: null, source: "none" };
}

export function isOvernight(s: Pick<Shift, "start_time" | "end_time">): boolean {
  return s.end_time.slice(0, 5) <= s.start_time.slice(0, 5);
}

/** Scheduled working minutes of a shift (length minus break). */
export function shiftMinutes(s: Pick<Shift, "start_time" | "end_time" | "break_minutes">): number {
  const toM = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
  let len = toM(s.end_time) - toM(s.start_time);
  if (len <= 0) len += 24 * 60;
  return len - s.break_minutes;
}

export const WEEKDAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
/** Monday-first order used on screen. */
export const WEEK_ORDER = [1, 2, 3, 4, 5, 6, 0];
