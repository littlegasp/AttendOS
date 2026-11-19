/**
 * Employee management helpers shared by the screens and tests. The database enforces every
 * rule here again (and more); these only give people a clear message before they save.
 */
import type { Role } from "./permissions";

export type EmploymentStatus = "probation" | "confirmed" | "contract" | "intern" | "notice_period" | "exited";

export const EMPLOYMENT_STATUS: { value: EmploymentStatus; label: string }[] = [
  { value: "probation", label: "Probation" },
  { value: "confirmed", label: "Confirmed" },
  { value: "contract", label: "Contract" },
  { value: "intern", label: "Intern" },
  { value: "notice_period", label: "Notice period" },
  { value: "exited", label: "Exited" },
];

export const statusLabel = (s: EmploymentStatus) => EMPLOYMENT_STATUS.find((x) => x.value === s)?.label ?? s;

export const ROLE_HELP: Record<Role, string> = {
  admin: "Full control of the company, including roles and company rules",
  hr: "Manages people, roster, offices, shifts and corrections",
  manager: "Sees and approves for their direct reports",
  employee: "Own attendance, history and corrections",
};

export interface Employee {
  id: string;
  emp_code: string | null;
  full_name: string;
  email: string;
  phone: string | null;
  role: Role;
  active: boolean;
  user_id: string | null;
  department_id: string | null;
  designation_id: string | null;
  manager_id: string | null;
  home_location_id: string | null;
  default_shift_id: string | null;
  joining_date: string | null;
  employment_status: EmploymentStatus;
  exit_date: string | null;
  created_at: string;
  department?: { name: string } | null;
  designation?: { name: string } | null;
  office?: { name: string } | null;
  manager?: { full_name: string } | null;
}

export interface EmployeeForm {
  full_name: string;
  email: string;
  emp_code: string;
  phone: string;
  joining_date: string;
  department_id: string;
  designation_id: string;
  manager_id: string;
  home_location_id: string;
  default_shift_id: string;
  employment_status: EmploymentStatus;
  exit_date: string;
}

export const EMPTY_FORM: EmployeeForm = {
  full_name: "",
  email: "",
  emp_code: "",
  phone: "",
  joining_date: "",
  department_id: "",
  designation_id: "",
  manager_id: "",
  home_location_id: "",
  default_shift_id: "",
  employment_status: "probation",
  exit_date: "",
};

/** Field errors shown under the inputs (the database repeats these checks). */
/** Today's date (YYYY-MM-DD) in the company's time zone. */
export function todayIn(timeZone: string, now = Date.now()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(now));
}

/**
 * Whether the person can sign in, as the database decides it (my_employee_id): active, and the last
 * working day (if set) not yet passed in the company's time zone.
 */
export function accessState(e: Pick<Employee, "active" | "exit_date">, today: string): "active" | "off" | "ended" {
  if (!e.active) return "off";
  if (e.exit_date && e.exit_date < today) return "ended";
  return "active";
}

export function validateEmployee(f: EmployeeForm, selfId?: string, today?: string): Partial<Record<keyof EmployeeForm, string>> {
  const e: Partial<Record<keyof EmployeeForm, string>> = {};
  if (f.full_name.trim().length < 2) e.full_name = "Enter the full name (at least 2 characters).";
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(f.email.trim())) e.email = "Enter a valid work e-mail.";
  if (f.phone && !/^[0-9+ ()-]{6,20}$/.test(f.phone.trim())) e.phone = "Use digits, spaces, + ( ) or - (6–20 characters).";
  if (f.emp_code && !/^[A-Za-z0-9-]{1,20}$/.test(f.emp_code.trim())) e.emp_code = "Letters, digits and - only (up to 20).";
  if (selfId && f.manager_id === selfId) e.manager_id = "Someone can't report to themselves.";
  if (f.exit_date && f.joining_date && f.exit_date < f.joining_date) e.exit_date = "The exit date can't be before the joining date.";
  else if (today && f.employment_status === "exited" && f.exit_date && f.exit_date > today)
    e.exit_date = "Exited can't have a future date. Use “Notice period” with the last working day instead.";
  return e;
}

/** Row for insert/update: empty strings become nulls; the ID is left to the database when blank. */
export function toRow(f: EmployeeForm) {
  const n = (v: string) => (v.trim() ? v.trim() : null);
  return {
    full_name: f.full_name.trim(),
    email: f.email.trim().toLowerCase(),
    emp_code: n(f.emp_code),
    phone: n(f.phone),
    joining_date: n(f.joining_date),
    department_id: n(f.department_id),
    designation_id: n(f.designation_id),
    manager_id: n(f.manager_id),
    home_location_id: n(f.home_location_id),
    default_shift_id: n(f.default_shift_id),
    employment_status: f.employment_status,
    exit_date: n(f.exit_date),
  };
}

export interface Filters {
  q: string;
  department: string;
  designation: string;
  office: string;
  status: string;
  access: "active" | "inactive" | "all";
  role: string;
}

export const NO_FILTERS: Filters = { q: "", department: "", designation: "", office: "", status: "", access: "active", role: "" };

/** Search text made safe for a PostgREST `or=(…ilike…)` filter. */
export function searchPattern(q: string): string | null {
  const t = q.trim().replace(/[,()*%\\:]/g, " ").replace(/\s+/g, " ").trim();
  return t ? `*${t}*` : null;
}

/** Which PostgREST filters a set of directory filters becomes. */
export function filterOps(f: Filters): { op: "eq" | "or"; col: string; value: string | boolean }[] {
  const ops: { op: "eq" | "or"; col: string; value: string | boolean }[] = [];
  const p = searchPattern(f.q);
  if (p) ops.push({ op: "or", col: "", value: `full_name.ilike.${p},email.ilike.${p},emp_code.ilike.${p},phone.ilike.${p}` });
  if (f.department) ops.push({ op: "eq", col: "department_id", value: f.department });
  if (f.designation) ops.push({ op: "eq", col: "designation_id", value: f.designation });
  if (f.office) ops.push({ op: "eq", col: "home_location_id", value: f.office });
  if (f.status) ops.push({ op: "eq", col: "employment_status", value: f.status });
  if (f.role) ops.push({ op: "eq", col: "role", value: f.role });
  if (f.access !== "all") ops.push({ op: "eq", col: "active", value: f.access === "active" });
  return ops;
}

export function initials(name: string) {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((p) => p[0]!.toUpperCase())
    .join("");
}
