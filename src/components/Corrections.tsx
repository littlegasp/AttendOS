"use client";

import { useState } from "react";
import { CORRECTION_KIND_LABEL, clock, shortDate } from "@/lib/attendance";
import { useSession } from "@/lib/session";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";
import { must, useLoad } from "@/lib/use-load";
import { ConfirmDialog } from "./ConfirmDialog";
import { Modal } from "./Modal";
import { EmptyState, ErrorState, LoadingState } from "./States";
import { Button, FormTextarea, SectionCard, StatusBadge } from "./ui";

export interface Correction {
  id: number;
  employee_id: string;
  work_date: string;
  kind: string;
  requested_in: string | null;
  requested_out: string | null;
  reason: string;
  status: "pending" | "approved" | "rejected" | "cancelled";
  requested_at: string;
  decided_at: string | null;
  decision_note: string | null;
  employee?: { full_name: string } | null;
}

export type PendingItem = Pick<Correction, "id" | "work_date" | "kind" | "requested_in" | "requested_out" | "reason"> & {
  name?: string;
  employee?: { full_name: string } | null;
  can_decide?: boolean;
};

const STATUS_STYLE = { pending: "pending", approved: "approved", rejected: "rejected", cancelled: "weekly-off" } as const;

function Times({ c, tz }: { c: Pick<Correction, "requested_in" | "requested_out">; tz: string }) {
  return (
    <span>
      {c.requested_in ? `In ${clock(c.requested_in, tz)}` : ""}
      {c.requested_in && c.requested_out ? " · " : ""}
      {c.requested_out ? `Out ${clock(c.requested_out, tz)}` : ""}
    </span>
  );
}

/** The signed-in person's own correction requests. */
export function MyCorrections({ tz, refreshKey = 0 }: { tz: string; refreshKey?: number }) {
  const { employeeId } = useSession();
  const [cancel, setCancel] = useState<Correction | null>(null);
  const [busy, setBusy] = useState(false);
  const { data, error, reload } = useLoad(
    async () => must(await supabase().from("attendance_corrections").select("*").eq("employee_id", employeeId!).order("requested_at", { ascending: false }).limit(50)) as Correction[],
    `mine:${refreshKey}`,
  );

  async function doCancel() {
    if (!cancel) return;
    setBusy(true);
    const { data: r, error: e } = await supabase().rpc("cancel_correction", { p_id: cancel.id });
    setBusy(false);
    setCancel(null);
    if (e || !r?.ok) return toast({ tone: "danger", title: "Not cancelled", body: e ? friendlyError(e) : r?.message });
    toast({ tone: "info", title: "Request cancelled" });
    reload();
  }

  return (
    <SectionCard title="My correction requests" subtitle="Ask from the History tab. Your manager or HR decides.">
      {error ? (
        <ErrorState body={error} onRetry={reload} />
      ) : !data ? (
        <LoadingState kind="table" />
      ) : data.length === 0 ? (
        <EmptyState compact title="No requests yet" body="If a check-in or check-out is missing or wrong, use “Request correction” on that day in History." />
      ) : (
        <ul className="corr-list">
          {data.map((c) => (
            <li key={c.id} className="corr-item">
              <div className="corr-main">
                <strong>{shortDate(c.work_date)} · {CORRECTION_KIND_LABEL[c.kind]}</strong>
                <span className="meta block"><Times c={c} tz={tz} /> · “{c.reason}”</span>
                {c.decision_note ? <span className="meta block">Reply: {c.decision_note}</span> : null}
              </div>
              <div className="corr-side">
                <StatusBadge status={STATUS_STYLE[c.status]} label={c.status[0]!.toUpperCase() + c.status.slice(1)} />
                {c.status === "pending" ? <Button size="sm" variant="ghost" onClick={() => setCancel(c)}>Cancel</Button> : null}
              </div>
            </li>
          ))}
        </ul>
      )}
      <ConfirmDialog
        open={Boolean(cancel)}
        title="Cancel this request?"
        consequence={<p>The request for {cancel ? shortDate(cancel.work_date) : ""} will be withdrawn. You can send a new one afterwards.</p>}
        confirmLabel="Cancel request"
        busy={busy}
        onCancel={() => setCancel(null)}
        onConfirm={doCancel}
      />
    </SectionCard>
  );
}

/** Pending requests the signed-in approver may decide (HR/Admin: everyone; Manager: their team). */
export function PendingCorrections({ items, tz, onDecided, limit }: { items: PendingItem[]; tz: string; onDecided: () => void; limit?: number }) {
  const [open, setOpen] = useState<{ c: PendingItem; approve: boolean } | null>(null);
  const shown = limit ? items.slice(0, limit) : items;
  if (items.length === 0) return <EmptyState compact title="Nothing waiting" body="Correction requests from your scope appear here." />;
  return (
    <>
      <ul className="corr-list">
        {shown.map((c) => (
          <li key={c.id} className="corr-item">
            <div className="corr-main">
              <strong>{c.name ?? c.employee?.full_name} · {shortDate(c.work_date)}</strong>
              <span className="meta block">{CORRECTION_KIND_LABEL[c.kind]} · <Times c={c} tz={tz} /></span>
              <span className="meta block">“{c.reason}”</span>
            </div>
            <div className="corr-side">
              {c.can_decide === false ? (
                <StatusBadge status="pending" label="Waiting" />
              ) : (
                <>
                  <Button size="sm" variant="ghost" onClick={() => setOpen({ c, approve: false })}>Reject</Button>
                  <Button size="sm" variant="primary" onClick={() => setOpen({ c, approve: true })}>Approve</Button>
                </>
              )}
            </div>
          </li>
        ))}
      </ul>
      {limit && items.length > limit ? <p className="meta">+{items.length - limit} more</p> : null}
      {open ? <DecideModal {...open} tz={tz} onClose={() => setOpen(null)} onDone={() => { setOpen(null); onDecided(); }} /> : null}
    </>
  );
}

function DecideModal({ c, approve, tz, onClose, onDone }: { c: PendingItem; approve: boolean; tz: string; onClose: () => void; onDone: () => void }) {
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function go() {
    setBusy(true);
    setErr(null);
    const { data, error } = await supabase().rpc("decide_correction", { p_id: c.id, p_approve: approve, p_note: note.trim() || null });
    setBusy(false);
    if (error) return setErr(friendlyError(error));
    if (!data?.ok) return setErr(data?.message ?? "Couldn't save the decision.");
    toast({ tone: approve ? "success" : "info", title: approve ? "Correction approved" : "Correction rejected", body: `${c.name ?? c.employee?.full_name} · ${shortDate(c.work_date)}` });
    onDone();
  }
  return (
    <Modal open title={`${approve ? "Approve" : "Reject"} correction`} subtitle={`${c.name ?? c.employee?.full_name} · ${shortDate(c.work_date)}`} onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <p className="small">
          {CORRECTION_KIND_LABEL[c.kind]}: <Times c={c} tz={tz} />. {approve ? "These times will be added to the record; the original entries are kept and marked as replaced. This is logged." : "Nothing changes in their attendance. They will see your reason."}
        </p>
        <FormTextarea label={approve ? "Note (optional)" : "Reason for rejecting"} required={!approve} rows={2} value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} />
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant={approve ? "primary" : "danger"} loading={busy} onClick={go}>{approve ? "Approve" : "Reject"}</Button>
        </div>
      </div>
    </Modal>
  );
}
