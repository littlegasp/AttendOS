"use client";

import { useState } from "react";
import { Modal } from "@/components/Modal";
import { EmptyState } from "@/components/States";
import { Button, FormTextarea, GlassCard, StatusBadge } from "@/components/ui";
import { DECISION, type Decision, DECISIONS_FOR, REVIEW_LABEL, type ReviewItem, type ReviewKind, reviewEmployee } from "@/lib/biometric-mock";
import { toast } from "@/lib/toast";
import { MappingForm } from "./Mapping";
import { DemoNote, fmtTime, useDemo, useSaved } from "./shared";

const STATUS_TEXT: Record<ReviewItem["status"], string> = { open: "Waiting for review", resolved: "Resolved", dismissed: "Dismissed" };

export function ReviewQueue() {
  const { state, people, tz, may } = useDemo();
  const [kind, setKind] = useState("");
  const [status, setStatus] = useState<"open" | "closed">("open");
  const [act, setAct] = useState<{ item: ReviewItem; decision: Decision } | null>(null);
  const [mapFor, setMapFor] = useState<ReviewItem | null>(null);
  const [history, setHistory] = useState<ReviewItem | null>(null);
  const rows = state.reviews
    .filter((r) => (status === "open" ? r.status === "open" : r.status !== "open") && (!kind || r.kind === kind))
    .sort((a, b) => b.raw.receivedAt.localeCompare(a.raw.receivedAt));
  const counts = Object.fromEntries((Object.keys(REVIEW_LABEL) as ReviewKind[]).map((k) => [k, state.reviews.filter((r) => r.kind === k && r.status === "open").length]));
  const decide = may("reviewBiometric");

  return (
    <GlassCard className="stack">
      <div className="emp-filters" role="group" aria-label="Filters">
        <label className={`filter-chip${kind ? " on" : ""}`}>
          <span className="fc-label">Type</span>
          <select value={kind} onChange={(e) => setKind(e.target.value)}>
            <option value="">All</option>
            {(Object.keys(REVIEW_LABEL) as ReviewKind[]).map((k) => <option key={k} value={k}>{REVIEW_LABEL[k]} ({counts[k]})</option>)}
          </select>
        </label>
        <label className={`filter-chip${status === "closed" ? " on" : ""}`}>
          <span className="fc-label">Show</span>
          <select value={status} onChange={(e) => setStatus(e.target.value as "open" | "closed")}>
            <option value="open">Waiting for review</option>
            <option value="closed">Resolved and dismissed</option>
          </select>
        </label>
      </div>
      <p className="meta">
        <strong>Original device time</strong> is what the device recorded (its own clock). <strong>Received</strong> is when AttendOS got it. The device record is never edited;
        each decision is added to the item&rsquo;s history.
      </p>

      {rows.length === 0 ? (
        <EmptyState title={status === "open" ? "Nothing waiting for review" : "No closed items"} body="Punches that cannot be counted automatically appear here for HR." />
      ) : (
        <ul className="bio-review">
          {rows.map((r) => {
            const d = state.devices.find((x) => x.id === r.raw.deviceId);
            const empId = r.employeeId !== undefined ? r.employeeId : reviewEmployee(state, r)?.employeeId ?? null;
            const p = empId ? people.find((x) => x.id === empId) : null;
            return (
              <li key={r.id} className="bio-review-item" data-review={r.id}>
                <div className="bio-review-main">
                  <div className="bio-review-head">
                    <span className={`badge tone-${r.kind === "timestamp" || r.kind === "unmatched" ? "warning" : "info"}`}><span className="badge-dot" aria-hidden="true" />{REVIEW_LABEL[r.kind]}</span>
                    <StatusBadge status={r.status === "open" ? "pending" : r.status === "resolved" ? "approved" : "rejected"} label={STATUS_TEXT[r.status]} />
                  </div>
                  <dl className="rules-view compact">
                    <dt>Employee</dt>
                    <dd className="bio-wrap">{p ? <>{p.full_name}{p.emp_code ? <span className="muted"> · {p.emp_code}</span> : null}</> : <span className="muted">Not mapped on this device</span>} · device code <span className="mono">{r.raw.code}</span></dd>
                    <dt>Device</dt><dd className="bio-wrap">{d ? <>{d.name} · serial <span className="mono">{r.raw.deviceSerial}</span></> : r.raw.deviceSerial === "import" ? "Imported file (no device)" : <>Removed device · serial <span className="mono">{r.raw.deviceSerial}</span></>}</dd>
                    <dt>Original device time</dt><dd><span className="mono">{r.raw.deviceLocalTime}</span> <span className="meta">device clock, {r.raw.deviceTimezone}</span></dd>
                    <dt>Received</dt><dd>{fmtTime(r.raw.receivedAt, tz)} <span className="meta">by AttendOS</span></dd>
                    <dt>Reason for review</dt><dd>{r.reason}</dd>
                    <dt>Status</dt><dd>{STATUS_TEXT[r.status]}{r.status !== "open" ? ` — ${r.history.at(-1)?.action} by ${r.history.at(-1)?.by}` : ""}</dd>
                  </dl>
                </div>
                <div className="bio-review-actions">
                  {r.kind === "correction_needed" && r.status === "open" ? <p className="tiny muted">Ask the employee to request an attendance correction for that day; it is decided in Corrections.</p> : null}
                  {r.kind === "held" && r.status === "open" ? <p className="tiny muted">No decision needed now: the punch is looked at again automatically.</p> : null}
                  {r.status === "open" && decide ? (
                    <>
                      {r.kind === "unmatched" && may("mapBiometricCodes") ? <Button size="sm" variant="primary" onClick={() => setMapFor(r)}>Map employee</Button> : null}
                      {DECISIONS_FOR[r.kind].map((dec, i) => (
                        <Button key={dec} size="sm" variant={i === 0 && r.kind !== "unmatched" ? "primary" : "secondary"} onClick={() => setAct({ item: r, decision: dec })}>{DECISION[dec].label}</Button>
                      ))}
                    </>
                  ) : null}
                  <button type="button" className="link-btn small" onClick={() => setHistory(r)}>History ({r.history.length})</button>
                </div>
              </li>
            );
          })}
        </ul>
      )}

      {act ? <DecisionDialog {...act} onClose={() => setAct(null)} /> : null}
      {mapFor ? <MappingForm open onClose={() => setMapFor(null)} code={mapFor.raw.code} deviceId={mapFor.raw.deviceId} validFrom={mapFor.raw.punchAt} /> : null}
      <Modal open={history !== null} title="Review history" subtitle={history ? `${REVIEW_LABEL[history.kind]} · code ${history.raw.code} · ${history.raw.deviceLocalTime}` : undefined} onClose={() => setHistory(null)}>
        {history ? (
          <ul className="audit-list bio-log">
            {(state.reviews.find((x) => x.id === history.id) ?? history).history.map((h, i) => (
              <li key={i}>
                <div><strong>{h.action}</strong>{h.note ? <p className="small">“{h.note}”</p> : null}<p className="meta">by {h.by}</p></div>
                <span className="audit-when meta">{fmtTime(h.at, tz)}</span>
              </li>
            ))}
          </ul>
        ) : null}
        <DemoNote />
      </Modal>
    </GlassCard>
  );
}

function DecisionDialog({ item, decision, onClose }: { item: ReviewItem; decision: Decision; onClose: () => void }) {
  const { apply, state, people } = useDemo();
  const saved = useSaved();
  const d = DECISION[decision];
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const empId = item.employeeId !== undefined ? item.employeeId : reviewEmployee(state, item)?.employeeId ?? null;
  const p = empId ? people.find((x) => x.id === empId) : null;
  return (
    <Modal open title={d.label} subtitle={`${REVIEW_LABEL[item.kind]} · ${p?.full_name ?? `code ${item.raw.code}`} · ${item.raw.deviceLocalTime}`} onClose={onClose}>
      <form
        className="stack"
        onSubmit={async (e) => {
          e.preventDefault();
          setBusy(true);
          const err = await apply({ type: "review", reviewId: item.id, decision, note });
          setBusy(false);
          if (err) return setError(err);
          const t = saved(d.label, "Added to the item's history. Nothing was saved to the database.", "Saved and added to the item's history. The device record is not changed.");
          toast({ tone: "success", title: t.title.replace(" (demonstration — not saved)", " — recorded in this demonstration only"), body: t.body });
          onClose();
        }}
      >
        <div className="alert warning" role="note"><p>{d.effect}</p></div>
        <FormTextarea label={d.reasonRequired ? "Reason" : "Note (optional)"} required={d.reasonRequired} minLength={d.reasonRequired ? 5 : undefined} value={note} onChange={(e) => setNote(e.target.value)} rows={3} helper="Kept in the review history with your name, role and the time. The original device record is not changed." />
        {error ? <div className="alert danger" role="alert"><p>{error}</p></div> : null}
        <DemoNote />
        <div className="dialog-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant={decision === "dismiss" ? "danger" : "primary"} loading={busy}>{d.label}</Button>
        </div>
      </form>
    </Modal>
  );
}
