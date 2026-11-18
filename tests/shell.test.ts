import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { ALL_ITEMS, NAV, itemFor, navFor, searchNav } from "../src/lib/nav";
import { MATRIX, ROLES, can, canSeeRegister } from "../src/lib/permissions";

const root = join(__dirname, "..");

test("every menu item has a route that shares the shell", () => {
  for (const it of ALL_ITEMS) {
    const file = it.href === "/" ? "src/app/page.tsx" : `src/app${it.href}/page.tsx`;
    assert.ok(existsSync(join(root, file)), `missing ${file}`);
  }
});

test("navigation groups match the guide", () => {
  assert.deepEqual(NAV.map((g) => g.label), ["Workspace", "Management", "Insights", "Configuration"]);
  assert.equal(ALL_ITEMS.length, 12);
});

test("role matrix follows the guide", () => {
  assert.ok(can("admin", "roles"));
  for (const r of ["hr", "manager", "employee"] as const) assert.equal(can(r, "roles"), false);
  assert.equal(can("manager", "settings"), false);
  assert.equal(can("employee", "settings"), false);
  assert.equal(MATRIX.settings.hr, "limited");
  assert.equal(MATRIX.allAttendance.manager, "none");
  assert.equal(MATRIX.teamAttendance.manager, "team");
  assert.equal(canSeeRegister("manager"), true);
  assert.equal(canSeeRegister("employee"), false);
  for (const r of ROLES) assert.ok(can(r.id, "personalAttendance"), `${r.id} must reach My Attendance`);
});

test("employees only see their own screens in the menu", () => {
  const hrefs = navFor("employee").flatMap((g) => g.items.map((i) => i.href));
  for (const hidden of ["/attendance", "/departments", "/roles", "/settings"]) assert.ok(!hrefs.includes(hidden), hidden);
  assert.ok(hrefs.includes("/my-attendance"));
  assert.equal(navFor("employee").some((g) => g.label === "Configuration"), false, "empty groups are dropped");
});

test("search only returns screens the role may open", () => {
  assert.equal(searchNav("employee", "roles").length, 0);
  assert.equal(searchNav("admin", "roles")[0]?.href, "/roles");
  assert.ok(searchNav("admin", "check in").some((i) => i.href === "/my-attendance"));
});

test("active item resolves for nested paths", () => {
  assert.equal(itemFor("/")?.href, "/");
  assert.equal(itemFor("/employees/42")?.href, "/employees");
  assert.equal(itemFor("/settings/")?.href, "/settings");
  assert.equal(itemFor("/roles.html")?.href, "/roles");
});

test("components use semantic tokens, not hard-coded colours", () => {
  const dir = join(root, "src/components");
  const files = ["ui.tsx", "AppShell.tsx", "AppHeader.tsx", "AppSidebar.tsx", "States.tsx", "Toaster.tsx", "ConfirmDialog.tsx"];
  for (const f of files) {
    const src = readFileSync(join(dir, f), "utf8");
    assert.equal(/#[0-9a-fA-F]{3,8}\b/.test(src), false, `${f} contains a hex colour`);
  }
});

test("both themes define every token", () => {
  const css = readFileSync(join(root, "src/app/globals.css"), "utf8");
  const block = (sel: string) => css.slice(css.indexOf(sel), css.indexOf("}", css.indexOf(sel)));
  const dark = block('html[data-theme="dark"]');
  const light = block('html[data-theme="light"]');
  const names = [...dark.matchAll(/(--[\w-]+):/g)].map((m) => m[1]);
  assert.ok(names.length >= 14);
  for (const n of names) assert.ok(light.includes(`${n}:`), `light theme misses ${n}`);
});

test("geolocation is allowed for this site only", () => {
  const h = readFileSync(join(root, "public/_headers"), "utf8");
  assert.match(h, /geolocation=\(self\)/);
});
