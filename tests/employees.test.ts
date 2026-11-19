import { test } from "node:test";
import assert from "node:assert/strict";
import { EMPTY_FORM, filterOps, NO_FILTERS, searchPattern, toRow, validateEmployee } from "../src/lib/employees";
import { describeChanges, subjectOf } from "../src/lib/audit";
import { can } from "../src/lib/permissions";
import { navFor } from "../src/lib/nav";

test("employee form: required fields and formats", () => {
  const e = validateEmployee({ ...EMPTY_FORM, full_name: "A", email: "nope", phone: "abc", emp_code: "bad code!" });
  assert.ok(e.full_name && e.email && e.phone && e.emp_code);
  assert.deepEqual(validateEmployee({ ...EMPTY_FORM, full_name: "Gita Rao", email: "gita@acme.in" }), {});
  assert.ok(validateEmployee({ ...EMPTY_FORM, full_name: "Gita Rao", email: "g@a.in", manager_id: "x" }, "x").manager_id, "can't report to yourself");
  assert.ok(validateEmployee({ ...EMPTY_FORM, full_name: "Gita Rao", email: "g@a.in", joining_date: "2026-11-10", exit_date: "2026-11-01" }).exit_date);
});

test("employee row: blanks become nulls, e-mail lower-cased, ID left to the database", () => {
  const r = toRow({ ...EMPTY_FORM, full_name: "  Gita Rao ", email: "Gita@Acme.IN ", department_id: "" });
  assert.equal(r.full_name, "Gita Rao");
  assert.equal(r.email, "gita@acme.in");
  assert.equal(r.emp_code, null);
  assert.equal(r.department_id, null);
});

test("directory search can't break out of the PostgREST filter", () => {
  assert.equal(searchPattern("  "), null);
  assert.equal(searchPattern("Rao"), "*Rao*");
  assert.equal(searchPattern("a,b(c)*%:d"), "*a b c d*");
  const ops = filterOps({ ...NO_FILTERS, q: "gita", department: "d1" });
  assert.equal(ops[0]!.op, "or");
  assert.match(String(ops[0]!.value), /^full_name\.ilike\.\*gita\*,email\.ilike/);
  assert.deepEqual(ops.slice(1), [
    { op: "eq", col: "department_id", value: "d1" },
    { op: "eq", col: "active", value: true },
  ]);
  assert.equal(filterOps({ ...NO_FILTERS, access: "all" }).length, 0, "Everyone = no access filter");
});

test("activity log wording", () => {
  const names = { m1: "Sana Shaikh" };
  assert.deepEqual(describeChanges({ role: "employee", updated_at: "x" }, { role: "manager", updated_at: "y" }), ["Role: employee → manager"]);
  assert.deepEqual(describeChanges({ manager_id: null }, { manager_id: "m1" }, names), ["Reporting manager: — → Sana Shaikh"]);
  assert.deepEqual(describeChanges({ active: true }, { active: false }), ["Access: On → Off"]);
  assert.deepEqual(describeChanges(null, { name: "Ops", id: "1", company_id: "c" }), ["Name: Ops"], "ids and company never shown");
  assert.equal(subjectOf(null, { employee_id: "m1", day: "2026-11-19" }, names), "Sana Shaikh");
});

test("Phase 3 permissions", () => {
  assert.ok(can("admin", "assignRoles"));
  for (const r of ["hr", "manager", "employee"] as const) assert.equal(can(r, "assignRoles"), false);
  assert.ok(can("hr", "manageEmployees"));
  assert.equal(can("manager", "manageEmployees"), false);
  assert.ok(can("hr", "viewAudit"));
  assert.equal(can("manager", "viewAudit"), false);
  const emp = navFor("employee").flatMap((g) => g.items.map((i) => i.href));
  assert.ok(emp.includes("/employees"), "employees reach their own profile");
  assert.ok(!emp.includes("/departments"));
});
