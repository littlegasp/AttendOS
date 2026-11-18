"use client";

import { IconAlert, IconCheck, NavIcon } from "./Icons";
import { EmptyState } from "./States";
import { Button, GlassCard, SectionCard, StatusBadge } from "./ui";
import {
  MODE_LABEL,
  SOURCE_LABEL,
  accuracyLevel,
  clock,
  hhmmss,
  hm,
  longDate,
  needsLocation,
  shiftRange,
  timeSplit,
  type AttendanceEvent,
  type Today,
} from "@/lib/attendance";
import type { useAttendance } from "@/lib/use-attendance";

type Att = ReturnType<typeof useAttendance>;

/** Status badge for the current moment. */
function NowBadge({ t }: { t: Today }) {
  if (t.state === "working") return <StatusBadge status="present" label="Checked in" />;
  if (t.state === "on_break") return <StatusBadge status="pending" label="On break" />;
  if (t.events.length) return <StatusBadge status="weekly-off" label="Checked out" />;
  if (t.plan.work_mode === "off") return <StatusBadge status="holiday" label={t.plan.source === "holiday" ? "Holiday" : "Day off"} />;
  return <StatusBadge status="pending" label="Not checked in" />;
}

/**
 * The main attendance card: time, status, today's plan and shift, the action buttons,
 * the working-hours timer and any problem. Used on My Attendance and the personal dashboard.
 */
export function AttendanceCard({ att, compact = false }: { att: Att; compact?: boolean }) {
  const { today: t, step, problem, act, serverNow } = att;
  if (!t) return null;
  const tz = t.timezone;
  const off = t.plan.work_mode === "off";
  const busy = step !== "idle";
  const { worked, brk } = timeSplit(t.events, serverNow);
  const lastIn = [...t.events].reverse().find((e) => e.kind === "in");
  const s = t.summary;
  const label = (idle: string) => (step === "locating" ? "Verifying location…" : step === "submitting" ? "Saving…" : idle);

  return (
    <GlassCard className={`punch-card${compact ? " compact" : ""}`}>
      <div className="punch-top">
        <div>
          <p className="meta">{longDate(serverNow, tz)}</p>
          <p className="punch-clock" aria-label={`Current time ${clock(serverNow, tz)}`}>{clock(serverNow, tz, true)}</p>
        </div>
        <NowBadge t={t} />
      </div>

      <div className="punch-plan">
        <span className={`plan-chip mode-${t.plan.work_mode}`}>
          <NavIcon name={t.plan.work_mode === "remote" ? "dashboard" : t.plan.work_mode === "off" ? "holiday" : "department"} />
          {MODE_LABEL[t.plan.work_mode]}
          {t.plan.location ? ` · ${t.plan.location.name}` : ""}
        </span>
        {t.shift && !off ? (
          <span className="shift-chip">
            <NavIcon name="shift" />
            {t.shift.name} · {shiftRange(t.shift, tz)}
            {t.shift.overnight ? <span className="tiny"> (overnight)</span> : null}
          </span>
        ) : null}
        <span className="meta">
          {SOURCE_LABEL[t.plan.source]}
          {t.plan.note ? ` · ${t.plan.note}` : ""}
          {t.work_date !== t.today ? ` · counts for ${t.work_date}` : ""}
        </span>
      </div>

      <div className="punch-action">
        {t.state === "off" ? (
          <Button variant="primary" size="lg" className="punch-btn" loading={busy} disabled={off} onClick={() => act("in")}>
            {label("Check In")}
          </Button>
        ) : (
          <div className="punch-row">
            {t.state === "working" ? (
              <Button size="lg" className="punch-btn break" disabled={busy} onClick={() => act("break_start")}>Start break</Button>
            ) : (
              <Button size="lg" className="punch-btn break on" disabled={busy} onClick={() => act("break_end")}>End break</Button>
            )}
            <Button variant="primary" size="lg" className="punch-btn out" loading={busy} onClick={() => act("out")}>
              {label("Check Out")}
            </Button>
          </div>
        )}
        {off && t.state === "off" ? (
          <p className="meta">
            {t.plan.source === "holiday" ? `Holiday: ${t.plan.note}.` : "Today is not a working day on your roster."} If you&apos;ve been asked to work, ask HR to update it.
          </p>
        ) : null}
      </div>

      <div className="punch-timer">
        <div>
          <span className="meta block">Worked</span>
          <span className="timer-value">{hhmmss(worked)}</span>
        </div>
        <div>
          <span className="meta block">Break</span>
          <span className="timer-sub">{hm(brk / 60000)}{t.shift ? <span className="meta"> / {hm(t.shift.break_minutes)}</span> : null}</span>
        </div>
        {t.state !== "off" && lastIn ? (
          <div>
            <span className="meta block">Since</span>
            <span className="timer-sub">{clock(lastIn.at, tz)}</span>
          </div>
        ) : null}
      </div>

      {s.late_min > 0 || s.early_min > 0 || s.overtime_min > 0 ? (
        <div className="punch-flags">
          {s.late_min > 0 ? <StatusBadge status="late" label={`Late by ${hm(s.late_min)}`} /> : null}
          {s.early_min > 0 ? <StatusBadge status="pending" label={`Left ${hm(s.early_min)} early`} /> : null}
          {s.overtime_min > 0 ? <StatusBadge status="verified" label={`Overtime ${hm(s.overtime_min)}`} /> : null}
        </div>
      ) : null}

      {problem ? (
        <div className={`alert ${problem.tone}`} role="alert">
          <IconAlert />
          <div>
            <strong>{problem.title}</strong>
            <p>{problem.body}</p>
          </div>
        </div>
      ) : null}
    </GlassCard>
  );
}

/** What check-in will verify, location access, and the result of the last reading. */
export function VerificationCard({ att, compact = false }: { att: Att; compact?: boolean }) {
  const { today: t, perm, lastFix } = att;
  if (!t) return null;
  const locNeeded = needsLocation(t);
  const level = lastFix ? accuracyLevel(lastFix.accuracy, t.max_accuracy_m) : null;
  return (
    <SectionCard title={compact ? "GPS verification" : "Location verification"} subtitle={locNeeded ? "Checked only when you check in or out" : "Not needed today"}>
      <ul className="verify-list">
        <li>
          <span className="v-label">Today</span>
          <span>
            {MODE_LABEL[t.plan.work_mode]}
            {t.plan.location ? ` at ${t.plan.location.name} (within ${t.plan.location.radius_m} m)` : t.plan.work_mode === "office" ? " at any company office" : ""}
          </span>
        </li>
        <li>
          <span className="v-label">Location access</span>
          <span>{perm === "granted" ? <StatusBadge status="verified" label="Allowed" /> : perm === "denied" ? <StatusBadge status="failed" label="Blocked" /> : <StatusBadge status="pending" label="Will ask" />}</span>
        </li>
        {!compact ? (
          <li>
            <span className="v-label">Accuracy needed</span>
            <span>{t.max_accuracy_m} m or better</span>
          </li>
        ) : null}
        <li>
          <span className="v-label">Last check</span>
          <span>
            {lastFix ? (
              <>
                {lastFix.ok ? <StatusBadge status="verified" /> : <StatusBadge status="failed" label="Not verified" />}{" "}
                <span className="meta">
                  ±{lastFix.accuracy} m{lastFix.distance !== null && lastFix.location ? ` · ${lastFix.distance} m from ${lastFix.location}` : ""}
                </span>
              </>
            ) : (
              <span className="meta">None yet on this visit</span>
            )}
          </span>
        </li>
      </ul>
      {level === "near" ? (
        <div className="alert warning acc-warn" role="note">
          <IconAlert />
          <p>That reading (±{lastFix!.accuracy} m) was close to the {t.max_accuracy_m} m limit. Next time, wait a few seconds near a window for a steadier fix.</p>
        </div>
      ) : null}
      {!compact ? (
        <p className="meta privacy-note">
          Your location is read once, only when you check in or out, to confirm you&apos;re at the rostered place. It is never tracked in the background, and only you and HR can see the exact point. Breaks don&apos;t read your location.
        </p>
      ) : null}
    </SectionCard>
  );
}

const KIND_TEXT: Record<AttendanceEvent["kind"], string> = { in: "Checked in", out: "Checked out", break_start: "Break started", break_end: "Break ended" };

export function Timeline({ t }: { t: Today }) {
  const tz = t.timezone;
  if (t.events.length === 0) {
    return <EmptyState compact title="No check-ins yet today" body={t.plan.work_mode === "off" ? "Enjoy your day off." : "Your check-in, breaks and check-out will appear here."} />;
  }
  return (
    <ol className="timeline">
      {t.events.map((e, i) => (
        <li key={`${e.at}-${i}`} className={`tl-item ${e.kind}`}>
          <span className="tl-dot" aria-hidden="true">{e.kind === "in" ? <IconCheck /> : null}</span>
          <div>
            <strong>{KIND_TEXT[e.kind]} · {clock(e.at, tz)}</strong>
            <span className="meta block">
              {e.kind.startsWith("break")
                ? "No location read for breaks"
                : `${e.work_mode === "remote" ? "Remote" : e.location ?? "Office"}${e.distance_m !== null ? ` · ${e.distance_m} m from the office point` : ""}${
                    e.source === "correction" ? " · added by an approved correction" : e.verified ? " · location verified" : " · no location"
                  }`}
            </span>
          </div>
        </li>
      ))}
    </ol>
  );
}
