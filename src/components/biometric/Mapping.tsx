"use client";

import { useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import { EmptyState } from "@/components/States";
import { Button, FormInput, FormSelect, FormTextarea, GlassCard, SectionCard, StatusBadge } from "@/components/ui";
import { isoToZoned, type Mapping, mappingConflicts, resolveMapping, zonedToIso } from "@/lib/biometric-mock";
import { toast } from "@/lib/toast";
import { DemoNote, fmtTime, useDemo } from "./shared";

function scopeName(deviceId: string | null, devices: { id: string; name: string }[]) {
  return deviceId ? devices.find((d) => d.id === deviceId)?.name ?? "Device" : "All devices (company-wide)";
}

export function MappingTable({ rows, showScope = true }: { rows: Mapping[]; showScope?: boolean }) {
  const { state, people, tz, now, may } = useDemo();
  const [ending, setEnding] = useState<Mapping | null>(null);
  const nowIso = new Date(now).toISOString();
  if (!rows.length) return <EmptyState title="No codes here" body={showScope ? "Map a device code to an employee to get started." : "No codes are mapped on this device yet."} />;
  return (
    <>
      <div className="table-wrap">
        <table className="table">
          <thead>
            <tr>
              <th scope="col">Device code</th><th scope="col">AttendOS employee</th><th scope="col">Employee status</th>
              {showScope ? <th scope="col">Device</th> : null}
              <th scope="col">Effective</th><th scope="col"><span className="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            {rows.map((m) => {
              const p = people.find((x) => x.id === m.employeeId);
              const ended = m.validTo !== null && m.validTo <= nowIso;
              const canEnd = m.validTo === null && may(m.deviceId === null ? "mapBiometricCompanyWide" : "mapBiometricCodes");
              return (
                <tr key={m.id}>
                  <th scope="row" className="mono">{m.code}</th>
                  <td className="bio-wrap">{p ? <>{p.full_name}<span className="tiny muted block mono">{p.emp_code ?? ""}</span></> : <span className="muted">Former employee</span>}</td>
                  <td>{p?.active ? <StatusBadge status="verified" label="Active" /> : <StatusBadge status="failed" label="Switched off" />}</td>
                  {showScope ? <td className="bio-wrap">{m.deviceId ? scopeName(m.deviceId, state.devices) : <span className="badge tone-warning"><span className="badge-dot" aria-hidden="true" />Company-wide</span>}</td> : null}
                  <td className="small">
                    {ended ? <StatusBadge status="weekly-off" label="Ended" /> : <StatusBadge status="approved" label="In effect" />}
                    <span className="tiny muted block">from {fmtTime(m.validFrom, tz)}</span>
                    {m.validTo ? <span className="tiny muted block">to {fmtTime(m.validTo, tz)}</span> : null}
                  </td>
                  <td>{canEnd ? <button type="button" className="link-btn small" onClick={() => setEnding(m)}>End mapping</button> : null}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      {ending ? <EndMappingDialog m={ending} onClose={() => setEnding(null)} /> : null}
    </>
  );
}

function EndMappingDialog({ m, onClose }: { m: Mapping; onClose: () => void }) {
  const { state, people, apply, tz, now } = useDemo();
  const [at, setAt] = useState(isoToZoned(new Date(now).toISOString(), tz));
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const p = people.find((x) => x.id === m.employeeId);
  return (
    <Modal open title={`End mapping of code ${m.code}`} subtitle={`${p?.full_name ?? "Former employee"} · ${scopeName(m.deviceId, state.devices)}`} onClose={onClose}>
      <form
        className="stack"
        onSubmit={(e) => {
          e.preventDefault();
          const err = apply({ type: "endMapping", mappingId: m.id, at: zonedToIso(at, tz), reason });
          if (err) return setError(err);
          toast({ tone: "success", title: `Mapping of code ${m.code} ended (demonstration — not saved)`, body: "Punches before the end stay with the same person." });
          onClose();
        }}
      >
        <p className="small">Punches recorded before the end keep belonging to {p?.full_name ?? "this person"}. Punches after it with code {m.code} become unmatched until the code is mapped again.</p>
        <FormInput label={`Ends at (${tz})`} type="datetime-local" required value={at} onChange={(e) => setAt(e.target.value)} />
        <FormTextarea label="Reason" required rows={2} value={reason} onChange={(e) => setReason(e.target.value)} helper="Kept in the mapping history." />
        {error ? <div className="alert danger" role="alert"><p>{error}</p></div> : null}
        <DemoNote />
        <div className="dialog-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="danger">End mapping</Button>
        </div>
      </form>
    </Modal>
  );
}

/** Map a code. Device-specific by default; company-wide only for Admin, with an explicit confirmation. Conflicts are explained before saving. */
export function MappingForm({ open, onClose, code: initialCode = "", deviceId: initialDevice, validFrom: initialFrom }: { open: boolean; onClose: () => void; code?: string; deviceId?: string; validFrom?: string }) {
  const { state, people, apply, tz, now, may } = useDemo();
  const devices = state.devices.filter((d) => !d.disabled);
  const [code, setCode] = useState(initialCode);
  const [scope, setScope] = useState(initialDevice ?? devices[0]?.id ?? "");
  const [emp, setEmp] = useState("");
  const [from, setFrom] = useState(isoToZoned(initialFrom ?? new Date(now).toISOString(), tz));
  const [confirmCw, setConfirmCw] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const sorted = useMemo(() => [...people].sort((a, b) => (a.emp_code ?? a.full_name).localeCompare(b.emp_code ?? b.full_name)), [people]);
  const companyWide = scope === "__company__";
  const deviceId = companyWide ? null : scope;
  const validFrom = zonedToIso(from, tz);
  const conflicts = mappingConflicts(state, people, { code, deviceId, employeeId: emp, validFrom });
  const blocks = conflicts.filter((c) => c.level === "block");
  const touched = code.trim() !== "" && emp !== "";
  const person = people.find((p) => p.id === emp);

  return (
    <Modal open={open} title="Map a device code" subtitle="Codes belong to one device. Choose the exact person — AttendOS never matches by name." onClose={onClose} wide>
      <form
        className="stack"
        onSubmit={(e) => {
          e.preventDefault();
          const err = apply({ type: "addMapping", code, deviceId, employeeId: emp, validFrom, confirmCompanyWide: confirmCw });
          if (err) return setError(err);
          toast({ tone: "success", title: `Code ${code.trim()} mapped (demonstration — not saved)`, body: "Waiting punches it covers were attributed at their original times in this tab only." });
          onClose();
        }}
      >
        <div className="form-2">
          <FormSelect
            label="Device"
            required
            value={scope}
            onChange={(e) => { setScope(e.target.value); setConfirmCw(false); }}
            options={[
              ...devices.map((d) => ({ value: d.id, label: d.name })),
              ...(may("mapBiometricCompanyWide") ? [{ value: "__company__", label: "All devices — company-wide (Admin)" }] : []),
            ]}
            helper={may("mapBiometricCompanyWide") ? "Device-specific is the default. Company-wide is for codes that mean the same person everywhere (e.g. one card)." : "HR maps codes per device. Company-wide codes are an Admin decision."}
          />
          <FormInput label="Device employee code" required value={code} onChange={(e) => setCode(e.target.value)} helper="Exactly as this device shows it (its user ID)." />
          <FormSelect
            label="AttendOS employee"
            required
            value={emp}
            onChange={(e) => setEmp(e.target.value)}
            placeholder="Choose a person"
            options={sorted.map((p) => ({ value: p.id, label: `${p.emp_code ? `${p.emp_code} · ` : ""}${p.full_name}${p.active ? "" : " (switched off)"}` }))}
          />
          <FormInput label={`Effective from (${tz})`} type="datetime-local" required value={from} onChange={(e) => setFrom(e.target.value)} helper="Punches from this moment use this mapping; earlier punches keep the mapping that applied then." />
        </div>
        {companyWide ? (
          <label className="check-row">
            <input type="checkbox" checked={confirmCw} onChange={(e) => setConfirmCw(e.target.checked)} />
            <span>I confirm code <strong>{code.trim() || "…"}</strong> means <strong>{person?.full_name ?? "this person"}</strong> on every device that has no mapping of its own for this code.</span>
          </label>
        ) : null}
        {touched || conflicts.some((c) => c.level === "notice") ? (
          <div className="stack bio-conflicts" aria-live="polite">
            <p className="field-label">Before you save</p>
            {conflicts.length === 0 ? <div className="alert success"><p>No conflicts. {person ? `${person.full_name} will be code ${code.trim()} on ${scopeName(deviceId, state.devices)}.` : ""}</p></div> : null}
            {conflicts.map((c, i) => (
              <div key={i} className={`alert ${c.level === "block" ? "danger" : "info"}`} role={c.level === "block" ? "alert" : undefined}><p>{c.text}</p></div>
            ))}
          </div>
        ) : null}
        {error ? <div className="alert danger" role="alert"><p>{error}</p></div> : null}
        <DemoNote />
        <div className="dialog-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="primary" disabled={blocks.length > 0 || (companyWide && !confirmCw)}>Save mapping</Button>
        </div>
      </form>
    </Modal>
  );
}

/** Shows which mapping applied to a code on a device at a given moment — the rule used for every punch. */
function WhoHadCode() {
  const { state, people, tz, now } = useDemo();
  const [device, setDevice] = useState(state.devices[0]?.id ?? "");
  const [code, setCode] = useState("");
  const [at, setAt] = useState(isoToZoned(new Date(now).toISOString(), tz));
  const iso = zonedToIso(at, tz);
  const m = device && code.trim() && iso ? resolveMapping(state, device, code.trim(), iso) : null;
  const p = m ? people.find((x) => x.id === m.employeeId) : null;
  return (
    <SectionCard title="Who had this code?" subtitle="Punches are attributed by the mapping in force at the punch time, so history never moves when a code is re-used.">
      <div className="form-2">
        <FormSelect label="Device" value={device} onChange={(e) => setDevice(e.target.value)} options={state.devices.map((d) => ({ value: d.id, label: d.name }))} />
        <FormInput label="Device code" value={code} onChange={(e) => setCode(e.target.value)} />
        <FormInput label={`At (${tz})`} type="datetime-local" value={at} onChange={(e) => setAt(e.target.value)} />
      </div>
      {code.trim() ? (
        <p className="small" aria-live="polite" data-testid="who-result">
          {m ? <>Code <strong className="mono">{code.trim()}</strong> on {scopeName(device, state.devices)} at {fmtTime(iso, tz)}: <strong>{p?.full_name ?? "a former employee"}</strong> ({m.deviceId ? "device mapping" : "company-wide mapping"}, effective {fmtTime(m.validFrom, tz)}{m.validTo ? ` – ${fmtTime(m.validTo, tz)}` : ""}).</> : <>No mapping applied at that moment — a punch would be unmatched.</>}
        </p>
      ) : null}
    </SectionCard>
  );
}

export function MappingScreen() {
  const { state, tz, now, may } = useDemo();
  const [scope, setScope] = useState("");
  const [show, setShow] = useState<"current" | "all">("current");
  const [form, setForm] = useState<{ code?: string; deviceId?: string; validFrom?: string } | null>(null);
  const nowIso = new Date(now).toISOString();
  const rows = state.mappings
    .filter((m) => (scope === "" ? true : scope === "company" ? m.deviceId === null : m.deviceId === scope))
    .filter((m) => show === "all" || m.validTo === null || m.validTo > nowIso)
    .sort((a, b) => (a.deviceId ?? "~").localeCompare(b.deviceId ?? "~") || a.code.localeCompare(b.code, undefined, { numeric: true }) || a.validFrom.localeCompare(b.validFrom));
  const unmapped = Object.values(
    state.reviews
      .filter((r) => r.kind === "unmatched" && r.status === "open")
      .reduce<Record<string, { code: string; deviceId: string; count: number; first: string; last: string }>>((acc, r) => {
        const k = `${r.raw.deviceId}|${r.raw.code}`;
        const prev = acc[k];
        acc[k] = { code: r.raw.code, deviceId: r.raw.deviceId, count: (prev?.count ?? 0) + 1, first: prev && prev.first < r.raw.punchAt ? prev.first : r.raw.punchAt, last: prev && prev.last > r.raw.receivedAt ? prev.last : r.raw.receivedAt };
        return acc;
      }, {}),
  );

  return (
    <div className="stack">
      <SectionCard title="Unmapped device codes" subtitle="Codes a device sent with no AttendOS employee on that device. Their punches wait in the review queue with their original times.">
        {unmapped.length ? (
          <ul className="audit-list bio-log bio-unmapped">
            {unmapped.map((u) => (
              <li key={`${u.deviceId}|${u.code}`}>
                <div className="bio-wrap">
                  <strong className="mono">{u.code}</strong> on {scopeName(u.deviceId, state.devices)}
                  <p className="meta">{u.count} waiting item{u.count === 1 ? "" : "s"} · first punch {fmtTime(u.first, tz)} · last received {fmtTime(u.last, tz)}</p>
                </div>
                {may("mapBiometricCodes") ? <Button size="sm" variant="primary" onClick={() => setForm({ code: u.code, deviceId: u.deviceId, validFrom: u.first })}>Map this code</Button> : null}
              </li>
            ))}
          </ul>
        ) : (
          <EmptyState title="Every received code is mapped" body="New codes appear here when a device sends a user ID that no one is mapped to on that device." />
        )}
      </SectionCard>

      <GlassCard className="stack">
        <div className="emp-toolbar">
          <div className="emp-filters" role="group" aria-label="Filters">
            <label className={`filter-chip${scope ? " on" : ""}`}>
              <span className="fc-label">Device</span>
              <select value={scope} onChange={(e) => setScope(e.target.value)}>
                <option value="">All</option>
                {state.devices.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}
                <option value="company">Company-wide only</option>
              </select>
            </label>
            <label className={`filter-chip${show === "all" ? " on" : ""}`}>
              <span className="fc-label">Show</span>
              <select value={show} onChange={(e) => setShow(e.target.value as "current" | "all")}>
                <option value="current">In effect</option>
                <option value="all">Including ended</option>
              </select>
            </label>
          </div>
          <span className="grow" />
          {may("mapBiometricCodes") && state.devices.length ? <Button variant="primary" onClick={() => setForm({})}>Map a code</Button> : null}
        </div>
        <p className="meta">The same code can belong to different people on different devices. A device&rsquo;s own mapping always takes precedence over a company-wide one.</p>
        <MappingTable rows={rows} />
      </GlassCard>

      {state.devices.length ? <WhoHadCode /> : null}

      <SectionCard title="Mapping history" subtitle="Every mapping change with its effective time, newest first. Ending a mapping never moves earlier punches to someone else.">
        {state.mappingHistory.length ? (
          <ul className="audit-list bio-log">
            {state.mappingHistory.slice(0, 40).map((h, i) => (
              <li key={`${h.at}-${i}`}>
                <div className="bio-wrap">
                  <strong className="mono">{h.code}</strong> · {scopeName(h.deviceId, state.devices)} · {h.action}
                  {h.effective ? <p className="meta">Effective {fmtTime(h.effective, tz)}</p> : null}
                  {h.reason ? <p className="small">“{h.reason}”</p> : null}
                  <p className="meta">by {h.by}</p>
                </div>
                <span className="audit-when meta">{fmtTime(h.at, tz)}</span>
              </li>
            ))}
          </ul>
        ) : (
          <EmptyState title="No mapping changes yet" body="Each mapping you add or end is listed here with who did it and when it takes effect." />
        )}
      </SectionCard>

      {form ? <MappingForm open onClose={() => setForm(null)} code={form.code} deviceId={form.deviceId} validFrom={form.validFrom} /> : null}
    </div>
  );
}
