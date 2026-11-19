/** Attendance Register / reports: rows from attendance_register() and helpers shared by screens and exports. */
import { STATUS_LABEL, type DayStatus } from "./attendance";

export interface RegisterRow {
  employee_id: string;
  emp_code: string | null;
  full_name: string;
  department: string | null;
  designation: string | null;
  work_date: string;
  work_mode: string;
  shift_name: string | null;
  first_in: string | null;
  last_out: string | null;
  worked_min: number;
  break_min: number;
  late_min: number;
  early_min: number;
  overtime_min: number;
  status: DayStatus;
  note: string | null;
  pending_correction: boolean;
  half_day: boolean;
  total: number;
}

export interface RegisterFilters {
  department: string;
  employee: string;
  shift: string;
  status: string;
}
export const NO_REGISTER_FILTERS: RegisterFilters = { department: "", employee: "", shift: "", status: "" };

export const REGISTER_STATUSES: { value: string; label: string }[] = [
  { value: "", label: "All" },
  { value: "attended", label: "Attended" },
  { value: "present", label: "Present (on time)" },
  { value: "late", label: "Late" },
  { value: "absent", label: "Absent" },
  { value: "on_leave", label: "On leave" },
  { value: "missing_checkout", label: "Missing check-out" },
  { value: "holiday", label: "Holiday" },
  { value: "off", label: "Day off" },
];

/** Letter for the monthly grid (always with the full label as a tooltip and in the legend). */
export const STATUS_LETTER: Partial<Record<DayStatus, string>> = {
  present: "P", late: "L", working: "W", on_break: "W", missing_checkout: "M", absent: "A",
  on_leave: "LV", holiday: "H", off: "O", not_started: "·", scheduled: "·",
};

export function statusText(s: DayStatus): string {
  return STATUS_LABEL[s] ?? s;
}

export const ATTENDED: DayStatus[] = ["present", "late", "working", "on_break", "missing_checkout"];

/** Attended out of days due, per person (monthly grid totals). */
export function personTotals(rows: Pick<RegisterRow, "employee_id" | "status">[]): Map<string, { attended: number; due: number; leave: number }> {
  const m = new Map<string, { attended: number; due: number; leave: number }>();
  for (const r of rows) {
    const t = m.get(r.employee_id) ?? { attended: 0, due: 0, leave: 0 };
    if (ATTENDED.includes(r.status)) { t.attended++; t.due++; }
    else if (r.status === "absent") t.due++;
    else if (r.status === "on_leave") t.leave++;
    m.set(r.employee_id, t);
  }
  return m;
}

export function sortRows<T extends Record<string, unknown>>(rows: T[], key: keyof T, dir: 1 | -1): T[] {
  return [...rows].sort((a, b) => {
    const x = a[key], y = b[key];
    if (x === y) return 0;
    if (x === null || x === undefined) return 1;
    if (y === null || y === undefined) return -1;
    return (x < y ? -1 : 1) * dir;
  });
}
