"use client";

import { useState } from "react";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { NavIcon } from "@/components/Icons";
import { PageContainer } from "@/components/PageContainer";
import { EmptyState, ErrorState, LoadingState, PermissionDenied } from "@/components/States";
import { Button, DateInput, FormInput, FormSelect, FormTextarea, GlassCard, MetricCard, SectionCard, StatusBadge, type AttendanceStatus } from "@/components/ui";
import { MATRIX, ROLES, SCOPE_LABEL, type Capability } from "@/lib/permissions";
import { toast } from "@/lib/toast";

const SWATCHES = ["bg", "surface", "elevated", "border", "primary", "secondary", "success", "info", "warning", "danger", "text", "text-2", "text-muted"];
const STATUSES: AttendanceStatus[] = ["present", "late", "absent", "leave", "pending", "approved", "rejected", "verified", "failed", "half-day", "holiday", "weekly-off"];
const CAP_LABEL: Record<Capability, string> = {
  dashboard: "Organization dashboard",
  personalAttendance: "Personal attendance",
  allAttendance: "All attendance records",
  teamAttendance: "Team attendance",
  employees: "Employee directory",
  leave: "Leave requests",
  shifts: "Shift configuration",
  holidays: "Holidays",
  reports: "Reports",
  departments: "Departments",
  settings: "Policies / settings",
  roles: "Roles / permissions",
};

/** Living reference for the Phase 1 design system. Sample values here are labelled as examples. */
export default function DesignPage() {
  const [loading, setLoading] = useState(false);
  const [dialog, setDialog] = useState(false);
  const [name, setName] = useState("");
  const [tried, setTried] = useState(false);
  const nameError = tried && name.trim().length < 2 ? "Enter at least 2 characters." : undefined;

  return (
    <PageContainer title="Design system" subtitle="Tokens and building blocks shared by every AttendOS screen" crumbs={[{ label: "Home", href: "/" }, { label: "Design system" }]}>
      <SectionCard title="Colour tokens" subtitle="Switch the theme from the header to see the light values">
        <div className="swatches">
          {SWATCHES.map((s) => (
            <div key={s} className="swatch">
              <i style={{ background: `var(--color-${s})` }} />
              <code>--color-{s}</code>
            </div>
          ))}
        </div>
      </SectionCard>

      <SectionCard title="Typography" subtitle="Inter, 8px spacing scale">
        <div className="type-demo">
          <p className="page-title">Page title 28/700</p>
          <p className="section-title">Section title 20/600</p>
          <p className="card-title">Card title 16/600</p>
          <p>Body text 14/400 — used for most content.</p>
          <p className="meta">Metadata 12/400</p>
          <p className="metric-value">09:02</p>
        </div>
      </SectionCard>

      <div className="grid-2">
        <SectionCard title="Buttons" subtitle="Loading and disabled states prevent double submits">
          <div className="row">
            <Button variant="primary">Primary</Button>
            <Button>Secondary</Button>
            <Button variant="ghost">Ghost</Button>
            <Button variant="danger">Danger</Button>
            <Button variant="primary" disabled>Disabled</Button>
            <Button
              variant="primary"
              loading={loading}
              onClick={() => {
                setLoading(true);
                setTimeout(() => setLoading(false), 1500);
              }}
            >
              {loading ? "Saving…" : "Try loading"}
            </Button>
            <Button variant="primary" size="lg">Check In</Button>
          </div>
        </SectionCard>

        <SectionCard title="Status badges" subtitle="Text + shape, never colour alone">
          <div className="row">{STATUSES.map((s) => <StatusBadge key={s} status={s} />)}</div>
        </SectionCard>
      </div>

      <div>
        <p className="meta" style={{ marginBottom: 8 }}>Metric cards — example values for display only</p>
        <div className="grid-kpi">
          <MetricCard label="Present Today" value="Example" tone="success" icon={<NavIcon name="people" />} note="Real counts arrive in Phase 2–3" />
          <MetricCard label="Absent Today" value="Example" tone="danger" icon={<NavIcon name="people" />} />
          <MetricCard label="Late Today" value="Example" tone="warning" icon={<NavIcon name="clock" />} />
          <MetricCard label="On Leave" value={null} tone="info" icon={<NavIcon name="leave" />} note="Loading state" />
        </div>
      </div>

      <div className="grid-2">
        <SectionCard title="Form fields" subtitle="Label, helper, validation and focus ring">
          <form
            className="form-grid"
            noValidate
            onSubmit={(e) => {
              e.preventDefault();
              setTried(true);
              if (name.trim().length >= 2) toast({ tone: "success", title: "Form is valid", body: "Nothing was saved — this is the design page." });
            }}
          >
            <FormInput label="Full name" required value={name} onChange={(e) => setName(e.target.value)} error={nameError} helper="As it appears on the employee record." />
            <FormSelect label="Leave type" placeholder="Choose a type" options={[{ value: "casual", label: "Casual" }, { value: "sick", label: "Sick" }, { value: "earned", label: "Earned" }, { value: "unpaid", label: "Unpaid" }]} />
            <DateInput label="Start date" />
            <FormTextarea label="Reason" rows={3} helper="Optional." />
            <div className="row"><Button type="submit" variant="primary">Validate</Button></div>
          </form>
        </SectionCard>

        <SectionCard title="Feedback" subtitle="Toasts and confirmation dialog">
          <div className="row">
            <Button onClick={() => toast({ tone: "success", title: "Checked in at 09:02 AM", body: "Example toast" })}>Success toast</Button>
            <Button onClick={() => toast({ tone: "warning", title: "Accuracy too low", body: "Example toast" })}>Warning toast</Button>
            <Button onClick={() => toast({ tone: "danger", title: "Outside permitted area", body: "Example toast" })}>Error toast</Button>
            <Button variant="danger" onClick={() => setDialog(true)}>Open confirm dialog</Button>
          </div>
          <ConfirmDialog
            open={dialog}
            danger
            title="Deactivate employee?"
            consequence={<p>They will no longer be able to check in. Their attendance history is kept. You can reactivate them later.</p>}
            confirmLabel="Deactivate"
            onCancel={() => setDialog(false)}
            onConfirm={() => {
              setDialog(false);
              toast({ tone: "info", title: "Example only", body: "Nothing was changed." });
            }}
          />
        </SectionCard>
      </div>

      <div className="grid-2">
        <GlassCard><EmptyState title="Empty state" body="Explains why nothing is listed and offers a next step." action={<Button variant="primary">Relevant action</Button>} /></GlassCard>
        <GlassCard><ErrorState body="Human-readable message; input is kept." onRetry={() => toast({ title: "Retry pressed" })} /></GlassCard>
        <GlassCard><PermissionDenied what="Roles & Permissions" /></GlassCard>
        <GlassCard><LoadingState /></GlassCard>
      </div>

      <SectionCard title="Role access matrix" subtitle="From src/lib/permissions.ts — drives navigation and gates now, server checks from Phase 2">
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th scope="col">Capability</th>
                {ROLES.map((r) => <th key={r.id} scope="col">{r.label}</th>)}
              </tr>
            </thead>
            <tbody>
              {(Object.keys(MATRIX) as Capability[]).map((c) => (
                <tr key={c}>
                  <th scope="row">{CAP_LABEL[c]}</th>
                  {ROLES.map((r) => {
                    const s = MATRIX[c][r.id];
                    return <td key={r.id} className={s === "none" ? "muted" : ""}>{SCOPE_LABEL[s]}</td>;
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </SectionCard>
    </PageContainer>
  );
}
