"use client";

import Link from "next/link";
import { forwardRef, useId } from "react";

/* ---------------- Cards ---------------- */

export function GlassCard({ className = "", children, as: Tag = "section", ...rest }: React.HTMLAttributes<HTMLElement> & { as?: "section" | "div" | "article" }) {
  return (
    <Tag className={`card glass ${className}`} {...rest}>
      {children}
    </Tag>
  );
}

export function SectionCard({ title, subtitle, actions, children, className = "" }: { title: string; subtitle?: string; actions?: React.ReactNode; children: React.ReactNode; className?: string }) {
  const id = useId();
  return (
    <GlassCard className={className} aria-labelledby={id}>
      <div className="card-head">
        <div>
          <h2 id={id} className="card-title">{title}</h2>
          {subtitle ? <p className="meta">{subtitle}</p> : null}
        </div>
        {actions ? <div className="row">{actions}</div> : null}
      </div>
      {children}
    </GlassCard>
  );
}

export type Tone = "primary" | "success" | "info" | "warning" | "danger" | "neutral";

/** A KPI tile. `value` must come from real data; pass `null` while it loads. */
export function MetricCard({ label, value, note, tone = "neutral", icon, href }: { label: string; value: React.ReactNode | null; note?: string; tone?: Tone; icon?: React.ReactNode; href?: string }) {
  const body = (
    <>
      <div className="metric-top">
        <span className="metric-label">{label}</span>
        {icon ? <span className={`metric-ic tone-${tone}`} aria-hidden="true">{icon}</span> : null}
      </div>
      <div className="metric-value">{value === null ? <i className="skel-line w40" aria-label="Loading" /> : value}</div>
      {note ? <div className="meta">{note}</div> : null}
    </>
  );
  return href ? (
    <Link href={href} className={`card glass metric metric-link tone-edge-${tone}`}>{body}</Link>
  ) : (
    <div className={`card glass metric tone-edge-${tone}`}>{body}</div>
  );
}

/* ---------------- Buttons ---------------- */

type BtnVariant = "primary" | "secondary" | "ghost" | "danger";

export const Button = forwardRef<HTMLButtonElement, React.ButtonHTMLAttributes<HTMLButtonElement> & { variant?: BtnVariant; size?: "sm" | "md" | "lg"; loading?: boolean }>(
  function Button({ variant = "secondary", size = "md", loading = false, disabled, className = "", children, type = "button", ...rest }, ref) {
    return (
      <button
        ref={ref}
        type={type}
        className={`btn ${variant} ${size} ${className}`}
        disabled={disabled || loading}
        aria-busy={loading || undefined}
        {...rest}
      >
        {loading ? <span className="spinner" aria-hidden="true" /> : null}
        <span>{children}</span>
      </button>
    );
  },
);

/* ---------------- Status badge ---------------- */

export type AttendanceStatus = "present" | "absent" | "late" | "leave" | "pending" | "approved" | "rejected" | "verified" | "failed" | "half-day" | "holiday" | "weekly-off";

const STATUS: Record<AttendanceStatus, { label: string; tone: Tone }> = {
  present: { label: "Present", tone: "success" },
  verified: { label: "Verified", tone: "success" },
  approved: { label: "Approved", tone: "success" },
  late: { label: "Late", tone: "warning" },
  pending: { label: "Pending", tone: "warning" },
  "half-day": { label: "Half day", tone: "warning" },
  leave: { label: "On leave", tone: "info" },
  holiday: { label: "Holiday", tone: "info" },
  "weekly-off": { label: "Weekly off", tone: "neutral" },
  absent: { label: "Absent", tone: "danger" },
  rejected: { label: "Rejected", tone: "danger" },
  failed: { label: "Failed", tone: "danger" },
};

/** Status is always shown as text plus a shape, never colour alone. */
export function StatusBadge({ status, label }: { status: AttendanceStatus; label?: string }) {
  const s = STATUS[status];
  return (
    <span className={`badge tone-${s.tone}`}>
      <span className="badge-dot" aria-hidden="true" />
      {label ?? s.label}
    </span>
  );
}

/* ---------------- Form fields ---------------- */

interface FieldProps {
  label: string;
  helper?: string;
  error?: string;
  required?: boolean;
}

function Field({ id, label, helper, error, required, children }: FieldProps & { id: string; children: React.ReactNode }) {
  return (
    <div className={`field${error ? " has-error" : ""}`}>
      <label htmlFor={id}>
        {label}
        {required ? <span className="req" aria-hidden="true"> *</span> : null}
      </label>
      {children}
      {error ? (
        <p id={`${id}-msg`} className="field-msg error" role="alert">{error}</p>
      ) : helper ? (
        <p id={`${id}-msg`} className="field-msg">{helper}</p>
      ) : null}
    </div>
  );
}

export function FormInput({ label, helper, error, required, id, ...rest }: FieldProps & React.InputHTMLAttributes<HTMLInputElement>) {
  const auto = useId();
  const fid = id ?? auto;
  return (
    <Field id={fid} label={label} helper={helper} error={error} required={required}>
      <input id={fid} className="input" required={required} aria-invalid={error ? true : undefined} aria-describedby={error || helper ? `${fid}-msg` : undefined} {...rest} />
    </Field>
  );
}

export function FormSelect({ label, helper, error, required, id, options, placeholder, ...rest }: FieldProps & React.SelectHTMLAttributes<HTMLSelectElement> & { options: { value: string; label: string }[]; placeholder?: string }) {
  const auto = useId();
  const fid = id ?? auto;
  return (
    <Field id={fid} label={label} helper={helper} error={error} required={required}>
      <select id={fid} className="input" required={required} aria-invalid={error ? true : undefined} aria-describedby={error || helper ? `${fid}-msg` : undefined} {...rest}>
        {placeholder ? <option value="">{placeholder}</option> : null}
        {options.map((o) => (
          <option key={o.value} value={o.value}>{o.label}</option>
        ))}
      </select>
    </Field>
  );
}

export function FormTextarea({ label, helper, error, required, id, ...rest }: FieldProps & React.TextareaHTMLAttributes<HTMLTextAreaElement>) {
  const auto = useId();
  const fid = id ?? auto;
  return (
    <Field id={fid} label={label} helper={helper} error={error} required={required}>
      <textarea id={fid} className="input" required={required} aria-invalid={error ? true : undefined} aria-describedby={error || helper ? `${fid}-msg` : undefined} {...rest} />
    </Field>
  );
}

export function DateInput(props: FieldProps & React.InputHTMLAttributes<HTMLInputElement>) {
  return <FormInput type="date" {...props} />;
}
