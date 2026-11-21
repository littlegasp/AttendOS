"use client";

import { useMemo, useState } from "react";
import { EmptyState } from "@/components/States";
import { GlassCard, StatusBadge } from "@/components/ui";
import type { SyncRun } from "@/lib/biometric-mock";
import { ago, fmtTime, NotYet, useDemo } from "./shared";

const STATUS: Record<SyncRun["status"], { s: "verified" | "pending" | "failed"; l: string }> = {
  ok: { s: "verified", l: "Completed" },
  partial: { s: "pending", l: "Partly stored" },
  retrying: { s: "pending", l: "Retrying" },
  failed: { s: "failed", l: "Failed" },
  running: { s: "pending", l: "Running" },
  replay: { s: "verified", l: "Replayed (already stored)" },
};

export function SyncTable({ runs, openDevice, showDevice = true }: { runs: SyncRun[]; openDevice?: (id: string) => void; showDevice?: boolean }) {
  const { state, tz, now } = useDemo();
  if (!runs.length) return <EmptyState title="No sync runs yet" body="Runs appear here once a Sync Agent uploads punches for this device." />;
  return (
    <div className="table-wrap">
      <table className="table bio-sync">
        <thead>
          <tr>
            <th scope="col">Started</th>
            {showDevice ? <th scope="col">Device</th> : null}
            <th scope="col">Status</th>
            <th scope="col" className="num">Received</th>
            <th scope="col" className="num">Stored</th>
            <th scope="col" className="num">Confirmed duplicates</th>
            <th scope="col" className="num">Possible duplicates</th>
            <th scope="col" className="num">Unmatched</th>
            <th scope="col" className="num">Rejected</th>
            <th scope="col">Errors / retry</th>
          </tr>
        </thead>
        <tbody>
          {runs.map((r) => {
            const d = state.devices.find((x) => x.id === r.deviceId);
            return (
              <tr key={r.id}>
                <td>{fmtTime(r.started, tz)}<span className="tiny muted block">{ago(r.started, now)}</span></td>
                {showDevice ? (
                  <td>{d && openDevice ? <button type="button" className="link-btn" onClick={() => openDevice(d.id)}>{d.name}</button> : d?.name ?? (r.agentId && state.agents.some((a) => a.id === r.agentId) ? <span className="muted">All devices of {state.agents.find((a) => a.id === r.agentId)!.name}</span> : "—")}</td>
                ) : null}
                <td><StatusBadge status={STATUS[r.status].s} label={STATUS[r.status].l} /></td>
                <td className="num">{r.received}</td>
                <td className="num">{r.stored}</td>
                <td className="num">{r.confirmedDup}</td>
                <td className="num">{r.possibleDup}</td>
                <td className="num">{r.unmatched}</td>
                <td className="num">{r.rejected}</td>
                <td>
                  {r.error ? <span className="small">{r.error}</span> : <span className="muted">—</span>}
                  {r.retry ? <span className="tiny block text-warning">Attempt {r.retry.attempt}; next try {fmtTime(r.retry.nextAt, tz)}</span> : null}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

export function SyncActivity({ openDevice }: { openDevice: (id: string) => void }) {
  const { state, may, live } = useDemo();
  const [device, setDevice] = useState("");
  const [status, setStatus] = useState("");
  const runs = useMemo(
    () => [...state.syncs].filter((r) => (!device || r.deviceId === device) && (!status || r.status === status)).sort((a, b) => b.started.localeCompare(a.started)),
    [state.syncs, device, status],
  );
  const totals = runs.reduce((t, r) => ({ received: t.received + r.received, stored: t.stored + r.stored, dup: t.dup + r.confirmedDup, poss: t.poss + r.possibleDup, un: t.un + r.unmatched, rej: t.rej + r.rejected }), { received: 0, stored: 0, dup: 0, poss: 0, un: 0, rej: 0 });
  return (
    <GlassCard className="stack">
      <div className="emp-filters" role="group" aria-label="Filters">
        <label className={`filter-chip${device ? " on" : ""}`}>
          <span className="fc-label">Device</span>
          <select value={device} onChange={(e) => setDevice(e.target.value)}>
            <option value="">All</option>
            {state.devices.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
          </select>
        </label>
        <label className={`filter-chip${status ? " on" : ""}`}>
          <span className="fc-label">Status</span>
          <select value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">All</option>
            {Object.entries(STATUS).map(([v, x]) => <option key={v} value={v}>{x.l}</option>)}
          </select>
        </label>
        <span className="grow" />
        {may("retryBiometricSync") ? <NotYet label="Retry failed syncs" phase="Agent" /> : null}
      </div>
      <p className="meta" aria-live="polite">
        {runs.length} runs · {totals.received} received · {totals.stored} stored · {totals.dup} confirmed duplicates · {totals.poss} possible duplicates · {totals.un} unmatched · {totals.rej} rejected
      </p>
      <SyncTable runs={runs} openDevice={openDevice} />
      <p className="meta">
        Confirmed duplicates had the same identity as a punch already stored and were not stored again. Possible duplicates are stored and sent to the review queue. Retries are
        made by the Sync Agent with increasing delays{live ? "; Unmatched counts the punches of each run still waiting for a mapping." : "; in this demonstration they are only shown."}
      </p>
    </GlassCard>
  );
}
