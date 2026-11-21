"use client";

import { useMemo, useState } from "react";
import { EmptyState } from "@/components/States";
import { Button, GlassCard } from "@/components/ui";
import { type Conn, connOf, DIRECTION_LABEL, MANUFACTURER_LABEL, type Manufacturer, METHOD_SHORT, needsAttention } from "@/lib/biometric-mock";
import { ago, ConnBadge, useDemo } from "./shared";

export function DeviceList({ openDevice, onAdd }: { openDevice: (id: string) => void; onAdd: () => void }) {
  const { state, offices, now, may, live } = useDemo();
  const canAdd = may("manageBiometricDevices");
  const [q, setQ] = useState("");
  const [maker, setMaker] = useState("");
  const [conn, setConn] = useState("");
  const [office, setOffice] = useState("");
  const officeName = (id: string | null) => offices.find((o) => o.id === id)?.name ?? "Not assigned";
  const agentName = (id: string | null) => state.agents.find((a) => a.id === id)?.name ?? "No agent";

  const rows = useMemo(() => {
    const t = q.trim().toLowerCase();
    return state.devices.filter(
      (d) =>
        (!t || [d.name, d.model, d.serial].some((v) => v.toLowerCase().includes(t))) &&
        (!maker || d.manufacturer === maker) &&
        (!conn || connOf(d) === conn) &&
        (!office || d.officeId === office),
    );
  }, [state.devices, q, maker, conn, office]);
  const filtered = Boolean(q || maker || conn || office);

  return (
    <GlassCard className="emp-dir">
      <div className="emp-toolbar">
        <div className="emp-search">
          <label className="sr-only" htmlFor="bio-q">Search devices</label>
          <input id="bio-q" className="input" type="search" placeholder="Search name, model or serial number…" value={q} onChange={(e) => setQ(e.target.value)} />
        </div>
        {canAdd ? <Button variant="primary" onClick={onAdd}>Add device</Button> : null}
      </div>
      <div className="emp-filters" role="group" aria-label="Filters">
        <Chip label="Manufacturer" value={maker} onChange={setMaker} options={Object.entries(MANUFACTURER_LABEL).map(([value, label]) => ({ value, label }))} />
        <Chip label="Status" value={conn} onChange={setConn} options={(["online", "offline", "error", "never", "disabled"] as Conn[]).map((value) => ({ value, label: { online: "Online", offline: "Offline", error: "Error", never: "Not connected", disabled: "Disabled" }[value] }))} />
        <Chip label="Office" value={office} onChange={setOffice} options={offices.map((o) => ({ value: o.id, label: o.name }))} />
        {filtered ? (
          <button type="button" className="link-btn small" onClick={() => { setQ(""); setMaker(""); setConn(""); setOffice(""); }}>Clear filters</button>
        ) : null}
      </div>

      {rows.length === 0 ? (
        <EmptyState
          title={filtered ? "No devices match" : "No biometric devices yet"}
          body={filtered ? "Try a different search or clear the filters." : canAdd ? `Add the first device to start mapping employee codes.${live ? "" : " In this demonstration nothing is connected."}` : "An Admin adds biometric devices. Once one is added you can map employee codes here."}
          action={filtered || !canAdd ? undefined : <Button variant="primary" onClick={onAdd}>Add device</Button>}
        />
      ) : (
        <>
          <p className="meta" aria-live="polite">{rows.length} {rows.length === 1 ? "device" : "devices"}</p>
          <div className="table-wrap emp-table">
            <table className="table">
              <thead>
                <tr>
                  <th scope="col">Device</th><th scope="col">Manufacturer</th><th scope="col">Model / serial</th><th scope="col">Office</th>
                  <th scope="col">Method</th><th scope="col">Agent</th><th scope="col">Status</th><th scope="col">Last seen</th><th scope="col">Last sync</th><th scope="col">Direction</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((d) => {
                  const attn = needsAttention(d, state, now);
                  return (
                    <tr key={d.id} className="row-link" onClick={() => openDevice(d.id)}>
                      <th scope="row">
                        <button type="button" className="person-cell" onClick={(e) => { e.stopPropagation(); openDevice(d.id); }}>
                          <span><span className="pc-name bio-wrap">{d.name}</span>{attn.length ? <span className="tiny block text-warning">{attn[0]}</span> : null}</span>
                        </button>
                      </th>
                      <td>{MANUFACTURER_LABEL[d.manufacturer]}</td>
                      <td>{d.model}<span className="tiny muted block mono">{d.serial}</span></td>
                      <td>{officeName(d.officeId)}</td>
                      <td>{METHOD_SHORT[d.method]}</td>
                      <td>{agentName(d.agentId)}</td>
                      <td><ConnBadge conn={connOf(d)} /></td>
                      <td>{ago(d.lastSeen, now)}</td>
                      <td>{ago(d.lastSync, now)}</td>
                      <td className="small">{d.direction === "device" ? "Device keys" : "Inferred"}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <ul className="emp-cards" aria-label="Devices">
            {rows.map((d) => (
              <li key={d.id}>
                <button type="button" className="emp-card" onClick={() => openDevice(d.id)}>
                  <span className="ec-main">
                    <strong className="bio-wrap">{d.name}</strong>
                    <span className="meta block">{MANUFACTURER_LABEL[d.manufacturer]} {d.model} · {officeName(d.officeId)}</span>
                    <span className="tiny muted block">{METHOD_SHORT[d.method]} · {DIRECTION_LABEL[d.direction]} · last sync {ago(d.lastSync, now)}</span>
                  </span>
                  <ConnBadge conn={connOf(d)} />
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
    </GlassCard>
  );
}

function Chip({ label, value, onChange, options }: { label: string; value: string; onChange: (v: string) => void; options: { value: string; label: string }[] }) {
  return (
    <label className={`filter-chip${value ? " on" : ""}`}>
      <span className="fc-label">{label}</span>
      <select value={value} onChange={(e) => onChange(e.target.value)}>
        <option value="">All</option>
        {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
    </label>
  );
}

export const MAKERS: Manufacturer[] = ["zkteco", "essl", "matrix", "other"];
