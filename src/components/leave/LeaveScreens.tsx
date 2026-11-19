"use client";

import { useEffect, useMemo, useState } from "react";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { Modal } from "@/components/Modal";
import { EmptyState, ErrorState, LoadingState } from "@/components/States";
import { Button, FormInput, FormSelect, FormTextarea, GlassCard, SectionCard, StatusBadge } from "@/components/ui";
import { addDays, formatDay, monthOf, shiftMonth, shortFormat } from "@/lib/dates";
import { todayIn } from "@/lib/employees";
import {
  byDay,
  daysLabel,
  HALF_LABEL,
  LEAVE_STATUS_BADGE,
  LEAVE_STATUS_LABEL,
  leaveError,
  validateLeave,
  type Balance,
  type LeaveForm,
  type LeaveRow,
  type LeaveStatus,
  type LeaveType,
} from "@/lib/leave";
import { can } from "@/lib/permissions";
import { useSession } from "@/lib/session";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";
import { must, useLoad } from "@/lib/use-load";

interface Person { id: string; full_name: string; emp_code: string | null; active: boolean }

function useToday() {
  const { company } = useSession();
  return { today: todayIn(company?.timezone ?? "Asia/Kolkata"), fmt: company?.date_format ?? "DD MMM YYYY" };
}

export function useLeaveTypes(key = "leave-types") {
  return useLoad(async () => must(await supabase().from("leave_types").select("*").order("name")) as LeaveType[], key);
}

function Dates({ r, fmt }: { r: Pick<LeaveRow, "start_date" | "end_date" | "half_day">; fmt: string }) {
  return (
    <span>
      {formatDay(r.start_date, fmt)}
      {r.end_date !== r.start_date ? ` – ${formatDay(r.end_date, fmt)}` : ""}
      {r.half_day ? <span className="meta"> · {HALF_LABEL[r.half_day]}</span> : null}
    </span>
  );
}

// ------------------------------------------------------------------ balances
export function BalanceCards({ rows }: { rows: Balance[] }) {
  return (
    <div className="leave-balances">
      {rows.map((b) => (
        <div key={b.leave_type_id} className="glass leave-bal">
          <span className="meta">{b.name} <span className="mono">({b.code})</span></span>
          <strong className="lb-num">{b.available === null ? "No limit" : Number(b.available)}</strong>
          <span className="tiny muted">
            {b.yearly_days === null ? `${Number(b.taken)} taken this year` : `of ${Number(b.yearly_days) + Number(b.adjustments)} · ${Number(b.taken)} taken`}
            {Number(b.pending) ? ` · ${Number(b.pending)} pending` : ""}
          </span>
        </div>
      ))}
    </div>
  );
}

// ------------------------------------------------------------------ apply (also HR "record leave")
export function ApplyModal({ types, people, onClose, onSaved }: { types: LeaveType[]; people?: Person[]; onClose: () => void; onSaved: () => void }) {
  const { today, fmt } = useToday();
  const [who, setWho] = useState("");
  const [f, setF] = useState<LeaveForm>({ type: types.find((t) => t.active)?.id ?? "", start: addDays(today, 1), end: addDays(today, 1), half: "", reason: "" });
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [pv, setPv] = useState<{ ok: boolean; days?: number; available?: number | null; unlimited?: boolean; overlap?: { status: string; start: string; end: string } | null; attendance?: boolean } | null>(null);
  const t = types.find((x) => x.id === f.type);
  const errors = { ...validateLeave(f, t), ...(people && !who ? { who: "Choose the person." } : {}) } as Record<string, string | undefined>;
  const set = (k: keyof LeaveForm) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) =>
    setF((x) => {
      const n = { ...x, [k]: e.target.value };
      if (k === "start" && (!x.end || x.end < e.target.value)) n.end = e.target.value;
      if (n.start !== n.end) n.half = "";
      return n;
    });

  // Server preview: days counted (roster + holidays), balance and conflicts — before anything is saved.
  useEffect(() => {
    if (!f.type || !f.start || !f.end || f.end < f.start || (people && !who)) return setPv(null);
    let live = true;
    const h = setTimeout(async () => {
      const { data } = await supabase().rpc("leave_preview", { p_type: f.type, p_start: f.start, p_end: f.end, p_half: f.half || null, p_employee: people ? who : null });
      if (live) setPv(data ?? null);
    }, 250);
    return () => {
      live = false;
      clearTimeout(h);
    };
  }, [f.type, f.start, f.end, f.half, who, people]);

  async function save() {
    setTried(true);
    if (Object.values(errors).some(Boolean)) return;
    setBusy(true);
    setErr(null);
    const { data, error } = await supabase().rpc("apply_leave", {
      p_type: f.type, p_start: f.start, p_end: f.end, p_half: f.half || null, p_reason: f.reason.trim(), p_employee: people ? who : null,
    });
    setBusy(false);
    if (error) return setErr(leaveError(error.message));
    toast({ tone: "success", title: data?.status === "approved" ? (people ? "Leave recorded" : "Leave approved") : "Leave requested", body: `${daysLabel(data?.days ?? 0)} · ${t?.name ?? ""}` });
    onSaved();
  }

  const short = pv?.ok && !pv.unlimited && pv.available !== null && pv.available !== undefined && (pv.days ?? 0) > pv.available;
  return (
    <Modal open title={people ? "Record leave for someone" : "Apply for leave"} subtitle={people ? "Recorded leave is approved at once and shows that HR recorded it." : t?.needs_approval === false ? "This leave type is approved automatically." : "Your manager or HR approves it."} onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        {people ? (
          <FormSelect label="Person" required value={who} onChange={(e) => setWho(e.target.value)} error={tried ? errors.who : undefined}
            options={[{ value: "", label: "Choose…" }, ...people.filter((p) => p.active).map((p) => ({ value: p.id, label: `${p.full_name}${p.emp_code ? ` · ${p.emp_code}` : ""}` }))]} />
        ) : null}
        <FormSelect label="Leave type" required value={f.type} onChange={set("type")} error={tried ? errors.type : undefined}
          options={types.filter((x) => x.active).map((x) => ({ value: x.id, label: `${x.name}${x.paid ? "" : " (unpaid)"}` }))} />
        <div className="form-2">
          <FormInput label="First day" type="date" required value={f.start} onChange={set("start")} error={tried ? errors.start : undefined} />
          <FormInput label="Last day" type="date" required value={f.end} min={f.start} onChange={set("end")} error={tried ? errors.end : undefined} />
        </div>
        {f.start && f.start === f.end && t?.allow_half_day ? (
          <FormSelect label="Duration" value={f.half} onChange={set("half")} error={tried ? errors.half : undefined}
            options={[{ value: "", label: "Full day" }, { value: "first", label: "Half day — first half" }, { value: "second", label: "Half day — second half" }]} />
        ) : null}
        <FormTextarea label="Reason" required rows={2} value={f.reason} onChange={set("reason")} error={tried ? errors.reason : undefined} maxLength={500} />
        {pv?.ok ? (
          <div className={`alert ${pv.overlap || short || (pv.attendance && !f.half) || pv.days === 0 ? "warning" : "info"}`} role="status">
            {pv.days === 0 ? "These dates are all days off or holidays — no leave is needed." : (
              <>
                Counts as <strong>{daysLabel(pv.days ?? 0)}</strong> (days off and holidays aren&apos;t counted).{" "}
                {pv.unlimited ? "No balance limit for this type." : `${pv.available ?? 0} available${short ? " — not enough for this request." : "."}`}
              </>
            )}
            {pv.overlap ? <span className="block">Overlaps a {pv.overlap.status} request ({formatDay(pv.overlap.start, fmt)} – {formatDay(pv.overlap.end, fmt)}).</span> : null}
            {pv.attendance && !f.half ? <span className="block">There is attendance on one of these days — choose a half day or other dates.</span> : null}
          </div>
        ) : null}
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} onClick={save}>{people ? "Record leave" : "Submit request"}</Button>
        </div>
      </div>
    </Modal>
  );
}

// ------------------------------------------------------------------ request list (mine / team)
function useLeaveList(from: string, to: string, status: string, key: string) {
  return useLoad(async () => must(await supabase().rpc("leave_list", { p_from: from, p_to: to, p_status: status || null })) as LeaveRow[], `${key}:${from}:${to}:${status}`);
}

function RequestTable({ rows, showPerson, onDecide, onCancel }: { rows: LeaveRow[]; showPerson: boolean; onDecide?: (r: LeaveRow, approve: boolean) => void; onCancel: (r: LeaveRow) => void }) {
  const { fmt } = useToday();
  return (
    <div className="table-wrap">
      <table className="table">
        <thead>
          <tr>
            {showPerson ? <th scope="col">Person</th> : null}
            <th scope="col">Type</th><th scope="col">Dates</th><th scope="col">Days</th><th scope="col">Reason</th><th scope="col">Status</th>
            <th scope="col"><span className="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.id}>
              {showPerson ? <th scope="row">{r.full_name}<span className="tiny muted block">{[r.emp_code, r.department].filter(Boolean).join(" · ")}</span></th> : null}
              <td>{r.leave_type}</td>
              <td><Dates r={r} fmt={fmt} /></td>
              <td>{Number(r.days)}</td>
              <td className="wrap">{r.reason}{r.decision_note ? <span className="tiny muted block">“{r.decision_note}”{r.decided_by_name ? ` — ${r.decided_by_name}` : ""}</span> : null}</td>
              <td><StatusBadge status={LEAVE_STATUS_BADGE[r.status]} label={LEAVE_STATUS_LABEL[r.status]} /></td>
              <td className="row-actions">
                {r.can_decide && onDecide ? (
                  <>
                    <Button size="sm" variant="primary" onClick={() => onDecide(r, true)}>Approve</Button>
                    <Button size="sm" variant="ghost" onClick={() => onDecide(r, false)}>Reject</Button>
                  </>
                ) : null}
                {r.can_cancel ? <Button size="sm" variant="ghost" onClick={() => onCancel(r)}>Cancel</Button> : null}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function DecideModal({ r, approve, onClose, onDone }: { r: LeaveRow; approve: boolean; onClose: () => void; onDone: () => void }) {
  const { fmt } = useToday();
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function go() {
    if (!approve && note.trim().length < 3) return setErr("Give a short reason when rejecting.");
    setBusy(true);
    const { error } = await supabase().rpc("decide_leave", { p_id: r.id, p_approve: approve, p_note: note.trim() || null });
    setBusy(false);
    if (error) return setErr(leaveError(error.message));
    toast({ tone: approve ? "success" : "info", title: approve ? "Leave approved" : "Leave rejected", body: r.full_name });
    onDone();
  }
  return (
    <Modal open title={`${approve ? "Approve" : "Reject"} ${r.full_name}'s leave?`} subtitle={`${r.leave_type} · ${formatDay(r.start_date, fmt)}${r.end_date !== r.start_date ? ` – ${formatDay(r.end_date, fmt)}` : ""} · ${daysLabel(r.days)}`} onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <p className="meta">Reason given: “{r.reason}”</p>
        <FormTextarea label={approve ? "Comment (optional)" : "Reason for rejecting"} required={!approve} rows={2} value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} />
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Back</Button>
          <Button variant={approve ? "primary" : "danger"} loading={busy} onClick={go}>{approve ? "Approve" : "Reject"}</Button>
        </div>
      </div>
    </Modal>
  );
}

function useCancel(onDone: () => void) {
  const [r, setR] = useState<LeaveRow | null>(null);
  const [busy, setBusy] = useState(false);
  const { fmt } = useToday();
  const dialog = (
    <ConfirmDialog
      open={Boolean(r)}
      danger
      title="Cancel this leave?"
      consequence={r ? <p>{r.leave_type}, {formatDay(r.start_date, fmt)}{r.end_date !== r.start_date ? ` – ${formatDay(r.end_date, fmt)}` : ""} ({daysLabel(r.days)}). The days go back to the balance. This is recorded in the activity log.</p> : null}
      confirmLabel="Cancel leave"
      busy={busy}
      onCancel={() => setR(null)}
      onConfirm={async () => {
        if (!r) return;
        setBusy(true);
        const { error } = await supabase().rpc("cancel_leave", { p_id: r.id, p_note: null });
        setBusy(false);
        setR(null);
        if (error) return toast({ tone: "danger", title: "Not cancelled", body: leaveError(error.message) });
        toast({ tone: "info", title: "Leave cancelled" });
        onDone();
      }}
    />
  );
  return { ask: setR, dialog };
}

export function MyLeaves() {
  const { employeeId } = useSession();
  const { today } = useToday();
  const [apply, setApply] = useState(false);
  const types = useLeaveTypes();
  const bal = useLoad(async () => must(await supabase().rpc("leave_balance_view", { emp: employeeId, p_year_start: null })) as Balance[], "my-balance");
  const list = useLeaveList(addDays(today, -400), addDays(today, 400), "", "mine");
  const reload = () => { bal.reload(); list.reload(); };
  const cancel = useCancel(reload);
  const mine = (list.data ?? []).filter((r) => r.employee_id === employeeId);
  if (types.error || bal.error || list.error) return <GlassCard><ErrorState body={types.error ?? bal.error ?? list.error ?? ""} onRetry={reload} /></GlassCard>;
  if (!types.data || !bal.data || !list.data) return <LoadingState kind="cards" />;
  return (
    <>
      <SectionCard title="My balance" subtitle={bal.data[0] ? `Leave year ${formatDay(bal.data[0].year_start, "DD MMM YYYY")} – ${formatDay(bal.data[0].year_end, "DD MMM YYYY")}` : undefined}
        actions={<Button variant="primary" size="sm" onClick={() => setApply(true)}>Apply for leave</Button>}>
        <BalanceCards rows={bal.data} />
      </SectionCard>
      <SectionCard title="My requests" subtitle="Pending requests can be cancelled; approved leave can be cancelled until it starts.">
        {mine.length === 0 ? <EmptyState compact title="No leave requests yet" body="Use Apply for leave. Your manager or HR approves it." /> : <RequestTable rows={mine} showPerson={false} onCancel={cancel.ask} />}
      </SectionCard>
      {apply ? <ApplyModal types={types.data} onClose={() => setApply(false)} onSaved={() => { setApply(false); reload(); }} /> : null}
      {cancel.dialog}
    </>
  );
}

export function TeamRequests() {
  const { role, employeeId } = useSession();
  const { today } = useToday();
  const [status, setStatus] = useState<"" | LeaveStatus>("pending");
  const [decide, setDecide] = useState<{ r: LeaveRow; approve: boolean } | null>(null);
  const [record, setRecord] = useState(false);
  const types = useLeaveTypes("team-types");
  const people = useLoad(async () => must(await supabase().rpc("people_directory")) as Person[], "team-people");
  const list = useLeaveList(addDays(today, -366), addDays(today, 366), status, "team");
  const cancel = useCancel(list.reload);
  const hr = can(role, "manageLeave");
  const rows = (list.data ?? []).filter((r) => r.employee_id !== employeeId);
  if (list.error) return <GlassCard><ErrorState body={list.error} onRetry={list.reload} /></GlassCard>;
  if (!list.data) return <LoadingState kind="table" />;
  return (
    <>
      <SectionCard title={hr ? "Leave requests" : "Team requests"} subtitle={hr ? "Everyone in the company" : "People who report to you"}
        actions={
          <>
            <label className="filter-chip">
              <span className="fc-label">Status</span>
              <select value={status} onChange={(e) => setStatus(e.target.value as "" | LeaveStatus)}>
                <option value="pending">Pending</option><option value="approved">Approved</option><option value="rejected">Rejected</option>
                <option value="cancelled">Cancelled</option><option value="">All</option>
              </select>
            </label>
            {hr && types.data && people.data ? <Button size="sm" variant="primary" onClick={() => setRecord(true)}>Record leave</Button> : null}
          </>
        }>
        {rows.length === 0 ? (
          <EmptyState compact title={status === "pending" ? "Nothing waiting for a decision" : "No requests"} body={status === "pending" ? "New requests from your team appear here and on the dashboard." : "Try another status."} />
        ) : (
          <RequestTable rows={rows} showPerson onDecide={(r, approve) => setDecide({ r, approve })} onCancel={cancel.ask} />
        )}
      </SectionCard>
      {decide ? <DecideModal r={decide.r} approve={decide.approve} onClose={() => setDecide(null)} onDone={() => { setDecide(null); list.reload(); }} /> : null}
      {record && types.data && people.data ? (
        <ApplyModal types={types.data} people={people.data.filter((p) => p.id !== employeeId)} onClose={() => setRecord(false)} onSaved={() => { setRecord(false); list.reload(); }} />
      ) : null}
      {cancel.dialog}
    </>
  );
}

// ------------------------------------------------------------------ balance for a person (manager / HR), with HR adjustments
export function LeaveBalance() {
  const { role, employeeId } = useSession();
  const [who, setWho] = useState(employeeId ?? "");
  const [adjust, setAdjust] = useState(false);
  const people = useLoad(async () => must(await supabase().rpc("people_directory")) as Person[], "bal-people");
  const types = useLeaveTypes("bal-types");
  const bal = useLoad(async () => must(await supabase().rpc("leave_balance_view", { emp: who, p_year_start: null })) as Balance[], `bal:${who}`);
  const hr = can(role, "manageLeave");
  const others = role !== "employee";
  return (
    <SectionCard
      title="Leave balance"
      subtitle="Yearly days + adjustments − taken − pending = available"
      actions={
        <>
          {others && people.data ? (
            <label className="filter-chip">
              <span className="fc-label">Person</span>
              <select value={who} onChange={(e) => setWho(e.target.value)}>
                {people.data.filter((p) => p.active).map((p) => <option key={p.id} value={p.id}>{p.full_name}{p.id === employeeId ? " (me)" : ""}</option>)}
              </select>
            </label>
          ) : null}
          {hr && who !== employeeId ? <Button size="sm" variant="primary" onClick={() => setAdjust(true)}>Adjust balance</Button> : null}
        </>
      }
    >
      {bal.error ? <ErrorState body={bal.error} onRetry={bal.reload} /> : !bal.data ? <LoadingState kind="table" /> : (
        <div className="table-wrap">
          <table className="table">
            <thead><tr><th scope="col">Leave type</th><th scope="col">Yearly days</th><th scope="col">Adjustments</th><th scope="col">Taken</th><th scope="col">Pending</th><th scope="col">Available</th></tr></thead>
            <tbody>
              {bal.data.map((b) => (
                <tr key={b.leave_type_id}>
                  <th scope="row">{b.name} <span className="mono muted">{b.code}</span>{b.paid ? null : <span className="tiny muted block">Unpaid</span>}</th>
                  <td>{b.yearly_days === null ? "No limit" : Number(b.yearly_days)}</td>
                  <td>{Number(b.adjustments) ? (Number(b.adjustments) > 0 ? "+" : "") + Number(b.adjustments) : "—"}</td>
                  <td>{Number(b.taken)}</td>
                  <td>{Number(b.pending) || "—"}</td>
                  <td><strong>{b.available === null ? "No limit" : Number(b.available)}</strong></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {adjust && types.data ? <AdjustModal who={who} name={people.data?.find((p) => p.id === who)?.full_name ?? ""} types={types.data} onClose={() => setAdjust(false)} onSaved={() => { setAdjust(false); bal.reload(); }} /> : null}
    </SectionCard>
  );
}

function AdjustModal({ who, name, types, onClose, onSaved }: { who: string; name: string; types: LeaveType[]; onClose: () => void; onSaved: () => void }) {
  const [type, setType] = useState(types.find((t) => t.active && t.yearly_days !== null)?.id ?? "");
  const [days, setDays] = useState("1");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const n = Number(days);
  async function save() {
    if (!type || !Number.isFinite(n) || n === 0 || Math.abs(n) > 365 || Math.round(n * 2) !== n * 2) return setErr("Enter a number of days such as 2, -1 or 0.5.");
    if (reason.trim().length < 3) return setErr("Give a reason (it is kept in the activity log).");
    setBusy(true);
    const { error } = await supabase().rpc("adjust_leave", { p_employee: who, p_type: type, p_days: n, p_reason: reason.trim(), p_year_start: null });
    setBusy(false);
    if (error) return setErr(friendlyError(error));
    toast({ tone: "success", title: "Balance adjusted", body: `${n > 0 ? "+" : ""}${n} for ${name}` });
    onSaved();
  }
  return (
    <Modal open title={`Adjust ${name}'s balance`} subtitle="For opening balances, carry-over or corrections. Use a minus sign to take days away." onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <div className="form-2">
          <FormSelect label="Leave type" value={type} onChange={(e) => setType(e.target.value)} options={types.filter((t) => t.active && t.yearly_days !== null).map((t) => ({ value: t.id, label: t.name }))} />
          <FormInput label="Days (+ or −)" type="number" step="0.5" value={days} onChange={(e) => setDays(e.target.value)} />
        </div>
        <FormTextarea label="Reason" required rows={2} value={reason} onChange={(e) => setReason(e.target.value)} maxLength={200} />
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} onClick={save}>Save adjustment</Button>
        </div>
      </div>
    </Modal>
  );
}

// ------------------------------------------------------------------ calendar
const WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
export function LeaveCalendar() {
  const { today, fmt } = useToday();
  const [month, setMonth] = useState(monthOf(today).from);
  const m = monthOf(month);
  const list = useLeaveList(m.from, m.to, "", "cal");
  const rows = useMemo(() => (list.data ?? []).filter((r) => r.status === "approved" || r.status === "pending"), [list.data]);
  const map = useMemo(() => byDay(rows, m.from, m.to), [rows, m.from, m.to]);
  const first = new Date(m.from + "T00:00:00Z").getUTCDay();
  const last = Number(m.to.slice(8));
  const cells: (string | null)[] = [...Array(first).fill(null), ...Array.from({ length: last }, (_, i) => `${m.from.slice(0, 8)}${String(i + 1).padStart(2, "0")}`)];
  return (
    <SectionCard title="Leave calendar" subtitle="Approved and pending leave you can see"
      actions={
        <div className="row">
          <Button size="sm" variant="ghost" onClick={() => setMonth(shiftMonth(month, -1))} aria-label="Previous month">‹</Button>
          <strong className="cal-month" aria-live="polite">{m.label}</strong>
          <Button size="sm" variant="ghost" onClick={() => setMonth(shiftMonth(month, 1))} aria-label="Next month">›</Button>
        </div>
      }>
      {list.error ? <ErrorState body={list.error} onRetry={list.reload} /> : !list.data ? <LoadingState kind="table" /> : (
        <>
          <div className="leave-cal" aria-hidden="true">
            {WD.map((d) => <div key={d} className="lc-head">{d}</div>)}
            {cells.map((d, i) => (
              <div key={i} className={`lc-day${d === today ? " today" : ""}${d ? "" : " blank"}`}>
                {d ? <span className="lc-num">{Number(d.slice(8))}</span> : null}
                {d ? (map.get(d) ?? []).slice(0, 3).map((k) => (
                  <span key={k} className={`lc-pill ${rows[k]!.status}`}>{rows[k]!.full_name.split(" ")[0]}{rows[k]!.half_day ? " ½" : ""}</span>
                )) : null}
                {d && (map.get(d)?.length ?? 0) > 3 ? <span className="tiny muted">+{map.get(d)!.length - 3} more</span> : null}
              </div>
            ))}
          </div>
          <p className="tiny muted"><span className="lc-pill approved">Approved</span> <span className="lc-pill pending">Pending</span> ½ = half day</p>
          {rows.length === 0 ? <EmptyState compact title={`No leave in ${m.label}`} /> : (
            <div className="table-wrap">
              <table className="table">
                <caption className="sr-only">Leave in {m.label}</caption>
                <thead><tr><th scope="col">Person</th><th scope="col">Type</th><th scope="col">Dates</th><th scope="col">Status</th></tr></thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={r.id}>
                      <th scope="row">{r.full_name}</th>
                      <td>{r.leave_type}</td>
                      <td>{shortFormat(r.start_date, fmt)}{r.end_date !== r.start_date ? ` – ${shortFormat(r.end_date, fmt)}` : ""}{r.half_day ? ` · ${HALF_LABEL[r.half_day]}` : ""}</td>
                      <td><StatusBadge status={LEAVE_STATUS_BADGE[r.status]} label={LEAVE_STATUS_LABEL[r.status]} /></td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </SectionCard>
  );
}

// ------------------------------------------------------------------ leave types (HR / Admin)
export function LeaveTypes() {
  const types = useLeaveTypes("types-tab");
  const [edit, setEdit] = useState<LeaveType | "new" | null>(null);
  if (types.error) return <GlassCard><ErrorState body={types.error} onRetry={types.reload} /></GlassCard>;
  if (!types.data) return <LoadingState kind="table" />;
  return (
    <SectionCard title="Leave types" subtitle="Yearly days reset each leave year. Types are switched off, never deleted." actions={<Button size="sm" variant="primary" onClick={() => setEdit("new")}>Add leave type</Button>}>
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th scope="col">Type</th><th scope="col">Yearly days</th><th scope="col">Paid</th><th scope="col">Approval</th><th scope="col">Half days</th><th scope="col">Apply back up to</th><th scope="col">Status</th><th scope="col"><span className="sr-only">Actions</span></th></tr></thead>
          <tbody>
            {types.data.map((t) => (
              <tr key={t.id}>
                <th scope="row">{t.name} <span className="mono muted">{t.code}</span></th>
                <td>{t.yearly_days === null ? "No limit" : Number(t.yearly_days)}</td>
                <td>{t.paid ? "Paid" : "Unpaid"}</td>
                <td>{t.needs_approval ? "Manager or HR" : "Automatic"}</td>
                <td>{t.allow_half_day ? "Allowed" : "No"}</td>
                <td>{t.max_backdate_days} days</td>
                <td>{t.active ? <StatusBadge status="verified" label="In use" /> : <StatusBadge status="weekly-off" label="Not in use" />}</td>
                <td><Button size="sm" variant="ghost" onClick={() => setEdit(t)}>Edit</Button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {edit ? <TypeModal t={edit === "new" ? null : edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); types.reload(); }} /> : null}
    </SectionCard>
  );
}

function TypeModal({ t, onClose, onSaved }: { t: LeaveType | null; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState({
    name: t?.name ?? "", code: t?.code ?? "", yearly: t ? (t.yearly_days === null ? "" : String(Number(t.yearly_days))) : "10",
    paid: t?.paid ?? true, approval: t?.needs_approval ?? true, half: t?.allow_half_day ?? true, back: String(t?.max_backdate_days ?? 30), active: t?.active ?? true,
  });
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const yes = (v: boolean) => (v ? "yes" : "no");
  async function save() {
    if (f.name.trim().length < 2) return setErr("Enter a name.");
    if (!/^[A-Za-z]{1,4}$/.test(f.code.trim())) return setErr("Code: 1–4 letters, e.g. CL.");
    const yearly = f.yearly.trim() === "" ? null : Number(f.yearly);
    if (yearly !== null && (!Number.isFinite(yearly) || yearly < 0 || yearly > 365)) return setErr("Yearly days: 0–365, or empty for no limit.");
    setBusy(true);
    setErr(null);
    const row = { name: f.name.trim(), code: f.code.trim().toUpperCase(), yearly_days: yearly, paid: f.paid, needs_approval: f.approval, allow_half_day: f.half, max_backdate_days: Number(f.back) || 0, active: f.active };
    const sb = supabase();
    const { error } = t ? await sb.from("leave_types").update(row).eq("id", t.id) : await sb.from("leave_types").insert(row);
    setBusy(false);
    if (error) return setErr(/duplicate|unique/i.test(error.message) ? "A leave type with that name or code already exists." : friendlyError(error));
    toast({ tone: "success", title: t ? "Leave type updated" : "Leave type added", body: row.name });
    onSaved();
  }
  return (
    <Modal open title={t ? `Edit ${t.name}` : "Add leave type"} onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <div className="form-2">
          <FormInput label="Name" required value={f.name} onChange={(e) => setF((x) => ({ ...x, name: e.target.value }))} maxLength={40} />
          <FormInput label="Code" required value={f.code} onChange={(e) => setF((x) => ({ ...x, code: e.target.value }))} helper="1–4 letters" maxLength={4} />
        </div>
        <div className="form-2">
          <FormInput label="Yearly days" type="number" step="0.5" value={f.yearly} onChange={(e) => setF((x) => ({ ...x, yearly: e.target.value }))} helper="Leave empty for no limit (e.g. Unpaid)." />
          <FormInput label="Apply back up to (days)" type="number" value={f.back} onChange={(e) => setF((x) => ({ ...x, back: e.target.value }))} helper="Older dates are recorded by HR." />
        </div>
        <div className="form-2">
          <FormSelect label="Paid" value={yes(f.paid)} onChange={(e) => setF((x) => ({ ...x, paid: e.target.value === "yes" }))} options={[{ value: "yes", label: "Paid" }, { value: "no", label: "Unpaid" }]} />
          <FormSelect label="Approval" value={yes(f.approval)} onChange={(e) => setF((x) => ({ ...x, approval: e.target.value === "yes" }))} options={[{ value: "yes", label: "Manager or HR approves" }, { value: "no", label: "Approved automatically" }]} />
        </div>
        <div className="form-2">
          <FormSelect label="Half days" value={yes(f.half)} onChange={(e) => setF((x) => ({ ...x, half: e.target.value === "yes" }))} options={[{ value: "yes", label: "Allowed" }, { value: "no", label: "Not allowed" }]} />
          <FormSelect label="Status" value={yes(f.active)} onChange={(e) => setF((x) => ({ ...x, active: e.target.value === "yes" }))} options={[{ value: "yes", label: "In use" }, { value: "no", label: "Not in use (keeps history)" }]} />
        </div>
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} onClick={save}>{t ? "Save changes" : "Add leave type"}</Button>
        </div>
      </div>
    </Modal>
  );
}

// ------------------------------------------------------------------ on the employee profile
export function PersonLeave({ employeeId }: { employeeId: string }) {
  const { today, fmt } = useToday();
  const bal = useLoad(async () => must(await supabase().rpc("leave_balance_view", { emp: employeeId, p_year_start: null })) as Balance[], `pl-bal:${employeeId}`);
  const list = useLoad(async () => (must(await supabase().rpc("leave_list", { p_from: addDays(today, -366), p_to: addDays(today, 366), p_status: null })) as LeaveRow[])
    .filter((r) => r.employee_id === employeeId).slice(0, 8), `pl-list:${employeeId}`);
  return (
    <SectionCard title="Leave" subtitle="Balance this leave year and recent requests">
      {bal.error || list.error ? <ErrorState body={bal.error ?? list.error ?? ""} onRetry={() => { bal.reload(); list.reload(); }} /> : !bal.data || !list.data ? <LoadingState kind="table" /> : (
        <div className="stack">
          <BalanceCards rows={bal.data} />
          {list.data.length === 0 ? <p className="meta">No leave requests.</p> : (
            <ul className="audit-list">
              {list.data.map((r) => (
                <li key={r.id}>
                  <span className="meta audit-when">{shortFormat(r.start_date, fmt)}</span>
                  <span>
                    <strong>{r.leave_type}</strong> · <Dates r={r} fmt={fmt} /> · {daysLabel(r.days)}{" "}
                    <StatusBadge status={LEAVE_STATUS_BADGE[r.status]} label={LEAVE_STATUS_LABEL[r.status]} />
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </SectionCard>
  );
}
