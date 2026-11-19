"use client";

import Link from "next/link";
import { useState } from "react";
import { brandCss, BRAND } from "@/lib/brand";
import { DATE_FORMATS, formatDay } from "@/lib/dates";
import { CAP_LABEL, MATRIX, ROLES, SCOPE_LABEL, can, roleLabel, type Capability, type Role } from "@/lib/permissions";
import { useSession } from "@/lib/session";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";
import { must, useLoad } from "@/lib/use-load";
import { EmptyState, ErrorState, LoadingState } from "./States";
import { Button, FormInput, FormSelect, SectionCard, StatusBadge } from "./ui";

/** The role matrix as the app uses it (src/lib/permissions.ts). The database enforces the same rules. */
export function RoleMatrix() {
  return (
    <SectionCard title="What each role can do" subtitle="Applied on every screen and enforced again by the database (row level security and checked functions).">
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th scope="col">Capability</th>{ROLES.map((r) => <th key={r.id} scope="col">{r.label}</th>)}</tr></thead>
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
      <p className="tiny muted">Roles are fixed (Admin, HR, Manager, Employee). Custom roles would be a later change to this table and the database rules together.</p>
    </SectionCard>
  );
}

interface Access {
  employee_id: string;
  emp_code: string | null;
  full_name: string;
  email: string;
  role: Role;
  active: boolean;
  employment_status: string;
  login_linked: boolean;
  email_confirmed: boolean;
  last_sign_in_at: string | null;
}

/** Admin only: who can sign in, with which role, and when they last did. Role changes happen on the profile. */
export function UserAccess() {
  const { company, role } = useSession();
  const [filter, setFilter] = useState<"" | Role | "nologin" | "off">("");
  const { data, error, reload } = useLoad(async () => must(await supabase().rpc("user_access")) as Access[], "user-access");
  if (!can(role, "assignRoles")) return null;
  if (error) return <SectionCard title="User access"><ErrorState body={error} onRetry={reload} /></SectionCard>;
  if (!data) return <LoadingState kind="table" />;
  const rows = data.filter((a) => !filter || (filter === "nologin" ? !a.login_linked && a.active : filter === "off" ? !a.active : a.role === filter));
  const counts = ROLES.map((r) => `${data.filter((a) => a.role === r.id && a.active).length} ${r.label}`).join(" · ");
  return (
    <SectionCard
      title="User access"
      subtitle={`${counts} · ${data.filter((a) => a.active && !a.login_linked).length} without a login yet`}
      actions={
        <label className="filter-chip"><span className="fc-label">Show</span>
          <select value={filter} onChange={(e) => setFilter(e.target.value as typeof filter)}>
            <option value="">Everyone</option>{ROLES.map((r) => <option key={r.id} value={r.id}>{r.label}s</option>)}
            <option value="nologin">No login yet</option><option value="off">Access off</option>
          </select></label>
      }
    >
      {rows.length === 0 ? <EmptyState compact title="No one matches" /> : (
        <div className="table-wrap">
          <table className="table">
            <thead><tr><th scope="col">Person</th><th scope="col">Role</th><th scope="col">Access</th><th scope="col">Login</th><th scope="col">Last sign-in</th><th scope="col"><span className="sr-only">Actions</span></th></tr></thead>
            <tbody>
              {rows.map((a) => (
                <tr key={a.employee_id}>
                  <th scope="row">{a.full_name}<span className="tiny muted block">{a.email}{a.emp_code ? ` · ${a.emp_code}` : ""}</span></th>
                  <td><span className="role-tag">{roleLabel(a.role)}</span></td>
                  <td>{a.active ? <StatusBadge status="verified" label="On" /> : <StatusBadge status="failed" label="Off" />}</td>
                  <td>{a.login_linked ? <StatusBadge status="present" label={a.email_confirmed ? "Linked · e-mail confirmed" : "Linked"} /> : <StatusBadge status="weekly-off" label="No login yet" />}</td>
                  <td>{a.last_sign_in_at ? new Date(a.last_sign_in_at).toLocaleString("en-IN", { timeZone: company?.timezone, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : <span className="muted">Never</span>}</td>
                  <td><Link className="btn ghost sm" href={`/employees?id=${a.employee_id}`}>Profile</Link></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="tiny muted">Change a role or switch access off from the person&apos;s profile (Employees). Only an Admin can assign Manager, HR or Admin.</p>
    </SectionCard>
  );
}

interface CompanyRow {
  id: string; name: string; slug: string; timezone: string; app_name: string | null; logo_url: string | null;
  accent_dark: string | null; accent_light: string | null; date_format: string; full_day_minutes: number | null; leave_year_start_month: number;
}
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const HEX = /^#[0-9a-fA-F]{6}$/;

/** Settings → General: company details, branding, date format, half-day rule and leave year. Admin edits; HR reads. */
export function GeneralSettings() {
  const { role, companyId, refreshCompany } = useSession();
  const admin = can(role, "editPolicy");
  const { data, error, reload } = useLoad(async () => must(await supabase().from("companies")
    .select("id, name, slug, timezone, app_name, logo_url, accent_dark, accent_light, date_format, full_day_minutes, leave_year_start_month").eq("id", companyId!).single()) as CompanyRow, "general");
  const [f, setF] = useState<CompanyRow | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  if (error) return <SectionCard title="General"><ErrorState body={error} onRetry={reload} /></SectionCard>;
  if (!data) return <LoadingState kind="table" />;
  const v = f ?? data;
  const set = (k: keyof CompanyRow) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF({ ...v, [k]: e.target.value });
  const fullHours = v.full_day_minutes ? String(Math.round((v.full_day_minutes / 60) * 10) / 10) : "";
  const problems: Record<string, string | undefined> = {
    name: v.name.trim().length < 2 ? "Enter the company name." : undefined,
    logo_url: v.logo_url && !/^https:\/\/\S+$/.test(v.logo_url) ? "Use an https:// address of an image." : undefined,
    accent_dark: v.accent_dark && !HEX.test(v.accent_dark) ? "Use a colour like #FF7A00." : undefined,
    accent_light: v.accent_light && !HEX.test(v.accent_light) ? "Use a colour like #F97316." : undefined,
  };
  const accentPair = Boolean(v.accent_dark) === Boolean(v.accent_light) ? undefined : "Set both accent colours, or neither.";
  async function save() {
    if (Object.values(problems).some(Boolean) || accentPair) return setErr("Check the highlighted fields.");
    setBusy(true);
    setErr(null);
    const row = {
      name: v.name.trim(), app_name: v.app_name?.trim() || null, logo_url: v.logo_url?.trim() || null,
      accent_dark: v.accent_dark?.trim() || null, accent_light: v.accent_light?.trim() || null, date_format: v.date_format,
      full_day_minutes: v.full_day_minutes ? Number(v.full_day_minutes) : null, leave_year_start_month: Number(v.leave_year_start_month),
    };
    const { error: e } = await supabase().from("companies").update(row).eq("id", data!.id);
    setBusy(false);
    if (e) return setErr(friendlyError(e));
    toast({ tone: "success", title: "Settings saved", body: "Everyone sees the change on their next screen." });
    setF(null);
    reload();
    refreshCompany();
  }
  const preview = v.accent_dark && v.accent_light && HEX.test(v.accent_dark) && HEX.test(v.accent_light)
    ? brandCss({ ...BRAND, accent: { dark: v.accent_dark, light: v.accent_light, darkSoft: v.accent_dark, lightSoft: v.accent_light } }) : "";
  return (
    <SectionCard title="General" subtitle={admin ? "Company details, branding and formats. Administrators only." : "Read-only: an administrator changes these."}>
      <fieldset className="form-grid" disabled={!admin || busy}>
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <div className="form-2">
          <FormInput label="Company name" required value={v.name} onChange={set("name")} error={problems.name} maxLength={120} />
          <FormInput label="Sign-in address" value={`/login?company=${v.slug}`} readOnly helper="Set by the platform owner." />
        </div>
        <div className="form-2">
          <FormInput label="App name (optional)" value={v.app_name ?? ""} onChange={set("app_name")} helper="Shown instead of the company name in the menu, e.g. “Acme People”." maxLength={40} />
          <FormInput label="Logo address (optional)" value={v.logo_url ?? ""} onChange={set("logo_url")} error={problems.logo_url} helper="An https:// link to a square PNG or SVG." />
        </div>
        <div className="form-2">
          <FormInput label="Accent colour — dark theme" value={v.accent_dark ?? ""} onChange={set("accent_dark")} error={problems.accent_dark ?? accentPair} placeholder="#FF7A00" />
          <FormInput label="Accent colour — light theme" value={v.accent_light ?? ""} onChange={set("accent_light")} error={problems.accent_light} placeholder="#F97316" helper="Status colours (present, late, absent…) never change." />
        </div>
        {preview ? <p className="tiny muted">Accent preview: <span className="accent-swatch" style={{ background: v.accent_dark! }} /> dark · <span className="accent-swatch" style={{ background: v.accent_light! }} /> light</p> : null}
        <div className="form-2">
          <FormSelect label="Date format" value={v.date_format} onChange={set("date_format")} options={DATE_FORMATS.map((d) => ({ value: d, label: `${d} — ${formatDay("2026-11-19", d)}` }))} />
          <FormInput label="Time zone" value={v.timezone} readOnly helper="Changed under Locations & GPS → Attendance rules." />
        </div>
        <div className="form-2">
          <FormInput label="Full day needs at least (hours)" type="number" step="0.5" min="1" max="16" value={fullHours}
            onChange={(e) => setF({ ...v, full_day_minutes: e.target.value ? Math.round(Number(e.target.value) * 60) : null })}
            helper="Half-day rule: present days with less worked time count as half days in reports. Empty = off." />
          <FormSelect label="Leave year starts in" value={String(v.leave_year_start_month)} onChange={set("leave_year_start_month")}
            options={MONTHS.map((m, i) => ({ value: String(i + 1), label: `${m}${i === 0 ? " (January–December)" : i === 3 ? " (April–March)" : ""}` }))} helper="Leave balances reset at the start of each leave year." />
        </div>
        {admin ? (
          <div className="dialog-actions">
            <Button variant="ghost" onClick={() => { setF(null); setErr(null); }} disabled={!f || busy}>Discard changes</Button>
            <Button variant="primary" loading={busy} disabled={!f} onClick={save}>Save settings</Button>
          </div>
        ) : null}
      </fieldset>
    </SectionCard>
  );
}
