"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { LOCATE_MESSAGES, clock, locate, needsLocation, permissionState, type Fix, type LocateError, type PunchKind, type PunchResult, type Today } from "./attendance";
import { friendlyError, supabase } from "./supabase";
import { toast } from "./toast";

export type Step = "idle" | "locating" | "submitting";

export interface Problem {
  title: string;
  body: string;
  tone: "warning" | "danger";
}

export interface LastFix {
  accuracy: number;
  distance: number | null;
  location: string | null;
  ok: boolean;
}

const FAIL_TITLES: Record<string, string> = {
  location_required: "Location needed",
  accuracy_low: "Accuracy too low",
  outside_area: "Outside the permitted area",
  already_in: "Already checked in",
  not_checked_in: "Not checked in",
  already_on_break: "Already on a break",
  not_on_break: "Not on a break",
  day_off: "Not a working day",
  no_office: "No office set up",
  not_employee: "Account not set up",
  bad_request: "Couldn't verify",
};

const DONE: Record<PunchKind, string> = { in: "Checked in", out: "Checked out", break_start: "Break started", break_end: "Break ended" };

/**
 * Today's attendance for the signed-in person, plus the check-in / break / check-out actions.
 * Shared by My Attendance and the personal dashboard so both behave identically.
 * Nothing is shown as done until the server has saved it.
 */
export function useAttendance() {
  const [today, setToday] = useState<Today | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [step, setStep] = useState<Step>("idle");
  const [problem, setProblem] = useState<Problem | null>(null);
  const [lastFix, setLastFix] = useState<LastFix | null>(null);
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

  const act = useCallback(
    async (kind: PunchKind) => {
      if (!today || step !== "idle") return;
      setProblem(null);
      let fix: Fix | null = null;

      if ((kind === "in" || kind === "out") && needsLocation(today)) {
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
      setAnnounce("Saving…");
      const { data, error } = await supabase().rpc("punch", { p_kind: kind, p_lat: fix?.lat ?? null, p_lng: fix?.lng ?? null, p_accuracy: fix?.accuracy ?? null });
      setStep("idle");

      if (error) {
        const msg = friendlyError(error);
        setProblem({ title: `${DONE[kind]}: not recorded`, body: `${msg} Nothing was saved, so you can safely try again.`, tone: "danger" });
        setAnnounce("Not recorded. " + msg);
        return;
      }
      const r = data as PunchResult;
      if (r.ok) {
        apply(r.today);
        if (fix) setLastFix({ accuracy: Math.round(fix.accuracy), distance: r.event.distance_m ?? null, location: r.event.location ?? null, ok: true });
        const msg = `${DONE[kind]} at ${clock(r.event.at, r.today.timezone)}`;
        toast({ tone: "success", title: msg, body: r.event.location ? `Verified at ${r.event.location}` : kind === "in" && r.event.work_mode === "remote" ? "Remote work day" : undefined });
        setAnnounce(msg);
      } else {
        if (r.today) apply(r.today);
        if (fix) setLastFix({ accuracy: Math.round(fix.accuracy), distance: r.distance_m ?? null, location: r.location ?? null, ok: false });
        const tone = ["already_in", "not_checked_in", "already_on_break", "not_on_break"].includes(r.code) ? "warning" : "danger";
        setProblem({ title: FAIL_TITLES[r.code] ?? "Not recorded", body: r.message, tone });
        setAnnounce(`${FAIL_TITLES[r.code] ?? "Not recorded"}. ${r.message}`);
      }
    },
    [today, step, apply],
  );

  return { today, loadError, load, step, problem, lastFix, perm, announce, act, serverNow: now + offset.current };
}
