"use client";

import { MetricCard, SectionCard } from "@/components/ui";
import { needsAttention } from "@/lib/biometric-mock";
import { ago, fmtTime, useDemo } from "./shared";
import { SyncTable } from "./SyncActivity";

export function Overview({ openDevice, goto }: { openDevice: (id: string) => void; goto: (tab: "devices" | "sync" | "review") => void }) {
  const { state, now, tz } = useDemo();
  const live = state.devices.filter((d) => !d.disabled);
  const online = live.filter((d) => d.conn === "online").length;
  const offline = live.filter((d) => d.conn === "offline" || d.conn === "error").length;
  const attention = live.filter((d) => needsAttention(d, state, now).length > 0);
  const lastOk = state.syncs.filter((r) => r.status === "ok").map((r) => r.completed!).sort().at(-1) ?? null;
  const unmatched = state.reviews.filter((r) => r.status === "open" && r.kind === "unmatched").length;
  const openReviews = state.reviews.filter((r) => r.status === "open").length;
  const recent = [...state.syncs].sort((a, b) => b.started.localeCompare(a.started)).slice(0, 6);

  return (
    <div className="stack">
      <div className="grid-kpi bio-kpis">
        <MetricCard label="Total devices" value={state.devices.length} note={`${state.devices.length - live.length} disabled`} />
        <MetricCard label="Online" value={online} tone="success" note="Demonstration status" />
        <MetricCard label="Offline or in error" value={offline} tone={offline ? "danger" : "neutral"} note={`${live.filter((d) => d.conn === "never").length} not yet connected`} />
        <MetricCard label="Need attention" value={attention.length} tone={attention.length ? "warning" : "neutral"} note="Errors, offline > 1 h, clock drift > 5 min, failed sync" />
        <MetricCard label="Last successful sync" value={<span className="bio-kpi-time">{ago(lastOk, now)}</span>} note={fmtTime(lastOk, tz)} tone="info" />
        <MetricCard label="Unmatched punches" value={unmatched} tone={unmatched ? "warning" : "neutral"} note={`${openReviews} review items open in total`} />
      </div>

      {attention.length ? (
        <SectionCard title="Devices needing attention" subtitle="Status shown is demonstration data.">
          <ul className="bio-attn">
            {attention.map((d) => (
              <li key={d.id}>
                <button type="button" className="link-btn" onClick={() => openDevice(d.id)}>{d.name}</button>
                <span className="meta">{needsAttention(d, state, now).join(" · ")}</span>
              </li>
            ))}
          </ul>
        </SectionCard>
      ) : null}

      <SectionCard
        title="Recent synchronisation"
        subtitle="Latest sync runs reported by Sync Agents (demonstration)."
        actions={<button type="button" className="link-btn small" onClick={() => goto("sync")}>All sync activity</button>}
      >
        <SyncTable runs={recent} openDevice={openDevice} />
      </SectionCard>

      <SectionCard title="Sync Agents" subtitle="Agents run on a company PC on the office network (Phase B4). Shown here as samples.">
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr><th scope="col">Agent</th><th scope="col">Computer</th><th scope="col">Status</th><th scope="col">Last heartbeat</th><th scope="col">Queue</th><th scope="col">Devices</th></tr>
            </thead>
            <tbody>
              {state.agents.map((a) => (
                <tr key={a.id}>
                  <th scope="row">{a.name}<span className="tiny muted block mono">key {a.keyPrefix}…</span></th>
                  <td>{a.host}</td>
                  <td><span className={`badge tone-${a.status === "online" ? "success" : "danger"}`}><span className="badge-dot" aria-hidden="true" />{a.status === "online" ? "Online · demo" : "Offline · demo"}</span></td>
                  <td>{ago(a.lastHeartbeat, now)}</td>
                  <td>{a.queueDepth ? `${a.queueDepth} waiting` : "Empty"}</td>
                  <td>{state.devices.filter((d) => d.agentId === a.id).map((d) => d.name).join(", ") || "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <button type="button" className="link-btn small" onClick={() => goto("devices")}>Open device list</button>
      </SectionCard>
    </div>
  );
}
