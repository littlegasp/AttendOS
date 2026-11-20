"use client";

import { useState } from "react";
import { Modal } from "@/components/Modal";
import { Button, FormInput, FormSelect } from "@/components/ui";
import {
  DIRECTION_LABEL,
  type DirectionMode,
  MANUFACTURER_LABEL,
  type Manufacturer,
  type Method,
  METHOD_LABEL,
  METHODS_FOR,
  MODELS_FOR,
  PUSH_AUTH_LABEL,
  type PushAuth,
} from "@/lib/biometric-mock";
import { toast } from "@/lib/toast";
import { MAKERS } from "./Devices";
import { useDemo } from "./shared";

const STEPS = ["Manufacturer", "Device", "Office", "Method", "Connection", "Sync Agent", "Direction", "Review"] as const;

interface Draft {
  manufacturer: Manufacturer | "";
  name: string;
  model: string;
  serial: string;
  officeId: string;
  method: Method | "";
  deviceIp: string;
  port: string;
  receiverPort: string;
  pushAuth: PushAuth;
  software: string;
  host: string;
  agentId: string;
  direction: DirectionMode;
}

const EMPTY: Draft = { manufacturer: "", name: "", model: "", serial: "", officeId: "", method: "", deviceIp: "", port: "4370", receiverPort: "8081", pushAuth: "authenticated", software: "", host: "", agentId: "", direction: "first_last" };

const LAN_IP = /^(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})$/;

export function AddDeviceWizard({ open, onClose, onSaved }: { open: boolean; onClose: () => void; onSaved: (id: string) => void }) {
  const { state, offices, apply, by } = useDemo();
  const [step, setStep] = useState(0);
  const [d, setD] = useState<Draft>(EMPTY);
  const [error, setError] = useState<string | null>(null);
  const set = <K extends keyof Draft>(k: K, v: Draft[K]) => setD((x) => ({ ...x, [k]: v }));
  const needsAgent = d.method !== "file_import";

  function problem(i: number): string | null {
    switch (i) {
      case 0: return d.manufacturer ? null : "Choose the manufacturer.";
      case 1:
        if (!d.name.trim()) return "Give the device a name staff will recognise (e.g. Main entrance).";
        if (!d.model.trim()) return "Enter the model.";
        if (!/^[A-Za-z0-9-]{4,32}$/.test(d.serial.trim())) return "Enter the serial number from the device's System info screen (4–32 letters, digits or -).";
        if (state.devices.some((x) => x.manufacturer === d.manufacturer && x.serial.toLowerCase() === d.serial.trim().toLowerCase())) return "This serial number is already registered for this manufacturer.";
        return null;
      case 2: return d.officeId ? null : "Choose the office where the device is installed.";
      case 3: return d.method ? null : "Choose how AttendOS will receive punches.";
      case 4:
        if (d.method === "sdk_pull" || d.method === "local_push") {
          if (!LAN_IP.test(d.deviceIp.trim())) return "Enter the device's private office-network address (10.x, 172.16–31.x or 192.168.x). Devices are never reached over the internet.";
          const port = Number(d.method === "sdk_pull" ? d.port : d.receiverPort);
          if (!Number.isInteger(port) || port < 1 || port > 65535) return "Enter a valid port (1–65535).";
        }
        if (d.method === "vendor_software" && (!d.software.trim() || !d.host.trim())) return "Enter the vendor software and the PC it runs on.";
        return null;
      case 5: return !needsAgent || d.agentId ? null : "Assign the Sync Agent that will talk to this device.";
      default: return null;
    }
  }

  function next() {
    const p = problem(step);
    if (p) return setError(p);
    setError(null);
    setStep((s) => Math.min(s + 1, STEPS.length - 1));
  }

  function save() {
    for (let i = 0; i < STEPS.length - 1; i++) {
      const p = problem(i);
      if (p) { setStep(i); return setError(p); }
    }
    const connection: Record<string, string> =
      d.method === "sdk_pull" ? { deviceIp: d.deviceIp.trim(), port: d.port }
      : d.method === "local_push" ? { deviceIp: d.deviceIp.trim(), receiverPort: d.receiverPort, pushAuth: d.pushAuth }
      : d.method === "vendor_software" ? { software: d.software.trim(), host: d.host.trim() }
      : {};
    const newId = `dev-${state.seq + 1}`; // the reducer's id for the next record
    const err = apply({
      type: "addDevice",
      device: { name: d.name.trim(), manufacturer: d.manufacturer as Manufacturer, model: d.model.trim(), serial: d.serial, firmware: "", officeId: d.officeId, method: d.method as Method, agentId: needsAgent ? d.agentId : null, direction: d.direction, connection, createdBy: by },
    });
    if (err) return setError(err);
    toast({ tone: "success", title: `${d.name.trim()} added (demonstration — not saved)`, body: "Status: Not connected. No device was contacted and nothing was saved to the database." });
    close();
    onSaved(newId);
  }

  function close() {
    setStep(0);
    setD(EMPTY);
    setError(null);
    onClose();
  }

  const makerOpts = MAKERS.map((m) => ({ value: m, label: MANUFACTURER_LABEL[m] }));

  return (
    <Modal open={open} title="Add a biometric device" subtitle={`Step ${step + 1} of ${STEPS.length}: ${STEPS[step]}`} onClose={close} wide>
      <div className="stack">
        <div className="alert warning" role="note">
          <p><strong>Demonstration only.</strong> This saves a sample device in this browser tab. No hardware connection is configured, nothing is contacted and nothing is stored in the database.</p>
        </div>
        <ol className="bio-steps" aria-label="Steps">
          {STEPS.map((s, i) => (
            <li key={s} className={i === step ? "on" : i < step ? "done" : undefined} aria-current={i === step ? "step" : undefined}>
              <span className="bio-step-n" aria-hidden="true">{i + 1}</span><span className="bio-step-t">{s}</span>
            </li>
          ))}
        </ol>

        {step === 0 ? (
          <fieldset className="modal-section">
            <legend>Manufacturer</legend>
            <div className="bio-choice">
              {makerOpts.map((m) => (
                <label key={m.value} className={`bio-choice-item${d.manufacturer === m.value ? " on" : ""}`}>
                  <input type="radio" name="maker" value={m.value} checked={d.manufacturer === m.value} onChange={() => setD((x) => ({ ...x, manufacturer: m.value, method: "", model: "" }))} />
                  <strong>{m.label}</strong>
                  <span className="meta">{m.value === "other" ? "Through a file import or a documented push method" : `${METHODS_FOR[m.value].map((x) => METHOD_LABEL[x]).join(" · ")}`}</span>
                </label>
              ))}
            </div>
            <p className="meta">Methods listed are those documented by the manufacturer. None has been tested with real hardware yet.</p>
          </fieldset>
        ) : null}

        {step === 1 ? (
          <div className="form-2">
            <FormInput label="Device name" required maxLength={60} value={d.name} onChange={(e) => set("name", e.target.value)} helper="Where it is, e.g. Main entrance (up to 60 characters)" />
            <div className="field">
              <label htmlFor="bio-model">Model <span className="req" aria-hidden="true">*</span></label>
              <input id="bio-model" className="input" list="bio-models" value={d.model} onChange={(e) => set("model", e.target.value)} />
              <datalist id="bio-models">{(d.manufacturer ? MODELS_FOR[d.manufacturer] : []).map((m) => <option key={m} value={m} />)}</datalist>
              <p className="field-msg">From the label or the device’s System info screen.</p>
            </div>
            <FormInput label="Serial number" required value={d.serial} onChange={(e) => set("serial", e.target.value)} helper="System info → Serial number" />
          </div>
        ) : null}

        {step === 2 ? (
          <FormSelect label="Office / location" required value={d.officeId} onChange={(e) => set("officeId", e.target.value)} placeholder="Choose an office" options={offices.map((o) => ({ value: o.id, label: o.name }))} helper="The office where the device is mounted. Punches are counted for that office." />
        ) : null}

        {step === 3 ? (
          <fieldset className="modal-section">
            <legend>How will AttendOS receive punches?</legend>
            <div className="bio-choice">
              {(d.manufacturer ? METHODS_FOR[d.manufacturer] : []).map((m) => (
                <label key={m} className={`bio-choice-item${d.method === m ? " on" : ""}`}>
                  <input type="radio" name="method" value={m} checked={d.method === m} onChange={() => set("method", m)} />
                  <strong>{METHOD_LABEL[m]}</strong>
                  <span className="meta">
                    {m === "sdk_pull" ? "The Sync Agent connects to the device on the office network and reads new punches." : m === "local_push" ? "The device sends punches to the Sync Agent on the office network (never directly to the internet)." : m === "vendor_software" ? "The Sync Agent reads punches from the manufacturer's software the company already runs." : "HR uploads a file exported from the device. Shown as an approved import, never as automatic sync."}
                  </span>
                </label>
              ))}
            </div>
          </fieldset>
        ) : null}

        {step === 4 ? (
          <div className="stack">
            {d.method === "sdk_pull" ? (
              <div className="form-2">
                <FormInput label="Device IP address (office network)" required value={d.deviceIp} onChange={(e) => set("deviceIp", e.target.value)} placeholder="192.168.1.201" />
                <FormInput label="Device port" required value={d.port} onChange={(e) => set("port", e.target.value)} inputMode="numeric" />
              </div>
            ) : null}
            {d.method === "local_push" ? (
              <>
                <div className="form-2">
                  <FormInput label="Device IP address (office network)" required value={d.deviceIp} onChange={(e) => set("deviceIp", e.target.value)} placeholder="192.168.1.201" helper="Extra check only — never the only identity check." />
                  <FormInput label="Agent receiver port" required value={d.receiverPort} onChange={(e) => set("receiverPort", e.target.value)} inputMode="numeric" />
                </div>
                <FormSelect label="How the device proves who it is" value={d.pushAuth} onChange={(e) => set("pushAuth", e.target.value as PushAuth)} options={(Object.keys(PUSH_AUTH_LABEL) as PushAuth[]).map((k) => ({ value: k, label: PUSH_AUTH_LABEL[k] }))} />
                {d.pushAuth === "unauthenticated_lan" ? <div className="alert warning" role="note"><p>Allowed only with Admin acceptance and devices on a separate network. Punches are labelled “unauthenticated”.</p></div> : null}
              </>
            ) : null}
            {d.method === "vendor_software" ? (
              <div className="form-2">
                <FormInput label="Vendor software" required value={d.software} onChange={(e) => set("software", e.target.value)} placeholder={d.manufacturer === "matrix" ? "COSEC CENTRA" : "eTimeTrackLite"} />
                <FormInput label="PC it runs on" required value={d.host} onChange={(e) => set("host", e.target.value)} placeholder="HR-PC-01" />
              </div>
            ) : null}
            {d.method === "file_import" ? <p className="meta">No connection settings: HR uploads files from the import screen (later phase).</p> : null}
            <p className="meta">Passwords and communication keys are entered on the Sync Agent PC, never here.</p>
          </div>
        ) : null}

        {step === 5 ? (
          needsAgent ? (
            <FormSelect
              label="Sync Agent"
              required
              value={d.agentId}
              onChange={(e) => set("agentId", e.target.value)}
              placeholder="Choose an agent"
              options={state.agents.map((a) => ({ value: a.id, label: `${a.name} — ${a.host}${a.status === "online" ? "" : " (offline)"}` }))}
              helper="The agent must be on the same office network as the device. Installing agents is Phase B4."
            />
          ) : (
            <p className="meta">File imports don’t use a Sync Agent.</p>
          )
        ) : null}

        {step === 6 ? (
          <fieldset className="modal-section">
            <legend>Punch direction</legend>
            <div className="bio-choice">
              {(Object.keys(DIRECTION_LABEL) as DirectionMode[]).map((k) => (
                <label key={k} className={`bio-choice-item${d.direction === k ? " on" : ""}`}>
                  <input type="radio" name="dir" value={k} checked={d.direction === k} onChange={() => set("direction", k)} />
                  <strong>{DIRECTION_LABEL[k]}</strong>
                  <span className="meta">{k === "device" ? "Use only if staff really press In / Out / Break on the device. Impossible sequences go to review." : "Recommended. First punch = in; last punch = out once the day closes; a single punch never creates a check-out."}</span>
                </label>
              ))}
            </div>
          </fieldset>
        ) : null}

        {step === 7 ? (
          <dl className="rules-view">
            <dt>Manufacturer</dt><dd>{d.manufacturer ? MANUFACTURER_LABEL[d.manufacturer] : "—"}</dd>
            <dt>Name</dt><dd>{d.name}</dd>
            <dt>Model / serial</dt><dd>{d.model} · <span className="mono">{d.serial}</span></dd>
            <dt>Office</dt><dd>{offices.find((o) => o.id === d.officeId)?.name}</dd>
            <dt>Method</dt><dd>{d.method ? METHOD_LABEL[d.method] : "—"}</dd>
            <dt>Connection</dt><dd>{d.method === "sdk_pull" ? `${d.deviceIp}:${d.port}` : d.method === "local_push" ? `${d.deviceIp} → agent port ${d.receiverPort} · ${PUSH_AUTH_LABEL[d.pushAuth]}` : d.method === "vendor_software" ? `${d.software} on ${d.host}` : "File import"}</dd>
            <dt>Sync Agent</dt><dd>{needsAgent ? state.agents.find((a) => a.id === d.agentId)?.name : "None"}</dd>
            <dt>Direction</dt><dd>{DIRECTION_LABEL[d.direction]}</dd>
            <dt>Status after saving</dt><dd>Not connected — no hardware connection is configured in this demonstration</dd>
          </dl>
        ) : null}

        {error ? <div className="alert danger" role="alert"><p>{error}</p></div> : null}
        <div className="dialog-actions">
          {step > 0 ? <Button onClick={() => { setError(null); setStep(step - 1); }}>Back</Button> : <Button onClick={close}>Cancel</Button>}
          {step < STEPS.length - 1 ? <Button variant="primary" onClick={next}>Next</Button> : <Button variant="primary" onClick={save}>Save sample device</Button>}
        </div>
      </div>
    </Modal>
  );
}
