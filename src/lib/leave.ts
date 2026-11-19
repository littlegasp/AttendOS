/** Leave: shapes from the database and small rules the screens share (the database repeats every check). */

export type LeaveStatus = "pending" | "approved" | "rejected" | "cancelled";

export interface LeaveType {
  id: string;
  name: string;
  code: string;
  paid: boolean;
  yearly_days: number | null;
  needs_approval: boolean;
  allow_half_day: boolean;
  max_backdate_days: number;
  active: boolean;
}

export interface Balance {
  leave_type_id: string;
  name: string;
  code: string;
  paid: boolean;
  yearly_days: number | null;
  adjustments: number;
  taken: number;
  pending: number;
  available: number | null;
  year_start: string;
  year_end: string;
}

export interface LeaveRow {
  id: number;
  employee_id: string;
  full_name: string;
  emp_code: string | null;
  department: string | null;
  leave_type: string;
  code: string;
  start_date: string;
  end_date: string;
  half_day: "first" | "second" | null;
  days: number;
  reason: string;
  status: LeaveStatus;
  requested_at: string;
  requested_by_name: string | null;
  decided_by_name: string | null;
  decided_at: string | null;
  decision_note: string | null;
  can_decide: boolean;
  can_cancel: boolean;
}

export const LEAVE_STATUS_LABEL: Record<LeaveStatus, string> = { pending: "Pending", approved: "Approved", rejected: "Rejected", cancelled: "Cancelled" };
export const LEAVE_STATUS_BADGE: Record<LeaveStatus, "pending" | "approved" | "rejected" | "weekly-off"> = {
  pending: "pending",
  approved: "approved",
  rejected: "rejected",
  cancelled: "weekly-off",
};

export const HALF_LABEL = { first: "First half", second: "Second half" } as const;

export function daysLabel(n: number): string {
  const v = Number(n);
  return `${Number.isInteger(v) ? v : v.toFixed(1)} ${v === 1 ? "day" : "days"}`;
}

export interface LeaveForm {
  type: string;
  start: string;
  end: string;
  half: "" | "first" | "second";
  reason: string;
}

export function validateLeave(f: LeaveForm, t: LeaveType | undefined): Partial<Record<keyof LeaveForm, string>> {
  const e: Partial<Record<keyof LeaveForm, string>> = {};
  if (!t) e.type = "Choose a leave type.";
  if (!f.start) e.start = "Choose the first day.";
  if (!f.end) e.end = "Choose the last day.";
  if (f.start && f.end && f.end < f.start) e.end = "The last day can't be before the first day.";
  if (f.half && f.start !== f.end) e.half = "A half day must be a single date.";
  if (f.half && t && !t.allow_half_day) e.half = `${t.name} leave can't be taken as a half day.`;
  if (f.reason.trim().length < 3) e.reason = "Give a short reason (at least 3 characters).";
  return e;
}

/** Turns the database's refusal into the sentence HR or the employee sees. */
export function leaveError(msg: string): string {
  if (/overlaps/i.test(msg) || /Not enough/i.test(msg) || /days back/i.test(msg) || /leave year/i.test(msg) || /attendance on one/i.test(msg)
      || /days off or holidays/i.test(msg) || /joining date|last working day/i.test(msg) || /half day/i.test(msg) || /reason when rejecting/i.test(msg)
      || /already/i.test(msg) || /has started/i.test(msg) || /own leave/i.test(msg) || /91 days/i.test(msg)) return msg;
  if (/Not allowed|permission/i.test(msg)) return "You don't have permission to do that.";
  return msg;
}

/** Calendar: which requests touch each day of a month. */
export function byDay(rows: Pick<LeaveRow, "start_date" | "end_date">[], from: string, to: string): Map<string, number[]> {
  const out = new Map<string, number[]>();
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i]!;
    let d = r.start_date < from ? from : r.start_date;
    const end = r.end_date > to ? to : r.end_date;
    while (d <= end) {
      out.set(d, [...(out.get(d) ?? []), i]);
      const [y, m, dd] = d.split("-").map(Number);
      d = new Date(Date.UTC(y!, m! - 1, dd! + 1)).toISOString().slice(0, 10);
    }
  }
  return out;
}
