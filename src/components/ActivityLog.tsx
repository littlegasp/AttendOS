"use client";

import { useState } from "react";
import { describeChanges, SOURCE_LABEL, subjectOf, TARGET_LABEL, type AuditSource } from "@/lib/audit";
import { useSession } from "@/lib/session";
import { supabase } from "@/lib/supabase";
import { useLoad } from "@/lib/use-load";
import { useLookups } from "./employees/lookups";
import { EmptyState, ErrorState, LoadingState } from "./States";
import { Button, SectionCard, StatusBadge } from "./ui";

interface Row {
  id: number;
  at: string;
  action: string;
  target: string;
  actor_employee: string | null;
  source: AuditSource;
  before: Record<string, unknown> | null;
  after: Record<string, unknown> | null;
}

const PAGE = 50;
const ACTION: Record<string, string> = { insert: "Added", update: "Changed", delete: "Removed", approve: "Approved", reject: "Rejected" };

/** Company-wide record of important HR/Admin changes. Read-only for everyone; the database never lets it be edited. */
export function ActivityLog() {
  const { company } = useSession();
  const [target, setTarget] = useState("");
  const [source, setSource] = useState<"" | AuditSource>("");
  const [page, setPage] = useState(0);
  const lookups = useLookups("audit-lookups");
  const { data, error, reload, loading } = useLoad(async () => {
    let q = supabase().from("audit_log").select("id, at, action, target, actor_employee, source, before, after", { count: "exact" });
    if (target) q = q.eq("target", target);
    if (source) q = q.eq("source", source);
    const r = await q.order("at", { ascending: false }).range(page * PAGE, page * PAGE + PAGE - 1);
    if (r.error) throw r.error;
    return { rows: (r.data ?? []) as Row[], count: r.count ?? 0 };
  }, `${target}:${source}:${page}`);

  if (error) return <SectionCard title="Activity log"><ErrorState body={error} onRetry={reload} /></SectionCard>;
  if (!data || !lookups.data) return <LoadingState kind="table" />;
  const L = lookups.data;
  const names: Record<string, string> = Object.fromEntries([
    ...L.people.map((p) => [p.id, p.full_name] as const),
    ...L.departments.map((d) => [d.id, d.name] as const),
    ...L.designations.map((d) => [d.id, d.name] as const),
    ...L.locations.map((d) => [d.id, d.name] as const),
    ...L.shifts.map((d) => [d.id, d.name] as const),
  ]);
  const pages = Math.max(1, Math.ceil(data.count / PAGE));

  return (
    <SectionCard
      title="Activity log"
      subtitle="Every change to people, roles, departments, offices, rules, roster, shifts, holidays, exceptions and corrections, with who made it. Entries can't be edited or deleted."
      actions={
        <>
          <label className="filter-chip">
            <span className="fc-label">Show</span>
            <select value={target} onChange={(e) => { setTarget(e.target.value); setPage(0); }}>
              <option value="">Everything</option>
              {Object.entries(TARGET_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
          </label>
          <label className="filter-chip">
            <span className="fc-label">Who</span>
            <select value={source} onChange={(e) => { setSource(e.target.value as "" | AuditSource); setPage(0); }}>
              <option value="">Everyone</option>
              {(Object.keys(SOURCE_LABEL) as AuditSource[]).map((k) => <option key={k} value={k}>{SOURCE_LABEL[k]}</option>)}
            </select>
          </label>
          <Button size="sm" variant="ghost" onClick={reload} loading={loading}>Refresh</Button>
        </>
      }
    >
      {data.rows.length === 0 ? (
        <EmptyState compact title="Nothing recorded yet" />
      ) : (
        <ul className="audit-list">
          {data.rows.map((a) => {
            const lines = describeChanges(a.before, a.after, names);
            const subject = subjectOf(a.before, a.after, names);
            return (
              <li key={a.id}>
                <span className="meta audit-when">
                  {new Date(a.at).toLocaleString("en-IN", { timeZone: company?.timezone, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })}
                </span>
                <span>
                  <strong>{ACTION[a.action] ?? a.action} {TARGET_LABEL[a.target]?.toLowerCase() ?? a.target}</strong>
                  {subject ? <span> · {subject}</span> : null}
                  <span className="meta"> · by {a.source === "app" ? (a.actor_employee ? names[a.actor_employee] ?? "a former employee" : "a signed-in user") : a.source === "seed" ? "sample data" : "the system"}</span>
                  {a.source === "seed" ? <> <StatusBadge status="weekly-off" label="Sample data" /></> : a.source === "system" ? <> <StatusBadge status="pending" label="Automatic" /></> : null}
                  {lines.length ? <span className="meta block">{lines.slice(0, 6).join(" · ")}{lines.length > 6 ? ` · +${lines.length - 6} more` : ""}</span> : null}
                </span>
              </li>
            );
          })}
        </ul>
      )}
      {pages > 1 ? (
        <div className="pager">
          <Button size="sm" onClick={() => setPage((p) => p - 1)} disabled={page === 0}>‹ Newer</Button>
          <span className="meta">Page {page + 1} of {pages}</span>
          <Button size="sm" onClick={() => setPage((p) => p + 1)} disabled={page + 1 >= pages}>Older ›</Button>
        </div>
      ) : null}
    </SectionCard>
  );
}
