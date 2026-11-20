"use client";

import { Fragment, useState } from "react";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { EmptyState } from "@/components/States";
import { Button, GlassCard, SectionCard } from "@/components/ui";
import { connOf, DIRECTION_LABEL, type DirectionMode, MANUFACTURER_LABEL, METHOD_LABEL, needsAttention, PUSH_AUTH_LABEL, type PushAuth } from "@/lib/biometric-mock";
import { toast } from "@/lib/toast";
import { MappingTable } from "./Mapping";
import { ago, ConnBadge, drift, fmtTime, NotYet, useDemo } from "./shared";
import { SyncTable } from "./SyncActivity";

const CONN_FIELD: Record<string, string> = { deviceIp: "Device IP (LAN)", port: "Device port", receiverPort: "Agent receiver port", pushAuth: "Push authentication", software: "Vendor software", host: "Software host" };

export function DeviceDetail({ id, back }: { id: string; back: () => void }) {
  const { state, offices, apply, tz, now, may } = useDemo();
  const manage = may("manageBiometricDevices");
  const [confirm, setConfirm] = useState(false);
  const d = state.devices.find((x) => x.id === id);
  if (!d) {
    return (
      <GlassCard>
        <EmptyState title="Device not found" body="It may have been added in an earlier session of this demonstration (data resets on reload)." action={<Button onClick={back}>Back to devices</Button>} />
      </GlassCard>
    );
  }
  const agent = state.agents.find((a) => a.id === d.agentId);
  const office = offices.find((o) => o.id === d.officeId);
  const attn = needsAttention(d, state, now);
  const runs = state.syncs.filter((r) => r.deviceId === d.id).sort((a, b) => b.started.localeCompare(a.started));
  const errs = state.errors.filter((e) => e.deviceId === d.id).sort((a, b) => b.at.localeCompare(a.at));
  const deviceMappings = state.mappings.filter((m) => m.deviceId === d.id);
  const nowIso = new Date(now).toISOString();
  const companyWide = state.mappings.filter((m) => m.deviceId === null && (m.validTo === null || m.validTo > nowIso)).length;

  return (
    <div className="stack">
      <button type="button" className="back-link link-btn" onClick={back}>‹ All devices</button>
      <GlassCard className="profile-head-card">
        <div className="ph-main">
          <h2 className="section-title bio-wrap">{d.name}</h2>
          <p className="meta">{MANUFACTURER_LABEL[d.manufacturer]} {d.model} · serial <span className="mono">{d.serial}</span></p>
          <div className="ph-badges">
            <ConnBadge conn={connOf(d)} />
            {attn.map((a) => <span key={a} className="badge tone-warning"><span className="badge-dot" aria-hidden="true" />{a}</span>)}
          </div>
        </div>
        <div className="ph-actions">
          {may("retryBiometricSync") ? <><NotYet label="Test connection" phase="B4" /><NotYet label="Sync now" phase="B4" /></> : null}
          {manage ? (
            <Button variant={d.disabled ? "secondary" : "danger"} size="sm" onClick={() => {
                if (!d.disabled) return setConfirm(true);
                const err = apply({ type: "setDisabled", deviceId: d.id, disabled: false });
                if (err) return toast({ tone: "danger", title: "Not allowed", body: err });
                toast({ tone: "success", title: `${d.name} enabled (demonstration — not saved)`, body: "No device was contacted." });
              }}>
              {d.disabled ? "Enable device" : "Disable device"}
            </Button>
          ) : null}
        </div>
      </GlassCard>

      <div className="grid-2">
        <SectionCard title="Device information">
          <dl className="rules-view">
            <dt>Manufacturer</dt><dd>{MANUFACTURER_LABEL[d.manufacturer]}</dd>
            <dt>Model</dt><dd>{d.model}</dd>
            <dt>Serial number</dt><dd className="mono">{d.serial}</dd>
            <dt>Firmware</dt><dd>{d.firmware || "Not reported yet"}</dd>
            <dt>Office</dt><dd>{office?.name ?? "Not assigned"}</dd>
            <dt>Registered</dt><dd>{fmtTime(d.createdAt, tz)} by {d.createdBy}</dd>
          </dl>
        </SectionCard>
        <SectionCard title="Connection" subtitle="Demonstration values — no device is contacted.">
          <dl className="rules-view">
            <dt>Status</dt><dd><ConnBadge conn={connOf(d)} /></dd>
            <dt>Method</dt><dd>{METHOD_LABEL[d.method]}</dd>
            {Object.entries(d.connection).map(([k, v]) => (
              <Fragment key={k}>
                <dt>{CONN_FIELD[k] ?? k}</dt>
                <dd>{k === "pushAuth" ? PUSH_AUTH_LABEL[v as PushAuth] ?? v : v}</dd>
              </Fragment>
            ))}
            <dt>Last seen</dt><dd>{ago(d.lastSeen, now)} <span className="meta">({fmtTime(d.lastSeen, tz)})</span></dd>
            <dt>Last successful sync</dt><dd>{ago(d.lastSync, now)} <span className="meta">({fmtTime(d.lastSync, tz)})</span></dd>
            <dt>Clock drift</dt><dd className={d.driftS !== null && Math.abs(d.driftS) > 300 ? "text-warning" : undefined}>{drift(d.driftS)}{d.driftS !== null && Math.abs(d.driftS) > 300 ? " — over the 5-minute limit; punches are flagged, never adjusted" : ""}</dd>
          </dl>
          <p className="meta">Device passwords and communication keys are entered on the Sync Agent PC and never stored in AttendOS.</p>
        </SectionCard>
        <SectionCard title="Sync Agent">
          {agent ? (
            <dl className="rules-view">
              <dt>Agent</dt><dd>{agent.name}</dd>
              <dt>Computer</dt><dd>{agent.host}</dd>
              <dt>Status</dt><dd><span className={`badge tone-${agent.status === "online" ? "success" : "danger"}`}><span className="badge-dot" aria-hidden="true" />{agent.status === "online" ? "Online · demo" : "Offline · demo"}</span></dd>
              <dt>Last heartbeat</dt><dd>{ago(agent.lastHeartbeat, now)}</dd>
              <dt>Queue</dt><dd>{agent.queueDepth ? `${agent.queueDepth} punches waiting to upload` : "Empty"}</dd>
              <dt>Version</dt><dd className="mono">{agent.version}</dd>
            </dl>
          ) : (
            <p className="meta">No agent assigned{d.method === "file_import" ? " — file imports are uploaded by HR." : "."}</p>
          )}
        </SectionCard>
        <SectionCard title="Mapping configuration">
          {manage ? (
          <div className="field">
            <label htmlFor="bio-dir">Punch direction</label>
            <select
              id="bio-dir"
              className="input"
              value={d.direction}
              onChange={(e) => {
                const err = apply({ type: "setDirection", deviceId: d.id, direction: e.target.value as DirectionMode });
                if (err) return toast({ tone: "danger", title: "Not allowed", body: err });
                toast({ tone: "success", title: "Direction mode changed (demonstration — not saved)", body: "No device or database setting changed." });
              }}
            >
              {(Object.keys(DIRECTION_LABEL) as DirectionMode[]).map((k) => <option key={k} value={k}>{DIRECTION_LABEL[k]}</option>)}
            </select>
            <p className="field-msg">{d.direction === "device" ? "Use only when staff actually press In / Out / Break on the device." : "First punch of the day = in; last punch = out after the day closes; others shown as extra punches."}</p>
          </div>
          ) : (
            <dl className="rules-view"><dt>Punch direction</dt><dd>{DIRECTION_LABEL[d.direction]} <span className="meta">(changed by Admin)</span></dd></dl>
          )}
          <p className="meta">{companyWide} company-wide codes apply to this device. Device-specific codes below take precedence.</p>
          <MappingTable rows={deviceMappings} showScope={false} />
        </SectionCard>
      </div>

      <SectionCard title="Sync history"><SyncTable runs={runs} showDevice={false} /></SectionCard>
      <SectionCard title="Error history">
        {errs.length ? (
          <ul className="audit-list bio-log">
            {errs.map((e) => (
              <li key={e.id}>
                <div>
                  <strong>{e.kind}</strong> {e.resolved ? <span className="badge tone-success"><span className="badge-dot" aria-hidden="true" />Resolved</span> : null}
                  <p className="small">{e.detail}</p>
                </div>
                <span className="audit-when meta">{fmtTime(e.at, tz)}</span>
              </li>
            ))}
          </ul>
        ) : (
          <EmptyState title="No errors" body="Errors reported by the Sync Agent for this device will be listed here." />
        )}
      </SectionCard>

      <ConfirmDialog
        open={confirm}
        title={`Disable ${d.name}?`}
        consequence="A disabled device's punches are no longer accepted. Its history, codes and sync records stay. In this demonstration only the label changes."
        confirmLabel="Disable device"
        danger
        onCancel={() => setConfirm(false)}
        onConfirm={() => {
          const err = apply({ type: "setDisabled", deviceId: d.id, disabled: true });
          setConfirm(false);
          if (err) return toast({ tone: "danger", title: "Not allowed", body: err });
          toast({ tone: "success", title: `${d.name} disabled (demonstration — not saved)`, body: "No device was contacted." });
        }}
      />
    </div>
  );
}
