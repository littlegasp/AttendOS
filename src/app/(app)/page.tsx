"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { AttendanceCard, VerificationCard } from "@/components/AttendanceCard";
import { PendingCorrections } from "@/components/Corrections";
import { Activity, DepartmentBars, Distribution, Holidays, MyStrip, PeopleList, type Summary } from "@/components/DashboardWidgets";
import { HistoryPanel } from "@/components/HistoryPanel";
import { NavIcon } from "@/components/Icons";
import { PageContainer } from "@/components/PageContainer";
import { EmptyState, ErrorState, LoadingState } from "@/components/States";
import { GlassCard, MetricCard, SectionCard } from "@/components/ui";
import { ALL_ITEMS, allowed } from "@/lib/nav";
import { SCOPE_LABEL, scopeOf } from "@/lib/permissions";
import { useSession } from "@/lib/session";
import { supabase } from "@/lib/supabase";
import { useAttendance } from "@/lib/use-attendance";
import { must, useLoad } from "@/lib/use-load";

function greeting(h: number) {
  return h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening";
}

/** Quick actions from the guide; each one only appears if the role can open its screen. */
const QUICK = [
  { href: "/my-attendance", label: "Mark Attendance" },
  { href: "/leave", label: "Apply Leave" },
  { href: "/attendance", label: "Team Attendance" },
  { href: "/reports", label: "Generate Report" },
];

export default function DashboardPage() {
  const { role, preview, name } = useSession();
  // Date is drawn in the browser so the static build never bakes in a stale day.
  const [now, setNow] = useState<Date | null>(null);
  useEffect(() => setNow(new Date()), []);
  const first = preview ? "" : `, ${name.split(/\s+/)[0]}`;

  return (
    <PageContainer
      title={now ? `${greeting(now.getHours())}${first}` : "Dashboard"}
      subtitle={now ? now.toLocaleDateString("en-IN", { weekday: "long", day: "numeric", month: "long", year: "numeric" }) : " "}
    >
      {preview ? <PreviewDashboard /> : role === "employee" ? <PersonalDashboard /> : <TeamDashboard />}
    </PageContainer>
  );
}

function QuickActions() {
  const { role } = useSession();
  const quick = QUICK.map((q) => ({ ...q, item: ALL_ITEMS.find((i) => i.href === q.href)! })).filter((q) => allowed(role, q.item));
  return (
    <div className="quick-grid">
      {quick.map((q, i) => (
        <Link key={q.href} href={q.href} className={`card glass quick${i === 0 ? " quick-primary" : ""}`}>
          <span className="quick-ic" aria-hidden="true"><NavIcon name={q.item.icon} /></span>
          <span className="quick-tx">
            <strong>{q.label}</strong>
            <span className="meta">{q.item.blurb}</span>
          </span>
        </Link>
      ))}
    </div>
  );
}

function PreviewDashboard() {
  const { role } = useSession();
  return (
    <>
      <QuickActions />
      <GlassCard>
        <EmptyState
          title="Dashboard figures need the company database"
          body={`This is the design preview, so there are no check-ins to count. When connected, this ${SCOPE_LABEL[scopeOf(role, "dashboard")].toLowerCase()} dashboard shows the attendance rate against yesterday, the status breakdown, departments, who is working now and who hasn't checked in, pending corrections, upcoming holidays and recent activity — all calculated by the database within ${role === "manager" ? "your team" : role === "employee" ? "your own records" : "the organization"}.`}
        />
      </GlassCard>
    </>
  );
}

function useSummary() {
  const { data, error, reload } = useLoad(async () => must(await supabase().rpc("dashboard_summary")) as Summary, "summary");
  useEffect(() => {
    const t = setInterval(reload, 60_000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  return { s: data?.ok ? data : undefined, error, reload };
}

/** Employees (and phones): their own status, action, timer, shift, GPS check and recent history. */
function PersonalDashboard() {
  const att = useAttendance();
  const { employeeId } = useSession();
  const { s, reload } = useSummary();
  if (att.loadError) return <GlassCard><ErrorState title="Couldn't load your attendance" body={att.loadError} onRetry={att.load} /></GlassCard>;
  if (!att.today) return <LoadingState kind="cards" label="Loading your day" />;
  return (
    <>
      <p className="sr-only" aria-live="assertive" role="status">{att.announce}</p>
      <div className="att-grid">
        <AttendanceCard att={att} />
        <div className="stack">
          <VerificationCard att={att} compact />
          <SectionCard title="Upcoming holidays">{s ? <Holidays rows={s.upcoming_holidays.slice(0, 3)} /> : <LoadingState kind="table" />}</SectionCard>
        </div>
      </div>
      {s && s.pending_corrections.length ? (
        <SectionCard title="My pending corrections" subtitle="Waiting for your manager or HR">
          <PendingCorrections items={s.pending_corrections} tz={s.timezone} onDecided={reload} />
        </SectionCard>
      ) : null}
      <HistoryPanel employeeId={employeeId!} tz={att.today.timezone} days={7} onRequested={reload} />
    </>
  );
}

/** Admin / HR (organization) and Managers (their team). */
function TeamDashboard() {
  const att = useAttendance();
  const { s, error, reload } = useSummary();
  if (error) return <GlassCard><ErrorState title="Couldn't load the dashboard" body={error} onRetry={reload} /></GlassCard>;
  if (!s) return <LoadingState kind="cards" label="Loading dashboard" />;

  const tz = s.timezone;
  const delta = s.rate.today !== null && s.rate.yesterday !== null ? Math.round((s.rate.today - s.rate.yesterday) * 10) / 10 : null;
  const overdue = s.not_checked_in.filter((n) => n.status === "absent").length;
  const scope = s.scope === "organization" ? "Whole organization" : "Your team";

  return (
    <>
      <MyStrip att={att} />
      <div className="grid-kpi">
        <MetricCard
          label="Attendance rate"
          tone="primary"
          icon={<NavIcon name="analytics" />}
          value={s.rate.today === null ? "—" : `${s.rate.today}%`}
          note={
            delta === null
              ? s.rate.today === null ? "No shifts have started yet" : "No comparison for yesterday"
              : `${delta > 0 ? "▲" : delta < 0 ? "▼" : "■"} ${Math.abs(delta)} pts vs yesterday (${s.rate.yesterday}%)`
          }
        />
        <MetricCard label="Attended today" tone="success" icon={<NavIcon name="people" />} value={`${s.rate.today_attended}`} note={`of ${s.rate.today_due} due so far · ${s.people} in scope`} />
        <MetricCard label="Working now" tone="info" icon={<NavIcon name="clock" />} value={`${s.working_now.length}`} note={`${s.working_now.filter((w) => w.on_break).length} on break`} />
        <MetricCard label="Late today" tone="warning" icon={<NavIcon name="clock" />} value={`${s.late_today}`} note="Checked in after shift start + grace" />
        <MetricCard label="Not checked in" tone="danger" icon={<NavIcon name="people" />} value={`${overdue}`} note={`${s.not_checked_in.length - overdue} not due yet`} />
      </div>

      <div className="grid-2">
        <SectionCard title="Attendance distribution" subtitle={`${scope} · today`}>
          <Distribution d={s.distribution} />
        </SectionCard>
        <SectionCard title="By department" subtitle="Attended out of those due so far">
          <DepartmentBars rows={s.by_department} />
          {s.by_department.length === 1 && s.by_department[0]!.department === "No department" ? (
            <p className="meta dept-note">People without a department are counted under “No department” — set it in Employees → Edit details.</p>
          ) : null}
        </SectionCard>
      </div>

      <div className="grid-2">
        <SectionCard title="Currently working" subtitle={`${s.working_now.length} people`}>
          <PeopleList rows={s.working_now} empty="No one is checked in right now" tz={tz} kind="working" />
        </SectionCard>
        <SectionCard title="Haven't checked in" subtitle={`${overdue} overdue · ${s.not_checked_in.length - overdue} not due yet`}>
          <PeopleList rows={s.not_checked_in} empty="Everyone due has checked in" tz={tz} kind="missing" />
        </SectionCard>
      </div>

      <div className="grid-3">
        <SectionCard title="Pending corrections" subtitle={s.scope === "team" ? "From your team" : "Awaiting a decision"}>
          <PendingCorrections items={s.pending_corrections} tz={tz} onDecided={reload} limit={5} />
        </SectionCard>
        <SectionCard title="Upcoming holidays">
          <Holidays rows={s.upcoming_holidays} />
        </SectionCard>
        <SectionCard title="Recent activity" subtitle="Last two days">
          <Activity rows={s.recent_activity} tz={tz} />
        </SectionCard>
      </div>

      <QuickActions />
    </>
  );
}
