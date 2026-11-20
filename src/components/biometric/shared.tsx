"use client";

import { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { IconInfo } from "@/components/Icons";
import { Tabs } from "@/components/Tabs";
import { type AttendanceStatus, StatusBadge } from "@/components/ui";
import { type Action, CONN_LABEL, type Conn, type DemoState, DemoRuleError, type Office, type Person, reducer } from "@/lib/biometric-mock";
import { can, type Capability, type Role } from "@/lib/permissions";

type DistOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never;
export type DemoAction = DistOmit<Action, "role" | "by">;

interface Demo {
  state: DemoState;
  /** Applies a demonstration action locally, as the signed-in role. Returns an error message when a rule or permission blocks it. */
  apply: (a: DemoAction) => string | null;
  people: Person[];
  offices: Office[];
  samplePeople: boolean;
  role: Role;
  may: (c: Capability) => boolean;
  by: string;
  tz: string;
  now: number;
}

const Ctx = createContext<Demo | null>(null);

export function DemoProvider({ initial, people, offices, samplePeople, role, by, tz, children }: { initial: DemoState; people: Person[]; offices: Office[]; samplePeople: boolean; role: Role; by: string; tz: string; children: React.ReactNode }) {
  const [state, setState] = useState(initial);
  const ref = useRef(state);
  ref.current = state;
  const [now] = useState(() => Date.now());
  const apply = useCallback(
    (a: DemoAction) => {
      try {
        const next = reducer(people)(ref.current, { ...a, role, by } as Action);
        ref.current = next;
        setState(next);
        return null;
      } catch (e) {
        if (e instanceof DemoRuleError) return e.message;
        throw e;
      }
    },
    [people, role, by],
  );
  const may = useCallback((c: Capability) => can(role, c), [role]);
  return <Ctx.Provider value={{ state, apply, people, offices, samplePeople, role, may, by, tz, now }}>{children}</Ctx.Provider>;
}

export function useDemo(): Demo {
  const d = useContext(Ctx);
  if (!d) throw new Error("useDemo outside DemoProvider");
  return d;
}

/** Shown at the top of every biometric screen, with the demonstration controls. */
export function DemoBanner({ onReset, onEmpty, empty }: { onReset: () => void; onEmpty: () => void; empty: boolean }) {
  const { samplePeople } = useDemo();
  return (
    <div className="alert info bio-demo" role="note" aria-label="Demonstration mode">
      <IconInfo />
      <div className="bio-demo-body">
        <strong>Demonstration data — no biometric device, Sync Agent or gateway is connected.</strong>
        <p>
          Devices, agents, codes, sync runs and review items are samples. Every action changes only this browser tab and is lost on reload: no device is contacted, no sync
          is retried and no database record is changed. {samplePeople ? "People and offices are sample names (preview mode)." : "People and offices are your company's real records, shown read-only."}
        </p>
        <div className="bio-demo-actions">
          <button type="button" className="link-btn small" onClick={onReset}>Reset sample data</button>
          {empty ? null : <button type="button" className="link-btn small" onClick={onEmpty}>Show the empty module</button>}
        </div>
      </div>
    </div>
  );
}

/** The module's tab bar: the shared Tabs, wrapped so phones can scroll it sideways with a visible hint. */
export function BioTabs<T extends string>(props: { tabs: { id: T; label: string; badge?: string }[]; value: T; onChange: (id: T) => void; label: string }) {
  const wrap = useRef<HTMLDivElement>(null);
  const [edge, setEdge] = useState({ left: false, right: false });
  useEffect(() => {
    const bar = wrap.current?.querySelector<HTMLElement>(".tabs");
    if (!bar) return;
    const update = () => setEdge({ left: bar.scrollLeft > 2, right: bar.scrollLeft + bar.clientWidth < bar.scrollWidth - 2 });
    const on = bar.querySelector<HTMLElement>(".tab-btn.on");
    if (on) {
      // Bring the selected tab fully into view without moving the page vertically.
      const l = on.offsetLeft - 16;
      const r = on.offsetLeft + on.offsetWidth + 16 - bar.clientWidth;
      if (l < bar.scrollLeft) bar.scrollLeft = Math.max(0, l);
      else if (r > bar.scrollLeft) bar.scrollLeft = r;
    }
    update();
    bar.addEventListener("scroll", update, { passive: true });
    window.addEventListener("resize", update);
    return () => {
      bar.removeEventListener("scroll", update);
      window.removeEventListener("resize", update);
    };
  }, [props.value]);
  return (
    <div ref={wrap} className={`bio-tabs${edge.left ? " fade-l" : ""}${edge.right ? " fade-r" : ""}`}>
      <Tabs {...props} />
      {edge.right ? <span className="bio-tabs-more" aria-hidden="true">›</span> : null}
    </div>
  );
}

const CONN_STATUS: Record<Conn, AttendanceStatus> = { online: "verified", offline: "absent", error: "failed", never: "weekly-off", disabled: "weekly-off" };

export function ConnBadge({ conn }: { conn: Conn }) {
  return <StatusBadge status={CONN_STATUS[conn]} label={`${CONN_LABEL[conn]}${conn === "disabled" ? "" : " · demo"}`} />;
}

export function fmtTime(iso: string | null, tz: string): string {
  if (!iso) return "—";
  return new Intl.DateTimeFormat("en-IN", { timeZone: tz, day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", hour12: true }).format(new Date(iso));
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

/** One line repeated in every dialog so a decision is never mistaken for a real change. */
export function DemoNote() {
  return <p className="meta bio-demo-note">Demonstration: only this browser tab changes. Nothing is sent to a device or saved to the database.</p>;
}
