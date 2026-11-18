import { test } from "node:test";
import assert from "node:assert/strict";
import { accuracyLevel, hhmmss, hm, isoToHhmm, localToIso, needsLocation, timeSplit, workedMs } from "../src/lib/attendance";
import { addDays, isOvernight, mondayOf, planFor, shiftFor, shiftMinutes, todayIn, weekDays, weekday } from "../src/lib/roster";
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
  assert.equal(needsLocation({ ...base, plan: { work_mode: "office", source: "day", note: null, location: null } }), true);
  assert.equal(needsLocation({ ...base, plan: { work_mode: "remote", source: "day", note: null, location: null } }), false);
  assert.equal(needsLocation({ ...base, remote_location_required: true, plan: { work_mode: "remote", source: "day", note: null, location: null } }), true);
  // Checking out follows the mode of the open check-in, even if HR changed today's plan meanwhile.
  assert.equal(
    needsLocation({ ...base, checked_in: true, events: [{ kind: "in", at: "x", work_mode: "office", location: "HQ", distance_m: 10, verified: true }], plan: { work_mode: "remote", source: "day", note: null, location: null } }),
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
  assert.deepEqual(planFor(emp, "2026-11-26", org, days, pattern), { work_mode: "office", location_id: "pune", source: "day", note: null });
  assert.deepEqual(planFor(emp, "2026-11-20", org, days, pattern), { work_mode: "office", location_id: "hq", source: "default" });
  assert.deepEqual(planFor(emp, "2026-11-22", org, days, pattern), { work_mode: "off", location_id: null, source: "default" });
});

test("branding only changes the accent, and rejects bad colours", () => {
  const css = brandCss();
  assert.match(css, /--color-primary:#FF7A00/);
  assert.doesNotMatch(css, /--color-success/, "status colours are never branded");
  assert.equal(brandCss({ ...BRAND, accent: { ...BRAND.accent, dark: "red;}body{display:none" } }), "");
});

test("breaks are taken out of worked time, including an open break", () => {
  const ev = [
    { kind: "in" as const, at: "2026-11-19T03:30:00Z" },
    { kind: "break_start" as const, at: "2026-11-19T07:30:00Z" },
    { kind: "break_end" as const, at: "2026-11-19T08:15:00Z" },
    { kind: "break_start" as const, at: "2026-11-19T10:00:00Z" },
  ];
  const r = timeSplit(ev, Date.parse("2026-11-19T10:30:00Z"));
  assert.equal(r.worked, (4 * 60 + 105) * 60_000);
  assert.equal(r.brk, (45 + 30) * 60_000);
  assert.equal(hm(75), "1h 15m");
});

test("company-time conversions work whatever the device time zone", () => {
  assert.equal(localToIso("2026-11-19", "09:00", "Asia/Kolkata"), "2026-11-19T03:30:00.000Z");
  assert.equal(localToIso("2026-11-19", "06:00", "Asia/Kolkata", 1), "2026-11-20T00:30:00.000Z", "overnight check-out next morning");
  assert.equal(isoToHhmm("2026-11-19T03:30:00Z", "Asia/Kolkata"), "09:00");
});

test("accuracy warnings", () => {
  assert.equal(accuracyLevel(40, 100), "ok");
  assert.equal(accuracyLevel(90, 100), "near");
  assert.equal(accuracyLevel(120, 100), "over");
});

test("roster plan: holiday and remote exception, mirroring the database", () => {
  const emp = { id: "e1", home_location_id: "hq" };
  const org = { default_work_mode: "office" as const, weekly_off: [0] };
  const hol = [{ id: "h", day: "2026-11-20", name: "Founders Day", location_id: null }];
  const ex = [{ id: "x", employee_id: "e1", start_date: "2026-11-23", end_date: "2026-11-24", reason: "Recovery" }];
  assert.deepEqual(planFor(emp, "2026-11-20", org, [], [], hol, ex), { work_mode: "off", location_id: null, source: "holiday", note: "Founders Day" });
  assert.deepEqual(planFor(emp, "2026-11-23", org, [], [], hol, ex), { work_mode: "remote", location_id: null, source: "exception", note: "Recovery" });
  const sun = planFor(emp, "2026-11-22", org, [], [], hol, [{ ...ex[0]!, start_date: "2026-11-22" }]);
  assert.equal(sun.work_mode, "off", "an exception never turns a day off into a work day");
});

test("shift resolution and overnight shifts", () => {
  const emp = { id: "e1", default_shift_id: "gen" };
  assert.deepEqual(shiftFor(emp, "2026-11-19", { default_shift_id: "co" }, [], []), { shift_id: "gen", source: "employee" });
  assert.deepEqual(shiftFor({ id: "e2", default_shift_id: null }, "2026-11-19", { default_shift_id: "co" }, [], []), { shift_id: "co", source: "company" });
  assert.deepEqual(shiftFor(emp, "2026-11-19", {}, [{ employee_id: "e1", day: "2026-11-19", shift_id: "night" }], [{ employee_id: "e1", weekday: 4, shift_id: "eve" }]), { shift_id: "night", source: "day" });
  assert.equal(isOvernight({ start_time: "22:00:00", end_time: "06:00:00" }), true);
  assert.equal(isOvernight({ start_time: "09:00:00", end_time: "18:00:00" }), false);
  assert.equal(shiftMinutes({ start_time: "22:00:00", end_time: "06:00:00", break_minutes: 60 }), 420);
});
