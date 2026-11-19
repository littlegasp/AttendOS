/** Report rows from report_people() / report_trend() and the totals built from them (screens + exports). */

export interface PersonReport {
  employee_id: string;
  emp_code: string | null;
  full_name: string;
  department: string | null;
  due_days: number;
  attended_days: number;
  absent_days: number;
  leave_days: number;
  late_days: number;
  late_min: number;
  early_days: number;
  missing_checkout: number;
  half_days: number;
  worked_min: number;
  overtime_min: number;
  avg_worked_min: number;
  rate: number | null;
}

export interface TrendRow {
  work_date: string;
  due: number;
  attended: number;
  late: number;
  on_leave: number;
  absent: number;
  avg_worked_min: number;
  rate: number | null;
}

const n = (v: unknown) => Number(v ?? 0);
const pct = (a: number, b: number) => (b > 0 ? Math.round((1000 * a) / b) / 10 : null);

export interface Summary {
  people: number;
  due: number;
  attended: number;
  rate: number | null;
  avgHours: number | null;
  lateDays: number;
  earlyDays: number;
  absentDays: number;
  absenteeism: number | null;
  overtimeHours: number;
  leaveDays: number;
  halfDays: number;
  missingCheckout: number;
}

/** Attendance rate counts only days people were due to work; average hours are per attended (complete) day. */
export function summarize(rows: PersonReport[]): Summary {
  const s = rows.reduce(
    (a, r) => ({
      due: a.due + n(r.due_days), attended: a.attended + n(r.attended_days), absent: a.absent + n(r.absent_days),
      late: a.late + n(r.late_days), early: a.early + n(r.early_days), leave: a.leave + n(r.leave_days), half: a.half + n(r.half_days),
      ot: a.ot + n(r.overtime_min), workedOnAvg: a.workedOnAvg + n(r.avg_worked_min) * (n(r.attended_days) - n(r.missing_checkout)),
      avgDays: a.avgDays + Math.max(0, n(r.attended_days) - n(r.missing_checkout)), miss: a.miss + n(r.missing_checkout),
    }),
    { due: 0, attended: 0, absent: 0, late: 0, early: 0, leave: 0, half: 0, ot: 0, workedOnAvg: 0, avgDays: 0, miss: 0 },
  );
  return {
    people: rows.length, due: s.due, attended: s.attended, rate: pct(s.attended, s.due),
    avgHours: s.avgDays ? Math.round((s.workedOnAvg / s.avgDays / 60) * 10) / 10 : null,
    lateDays: s.late, earlyDays: s.early, absentDays: s.absent, absenteeism: pct(s.absent, s.due),
    overtimeHours: Math.round((s.ot / 60) * 10) / 10, leaveDays: s.leave, halfDays: s.half, missingCheckout: s.miss,
  };
}

export interface DeptReport { department: string; people: number; due: number; attended: number; rate: number | null; late: number; absent: number; leave: number; overtimeHours: number }

export function byDepartment(rows: PersonReport[]): DeptReport[] {
  const m = new Map<string, DeptReport>();
  for (const r of rows) {
    const k = r.department ?? "No department";
    const d = m.get(k) ?? { department: k, people: 0, due: 0, attended: 0, rate: null, late: 0, absent: 0, leave: 0, overtimeHours: 0 };
    d.people++; d.due += n(r.due_days); d.attended += n(r.attended_days); d.late += n(r.late_days);
    d.absent += n(r.absent_days); d.leave += n(r.leave_days); d.overtimeHours += n(r.overtime_min) / 60;
    m.set(k, d);
  }
  return [...m.values()].map((d) => ({ ...d, rate: pct(d.attended, d.due), overtimeHours: Math.round(d.overtimeHours * 10) / 10 }))
    .sort((a, b) => a.department.localeCompare(b.department));
}

/** On time / late / absent / on leave across the range (days, not people). */
export function statusMix(trend: TrendRow[]): { key: string; label: string; value: number }[] {
  const t = trend.reduce((a, r) => ({ att: a.att + n(r.attended), late: a.late + n(r.late), abs: a.abs + n(r.absent), lv: a.lv + n(r.on_leave) }), { att: 0, late: 0, abs: 0, lv: 0 });
  return [
    { key: "present", label: "On time", value: Math.max(0, t.att - t.late) },
    { key: "late", label: "Late", value: t.late },
    { key: "absent", label: "Absent", value: t.abs },
    { key: "on_leave", label: "On leave", value: t.lv },
  ];
}
