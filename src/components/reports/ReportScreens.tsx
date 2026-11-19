"use client";

import { useMemo, useState } from "react";
import { EmptyState, ErrorState, LoadingState } from "@/components/States";
import { Tabs } from "@/components/Tabs";
import { Button, FormInput, GlassCard, MetricCard, SectionCard, StatusBadge } from "@/components/ui";
import { NavIcon } from "@/components/Icons";
import { clock, hm } from "@/lib/attendance";
import { downloadCsv, toCsv } from "@/lib/csv";
import { daysBetween, formatDay, MAX_RANGE_DAYS, presetRange, shortFormat, type RangePreset } from "@/lib/dates";
import { todayIn } from "@/lib/employees";
import { LEAVE_STATUS_BADGE, LEAVE_STATUS_LABEL, type LeaveRow } from "@/lib/leave";
import { can } from "@/lib/permissions";
import type { RegisterRow } from "@/lib/register";
import { byDepartment, statusMix, summarize, type PersonReport, type TrendRow } from "@/lib/reports";
import { useSession } from "@/lib/session";
import { supabase } from "@/lib/supabase";
import { must, useLoad } from "@/lib/use-load";
import { BarList, LineChart, StackBar } from "./Charts";

export interface ReportFilter { preset: RangePreset; from: string; to: string; department: string; employee: string; shift: string }
interface Lookup { id: string; name: string }
interface Person { id: string; full_name: string; active: boolean }

export function useReportFilter() {
  const { company } = useSession();
  const today = todayIn(company?.timezone ?? "Asia/Kolkata");
  const r = presetRange("this_month", today);
  const [f, setF] = useState<ReportFilter>({ preset: "this_month", from: r.from, to: r.to, department: "", employee: "", shift: "" });
  return { f, setF, today };
}

export function rangeError(f: ReportFilter): string | null {
  if (!f.from || !f.to) return "Choose both dates.";
  if (f.to < f.from) return "The end date is before the start date.";
  if (daysBetween(f.from, f.to) + 1 > MAX_RANGE_DAYS) return `Choose up to ${MAX_RANGE_DAYS} days at a time.`;
  return null;
}

export function ReportFilters({ f, setF, today, children }: { f: ReportFilter; setF: (f: ReportFilter) => void; today: string; children?: React.ReactNode }) {
  const { role } = useSession();
  const lookups = useLoad(async () => {
    const sb = supabase();
    const [departments, shifts, people] = await Promise.all([
      sb.from("departments").select("id, name").order("name").then(must<Lookup[]>),
      sb.from("shifts").select("id, name").order("name").then(must<Lookup[]>),
      sb.rpc("people_directory").then(must<Person[]>),
    ]);
    return { departments, shifts, people };
  }, "report-lookups");
  const preset = (p: RangePreset) => setF({ ...f, preset: p, ...(p === "custom" ? {} : presetRange(p, today)) });
  const err = rangeError(f);
  const L = lookups.data;
  return (
    <GlassCard className="reg-filters no-print">
      <div className="emp-filters">
        <label className="filter-chip"><span className="fc-label">Period</span>
          <select value={f.preset} onChange={(e) => preset(e.target.value as RangePreset)}>
            <option value="today">Today</option><option value="7d">Last 7 days</option><option value="this_month">This month</option>
            <option value="last_month">Last month</option><option value="custom">Custom…</option>
          </select></label>
        {f.preset === "custom" ? (
          <div className="range-fields">
            <FormInput label="From" type="date" value={f.from} max={today} onChange={(e) => setF({ ...f, from: e.target.value })} />
            <FormInput label="To" type="date" value={f.to} max={today} onChange={(e) => setF({ ...f, to: e.target.value })} error={err ?? undefined} />
          </div>
        ) : null}
        {L && role !== "employee" ? (
          <>
            <label className="filter-chip"><span className="fc-label">Department</span>
              <select value={f.department} onChange={(e) => setF({ ...f, department: e.target.value })}><option value="">All</option>{L.departments.map((d) => <option key={d.id} value={d.id}>{d.name}</option>)}</select></label>
            <label className="filter-chip"><span className="fc-label">Employee</span>
              <select value={f.employee} onChange={(e) => setF({ ...f, employee: e.target.value })}><option value="">All</option>{L.people.map((p) => <option key={p.id} value={p.id}>{p.full_name}</option>)}</select></label>
          </>
        ) : null}
        {L ? (
          <label className="filter-chip"><span className="fc-label">Shift</span>
            <select value={f.shift} onChange={(e) => setF({ ...f, shift: e.target.value })}><option value="">All</option>{L.shifts.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
        ) : null}
        <span className="grow" />
        {children}
      </div>
      <p className="tiny muted">
        {formatDay(f.from)} – {formatDay(f.to)} · {role === "employee" ? "Your own attendance" : role === "manager" ? "Your team" : "Everyone you may see"} · Attendance rate counts only days people were due to work.
      </p>
    </GlassCard>
  );
}

function args(f: ReportFilter) {
  return { p_from: f.from, p_to: f.to, p_department: f.department || null, p_employee: f.employee || null, p_shift: f.shift || null };
}

export function useReportData(f: ReportFilter) {
  const ok = !rangeError(f);
  const key = `${f.from}:${f.to}:${f.department}:${f.employee}:${f.shift}`;
  return useLoad(async () => {
    if (!ok) return null;
    const sb = supabase();
    const [people, trend] = await Promise.all([
      sb.rpc("report_people", args(f)).then(must<PersonReport[]>),
      sb.rpc("report_trend", args(f)).then(must<TrendRow[]>),
    ]);
    return { people, trend };
  }, key);
}

type RTab = "summary" | "employees" | "departments" | "late" | "overtime" | "leave" | "daily";

/** Reports: same filters and scope as the screen for every export. */
export function Reports() {
  const { company, role } = useSession();
  const tz = company?.timezone ?? "Asia/Kolkata";
  const fmt = company?.date_format ?? "DD MMM YYYY";
  const { f, setF, today } = useReportFilter();
  const [tab, setTab] = useState<RTab>("summary");
  const data = useReportData(f);
  const detail = useLoad(async () => {
    if (rangeError(f) || (tab !== "late" && tab !== "overtime")) return null;
    return must(await supabase().rpc("attendance_register", { ...args(f), p_status: tab === "late" ? "late" : null, p_limit: 5000, p_offset: 0 })) as RegisterRow[];
  }, `detail:${tab}:${f.from}:${f.to}:${f.department}:${f.employee}:${f.shift}`);
  const leave = useLoad(async () => {
    if (rangeError(f) || tab !== "leave") return null;
    const rows = must(await supabase().rpc("leave_list", { p_from: f.from, p_to: f.to, p_status: null })) as LeaveRow[];
    return rows.filter((r) => (!f.employee || r.employee_id === f.employee) && (r.status === "approved" || r.status === "pending"));
  }, `leave:${tab}:${f.from}:${f.to}:${f.employee}`);
  const people = useMemo(() => data.data?.people ?? [], [data.data]);
  const sum = useMemo(() => summarize(people), [people]);
  const depts = useMemo(() => byDepartment(people), [people]);
  const exportable = can(role, "exportReports");
  const name = `attendance-${tab}-${f.from}-to-${f.to}`;

  function exportCsv() {
    if (tab === "summary" || tab === "employees") {
      downloadCsv(name, toCsv(people, [
        { label: "Employee", value: (r) => r.full_name }, { label: "Employee ID", value: (r) => r.emp_code }, { label: "Department", value: (r) => r.department },
        { label: "Days due", value: (r) => r.due_days }, { label: "Attended", value: (r) => r.attended_days }, { label: "Attendance %", value: (r) => r.rate },
        { label: "Absent", value: (r) => r.absent_days }, { label: "On leave (days)", value: (r) => r.leave_days }, { label: "Late days", value: (r) => r.late_days },
        { label: "Late minutes", value: (r) => r.late_min }, { label: "Early departures", value: (r) => r.early_days }, { label: "Half days", value: (r) => r.half_days },
        { label: "Missing check-out", value: (r) => r.missing_checkout }, { label: "Hours worked", value: (r) => (Number(r.worked_min) / 60).toFixed(2) },
        { label: "Avg hours per day", value: (r) => (Number(r.avg_worked_min) / 60).toFixed(2) }, { label: "Overtime hours", value: (r) => (Number(r.overtime_min) / 60).toFixed(2) },
      ]));
    } else if (tab === "departments") {
      downloadCsv(name, toCsv(depts, [
        { label: "Department", value: (d) => d.department }, { label: "People", value: (d) => d.people }, { label: "Days due", value: (d) => d.due },
        { label: "Attended", value: (d) => d.attended }, { label: "Attendance %", value: (d) => d.rate }, { label: "Late days", value: (d) => d.late },
        { label: "Absent days", value: (d) => d.absent }, { label: "Leave days", value: (d) => d.leave }, { label: "Overtime hours", value: (d) => d.overtimeHours },
      ]));
    } else if (tab === "daily") {
      downloadCsv(name, toCsv(data.data?.trend ?? [], [
        { label: "Date", value: (t) => formatDay(t.work_date, fmt) }, { label: "Due", value: (t) => t.due }, { label: "Attended", value: (t) => t.attended },
        { label: "Attendance %", value: (t) => t.rate }, { label: "Late", value: (t) => t.late }, { label: "Absent", value: (t) => t.absent },
        { label: "On leave", value: (t) => t.on_leave }, { label: "Avg hours", value: (t) => (Number(t.avg_worked_min) / 60).toFixed(2) },
      ]));
    } else if (tab === "leave") {
      downloadCsv(name, toCsv(leave.data ?? [], [
        { label: "Employee", value: (r) => r.full_name }, { label: "Employee ID", value: (r) => r.emp_code }, { label: "Department", value: (r) => r.department },
        { label: "Leave type", value: (r) => r.leave_type }, { label: "From", value: (r) => formatDay(r.start_date, fmt) }, { label: "To", value: (r) => formatDay(r.end_date, fmt) },
        { label: "Days", value: (r) => r.days }, { label: "Status", value: (r) => LEAVE_STATUS_LABEL[r.status] }, { label: "Approved by", value: (r) => r.decided_by_name },
      ]));
    } else {
      const rows = (detail.data ?? []).filter((r) => (tab === "overtime" ? r.overtime_min > 0 : r.late_min > 0));
      downloadCsv(name, toCsv(rows, [
        { label: "Employee", value: (r) => r.full_name }, { label: "Employee ID", value: (r) => r.emp_code }, { label: "Department", value: (r) => r.department },
        { label: "Date", value: (r) => formatDay(r.work_date, fmt) }, { label: "Shift", value: (r) => r.shift_name },
        { label: "Check-in", value: (r) => (r.first_in ? clock(r.first_in, tz) : "") }, { label: "Check-out", value: (r) => (r.last_out ? clock(r.last_out, tz) : "") },
        { label: tab === "overtime" ? "Overtime (min)" : "Late (min)", value: (r) => (tab === "overtime" ? r.overtime_min : r.late_min) },
      ]));
    }
  }

  const actions = (
    <div className="report-actions">
      {exportable ? <Button size="sm" onClick={exportCsv} disabled={!data.data}>Export CSV</Button> : null}
      {exportable ? <Button size="sm" variant="ghost" onClick={() => window.print()} disabled={!data.data}>Print / PDF</Button> : null}
    </div>
  );
  const tabs: { id: RTab; label: string }[] = [
    { id: "summary", label: "Summary" }, { id: "employees", label: "Employee-wise" },
    ...(role === "employee" ? [] : [{ id: "departments" as RTab, label: "Department-wise" }]),
    { id: "late", label: "Late arrivals" }, { id: "overtime", label: "Overtime" }, { id: "leave", label: "Leave" }, { id: "daily", label: "Daily" },
  ];

  return (
    <>
      <ReportFilters f={f} setF={setF} today={today}>{actions}</ReportFilters>
      <p className="print-only"><strong>{company?.name} — {tabs.find((t) => t.id === tab)?.label} report</strong>, {formatDay(f.from, fmt)} – {formatDay(f.to, fmt)}</p>
      <Tabs label="Report" value={tab} onChange={setTab} tabs={tabs} />
      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} className="tab-panel">
        {rangeError(f) ? <GlassCard><EmptyState title="Choose a valid period" body={rangeError(f)!} /></GlassCard> :
          data.error ? <GlassCard><ErrorState body={data.error} onRetry={data.reload} /></GlassCard> :
          !data.data ? <LoadingState kind="cards" /> :
          people.length === 0 ? <GlassCard><EmptyState title="No attendance in this period" body="Nobody in scope was due to work, or the filters exclude everyone." /></GlassCard> :
          tab === "summary" ? (
            <>
              <div className="grid-kpi report-kpis">
                <MetricCard label="Attendance rate" tone="primary" icon={<NavIcon name="analytics" />} value={sum.rate === null ? "—" : `${sum.rate}%`} note={`${sum.attended} of ${sum.due} days due · ${sum.people} people`} />
                <MetricCard label="Average working hours" tone="info" icon={<NavIcon name="clock" />} value={sum.avgHours === null ? "—" : `${sum.avgHours} h`} note="Per completed day" />
                <MetricCard label="Late arrivals" tone="warning" icon={<NavIcon name="clock" />} value={`${sum.lateDays}`} note={`${sum.earlyDays} early departures`} />
                <MetricCard label="Absenteeism" tone="danger" icon={<NavIcon name="people" />} value={sum.absenteeism === null ? "—" : `${sum.absenteeism}%`} note={`${sum.absentDays} absent days`} />
                <MetricCard label="Overtime" tone="success" icon={<NavIcon name="shift" />} value={`${sum.overtimeHours} h`} note={`${sum.halfDays} half days · ${sum.missingCheckout} missing check-outs`} />
                <MetricCard label="Leave" tone="info" icon={<NavIcon name="leave" />} value={`${sum.leaveDays}`} note="Days on approved leave" />
              </div>
              {role !== "employee" ? (
                <SectionCard title="By department" subtitle="Attendance rate">
                  <BarList title="Attendance rate by department" unit="%" max={100} rows={depts.map((d) => ({ label: d.department, value: d.rate, note: `${d.attended}/${d.due}` }))} />
                </SectionCard>
              ) : null}
            </>
          ) : tab === "employees" ? <PeopleTable rows={people} /> :
          tab === "departments" ? <DeptTable rows={depts} /> :
          tab === "daily" ? <DailyTable rows={data.data.trend} fmt={fmt} /> :
          tab === "leave" ? (leave.error ? <ErrorState body={leave.error} onRetry={leave.reload} /> : !leave.data ? <LoadingState kind="table" /> : <LeaveTable rows={leave.data} fmt={fmt} />) :
          detail.error ? <GlassCard><ErrorState body={detail.error} onRetry={detail.reload} /></GlassCard> : !detail.data ? <LoadingState kind="table" /> :
          <DetailTable rows={detail.data.filter((r) => (tab === "overtime" ? r.overtime_min > 0 : r.late_min > 0))} kind={tab === "overtime" ? "overtime" : "late"} tz={tz} fmt={fmt} />}
      </div>
    </>
  );
}

function PeopleTable({ rows }: { rows: PersonReport[] }) {
  return (
    <SectionCard title="Employee-wise" subtitle={`${rows.length} people`}>
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th scope="col">Employee</th><th scope="col">Due</th><th scope="col">Attended</th><th scope="col">Rate</th><th scope="col">Absent</th><th scope="col">Leave</th><th scope="col">Late</th><th scope="col">Early</th><th scope="col">Half days</th><th scope="col">Hours</th><th scope="col">Avg / day</th><th scope="col">Overtime</th></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.employee_id}>
                <th scope="row">{r.full_name}<span className="tiny muted block">{[r.emp_code, r.department].filter(Boolean).join(" · ")}</span></th>
                <td>{r.due_days}</td><td>{r.attended_days}</td><td>{r.rate === null ? "—" : `${r.rate}%`}</td><td>{r.absent_days || "—"}</td><td>{r.leave_days || "—"}</td>
                <td>{r.late_days ? `${r.late_days} (${hm(Number(r.late_min))})` : "—"}</td><td>{r.early_days || "—"}</td><td>{r.half_days || "—"}</td>
                <td>{hm(Number(r.worked_min))}</td><td>{r.avg_worked_min ? hm(Number(r.avg_worked_min)) : "—"}</td><td>{Number(r.overtime_min) ? hm(Number(r.overtime_min)) : "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </SectionCard>
  );
}

function DeptTable({ rows }: { rows: ReturnType<typeof byDepartment> }) {
  return (
    <SectionCard title="Department-wise">
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th scope="col">Department</th><th scope="col">People</th><th scope="col">Days due</th><th scope="col">Attended</th><th scope="col">Rate</th><th scope="col">Late days</th><th scope="col">Absent days</th><th scope="col">Leave days</th><th scope="col">Overtime</th></tr></thead>
          <tbody>{rows.map((d) => <tr key={d.department}><th scope="row">{d.department}</th><td>{d.people}</td><td>{d.due}</td><td>{d.attended}</td><td>{d.rate === null ? "—" : `${d.rate}%`}</td><td>{d.late}</td><td>{d.absent}</td><td>{d.leave}</td><td>{d.overtimeHours} h</td></tr>)}</tbody>
        </table>
      </div>
    </SectionCard>
  );
}

function DailyTable({ rows, fmt }: { rows: TrendRow[]; fmt: string }) {
  return (
    <SectionCard title="Daily">
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th scope="col">Date</th><th scope="col">Due</th><th scope="col">Attended</th><th scope="col">Rate</th><th scope="col">Late</th><th scope="col">Absent</th><th scope="col">On leave</th><th scope="col">Avg hours</th></tr></thead>
          <tbody>{[...rows].reverse().map((t) => <tr key={t.work_date}><th scope="row">{formatDay(t.work_date, fmt)}</th><td>{t.due}</td><td>{t.attended}</td><td>{t.rate === null ? "—" : `${t.rate}%`}</td><td>{t.late}</td><td>{t.absent}</td><td>{t.on_leave}</td><td>{t.avg_worked_min ? hm(Number(t.avg_worked_min)) : "—"}</td></tr>)}</tbody>
        </table>
      </div>
    </SectionCard>
  );
}

function DetailTable({ rows, kind, tz, fmt }: { rows: RegisterRow[]; kind: "late" | "overtime"; tz: string; fmt: string }) {
  if (!rows.length) return <GlassCard><EmptyState title={kind === "late" ? "No late arrivals" : "No overtime"} body="Nothing in this period for these filters." /></GlassCard>;
  return (
    <SectionCard title={kind === "late" ? "Late arrivals" : "Overtime"} subtitle={`${rows.length} days · ${hm(rows.reduce((a, r) => a + (kind === "late" ? r.late_min : r.overtime_min), 0))} in total`}>
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th scope="col">Employee</th><th scope="col">Date</th><th scope="col">Shift</th><th scope="col">Check-in</th><th scope="col">Check-out</th><th scope="col">{kind === "late" ? "Late by" : "Overtime"}</th></tr></thead>
          <tbody>{rows.map((r) => <tr key={`${r.employee_id}:${r.work_date}`}><th scope="row">{r.full_name}<span className="tiny muted block">{r.department ?? ""}</span></th><td>{formatDay(r.work_date, fmt)}</td><td>{r.shift_name ?? "—"}</td><td>{r.first_in ? clock(r.first_in, tz) : "—"}</td><td>{r.last_out ? clock(r.last_out, tz) : "—"}</td><td><strong>{hm(kind === "late" ? r.late_min : r.overtime_min)}</strong></td></tr>)}</tbody>
        </table>
      </div>
    </SectionCard>
  );
}

function LeaveTable({ rows, fmt }: { rows: LeaveRow[]; fmt: string }) {
  if (!rows.length) return <GlassCard><EmptyState title="No leave in this period" /></GlassCard>;
  const byType = new Map<string, number>();
  rows.filter((r) => r.status === "approved").forEach((r) => byType.set(r.leave_type, (byType.get(r.leave_type) ?? 0) + Number(r.days)));
  return (
    <SectionCard title="Leave" subtitle={[...byType.entries()].map(([k, v]) => `${k} ${v} d`).join(" · ") || "Approved and pending"}>
      <div className="table-wrap">
        <table className="table">
          <thead><tr><th scope="col">Employee</th><th scope="col">Type</th><th scope="col">Dates</th><th scope="col">Days</th><th scope="col">Status</th><th scope="col">Decided by</th></tr></thead>
          <tbody>{rows.map((r) => <tr key={r.id}><th scope="row">{r.full_name}</th><td>{r.leave_type}</td><td>{formatDay(r.start_date, fmt)}{r.end_date !== r.start_date ? ` – ${formatDay(r.end_date, fmt)}` : ""}</td><td>{Number(r.days)}</td><td><StatusBadge status={LEAVE_STATUS_BADGE[r.status]} label={LEAVE_STATUS_LABEL[r.status]} /></td><td>{r.decided_by_name ?? "—"}</td></tr>)}</tbody>
        </table>
      </div>
    </SectionCard>
  );
}

/** Analytics: trends and comparisons, each with a table equivalent. */
export function Analytics() {
  const { company, role } = useSession();
  const fmt = company?.date_format ?? "DD MMM YYYY";
  const { f, setF, today } = useReportFilter();
  const data = useReportData(f);
  if (data.error) return <GlassCard><ErrorState body={data.error} onRetry={data.reload} /></GlassCard>;
  const trend = data.data?.trend ?? [];
  const people = data.data?.people ?? [];
  const sum = summarize(people);
  const depts = byDepartment(people);
  const mix = statusMix(trend);
  const rateSummary = trend.length ? `From ${trend[0]!.rate ?? "—"}% on ${shortFormat(trend[0]!.work_date, fmt)} to ${trend[trend.length - 1]!.rate ?? "—"}% on ${shortFormat(trend[trend.length - 1]!.work_date, fmt)}; ${sum.rate ?? "—"}% overall.` : "No data.";
  return (
    <>
      <ReportFilters f={f} setF={setF} today={today} />
      {rangeError(f) ? <GlassCard><EmptyState title="Choose a valid period" body={rangeError(f)!} /></GlassCard> : !data.data ? <LoadingState kind="cards" /> : people.length === 0 ? (
        <GlassCard><EmptyState title="No attendance in this period" /></GlassCard>
      ) : (
        <>
          <div className="grid-2">
            <SectionCard title="Attendance trend" subtitle="Attended out of due, per day">
              <LineChart title="Attendance rate" summary={rateSummary} unit="%" max={100} points={trend.map((t) => ({ label: shortFormat(t.work_date, fmt), value: t.rate === null ? null : Number(t.rate) }))} />
            </SectionCard>
            <SectionCard title="Working-hours trend" subtitle="Average hours per completed day">
              <LineChart tone="info" title="Average hours" summary={`${sum.avgHours ?? "—"} h on average.`} unit="h" points={trend.map((t) => ({ label: shortFormat(t.work_date, fmt), value: t.avg_worked_min ? Math.round((Number(t.avg_worked_min) / 60) * 10) / 10 : null }))} />
            </SectionCard>
          </div>
          <div className="grid-2">
            <SectionCard title="Status distribution" subtitle="Working days in the period">
              <StackBar title="Status distribution" parts={mix} />
            </SectionCard>
            {role !== "employee" ? (
              <SectionCard title="Department comparison" subtitle="Attendance rate">
                <BarList title="Attendance rate by department" unit="%" max={100} rows={depts.map((d) => ({ label: d.department, value: d.rate, note: `${d.people} people` }))} />
              </SectionCard>
            ) : (
              <SectionCard title="Your period">
                <BarList title="Your days" rows={[{ label: "Attended", value: sum.attended }, { label: "Late", value: sum.lateDays }, { label: "Absent", value: sum.absentDays }, { label: "On leave", value: sum.leaveDays }]} />
              </SectionCard>
            )}
          </div>
        </>
      )}
    </>
  );
}
