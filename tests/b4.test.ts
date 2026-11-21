import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import type { SupabaseClient } from "@supabase/supabase-js";
import { csvSource, loadDaySources, missingFunction, punchLabel, SOURCE_LABEL, sourcesLabel, verificationOf } from "../src/lib/sources";
import { liveAction, liveAddDevice, loadLive, NotInstalled } from "../src/lib/biometric-live";
import { emptyState, type DemoState } from "../src/lib/biometric-mock";
import { toCsv } from "../src/lib/csv";
import { can, type Role } from "../src/lib/permissions";
import { navFor } from "../src/lib/nav";

/* ------------------------------------------------------------------ a recording stand-in for the database client */

type Call = { kind: "rpc" | "from"; name: string; args?: unknown; select?: string; filters: [string, unknown][] };
function fakeDb(answer: (c: Call) => { data: unknown; error: { code?: string; message: string } | null }) {
  const calls: Call[] = [];
  const builder = (c: Call) => {
    const b = {
      select(cols: string) { c.select = cols; return b; },
      order() { return b; },
      limit() { return b; },
      in(col: string, v: unknown) { c.filters.push([col, v]); return b; },
      eq(col: string, v: unknown) { c.filters.push([col, v]); return b; },
      then(ok: (v: unknown) => unknown, bad?: (e: unknown) => unknown) { return Promise.resolve(answer(c)).then(ok, bad); },
    };
    return b;
  };
  const sb = {
    from(name: string) { const c: Call = { kind: "from", name, filters: [] }; calls.push(c); return builder(c); },
    rpc(name: string, args: unknown) { const c: Call = { kind: "rpc", name, args, filters: [] }; calls.push(c); return Promise.resolve(answer(c)); },
  };
  return { sb: sb as unknown as SupabaseClient, calls };
}

/* ------------------------------------------------------------------ source labels and verification wording */

test("B4 source labels: exactly Web, Biometric, Imported, Correction; fixed order for a day", () => {
  assert.deepEqual(SOURCE_LABEL, { web: "Web", biometric: "Biometric", import: "Imported", correction: "Correction" });
  assert.equal(sourcesLabel(["correction", "web"]), "Web + Correction");
  assert.equal(sourcesLabel(["biometric", "import", "web", "correction"]), "Web + Biometric + Imported + Correction");
  assert.equal(sourcesLabel([]), "");
  assert.equal(sourcesLabel(null), "");
});

test("B4 biometric and imported records are never called GPS-verified or authenticated", () => {
  for (const source of ["biometric", "import"]) {
    for (const verified of [true, false, null]) {
      const v = verificationOf({ source, verified, work_mode: "office", kind: "in" });
      assert.doesNotMatch(v.label, /verified|authenticat|identity/i, `${source}/${verified}: ${v.label}`);
      assert.match(v.detail, /Not GPS-verified/, v.detail);
      assert.doesNotMatch(v.detail, /authenticat|proves|identity confirmed/i);
    }
  }
  assert.equal(verificationOf({ source: "web", verified: true, kind: "in" }).label, "Location verified (GPS)");
  assert.equal(verificationOf({ source: "web", verified: false, work_mode: "remote", kind: "in" }).label, "Remote · no location check");
  assert.equal(verificationOf({ source: "correction", verified: false, kind: "out" }).label, "Approved correction");
  assert.equal(verificationOf({ source: "biometric", kind: "break_start" }).label, "No location for breaks");
});

test("B4 punch state wording: correction_needed gets its own words; database labels are kept otherwise", () => {
  assert.equal(punchLabel({ label: "Waiting to be processed", role: "correction_needed" }), "Needs an attendance correction");
  assert.equal(punchLabel({ label: "Provisional Out", role: "provisional_out" }), "Provisional Out");
  assert.equal(punchLabel({ label: "Extra punch", role: "extra" }), "Extra punch");
});

test("B4 CSV Source column: values from attendance_day_sources, blank when unknown; formulas still neutralised", async () => {
  const { sb, calls } = fakeDb((c) => ({ data: c.kind === "rpc" ? [{ employee_id: "e1", work_date: "2026-11-20", sources: ["biometric", "correction"], pending_checkout: false }, { employee_id: "e2", work_date: "2026-11-20", sources: [], pending_checkout: true }] : [], error: null }));
  const map = await loadDaySources(sb, "2026-11-20", "2026-11-20");
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.args, { p_from: "2026-11-20", p_to: "2026-11-20", p_department: null, p_employee: null });
  assert.equal(csvSource(map, "e1", "2026-11-20"), "Biometric + Correction");
  assert.equal(csvSource(map, "e2", "2026-11-20"), "", "provisional only: nothing counted yet");
  assert.equal(map!.get("e2:2026-11-20")!.pending, true);
  assert.equal(csvSource(null, "e1", "2026-11-20"), "", "unknown on a database without 0012");
  const csv = toCsv([{ a: "x" }], [{ label: "Employee", value: () => "=cmd" }, { label: "Source", value: () => "Web" }]);
  assert.match(csv, /^﻿Employee,Source\r\n'=cmd,Web\r\n$/);
});

test("B4 day sources: ranges over 93 days are split; a database without 0012 gives null (screens keep working)", async () => {
  const { sb, calls } = fakeDb(() => ({ data: [], error: null }));
  await loadDaySources(sb, "2026-01-01", "2026-12-31", "d1", "e1");
  assert.equal(calls.length, 4);
  assert.deepEqual(calls.map((c) => [(c.args as { p_from: string }).p_from, (c.args as { p_to: string }).p_to]), [["2026-01-01", "2026-04-03"], ["2026-04-04", "2026-07-05"], ["2026-07-06", "2026-10-06"], ["2026-10-07", "2026-12-31"]]);
  for (const c of calls) assert.equal(((c.args as { p_to: string }).p_to > (c.args as { p_from: string }).p_from), true);
  const missing = fakeDb(() => ({ data: null, error: { code: "PGRST202", message: "Could not find the function public.attendance_day_sources" } }));
  assert.equal(await loadDaySources(missing.sb, "2026-11-01", "2026-11-30"), null);
  assert.ok(missingFunction({ code: "42883", message: "function does not exist" }));
  const failing = fakeDb(() => ({ data: null, error: { code: "42501", message: "Not allowed" } }));
  await assert.rejects(loadDaySources(failing.sb, "2026-11-01", "2026-11-30"), { message: "Not allowed" });
});

/* ------------------------------------------------------------------ live biometric module */

const NOW = Date.parse("2026-11-21T06:00:00Z");
const people = [{ id: "e1", full_name: "Asha Rao", emp_code: "E1", active: true }, { id: "e2", full_name: "Ben Das", emp_code: "E2", active: true }];
const T = (min: number) => new Date(NOW - min * 60_000).toISOString();

function liveDb() {
  return fakeDb((c) => {
    if (c.kind !== "from") return { data: null, error: null };
    switch (c.name) {
      case "biometric_agents": return { data: [{ id: "a1", name: "HO PC", agent_identifier: "ho-pc", version: "1.0", status: "active", last_heartbeat_at: T(2) }], error: null };
      case "biometric_devices": return { data: [
        { id: "d1", name: "Main gate", manufacturer: "zkteco", model: "K40", serial_number: "SER001", firmware_version: null, location_id: "L1", integration_method: "sdk_pull", agent_id: "a1", direction_mode: "first_last", status: "active", last_seen_at: T(3), last_successful_sync_at: T(3), clock_drift_s: 4, connection: { deviceIp: "192.168.1.9", port: 4370 }, created_at: T(9000), created_by: "e1" },
        { id: "d2", name: "Old door", manufacturer: "essl", model: "X990", serial_number: "SER002", firmware_version: "6.6", location_id: null, integration_method: "local_push", agent_id: "a1", direction_mode: "device", status: "disabled", last_seen_at: null, last_successful_sync_at: null, clock_drift_s: null, connection: {}, created_at: T(9000), created_by: null },
      ], error: null };
      case "biometric_employee_mappings": return { data: [{ id: "m1", device_id: "d1", employee_id: "e1", employee_device_code: "101", valid_from: T(5000), valid_to: T(100), end_reason: "Left", created_by: "e1", ended_by: "e1", created_at: T(5000), updated_at: T(100) }], error: null };
      case "biometric_sync_runs": return { data: [{ id: 7, agent_id: "a1", device_id: "d1", started_at: T(5), completed_at: T(4), status: "partial", received: 3, stored: 3, confirmed_duplicates: 0, possible_duplicates: 1, conflicts: 0, rejected: 0, error_summary: null }], error: null };
      case "biometric_event_errors": return { data: [{ id: 1, device_id: "d1", kind: "clock_drift", detail: {}, created_at: T(6), resolved_at: null }], error: null };
      case "biometric_event_reviews": return { data: [{ id: 3, raw_event_id: 13, action: "dismiss", reason: "Visitor test", decided_by: "e1", decided_role: "hr", decided_at: T(1), state_before: { status: "flagged" } }], error: null };
      case "biometric_event_state":
        if (c.filters.some(([col]) => col === "status")) return { data: [
          { raw_event_id: 11, employee_id: null, status: "unmatched", flag_reasons: [], hold_reason: null, decided: false, version: 1, processed_at: null, next_check_at: null, work_date: null },
          { raw_event_id: 12, employee_id: "e2", status: "correction_needed", flag_reasons: ["would_open_closed_day"], hold_reason: null, decided: false, version: 3, processed_at: T(2), next_check_at: null, work_date: "2026-11-20" },
          { raw_event_id: 14, employee_id: "e2", status: "held", flag_reasons: [], hold_reason: "on_leave", decided: false, version: 2, processed_at: T(2), next_check_at: T(-60), work_date: "2026-11-20" },
        ], error: null };
        return { data: [{ raw_event_id: 13, employee_id: "e1", status: "dismissed", flag_reasons: ["unauthenticated_source"], hold_reason: null, decided: true, version: 2, processed_at: T(1), next_check_at: null, work_date: "2026-11-20" }], error: null };
      case "biometric_raw_events_safe": return { data: [11, 12, 13, 14].map((id) => ({ id, device_id: "d1", import_batch_id: null, sync_run_id: 7, employee_device_code: id === 11 ? "999" : "102", device_local_time: "2026-11-20 09:00:00", device_timezone: "Asia/Kolkata", punch_at: T(1400), received_at: T(5), time_flags: [] })), error: null };
      default: return { data: null, error: { code: "42P01", message: `relation ${c.name} does not exist` } };
    }
  });
}

test("B4 live load: real records in the B2 shapes; raw punches only through the safe view; no payload function", async () => {
  const { sb, calls } = liveDb();
  const s = await loadLive(sb, people, [], NOW);
  assert.equal(s.devices.length, 2);
  assert.equal(s.devices[0]!.conn, "online");
  assert.equal(s.devices[1]!.disabled, true);
  assert.equal(s.devices[1]!.conn, "never");
  assert.equal(s.devices[0]!.connection.port, "4370");
  assert.equal(s.devices[0]!.createdBy, "Asha Rao");
  assert.equal(s.agents[0]!.status, "online");
  assert.equal(s.agents[0]!.queueDepth, null, "queue is not invented");
  assert.equal(s.mappingHistory.length, 2, "mapped + ended");
  assert.equal(s.syncs[0]!.unmatched, 1, "one punch of the run still unmatched");
  const kinds = Object.fromEntries(s.reviews.map((r) => [r.rawId, [r.kind, r.status]]));
  assert.deepEqual(kinds, { 11: ["unmatched", "open"], 12: ["correction_needed", "open"], 14: ["held", "open"], 13: ["flagged", "dismissed"] });
  const closed = s.reviews.find((r) => r.rawId === 13)!;
  assert.equal(closed.history.at(-1)!.action, "Dismiss");
  assert.match(closed.history.at(-1)!.by, /Asha Rao · HR/);
  assert.equal(closed.history.at(-1)!.note, "Visitor test");
  assert.equal(s.reviews.find((r) => r.rawId === 12)!.version, 3);
  assert.match(s.reviews.find((r) => r.rawId === 12)!.reason, /finished day open/);
  assert.match(s.reviews.find((r) => r.rawId === 14)!.reason, /approved leave/);
  assert.ok(Object.isFrozen(s.reviews[0]!.raw));
  const tables = new Set(calls.map((c) => c.name));
  assert.ok(!tables.has("biometric_raw_events"), "the raw table itself is never selected");
  assert.ok(!tables.has("biometric_agent_credentials"), "credentials are never read");
  assert.ok(!calls.some((c) => c.kind === "rpc"), "loading calls no function (no payload function)");
  assert.ok(!calls.some((c) => /payload|response|key_hash/.test(c.select ?? "")), "no payload, response or key column is selected");
});

test("B4 live load: a database without the biometric tables is reported, not shown as an error", async () => {
  const { sb } = fakeDb(() => ({ data: null, error: { code: "42P01", message: 'relation "biometric_agents" does not exist' } }));
  await assert.rejects(loadLive(sb, people, [], NOW), NotInstalled);
});

test("B4 live actions call only the checked database functions, with the punch version for reviews", async () => {
  const { sb, calls } = fakeDb(() => ({ data: { ok: true, device_id: "new-1" }, error: null }));
  const s: DemoState = { ...emptyState(), reviews: [{ id: "raw-12", kind: "extra", raw: Object.freeze({ deviceId: "d1", deviceSerial: "S", code: "1", deviceLocalTime: "", deviceTimezone: "", punchAt: "", receivedAt: "" }), reason: "", status: "open", history: [], rawId: 12, version: 5, employeeId: "e1" }] };
  assert.equal(await liveAction(sb, s, { type: "setDisabled", deviceId: "d1", disabled: true }), null);
  assert.equal(await liveAction(sb, s, { type: "setDirection", deviceId: "d1", direction: "device" }), null);
  assert.equal(await liveAction(sb, s, { type: "addMapping", code: " 101 ", deviceId: "d1", employeeId: "e1", validFrom: "2026-11-21T00:00:00Z" }), null);
  assert.equal(await liveAction(sb, s, { type: "endMapping", mappingId: "m1", at: "2026-11-21T00:00:00Z", reason: " Left the company " }), null);
  assert.equal(await liveAction(sb, s, { type: "review", reviewId: "raw-12", decision: "keep_extra", note: "" }), null);
  assert.deepEqual((await liveAddDevice(sb, { name: "Gate", manufacturer: "zkteco", model: "K40", serial: "SER9", officeId: "L1", method: "sdk_pull", agentId: "a1", direction: "first_last", connection: {} })).id, "new-1");
  assert.deepEqual(calls.map((c) => c.name), ["biometric_set_device_status", "biometric_set_direction_mode", "biometric_save_mapping", "biometric_end_mapping", "biometric_review_event", "biometric_save_device"]);
  assert.deepEqual(calls[0]!.args, { p_id: "d1", p_status: "disabled" });
  assert.deepEqual(calls[2]!.args, { p_code: "101", p_device: "d1", p_employee: "e1", p_valid_from: "2026-11-21T00:00:00Z", p_confirm_company_wide: false });
  assert.deepEqual(calls[3]!.args, { p_id: "m1", p_at: "2026-11-21T00:00:00Z", p_reason: "Left the company" });
  assert.deepEqual(calls[4]!.args, { p_raw: 12, p_action: "keep_extra", p_reason: null, p_expected_version: 5 });
  assert.ok(calls.every((c) => c.kind === "rpc"), "no direct table write");
});

test("B4 live actions: database refusals reach the screen as messages", async () => {
  const refused = fakeDb(() => ({ data: { ok: false, message: "This item changed since you opened it. Reload and decide again." }, error: null }));
  const s: DemoState = { ...emptyState(), reviews: [{ id: "raw-1", kind: "flagged", raw: Object.freeze({ deviceId: "", deviceSerial: "", code: "", deviceLocalTime: "", deviceTimezone: "", punchAt: "", receivedAt: "" }), reason: "", status: "open", history: [], rawId: 1, version: 1 }] };
  assert.match((await liveAction(refused.sb, s, { type: "review", reviewId: "raw-1", decision: "accept_time", note: "Checked CCTV" }))!, /changed since you opened it/);
  const denied = fakeDb(() => ({ data: null, error: { code: "42501", message: "Not allowed" } }));
  assert.match((await liveAction(denied.sb, s, { type: "setDisabled", deviceId: "d1", disabled: true }))!, /^Not allowed/);
  assert.match((await liveAction(denied.sb, s, { type: "review", reviewId: "missing", decision: "dismiss", note: "x" }))!, /no longer exists/);
});

test("B4 roles: Admin and HR use the module; HR cannot configure devices or company-wide codes; Manager and Employee have no access", () => {
  const roles: Role[] = ["admin", "hr", "manager", "employee"];
  const has = (r: Role) => navFor(r).some((g) => g.items.some((i) => i.href === "/biometric"));
  assert.deepEqual(roles.map(has), [true, true, false, false]);
  assert.deepEqual(roles.map((r) => can(r, "manageBiometricDevices")), [true, false, false, false]);
  assert.deepEqual(roles.map((r) => can(r, "mapBiometricCompanyWide")), [true, false, false, false]);
  assert.deepEqual(roles.map((r) => can(r, "mapBiometricCodes")), [true, true, false, false]);
  assert.deepEqual(roles.map((r) => can(r, "reviewBiometric")), [true, true, false, false]);
});

test("B4 privacy scan: no raw payload function, no raw table, no direct writes, no colours in the new code", () => {
  const files = [
    "../src/lib/biometric-live.ts", "../src/lib/sources.ts", "../src/components/DayTimeline.tsx", "../src/components/SourceBadges.tsx",
    ...readdirSync(join(__dirname, "../src/components/biometric")).map((f) => `../src/components/biometric/${f}`),
  ].map((f) => readFileSync(join(__dirname, f), "utf8").replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, ""));
  for (const src of files) {
    assert.doesNotMatch(src, /biometric_raw_payload|biometric_error_payload|raw_payload|agent_credentials|key_hash/, "no payload or credential access");
    assert.doesNotMatch(src, /from\("biometric_raw_events"\)/, "raw table only through the safe view");
    assert.doesNotMatch(src, /\.(insert|update|upsert|delete)\(/, "no direct table writes");
    assert.doesNotMatch(src, /fetch\(|WebSocket|XMLHttpRequest|EventSource/, "no other network calls");
    assert.doesNotMatch(src, /#[0-9a-fA-F]{3,8}\b/, "no hard-coded colours");
  }
});

/* ------------------------------------------------------------------ source badge contrast (WCAG AA ≥ 4.5:1), both themes */

/** Reads a theme's colour tokens and the .src-badge mix percentages from globals.css and works out the painted colours. */
function sourceBadgeContrast(): Record<"dark" | "light", Record<string, number>> {
  const css = readFileSync(join(__dirname, "../src/app/globals.css"), "utf8");
  const block = (sel: string) => css.slice(css.indexOf(sel)).split("}")[0]!;
  const tokens = (b: string) => Object.fromEntries([...b.matchAll(/--(color-[a-z0-9-]+):\s*(#[0-9a-f]{6})/gi)].map((m) => [m[1]!, m[2]!]));
  const dark = tokens(block(":root,"));
  const light = { ...dark, ...tokens(block('html[data-theme="light"] {')) };
  const rule = block(".badge.src-badge {");
  const fgPct = Number(/color:\s*color-mix\(in srgb, var\(--tone\) (\d+)%, var\(--color-text\)\)/.exec(rule)![1]) / 100;
  const bgPct = Number(/background:\s*color-mix\(in srgb, var\(--tone\) (\d+)%, var\(--color-surface\)\)/.exec(rule)![1]) / 100;
  const rgb = (h: string) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
  const mix = (a: number[], b: number[], p: number) => a.map((v, i) => v * p + b[i]! * (1 - p));
  const lum = (c: number[]) => { const [r, g, b] = c.map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r! + 0.7152 * g! + 0.0722 * b!; };
  const ratio = (a: number[], b: number[]) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  const TONE: Record<string, string> = { web: "color-text-muted", biometric: "color-info", import: "color-info", correction: "color-warning" };
  const out = {} as Record<"dark" | "light", Record<string, number>>;
  for (const [name, t] of [["dark", dark], ["light", light]] as const) {
    out[name] = Object.fromEntries(Object.entries(TONE).map(([src, tok]) => {
      const tone = rgb(t[tok]!);
      return [src, ratio(mix(tone, rgb(t["color-text"]!), fgPct), mix(tone, rgb(t["color-surface"]!), bgPct))];
    }));
  }
  return out;
}

test("B4 source badges meet WCAG AA (≥ 4.5:1) for Web, Biometric, Imported and Correction in dark and light themes", () => {
  const r = sourceBadgeContrast();
  for (const theme of ["dark", "light"] as const) {
    for (const src of ["web", "biometric", "import", "correction"]) assert.ok(r[theme][src]! >= 4.5, `${theme} ${src}: ${r[theme][src]!.toFixed(2)}:1`);
  }
  console.log("source badge contrast", JSON.stringify(Object.fromEntries(Object.entries(r).map(([k, v]) => [k, Object.fromEntries(Object.entries(v).map(([a, b]) => [a, Number(b.toFixed(2))]))]))));
});

test("B4 source badges: a marker shape per source (colour is not the only cue); status badges are not restyled", () => {
  const css = readFileSync(join(__dirname, "../src/app/globals.css"), "utf8");
  for (const s of ["web", "biometric", "correction"]) assert.match(css, new RegExp(`\\.src-${s} \\.badge-dot \\{[^}]+\\}`));
  assert.match(css, /\.src-import \.badge-dot/);
  assert.match(css, /\.badge\.src-badge\.src-import \{ border-style: dashed; \}/);
  assert.match(css, /\.metric-ic, \.badge \{ color: var\(--tone\); background: color-mix\(in srgb, var\(--tone\) calc\(var\(--tint-alpha\) \* 100%\), transparent\); \}/, "base badge rule unchanged");
  assert.match(css, /html\[data-theme="light"\] \.badge \{ filter: saturate\(1\.1\) brightness\(\.85\); \}/, "status badge light filter unchanged");
  const comp = readFileSync(join(__dirname, "../src/components/SourceBadges.tsx"), "utf8");
  assert.match(comp, /src-badge src-\$\{/);
});
