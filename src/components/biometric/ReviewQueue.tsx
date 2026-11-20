"use client";

import { useState } from "react";
import { Modal } from "@/components/Modal";
import { EmptyState } from "@/components/States";
import { Button, FormTextarea, GlassCard, StatusBadge } from "@/components/ui";
import { REVIEW_LABEL, type ReviewItem, type ReviewKind } from "@/lib/biometric-mock";
import { toast } from "@/lib/toast";
import { MappingForm } from "./Mapping";
import { fmtTime, useDemo } from "./shared";

type Act = "accept" | "dismiss" | "confirm_duplicate" | "not_duplicate" | "keep_correction";

const ACTIONS: Record<ReviewKind, { act: Act; label: string; primary?: boolean }[]> = {
  unmatched: [{ act: "dismiss", label: "Dismiss" }],
  ambiguous: [{ act: "accept", label: "Keep as extra punch", primary: true }, { act: "dismiss", label: "Dismiss" }],
  possible_duplicate: [{ act: "confirm_duplicate", label: "Confirm duplicate", primary: true }, { act: "not_duplicate", label: "Not a duplicate" }],
  after_correction: [{ act: "keep_correction", label: "Keep HR correction", primary: true }, { act: "dismiss", label: "Dismiss" }],
  timestamp: [{ act: "accept", label: "Accept time as recorded" }, { act: "dismiss", label: "Dismiss", primary: true }],
};

export function ReviewQueue() {
  const { state, people, tz } = useDemo();
  const [kind, setKind] = useState("");
  const [status, setStatus] = useState<"open" | "closed">("open");
  const [act, setAct] = useState<{ item: ReviewItem; act: Act; label: string } | null>(null);
  const [mapFor, setMapFor] = useState<ReviewItem | null>(null);
  const [history, setHistory] = useState<ReviewItem | null>(null);
  const rows = state.reviews
    .filter((r) => (status === "open" ? r.status === "open" : r.status !== "open") && (!kind || r.kind === kind))
    .sort((a, b) => b.receivedAt.localeCompare(a.receivedAt));
  const counts = Object.fromEntries((Object.keys(REVIEW_LABEL) as ReviewKind[]).map((k) => [k, state.reviews.filter((r) => r.kind === k && r.status === "open").length]));

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
      <p className="meta">Original punch times are kept exactly as the device recorded them. Decisions are added to each item’s history; the device record itself is never edited.</p>

      {rows.length === 0 ? (
        <EmptyState title={status === "open" ? "Nothing waiting for review" : "No closed items"} body="Punches that cannot be counted automatically appear here for HR." />
      ) : (
        <ul className="bio-review">
          {rows.map((r) => {
            const d = state.devices.find((x) => x.id === r.deviceId);
            const p = people.find((x) => x.id === r.employeeId);
            return (
              <li key={r.id} className="bio-review-item">
                <div className="bio-review-main">
                  <div className="bio-review-head">
                    <span className={`badge tone-${r.kind === "timestamp" || r.kind === "unmatched" ? "warning" : "info"}`}><span className="badge-dot" aria-hidden="true" />{REVIEW_LABEL[r.kind]}</span>
                    {r.status === "open" ? null : <StatusBadge status={r.status === "resolved" ? "approved" : "rejected"} label={r.status === "resolved" ? "Resolved" : "Dismissed"} />}
                  </div>
                  <dl className="rules-view compact">
                    <dt>Original punch time</dt><dd className="mono">{r.deviceLocalTime} <span className="meta">(device clock)</span></dd>
                    <dt>Device</dt><dd>{d?.name ?? "—"}</dd>
                    <dt>Employee code</dt><dd className="mono">{r.code}</dd>
                    <dt>Employee</dt><dd>{p ? p.full_name : <span className="muted">Not mapped</span>}</dd>
                    <dt>Received</dt><dd>{fmtTime(r.receivedAt, tz)}</dd>
                    <dt>Reason</dt><dd>{r.detail}</dd>
                  </dl>
                </div>
                <div className="bio-review-actions">
                  {r.status === "open" ? (
                    <>
                      {r.kind === "unmatched" ? <Button size="sm" variant="primary" onClick={() => setMapFor(r)}>Map employee</Button> : null}
                      {ACTIONS[r.kind].map((a) => (
                        <Button key={a.act} size="sm" variant={a.primary ? "primary" : "secondary"} onClick={() => setAct({ item: r, act: a.act, label: a.label })}>{a.label}</Button>
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

      {act ? <ActDialog {...act} onClose={() => setAct(null)} /> : null}
      {mapFor ? <MappingForm open onClose={() => setMapFor(null)} code={mapFor.code} deviceId={mapFor.deviceId} reviewId={mapFor.id} /> : null}
      <Modal open={history !== null} title="Review history" subtitle={history ? `${REVIEW_LABEL[history.kind]} · code ${history.code}` : undefined} onClose={() => setHistory(null)}>
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
      </Modal>
    </GlassCard>
  );
}

function ActDialog({ item, act, label, onClose }: { item: ReviewItem; act: Act; label: string; onClose: () => void }) {
  const { apply, by } = useDemo();
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  return (
    <Modal open title={label} subtitle={`${REVIEW_LABEL[item.kind]} · code ${item.code} · ${item.deviceLocalTime}`} onClose={onClose}>
      <form
        className="stack"
        onSubmit={(e) => {
          e.preventDefault();
          const err = apply({ type: "review", reviewId: item.id, action: act, note, by });
          if (err) return setError(err);
          toast({ tone: "success", title: `${label} (demonstration)`, body: "Added to the item's history." });
          onClose();
        }}
      >
        <FormTextarea label={act === "dismiss" ? "Reason" : "Note (optional)"} required={act === "dismiss"} value={note} onChange={(e) => setNote(e.target.value)} rows={3} helper="Kept in the review history with your name and the time." />
        {error ? <div className="alert danger" role="alert"><p>{error}</p></div> : null}
        <div className="dialog-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="primary">{label}</Button>
        </div>
      </form>
    </Modal>
  );
}
