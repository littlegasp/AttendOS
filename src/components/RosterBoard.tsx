"use client";

import { useMemo, useState } from "react";
import { MODE_LABEL, timeOfDay, type WorkMode } from "@/lib/attendance";
import {
  addDays,
  isOvernight,
  mondayOf,
  planFor,
  shiftFor,
  todayIn,
  weekDays,
  WEEK_ORDER,
  WEEKDAY_SHORT,
  type DayRow,
  type Employee,
  type Holiday,
  type Location,
  type Org,
  type PatternRow,
  type Plan,
  type RemoteException,
  type Shift,
  type ShiftDayRow,
  type ShiftPatternRow,
} from "@/lib/roster";
import { useSession } from "@/lib/session";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";
import { must, useLoad } from "@/lib/use-load";
import { Modal } from "./Modal";
import { EmptyState, ErrorState, LoadingState } from "./States";
import { Button, FormSelect, FormTextarea, GlassCard } from "./ui";

interface Data {
  org: Org;
  locations: Location[];
  employees: Employee[];
  pattern: PatternRow[];
  days: DayRow[];
  shifts: Shift[];
  shiftPattern: ShiftPatternRow[];
  shiftDays: ShiftDayRow[];
  holidays: Holiday[];
  exceptions: RemoteException[];
}

const fmtDay = (d: string) => new Date(`${d}T12:00:00Z`).toLocaleDateString("en-IN", { day: "numeric", month: "short", timeZone: "UTC" });
export const shiftTimes = (s: Pick<Shift, "start_time" | "end_time">) => `${timeOfDay(s.start_time.slice(0, 5))}–${timeOfDay(s.end_time.slice(0, 5))}`;

function Chip({ plan, locations }: { plan: Plan; locations: Location[] }) {
  const loc = plan.location_id ? locations.find((l) => l.id === plan.location_id)?.name : null;
  return (
    <span className={`plan-chip sm mode-${plan.work_mode}${plan.source === "day" ? " changed" : ""}`}>
      {plan.source === "holiday" ? "Holiday" : MODE_LABEL[plan.work_mode]}
      {plan.work_mode === "office" ? <span className="chip-sub">{loc ?? "Any office"}</span> : null}
      {plan.source === "holiday" || plan.source === "exception" ? <span className="chip-sub">{plan.source === "exception" ? "Exception" : plan.note}</span> : null}
    </span>
  );
}

function ShiftLine({ shift, changed }: { shift: Shift | undefined; changed: boolean }) {
  if (!shift) return <span className="shift-line none">No shift</span>;
  return (
    <span className={`shift-line${changed ? " changed" : ""}`} title={`${shift.name}: ${shiftTimes(shift)}`}>
      {shift.name} · {shiftTimes(shift)}
      {isOvernight(shift) ? " ↷" : ""}
    </span>
  );
}

/**
 * HR sets, separately: WHERE each person works (office / remote / day off) and WHICH SHIFT
 * (start, end, break, grace). Others see their permitted rows read-only.
 */
export function RosterBoard() {
  const { role } = useSession();
  const canEdit = role === "admin" || role === "hr";
  const [monday, setMonday] = useState<string | null>(null);
  const [q, setQ] = useState("");
  const [selected, setSelected] = useState<string[]>([]);
  const [dayEdit, setDayEdit] = useState<{ emp: Employee; day: string; plan: Plan; shiftId: string | null; shiftChanged: boolean } | null>(null);
  const [patternFor, setPatternFor] = useState<Employee[] | null>(null);

  const week = monday ?? "";
  const { data, error, loading, reload } = useLoad<Data>(async () => {
    const sb = supabase();
    const org = must(await sb.from("organization").select("timezone, max_accuracy_m, remote_location_required, default_work_mode, weekly_off, default_shift_id").single<Org>());
    const start = monday ?? mondayOf(todayIn(org.timezone));
    if (!monday) setMonday(start);
    const end = addDays(start, 6);
    const [locations, employees, pattern, days, shifts, shiftPattern, shiftDays, holidays, exceptions] = await Promise.all([
      sb.from("locations").select("*").order("name").then(must<Location[]>),
      sb.from("employees").select("id, full_name, emp_code, role, active, home_location_id, default_shift_id").eq("active", true).order("full_name").then(must<Employee[]>),
      sb.from("roster_pattern").select("*").then(must<PatternRow[]>),
      sb.from("roster_day").select("*").gte("day", start).lte("day", end).then(must<DayRow[]>),
      sb.from("shifts").select("*").order("start_time").then(must<Shift[]>),
      sb.from("shift_pattern").select("*").then(must<ShiftPatternRow[]>),
      sb.from("shift_day").select("*").gte("day", start).lte("day", end).then(must<ShiftDayRow[]>),
      sb.from("holidays").select("*").gte("day", start).lte("day", end).then(must<Holiday[]>),
      sb.from("remote_exceptions").select("*").lte("start_date", end).gte("end_date", start).then(must<RemoteException[]>),
    ]);
    return { org, locations, employees, pattern, days, shifts, shiftPattern, shiftDays, holidays, exceptions };
  }, week);

  const days = monday ? weekDays(monday) : [];
  const today = data ? todayIn(data.org.timezone) : "";
  const people = useMemo(() => (data?.employees ?? []).filter((e) => e.full_name.toLowerCase().includes(q.trim().toLowerCase())), [data, q]);

  if (error) return <GlassCard><ErrorState title="Couldn't load the roster" body={error} onRetry={reload} /></GlassCard>;
  if (!data || !monday) return <LoadingState kind="table" label="Loading roster" />;

  const activeLocs = data.locations.filter((l) => l.active);
  const activeShifts = data.shifts.filter((s) => s.active);
  const shiftById = (id: string | null) => data.shifts.find((s) => s.id === id);
  const allSelected = people.length > 0 && people.every((p) => selected.includes(p.id));

  return (
    <GlassCard className="roster-card">
      <div className="roster-toolbar">
        <div className="row">
          <Button size="sm" onClick={() => setMonday(addDays(monday, -7))} aria-label="Previous week">‹ Prev</Button>
          <Button size="sm" variant="ghost" onClick={() => setMonday(mondayOf(today))}>This week</Button>
          <Button size="sm" onClick={() => setMonday(addDays(monday, 7))} aria-label="Next week">Next ›</Button>
          <strong className="week-label">{fmtDay(days[0]!)} – {fmtDay(days[6]!)}</strong>
          {loading ? <span className="spinner sm" aria-label="Updating" /> : null}
        </div>
        <div className="row">
          {data.employees.length > 1 ? (
            <>
              <label className="sr-only" htmlFor="roster-search">Search people</label>
              <input id="roster-search" className="input sm" type="search" placeholder="Search people…" value={q} onChange={(e) => setQ(e.target.value)} />
            </>
          ) : null}
          {canEdit ? (
            <Button size="sm" variant="primary" disabled={selected.length === 0} onClick={() => setPatternFor(data.employees.filter((e) => selected.includes(e.id)))}>
              Set weekly pattern{selected.length ? ` (${selected.length})` : ""}
            </Button>
          ) : null}
        </div>
      </div>

      {canEdit && activeLocs.length === 0 ? (
        <div className="alert warning" role="note">No office location is set up yet, so nobody can check in at an office. Add one in Settings → Locations &amp; GPS.</div>
      ) : null}
      {canEdit && activeShifts.length === 0 ? (
        <div className="alert info" role="note">No shifts yet. Create them in the Shifts tab to get late, early-leaving and overtime figures.</div>
      ) : null}

      {people.length === 0 ? (
        <EmptyState
          title={q ? `No one matches “${q}”` : "No people to show"}
          body={q ? "Try another name." : canEdit ? "People appear here after their first sign-in. Employee onboarding arrives with the Employees module." : "Your roster appears here once HR sets it."}
        />
      ) : (
        <div className="table-wrap roster-wrap">
          <table className="table roster">
            <caption className="sr-only">Work roster for the week starting {fmtDay(monday)}: work location and shift per person per day.</caption>
            <thead>
              <tr>
                <th scope="col" className="sticky-col">
                  {canEdit ? <input type="checkbox" aria-label="Select everyone shown" checked={allSelected} onChange={() => setSelected(allSelected ? [] : people.map((p) => p.id))} /> : null}
                  <span>Person</span>
                </th>
                {days.map((d) => {
                  const hol = data.holidays.find((h) => h.day === d && !h.location_id);
                  return (
                    <th key={d} scope="col" className={d === today ? "is-today" : ""}>
                      {WEEKDAY_SHORT[new Date(`${d}T12:00:00Z`).getUTCDay()]} <span className="meta">{fmtDay(d)}</span>
                      {hol ? <span className="tiny hol-tag block">{hol.name}</span> : null}
                    </th>
                  );
                })}
              </tr>
            </thead>
            <tbody>
              {people.map((emp) => (
                <tr key={emp.id}>
                  <th scope="row" className="sticky-col">
                    {canEdit ? (
                      <input
                        type="checkbox"
                        aria-label={`Select ${emp.full_name}`}
                        checked={selected.includes(emp.id)}
                        onChange={() => setSelected((s) => (s.includes(emp.id) ? s.filter((x) => x !== emp.id) : [...s, emp.id]))}
                      />
                    ) : null}
                    <span className="person">
                      <span>{emp.full_name}</span>
                      {canEdit ? <button type="button" className="link-btn tiny" onClick={() => setPatternFor([emp])}>Weekly pattern</button> : null}
                    </span>
                  </th>
                  {days.map((d) => {
                    const plan = planFor(emp, d, data.org, data.days, data.pattern, data.holidays, data.exceptions);
                    const sh = shiftFor(emp, d, data.org, data.shiftDays, data.shiftPattern);
                    const shift = plan.work_mode === "off" ? undefined : shiftById(sh.shift_id);
                    const cell = (
                      <span className="cell-stack">
                        <Chip plan={plan} locations={data.locations} />
                        {plan.work_mode !== "off" ? <ShiftLine shift={shift} changed={sh.source === "day"} /> : null}
                      </span>
                    );
                    return (
                      <td key={d} className={d === today ? "is-today" : ""}>
                        {canEdit ? (
                          <button
                            type="button"
                            className="cell-btn"
                            aria-label={`${emp.full_name}, ${fmtDay(d)}: ${MODE_LABEL[plan.work_mode]}${shift ? `, ${shift.name} shift` : ""}. Change`}
                            onClick={() => setDayEdit({ emp, day: d, plan, shiftId: sh.shift_id, shiftChanged: sh.source === "day" })}
                          >
                            {cell}
                          </button>
                        ) : (
                          cell
                        )}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div className="roster-legend meta">
        <span><span className="plan-chip sm mode-office">Office</span> check in inside the office area</span>
        <span><span className="plan-chip sm mode-remote">Remote</span> {data.org.remote_location_required ? "check-in records location, no office area" : "check-in without location"}</span>
        <span><span className="plan-chip sm mode-off">Day off</span> check-in blocked</span>
        <span><span className="shift-line">Shift · times</span> late / early / overtime are measured against it; ↷ = overnight</span>
        <span><span className="plan-chip sm mode-office changed">Dashed</span> set for that date only</span>
      </div>

      {dayEdit ? (
        <DayModal
          {...dayEdit}
          locations={activeLocs}
          shifts={activeShifts}
          onClose={() => setDayEdit(null)}
          onSaved={() => {
            setDayEdit(null);
            reload();
          }}
        />
      ) : null}
      {patternFor ? (
        <PatternModal
          people={patternFor}
          pattern={data.pattern}
          shiftPattern={data.shiftPattern}
          locations={activeLocs}
          shifts={activeShifts}
          org={data.org}
          onClose={() => setPatternFor(null)}
          onSaved={() => {
            setPatternFor(null);
            setSelected([]);
            reload();
          }}
        />
      ) : null}
    </GlassCard>
  );
}

const MODE_OPTIONS = [
  { value: "office", label: "Office" },
  { value: "remote", label: "Remote" },
  { value: "off", label: "Day off" },
];

/** One date: work location and shift are separate sections, each saved only if changed. */
function DayModal({
  emp,
  day,
  plan,
  shiftId,
  shiftChanged,
  locations,
  shifts,
  onClose,
  onSaved,
}: {
  emp: Employee;
  day: string;
  plan: Plan;
  shiftId: string | null;
  shiftChanged: boolean;
  locations: Location[];
  shifts: Shift[];
  onClose: () => void;
  onSaved: () => void;
}) {
  const [mode, setMode] = useState<WorkMode>(plan.work_mode);
  const [loc, setLoc] = useState(plan.location_id ?? "");
  const [note, setNote] = useState("");
  const [shift, setShift] = useState(shiftId ?? "");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const locDirty = mode !== plan.work_mode || (mode === "office" && (loc || null) !== plan.location_id) || note.trim() !== "";
  const shiftDirty = (shift || null) !== shiftId;

  async function save() {
    setBusy(true);
    setErr(null);
    const sb = supabase();
    if (locDirty) {
      const { error } = await sb
        .from("roster_day")
        .upsert({ employee_id: emp.id, day, work_mode: mode, location_id: mode === "office" && loc ? loc : null, note: note.trim() || null }, { onConflict: "employee_id,day" });
      if (error) {
        setBusy(false);
        return setErr(friendlyError(error));
      }
    }
    if (shiftDirty && shift) {
      const { error } = await sb.from("shift_day").upsert({ employee_id: emp.id, day, shift_id: shift }, { onConflict: "employee_id,day" });
      if (error) {
        setBusy(false);
        return setErr(`${locDirty ? "Work location saved, but the shift wasn't: " : ""}${friendlyError(error)}`);
      }
    }
    setBusy(false);
    toast({ tone: "success", title: "Roster updated", body: `${emp.full_name} · ${fmtDay(day)}` });
    onSaved();
  }

  async function reset(table: "roster_day" | "shift_day") {
    setBusy(true);
    const { error } = await supabase().from(table).delete().eq("employee_id", emp.id).eq("day", day);
    setBusy(false);
    if (error) return setErr(friendlyError(error));
    toast({ tone: "info", title: table === "roster_day" ? "Work location back to weekly pattern" : "Shift back to weekly pattern", body: `${emp.full_name} · ${fmtDay(day)}` });
    onSaved();
  }

  return (
    <Modal open wide title={`${emp.full_name} · ${fmtDay(day)}`} subtitle="Applies to this date only. Work location and shift are set separately." onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        {plan.source === "holiday" ? <div className="alert info" role="note">This date is a holiday ({plan.note}). Setting a work location here makes it a working day for this person.</div> : null}
        {plan.source === "exception" ? <div className="alert info" role="note">Remote-work exception: {plan.note}.</div> : null}
        <fieldset className="modal-section">
          <legend>Work location</legend>
          <div className="form-2">
            <FormSelect label="Work from" value={mode} onChange={(e) => setMode(e.target.value as WorkMode)} options={MODE_OPTIONS} />
            {mode === "office" ? (
              <FormSelect
                label="Office"
                value={loc}
                onChange={(e) => setLoc(e.target.value)}
                options={[{ value: "", label: "Any company office" }, ...locations.map((l) => ({ value: l.id, label: l.name }))]}
                helper="Check-in is only accepted inside this office's area."
              />
            ) : null}
          </div>
          <FormTextarea label="Note" rows={2} value={note} onChange={(e) => setNote(e.target.value)} helper="Optional, e.g. client visit or site work." maxLength={200} />
          {plan.source === "day" ? <button type="button" className="link-btn small" onClick={() => reset("roster_day")} disabled={busy}>Use weekly pattern for location</button> : null}
        </fieldset>
        <fieldset className="modal-section" disabled={mode === "off"}>
          <legend>Shift</legend>
          {shifts.length === 0 ? (
            <p className="meta">No shifts exist yet. Create them in the Shifts tab.</p>
          ) : (
            <FormSelect
              label="Shift"
              value={shift}
              onChange={(e) => setShift(e.target.value)}
              options={[...(shiftId ? [] : [{ value: "", label: "No shift" }]), ...shifts.map((s) => ({ value: s.id, label: `${s.name} · ${shiftTimes(s)}${isOvernight(s) ? " (overnight)" : ""}` }))]}
              helper={mode === "off" ? "Not used on a day off." : "Late, early-leaving and overtime are measured against this shift."}
            />
          )}
          {shiftChanged ? <button type="button" className="link-btn small" onClick={() => reset("shift_day")} disabled={busy}>Use weekly pattern for shift</button> : null}
        </fieldset>
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} disabled={!locDirty && !shiftDirty} onClick={save}>Save</Button>
        </div>
      </div>
    </Modal>
  );
}

function PatternModal({
  people,
  pattern,
  shiftPattern,
  locations,
  shifts,
  org,
  onClose,
  onSaved,
}: {
  people: Employee[];
  pattern: PatternRow[];
  shiftPattern: ShiftPatternRow[];
  locations: Location[];
  shifts: Shift[];
  org: Org;
  onClose: () => void;
  onSaved: () => void;
}) {
  const first = people[0]!;
  const start = (wd: number) => {
    const p = pattern.find((r) => r.employee_id === first.id && r.weekday === wd);
    const sp = shiftPattern.find((r) => r.employee_id === first.id && r.weekday === wd);
    return { mode: (p?.work_mode ?? "default") as WorkMode | "default", loc: p?.location_id ?? "", shift: sp?.shift_id ?? "" };
  };
  const [rows, setRows] = useState(() => Object.fromEntries(WEEK_ORDER.map((wd) => [wd, start(wd)])) as Record<number, { mode: WorkMode | "default"; loc: string; shift: string }>);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const defLabel = (wd: number) => (org.weekly_off.includes(wd) ? "Default (day off)" : `Default (${MODE_LABEL[org.default_work_mode]})`);
  const set = (wd: number, k: "mode" | "loc" | "shift", v: string) => setRows((r) => ({ ...r, [wd]: { ...r[wd]!, [k]: v } }));

  async function save() {
    setBusy(true);
    setErr(null);
    const ids = people.map((p) => p.id);
    const loc = WEEK_ORDER.filter((wd) => rows[wd]!.mode !== "default").map((wd) => ({ weekday: wd, work_mode: rows[wd]!.mode, location_id: rows[wd]!.mode === "office" ? rows[wd]!.loc : "" }));
    const r1 = await supabase().rpc("set_roster_pattern", { p_employees: ids, p_rows: loc });
    if (r1.error) {
      setBusy(false);
      return setErr(friendlyError(r1.error));
    }
    const sh = WEEK_ORDER.filter((wd) => rows[wd]!.shift).map((wd) => ({ weekday: wd, shift_id: rows[wd]!.shift }));
    const r2 = await supabase().rpc("set_shift_pattern", { p_employees: ids, p_rows: sh });
    setBusy(false);
    if (r2.error) return setErr(`Work locations saved; shifts weren't: ${friendlyError(r2.error)}`);
    toast({ tone: "success", title: "Weekly pattern saved", body: people.length === 1 ? first.full_name : `${people.length} people` });
    onSaved();
  }

  return (
    <Modal
      open
      wide
      title={people.length === 1 ? `Weekly pattern · ${first.full_name}` : `Weekly pattern · ${people.length} people`}
      subtitle={people.length > 1 ? `Replaces the weekly pattern of everyone selected (starting from ${first.full_name}'s).` : "Repeats every week. Changes for a single date still win."}
      onClose={onClose}
    >
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <div className="pattern-grid">
          <div className="pattern-row pattern-head meta" aria-hidden="true">
            <span />
            <span>Work location</span>
            <span>Office</span>
            <span>Shift</span>
          </div>
          {WEEK_ORDER.map((wd) => (
            <div key={wd} className="pattern-row">
              <strong className="pattern-day">{WEEKDAY_SHORT[wd]}</strong>
              <FormSelect label={`${WEEKDAY_SHORT[wd]} work location`} value={rows[wd]!.mode} onChange={(e) => set(wd, "mode", e.target.value)} options={[{ value: "default", label: defLabel(wd) }, ...MODE_OPTIONS]} />
              {rows[wd]!.mode === "office" ? (
                <FormSelect label={`${WEEKDAY_SHORT[wd]} office`} value={rows[wd]!.loc} onChange={(e) => set(wd, "loc", e.target.value)} options={[{ value: "", label: "Any office" }, ...locations.map((l) => ({ value: l.id, label: l.name }))]} />
              ) : (
                <span className="meta pattern-na">—</span>
              )}
              <FormSelect
                label={`${WEEKDAY_SHORT[wd]} shift`}
                value={rows[wd]!.shift}
                onChange={(e) => set(wd, "shift", e.target.value)}
                options={[{ value: "", label: "Person's default shift" }, ...shifts.map((s) => ({ value: s.id, label: `${s.name} · ${shiftTimes(s)}` }))]}
              />
            </div>
          ))}
        </div>
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} onClick={save}>Save pattern</Button>
        </div>
      </div>
    </Modal>
  );
}
