"use client";

import { useState } from "react";
import { NavIcon } from "@/components/Icons";
import { Modal } from "@/components/Modal";
import { ModulePage } from "@/components/ModulePage";
import { EmptyState, ErrorState, LoadingState } from "@/components/States";
import { Tabs } from "@/components/Tabs";
import { Button, FormInput, FormSelect, FormTextarea, GlassCard, SectionCard, StatusBadge } from "@/components/ui";
import { can } from "@/lib/permissions";
import { useSession } from "@/lib/session";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";
import { must, useLoad } from "@/lib/use-load";

interface Dept {
  id: string;
  name: string;
  code: string | null;
  description: string | null;
  head_id: string | null;
  active: boolean;
  head?: { full_name: string } | null;
}
interface Desig {
  id: string;
  name: string;
  active: boolean;
}
interface Person {
  id: string;
  full_name: string;
  emp_code: string | null;
  department_id: string | null;
  active: boolean;
}

type Tab = "departments" | "designations";

export default function DepartmentsPage() {
  const { preview } = useSession();
  const [tab, setTab] = useState<Tab>("departments");
  return (
    <ModulePage href="/departments">
      <Tabs label="Organisation structure" value={tab} onChange={setTab} tabs={[{ id: "departments", label: "Departments" }, { id: "designations", label: "Designations" }]} />
      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} className="tab-panel">
        {preview ? (
          <GlassCard>
            <EmptyState icon={<NavIcon name="department" />} title="Departments need the company database" body="Once connected, HR keeps departments (with a head) and designations here; people are placed in them from their profile." />
          </GlassCard>
        ) : (
          <Structure tab={tab} />
        )}
      </div>
    </ModulePage>
  );
}

function Structure({ tab }: { tab: Tab }) {
  const { role } = useSession();
  const manage = can(role, "manageEmployees");
  const { data, error, reload } = useLoad(async () => {
    const sb = supabase();
    const [depts, desigs, people, counts] = await Promise.all([
      sb.from("departments").select("id, name, code, description, head_id, active, head:employees!departments_head_id_fkey(full_name)").order("name").then((r) => must(r) as unknown as Dept[]),
      sb.from("designations").select("id, name, active").order("name").then(must<Desig[]>),
      sb.rpc("people_directory").then(must<Person[]>),
      sb.from("employees").select("department_id, designation_id").eq("active", true).then(must<{ department_id: string | null; designation_id: string | null }[]>),
    ]);
    return { depts, desigs, people, counts };
  }, "structure");
  const [editDept, setEditDept] = useState<Dept | "new" | null>(null);
  const [editDesig, setEditDesig] = useState<Desig | "new" | null>(null);

  if (error) return <GlassCard><ErrorState body={error} onRetry={reload} /></GlassCard>;
  if (!data) return <LoadingState kind="table" />;
  const deptCount = (id: string) => data.counts.filter((c) => c.department_id === id).length;
  const desigCount = (id: string) => data.counts.filter((c) => c.designation_id === id).length;
  const unplaced = data.counts.filter((c) => !c.department_id).length;

  return tab === "departments" ? (
    <>
      <SectionCard title="Departments" subtitle={`${data.depts.filter((d) => d.active).length} in use · ${unplaced} active ${unplaced === 1 ? "person has" : "people have"} no department`} actions={manage ? <Button variant="primary" size="sm" onClick={() => setEditDept("new")}>Add department</Button> : null}>
        {data.depts.length === 0 ? (
          <EmptyState title="No departments yet" body="Add departments such as Sales, Operations or Accounts. The dashboard's department view uses them." action={manage ? <Button variant="primary" onClick={() => setEditDept("new")}>Add department</Button> : undefined} />
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead><tr><th scope="col">Department</th><th scope="col">Code</th><th scope="col">Head</th><th scope="col">People</th><th scope="col">Status</th>{manage ? <th scope="col"><span className="sr-only">Actions</span></th> : null}</tr></thead>
              <tbody>
                {data.depts.map((d) => (
                  <tr key={d.id}>
                    <th scope="row">{d.name}{d.description ? <span className="tiny muted block wrap">{d.description}</span> : null}</th>
                    <td className="mono">{d.code ?? "—"}</td>
                    <td>{d.head?.full_name ?? <span className="muted">—</span>}</td>
                    <td>{deptCount(d.id)}</td>
                    <td>{d.active ? <StatusBadge status="verified" label="In use" /> : <StatusBadge status="weekly-off" label="Not in use" />}</td>
                    {manage ? <td><Button size="sm" variant="ghost" onClick={() => setEditDept(d)}>Edit</Button></td> : null}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </SectionCard>
      {editDept ? <DeptModal dept={editDept === "new" ? null : editDept} people={data.people.filter((p) => p.active)} onClose={() => setEditDept(null)} onSaved={() => { setEditDept(null); reload(); }} /> : null}
    </>
  ) : (
    <>
      <SectionCard title="Designations" subtitle="Job titles used on profiles" actions={manage ? <Button variant="primary" size="sm" onClick={() => setEditDesig("new")}>Add designation</Button> : null}>
        {data.desigs.length === 0 ? (
          <EmptyState title="No designations yet" body="Add job titles such as Sales Executive or Plant Supervisor." action={manage ? <Button variant="primary" onClick={() => setEditDesig("new")}>Add designation</Button> : undefined} />
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead><tr><th scope="col">Designation</th><th scope="col">People</th><th scope="col">Status</th>{manage ? <th scope="col"><span className="sr-only">Actions</span></th> : null}</tr></thead>
              <tbody>
                {data.desigs.map((d) => (
                  <tr key={d.id}>
                    <th scope="row">{d.name}</th>
                    <td>{desigCount(d.id)}</td>
                    <td>{d.active ? <StatusBadge status="verified" label="In use" /> : <StatusBadge status="weekly-off" label="Not in use" />}</td>
                    {manage ? <td><Button size="sm" variant="ghost" onClick={() => setEditDesig(d)}>Edit</Button></td> : null}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </SectionCard>
      {editDesig ? <DesigModal desig={editDesig === "new" ? null : editDesig} onClose={() => setEditDesig(null)} onSaved={() => { setEditDesig(null); reload(); }} /> : null}
    </>
  );
}

const dupe = (m: string) => /duplicate|unique/i.test(m);

function DeptModal({ dept, people, onClose, onSaved }: { dept: Dept | null; people: Person[]; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState({ name: dept?.name ?? "", code: dept?.code ?? "", head: dept?.head_id ?? "", description: dept?.description ?? "", active: dept?.active ?? true });
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const nameErr = f.name.trim().length < 2 ? "Enter a name of at least 2 characters." : undefined;
  async function save() {
    setTried(true);
    if (nameErr) return;
    setBusy(true);
    setErr(null);
    const row = { name: f.name.trim(), code: f.code.trim() || null, head_id: f.head || null, description: f.description.trim() || null, active: f.active };
    const sb = supabase();
    const { error } = dept ? await sb.from("departments").update(row).eq("id", dept.id) : await sb.from("departments").insert(row);
    setBusy(false);
    if (error) return setErr(dupe(error.message) ? "A department with that name already exists." : friendlyError(error));
    toast({ tone: "success", title: dept ? "Department updated" : "Department added", body: row.name });
    onSaved();
  }
  return (
    <Modal open title={dept ? `Edit ${dept.name}` : "Add department"} onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <div className="form-2">
          <FormInput label="Name" required value={f.name} onChange={(e) => setF((x) => ({ ...x, name: e.target.value }))} error={tried ? nameErr : undefined} maxLength={80} />
          <FormInput label="Code" value={f.code} onChange={(e) => setF((x) => ({ ...x, code: e.target.value }))} helper="Optional, e.g. OPS." maxLength={12} />
        </div>
        <FormSelect label="Department head" value={f.head} onChange={(e) => setF((x) => ({ ...x, head: e.target.value }))} options={[{ value: "", label: "No head" }, ...people.map((p) => ({ value: p.id, label: `${p.full_name}${p.emp_code ? ` · ${p.emp_code}` : ""}` }))]} />
        <FormTextarea label="Description" rows={2} value={f.description} onChange={(e) => setF((x) => ({ ...x, description: e.target.value }))} maxLength={300} />
        <FormSelect label="Status" value={f.active ? "yes" : "no"} onChange={(e) => setF((x) => ({ ...x, active: e.target.value === "yes" }))} options={[{ value: "yes", label: "In use" }, { value: "no", label: "Not in use (keeps history)" }]} helper="Departments aren't deleted, so past records still make sense." />
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} onClick={save}>{dept ? "Save changes" : "Add department"}</Button>
        </div>
      </div>
    </Modal>
  );
}

function DesigModal({ desig, onClose, onSaved }: { desig: Desig | null; onClose: () => void; onSaved: () => void }) {
  const [name, setName] = useState(desig?.name ?? "");
  const [active, setActive] = useState(desig?.active ?? true);
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const nameErr = name.trim().length < 2 ? "Enter a name of at least 2 characters." : undefined;
  async function save() {
    setTried(true);
    if (nameErr) return;
    setBusy(true);
    setErr(null);
    const sb = supabase();
    const row = { name: name.trim(), active };
    const { error } = desig ? await sb.from("designations").update(row).eq("id", desig.id) : await sb.from("designations").insert(row);
    setBusy(false);
    if (error) return setErr(dupe(error.message) ? "That designation already exists." : friendlyError(error));
    toast({ tone: "success", title: desig ? "Designation updated" : "Designation added", body: row.name });
    onSaved();
  }
  return (
    <Modal open title={desig ? `Edit ${desig.name}` : "Add designation"} onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <FormInput label="Designation" required value={name} onChange={(e) => setName(e.target.value)} error={tried ? nameErr : undefined} placeholder="e.g. Sales Executive" maxLength={80} />
        <FormSelect label="Status" value={active ? "yes" : "no"} onChange={(e) => setActive(e.target.value === "yes")} options={[{ value: "yes", label: "In use" }, { value: "no", label: "Not in use (keeps history)" }]} />
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} onClick={save}>{desig ? "Save changes" : "Add designation"}</Button>
        </div>
      </div>
    </Modal>
  );
}
