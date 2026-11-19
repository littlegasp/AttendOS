"use client";

import { useState } from "react";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { HistoryPanel } from "@/components/HistoryPanel";
import { Modal } from "@/components/Modal";
import { EmptyState, ErrorState, LoadingState } from "@/components/States";
import { Button, FormSelect, GlassCard, SectionCard, StatusBadge } from "@/components/ui";
import { describeChanges } from "@/lib/audit";
import { ROLE_HELP, initials, statusLabel, type Employee } from "@/lib/employees";
import { can, ROLES, roleLabel, type Role } from "@/lib/permissions";
import { useSession } from "@/lib/session";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";
import { must, useLoad } from "@/lib/use-load";
import { shortDay } from "./EmployeeDirectory";
import { EmployeeFormModal } from "./EmployeeFormModal";
import { EMP_SELECT, type Lookups } from "./lookups";

interface AuditRow {
  id: number;
  at: string;
  action: string;
  actor_employee: string | null;
  before: Record<string, unknown> | null;
  after: Record<string, unknown> | null;
}

export function EmployeeProfile({ id, lookups, onBack, onChanged }: { id: string; lookups: Lookups; onBack: () => void; onChanged: () => void }) {
  const { role, employeeId, company } = useSession();
  const manage = can(role, "manageEmployees");
  const isAdmin = can(role, "assignRoles");
  const [edit, setEdit] = useState(false);
  const [roleOpen, setRoleOpen] = useState(false);
  const [toggle, setToggle] = useState(false);
  const [busy, setBusy] = useState(false);
  const [bump, setBump] = useState(0);

  const { data, error, reload } = useLoad(async () => {
    const sb = supabase();
    const emp = must(await sb.from("employees").select(EMP_SELECT).eq("id", id).maybeSingle()) as unknown as Employee | null;
    const reports = must(await sb.from("employees").select("id, full_name, emp_code, active").eq("manager_id", id).order("full_name")) as { id: string; full_name: string; emp_code: string | null; active: boolean }[];
    const audit = manage
      ? (must(await sb.from("audit_log").select("id, at, action, actor_employee, before, after").eq("target", "employees").eq("target_id", id).order("at", { ascending: false }).limit(15)) as AuditRow[])
      : [];
    return { emp, reports, audit };
  }, `${id}:${bump}`);

  if (error) return <GlassCard><ErrorState title="Couldn't load this person" body={error} onRetry={reload} /></GlassCard>;
  if (!data) return <LoadingState label="Loading profile" />;
  const e = data.emp;
  if (!e) {
    return (
      <GlassCard>
        <EmptyState title="This person isn't available" body="They may be outside your team, or the link is wrong." action={<Button onClick={onBack}>Back to people</Button>} />
      </GlassCard>
    );
  }

  const self = e.id === employeeId;
  const protectedAccount = (e.role === "admin" || e.role === "hr") && !isAdmin;
  const names: Record<string, string> = Object.fromEntries([
    ...lookups.people.map((p) => [p.id, p.full_name] as const),
    ...lookups.departments.map((d) => [d.id, d.name] as const),
    ...lookups.designations.map((d) => [d.id, d.name] as const),
    ...lookups.locations.map((d) => [d.id, d.name] as const),
    ...lookups.shifts.map((d) => [d.id, d.name] as const),
  ]);
  const shift = lookups.shifts.find((s) => s.id === e.default_shift_id);
  const after = () => {
    setBump((b) => b + 1);
    onChanged();
  };

  async function setActive(on: boolean) {
    setBusy(true);
    const patch = on && e!.employment_status === "exited" ? { active: true, employment_status: "confirmed", exit_date: null } : { active: on };
    const { error: err } = await supabase().from("employees").update(patch).eq("id", e!.id);
    setBusy(false);
    setToggle(false);
    if (err) return toast({ tone: "danger", title: "Not changed", body: /last active administrator/i.test(err.message) ? "This is the company's last active administrator." : /Admin or HR/i.test(err.message) ? "Only an administrator can switch off an Admin or HR account." : friendlyError(err) });
    toast({ tone: on ? "success" : "info", title: on ? "Access switched on" : "Access switched off", body: e!.full_name });
    after();
  }

  return (
    <>
      <button type="button" className="link-btn back-link" onClick={onBack}>‹ All people</button>
      <GlassCard className="profile-head-card">
        <span className="avatar xl" aria-hidden="true">{initials(e.full_name)}</span>
        <div className="ph-main">
          <h2 className="section-title">{e.full_name}</h2>
          <p className="meta">
            {[e.emp_code, e.designation?.name, e.department?.name].filter(Boolean).join(" · ") || "No department yet"}
          </p>
          <div className="row ph-badges">
            {e.active ? <StatusBadge status="verified" label="Active" /> : <StatusBadge status="failed" label="Deactivated" />}
            <StatusBadge status={e.employment_status === "probation" || e.employment_status === "notice_period" ? "pending" : e.employment_status === "exited" ? "failed" : "approved"} label={statusLabel(e.employment_status)} />
            <span className="role-tag">{roleLabel(e.role)}</span>
            {e.user_id ? <StatusBadge status="present" label="Login linked" /> : <StatusBadge status="weekly-off" label="No login yet" />}
          </div>
        </div>
        {manage ? (
          <div className="ph-actions">
            <Button onClick={() => setEdit(true)}>Edit details</Button>
            {isAdmin && !self ? <Button onClick={() => setRoleOpen(true)}>Change role</Button> : null}
            {!self && !protectedAccount ? (
              e.active ? <Button variant="danger" onClick={() => setToggle(true)}>Deactivate</Button> : <Button variant="primary" onClick={() => setToggle(true)}>Reactivate</Button>
            ) : null}
          </div>
        ) : null}
      </GlassCard>

      <div className="grid-2">
        <SectionCard title="Work details">
          <dl className="rules-view">
            <dt>Employee ID</dt><dd className="mono">{e.emp_code ?? "—"}</dd>
            <dt>Department</dt><dd>{e.department?.name ?? "—"}</dd>
            <dt>Designation</dt><dd>{e.designation?.name ?? "—"}</dd>
            <dt>Reporting manager</dt><dd>{e.manager?.full_name ?? "—"}</dd>
            <dt>Assigned office</dt><dd>{e.office?.name ?? "Any company office"}</dd>
            <dt>Default shift</dt><dd>{shift ? `${shift.name} · ${shift.start_time.slice(0, 5)}–${shift.end_time.slice(0, 5)}` : "Company default"}</dd>
            <dt>Joining date</dt><dd>{shortDay(e.joining_date)}</dd>
            <dt>Employment</dt><dd>{statusLabel(e.employment_status)}{e.exit_date ? ` · ${e.employment_status === "notice_period" ? "last day" : "left"} ${shortDay(e.exit_date)}` : ""}</dd>
          </dl>
        </SectionCard>
        <div className="stack">
          <SectionCard title="Contact & sign-in">
            <dl className="rules-view">
              <dt>Work e-mail</dt><dd>{e.email}</dd>
              <dt>Phone</dt><dd>{e.phone ?? "—"}</dd>
              <dt>Role</dt><dd>{roleLabel(e.role)} <span className="meta block">{ROLE_HELP[e.role]}</span></dd>
              <dt>Sign-in</dt>
              <dd>
                {e.user_id
                  ? "Signs in with this e-mail."
                  : `Not yet. They get access once they sign up${company ? ` at the ${company.name} sign-in page` : ""} with this e-mail and confirm it.`}
              </dd>
            </dl>
          </SectionCard>
          <SectionCard title="Direct reports" subtitle={`${data.reports.filter((r) => r.active).length} active`}>
            {data.reports.length === 0 ? (
              <p className="meta">No one reports to {self ? "you" : e.full_name.split(" ")[0]}.</p>
            ) : (
              <ul className="people-list">
                {data.reports.map((r) => (
                  <li key={r.id}>
                    <span className="avatar sm" aria-hidden="true">{initials(r.full_name)}</span>
                    <span className="pl-main"><strong>{r.full_name}</strong><span className="meta block">{r.emp_code ?? ""}</span></span>
                    {!r.active ? <StatusBadge status="failed" label="Deactivated" /> : null}
                  </li>
                ))}
              </ul>
            )}
            {!e.active && data.reports.some((r) => r.active) && manage ? (
              <p className="alert warning small">This person is deactivated but still has active direct reports. Give them a new reporting manager.</p>
            ) : null}
          </SectionCard>
        </div>
      </div>

      <HistoryPanel employeeId={e.id} tz={company?.timezone ?? "Asia/Kolkata"} days={14} canRequest={false} />

      {manage ? (
        <SectionCard title="Change history" subtitle="Who changed this record, and what changed">
          {data.audit.length === 0 ? (
            <p className="meta">No changes recorded yet.</p>
          ) : (
            <ul className="audit-list">
              {data.audit.map((a) => {
                const lines = describeChanges(a.before, a.after, names);
                const who = a.actor_employee ? names[a.actor_employee] : undefined;
                return (
                  <li key={a.id}>
                    <span className="meta audit-when">{new Date(a.at).toLocaleString("en-IN", { timeZone: company?.timezone, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })}</span>
                    <span>
                      <strong>{a.action === "insert" ? "Added" : "Updated"}</strong>
                      {who ? <span className="meta"> by {who}</span> : null}
                      <span className="meta block">{lines.length ? lines.join(" · ") : "No visible change"}</span>
                    </span>
                  </li>
                );
              })}
            </ul>
          )}
        </SectionCard>
      ) : null}

      {edit ? <EmployeeFormModal employee={e} lookups={lookups} onClose={() => setEdit(false)} onSaved={() => { setEdit(false); after(); }} /> : null}
      {roleOpen ? <RoleModal emp={e} onClose={() => setRoleOpen(false)} onSaved={() => { setRoleOpen(false); after(); }} /> : null}
      <ConfirmDialog
        open={toggle}
        danger={e.active}
        busy={busy}
        title={e.active ? `Deactivate ${e.full_name}?` : `Reactivate ${e.full_name}?`}
        consequence={
          e.active ? (
            <p>They can no longer sign in or check in. Their attendance history is kept, and you can reactivate them later. {data.reports.some((r) => r.active) ? "They still have active direct reports — reassign them afterwards." : ""}</p>
          ) : (
            <p>They can sign in and check in again.{e.employment_status === "exited" ? " Their employment status goes back to Confirmed." : ""}</p>
          )
        }
        confirmLabel={e.active ? "Deactivate" : "Reactivate"}
        onCancel={() => setToggle(false)}
        onConfirm={() => setActive(!e.active)}
      />
    </>
  );
}

function RoleModal({ emp, onClose, onSaved }: { emp: Employee; onClose: () => void; onSaved: () => void }) {
  const [r, setR] = useState<Role>(emp.role);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    setBusy(true);
    setErr(null);
    const { error } = await supabase().from("employees").update({ role: r }).eq("id", emp.id);
    setBusy(false);
    if (error) return setErr(/last active administrator/i.test(error.message) ? "This is the company's last active administrator. Make someone else Admin first." : friendlyError(error));
    toast({ tone: "success", title: "Role changed", body: `${emp.full_name} is now ${roleLabel(r)}` });
    onSaved();
  }
  return (
    <Modal open title={`Role · ${emp.full_name}`} subtitle="Only administrators can change roles. The change is logged." onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <FormSelect label="Role" value={r} onChange={(e) => setR(e.target.value as Role)} options={ROLES.map((x) => ({ value: x.id, label: x.label }))} helper={ROLE_HELP[r]} />
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} disabled={r === emp.role} onClick={save}>Change role</Button>
        </div>
      </div>
    </Modal>
  );
}
