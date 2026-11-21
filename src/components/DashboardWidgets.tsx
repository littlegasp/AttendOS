"use client";

import Link from "next/link";
import { STATUS_LABEL, clock, shortDate, type DayStatus } from "@/lib/attendance";
import { EmptyState } from "./States";
import { Button, StatusBadge } from "./ui";
import type { useAttendance } from "@/lib/use-attendance";
import { hhmmss, timeSplit } from "@/lib/attendance";

export interface Summary {
  ok: true;
  scope: "organization" | "team" | "personal";
  today: string;
  timezone: string;
  people: number;
  rate: { today: number | null; today_attended: number; today_due: number; yesterday: number | null };
  distribution: Partial<Record<DayStatus, number>> | null;
  late_today: number;
  by_department: { department: string; attended: number; due: number }[];
  working_now: { name: string; since: string; work_mode: string; location: string | null; on_break: boolean; late_min: number }[];
  not_checked_in: { name: string; shift_start: string | null; status: "absent" | "not_started"; work_mode: string }[];
  pending_corrections: { id: number; name: string; work_date: string; kind: string; requested_in: string | null; requested_out: string | null; reason: string; requested_at: string; can_decide: boolean }[];
  upcoming_holidays: { day: string; name: string; location: string | null }[];
  recent_activity: { name: string; kind: string; at: string; work_mode: string; location: string | null; source: string }[];
  on_leave_today?: number;
  on_leave?: { name: string; type: string; half_day: string | null; end: string }[];
  pending_leave?: { id: number; name: string; type: string; start: string; end: string; days: number; half_day: string | null; reason: string; can_decide: boolean }[];
}

/** Who is on leave today and requests waiting for a decision (decisions are made in Leave Management). */
export function LeaveToday({ s }: { s: Summary }) {
  const on = s.on_leave ?? [];
  const pending = (s.pending_leave ?? []).filter((p) => p.can_decide);
  return (
    <div className="stack">
      {on.length === 0 ? <p className="meta">No one is on leave today.</p> : (
        <ul className="people-list">
          {on.map((p, i) => (
            <li key={i}><strong>{p.name}</strong> <span className="meta">· {p.type}{p.half_day ? " (half day)" : ""}{p.end > s.today ? ` · back after ${p.end.slice(8)}/${p.end.slice(5, 7)}` : ""}</span></li>
          ))}
        </ul>
      )}
      {pending.length ? (
        <p className="meta">
          <strong>{pending.length}</strong> leave {pending.length === 1 ? "request is" : "requests are"} waiting for your decision.{" "}
          <Link href="/leave">Review in Leave Management</Link>
        </p>
      ) : null}
    </div>
  );
}

/** Order and colour (via tone classes) of the attendance distribution. */
const DIST: { key: DayStatus; tone: string }[] = [
  { key: "present", tone: "success" },
  { key: "working", tone: "success-soft" },
  { key: "on_break", tone: "info" },
  { key: "late", tone: "warning" },
  { key: "missing_checkout", tone: "danger-soft" },
  { key: "absent", tone: "danger" },
  { key: "not_started", tone: "neutral" },
  { key: "on_leave", tone: "info" },
  { key: "holiday", tone: "info-soft" },
  { key: "off", tone: "neutral-soft" },
];

/** Stacked bar with a legend that carries the numbers (so it reads without colour). */
export function Distribution({ d }: { d: Summary["distribution"] }) {
  const parts = DIST.map((p) => ({ ...p, n: d?.[p.key] ?? 0 })).filter((p) => p.n > 0);
  const total = parts.reduce((a, p) => a + p.n, 0);
  if (!total) return <EmptyState compact title="No one in scope today" />;
  const summary = parts.map((p) => `${STATUS_LABEL[p.key]} ${p.n}`).join(", ");
  return (
    <div className="dist">
      <div className="dist-bar" role="img" aria-label={`Attendance today: ${summary}`}>
        {parts.map((p) => (
          <span key={p.key} className={`dist-seg t-${p.tone}`} style={{ flexGrow: p.n }} title={`${STATUS_LABEL[p.key]}: ${p.n}`} />
        ))}
      </div>
      <ul className="dist-legend">
        {parts.map((p) => (
          <li key={p.key}>
            <span className={`dist-dot t-${p.tone}`} aria-hidden="true" />
            <span>{STATUS_LABEL[p.key]}</span>
            <strong>{p.n}</strong>
            <span className="meta">{Math.round((100 * p.n) / total)}%</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

export function DepartmentBars({ rows }: { rows: Summary["by_department"] }) {
  const shown = rows.filter((r) => r.due > 0);
  if (!shown.length) return <EmptyState compact title="No one due yet today" body="Departments appear once shifts have started." />;
  return (
    <ul className="dept-bars">
      {shown.map((r) => {
        const pct = Math.round((100 * r.attended) / r.due);
        return (
          <li key={r.department}>
            <div className="dept-row">
              <span>{r.department}</span>
              <span className="meta">
                <strong>{pct}%</strong> · {r.attended} of {r.due}
              </span>
            </div>
            <div className="dept-track" aria-hidden="true">
              <span className={`dept-fill${pct < 70 ? " low" : ""}`} style={{ width: `${pct}%` }} />
            </div>
          </li>
        );
      })}
    </ul>
  );
}

export function PeopleList({ rows, empty, tz, kind }: { rows: Summary["working_now"] | Summary["not_checked_in"]; empty: string; tz: string; kind: "working" | "missing" }) {
  if (!rows.length) return <EmptyState compact title={empty} />;
  return (
    <ul className="people-list">
      {rows.slice(0, 8).map((r, i) => (
        <li key={`${r.name}-${i}`}>
          <span className="avatar sm" aria-hidden="true">{r.name.split(/\s+/).slice(0, 2).map((p) => p[0]).join("")}</span>
          <span className="pl-main">
            <strong>{r.name}</strong>
            <span className="meta block">
              {kind === "working"
                ? (() => {
                    const w = r as Summary["working_now"][number];
                    return `Since ${clock(w.since, tz)} · ${w.work_mode === "remote" ? "Remote" : w.location ?? "Office"}`;
                  })()
                : (() => {
                    const m = r as Summary["not_checked_in"][number];
                    return `${m.shift_start ? `Shift ${clock(m.shift_start, tz)}` : "No shift set"} · ${m.work_mode === "remote" ? "Remote" : "Office"}`;
                  })()}
            </span>
          </span>
          {kind === "working" ? (
            (r as Summary["working_now"][number]).on_break ? <StatusBadge status="pending" label="On break" /> : (r as Summary["working_now"][number]).late_min ? <StatusBadge status="late" /> : <StatusBadge status="present" label="Working" />
          ) : (r as Summary["not_checked_in"][number]).status === "absent" ? (
            <StatusBadge status="absent" label="Overdue" />
          ) : (
            <StatusBadge status="weekly-off" label="Not due yet" />
          )}
        </li>
      ))}
      {rows.length > 8 ? <li className="meta">+{rows.length - 8} more</li> : null}
    </ul>
  );
}

export function Holidays({ rows }: { rows: Summary["upcoming_holidays"] }) {
  if (!rows.length) return <EmptyState compact title="No upcoming holidays" body="HR adds them on the Holidays screen." />;
  return (
    <ul className="hol-list">
      {rows.map((h) => (
        <li key={`${h.day}-${h.name}`}>
          <span className="hol-date">
            <strong>{new Date(`${h.day}T12:00:00Z`).getUTCDate()}</strong>
            <span>{new Date(`${h.day}T12:00:00Z`).toLocaleDateString("en-IN", { month: "short", timeZone: "UTC" })}</span>
          </span>
          <span>
            <strong>{h.name}</strong>
            <span className="meta block">{shortDate(h.day)}{h.location ? ` · ${h.location} only` : ""}</span>
          </span>
        </li>
      ))}
    </ul>
  );
}

const ACT: Record<string, string> = { in: "checked in", out: "checked out", break_start: "started a break", break_end: "ended a break" };

export function Activity({ rows, tz }: { rows: Summary["recent_activity"]; tz: string }) {
  if (!rows.length) return <EmptyState compact title="No activity yet" body="Check-ins and check-outs from the last two days appear here." />;
  return (
    <ul className="act-list">
      {rows.map((a, i) => (
        <li key={`${a.at}-${i}`}>
          <span className={`act-dot k-${a.kind}`} aria-hidden="true" />
          <span>
            <strong>{a.name}</strong> {ACT[a.kind] ?? a.kind}
            {a.kind === "in" || a.kind === "out" ? <span className="meta"> · {a.work_mode === "remote" ? "remote" : a.location ?? "office"}</span> : null}
            {a.source === "correction" ? <span className="meta"> · by correction</span> : a.source === "biometric" ? <span className="meta"> · biometric device</span> : a.source === "import" ? <span className="meta"> · imported</span> : null}
          </span>
          <span className="meta act-time">{clock(a.at, tz)}</span>
        </li>
      ))}
    </ul>
  );
}

/** A slim personal strip for HR / managers / admins: their own status with one tap to act. */
export function MyStrip({ att }: { att: ReturnType<typeof useAttendance> }) {
  const t = att.today;
  if (!t) return null;
  const { worked } = timeSplit(t.events, att.serverNow);
  return (
    <div className="card glass my-strip">
      <div className="ms-main">
        <span className="meta">My attendance</span>
        <strong>
          {t.state === "working" ? "Checked in" : t.state === "on_break" ? "On break" : t.events.length ? "Checked out" : t.plan.work_mode === "off" ? "Day off" : "Not checked in"}
        </strong>
      </div>
      <span className="ms-timer">{hhmmss(worked)}</span>
      <div className="ms-actions">
        {t.state === "off" && t.plan.work_mode !== "off" ? (
          <Button variant="primary" loading={att.step !== "idle"} onClick={() => att.act("in")}>Check In</Button>
        ) : t.state !== "off" ? (
          <Button loading={att.step !== "idle"} onClick={() => att.act("out")}>Check Out</Button>
        ) : null}
        <Link href="/my-attendance" className="btn ghost md">Details</Link>
      </div>
      {att.problem ? <p className="ms-problem" role="alert">{att.problem.title}: {att.problem.body}</p> : null}
    </div>
  );
}
