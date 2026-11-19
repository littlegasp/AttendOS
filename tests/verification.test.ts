import { test } from "node:test";
import assert from "node:assert/strict";
import { accessState, EMPTY_FORM, todayIn, validateEmployee } from "../src/lib/employees";
import { describeChanges, SOURCE_LABEL } from "../src/lib/audit";

test("company date: today is taken in the company's time zone, not the browser's", () => {
  const at = Date.UTC(2026, 10, 19, 20, 0); // 19 Nov 20:00 UTC = 20 Nov 01:30 in India
  assert.equal(todayIn("Asia/Kolkata", at), "2026-11-20");
  assert.equal(todayIn("Europe/London", at), "2026-11-19");
});

test("access: off when switched off, ended after the last working day, on until then", () => {
  assert.equal(accessState({ active: false, exit_date: null }, "2026-11-19"), "off");
  assert.equal(accessState({ active: true, exit_date: "2026-11-19" }, "2026-11-19"), "active", "last day still has access");
  assert.equal(accessState({ active: true, exit_date: "2026-11-18" }, "2026-11-19"), "ended");
  assert.equal(accessState({ active: true, exit_date: null }, "2026-11-19"), "active");
});

test("employee form: Exited can't have a future date (use Notice period)", () => {
  const base = { ...EMPTY_FORM, full_name: "Gita Rao", email: "g@a.in" };
  assert.ok(validateEmployee({ ...base, employment_status: "exited", exit_date: "2026-11-25" }, undefined, "2026-11-19").exit_date);
  assert.equal(validateEmployee({ ...base, employment_status: "exited", exit_date: "2026-11-19" }, undefined, "2026-11-19").exit_date, undefined);
  assert.equal(validateEmployee({ ...base, employment_status: "notice_period", exit_date: "2026-12-31" }, undefined, "2026-11-19").exit_date, undefined);
});

test("activity log: sign-in link changes are described in words; sources are labelled", () => {
  assert.deepEqual(describeChanges({ user_id: null, full_name: "A" }, { user_id: "u1", full_name: "A" }), ["Sign-in: login linked (confirmed work e-mail)"]);
  assert.deepEqual(describeChanges({ user_id: "u1" }, { user_id: null }), ["Sign-in: login unlinked"]);
  assert.deepEqual(describeChanges(null, { user_id: "u1", full_name: "A" }), ["Name: A"], "a new record doesn't list the login id");
  assert.equal(SOURCE_LABEL.seed, "Sample data");
});
