"use client";

import { useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import { EmptyState } from "@/components/States";
import { Button, FormInput, FormSelect, GlassCard, SectionCard, StatusBadge } from "@/components/ui";
import type { Mapping } from "@/lib/biometric-mock";
import { toast } from "@/lib/toast";
import { fmtTime, useDemo } from "./shared";

type MapState = "active" | "ended" | "future";
function stateOf(m: Mapping, nowIso: string): MapState {
  if (m.validTo && m.validTo <= nowIso) return "ended";
  if (m.validFrom > nowIso) return "future";
  return "active";
}

export function MappingTable({ rows, showScope = true }: { rows: Mapping[]; showScope?: boolean }) {
  const { state, people, apply, by, tz, now } = useDemo();
  const nowIso = new Date(now).toISOString();
  if (!rows.length) return <EmptyState title="No codes here" body={showScope ? "Map a device code to an employee to get started." : "No device-specific codes; company-wide codes apply."} />;
  return (
    <div className="table-wrap">
      <table className="table">
        <thead>
          <tr>
            <th scope="col">Device code</th><th scope="col">AttendOS employee</th><th scope="col">Employee status</th>
            {showScope ? <th scope="col">Applies to</th> : null}
            <th scope="col">Valid</th><th scope="col"><span className="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((m) => {
            const p = people.find((x) => x.id === m.employeeId);
            const st = stateOf(m, nowIso);
            return (
              <tr key={m.id}>
                <th scope="row" className="mono">{m.code}</th>
                <td>{p ? <>{p.full_name}<span className="tiny muted block mono">{p.emp_code ?? ""}</span></> : <span className="muted">Former employee</span>}</td>
                <td>{p?.active ? <StatusBadge status="verified" label="Active" /> : <StatusBadge status="failed" label="Switched off" />}</td>
                {showScope ? <td>{m.deviceId ? state.devices.find((d) => d.id === m.deviceId)?.name ?? "Device" : <span>All devices <span className="tiny muted">(company-wide)</span></span>}</td> : null}
                <td className="small">
                  {st === "ended" ? <StatusBadge status="weekly-off" label="Ended" /> : <StatusBadge status="approved" label="Active" />}
                  <span className="tiny muted block">from {fmtTime(m.validFrom, tz)}{m.validTo ? ` to ${fmtTime(m.validTo, tz)}` : ""}</span>
                </td>
                <td>
                  {st !== "ended" ? (
                    <button
                      type="button"
                      className="link-btn small"
                      onClick={() => {
                        apply({ type: "endMapping", mappingId: m.id, by });
                        toast({ tone: "success", title: `Mapping for code ${m.code} ended (demonstration)`, body: "Earlier punches stay with the same person." });
                      }}
                    >
                      End mapping
                    </button>
                  ) : null}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

export function MappingForm({ open, onClose, code: initialCode = "", deviceId: initialDevice = "", reviewId }: { open: boolean; onClose: () => void; code?: string; deviceId?: string; reviewId?: string }) {
  const { state, people, apply, by } = useDemo();
  const [code, setCode] = useState(initialCode);
  const [scope, setScope] = useState(initialDevice);
  const [emp, setEmp] = useState("");
  const [error, setError] = useState<string | null>(null);
  const sorted = useMemo(() => [...people].sort((a, b) => (a.emp_code ?? a.full_name).localeCompare(b.emp_code ?? b.full_name)), [people]);
  return (
    <Modal open={open} title="Map a device code" subtitle="Choose the exact person. AttendOS never matches codes by name." onClose={onClose}>
      <form
        className="stack"
        onSubmit={(e) => {
          e.preventDefault();
          const err = apply({ type: "addMapping", code, deviceId: scope || null, employeeId: emp, by, reviewId });
          if (err) return setError(err);
          toast({ tone: "success", title: `Code ${code.trim()} mapped (demonstration)`, body: "Unmatched punches with this code were re-checked with their original times." });
          onClose();
        }}
      >
        <FormInput label="Device employee code" required value={code} onChange={(e) => setCode(e.target.value)} helper="Exactly as the device shows it (the user ID on the machine)." />
        <FormSelect
          label="Applies to"
          value={scope}
          onChange={(e) => setScope(e.target.value)}
          options={[{ value: "", label: "All devices (company-wide)" }, ...state.devices.map((d) => ({ value: d.id, label: `Only ${d.name}` }))]}
          helper="A device-specific code takes precedence over a company-wide one on that device."
        />
        <FormSelect
          label="AttendOS employee"
          required
          value={emp}
          onChange={(e) => setEmp(e.target.value)}
          placeholder="Choose a person"
          options={sorted.map((p) => ({ value: p.id, label: `${p.emp_code ? `${p.emp_code} · ` : ""}${p.full_name}${p.active ? "" : " (switched off)"}` }))}
          helper="Only active employees can be mapped. The mapping starts now; earlier punches are not re-assigned."
        />
        {error ? <div className="alert danger" role="alert"><p>{error}</p></div> : null}
        <div className="dialog-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="primary">Save mapping</Button>
        </div>
      </form>
    </Modal>
  );
}

export function MappingScreen() {
  const { state, tz, now } = useDemo();
  const [scope, setScope] = useState("");
  const [show, setShow] = useState<"current" | "all">("current");
  const [form, setForm] = useState<{ code?: string; deviceId?: string } | null>(null);
  const nowIso = new Date(now).toISOString();
  const rows = state.mappings
    .filter((m) => (scope === "" ? true : scope === "company" ? m.deviceId === null : m.deviceId === scope))
    .filter((m) => show === "all" || stateOf(m, nowIso) !== "ended")
    .sort((a, b) => a.code.localeCompare(b.code, undefined, { numeric: true }));
  const unmapped = Object.values(
    state.reviews
      .filter((r) => r.kind === "unmatched" && r.status === "open")
      .reduce<Record<string, { code: string; deviceId: string; count: number; last: string }>>((acc, r) => {
        const k = `${r.deviceId}|${r.code}`;
        acc[k] = { code: r.code, deviceId: r.deviceId, count: (acc[k]?.count ?? 0) + 1, last: acc[k] && acc[k].last > r.receivedAt ? acc[k].last : r.receivedAt };
        return acc;
      }, {}),
  );

  return (
    <div className="stack">
      <SectionCard title="Unmapped device codes" subtitle="Codes received from devices with no AttendOS employee. Their punches wait in the review queue with their original times.">
        {unmapped.length ? (
          <ul className="audit-list bio-log bio-unmapped">
            {unmapped.map((u) => (
              <li key={`${u.deviceId}|${u.code}`}>
                <div>
                  <strong className="mono">{u.code}</strong> on {state.devices.find((d) => d.id === u.deviceId)?.name}
                  <p className="meta">{u.count} waiting item{u.count === 1 ? "" : "s"} · last received {fmtTime(u.last, tz)}</p>
                </div>
                <Button size="sm" variant="primary" onClick={() => setForm({ code: u.code, deviceId: "" })}>Map this code</Button>
              </li>
            ))}
          </ul>
        ) : (
          <EmptyState title="Every received code is mapped" body="New codes appear here when a device sends a user ID that no one is mapped to." />
        )}
      </SectionCard>

      <GlassCard className="stack">
        <div className="emp-toolbar">
          <div className="emp-filters" role="group" aria-label="Filters">
            <label className={`filter-chip${scope ? " on" : ""}`}>
              <span className="fc-label">Applies to</span>
              <select value={scope} onChange={(e) => setScope(e.target.value)}>
                <option value="">All</option>
                <option value="company">Company-wide</option>
                {state.devices.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
              </select>
            </label>
            <label className={`filter-chip${show === "all" ? " on" : ""}`}>
              <span className="fc-label">Show</span>
              <select value={show} onChange={(e) => setShow(e.target.value as "current" | "all")}>
                <option value="current">Current</option>
                <option value="all">Including ended</option>
              </select>
            </label>
          </div>
          <span className="grow" />
          <Button variant="primary" onClick={() => setForm({})}>Map a code</Button>
        </div>
        <MappingTable rows={rows} />
      </GlassCard>

      <SectionCard title="Mapping history" subtitle="Every mapping change, newest first. Ending a mapping never moves earlier punches to someone else.">
        <ul className="audit-list bio-log">
          {state.mappingHistory.slice(0, 30).map((h, i) => (
            <li key={`${h.at}-${i}`}>
              <div><strong className="mono">{h.code}</strong> · {h.action}<p className="meta">by {h.by}</p></div>
              <span className="audit-when meta">{fmtTime(h.at, tz)}</span>
            </li>
          ))}
        </ul>
      </SectionCard>

      {form ? <MappingForm open onClose={() => setForm(null)} code={form.code} deviceId={form.deviceId} /> : null}
    </div>
  );
}
