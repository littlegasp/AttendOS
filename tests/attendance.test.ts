import { test } from "node:test";
import assert from "node:assert/strict";
import { hhmmss, needsLocation, workedMs } from "../src/lib/attendance";
import { addDays, mondayOf, planFor, todayIn, weekDays, weekday } from "../src/lib/roster";
import { BRAND, brandCss } from "../src/lib/brand";

test("worked time adds closed sessions and the open one", () => {
  const ev = [
    { kind: "in" as const, at: "2026-11-19T03:30:00Z" },
    { kind: "out" as const, at: "2026-11-19T07:30:00Z" },
    { kind: "in" as const, at: "2026-11-19T08:00:00Z" },
  ];
  assert.equal(workedMs(ev, Date.parse("2026-11-19T09:00:00Z")), 5 * 3600_000);
  assert.equal(hhmmss(5 * 3600_000 + 61_000), "05:01:01");
  assert.equal(workedMs([{ kind: "out", at: "2026-11-19T03:30:00Z" }], Date.now()), 0, "a stray check-out adds nothing");
});

test("location is needed on office days, and on remote days only by policy", () => {
  const base = { checked_in: false, events: [], remote_location_required: false };
  assert.equal(needsLocation({ ...base, plan: { work_mode: "office", source: "day", location: null } }), true);
  assert.equal(needsLocation({ ...base, plan: { work_mode: "remote", source: "day", location: null } }), false);
  assert.equal(needsLocation({ ...base, remote_location_required: true, plan: { work_mode: "remote", source: "day", location: null } }), true);
  // Checking out follows the mode of the open check-in, even if HR changed today's plan meanwhile.
  assert.equal(
    needsLocation({ ...base, checked_in: true, events: [{ kind: "in", at: "x", work_mode: "office", location: "HQ", distance_m: 10, verified: true }], plan: { work_mode: "remote", source: "day", location: null } }),
    true,
  );
});

test("dates are worked out without the device's time zone", () => {
  assert.equal(weekday("2026-11-19"), 4); // Thursday
  assert.equal(mondayOf("2026-11-19"), "2026-11-16");
  assert.equal(mondayOf("2026-11-22"), "2026-11-16", "Sunday belongs to the week starting Monday");
  assert.equal(addDays("2026-12-31", 1), "2027-01-01");
  assert.deepEqual(weekDays("2026-11-16").slice(-1), ["2026-11-22"]);
  assert.equal(todayIn("Asia/Kolkata", new Date("2026-11-18T19:00:00Z")), "2026-11-19", "00:30 IST is already the next day");
});

test("roster plan: date change beats weekly pattern beats company default", () => {
  const emp = { id: "e1", home_location_id: "hq" };
  const org = { default_work_mode: "office" as const, weekly_off: [0] };
  const pattern = [{ employee_id: "e1", weekday: 4, work_mode: "remote" as const, location_id: null }];
  const days = [{ employee_id: "e1", day: "2026-11-26", work_mode: "office" as const, location_id: "pune", note: null }];
  assert.deepEqual(planFor(emp, "2026-11-19", org, days, pattern), { work_mode: "remote", location_id: null, source: "pattern" });
  assert.deepEqual(planFor(emp, "2026-11-26", org, days, pattern), { work_mode: "office", location_id: "pune", source: "day" });
  assert.deepEqual(planFor(emp, "2026-11-20", org, days, pattern), { work_mode: "office", location_id: "hq", source: "default" });
  assert.deepEqual(planFor(emp, "2026-11-22", org, days, pattern), { work_mode: "off", location_id: null, source: "default" });
});

test("branding only changes the accent, and rejects bad colours", () => {
  const css = brandCss();
  assert.match(css, /--color-primary:#FF7A00/);
  assert.doesNotMatch(css, /--color-success/, "status colours are never branded");
  assert.equal(brandCss({ ...BRAND, accent: { ...BRAND.accent, dark: "red;}body{display:none" } }), "");
});
