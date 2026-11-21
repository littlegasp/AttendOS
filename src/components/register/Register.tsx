"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { DayTimeline } from "@/components/DayTimeline";
import { ProvisionalOut, SourceBadges } from "@/components/SourceBadges";
import { EmptyState, ErrorState, LoadingState } from "@/components/States";
import { Tabs } from "@/components/Tabs";
import { Button, FormInput, GlassCard, SectionCard, StatusBadge } from "@/components/ui";
import { STATUS_BADGE, clock, hm } from "@/lib/attendance";
import { downloadCsv, toCsv } from "@/lib/csv";
import { formatDay, monthOf, shiftMonth } from "@/lib/dates";
import { todayIn } from "@/lib/employees";
import { can } from "@/lib/permissions";
import {
  NO_REGISTER_FILTERS,
  personTotals,
  REGISTER_STATUSES,
  sortRows,
  STATUS_LETTER,
  statusText,
  type RegisterFilters,
  type RegisterRow,
} from "@/lib/register";
import { useSession } from "@/lib/session";
import { csvSource, daySourceKey, type DaySourceMap, loadDaySources } from "@/lib/sources";
import { supabase } from "@/lib/supabase";
import { must, useLoad } from "@/lib/use-load";

type View = "daily" | "monthly" | "person";
const KEY = "attendos.register";
const LIMIT = 5000;
const PAGE = 50;

interface Lookup { id: string; name: string; active: boolean }
interface Person { id: string; full_name: string; emp_code: string | null; active: boolean }

/** The same columns on screen and in the CSV, so an export never shows more than the screen. Source (B4) is added last so existing columns keep their place. */
function csvCols(tz: string, fmt: string, src: DaySourceMap | null | undefined) {
  return [
    { label: "Employee", value: (r: RegisterRow) => r.full_name },
    { label: "Employee ID", value: (r: RegisterRow) => r.emp_code },
    { label: "Department", value: (r: RegisterRow) => r.department },
    { label: "Date", value: (r: RegisterRow) => formatDay(r.work_date, fmt) },
    { label: "Shift", value: (r: RegisterRow) => r.shift_name },
    { label: "Work location", value: (r: RegisterRow) => r.work_mode },
    { label: "Check-in", value: (r: RegisterRow) => (r.first_in ? clock(r.first_in, tz) : "") },
    { label: "Check-out", value: (r: RegisterRow) => (r.last_out ? clock(r.last_out, tz) : "") },
    { label: "Working hours", value: (r: RegisterRow) => (r.worked_min ? (r.worked_min / 60).toFixed(2) : "") },
    { label: "Break (min)", value: (r: RegisterRow) => r.break_min || "" },
    { label: "Late (min)", value: (r: RegisterRow) => r.late_min || "" },
    { label: "Early leave (min)", value: (r: RegisterRow) => r.early_min || "" },
    { label: "Overtime (min)", value: (r: RegisterRow) => r.overtime_min || "" },
    { label: "Status", value: (r: RegisterRow) => statusText(r.status) + (r.half_day ? " (half day)" : "") },
    { label: "Note", value: (r: RegisterRow) => r.note },
    { label: "Source", value: (r: RegisterRow) => csvSource(src, r.employee_id, r.work_date) },
  ];
}

function loadSaved(): { view: View; f: RegisterFilters } {
  try {
    const v = JSON.parse(localStorage.getItem(KEY) ?? "null");
    if (v && ["daily", "monthly", "person"].includes(v.view)) return { view: v.view, f: { ...NO_REGISTER_FILTERS, ...v.f } };
  } catch {
    /* not remembered */
  }
  return { view: "daily", f: NO_REGISTER_FILTERS };
}

export function Register() {
  const { company, role } = useSession();
  const tz = company?.timezone ?? "Asia/Kolkata";
  const fmt = company?.date_format ?? "DD MMM YYYY";
  const today = todayIn(tz);
  const [view, setView] = useState<View>("daily");
  const [f, setF] = useState<RegisterFilters>(NO_REGISTER_FILTERS);
  const [day, setDay] = useState(today);
  const [month, setMonth] = useState(monthOf(today).from);
  const [page, setPage] = useState(0);
  const [sort, setSort] = useState<{ key: keyof RegisterRow; dir: 1 | -1 }>({ key: "full_name", dir: 1 });

  useEffect(() => {
    const s = loadSaved();
    setView(s.view);
    setF(s.f);
  }, []);
  useEffect(() => {
    try {
      localStorage.setItem(KEY, JSON.stringify({ view, f }));
    } catch {
      /* not remembered */
    }
  }, [view, f]);

  const lookups = useLoad(async () => {
    const sb = supabase();
    const [departments, shifts, people] = await Promise.all([
      sb.from("departments").select("id, name, active").order("name").then(must<Lookup[]>),
      sb.from("shifts").select("id, name, active").order("name").then(must<Lookup[]>),
      sb.rpc("people_directory").then(must<Person[]>),
    ]);
    return { departments, shifts, people };
  }, "register-lookups");

  const m = monthOf(month);
  const range = view === "daily" ? { from: day, to: day } : { from: m.from, to: m.to > today ? today : m.to };
  const personNeeded = view === "person" && !f.employee;
  const { data, error, loading, reload } = useLoad(async () => {
    if (personNeeded || range.to < range.from) return [] as RegisterRow[];
    return must(await supabase().rpc("attendance_register", {
      p_from: range.from, p_to: range.to, p_department: f.department || null, p_employee: f.employee || null,
      p_shift: f.shift || null, p_status: view === "monthly" ? null : f.status || null, p_limit: LIMIT, p_offset: 0,
    })) as RegisterRow[];
  }, `${view}:${range.from}:${range.to}:${f.department}:${f.employee}:${f.shift}:${f.status}`);

  const sources = useLoad(async () => {
    if (personNeeded || range.to < range.from) return null;
    return loadDaySources(supabase(), range.from, range.to, f.department || null, f.employee || null);
  }, `src:${view}:${range.from}:${range.to}:${f.department}:${f.employee}`);
  const [timeline, setTimeline] = useState<RegisterRow | null>(null);

  const rows = useMemo(() => (data ? sortRows(data as unknown as Record<string, unknown>[], sort.key as string, sort.dir) as unknown as RegisterRow[] : []), [data, sort]);
  useEffect(() => setPage(0), [view, day, month, f]);
  const set = (k: keyof RegisterFilters) => (e: React.ChangeEvent<HTMLSelectElement>) => setF((x) => ({ ...x, [k]: e.target.value }));
  const active = (Object.keys(f) as (keyof RegisterFilters)[]).filter((k) => f[k]).length;
  const truncated = Boolean(data && data[0] && data[0].total > LIMIT);

  function exportCsv() {
    const label = view === "daily" ? day : `${m.from.slice(0, 7)}`;
    downloadCsv(`attendance-${view}-${label}`, toCsv(rows, csvCols(tz, fmt, sources.data)));
  }

  const L = lookups.data;
  return (
    <>
      <Tabs label="Register view" value={view} onChange={setView} tabs={[{ id: "daily", label: "Daily" }, { id: "monthly", label: "Monthly" }, { id: "person", label: "Employee detail" }]} />
      <div role="tabpanel" id={`panel-${view}`} aria-labelledby={`tab-${view}`} className="tab-panel">
        <GlassCard className="reg-filters">
          <div className="emp-filters">
            {view === "daily" ? (
              <FormInput label="Date" type="date" value={day} max={today} onChange={(e) => e.target.value && setDay(e.target.value)} />
            ) : (
              <div className="month-nav">
                <span className="fc-label">Month</span>
                <div className="row">
                  <Button size="sm" variant="ghost" aria-label="Previous month" onClick={() => setMonth(shiftMonth(month, -1))}>‹</Button>
                  <strong aria-live="polite">{m.label}</strong>
                  <Button size="sm" variant="ghost" aria-label="Next month" disabled={shiftMonth(month, 1) > today} onClick={() => setMonth(shiftMonth(month, 1))}>›</Button>
                </div>
              </div>
            )}
            {L ? (
              <>
                <label className="filter-chip"><span className="fc-label">Department</span>
                  <select value={f.department} onChange={set("department")}><option value="">All</option>{L.departments.map((d) => <option key={d.id} value={d.id}>{d.name}{d.active ? "" : " (not in use)"}</option>)}</select></label>
                <label className="filter-chip"><span className="fc-label">Employee</span>
                  <select value={f.employee} onChange={set("employee")}><option value="">{view === "person" ? "Choose…" : "All"}</option>{L.people.map((p) => <option key={p.id} value={p.id}>{p.full_name}{p.active ? "" : " (inactive)"}</option>)}</select></label>
                <label className="filter-chip"><span className="fc-label">Shift</span>
                  <select value={f.shift} onChange={set("shift")}><option value="">All</option>{L.shifts.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
                {view !== "monthly" ? (
                  <label className="filter-chip"><span className="fc-label">Status</span>
                    <select value={f.status} onChange={set("status")}>{REGISTER_STATUSES.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}</select></label>
                ) : null}
              </>
            ) : null}
            {active ? <Button size="sm" variant="ghost" onClick={() => setF(NO_REGISTER_FILTERS)}>Clear filters ({active})</Button> : null}
            <span className="grow" />
            {can(role, "exportReports") ? <Button size="sm" onClick={exportCsv} disabled={!rows.length}>Export CSV</Button> : null}
          </div>
          <p className="tiny muted">
            {role === "manager" ? "Your team only. " : ""}Times in {tz}. Export opens in Excel or Google Sheets and holds exactly what this view shows.
          </p>
        </GlassCard>

        {error ? <GlassCard><ErrorState body={error} onRetry={reload} /></GlassCard> : personNeeded ? (
          <GlassCard><EmptyState title="Choose an employee" body="Pick a person in the Employee filter to see their month day by day." /></GlassCard>
        ) : !data ? <LoadingState kind="table" /> : rows.length === 0 ? (
          <GlassCard><EmptyState title="No records" body={active ? "Nothing matches these filters. Clear them or choose another date." : "No one was due on this date (or it's in the future)."} /></GlassCard>
        ) : view === "monthly" ? (
          <MonthGrid rows={rows} from={m.from} to={range.to} fmt={fmt} loading={loading} />
        ) : (
          <SectionCard title={view === "daily" ? formatDay(day, fmt) : `${rows[0]!.full_name} · ${m.label}`} subtitle={`${rows.length} ${rows.length === 1 ? "record" : "records"}${truncated ? ` (first ${LIMIT} — narrow the filters)` : ""}`}
            actions={view === "person" ? <Link className="btn ghost sm" href={`/employees?id=${f.employee}`}>Open profile</Link> : undefined}>
            <DayTable rows={rows.slice(page * PAGE, page * PAGE + PAGE)} tz={tz} fmt={fmt} sort={sort} onSort={(key) => setSort((s) => ({ key, dir: s.key === key ? (s.dir === 1 ? -1 : 1) : 1 }))} showDate={view !== "daily"} src={sources.data} onTimeline={setTimeline} />
            {rows.length > PAGE ? (
              <div className="pager">
                <Button size="sm" onClick={() => setPage((p) => p - 1)} disabled={page === 0}>‹ Previous</Button>
                <span className="meta">Page {page + 1} of {Math.ceil(rows.length / PAGE)}</span>
                <Button size="sm" onClick={() => setPage((p) => p + 1)} disabled={(page + 1) * PAGE >= rows.length}>Next ›</Button>
              </div>
            ) : null}
          </SectionCard>
        )}
      </div>
      {timeline ? <DayTimeline employeeId={timeline.employee_id} name={timeline.full_name} day={timeline.work_date} tz={tz} onClose={() => setTimeline(null)} /> : null}
    </>
  );
}

function SortTh({ label, k, sort, onSort }: { label: string; k: keyof RegisterRow; sort: { key: keyof RegisterRow; dir: 1 | -1 }; onSort: (k: keyof RegisterRow) => void }) {
  const on = sort.key === k;
  return (
    <th scope="col" aria-sort={on ? (sort.dir === 1 ? "ascending" : "descending") : "none"}>
      <button type="button" className="th-sort" onClick={() => onSort(k)}>{label}{on ? (sort.dir === 1 ? " ▲" : " ▼") : ""}</button>
    </th>
  );
}

function DayTable({ rows, tz, fmt, sort, onSort, showDate, src, onTimeline }: { rows: RegisterRow[]; tz: string; fmt: string; sort: { key: keyof RegisterRow; dir: 1 | -1 }; onSort: (k: keyof RegisterRow) => void; showDate: boolean; src: DaySourceMap | null | undefined; onTimeline: (r: RegisterRow) => void }) {
  return (
    <div className="table-wrap">
      <table className="table">
        <thead>
          <tr>
            <SortTh label="Employee" k="full_name" sort={sort} onSort={onSort} />
            <SortTh label="ID" k="emp_code" sort={sort} onSort={onSort} />
            <SortTh label="Department" k="department" sort={sort} onSort={onSort} />
            {showDate ? <SortTh label="Date" k="work_date" sort={sort} onSort={onSort} /> : null}
            <th scope="col">Shift</th>
            <SortTh label="Check-in" k="first_in" sort={sort} onSort={onSort} />
            <SortTh label="Check-out" k="last_out" sort={sort} onSort={onSort} />
            <SortTh label="Working hours" k="worked_min" sort={sort} onSort={onSort} />
            <SortTh label="Late" k="late_min" sort={sort} onSort={onSort} />
            <SortTh label="Status" k="status" sort={sort} onSort={onSort} />
            <th scope="col">Source</th>
            <th scope="col"><span className="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={`${r.employee_id}:${r.work_date}`}>
              <th scope="row">{r.full_name}</th>
              <td className="mono">{r.emp_code ?? "—"}</td>
              <td>{r.department ?? <span className="muted">—</span>}</td>
              {showDate ? <td>{formatDay(r.work_date, fmt)}</td> : null}
              <td>{r.shift_name ?? <span className="muted">—</span>}</td>
              <td>{r.first_in ? clock(r.first_in, tz) : "—"}</td>
              <td>{r.last_out ? clock(r.last_out, tz) : src?.get(daySourceKey(r.employee_id, r.work_date))?.pending ? <ProvisionalOut /> : "—"}</td>
              <td>{r.worked_min ? hm(r.worked_min) : "—"}{r.half_day ? <span className="tiny muted block">Half day</span> : null}</td>
              <td>{r.late_min ? <span className="text-warning">{hm(r.late_min)}</span> : "—"}</td>
              <td>
                <StatusBadge status={STATUS_BADGE[r.status] ?? "weekly-off"} label={statusText(r.status)} />
                {r.pending_correction ? <span className="tiny muted block">Correction pending</span> : null}
                {r.status === "on_leave" && r.note ? <span className="tiny muted block">{r.note}</span> : null}
              </td>
              <td><SourceBadges day={src?.get(daySourceKey(r.employee_id, r.work_date))} /></td>
              <td>
                <div className="row-actions v">
                  <button type="button" className="btn ghost sm" onClick={() => onTimeline(r)} aria-label={`Timeline for ${r.full_name}, ${formatDay(r.work_date, fmt)}`}>Timeline</button>
                  <Link className="btn ghost sm" href={`/employees?id=${r.employee_id}`}>View</Link>
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function MonthGrid({ rows, from, to, fmt, loading }: { rows: RegisterRow[]; from: string; to: string; fmt: string; loading: boolean }) {
  const days: string[] = [];
  for (let d = from; d <= to; d = new Date(Date.parse(d + "T00:00:00Z") + 86400000).toISOString().slice(0, 10)) days.push(d);
  const people = Array.from(new Map(rows.map((r) => [r.employee_id, r])).values()).sort((a, b) => a.full_name.localeCompare(b.full_name));
  const cell = new Map(rows.map((r) => [`${r.employee_id}:${r.work_date}`, r]));
  const totals = personTotals(rows);
  return (
    <SectionCard title={`Month at a glance`} subtitle={`${people.length} people · ${formatDay(from, fmt)} – ${formatDay(to, fmt)}${loading ? " · updating…" : ""}`}>
      <div className="table-wrap month-grid-wrap">
        <table className="table month-grid">
          <thead>
            <tr>
              <th scope="col" className="mg-name">Employee</th>
              {days.map((d) => <th key={d} scope="col" className="mg-day">{Number(d.slice(8))}</th>)}
              <th scope="col">Attended</th><th scope="col">Leave</th>
            </tr>
          </thead>
          <tbody>
            {people.map((p) => {
              const t = totals.get(p.employee_id)!;
              return (
                <tr key={p.employee_id}>
                  <th scope="row" className="mg-name">{p.full_name}<span className="tiny muted block">{p.emp_code}</span></th>
                  {days.map((d) => {
                    const r = cell.get(`${p.employee_id}:${d}`);
                    return (
                      <td key={d} className={`mg-cell ${r ? `st-${r.status}` : ""}`} title={r ? `${formatDay(d, fmt)}: ${statusText(r.status)}` : formatDay(d, fmt)}>
                        {r ? STATUS_LETTER[r.status] ?? "" : ""}
                        {r ? <span className="sr-only"> {statusText(r.status)}</span> : null}
                      </td>
                    );
                  })}
                  <td>{t.attended}/{t.due}</td>
                  <td>{t.leave || "—"}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <p className="tiny muted mg-legend">P Present · L Late · W Working now · M Missing check-out · A Absent · LV On leave · H Holiday · O Day off · “·” not started</p>
    </SectionCard>
  );
}
