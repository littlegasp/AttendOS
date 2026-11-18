import { canSeeRegister, can, type Capability, type Role } from "./permissions";

export type IconName =
  | "dashboard"
  | "clock"
  | "register"
  | "people"
  | "leave"
  | "shift"
  | "holiday"
  | "report"
  | "analytics"
  | "department"
  | "shield"
  | "gear";

export interface NavItem {
  href: string;
  label: string;
  icon: IconName;
  /** Capability that decides whether the item is listed for a role. */
  cap: Capability | "register";
  /** Phase of the guide that builds the module's real content. */
  phase: number;
  /** One line shown in the page subtitle and in search. */
  blurb: string;
}

export interface NavGroup {
  label: string;
  items: NavItem[];
}

/** Primary navigation, grouped as in the guide (section 3). */
export const NAV: NavGroup[] = [
  {
    label: "Workspace",
    items: [
      { href: "/", label: "Dashboard", icon: "dashboard", cap: "dashboard", phase: 5, blurb: "Today's attendance at a glance" },
      { href: "/my-attendance", label: "My Attendance", icon: "clock", cap: "personalAttendance", phase: 2, blurb: "Check in and check out with location verification" },
      { href: "/attendance", label: "Attendance Register", icon: "register", cap: "register", phase: 3, blurb: "Daily and monthly attendance records" },
      { href: "/employees", label: "Employees", icon: "people", cap: "employees", phase: 3, blurb: "Employee directory and profiles" },
    ],
  },
  {
    label: "Management",
    items: [
      { href: "/leave", label: "Leave Management", icon: "leave", cap: "leave", phase: 4, blurb: "Leave requests, approvals and balances" },
      { href: "/shifts", label: "Shifts & Schedules", icon: "shift", cap: "shifts", phase: 4, blurb: "Work roster and shifts" },
      { href: "/holidays", label: "Holidays", icon: "holiday", cap: "holidays", phase: 4, blurb: "Holiday calendar" },
    ],
  },
  {
    label: "Insights",
    items: [
      { href: "/reports", label: "Reports", icon: "report", cap: "reports", phase: 5, blurb: "Attendance, leave and overtime reports" },
      { href: "/analytics", label: "Analytics", icon: "analytics", cap: "reports", phase: 5, blurb: "Trends and comparisons" },
    ],
  },
  {
    label: "Configuration",
    items: [
      { href: "/departments", label: "Departments", icon: "department", cap: "departments", phase: 3, blurb: "Departments and department heads" },
      { href: "/roles", label: "Roles & Permissions", icon: "shield", cap: "roles", phase: 5, blurb: "Who can see and do what" },
      { href: "/settings", label: "Settings", icon: "gear", cap: "settings", phase: 5, blurb: "Organization, attendance policy and GPS" },
    ],
  },
];

export const ALL_ITEMS: NavItem[] = NAV.flatMap((g) => g.items);

export function allowed(role: Role, item: NavItem): boolean {
  return item.cap === "register" ? canSeeRegister(role) : can(role, item.cap);
}

/** Navigation for one role: groups with no visible item are dropped. */
export function navFor(role: Role): NavGroup[] {
  return NAV.map((g) => ({ ...g, items: g.items.filter((i) => allowed(role, i)) })).filter((g) => g.items.length > 0);
}

export function normalise(path: string | null | undefined): string {
  return (path ?? "/").replace(/\.html$/, "").replace(/\/index$/, "/").replace(/\/$/, "") || "/";
}

export function itemFor(path: string): NavItem | undefined {
  const p = normalise(path);
  return ALL_ITEMS.find((i) => (i.href === "/" ? p === "/" : p === i.href || p.startsWith(i.href + "/")));
}

/** Search across menu items by label or description. */
export function searchNav(role: Role, q: string): NavItem[] {
  const t = q.trim().toLowerCase();
  const items = ALL_ITEMS.filter((i) => allowed(role, i));
  if (!t) return items;
  return items.filter((i) => i.label.toLowerCase().includes(t) || i.blurb.toLowerCase().includes(t));
}
