import { test } from "node:test";
import assert from "node:assert/strict";
import { csvCell, toCsv } from "../src/lib/csv";
import { addDays, daysBetween, formatDay, monthOf, presetRange, shiftMonth } from "../src/lib/dates";
import { byDay, daysLabel, validateLeave, type LeaveType } from "../src/lib/leave";
import { personTotals } from "../src/lib/register";
import { byDepartment, statusMix, summarize, type PersonReport } from "../src/lib/reports";
import { can } from "../src/lib/permissions";

test("dates: company formats, month ends, leap years and report presets", () => {
  assert.equal(formatDay("2026-11-19"), "19 Nov 2026");
  assert.equal(formatDay("2026-11-19", "DD/MM/YYYY"), "19/11/2026");
  assert.equal(formatDay("2026-11-19", "MM/DD/YYYY"), "11/19/2026");
  assert.equal(monthOf("2028-02-10").to, "2028-02-29", "leap year");
  assert.equal(monthOf("2026-12-31").to, "2026-12-31");
  assert.equal(shiftMonth("2026-01-31", -1), "2025-12-01");
  assert.equal(addDays("2026-12-31", 1), "2027-01-01");
  assert.equal(daysBetween("2026-02-27", "2026-03-01"), 2);
  assert.deepEqual(presetRange("last_month", "2026-03-15"), { from: "2026-02-01", to: "2026-02-28" });
  assert.deepEqual(presetRange("7d", "2026-01-03"), { from: "2025-12-28", to: "2026-01-03" });
});

test("csv: quoting, Excel BOM and no formulas from data", () => {
  assert.equal(csvCell('He said "hi", ok'), '"He said ""hi"", ok"');
  assert.equal(csvCell("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"");
  assert.equal(csvCell("+91 98200"), "'+91 98200");
  assert.equal(csvCell("-12"), "-12", "negative numbers stay numbers");
  const out = toCsv([{ a: 1, b: null }], [{ label: "A", value: (r) => r.a }, { label: "B", value: (r) => r.b }]);
  assert.ok(out.startsWith("﻿A,B\r\n1,\r\n"));
});

const CL: LeaveType = { id: "t", name: "Casual", code: "CL", paid: true, yearly_days: 12, needs_approval: true, allow_half_day: false, max_backdate_days: 30, active: true };

test("leave form: dates, half days and reason", () => {
  const ok = { type: "t", start: "2026-11-20", end: "2026-11-21", half: "" as const, reason: "Family" };
  assert.deepEqual(validateLeave(ok, CL), {});
  assert.ok(validateLeave({ ...ok, end: "2026-11-19" }, CL).end);
  assert.ok(validateLeave({ ...ok, half: "first" }, { ...CL, allow_half_day: true }).half, "half day must be one date");
  assert.ok(validateLeave({ ...ok, end: ok.start, half: "first" }, CL).half, "type doesn't allow half days");
  assert.ok(validateLeave({ ...ok, reason: "x" }, CL).reason);
  assert.equal(daysLabel(0.5), "0.5 days");
  assert.equal(daysLabel(1), "1 day");
});

test("leave calendar: a request across a month boundary only fills days in the month", () => {
  const m = byDay([{ start_date: "2026-10-30", end_date: "2026-11-02" }], "2026-11-01", "2026-11-30");
  assert.deepEqual([...m.keys()], ["2026-11-01", "2026-11-02"]);
});

test("register totals: leave and days off are not counted as due", () => {
  const t = personTotals([
    { employee_id: "a", status: "present" }, { employee_id: "a", status: "late" }, { employee_id: "a", status: "absent" },
    { employee_id: "a", status: "on_leave" }, { employee_id: "a", status: "off" }, { employee_id: "a", status: "holiday" },
  ]);
  assert.deepEqual(t.get("a"), { attended: 2, due: 3, leave: 1 });
});

const P = (o: Partial<PersonReport>): PersonReport => ({ employee_id: "x", emp_code: null, full_name: "X", department: null, due_days: 0, attended_days: 0, absent_days: 0, leave_days: 0,
  late_days: 0, late_min: 0, early_days: 0, missing_checkout: 0, half_days: 0, worked_min: 0, overtime_min: 0, avg_worked_min: 0, rate: null, ...o });

test("reports: rate from due days, average hours per complete day, department totals", () => {
  const rows = [P({ department: "Sales", due_days: 10, attended_days: 9, absent_days: 1, late_days: 2, avg_worked_min: 480, overtime_min: 90 }),
                P({ employee_id: "y", department: "Sales", due_days: 10, attended_days: 10, missing_checkout: 2, avg_worked_min: 420 })];
  const s = summarize(rows);
  assert.equal(s.rate, 95);
  assert.equal(s.absenteeism, 5);
  assert.equal(s.avgHours, Math.round(((480 * 9 + 420 * 8) / 17 / 60) * 10) / 10);
  assert.equal(s.overtimeHours, 1.5);
  assert.equal(summarize([]).rate, null, "no due days: no rate rather than 0%");
  assert.deepEqual(byDepartment(rows).map((d) => [d.department, d.rate]), [["Sales", 95]]);
  assert.deepEqual(statusMix([{ work_date: "d", due: 3, attended: 2, late: 1, on_leave: 1, absent: 1, avg_worked_min: 0, rate: 66.7 }]).map((m) => m.value), [1, 1, 1, 1]);
});

test("permissions: leave decisions and exports follow the role matrix", () => {
  assert.ok(can("manager", "decideLeave") && !can("employee", "decideLeave"));
  assert.ok(can("hr", "manageLeave") && !can("manager", "manageLeave"));
  assert.ok(can("employee", "exportReports"), "employees export only their own rows (the database limits them)");
});
