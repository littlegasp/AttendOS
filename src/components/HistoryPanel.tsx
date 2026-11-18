"use client";

import { useState } from "react";
import {
  CORRECTION_KIND_LABEL,
  STATUS_BADGE,
  STATUS_LABEL,
  clock,
  hm,
  isoToHhmm,
  localToIso,
  shortDate,
  type DayRow,
} from "@/lib/attendance";
import { addDays, todayIn } from "@/lib/roster";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";
import { must, useLoad } from "@/lib/use-load";
import { Modal } from "./Modal";
import { EmptyState, ErrorState, LoadingState } from "./States";
import { Button, FormInput, FormSelect, FormTextarea, GlassCard, SectionCard, StatusBadge } from "./ui";

const monthStart = (day: string) => `${day.slice(0, 7)}-01`;
const monthEnd = (start: string) => addDays(`${addDays(start, 32).slice(0, 7)}-01`, -1);
const monthLabel = (start: string) => new Date(`${start}T12:00:00Z`).toLocaleDateString("en-IN", { month: "long", year: "numeric", timeZone: "UTC" });

/**
 * Day-by-day attendance for one person: times, breaks, late / early / overtime, status.
 * `employeeId` is the signed-in person on My Attendance; the database also lets their
 * manager and HR read it.
 */
export function HistoryPanel({ employeeId, tz, days, canRequest = true, onRequested }: { employeeId: string; tz: string; days?: number; canRequest?: boolean; onRequested?: () => void }) {
  const today = todayIn(tz);
  const [month, setMonth] = useState(monthStart(today));
  const from = days ? addDays(today, -(days - 1)) : month;
  const to = days ? today : monthEnd(month) > today ? today : monthEnd(month);
  const [fix, setFix] = useState<DayRow | null>(null);

  const { data, error, loading, reload } = useLoad(
    async () => (from > today ? [] : must(await supabase().rpc("attendance_history", { emp: employeeId, d_from: from, d_to: to })) as DayRow[]),
    `${employeeId}:${from}:${to}`,
  );

  if (error) return <GlassCard><ErrorState title="Couldn't load attendance history" body={error} onRetry={reload} /></GlassCard>;

  const rows = (data ?? []).filter((r) => !["scheduled"].includes(r.status));
  const worked = rows.reduce((a, r) => a + r.worked_min, 0);
  const lateDays = rows.filter((r) => r.late_min > 0).length;
  const present = rows.filter((r) => ["present", "late", "working", "on_break", "missing_checkout"].includes(r.status)).length;
  const ot = rows.reduce((a, r) => a + r.overtime_min, 0);
  const missing = rows.filter((r) => r.status === "missing_checkout").length;
  const canFix = (r: DayRow) => canRequest && !r.pending_correction && r.work_date >= addDays(today, -31) && !["off", "holiday", "not_started", "working", "on_break"].includes(r.status);

  const body =
    !data ? (
      <LoadingState kind="table" label="Loading history" />
    ) : rows.length === 0 ? (
      <EmptyState compact title="No attendance in this period" body="Days appear here once you're rostered or check in." />
    ) : (
      <>
        <div className="history-stats">
          <span><strong>{present}</strong> <span className="meta">days attended</span></span>
          <span><strong>{hm(worked)}</strong> <span className="meta">worked</span></span>
          <span><strong>{lateDays}</strong> <span className="meta">late</span></span>
          <span><strong>{hm(ot)}</strong> <span className="meta">overtime</span></span>
          {missing ? <span className="warn"><strong>{missing}</strong> <span className="meta">missing check-out</span></span> : null}
        </div>
        <div className="table-wrap history-table">
          <table className="table">
            <thead>
              <tr>
                <th scope="col">Date</th><th scope="col">Shift</th><th scope="col">In</th><th scope="col">Out</th><th scope="col">Break</th>
                <th scope="col">Worked</th><th scope="col">Late</th><th scope="col">Early</th><th scope="col">Overtime</th><th scope="col">Status</th>
                {canRequest ? <th scope="col"><span className="sr-only">Actions</span></th> : null}
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.work_date}>
                  <th scope="row">{shortDate(r.work_date)}</th>
                  <td className="muted" title={r.shift_start ? `${clock(r.shift_start, tz)}–${clock(r.shift_end!, tz)}` : undefined}>{r.shift_name ?? (r.work_mode === "off" ? "—" : "No shift")}</td>
                  <td>{r.first_in ? clock(r.first_in, tz) : "—"}</td>
                  <td>{r.last_out ? clock(r.last_out, tz) : r.open ? <span className="muted">open</span> : "—"}</td>
                  <td>{r.break_min ? hm(r.break_min) : "—"}</td>
                  <td>{r.worked_min ? hm(r.worked_min) : "—"}</td>
                  <td className={r.late_min ? "warn" : ""}>{r.late_min ? hm(r.late_min) : "—"}</td>
                  <td className={r.early_min ? "warn" : ""}>{r.early_min ? hm(r.early_min) : "—"}</td>
                  <td>{r.overtime_min ? hm(r.overtime_min) : "—"}</td>
                  <td>
                    <StatusBadge status={STATUS_BADGE[r.status]} label={STATUS_LABEL[r.status]} />
                    {r.pending_correction ? <span className="tiny muted block">Correction pending</span> : null}
                  </td>
                  {canRequest ? <td>{canFix(r) ? <Button size="sm" variant="ghost" aria-label={`Request a correction for ${shortDate(r.work_date)}`} onClick={() => setFix(r)}>Correct…</Button> : null}</td> : null}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <ul className="history-cards" aria-label="Attendance by day">
          {rows.map((r) => (
            <li key={r.work_date} className="history-card">
              <div className="hc-top">
                <strong>{shortDate(r.work_date)}</strong>
                <StatusBadge status={STATUS_BADGE[r.status]} label={STATUS_LABEL[r.status]} />
              </div>
              <div className="hc-times">
                <span><span className="meta block">In</span>{r.first_in ? clock(r.first_in, tz) : "—"}</span>
                <span><span className="meta block">Out</span>{r.last_out ? clock(r.last_out, tz) : r.open ? "open" : "—"}</span>
                <span><span className="meta block">Worked</span>{r.worked_min ? hm(r.worked_min) : "—"}</span>
              </div>
              {r.late_min || r.early_min || r.overtime_min || r.pending_correction ? (
                <p className="meta">
                  {[r.late_min ? `Late ${hm(r.late_min)}` : "", r.early_min ? `Left ${hm(r.early_min)} early` : "", r.overtime_min ? `Overtime ${hm(r.overtime_min)}` : "", r.pending_correction ? "Correction pending" : ""]
                    .filter(Boolean)
                    .join(" · ")}
                </p>
              ) : null}
              {canFix(r) ? <Button size="sm" variant="ghost" onClick={() => setFix(r)}>Request correction</Button> : null}
            </li>
          ))}
        </ul>
      </>
    );

  return (
    <SectionCard
      title={days ? "Recent attendance" : "Attendance history"}
      subtitle={days ? `Last ${days} days` : monthLabel(month)}
      actions={
        days ? null : (
          <>
            <Button size="sm" onClick={() => setMonth(monthStart(addDays(month, -1)))} aria-label="Previous month">‹</Button>
            <Button size="sm" variant="ghost" onClick={() => setMonth(monthStart(today))}>This month</Button>
            <Button size="sm" onClick={() => setMonth(monthStart(addDays(monthEnd(month), 1)))} disabled={monthStart(today) <= month} aria-label="Next month">›</Button>
            {loading ? <span className="spinner sm" aria-label="Updating" /> : null}
          </>
        )
      }
    >
      {body}
      {fix ? (
        <CorrectionModal
          row={fix}
          tz={tz}
          onClose={() => setFix(null)}
          onSaved={() => {
            setFix(null);
            reload();
            onRequested?.();
          }}
        />
      ) : null}
    </SectionCard>
  );
}

/** Ask for a correction to one day. HR / the manager decides; nothing changes until then. */
export function CorrectionModal({ row, tz, onClose, onSaved }: { row: DayRow; tz: string; onClose: () => void; onSaved: () => void }) {
  const suggested = row.status === "missing_checkout" ? "missing_out" : !row.first_in ? "missing_in" : "wrong_time";
  const [kind, setKind] = useState(suggested);
  const [tin, setTin] = useState(row.first_in ? isoToHhmm(row.first_in, tz) : row.shift_start ? isoToHhmm(row.shift_start, tz) : "09:00");
  const [tout, setTout] = useState(row.last_out ? isoToHhmm(row.last_out, tz) : row.shift_end ? isoToHhmm(row.shift_end, tz) : "18:00");
  const [nextDay, setNextDay] = useState(Boolean(row.shift_end && row.shift_start && row.shift_end.slice(0, 10) !== row.shift_start.slice(0, 10)));
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const wantIn = kind === "missing_in" || kind === "wrong_time" || kind === "other";
  const wantOut = kind === "missing_out" || kind === "wrong_time" || kind === "other";

  async function send() {
    setErr(null);
    if (reason.trim().length < 5) return setErr("Write a short reason (at least 5 characters).");
    setBusy(true);
    const { data, error } = await supabase().rpc("request_correction", {
      p_work_date: row.work_date,
      p_kind: kind,
      p_in: wantIn && tin ? localToIso(row.work_date, tin, tz) : null,
      p_out: wantOut && tout ? localToIso(row.work_date, tout, tz, nextDay ? 1 : 0) : null,
      p_reason: reason.trim(),
    });
    setBusy(false);
    if (error) return setErr(friendlyError(error));
    if (!data?.ok) return setErr(data?.message ?? "Couldn't send the request.");
    toast({ tone: "success", title: "Correction requested", body: `${shortDate(row.work_date)} · waiting for approval` });
    onSaved();
  }

  return (
    <Modal open title={`Request a correction · ${shortDate(row.work_date)}`} subtitle="Your original entries stay on record; an approved correction is added beside them." onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <FormSelect label="What needs correcting?" value={kind} onChange={(e) => setKind(e.target.value)} options={Object.entries(CORRECTION_KIND_LABEL).map(([value, label]) => ({ value, label }))} />
        <div className="form-2">
          {wantIn ? <FormInput label="Correct check-in time" type="time" value={tin} onChange={(e) => setTin(e.target.value)} /> : null}
          {wantOut ? <FormInput label="Correct check-out time" type="time" value={tout} onChange={(e) => setTout(e.target.value)} /> : null}
        </div>
        {wantOut ? (
          <label className="check-row">
            <input type="checkbox" checked={nextDay} onChange={(e) => setNextDay(e.target.checked)} /> Check-out was after midnight (overnight shift)
          </label>
        ) : null}
        <FormTextarea label="Reason" required rows={3} value={reason} onChange={(e) => setReason(e.target.value)} helper="e.g. Phone battery died; left at 6 pm." maxLength={300} />
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} onClick={send}>Send request</Button>
        </div>
      </div>
    </Modal>
  );
}
