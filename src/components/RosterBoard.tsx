"use client";

import { useMemo, useState } from "react";
import { MODE_LABEL, type WorkMode } from "@/lib/attendance";
import { mondayOf, planFor, todayIn, weekDays, WEEK_ORDER, WEEKDAY_SHORT, addDays, type DayRow, type Employee, type Location, type Org, type PatternRow, type Plan } from "@/lib/roster";
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
}

const fmtDay = (d: string) => new Date(`${d}T12:00:00Z`).toLocaleDateString("en-IN", { day: "numeric", month: "short", timeZone: "UTC" });

function Chip({ plan, locations }: { plan: Plan; locations: Location[] }) {
  const loc = plan.location_id ? locations.find((l) => l.id === plan.location_id)?.name : null;
  return (
    <span className={`plan-chip sm mode-${plan.work_mode}${plan.source === "day" ? " changed" : ""}`}>
      {MODE_LABEL[plan.work_mode]}
      {plan.work_mode === "office" ? <span className="chip-sub">{loc ?? "Any office"}</span> : null}
    </span>
  );
}

/** HR sets who works from which office on which day, and who works remotely. Others see their permitted rows read-only. */
export function RosterBoard() {
  const { role } = useSession();
  const canEdit = role === "admin" || role === "hr";
  const [monday, setMonday] = useState<string | null>(null);
  const [q, setQ] = useState("");
  const [selected, setSelected] = useState<string[]>([]);
  const [dayEdit, setDayEdit] = useState<{ emp: Employee; day: string; plan: Plan } | null>(null);
  const [patternFor, setPatternFor] = useState<Employee[] | null>(null);

  const week = monday ?? "";
  const { data, error, loading, reload } = useLoad<Data>(async () => {
    const sb = supabase();
    const org = must(await sb.from("organization").select("timezone, max_accuracy_m, remote_location_required, default_work_mode, weekly_off").single<Org>());
    const start = monday ?? mondayOf(todayIn(org.timezone));
    if (!monday) setMonday(start);
    const [locations, employees, pattern, days] = await Promise.all([
      sb.from("locations").select("*").order("name").then(must<Location[]>),
      sb.from("employees").select("id, full_name, emp_code, role, active, home_location_id").eq("active", true).order("full_name").then(must<Employee[]>),
      sb.from("roster_pattern").select("*").then(must<PatternRow[]>),
      sb.from("roster_day").select("*").gte("day", start).lte("day", addDays(start, 6)).then(must<DayRow[]>),
    ]);
    return { org, locations, employees, pattern, days };
  }, week);

  const days = monday ? weekDays(monday) : [];
  const today = data ? todayIn(data.org.timezone) : "";
  const people = useMemo(() => (data?.employees ?? []).filter((e) => e.full_name.toLowerCase().includes(q.trim().toLowerCase())), [data, q]);

  if (error) return <GlassCard><ErrorState title="Couldn't load the roster" body={error} onRetry={reload} /></GlassCard>;
  if (!data || !monday) return <LoadingState kind="table" label="Loading roster" />;

  const activeLocs = data.locations.filter((l) => l.active);
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
        <div className="alert warning" role="note">No office location is set up yet, so nobody can check in at an office. Add one in Settings → Office locations.</div>
      ) : null}

      {people.length === 0 ? (
        <EmptyState
          title={q ? `No one matches “${q}”` : "No people to show"}
          body={q ? "Try another name." : canEdit ? "People appear here after their first sign-in. Employee onboarding arrives with the Employees module." : "Your roster appears here once HR sets it."}
        />
      ) : (
        <div className="table-wrap roster-wrap">
          <table className="table roster">
            <caption className="sr-only">Work roster for the week starting {fmtDay(monday)}. Office, remote or day off per person per day.</caption>
            <thead>
              <tr>
                <th scope="col" className="sticky-col">
                  {canEdit ? (
                    <input type="checkbox" aria-label="Select everyone shown" checked={allSelected} onChange={() => setSelected(allSelected ? [] : people.map((p) => p.id))} />
                  ) : null}
                  <span>Person</span>
                </th>
                {days.map((d) => (
                  <th key={d} scope="col" className={d === today ? "is-today" : ""}>
                    {WEEKDAY_SHORT[new Date(`${d}T12:00:00Z`).getUTCDay()]} <span className="meta">{fmtDay(d)}</span>
                  </th>
                ))}
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
                    const plan = planFor(emp, d, data.org, data.days, data.pattern);
                    return (
                      <td key={d} className={d === today ? "is-today" : ""}>
                        {canEdit ? (
                          <button
                            type="button"
                            className="cell-btn"
                            aria-label={`${emp.full_name}, ${fmtDay(d)}: ${MODE_LABEL[plan.work_mode]}. Change`}
                            onClick={() => setDayEdit({ emp, day: d, plan })}
                          >
                            <Chip plan={plan} locations={data.locations} />
                          </button>
                        ) : (
                          <Chip plan={plan} locations={data.locations} />
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
        <span><span className="plan-chip sm mode-office">Office</span> must check in within the office area</span>
        <span><span className="plan-chip sm mode-remote">Remote</span> {data.org.remote_location_required ? "check-in records location, no office area" : "check-in without location"}</span>
        <span><span className="plan-chip sm mode-off">Day off</span> check-in blocked</span>
        <span><span className="plan-chip sm mode-office changed">Changed</span> set for that date (wins over the weekly pattern)</span>
      </div>

      {dayEdit ? (
        <DayModal
          {...dayEdit}
          locations={activeLocs}
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
          locations={activeLocs}
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

function DayModal({ emp, day, plan, locations, onClose, onSaved }: { emp: Employee; day: string; plan: Plan; locations: Location[]; onClose: () => void; onSaved: () => void }) {
  const [mode, setMode] = useState<WorkMode>(plan.work_mode);
  const [loc, setLoc] = useState(plan.location_id ?? "");
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  async function save() {
    setBusy(true);
    setErr(null);
    const { error } = await supabase()
      .from("roster_day")
      .upsert({ employee_id: emp.id, day, work_mode: mode, location_id: mode === "office" && loc ? loc : null, note: note.trim() || null }, { onConflict: "employee_id,day" });
    setBusy(false);
    if (error) return setErr(friendlyError(error));
    toast({ tone: "success", title: "Roster updated", body: `${emp.full_name}: ${MODE_LABEL[mode]} on ${fmtDay(day)}` });
    onSaved();
  }

  async function reset() {
    setBusy(true);
    const { error } = await supabase().from("roster_day").delete().eq("employee_id", emp.id).eq("day", day);
    setBusy(false);
    if (error) return setErr(friendlyError(error));
    toast({ tone: "info", title: "Back to weekly pattern", body: `${emp.full_name} on ${fmtDay(day)}` });
    onSaved();
  }

  return (
    <Modal open title={`${emp.full_name} · ${fmtDay(day)}`} subtitle="Applies to this date only" onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
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
        <FormTextarea label="Note" rows={2} value={note} onChange={(e) => setNote(e.target.value)} helper="Optional, e.g. client visit or site work." maxLength={200} />
        <div className="dialog-actions">
          {plan.source === "day" ? <Button variant="ghost" onClick={reset} disabled={busy}>Use weekly pattern</Button> : null}
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} onClick={save}>Save</Button>
        </div>
      </div>
    </Modal>
  );
}

function PatternModal({ people, pattern, locations, org, onClose, onSaved }: { people: Employee[]; pattern: PatternRow[]; locations: Location[]; org: Org; onClose: () => void; onSaved: () => void }) {
  const first = people[0]!;
  const start = (wd: number) => {
    const p = pattern.find((r) => r.employee_id === first.id && r.weekday === wd);
    return { mode: (p?.work_mode ?? "default") as WorkMode | "default", loc: p?.location_id ?? "" };
  };
  const [rows, setRows] = useState(() => Object.fromEntries(WEEK_ORDER.map((wd) => [wd, start(wd)])) as Record<number, { mode: WorkMode | "default"; loc: string }>);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const defLabel = (wd: number) => (org.weekly_off.includes(wd) ? "Company default (day off)" : `Company default (${MODE_LABEL[org.default_work_mode]})`);

  async function save() {
    setBusy(true);
    setErr(null);
    const rowsOut = WEEK_ORDER.filter((wd) => rows[wd]!.mode !== "default").map((wd) => ({
      weekday: wd,
      work_mode: rows[wd]!.mode,
      location_id: rows[wd]!.mode === "office" ? rows[wd]!.loc : "",
    }));
    const { error } = await supabase().rpc("set_roster_pattern", { p_employees: people.map((p) => p.id), p_rows: rowsOut });
    if (error) {
      setBusy(false);
      return setErr(friendlyError(error));
    }
    setBusy(false);
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
          {WEEK_ORDER.map((wd) => (
            <div key={wd} className="pattern-row">
              <strong className="pattern-day">{WEEKDAY_SHORT[wd]}</strong>
              <FormSelect
                label={`${WEEKDAY_SHORT[wd]} work from`}
                value={rows[wd]!.mode}
                onChange={(e) => setRows((r) => ({ ...r, [wd]: { ...r[wd]!, mode: e.target.value as WorkMode | "default" } }))}
                options={[{ value: "default", label: defLabel(wd) }, ...MODE_OPTIONS]}
              />
              {rows[wd]!.mode === "office" ? (
                <FormSelect
                  label={`${WEEKDAY_SHORT[wd]} office`}
                  value={rows[wd]!.loc}
                  onChange={(e) => setRows((r) => ({ ...r, [wd]: { ...r[wd]!, loc: e.target.value } }))}
                  options={[{ value: "", label: "Any company office" }, ...locations.map((l) => ({ value: l.id, label: l.name }))]}
                />
              ) : (
                <span />
              )}
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
