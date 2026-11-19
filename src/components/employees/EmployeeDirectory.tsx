"use client";

import { useEffect, useState } from "react";
import { EmptyState, ErrorState, LoadingState } from "@/components/States";
import { Button, GlassCard, StatusBadge } from "@/components/ui";
import { filterOps, initials, NO_FILTERS, statusLabel, EMPLOYMENT_STATUS, type Employee, type Filters } from "@/lib/employees";
import { can } from "@/lib/permissions";
import { useSession } from "@/lib/session";
import { supabase } from "@/lib/supabase";
import { useLoad } from "@/lib/use-load";
import { EMP_SELECT, type Lookups } from "./lookups";

const PAGE = 25;

const ROLE_LABEL: Record<string, string> = { admin: "Admin", hr: "HR", manager: "Manager", employee: "Employee" };

export function shortDay(d: string | null) {
  return d ? new Date(`${d}T12:00:00Z`).toLocaleDateString("en-IN", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" }) : "—";
}

/**
 * Searchable, filterable list of people. Searching and filtering run in the database
 * (PostgREST filters), and row level security limits rows to what the role may see.
 */
export function EmployeeDirectory({ lookups, onOpen, onAdd, refreshKey }: { lookups: Lookups; onOpen: (id: string) => void; onAdd: () => void; refreshKey: number }) {
  const { role } = useSession();
  const manage = can(role, "manageEmployees");
  const [f, setF] = useState<Filters>(NO_FILTERS);
  const [q, setQ] = useState("");
  const [page, setPage] = useState(0);

  // Search as you type, after a short pause.
  useEffect(() => {
    const t = setTimeout(() => {
      setF((x) => ({ ...x, q }));
      setPage(0);
    }, 300);
    return () => clearTimeout(t);
  }, [q]);

  const key = JSON.stringify({ f, page, refreshKey });
  const { data, error, loading, reload } = useLoad(async () => {
    let query = supabase().from("employees").select(EMP_SELECT, { count: "exact" });
    for (const o of filterOps(f)) query = o.op === "or" ? query.or(String(o.value)) : query.eq(o.col, o.value);
    const r = await query.order("full_name").range(page * PAGE, page * PAGE + PAGE - 1);
    if (r.error) throw r.error;
    return { rows: (r.data ?? []) as unknown as Employee[], count: r.count ?? 0 };
  }, key);

  const setFilter = (k: keyof Filters) => (e: React.ChangeEvent<HTMLSelectElement>) => {
    setF((x) => ({ ...x, [k]: e.target.value }));
    setPage(0);
  };
  const active = (Object.keys(NO_FILTERS) as (keyof Filters)[]).filter((k) => k !== "q" && f[k] !== NO_FILTERS[k]).length;
  const pages = data ? Math.max(1, Math.ceil(data.count / PAGE)) : 1;

  return (
    <GlassCard className="emp-dir">
      <div className="emp-toolbar">
        <div className="emp-search">
          <label className="sr-only" htmlFor="emp-q">Search people</label>
          <input id="emp-q" className="input" type="search" placeholder="Search name, e-mail, employee ID or phone…" value={q} onChange={(e) => setQ(e.target.value)} />
        </div>
        {manage ? <Button variant="primary" onClick={onAdd}>Add employee</Button> : null}
      </div>
      {manage || role === "manager" ? (
        <div className="emp-filters" role="group" aria-label="Filters">
          <FilterSelect label="Department" value={f.department} onChange={setFilter("department")} options={lookups.departments.map((d) => ({ value: d.id, label: d.name }))} />
          <FilterSelect label="Designation" value={f.designation} onChange={setFilter("designation")} options={lookups.designations.map((d) => ({ value: d.id, label: d.name }))} />
          <FilterSelect label="Office" value={f.office} onChange={setFilter("office")} options={lookups.locations.map((d) => ({ value: d.id, label: d.name }))} />
          <FilterSelect label="Employment" value={f.status} onChange={setFilter("status")} options={EMPLOYMENT_STATUS} />
          <FilterSelect label="Role" value={f.role} onChange={setFilter("role")} options={Object.entries(ROLE_LABEL).map(([value, label]) => ({ value, label }))} />
          <FilterSelect
            label="Access"
            value={f.access}
            onChange={setFilter("access")}
            all={false}
            options={[
              { value: "active", label: "Active" },
              { value: "inactive", label: "Deactivated" },
              { value: "all", label: "Everyone" },
            ]}
          />
          {active ? (
            <button type="button" className="link-btn small" onClick={() => { setF({ ...NO_FILTERS, q: f.q }); setPage(0); }}>
              Clear filters ({active})
            </button>
          ) : null}
        </div>
      ) : null}

      {error ? (
        <ErrorState title="Couldn't load people" body={error} onRetry={reload} />
      ) : !data ? (
        <LoadingState kind="table" label="Loading people" />
      ) : data.rows.length === 0 ? (
        <EmptyState
          title={f.q || active ? "No one matches" : "No people yet"}
          body={f.q || active ? "Try a different search or clear the filters." : manage ? "Add your first employee. They can sign in once they sign up with the same e-mail." : "People appear here once HR adds them."}
          action={manage && !f.q && !active ? <Button variant="primary" onClick={onAdd}>Add employee</Button> : undefined}
        />
      ) : (
        <>
          <p className="meta" aria-live="polite">
            {data.count} {data.count === 1 ? "person" : "people"}
            {loading ? " · updating…" : ""}
          </p>
          <div className="table-wrap emp-table">
            <table className="table">
              <thead>
                <tr>
                  <th scope="col">Person</th><th scope="col">ID</th><th scope="col">Department</th><th scope="col">Designation</th>
                  <th scope="col">Reports to</th><th scope="col">Office</th><th scope="col">Joined</th><th scope="col">Status</th>
                </tr>
              </thead>
              <tbody>
                {data.rows.map((e) => (
                  <tr key={e.id} className="row-link" onClick={() => onOpen(e.id)}>
                    <th scope="row">
                      <button type="button" className="person-cell" onClick={(ev) => { ev.stopPropagation(); onOpen(e.id); }}>
                        <span className="avatar sm" aria-hidden="true">{initials(e.full_name)}</span>
                        <span>
                          <span className="pc-name">{e.full_name}</span>
                          <span className="tiny muted block">{e.email}</span>
                        </span>
                      </button>
                    </th>
                    <td className="mono">{e.emp_code ?? "—"}</td>
                    <td>{e.department?.name ?? <span className="muted">—</span>}</td>
                    <td>{e.designation?.name ?? <span className="muted">—</span>}</td>
                    <td>{e.manager?.full_name ?? <span className="muted">—</span>}</td>
                    <td>{e.office?.name ?? <span className="muted">Any</span>}</td>
                    <td>{shortDay(e.joining_date)}</td>
                    <td>
                      <span className="badge-stack">
                        {!e.active ? <StatusBadge status="failed" label="Deactivated" /> : <StatusBadge status={e.employment_status === "probation" || e.employment_status === "notice_period" ? "pending" : "verified"} label={statusLabel(e.employment_status)} />}
                        {e.role !== "employee" ? <span className="role-tag">{ROLE_LABEL[e.role]}</span> : null}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <ul className="emp-cards" aria-label="People">
            {data.rows.map((e) => (
              <li key={e.id}>
                <button type="button" className="emp-card" onClick={() => onOpen(e.id)}>
                  <span className="avatar" aria-hidden="true">{initials(e.full_name)}</span>
                  <span className="ec-main">
                    <strong>{e.full_name}</strong>
                    <span className="meta block">{[e.emp_code, e.designation?.name, e.department?.name].filter(Boolean).join(" · ") || e.email}</span>
                  </span>
                  {!e.active ? <StatusBadge status="failed" label="Off" /> : e.role !== "employee" ? <span className="role-tag">{ROLE_LABEL[e.role]}</span> : null}
                </button>
              </li>
            ))}
          </ul>
          {pages > 1 ? (
            <div className="pager">
              <Button size="sm" onClick={() => setPage((p) => p - 1)} disabled={page === 0}>‹ Previous</Button>
              <span className="meta">Page {page + 1} of {pages}</span>
              <Button size="sm" onClick={() => setPage((p) => p + 1)} disabled={page + 1 >= pages}>Next ›</Button>
            </div>
          ) : null}
        </>
      )}
    </GlassCard>
  );
}

function FilterSelect({ label, value, onChange, options, all = true }: { label: string; value: string; onChange: (e: React.ChangeEvent<HTMLSelectElement>) => void; options: { value: string; label: string }[]; all?: boolean }) {
  return (
    <label className={`filter-chip${value && (all || value !== "active") ? " on" : ""}`}>
      <span className="fc-label">{label}</span>
      <select value={value} onChange={onChange}>
        {all ? <option value="">All</option> : null}
        {options.map((o) => (
          <option key={o.value} value={o.value}>{o.label}</option>
        ))}
      </select>
    </label>
  );
}
