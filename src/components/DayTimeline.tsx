"use client";

import { clock, shortDate } from "@/lib/attendance";
import { useSession } from "@/lib/session";
import { type DayEvent, missingFunction, punchLabel, punchTone, type Tone, verificationOf } from "@/lib/sources";
import { supabase } from "@/lib/supabase";
import { useLoad } from "@/lib/use-load";
import { Modal } from "./Modal";
import { SourceBadge } from "./SourceBadges";
import { EmptyState, ErrorState, LoadingState } from "./States";

const KIND: Record<string, string> = { in: "IN", out: "OUT", break_start: "Break start", break_end: "Break end" };

function Badge({ tone, children }: { tone: Tone; children: React.ReactNode }) {
  return (
    <span className={`badge tone-${tone}`}>
      <span className="badge-dot" aria-hidden="true" />
      {children}
    </span>
  );
}

interface Pending { pending_checkout: boolean; provisional_out_at: string | null; final_at: string | null }
interface Loaded { events: DayEvent[]; pending: Pending | null; directions: Map<number, string> }

/**
 * Everything recorded for one person on one work date (day_events, migration 0012): counted check-ins and
 * check-outs from every source, plus biometric/imported punches that were not counted and why. Read-only.
 * Direction of an uncounted punch is shown only where the device reported it and the reader may see it (HR/Admin).
 */
export function DayTimeline({ employeeId, name, day, tz, onClose }: { employeeId: string; name?: string; day: string; tz: string; onClose: () => void }) {
  const { role } = useSession();
  const hr = role === "admin" || role === "hr";
  const { data, error, reload } = useLoad<Loaded | "missing">(async () => {
    const sb = supabase();
    const [ev, pd] = await Promise.all([sb.rpc("day_events", { p_emp: employeeId, p_day: day }), sb.rpc("biometric_day_pending", { p_emp: employeeId, p_day: day })]);
    if (ev.error) {
      if (missingFunction(ev.error)) return "missing";
      throw ev.error;
    }
    const events = (ev.data ?? []) as DayEvent[];
    const pending = pd.error ? null : ((Array.isArray(pd.data) ? pd.data[0] : pd.data) as Pending | null);
    const directions = new Map<number, string>();
    const ids = events.filter((e) => !e.counted && e.raw_event_id && !e.kind).map((e) => e.raw_event_id!);
    if (hr && ids.length) {
      // Only the direction column of the safe view (no payload columns exist in it); row level security limits it to HR/Admin.
      const { data: raw } = await sb.from("biometric_raw_events_safe").select("id, direction").in("id", ids);
      for (const r of (raw ?? []) as { id: number; direction: string | null }[]) if (r.direction) directions.set(r.id, r.direction);
    }
    return { events, pending, directions };
  }, `timeline:${employeeId}:${day}`);

  const title = `Day timeline · ${shortDate(day)}`;
  return (
    <Modal open title={title} subtitle={name ? `${name} · times in ${tz}` : `Times in ${tz}`} onClose={onClose} wide>
      {error ? (
        <ErrorState title="Couldn't load this day" body={error} onRetry={reload} />
      ) : !data ? (
        <LoadingState kind="table" label="Loading the day" />
      ) : data === "missing" ? (
        <EmptyState compact title="Timeline not available yet" body="This database does not have the attendance timeline installed yet. The attendance figures on this screen are unaffected." />
      ) : (
        <TimelineBody data={data} tz={tz} />
      )}
    </Modal>
  );
}

function TimelineBody({ data, tz }: { data: Loaded; tz: string }) {
  const { events, pending, directions } = data;
  return (
    <div className="stack day-timeline">
      {pending?.pending_checkout && pending.provisional_out_at ? (
        <div className="alert warning" role="note" data-testid="provisional-note">
          <p>
            <strong>Provisional check-out at {clock(pending.provisional_out_at, tz)}.</strong> It is not counted in working hours, overtime or early leaving. It becomes the
            final check-out when the day closes{pending.final_at ? ` (${clock(pending.final_at, tz)})` : ""}, unless a later punch or a correction replaces it.
          </p>
        </div>
      ) : null}
      {events.length === 0 ? (
        <EmptyState compact title="Nothing recorded on this day" body="Check-ins, check-outs and device punches for this date appear here." />
      ) : (
        <>
          <div className="table-wrap">
            <table className="table timeline-table">
              <thead>
                <tr>
                  <th scope="col">Time</th><th scope="col">Direction</th><th scope="col">Source</th><th scope="col">Device</th><th scope="col">Status</th>
                </tr>
              </thead>
              <tbody>
                {events.map((e, i) => <Row key={`${e.attendance_event_id ?? "r"}-${e.raw_event_id ?? i}-${i}`} e={e} tz={tz} dir={e.raw_event_id ? directions.get(e.raw_event_id) : undefined} />)}
              </tbody>
            </table>
          </div>
          <ul className="timeline-cards" aria-label="Day timeline">
            {events.map((e, i) => {
              const s = status(e);
              return (
                <li key={`c-${i}`} className="history-card">
                  <div className="hc-top">
                    <strong>{clock(e.at, tz)} · {direction(e, e.raw_event_id ? directions.get(e.raw_event_id) : undefined)}</strong>
                    <SourceBadge source={e.source} />
                  </div>
                  <p className="meta">{e.device ? `${e.device} · ` : ""}{s.text}{s.note ? ` · ${s.note}` : ""}</p>
                </li>
              );
            })}
          </ul>
        </>
      )}
      <p className="meta">
        Only rows marked <strong>Counted</strong> make up the day&rsquo;s hours. Biometric and imported records show which device recorded the mapped employee code; they are not GPS-verified.
        A device punch is never edited — corrections are added beside it.
      </p>
    </div>
  );
}

function direction(e: DayEvent, raw?: string): string {
  if (e.kind) return KIND[e.kind] ?? e.kind;
  if (e.role === "provisional_out") return "OUT (provisional)";
  if (raw === "in" || raw === "out") return `${raw.toUpperCase()} (device key)`;
  return "Punch";
}

function status(e: DayEvent): { text: string; tone: Tone; note?: string } {
  if (e.counted) {
    const v = verificationOf({ source: e.source, kind: e.kind, verified: null });
    return { text: "Counted", tone: "success", note: e.source === "web" ? undefined : e.source === "correction" ? v.label : `${v.label} · not GPS-verified` };
  }
  if (e.kind) return { text: e.replaced_by_correction ? "Replaced by a correction (kept on record)" : "Not counted (replaced)", tone: "neutral" };
  return { text: punchLabel(e), tone: punchTone(e.role) };
}

function Row({ e, tz, dir }: { e: DayEvent; tz: string; dir?: string }) {
  const s = status(e);
  return (
    <tr className={e.counted ? undefined : "muted-row"} data-source={e.source} data-counted={e.counted ? "yes" : "no"}>
      <th scope="row">{clock(e.at, tz)}</th>
      <td>{direction(e, dir)}</td>
      <td><SourceBadge source={e.source} /></td>
      <td className="bio-wrap">{e.device ?? <span className="muted">—</span>}</td>
      <td><Badge tone={s.tone}>{s.text}</Badge>{s.note ? <span className="tiny muted block">{s.note}</span> : null}</td>
    </tr>
  );
}
