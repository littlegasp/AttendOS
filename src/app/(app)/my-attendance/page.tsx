"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { IconAlert, IconCheck, NavIcon } from "@/components/Icons";
import { PageContainer } from "@/components/PageContainer";
import { EmptyState, ErrorState, LoadingState } from "@/components/States";
import { Button, GlassCard, SectionCard, StatusBadge } from "@/components/ui";
import {
  LOCATE_MESSAGES,
  MODE_LABEL,
  SOURCE_LABEL,
  clock,
  hhmmss,
  locate,
  longDate,
  needsLocation,
  permissionState,
  workedMs,
  type Fix,
  type LocateError,
  type PunchResult,
  type Today,
} from "@/lib/attendance";
import { useSession } from "@/lib/session";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";

type Step = "idle" | "locating" | "submitting";

interface Problem {
  title: string;
  body: string;
  tone: "warning" | "danger";
}

const FAIL_TITLES: Record<string, string> = {
  location_required: "Location needed",
  accuracy_low: "Accuracy too low",
  outside_area: "Outside the permitted area",
  already_in: "Already checked in",
  not_checked_in: "Not checked in",
  day_off: "Not a working day",
  no_office: "No office set up",
  not_employee: "Account not set up",
  bad_request: "Couldn't verify",
};

export default function MyAttendancePage() {
  const { preview } = useSession();
  return (
    <PageContainer title="My Attendance" subtitle="Check in and check out with location verification" crumbs={[{ label: "Home", href: "/" }, { label: "My Attendance" }]}>
      {preview ? (
        <GlassCard>
          <EmptyState
            icon={<NavIcon name="clock" />}
            title="Check-in works once this copy is connected to its database"
            body="This is the design preview, so there is no account to record attendance against. Nothing here is pretend: as soon as the company's database is connected and you sign in, this screen shows your roster for today and lets you check in."
          />
        </GlassCard>
      ) : (
        <Attendance />
      )}
    </PageContainer>
  );
}

function Attendance() {
  const [today, setToday] = useState<Today | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [step, setStep] = useState<Step>("idle");
  const [problem, setProblem] = useState<Problem | null>(null);
  const [lastFix, setLastFix] = useState<{ accuracy: number; distance: number | null; location: string | null; ok: boolean } | null>(null);
  const [perm, setPerm] = useState<string>("unknown");
  const [announce, setAnnounce] = useState("");
  const offset = useRef(0); // server clock minus device clock
  const [now, setNow] = useState(() => Date.now());

  const apply = useCallback((t: Today) => {
    offset.current = Date.parse(t.server_now) - Date.now();
    setToday(t);
  }, []);

  const load = useCallback(async () => {
    setLoadError(null);
    const { data, error } = await supabase().rpc("my_today");
    if (error) return setLoadError(friendlyError(error));
    if (!data?.ok) return setLoadError(data?.code === "not_employee" ? "Your account is not set up as an active employee. Contact HR." : "Couldn't load today's attendance.");
    apply(data as Today);
  }, [apply]);

  useEffect(() => {
    load();
    permissionState().then(setPerm);
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [load]);

  async function punch(kind: "in" | "out") {
    if (!today || step !== "idle") return;
    setProblem(null);
    let fix: Fix | null = null;

    if (needsLocation(today)) {
      setStep("locating");
      setAnnounce("Verifying your location…");
      try {
        fix = await locate();
        setPerm("granted");
      } catch (e) {
        const code = e as LocateError;
        if (code === "denied") setPerm("denied");
        const m = LOCATE_MESSAGES[code] ?? LOCATE_MESSAGES.unavailable;
        setProblem({ ...m, tone: "warning" });
        setAnnounce(m.title);
        setStep("idle");
        return;
      }
    }

    setStep("submitting");
    setAnnounce(kind === "in" ? "Submitting check-in…" : "Submitting check-out…");
    const { data, error } = await supabase().rpc("punch", { p_kind: kind, p_lat: fix?.lat ?? null, p_lng: fix?.lng ?? null, p_accuracy: fix?.accuracy ?? null });
    setStep("idle");

    if (error) {
      // Never claim success without the server's answer.
      const msg = friendlyError(error);
      setProblem({ title: kind === "in" ? "Check-in not recorded" : "Check-out not recorded", body: `${msg} Nothing was saved, so you can safely try again.`, tone: "danger" });
      setAnnounce("Not recorded. " + msg);
      return;
    }

    const r = data as PunchResult;
    if (r.ok) {
      apply(r.today);
      setLastFix(fix ? { accuracy: Math.round(fix.accuracy), distance: r.event.distance_m, location: r.event.location, ok: true } : null);
      const msg = `${kind === "in" ? "Checked in" : "Checked out"} at ${clock(r.event.at, r.today.timezone)}`;
      toast({ tone: "success", title: msg, body: r.event.location ? `Verified at ${r.event.location}` : r.event.work_mode === "remote" ? "Remote work day" : undefined });
      setAnnounce(msg);
    } else {
      if (r.today) apply(r.today);
      if (fix) setLastFix({ accuracy: Math.round(fix.accuracy), distance: r.distance_m ?? null, location: r.location ?? null, ok: false });
      const tone = r.code === "already_in" || r.code === "not_checked_in" ? "warning" : "danger";
      setProblem({ title: FAIL_TITLES[r.code] ?? "Not recorded", body: r.message, tone });
      setAnnounce(`${FAIL_TITLES[r.code] ?? "Not recorded"}. ${r.message}`);
    }
  }

  if (loadError) return <GlassCard><ErrorState title="Couldn't load your attendance" body={loadError} onRetry={load} /></GlassCard>;
  if (!today) return <LoadingState label="Loading your attendance" />;

  const serverNow = now + offset.current;
  const tz = today.timezone;
  const off = today.plan.work_mode === "off";
  const lastIn = [...today.events].reverse().find((e) => e.kind === "in");
  const status = today.checked_in ? "in" : today.events.length ? "out" : "none";
  const busy = step !== "idle";
  const locNeeded = needsLocation(today);

  return (
    <>
      <p className="sr-only" aria-live="assertive" role="status">{announce}</p>
      <div className="att-grid">
        <GlassCard className="punch-card">
          <div className="punch-top">
            <div>
              <p className="meta">{longDate(serverNow, tz)}</p>
              <p className="punch-clock" aria-label={`Current time ${clock(serverNow, tz)}`}>{clock(serverNow, tz, true)}</p>
            </div>
            {status === "in" ? (
              <StatusBadge status="present" label="Checked in" />
            ) : status === "out" ? (
              <StatusBadge status="weekly-off" label="Checked out" />
            ) : off ? (
              <StatusBadge status="holiday" label="Day off" />
            ) : (
              <StatusBadge status="pending" label="Not checked in" />
            )}
          </div>

          <div className="punch-plan">
            <span className={`plan-chip mode-${today.plan.work_mode}`}>
              <NavIcon name={today.plan.work_mode === "remote" ? "dashboard" : today.plan.work_mode === "off" ? "holiday" : "department"} />
              {MODE_LABEL[today.plan.work_mode]}
              {today.plan.location ? ` · ${today.plan.location.name}` : ""}
            </span>
            <span className="meta">Today&apos;s plan, {SOURCE_LABEL[today.plan.source]}</span>
          </div>

          <div className="punch-action">
            {today.checked_in ? (
              <Button variant="primary" size="lg" className="punch-btn out" loading={busy} onClick={() => punch("out")}>
                {step === "locating" ? "Verifying location…" : step === "submitting" ? "Submitting check-out…" : "Check Out"}
              </Button>
            ) : (
              <Button variant="primary" size="lg" className="punch-btn" loading={busy} disabled={off} onClick={() => punch("in")}>
                {step === "locating" ? "Verifying location…" : step === "submitting" ? "Submitting check-in…" : "Check In"}
              </Button>
            )}
            {off && !today.checked_in ? <p className="meta">Today is not a working day on your roster. If you&apos;ve been asked to work, ask HR to update it.</p> : null}
          </div>

          <div className="punch-timer">
            <span className="meta">Worked today</span>
            <span className="timer-value">{hhmmss(workedMs(today.events, serverNow))}</span>
            {today.checked_in && lastIn ? <span className="meta">since {clock(lastIn.at, tz)}</span> : null}
          </div>

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

        <SectionCard title="Location verification" subtitle={locNeeded ? "Checked only when you press the button" : "Not needed today"}>
          <ul className="verify-list">
            <li>
              <span className="v-label">Today</span>
              <span>{MODE_LABEL[today.plan.work_mode]}{today.plan.location ? ` at ${today.plan.location.name} (within ${today.plan.location.radius_m} m)` : today.plan.work_mode === "office" ? " at any company office" : ""}</span>
            </li>
            <li>
              <span className="v-label">Location access</span>
              <span>
                {perm === "granted" ? <StatusBadge status="verified" label="Allowed" /> : perm === "denied" ? <StatusBadge status="failed" label="Blocked" /> : <StatusBadge status="pending" label="Will ask" />}
              </span>
            </li>
            <li>
              <span className="v-label">Accuracy needed</span>
              <span>{today.max_accuracy_m} m or better</span>
            </li>
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
          <p className="meta privacy-note">
            Your location is read once, only when you check in or out, to confirm you&apos;re at the rostered place. It is never tracked in the background, and only you and HR can see the exact point.
          </p>
        </SectionCard>
      </div>

      <SectionCard title="Today's timeline" subtitle={longDate(serverNow, tz)}>
        {today.events.length === 0 ? (
          <EmptyState compact title="No check-ins yet today" body={off ? "Enjoy your day off." : "Your check-in and check-out times will appear here."} />
        ) : (
          <ol className="timeline">
            {today.events.map((e, i) => (
              <li key={`${e.at}-${i}`} className={`tl-item ${e.kind}`}>
                <span className="tl-dot" aria-hidden="true">{e.kind === "in" ? <IconCheck /> : null}</span>
                <div>
                  <strong>{e.kind === "in" ? "Checked in" : "Checked out"} · {clock(e.at, tz)}</strong>
                  <span className="meta block">
                    {e.work_mode === "remote" ? "Remote" : e.location ?? "Office"}
                    {e.distance_m !== null ? ` · ${e.distance_m} m from the office point` : ""}
                    {e.verified ? " · location verified" : " · no location"}
                  </span>
                </div>
              </li>
            ))}
          </ol>
        )}
      </SectionCard>

      <p className="meta">Missed a check-out or something looks wrong? Tell HR. Your original entries are never edited away; any correction is kept with a reason.</p>
    </>
  );
}
