"use client";

import { createContext, useCallback, useContext, useRef, useState } from "react";
import { IconInfo } from "@/components/Icons";
import { type AttendanceStatus, StatusBadge } from "@/components/ui";
import {
  type Action,
  CONN_LABEL,
  type Conn,
  type DemoState,
  DemoRuleError,
  type Office,
  type Person,
  reducer,
} from "@/lib/biometric-mock";

interface Demo {
  state: DemoState;
  /** Applies a demonstration action locally. Returns an error message when a rule is broken. */
  apply: (a: Action) => string | null;
  people: Person[];
  offices: Office[];
  /** True when people and offices are the sample lists (preview mode). */
  samplePeople: boolean;
  by: string;
  tz: string;
  now: number;
}

const Ctx = createContext<Demo | null>(null);

export function DemoProvider({ initial, people, offices, samplePeople, by, tz, children }: { initial: DemoState; people: Person[]; offices: Office[]; samplePeople: boolean; by: string; tz: string; children: React.ReactNode }) {
  const [state, setState] = useState(initial);
  const ref = useRef(state);
  ref.current = state;
  const [now] = useState(() => Date.now());
  const apply = useCallback(
    (a: Action) => {
      try {
        const next = reducer(people)(ref.current, a);
        ref.current = next;
        setState(next);
        return null;
      } catch (e) {
        if (e instanceof DemoRuleError) return e.message;
        throw e;
      }
    },
    [people],
  );
  return <Ctx.Provider value={{ state, apply, people, offices, samplePeople, by, tz, now }}>{children}</Ctx.Provider>;
}

export function useDemo(): Demo {
  const d = useContext(Ctx);
  if (!d) throw new Error("useDemo outside DemoProvider");
  return d;
}

/** Shown at the top of every biometric screen. */
export function DemoBanner({ samplePeople }: { samplePeople: boolean }) {
  return (
    <div className="alert info bio-demo" role="note">
      <IconInfo />
      <div>
        <strong>Demonstration data — no biometric device, Sync Agent or gateway is connected.</strong>
        <p>
          Devices, agents, codes, sync runs and review items are samples. Changes stay in this browser tab and are lost on reload; nothing is saved to the
          database and no attendance is affected. {samplePeople ? "People and offices are sample names (preview mode)." : "People and offices are your company's real records, read-only."}
        </p>
      </div>
    </div>
  );
}

const CONN_STATUS: Record<Conn, AttendanceStatus> = { online: "verified", offline: "absent", error: "failed", never: "weekly-off", disabled: "weekly-off" };

export function ConnBadge({ conn }: { conn: Conn }) {
  return <StatusBadge status={CONN_STATUS[conn]} label={`${CONN_LABEL[conn]}${conn === "disabled" ? "" : " · demo"}`} />;
}

export function fmtTime(iso: string | null, tz: string): string {
  if (!iso) return "—";
  return new Intl.DateTimeFormat("en-IN", { timeZone: tz, day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit", hour12: true }).format(new Date(iso));
}

export function ago(iso: string | null, now: number): string {
  if (!iso) return "never";
  const s = Math.round((now - Date.parse(iso)) / 1000);
  if (s < 0) return "in the future";
  if (s < 90) return "just now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h} h ago`;
  return `${Math.round(h / 24)} days ago`;
}

export function drift(s: number | null): string {
  if (s === null) return "Unknown";
  const a = Math.abs(s);
  const t = a < 60 ? `${a} s` : `${Math.floor(a / 60)} min ${a % 60} s`;
  return s === 0 ? "In sync" : `${t} ${s > 0 ? "ahead of" : "behind"} the agent`;
}

/** Buttons for real-hardware actions that arrive in later phases: visible, explained, never pretending. */
export function NotYet({ label, phase }: { label: string; phase: string }) {
  return (
    <button type="button" className="btn secondary sm" disabled title={`Available in Phase ${phase} — no hardware connection in this demonstration`}>
      <span>{label}</span>
      <span className="bio-later">{phase}</span>
    </button>
  );
}
