import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { DemoRuleError, PREVIEW_OFFICES, PREVIEW_PEOPLE, reducer, resolveMapping, seed, type Action, type DemoState } from "../src/lib/biometric-mock";
import { navFor } from "../src/lib/nav";
import { can } from "../src/lib/permissions";

const people = PREVIEW_PEOPLE;
const run = (s: DemoState, a: Action) => reducer(people)(s, a);
const fresh = () => seed(people, PREVIEW_OFFICES, Date.parse("2026-11-20T06:00:00Z"));
const by = "Test HR";

test("only Admin and HR see Biometric Devices", () => {
  assert.ok(can("admin", "biometric"));
  assert.ok(can("hr", "biometric"));
  assert.equal(can("manager", "biometric"), false);
  assert.equal(can("employee", "biometric"), false);
  const has = (r: "admin" | "hr" | "manager" | "employee") => navFor(r).some((g) => g.items.some((i) => i.href === "/biometric"));
  assert.ok(has("admin") && has("hr"));
  assert.equal(has("manager") || has("employee"), false);
  assert.equal(navFor("admin").find((g) => g.items.some((i) => i.href === "/biometric"))?.label, "Configuration");
});

test("seed covers every manufacturer, agent state, sync outcome and review type", () => {
  const s = fresh();
  for (const m of ["zkteco", "essl", "matrix"]) assert.ok(s.devices.some((d) => d.manufacturer === m), m);
  assert.deepEqual(new Set(s.agents.map((a) => a.status)), new Set(["online", "offline"]));
  for (const st of ["ok", "partial", "failed", "retrying"]) assert.ok(s.syncs.some((r) => r.status === st), st);
  for (const k of ["unmatched", "ambiguous", "possible_duplicate", "after_correction", "timestamp"]) assert.ok(s.reviews.some((r) => r.kind === k), k);
  assert.ok(s.syncs.some((r) => r.confirmedDup > 0) && s.syncs.some((r) => r.possibleDup > 0));
  // Every seeded mapping points at a real person by exact id.
  for (const m of s.mappings) assert.ok(people.some((p) => p.id === m.employeeId));
});

test("mapping needs an exact, active employee — never a name match", () => {
  const s = fresh();
  assert.throws(() => run(s, { type: "addMapping", code: "300", deviceId: null, employeeId: "Aarav Sharma (sample)", by }), DemoRuleError);
  const leaver = people.find((p) => !p.active)!;
  assert.throws(() => run(s, { type: "addMapping", code: "300", deviceId: null, employeeId: leaver.id, by }), /switched off/);
  assert.throws(() => run(s, { type: "addMapping", code: "  ", deviceId: null, employeeId: people[9]!.id, by }), DemoRuleError);
});

test("no overlapping mappings for the same code and scope; one company-wide code per person", () => {
  const s = fresh();
  const taken = s.mappings.find((m) => m.deviceId === null && !m.validTo)!;
  assert.throws(() => run(s, { type: "addMapping", code: taken.code, deviceId: null, employeeId: people[9]!.id, by }), /already has a company-wide mapping/);
  assert.throws(() => run(s, { type: "addMapping", code: "777", deviceId: null, employeeId: taken.employeeId, by }), /already has a company-wide code/);
  // The same code on one device only is allowed (device-specific override).
  const s2 = run(s, { type: "addMapping", code: taken.code, deviceId: "dev-1", employeeId: people[9]!.id, by });
  const now = new Date().toISOString();
  assert.equal(resolveMapping(s2, "dev-1", taken.code, now)?.employeeId, people[9]!.id, "device-specific wins");
  assert.equal(resolveMapping(s2, "dev-2", taken.code, now)?.employeeId, taken.employeeId, "company-wide elsewhere");
});

test("mapping an unmatched code resolves its review items and records history", () => {
  const s = fresh();
  const s2 = run(s, { type: "addMapping", code: "117", deviceId: null, employeeId: people[9]!.id, by });
  const item = s2.reviews.find((r) => r.code === "117")!;
  assert.equal(item.status, "resolved");
  assert.equal(item.employeeId, people[9]!.id);
  assert.match(item.history.at(-1)!.action, /Mapped 117/);
  assert.equal(s2.mappingHistory[0]!.code, "117");
  assert.equal(item.deviceLocalTime, s.reviews.find((r) => r.code === "117")!.deviceLocalTime, "original punch time unchanged");
});

test("ending a mapping keeps its history and validity window", () => {
  const s = fresh();
  const m = s.mappings.find((x) => !x.validTo)!;
  const s2 = run(s, { type: "endMapping", mappingId: m.id, by });
  const ended = s2.mappings.find((x) => x.id === m.id)!;
  assert.ok(ended.validTo);
  assert.equal(ended.employeeId, m.employeeId);
  assert.match(s2.mappingHistory[0]!.action, /ended/);
});

test("review decisions are appended, dismissal needs a reason", () => {
  const s = fresh();
  const r = s.reviews.find((x) => x.status === "open" && x.kind === "timestamp")!;
  assert.throws(() => run(s, { type: "review", reviewId: r.id, action: "dismiss", note: "no", by }), /reason/);
  const s2 = run(s, { type: "review", reviewId: r.id, action: "dismiss", note: "Device clock was wrong", by });
  const after = s2.reviews.find((x) => x.id === r.id)!;
  assert.equal(after.status, "dismissed");
  assert.equal(after.history.length, r.history.length + 1);
  assert.equal(after.deviceLocalTime, r.deviceLocalTime);
});

test("adding a device refuses a duplicate serial and starts as Not connected", () => {
  const s = fresh();
  const base = { name: "Lobby", manufacturer: "zkteco" as const, model: "MB160", serial: "NEW12345", firmware: "", officeId: PREVIEW_OFFICES[0]!.id, method: "sdk_pull" as const, agentId: "agt-1", direction: "first_last" as const, connection: { deviceIp: "192.168.1.5", port: "4370" }, createdBy: by };
  const s2 = run(s, { type: "addDevice", device: base, by });
  const d = s2.devices.at(-1)!;
  assert.equal(d.conn, "never");
  assert.equal(d.lastSync, null);
  assert.throws(() => run(s2, { type: "addDevice", device: { ...base, serial: "new12345" }, by }), /already registered/);
});

test("the biometric module makes no database writes and no device connections", () => {
  const dir = join(__dirname, "../src/components/biometric");
  const files = readdirSync(dir).map((f) => readFileSync(join(dir, f), "utf8")).concat(readFileSync(join(__dirname, "../src/app/(app)/biometric/page.tsx"), "utf8"), readFileSync(join(__dirname, "../src/lib/biometric-mock.ts"), "utf8"));
  for (const src of files) {
    assert.equal(/\.(insert|update|upsert|delete)\(/.test(src), false, "no table writes");
    assert.equal(/fetch\(|WebSocket|XMLHttpRequest/.test(src), false, "no network calls");
    assert.equal(/#[0-9a-fA-F]{3,8}\b/.test(src), false, "no hard-coded colours");
  }
  const page = files.at(-2)!;
  const rpcs = [...page.matchAll(/\.rpc\("([a-z_]+)"/g)].map((m) => m[1]);
  assert.deepEqual(rpcs, ["people_directory"], "only the read-only people list");
});
