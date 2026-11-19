/**
 * The role access matrix from the AttendOS guide (section 3), kept as data so a new
 * role can be added here without touching any screen.
 *
 * IMPORTANT: this file only decides what the interface shows. From Phase 2 the same
 * matrix is enforced in the database (row level security + checked functions), and the
 * browser is never trusted on its own.
 */

export type Role = "admin" | "hr" | "manager" | "employee";

/** How much of a capability a role gets. "none" means the screen shows Permission denied. */
export type Scope = "none" | "own" | "team" | "configured" | "limited" | "all";

export type Capability =
  | "dashboard"
  | "personalAttendance"
  | "allAttendance"
  | "teamAttendance"
  | "employees"
  | "leave"
  | "shifts"
  | "holidays"
  | "reports"
  | "departments"
  | "settings"
  | "roles"
  | "manageLocations"
  | "editPolicy"
  | "manageShifts"
  | "approveCorrections"
  | "verificationHistory"
  | "manageEmployees"
  | "assignRoles"
  | "viewAudit";

export const ROLES: { id: Role; label: string }[] = [
  { id: "admin", label: "Admin" },
  { id: "hr", label: "HR" },
  { id: "manager", label: "Manager" },
  { id: "employee", label: "Employee" },
];

export const MATRIX: Record<Capability, Record<Role, Scope>> = {
  dashboard: { admin: "all", hr: "configured", manager: "team", employee: "own" },
  personalAttendance: { admin: "own", hr: "own", manager: "own", employee: "own" },
  allAttendance: { admin: "all", hr: "all", manager: "none", employee: "none" },
  teamAttendance: { admin: "all", hr: "all", manager: "team", employee: "none" },
  employees: { admin: "all", hr: "all", manager: "team", employee: "own" },
  leave: { admin: "all", hr: "all", manager: "team", employee: "own" },
  shifts: { admin: "all", hr: "configured", manager: "team", employee: "own" },
  holidays: { admin: "all", hr: "all", manager: "own", employee: "own" },
  reports: { admin: "all", hr: "configured", manager: "team", employee: "own" },
  departments: { admin: "all", hr: "limited", manager: "none", employee: "none" },
  settings: { admin: "all", hr: "limited", manager: "none", employee: "none" },
  roles: { admin: "all", hr: "none", manager: "none", employee: "none" },
  // Finer rules inside Settings and attendance (mirrored by the database):
  manageLocations: { admin: "all", hr: "all", manager: "none", employee: "none" }, // offices, assigned office, remote exceptions
  editPolicy: { admin: "all", hr: "none", manager: "none", employee: "none" }, // company-wide attendance rules
  manageShifts: { admin: "all", hr: "all", manager: "none", employee: "none" }, // shifts, roster, holidays
  approveCorrections: { admin: "all", hr: "all", manager: "team", employee: "none" },
  verificationHistory: { admin: "all", hr: "all", manager: "none", employee: "none" },
  manageEmployees: { admin: "all", hr: "all", manager: "none", employee: "none" }, // add/edit people, departments, designations
  assignRoles: { admin: "all", hr: "none", manager: "none", employee: "none" },
  viewAudit: { admin: "all", hr: "all", manager: "none", employee: "none" },
};

export function scopeOf(role: Role, cap: Capability): Scope {
  return MATRIX[cap][role];
}

export function can(role: Role, cap: Capability): boolean {
  return scopeOf(role, cap) !== "none";
}

/** The Attendance Register shows either every record or the assigned team. */
export function canSeeRegister(role: Role): boolean {
  return can(role, "allAttendance") || can(role, "teamAttendance");
}

export const SCOPE_LABEL: Record<Scope, string> = {
  none: "No access",
  own: "Personal",
  team: "Assigned team",
  configured: "As configured",
  limited: "Limited",
  all: "Organization",
};

export function roleLabel(role: Role): string {
  return ROLES.find((r) => r.id === role)?.label ?? role;
}
