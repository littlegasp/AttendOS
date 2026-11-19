/** Turns audit_log rows into plain sentences for the Activity log. */

const LABELS: Record<string, string> = {
  full_name: "Name",
  email: "E-mail",
  emp_code: "Employee ID",
  phone: "Phone",
  role: "Role",
  active: "Access",
  department_id: "Department",
  designation_id: "Designation",
  manager_id: "Reporting manager",
  home_location_id: "Assigned office",
  default_shift_id: "Default shift",
  joining_date: "Joining date",
  employment_status: "Employment status",
  exit_date: "Exit date",
  name: "Name",
  code: "Code",
  head_id: "Department head",
  description: "Description",
  lat: "Latitude",
  lng: "Longitude",
  radius_m: "Area (m)",
  address: "Address",
  timezone: "Time zone",
  max_accuracy_m: "Accuracy limit (m)",
  remote_location_required: "Remote location required",
  default_work_mode: "Default work location",
  weekly_off: "Weekly days off",
  work_mode: "Work location",
  location_id: "Office",
  shift_id: "Shift",
  start_time: "Start",
  end_time: "End",
  break_minutes: "Break (min)",
  grace_minutes: "Grace (min)",
  day: "Date",
  start_date: "From",
  end_date: "To",
  reason: "Reason",
  status: "Status",
  decision_note: "Note",
  note: "Note",
};

const NOISE = new Set(["updated_at", "created_at", "set_at", "set_by", "decided_at", "decided_by", "requested_at", "company_id", "id", "user_id"]);

export const TARGET_LABEL: Record<string, string> = {
  employees: "Employee",
  departments: "Department",
  designations: "Designation",
  locations: "Office location",
  companies: "Company settings",
  shifts: "Shift",
  holidays: "Holiday",
  roster_pattern: "Weekly roster",
  roster_day: "Roster date",
  shift_pattern: "Weekly shift",
  shift_day: "Shift date",
  remote_exceptions: "Remote-work exception",
  attendance_corrections: "Attendance correction",
};

type Json = Record<string, unknown> | null;

function show(v: unknown, names: Record<string, string>): string {
  if (v === null || v === undefined || v === "") return "—";
  if (typeof v === "boolean") return v ? "On" : "Off";
  if (Array.isArray(v)) return v.join(", ");
  const s = String(v);
  return names[s] ?? s;
}

/** "Role: employee → manager" style changes; `names` turns ids into names where known. */
export function describeChanges(before: Json, after: Json, names: Record<string, string> = {}): string[] {
  const keys = new Set([...Object.keys(before ?? {}), ...Object.keys(after ?? {})]);
  const out: string[] = [];
  for (const k of keys) {
    if (NOISE.has(k)) continue;
    const a = before?.[k];
    const b = after?.[k];
    if (JSON.stringify(a) === JSON.stringify(b)) continue;
    const label = LABELS[k] ?? k.replace(/_/g, " ");
    if (!before) {
      if (b === null || b === undefined || b === "" || b === false) continue;
      out.push(`${label}: ${show(b, names)}`);
    } else if (!after) out.push(`${label}: ${show(a, names)}`);
    else out.push(`${label}: ${show(a, names)} → ${show(b, names)}`);
  }
  return out;
}

/** The name of the record an entry is about. */
export function subjectOf(before: Json, after: Json, names: Record<string, string>): string {
  const r = (after ?? before ?? {}) as Record<string, unknown>;
  if (typeof r.full_name === "string") return r.full_name;
  if (typeof r.name === "string") return r.name;
  if (typeof r.employee_id === "string") return names[r.employee_id] ?? "Someone";
  return "";
}
