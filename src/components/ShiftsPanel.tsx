"use client";

import { useState } from "react";
import { hm } from "@/lib/attendance";
import { can } from "@/lib/permissions";
import { isOvernight, shiftMinutes, type Shift } from "@/lib/roster";
import { useSession } from "@/lib/session";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";
import { must, useLoad } from "@/lib/use-load";
import { Modal } from "./Modal";
import { shiftTimes } from "./RosterBoard";
import { EmptyState, ErrorState, LoadingState } from "./States";
import { Button, FormInput, FormSelect, SectionCard, StatusBadge } from "./ui";

/** Shift definitions: name, start, end, break, grace. Overnight when the end is at or before the start. */
export function ShiftsPanel() {
  const { role } = useSession();
  const canEdit = can(role, "manageShifts");
  const canDefault = can(role, "editPolicy");
  const { data, error, reload } = useLoad(async () => {
    const sb = supabase();
    const [shifts, org] = await Promise.all([
      sb.from("shifts").select("*").order("start_time").then(must<Shift[]>),
      sb.from("organization").select("default_shift_id").single<{ default_shift_id: string | null }>().then(must<{ default_shift_id: string | null }>),
    ]);
    return { shifts, org };
  }, "shifts");
  const [edit, setEdit] = useState<Shift | "new" | null>(null);
  const [savingDefault, setSavingDefault] = useState(false);

  if (error) return <SectionCard title="Shifts"><ErrorState body={error} onRetry={reload} /></SectionCard>;
  if (!data) return <LoadingState kind="table" label="Loading shifts" />;

  async function setDefault(id: string) {
    setSavingDefault(true);
    const { error: e } = await supabase().from("organization").update({ default_shift_id: id || null }).eq("id", 1);
    setSavingDefault(false);
    if (e) return toast({ tone: "danger", title: "Not saved", body: friendlyError(e) });
    toast({ tone: "success", title: "Company default shift saved" });
    reload();
  }

  return (
    <>
      <SectionCard
        title="Shifts"
        subtitle="Assign them per person and per day in the Work roster tab"
        actions={canEdit ? <Button variant="primary" size="sm" onClick={() => setEdit("new")}>Add shift</Button> : null}
      >
        {data.shifts.length === 0 ? (
          <EmptyState title="No shifts yet" body="Add shifts such as General 9:00–6:00 or Night 10:00 pm–6:00 am. Late arrival, early departure and overtime are measured against them." action={canEdit ? <Button variant="primary" onClick={() => setEdit("new")}>Add the first shift</Button> : undefined} />
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr><th scope="col">Shift</th><th scope="col">Time</th><th scope="col">Break</th><th scope="col">Grace</th><th scope="col">Scheduled</th><th scope="col">Status</th>{canEdit ? <th scope="col"><span className="sr-only">Actions</span></th> : null}</tr>
              </thead>
              <tbody>
                {data.shifts.map((s) => (
                  <tr key={s.id}>
                    <th scope="row">
                      {s.name}
                      {data.org.default_shift_id === s.id ? <span className="tiny muted block">Company default</span> : null}
                    </th>
                    <td>{shiftTimes(s)} {isOvernight(s) ? <StatusBadge status="holiday" label="Overnight" /> : null}</td>
                    <td>{hm(s.break_minutes)}</td>
                    <td>{s.grace_minutes} min</td>
                    <td>{hm(shiftMinutes(s))}</td>
                    <td>{s.active ? <StatusBadge status="verified" label="In use" /> : <StatusBadge status="weekly-off" label="Not in use" />}</td>
                    {canEdit ? <td><Button size="sm" variant="ghost" onClick={() => setEdit(s)}>Edit</Button></td> : null}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </SectionCard>

      <SectionCard title="Company default shift" subtitle={canDefault ? "Used for anyone without their own shift" : "Only an administrator can change this"}>
        {canDefault ? (
          <div className="row default-shift">
            <FormSelect
              label="Default shift"
              value={data.org.default_shift_id ?? ""}
              disabled={savingDefault}
              onChange={(e) => setDefault(e.target.value)}
              options={[{ value: "", label: "None (no late / overtime figures without a shift)" }, ...data.shifts.filter((s) => s.active).map((s) => ({ value: s.id, label: `${s.name} · ${shiftTimes(s)}` }))]}
            />
          </div>
        ) : (
          <p className="readonly-value">
            <StatusBadge status="weekly-off" label="View only" /> {data.shifts.find((s) => s.id === data.org.default_shift_id)?.name ?? "None set"}
          </p>
        )}
      </SectionCard>

      {edit ? <ShiftModal shift={edit === "new" ? null : edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); reload(); }} /> : null}
    </>
  );
}

function ShiftModal({ shift, onClose, onSaved }: { shift: Shift | null; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState({
    name: shift?.name ?? "",
    start: shift?.start_time.slice(0, 5) ?? "09:00",
    end: shift?.end_time.slice(0, 5) ?? "18:00",
    brk: String(shift?.break_minutes ?? 60),
    grace: String(shift?.grace_minutes ?? 10),
    active: shift?.active ?? true,
  });
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const brk = Number(f.brk);
  const grace = Number(f.grace);
  const errors = {
    name: f.name.trim().length < 2 ? "Enter a name of at least 2 characters." : undefined,
    end: f.start === f.end ? "End time must differ from start time." : undefined,
    brk: !Number.isInteger(brk) || brk < 0 || brk > 240 ? "0 to 240 minutes." : undefined,
    grace: !Number.isInteger(grace) || grace < 0 || grace > 120 ? "0 to 120 minutes." : undefined,
  };
  const ok = !Object.values(errors).some(Boolean);
  const overnight = f.end <= f.start;
  const sched = ok ? shiftMinutes({ start_time: f.start, end_time: f.end, break_minutes: brk }) : 0;

  async function save() {
    setTried(true);
    if (!ok) return;
    if (sched <= 0) return setErr("The break is longer than the shift.");
    setBusy(true);
    setErr(null);
    const row = { name: f.name.trim(), start_time: f.start, end_time: f.end, break_minutes: brk, grace_minutes: grace, active: f.active };
    const sb = supabase();
    const { error } = shift ? await sb.from("shifts").update(row).eq("id", shift.id) : await sb.from("shifts").insert(row);
    setBusy(false);
    if (error) return setErr(friendlyError(error));
    toast({ tone: "success", title: shift ? "Shift updated" : "Shift added", body: row.name });
    onSaved();
  }

  return (
    <Modal open title={shift ? `Edit ${shift.name}` : "Add shift"} subtitle={shift ? "Changes apply to every day calculated from now on, past days included." : undefined} onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <FormInput label="Shift name" required value={f.name} onChange={(e) => setF((x) => ({ ...x, name: e.target.value }))} error={tried ? errors.name : undefined} placeholder="e.g. General, Night" maxLength={60} />
        <div className="form-2">
          <FormInput label="Start time" type="time" required value={f.start} onChange={(e) => setF((x) => ({ ...x, start: e.target.value }))} />
          <FormInput label="End time" type="time" required value={f.end} onChange={(e) => setF((x) => ({ ...x, end: e.target.value }))} error={tried ? errors.end : undefined} helper={overnight && !errors.end ? "Ends the next morning (overnight shift)." : undefined} />
        </div>
        <div className="form-2">
          <FormInput label="Break (minutes)" type="number" min={0} max={240} value={f.brk} onChange={(e) => setF((x) => ({ ...x, brk: e.target.value }))} error={tried ? errors.brk : undefined} helper="Unpaid break allowed in this shift." />
          <FormInput label="Grace period (minutes)" type="number" min={0} max={120} value={f.grace} onChange={(e) => setF((x) => ({ ...x, grace: e.target.value }))} error={tried ? errors.grace : undefined} helper="Check-ins within this are not late." />
        </div>
        <FormSelect label="Status" value={f.active ? "yes" : "no"} onChange={(e) => setF((x) => ({ ...x, active: e.target.value === "yes" }))} options={[{ value: "yes", label: "In use" }, { value: "no", label: "Not in use (keeps history)" }]} />
        {ok && sched > 0 ? <p className="meta">Scheduled work: {hm(sched)} per day. Time beyond this counts as overtime.</p> : null}
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} onClick={save}>{shift ? "Save changes" : "Add shift"}</Button>
        </div>
      </div>
    </Modal>
  );
}
