import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  assertAllowed, endMappingConflicts, reassignedPunches, DECISION, DECISIONS_FOR, DemoRuleError, emptyState, mappingConflicts, PREVIEW_OFFICES, PREVIEW_PEOPLE, reducer, resolveMapping, reviewEmployee, seed,
  type Action, type DemoState,
} from "../src/lib/biometric-mock";
import { navFor } from "../src/lib/nav";
import { can, type Role } from "../src/lib/permissions";
import type { DemoAction } from "../src/components/biometric/shared";

const people = PREVIEW_PEOPLE;
const NOW = Date.parse("2026-11-20T06:00:00Z");
const nowIso = new Date(NOW).toISOString();
const run = (s: DemoState, a: Action) => reducer(people, () => nowIso)(s, a);
const fresh = () => seed(people, PREVIEW_OFFICES, NOW);
const active = people.filter((p) => p.active).sort((a, b) => (a.emp_code ?? "").localeCompare(b.emp_code ?? ""));
const leaver = people.find((p) => !p.active)!;
const DAY = 86_400_000;
const daysAgo = (d: number) => new Date(NOW - d * DAY).toISOString();
const as = (role: Role) => ({ role, by: `Test ${role}` });
const ROLES: Role[] = ["admin", "hr", "manager", "employee"];

test("only Admin and HR see Biometric Devices", () => {
  assert.ok(can("admin", "biometric") && can("hr", "biometric"));
  assert.equal(can("manager", "biometric") || can("employee", "biometric"), false);
  const has = (r: Role) => navFor(r).some((g) => g.items.some((i) => i.href === "/biometric"));
  assert.ok(has("admin") && has("hr"));
  assert.equal(has("manager") || has("employee"), false);
  assert.equal(navFor("admin").find((g) => g.items.some((i) => i.href === "/biometric"))?.label, "Configuration");
});

test("permission matrix: device configuration and company-wide codes are Admin-only", () => {
  const expect: Record<string, Role[]> = {
    manageBiometricDevices: ["admin"],
    mapBiometricCompanyWide: ["admin"],
    mapBiometricCodes: ["admin", "hr"],
    reviewBiometric: ["admin", "hr"],
    retryBiometricSync: ["admin", "hr"],
  };
  for (const [cap, roles] of Object.entries(expect)) {
    for (const r of ROLES) assert.equal(can(r, cap as Parameters<typeof can>[1]), roles.includes(r), `${r} ${cap}`);
  }
});

test("the reducer enforces roles itself — not only the interface", () => {
  const s = fresh();
  const device = { name: "Lobby", manufacturer: "zkteco" as const, model: "MB160", serial: "NEW1", firmware: "", officeId: null, method: "sdk_pull" as const, agentId: "agt-1", direction: "first_last" as const, connection: {}, createdBy: "x" };
  const open = s.reviews.find((r) => r.status === "open" && r.kind === "possible_duplicate")!;
  const actions: DemoAction[] = [
    { type: "addDevice", device },
    { type: "setDisabled", deviceId: "dev-1", disabled: true },
    { type: "setDirection", deviceId: "dev-1", direction: "device" },
    { type: "addMapping", code: "900", deviceId: "dev-1", employeeId: active[9]!.id, validFrom: nowIso },
    { type: "endMapping", mappingId: "map-1", at: nowIso, reason: "Test reason" },
    { type: "review", reviewId: open.id, decision: "confirm_duplicate", note: "" },
  ];
  for (const r of ["manager", "employee"] as Role[]) {
    for (const a of actions) assert.throws(() => run(s, { ...a, ...as(r) } as Action), DemoRuleError, `${r} ${a.type}`);
    assert.throws(() => run(s, { type: "reset", role: r, state: emptyState() }), DemoRuleError);
  }
  // HR: cannot configure devices or map company-wide; can map device codes and review.
  for (const a of actions.slice(0, 3)) assert.throws(() => run(s, { ...a, ...as("hr") } as Action), /HR users cannot/);
  assert.throws(() => run(s, { type: "addMapping", code: "900", deviceId: null, employeeId: active[9]!.id, validFrom: nowIso, confirmCompanyWide: true, ...as("hr") }), /Admin decision/);
  const cw = s.mappings.find((m) => m.deviceId === null)!;
  assert.throws(() => run(s, { type: "endMapping", mappingId: cw.id, at: nowIso, reason: "Test reason", ...as("hr") }), /Admin decision/);
  assert.doesNotThrow(() => run(s, { ...actions[3]!, ...as("hr") } as Action));
  assert.doesNotThrow(() => run(s, { ...actions[5]!, ...as("hr") } as Action));
  // Admin can do everything.
  for (const a of actions) assert.doesNotThrow(() => run(s, { ...a, ...as("admin") } as Action), a.type);
  assert.throws(() => assertAllowed("employee", { type: "reset", role: "employee", state: s }), /Employee users cannot/);
});

test("codes are device-specific: the same code means different people on different devices", () => {
  const s = fresh();
  const a = resolveMapping(s, "dev-1", "101", nowIso)!;
  const b = resolveMapping(s, "dev-3", "101", nowIso)!;
  assert.notEqual(a.employeeId, b.employeeId);
  assert.equal(resolveMapping(s, "dev-2", "101", nowIso), null, "a code mapped on other devices is not assumed here");
  assert.ok(s.mappings.filter((m) => m.deviceId === null).length === 1, "only one explicit company-wide mapping");
});

test("historical punches keep the mapping in force at the punch time", () => {
  const s = fresh();
  assert.equal(resolveMapping(s, "dev-1", "107", daysAgo(100))!.employeeId, leaver.id, "before the re-use: the leaver");
  assert.equal(resolveMapping(s, "dev-1", "107", daysAgo(40)), null, "gap between the two mappings: unmatched");
  assert.equal(resolveMapping(s, "dev-1", "107", daysAgo(1))!.employeeId, active[6]!.id, "after the re-use: the new person");
  // Ending a mapping never moves earlier punches.
  const m = resolveMapping(s, "dev-1", "101", daysAgo(1))!;
  const s2 = run(s, { type: "endMapping", mappingId: m.id, at: nowIso, reason: "Changed devices", ...as("hr") });
  assert.equal(resolveMapping(s2, "dev-1", "101", daysAgo(1))!.employeeId, m.employeeId);
  assert.equal(resolveMapping(s2, "dev-1", "101", new Date(NOW + DAY).toISOString()), null);
  assert.equal(s2.mappingHistory[0]!.reason, "Changed devices");
  assert.throws(() => run(s, { type: "endMapping", mappingId: m.id, at: nowIso, reason: "no", ...as("hr") }), /reason/);
  assert.throws(() => run(s, { type: "endMapping", mappingId: m.id, at: daysAgo(400), reason: "Too early", ...as("hr") }), /after the mapping started/);
});

test("device mapping takes precedence over company-wide", () => {
  const s = fresh();
  const cw = s.mappings.find((m) => m.deviceId === null)!;
  assert.equal(resolveMapping(s, "dev-2", cw.code, nowIso)!.id, cw.id, "company-wide applies where the device has none");
  const s2 = run(s, { type: "addMapping", code: cw.code, deviceId: "dev-2", employeeId: active[8]!.id, validFrom: daysAgo(1), ...as("hr") });
  assert.equal(resolveMapping(s2, "dev-2", cw.code, nowIso)!.employeeId, active[8]!.id);
  assert.equal(resolveMapping(s2, "dev-1", cw.code, nowIso)!.id, cw.id);
  assert.equal(resolveMapping(s2, "dev-2", cw.code, daysAgo(5))!.id, cw.id, "before the device mapping took effect");
});

test("conflicts are explained before saving: blocks and notices", () => {
  const s = fresh();
  const blocks = (d: Parameters<typeof mappingConflicts>[2]) => mappingConflicts(s, people, d).filter((c) => c.level === "block").map((c) => c.text);
  const notices = (d: Parameters<typeof mappingConflicts>[2]) => mappingConflicts(s, people, d).filter((c) => c.level === "notice").map((c) => c.text);
  const taken = resolveMapping(s, "dev-1", "101", nowIso)!;
  assert.match(blocks({ code: "101", deviceId: "dev-1", employeeId: active[9]!.id, validFrom: nowIso }).join(), /already mapped/);
  assert.match(blocks({ code: "999", deviceId: "dev-1", employeeId: taken.employeeId, validFrom: nowIso }).join(), /already has code 101/);
  assert.match(blocks({ code: "999", deviceId: "dev-1", employeeId: leaver.id, validFrom: nowIso }).join(), /switched off/);
  assert.match(blocks({ code: "", deviceId: "dev-1", employeeId: active[9]!.id, validFrom: nowIso }).join(), /Enter the employee code/);
  assert.match(blocks({ code: "a b", deviceId: "dev-1", employeeId: active[9]!.id, validFrom: nowIso }).join(), /letters, digits/);
  assert.match(blocks({ code: "999", deviceId: "dev-1", employeeId: "Aarav Sharma (sample)", validFrom: nowIso }).join(), /not in this company/, "never a name match");
  // Same code on a different device is fine.
  assert.deepEqual(blocks({ code: "101", deviceId: "dev-2", employeeId: active[9]!.id, validFrom: nowIso }), []);
  // Company-wide: warns about devices that keep their own mapping.
  const n = notices({ code: "101", deviceId: null, employeeId: active[9]!.id, validFrom: nowIso }).join(" ");
  assert.match(n, /Main entrance.*keeps precedence/);
  assert.match(n, /Plant shop floor/);
  assert.match(n, /every device without its own mapping/);
  // Waiting punches: covered vs earlier than the effective date.
  const r = s.reviews.find((x) => x.raw.code === "117")!;
  assert.match(notices({ code: "117", deviceId: "dev-1", employeeId: active[9]!.id, validFrom: r.raw.punchAt }).join(), /1 waiting punch .* original time/);
  assert.match(notices({ code: "117", deviceId: "dev-1", employeeId: active[9]!.id, validFrom: nowIso }).join(), /earlier than the effective date/);
});

test("company-wide mapping needs an explicit Admin confirmation", () => {
  const s = fresh();
  const d = { type: "addMapping" as const, code: "C9000", deviceId: null, employeeId: active[8]!.id, validFrom: nowIso, ...as("admin") };
  assert.throws(() => run(s, d), /Confirm that this code/);
  const s2 = run(s, { ...d, confirmCompanyWide: true });
  assert.equal(s2.mappings.at(-1)!.deviceId, null);
});

test("mapping an unmatched code resolves only the punches it covers, at their original time", () => {
  const s = fresh();
  const before = s.reviews.find((r) => r.raw.code === "117")!;
  // Effective after the punch: the item stays unmatched.
  const late = run(s, { type: "addMapping", code: "117", deviceId: "dev-1", employeeId: active[9]!.id, validFrom: nowIso, ...as("hr") });
  assert.equal(late.reviews.find((r) => r.id === before.id)!.status, "open");
  // Mapping on another device does not touch it.
  const other = run(s, { type: "addMapping", code: "117", deviceId: "dev-2", employeeId: active[9]!.id, validFrom: daysAgo(1), ...as("hr") });
  assert.equal(other.reviews.find((r) => r.id === before.id)!.status, "open");
  const s2 = run(s, { type: "addMapping", code: "117", deviceId: "dev-1", employeeId: active[9]!.id, validFrom: before.raw.punchAt, ...as("hr") });
  const item = s2.reviews.find((r) => r.id === before.id)!;
  assert.equal(item.status, "resolved");
  assert.equal(reviewEmployee(s2, item)!.employeeId, active[9]!.id);
  assert.deepEqual(item.raw, before.raw, "raw device record unchanged");
  assert.equal(item.history.length, before.history.length + 1);
  assert.match(item.history.at(-1)!.by, /Test hr · HR/);
});

test("review decisions: only valid ones, reason where required, raw never modified, decided once", () => {
  const s = fresh();
  for (const [kind, ds] of Object.entries(DECISIONS_FOR)) assert.ok(ds.length > 0, kind);
  for (const d of ["accept_time", "dismiss", "not_duplicate"] as const) assert.ok(DECISION[d].reasonRequired, d);
  const r = s.reviews.find((x) => x.status === "open" && x.kind === "timestamp")!;
  const rawBefore = structuredClone(r.raw);
  assert.ok(Object.isFrozen(r.raw), "raw punch is frozen");
  assert.throws(() => run(s, { type: "review", reviewId: r.id, decision: "confirm_duplicate", note: "", ...as("hr") }), /does not apply/);
  assert.throws(() => run(s, { type: "review", reviewId: r.id, decision: "dismiss", note: "no", ...as("hr") }), /reason is required/);
  const s2 = run(s, { type: "review", reviewId: r.id, decision: "dismiss", note: "Device clock was wrong", ...as("hr") });
  const after = s2.reviews.find((x) => x.id === r.id)!;
  assert.equal(after.status, "dismissed");
  assert.deepEqual(after.raw, rawBefore);
  assert.deepEqual(after.history.slice(0, -1), r.history, "earlier history kept");
  const last = after.history.at(-1)!;
  assert.equal(last.action, "Dismiss");
  assert.equal(last.note, "Device clock was wrong");
  assert.equal(last.at, nowIso);
  assert.match(last.by, /HR$/);
  assert.throws(() => run(s2, { type: "review", reviewId: r.id, decision: "accept_time", note: "Second try", ...as("admin") }), /already been decided/);
  // Optional note: confirm duplicate works without one.
  const dup = s.reviews.find((x) => x.status === "open" && x.kind === "possible_duplicate")!;
  assert.equal(run(s, { type: "review", reviewId: dup.id, decision: "confirm_duplicate", note: "", ...as("hr") }).reviews.find((x) => x.id === dup.id)!.status, "resolved");
});

test("adding a device: name length, duplicate serial, starts Not connected", () => {
  const s = fresh();
  const base = { name: "Lobby", manufacturer: "zkteco" as const, model: "MB160", serial: "NEW12345", firmware: "", officeId: PREVIEW_OFFICES[0]!.id, method: "sdk_pull" as const, agentId: "agt-1", direction: "first_last" as const, connection: { deviceIp: "192.168.1.5", port: "4370" }, createdBy: "x" };
  const s2 = run(s, { type: "addDevice", device: base, ...as("admin") });
  const d = s2.devices.at(-1)!;
  assert.equal(d.conn, "never");
  assert.equal(d.lastSync, null);
  assert.throws(() => run(s2, { type: "addDevice", device: { ...base, serial: "new12345" }, ...as("admin") }), /already registered/);
  assert.throws(() => run(s, { type: "addDevice", device: { ...base, name: "x".repeat(61) }, ...as("admin") }), /1–60/);
});

test("reset and empty module", () => {
  const s = run(fresh(), { type: "reset", state: emptyState(), role: "hr" });
  assert.equal(s.devices.length + s.mappings.length + s.reviews.length, 0);
});

test("the biometric module makes no database writes and no device connections", () => {
  const dir = join(__dirname, "../src/components/biometric");
  const page = readFileSync(join(__dirname, "../src/app/(app)/biometric/page.tsx"), "utf8");
  const files = readdirSync(dir).map((f) => readFileSync(join(dir, f), "utf8")).concat(page, readFileSync(join(__dirname, "../src/lib/biometric-mock.ts"), "utf8"));
  for (const src of files) {
    assert.equal(/\.(insert|update|upsert|delete)\(/.test(src), false, "no table writes");
    assert.equal(/fetch\(|WebSocket|XMLHttpRequest|EventSource/.test(src), false, "no network calls");
    assert.equal(/#[0-9a-fA-F]{3,8}\b/.test(src), false, "no hard-coded colours");
  }
  const rpcs = [...page.matchAll(/\.rpc\("([a-z_]+)"/g)].map((m) => m[1]);
  assert.deepEqual(rpcs, ["people_directory"], "only the read-only people list");
});

test("sign-off: processed punches are never silently reassigned by a mapping change", () => {
  const s = fresh();
  const dup = s.reviews.find((r) => r.raw.code === "105" && r.status === "open")!; // processed (attributed) punch
  const m105 = reviewEmployee(s, dup)!;
  const beforePunch = new Date(Date.parse(dup.raw.punchAt) - 60_000).toISOString();
  assert.match(endMappingConflicts(s, m105.id, beforePunch)[0]!.text, /already processed punch/);
  assert.throws(() => run(s, { type: "endMapping", mappingId: m105.id, at: beforePunch, reason: "Back-dated end", ...as("admin") }), /already processed/);
  assert.deepEqual(endMappingConflicts(s, m105.id, nowIso), [], "ending after the punch is fine");
  const s2 = run(s, { type: "endMapping", mappingId: m105.id, at: nowIso, reason: "Left today", ...as("hr") });
  assert.equal(reviewEmployee(s2, s2.reviews.find((r) => r.id === dup.id)!)!.employeeId, m105.employeeId, "still the same person");
  // A dismissed unmatched punch is processed too: a back-dated mapping may not pick it up.
  const un = s.reviews.find((r) => r.raw.code === "117")!;
  const s3 = run(s, { type: "review", reviewId: un.id, decision: "dismiss", note: "Visitor test punch", ...as("hr") });
  assert.throws(() => run(s3, { type: "addMapping", code: "117", deviceId: "dev-1", employeeId: active[9]!.id, validFrom: un.raw.punchAt, ...as("hr") }), /already processed/);
  const s4 = run(s3, { type: "addMapping", code: "117", deviceId: "dev-1", employeeId: active[9]!.id, validFrom: nowIso, ...as("hr") });
  assert.equal(s4.reviews.find((r) => r.id === un.id)!.status, "dismissed");
  assert.equal(reviewEmployee(s4, s4.reviews.find((r) => r.id === un.id)!), null);
  // Company-wide added back-dated over a processed punch on a device without its own mapping is blocked too.
  const s5 = run(s, { type: "addMapping", code: "117", deviceId: "dev-1", employeeId: active[9]!.id, validFrom: un.raw.punchAt, ...as("hr") });
  assert.equal(reassignedPunches(s5, s5.mappings).length, 0);
});

test("sign-off: effective dates — a mapping starting later does not cover earlier punches", () => {
  const s = fresh();
  const un = s.reviews.find((r) => r.raw.code === "205")!;
  const later = new Date(Date.parse(un.raw.punchAt) + 60_000).toISOString();
  const s2 = run(s, { type: "addMapping", code: "205", deviceId: "dev-3", employeeId: active[9]!.id, validFrom: later, ...as("hr") });
  assert.equal(s2.reviews.find((r) => r.id === un.id)!.status, "open");
  assert.equal(resolveMapping(s2, "dev-3", "205", un.raw.punchAt), null);
  assert.equal(resolveMapping(s2, "dev-3", "205", nowIso)!.employeeId, active[9]!.id);
});

test("sign-off: repeated or invalid actions leave state consistent and never mutate it", () => {
  const s = fresh();
  const snap = structuredClone(s);
  const dup = s.reviews.find((r) => r.status === "open" && r.kind === "possible_duplicate")!;
  const s2 = run(s, { type: "review", reviewId: dup.id, decision: "confirm_duplicate", note: "", ...as("hr") });
  assert.deepEqual(s, snap, "reducer never mutates the previous state");
  for (const d of ["confirm_duplicate", "not_duplicate", "dismiss"] as const) {
    assert.throws(() => run(s2, { type: "review", reviewId: dup.id, decision: d, note: "Second decision", ...as("admin") }), /already been decided/);
  }
  assert.equal(s2.reviews.find((r) => r.id === dup.id)!.history.length, dup.history.length + 1, "exactly one decision recorded");
  // Mapping twice: the second is an overlap.
  const un = s.reviews.find((r) => r.raw.code === "117")!;
  const m1 = run(s, { type: "addMapping", code: "117", deviceId: "dev-1", employeeId: active[9]!.id, validFrom: un.raw.punchAt, ...as("hr") });
  assert.throws(() => run(m1, { type: "addMapping", code: "117", deviceId: "dev-1", employeeId: active[9]!.id, validFrom: un.raw.punchAt, ...as("hr") }), /already mapped/);
  // A punch resolved by mapping cannot then be dismissed.
  assert.throws(() => run(m1, { type: "review", reviewId: un.id, decision: "dismiss", note: "Too late now", ...as("hr") }), /already been decided/);
  // Ending twice.
  const m = m1.mappings.at(-1)!;
  const e1 = run(m1, { type: "endMapping", mappingId: m.id, at: nowIso, reason: "First end", ...as("hr") });
  assert.throws(() => run(e1, { type: "endMapping", mappingId: m.id, at: nowIso, reason: "Second end", ...as("hr") }), /already ended/);
  assert.throws(() => run(s, { type: "review", reviewId: "missing", decision: "dismiss", note: "Not there", ...as("hr") }));
});

test("sign-off: every review decision is Admin/HR only and records actor, role, time and reason", () => {
  const s = fresh();
  for (const r of s.reviews.filter((x) => x.status === "open")) {
    for (const d of DECISIONS_FOR[r.kind]) {
      const note = "Checked against the gate log";
      for (const role of ["manager", "employee"] as Role[]) assert.throws(() => run(s, { type: "review", reviewId: r.id, decision: d, note, ...as(role) }), /cannot make review decisions/);
      for (const role of ["admin", "hr"] as Role[]) {
        const after = run(s, { type: "review", reviewId: r.id, decision: d, note, ...as(role) }).reviews.find((x) => x.id === r.id)!;
        const h = after.history.at(-1)!;
        assert.equal(h.action, DECISION[d].label);
        assert.equal(h.note, note);
        assert.equal(h.at, nowIso);
        assert.equal(h.by, `Test ${role} · ${role === "hr" ? "HR" : "Admin"}`);
        assert.deepEqual(after.raw, r.raw);
        assert.equal(after.status, d === "dismiss" ? "dismissed" : "resolved");
      }
    }
  }
});
