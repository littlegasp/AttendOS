"use client";

import { useState } from "react";
import { Modal } from "@/components/Modal";
import { Button, FormInput, FormSelect } from "@/components/ui";
import { EMPLOYMENT_STATUS, EMPTY_FORM, toRow, validateEmployee, type Employee, type EmployeeForm } from "@/lib/employees";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";
import type { Lookups } from "./lookups";

const fromEmployee = (e: Employee): EmployeeForm => ({
  full_name: e.full_name,
  email: e.email,
  emp_code: e.emp_code ?? "",
  phone: e.phone ?? "",
  joining_date: e.joining_date ?? "",
  department_id: e.department_id ?? "",
  designation_id: e.designation_id ?? "",
  manager_id: e.manager_id ?? "",
  home_location_id: e.home_location_id ?? "",
  default_shift_id: e.default_shift_id ?? "",
  employment_status: e.employment_status,
  exit_date: e.exit_date ?? "",
});

/** Turns database refusals into something HR can act on. */
function explain(msg: string): string {
  if (/employees_email_key|duplicate key.*email/i.test(msg)) return "Someone already uses that e-mail address.";
  if (/employees_company_code_key/i.test(msg)) return "That employee ID is already used in your company.";
  if (/loop/i.test(msg)) return "That reporting manager would create a loop (they report, directly or not, to this person).";
  if (/active employee/i.test(msg)) return "The reporting manager must be an active employee.";
  if (/linked to a login/i.test(msg)) return "This person already signs in with that e-mail, so it can't be changed here.";
  if (/Admin or HR account/i.test(msg)) return "Only an administrator can change the e-mail or access of an Admin or HR account.";
  return friendlyError({ message: msg });
}

export function EmployeeFormModal({ employee, lookups, onClose, onSaved }: { employee: Employee | null; lookups: Lookups; onClose: () => void; onSaved: (id: string) => void }) {
  const [f, setF] = useState<EmployeeForm>(employee ? fromEmployee(employee) : EMPTY_FORM);
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const errors = validateEmployee(f, employee?.id);
  const set = (k: keyof EmployeeForm) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF((x) => ({ ...x, [k]: e.target.value }));
  const show = (k: keyof EmployeeForm) => (tried ? errors[k] : undefined);
  const linked = Boolean(employee?.user_id);
  const opts = <T extends { id: string; name: string; active: boolean }>(rows: T[], current: string, none: string) => [
    { value: "", label: none },
    ...rows.filter((r) => r.active || r.id === current).map((r) => ({ value: r.id, label: r.active ? r.name : `${r.name} (not in use)` })),
  ];

  async function save() {
    setTried(true);
    if (Object.keys(errors).length) return;
    setBusy(true);
    setErr(null);
    const row = toRow(f);
    const sb = supabase();
    const res = employee
      ? await sb.from("employees").update(linked ? { ...row, email: undefined } : row).eq("id", employee.id).select("id").single()
      : await sb.from("employees").insert(row).select("id, emp_code").single();
    setBusy(false);
    if (res.error) return setErr(explain(res.error.message));
    const saved = res.data as { id: string; emp_code?: string };
    toast({ tone: "success", title: employee ? "Employee updated" : "Employee added", body: employee ? row.full_name : `${row.full_name} · ${saved.emp_code ?? ""}`.trim() });
    onSaved(saved.id);
  }

  return (
    <Modal open wide title={employee ? `Edit ${employee.full_name}` : "Add employee"} subtitle={employee ? undefined : "They get access when they sign up or accept an invite with this e-mail. Role starts as Employee."} onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <fieldset className="modal-section">
          <legend>Person</legend>
          <div className="form-2">
            <FormInput label="Full name" required value={f.full_name} onChange={set("full_name")} error={show("full_name")} maxLength={120} autoComplete="off" />
            <FormInput label="Employee ID" value={f.emp_code} onChange={set("emp_code")} error={show("emp_code")} helper={employee ? undefined : "Leave empty to use the next number (E0001…)."} maxLength={20} />
          </div>
          <div className="form-2">
            <FormInput
              label="Work e-mail"
              type="email"
              required
              value={f.email}
              onChange={set("email")}
              error={show("email")}
              disabled={linked}
              helper={linked ? "Linked to their login, so it can't be changed here." : "Used to sign in. Must be unique."}
            />
            <FormInput label="Phone" type="tel" value={f.phone} onChange={set("phone")} error={show("phone")} />
          </div>
        </fieldset>
        <fieldset className="modal-section">
          <legend>Work</legend>
          <div className="form-2">
            <FormSelect label="Department" value={f.department_id} onChange={set("department_id")} options={opts(lookups.departments, f.department_id, "No department")} />
            <FormSelect label="Designation" value={f.designation_id} onChange={set("designation_id")} options={opts(lookups.designations, f.designation_id, "No designation")} />
          </div>
          <div className="form-2">
            <FormSelect
              label="Reporting manager"
              value={f.manager_id}
              onChange={set("manager_id")}
              error={show("manager_id")}
              options={[
                { value: "", label: "No reporting manager" },
                ...lookups.people.filter((p) => p.active && p.id !== employee?.id).map((p) => ({ value: p.id, label: `${p.full_name}${p.emp_code ? ` · ${p.emp_code}` : ""}${p.role === "manager" ? "" : ` (${p.role})`}` })),
              ]}
              helper="Approvals and the team dashboard go to people with the Manager role."
            />
            <FormInput label="Joining date" type="date" value={f.joining_date} onChange={set("joining_date")} helper="Days before it aren't counted as absent." />
          </div>
          <div className="form-2">
            <FormSelect label="Assigned office" value={f.home_location_id} onChange={set("home_location_id")} options={opts(lookups.locations, f.home_location_id, "Any office")} />
            <FormSelect
              label="Default shift"
              value={f.default_shift_id}
              onChange={set("default_shift_id")}
              options={[
                { value: "", label: "Company default" },
                ...lookups.shifts.filter((s) => s.active || s.id === f.default_shift_id).map((s) => ({ value: s.id, label: `${s.name} · ${s.start_time.slice(0, 5)}–${s.end_time.slice(0, 5)}` })),
              ]}
            />
          </div>
          <div className="form-2">
            <FormSelect label="Employment status" value={f.employment_status} onChange={set("employment_status")} options={EMPLOYMENT_STATUS} helper={f.employment_status === "exited" ? "Saving as Exited switches off their access." : undefined} />
            {f.employment_status === "exited" || f.employment_status === "notice_period" || f.exit_date ? (
              <FormInput label={f.employment_status === "notice_period" ? "Last working day" : "Exit date"} type="date" value={f.exit_date} onChange={set("exit_date")} error={show("exit_date")} />
            ) : (
              <span />
            )}
          </div>
        </fieldset>
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} onClick={save}>{employee ? "Save changes" : "Add employee"}</Button>
        </div>
      </div>
    </Modal>
  );
}
