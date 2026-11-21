"use client";

import { useState } from "react";
import { MODE_LABEL, accuracyLevel, clock, locate, LOCATE_MESSAGES, shortDate, type LocateError } from "@/lib/attendance";
import { can } from "@/lib/permissions";
import { WEEK_ORDER, WEEKDAY_SHORT, todayIn, type Employee, type Location, type Org, type RemoteException, type Shift } from "@/lib/roster";
import { useSession } from "@/lib/session";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";
import { must, useLoad } from "@/lib/use-load";
import { ConfirmDialog } from "./ConfirmDialog";
import { IconAlert, IconLock } from "./Icons";
import { AddressSearch, LocationMap } from "./LocationMap";
import { Modal } from "./Modal";
import { shiftTimes } from "./RosterBoard";
import { EmptyState, ErrorState, LoadingState } from "./States";
import { Button, FormInput, FormSelect, FormTextarea, SectionCard, StatusBadge } from "./ui";

/** Every IANA time zone the browser knows, India first. */
export function timeZoneOptions(current: string) {
  let all: string[] = [];
  try {
    all = (Intl as unknown as { supportedValuesOf: (k: string) => string[] }).supportedValuesOf("timeZone");
  } catch {
    all = ["Asia/Kolkata", "Asia/Dubai", "Asia/Singapore", "Europe/London", "America/New_York"];
  }
  // The browser may list India as Asia/Calcutta; the database uses Asia/Kolkata.
  const list = Array.from(new Set(["Asia/Kolkata", ...all.filter((z) => z !== "Asia/Calcutta"), current]));
  return list.map((z) => ({ value: z, label: z === "Asia/Kolkata" ? "Asia/Kolkata (India, IST)" : z.replace(/_/g, " ") }));
}

const ORG_COLS = "timezone, max_accuracy_m, remote_location_required, default_work_mode, weekly_off, default_shift_id";

/** Who may do what on this screen — one place, from the permission matrix (the database enforces the same). */
export function SettingsAccessNote() {
  const { role } = useSession();
  if (can(role, "editPolicy")) return null;
  return (
    <div className="alert info access-note" role="note">
      <IconLock />
      <p>
        As <strong>HR</strong> you can manage office locations, each person&apos;s assigned office and shift, and remote-work exceptions. Company-wide attendance rules are set by an administrator and are shown read-only.
      </p>
    </div>
  );
}

/* ================================================================ offices + rules */

export function LocationsPanel() {
  const { role, companyId } = useSession();
  const canManage = can(role, "manageLocations");
  const { data, error, reload } = useLoad(async () => {
    const sb = supabase();
    const [locations, org] = await Promise.all([
      sb.from("locations").select("*").order("name").then(must<Location[]>),
      sb.from("companies").select(ORG_COLS).eq("id", companyId!).single<Org>().then(must<Org>),
    ]);
    return { locations, org };
  }, "locations");
  const [edit, setEdit] = useState<Location | "new" | null>(null);

  if (error) return <SectionCard title="Office locations"><ErrorState body={error} onRetry={reload} /></SectionCard>;
  if (!data) return <LoadingState kind="table" label="Loading locations" />;

  return (
    <>
      <SectionCard
        title="Office locations"
        subtitle="People rostered to the office can only check in inside one of these areas"
        actions={canManage ? <Button variant="primary" size="sm" onClick={() => setEdit("new")}>Add location</Button> : null}
      >
        {data.locations.length === 0 ? (
          <EmptyState title="No office locations yet" body="Add each office or site with its map point and an area size. Until one exists, office check-ins are refused." action={canManage ? <Button variant="primary" onClick={() => setEdit("new")}>Add the first location</Button> : undefined} />
        ) : (
          <div className="offices">
            <LocationMap label="Map of office locations and their check-in areas" offices={data.locations} height={300} />
            <div className="table-wrap">
              <table className="table">
                <thead>
                  <tr><th scope="col">Name</th><th scope="col">Address</th><th scope="col">Map point</th><th scope="col">Area</th><th scope="col">Status</th>{canManage ? <th scope="col"><span className="sr-only">Actions</span></th> : null}</tr>
                </thead>
                <tbody>
                  {data.locations.map((l) => (
                    <tr key={l.id}>
                      <th scope="row">{l.name}</th>
                      <td className="muted wrap">{l.address || "—"}</td>
                      <td className="mono">{l.lat.toFixed(5)}, {l.lng.toFixed(5)}</td>
                      <td>{l.radius_m} m</td>
                      <td>{l.active ? <StatusBadge status="verified" label="In use" /> : <StatusBadge status="weekly-off" label="Not in use" />}</td>
                      {canManage ? <td><Button size="sm" variant="ghost" onClick={() => setEdit(l)}>Edit</Button></td> : null}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}
      </SectionCard>

      <RulesCard org={data.org} canEdit={can(role, "editPolicy")} onSaved={reload} />

      {edit ? <LocationModal loc={edit === "new" ? null : edit} others={data.locations.filter((l) => edit === "new" || l.id !== edit.id)} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); reload(); }} /> : null}
    </>
  );
}

function LocationModal({ loc, others, onClose, onSaved }: { loc: Location | null; others: Location[]; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState({
    name: loc?.name ?? "",
    address: loc?.address ?? "",
    lat: loc ? String(loc.lat) : "",
    lng: loc ? String(loc.lng) : "",
    radius: loc ? String(loc.radius_m) : "150",
    active: loc?.active ?? true,
  });
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [locating, setLocating] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF((x) => ({ ...x, [k]: e.target.value }));

  const lat = Number(f.lat);
  const lng = Number(f.lng);
  const radius = Number(f.radius);
  const errors = {
    name: f.name.trim().length < 2 ? "Enter a name of at least 2 characters." : undefined,
    lat: f.lat === "" || !Number.isFinite(lat) || lat < -90 || lat > 90 ? "Enter a latitude between -90 and 90." : undefined,
    lng: f.lng === "" || !Number.isFinite(lng) || lng < -180 || lng > 180 ? "Enter a longitude between -180 and 180." : undefined,
    radius: !Number.isInteger(radius) || radius < 25 || radius > 2000 ? "Use a whole number from 25 to 2000 metres." : undefined,
  };
  const valid = !Object.values(errors).some(Boolean);
  const point = !errors.lat && !errors.lng ? { lat, lng } : null;
  const radiusOk = !errors.radius ? radius : 150;

  async function useHere() {
    setLocating(true);
    setErr(null);
    try {
      const p = await locate();
      setF((x) => ({ ...x, lat: p.lat.toFixed(6), lng: p.lng.toFixed(6) }));
      toast({ tone: p.accuracy > 50 ? "warning" : "info", title: "Map point set from this device", body: `Accuracy about ±${Math.round(p.accuracy)} m.${p.accuracy > 50 ? " That's rough — drag the pin to the exact spot." : ""}` });
    } catch (e) {
      setErr(LOCATE_MESSAGES[e as LocateError]?.body ?? "Couldn't read this device's location.");
    }
    setLocating(false);
  }

  async function save() {
    setTried(true);
    if (!valid) return;
    setBusy(true);
    setErr(null);
    const row = { name: f.name.trim(), address: f.address.trim() || null, lat, lng, radius_m: radius, active: f.active };
    const sb = supabase();
    const { error } = loc ? await sb.from("locations").update(row).eq("id", loc.id) : await sb.from("locations").insert(row);
    setBusy(false);
    if (error) return setErr(friendlyError(error));
    toast({ tone: "success", title: loc ? "Location updated" : "Location added", body: row.name });
    onSaved();
  }

  return (
    <Modal open wide title={loc ? `Edit ${loc.name}` : "Add office location"} subtitle="Search the address, click the map or drag the pin. The circle is where check-in is accepted." onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <FormInput label="Name" required value={f.name} onChange={set("name")} error={tried ? errors.name : undefined} placeholder="e.g. Andheri Head Office" maxLength={80} />
        <AddressSearch onPick={(p) => setF((x) => ({ ...x, lat: String(p.lat), lng: String(p.lng), address: x.address || p.label.slice(0, 200) }))} />
        <LocationMap
          label="Office location map. Click to place the office point."
          offices={others}
          point={point}
          radius={radiusOk}
          onPick={(la, ln) => setF((x) => ({ ...x, lat: String(la), lng: String(ln) }))}
          height={280}
        />
        <div className="form-2">
          <FormInput label="Latitude" required inputMode="decimal" value={f.lat} onChange={set("lat")} error={tried ? errors.lat : undefined} placeholder="19.110000" />
          <FormInput label="Longitude" required inputMode="decimal" value={f.lng} onChange={set("lng")} error={tried ? errors.lng : undefined} placeholder="72.880000" />
        </div>
        <Button size="sm" onClick={useHere} loading={locating}>Use this device&apos;s location</Button>
        <div className="field radius-field">
          <label htmlFor="radius-range">Check-in area: <strong>{f.radius || "—"} m</strong> radius</label>
          <input id="radius-range" type="range" min={25} max={1000} step={5} value={Math.min(Number(f.radius) || 150, 1000)} onChange={set("radius")} aria-describedby="radius-msg" />
          <div className="radius-row">
            <FormInput label="Exact radius (metres)" type="number" min={25} max={2000} value={f.radius} onChange={set("radius")} error={tried ? errors.radius : undefined} />
          </div>
          <p id="radius-msg" className="field-msg">100–200 m suits most offices. Larger areas also accept check-ins from nearby buildings.</p>
        </div>
        <FormInput label="Address" value={f.address} onChange={set("address")} helper="Shown to people for reference." />
        <FormSelect label="Status" value={f.active ? "yes" : "no"} onChange={(e) => setF((x) => ({ ...x, active: e.target.value === "yes" }))} options={[{ value: "yes", label: "In use" }, { value: "no", label: "Not in use (keeps history)" }]} />
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} onClick={save}>{loc ? "Save changes" : "Add location"}</Button>
        </div>
      </div>
    </Modal>
  );
}

function RulesCard({ org, canEdit, onSaved }: { org: Org; canEdit: boolean; onSaved: () => void }) {
  const { companyId, refreshCompany } = useSession();
  const [f, setF] = useState({ acc: String(org.max_accuracy_m), remoteLoc: org.remote_location_required, mode: org.default_work_mode, off: org.weekly_off, tz: org.timezone });
  const [busy, setBusy] = useState(false);
  const acc = Number(f.acc);
  const accErr = !Number.isInteger(acc) || acc < 10 || acc > 2000 ? "Use a whole number from 10 to 2000." : undefined;
  const dirty =
    acc !== org.max_accuracy_m || f.remoteLoc !== org.remote_location_required || f.mode !== org.default_work_mode || f.tz !== org.timezone ||
    [...f.off].sort().join() !== [...org.weekly_off].sort().join();

  async function save() {
    if (accErr) return;
    setBusy(true);
    const { error } = await supabase()
      .from("companies")
      .update({ max_accuracy_m: acc, remote_location_required: f.remoteLoc, default_work_mode: f.mode, weekly_off: f.off, timezone: f.tz })
      .eq("id", companyId!);
    setBusy(false);
    if (error) return toast({ tone: "danger", title: "Not saved", body: /time zone|timezone|check/i.test(error.message) ? "That time zone isn't recognised." : friendlyError(error) });
    toast({ tone: "success", title: "Attendance rules saved", body: f.tz !== org.timezone ? `Time zone is now ${f.tz}. Today's date and every time on screen follow it.` : undefined });
    refreshCompany();
    onSaved();
  }

  if (!canEdit) {
    // HR: a plain read-only summary, so nothing looks editable that isn't.
    return (
      <SectionCard title="Attendance rules" subtitle="Set by an administrator" actions={<StatusBadge status="weekly-off" label="View only" />}>
        <dl className="rules-view">
          <dt>Location accuracy needed</dt><dd>{org.max_accuracy_m} m or better</dd>
          <dt>When HR hasn&apos;t set a day</dt><dd>{MODE_LABEL[org.default_work_mode]}</dd>
          <dt>Remote days</dt><dd>{org.remote_location_required ? "Location recorded at check-in" : "Check in without location"}</dd>
          <dt>Weekly days off</dt><dd>{WEEK_ORDER.filter((d) => org.weekly_off.includes(d)).map((d) => WEEKDAY_SHORT[d]).join(", ") || "None"}</dd>
          <dt>Time zone</dt><dd>{org.timezone}</dd>
        </dl>
      </SectionCard>
    );
  }

  return (
    <SectionCard title="Attendance rules" subtitle="Applies to everyone's check-in · administrators only">
      <div className="form-grid">
        <div className="form-2">
          <FormInput label="Location accuracy needed (metres)" type="number" value={f.acc} onChange={(e) => setF((x) => ({ ...x, acc: e.target.value }))} error={accErr} helper="Check-ins with a less precise location are refused." />
          <FormSelect label="When HR hasn't set a day" value={f.mode} onChange={(e) => setF((x) => ({ ...x, mode: e.target.value as "office" | "remote" }))} options={[{ value: "office", label: `${MODE_LABEL.office} (assigned office or any office)` }, { value: "remote", label: MODE_LABEL.remote }]} />
        </div>
        {!accErr && acc > 150 ? (
          <div className="alert warning" role="note">
            <IconAlert />
            <p>{acc} m is a loose limit: a reading that rough could place someone in a neighbouring building. 50–100 m is typical for phones outdoors or near windows.</p>
          </div>
        ) : null}
        {!accErr && acc < 30 ? (
          <div className="alert warning" role="note">
            <IconAlert />
            <p>{acc} m is very strict: phones indoors often report 30–80 m, so many check-ins may be refused.</p>
          </div>
        ) : null}
        <FormSelect
          label="Company time zone"
          value={f.tz}
          onChange={(e) => setF((x) => ({ ...x, tz: e.target.value }))}
          options={timeZoneOptions(f.tz)}
          helper="Decides what “today” is, shift times, late arrivals and every time shown to your people."
        />
        <FormSelect
          label="Remote days"
          value={f.remoteLoc ? "yes" : "no"}
          onChange={(e) => setF((x) => ({ ...x, remoteLoc: e.target.value === "yes" }))}
          options={[{ value: "no", label: "Check in without location" }, { value: "yes", label: "Record location at check-in (no office area)" }]}
        />
        <div className="field">
          <span className="field-label" id="off-label">Weekly days off (company default)</span>
          <div className="day-toggles" role="group" aria-labelledby="off-label">
            {WEEK_ORDER.map((wd) => {
              const on = f.off.includes(wd);
              return (
                <button key={wd} type="button" aria-pressed={on} className={`day-toggle${on ? " on" : ""}`} onClick={() => setF((x) => ({ ...x, off: on ? x.off.filter((d) => d !== wd) : [...x.off, wd] }))}>
                  {WEEKDAY_SHORT[wd]}
                </button>
              );
            })}
          </div>
          <p className="field-msg">Used for anyone without a weekly pattern. Time zone: {org.timezone}.</p>
        </div>
        <div className="row"><Button variant="primary" loading={busy} disabled={!dirty || Boolean(accErr)} onClick={save}>Save rules</Button></div>
      </div>
    </SectionCard>
  );
}

/* ================================================================ assignments + exceptions */

export function AssignmentsPanel() {
  const { role, companyId } = useSession();
  const canManage = can(role, "manageLocations");
  const { data, error, reload } = useLoad(async () => {
    const sb = supabase();
    const [employees, locations, shifts, exceptions, org] = await Promise.all([
      sb.from("employees").select("id, full_name, emp_code, role, active, home_location_id, default_shift_id").eq("active", true).order("full_name").then(must<Employee[]>),
      sb.from("locations").select("*").eq("active", true).order("name").then(must<Location[]>),
      sb.from("shifts").select("*").eq("active", true).order("start_time").then(must<Shift[]>),
      sb.from("remote_exceptions").select("*").order("start_date", { ascending: false }).then(must<RemoteException[]>),
      sb.from("companies").select("timezone").eq("id", companyId!).single<{ timezone: string }>().then(must<{ timezone: string }>),
    ]);
    return { employees, locations, shifts, exceptions, today: todayIn(org.timezone) };
  }, "assignments");
  const [saving, setSaving] = useState<string | null>(null);
  const [addEx, setAddEx] = useState<Employee | null | "pick">(null);
  const [delEx, setDelEx] = useState<RemoteException | null>(null);
  const [busy, setBusy] = useState(false);

  if (error) return <SectionCard title="Assigned office & shift"><ErrorState body={error} onRetry={reload} /></SectionCard>;
  if (!data) return <LoadingState kind="table" />;

  async function update(emp: Employee, patch: Partial<Employee>) {
    setSaving(emp.id);
    const { error: e } = await supabase().from("employees").update(patch).eq("id", emp.id);
    setSaving(null);
    if (e) return toast({ tone: "danger", title: "Not saved", body: friendlyError(e) });
    toast({ tone: "success", title: "Saved", body: emp.full_name });
    reload();
  }

  async function removeEx() {
    if (!delEx) return;
    setBusy(true);
    const { error: e } = await supabase().from("remote_exceptions").delete().eq("id", delEx.id);
    setBusy(false);
    setDelEx(null);
    if (e) return toast({ tone: "danger", title: "Not removed", body: friendlyError(e) });
    toast({ tone: "info", title: "Exception removed" });
    reload();
  }

  const name = (id: string) => data.employees.find((e) => e.id === id)?.full_name ?? "Former employee";
  const current = data.exceptions.filter((x) => x.end_date >= data.today);

  return (
    <>
      <SectionCard title="Assigned office & default shift" subtitle="Used on days the roster doesn't say otherwise">
        {data.employees.length === 0 ? (
          <EmptyState compact title="No people yet" body="People appear here after their first sign-in." />
        ) : (
          <div className="table-wrap">
            <table className="table assign-table">
              <thead>
                <tr><th scope="col">Person</th><th scope="col">Assigned office</th><th scope="col">Default shift</th><th scope="col">Remote exception</th></tr>
              </thead>
              <tbody>
                {data.employees.map((e) => {
                  const ex = current.find((x) => x.employee_id === e.id);
                  return (
                    <tr key={e.id}>
                      <th scope="row">{e.full_name}<span className="tiny muted block">{e.role}</span></th>
                      <td>
                        <label className="sr-only" htmlFor={`off-${e.id}`}>Assigned office for {e.full_name}</label>
                        <select id={`off-${e.id}`} className="input sm wide" value={e.home_location_id ?? ""} disabled={!canManage || saving === e.id} onChange={(ev) => update(e, { home_location_id: ev.target.value || null })}>
                          <option value="">Any office</option>
                          {data.locations.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
                        </select>
                      </td>
                      <td>
                        <label className="sr-only" htmlFor={`sh-${e.id}`}>Default shift for {e.full_name}</label>
                        <select id={`sh-${e.id}`} className="input sm wide" value={e.default_shift_id ?? ""} disabled={!canManage || saving === e.id} onChange={(ev) => update(e, { default_shift_id: ev.target.value || null })}>
                          <option value="">Company default</option>
                          {data.shifts.map((s) => <option key={s.id} value={s.id}>{s.name} · {shiftTimes(s)}</option>)}
                        </select>
                      </td>
                      <td>
                        {ex ? (
                          <span className="tiny">{ex.start_date <= data.today ? "Until" : "From"} {shortDate(ex.start_date <= data.today ? ex.end_date : ex.start_date)}</span>
                        ) : canManage ? (
                          <Button size="sm" variant="ghost" onClick={() => setAddEx(e)}>Add</Button>
                        ) : (
                          <span className="muted">—</span>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </SectionCard>

      <SectionCard
        title="Remote-work exceptions"
        subtitle="For a date range, office days become remote days (days off stay off). Date changes in the roster still win."
        actions={canManage ? <Button size="sm" variant="primary" onClick={() => setAddEx("pick")}>Add exception</Button> : null}
      >
        {current.length === 0 ? (
          <EmptyState compact title="No current or upcoming exceptions" body="Use these for temporary arrangements such as recovery from illness, travel or a project away from the office." />
        ) : (
          <ul className="corr-list">
            {current.map((x) => (
              <li key={x.id} className="corr-item">
                <div className="corr-main">
                  <strong>{name(x.employee_id)}</strong>
                  <span className="meta block">{shortDate(x.start_date)} – {shortDate(x.end_date)} · “{x.reason}”</span>
                </div>
                <div className="corr-side">
                  {x.start_date <= data.today ? <StatusBadge status="verified" label="Active" /> : <StatusBadge status="pending" label="Upcoming" />}
                  {canManage ? <Button size="sm" variant="ghost" onClick={() => setDelEx(x)}>Remove</Button> : null}
                </div>
              </li>
            ))}
          </ul>
        )}
      </SectionCard>

      {addEx ? <ExceptionModal emp={addEx === "pick" ? null : addEx} people={data.employees} today={data.today} onClose={() => setAddEx(null)} onSaved={() => { setAddEx(null); reload(); }} /> : null}
      <ConfirmDialog open={Boolean(delEx)} danger title="Remove this exception?" consequence={<p>{delEx ? name(delEx.employee_id) : ""} goes back to their normal roster for these dates. The change is logged.</p>} confirmLabel="Remove" busy={busy} onCancel={() => setDelEx(null)} onConfirm={removeEx} />
    </>
  );
}

function ExceptionModal({ emp, people, today, onClose, onSaved }: { emp: Employee | null; people: Employee[]; today: string; onClose: () => void; onSaved: () => void }) {
  const [who, setWho] = useState(emp?.id ?? "");
  const [from, setFrom] = useState(today);
  const [to, setTo] = useState(today);
  const [reason, setReason] = useState("");
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const errors = {
    who: !who ? "Choose a person." : undefined,
    to: to < from ? "End date must be on or after the start date." : undefined,
    reason: reason.trim().length < 3 ? "Give a short reason." : undefined,
  };
  async function save() {
    setTried(true);
    if (Object.values(errors).some(Boolean)) return;
    setBusy(true);
    const { error } = await supabase().from("remote_exceptions").insert({ employee_id: who, start_date: from, end_date: to, reason: reason.trim() });
    setBusy(false);
    if (error) return setErr(friendlyError(error));
    toast({ tone: "success", title: "Remote-work exception added", body: `${people.find((p) => p.id === who)?.full_name} · ${shortDate(from)} – ${shortDate(to)}` });
    onSaved();
  }
  return (
    <Modal open title="Add remote-work exception" subtitle="Office days in this range become remote days for this person." onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <FormSelect label="Person" value={who} onChange={(e) => setWho(e.target.value)} placeholder="Choose a person" options={people.map((p) => ({ value: p.id, label: p.full_name }))} error={tried ? errors.who : undefined} />
        <div className="form-2">
          <FormInput label="From" type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
          <FormInput label="To" type="date" value={to} onChange={(e) => setTo(e.target.value)} error={tried ? errors.to : undefined} />
        </div>
        <FormTextarea label="Reason" required rows={2} value={reason} onChange={(e) => setReason(e.target.value)} error={tried ? errors.reason : undefined} helper="Kept with the record; avoid medical details." maxLength={200} />
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} onClick={save}>Add exception</Button>
        </div>
      </div>
    </Modal>
  );
}

/* ================================================================ verification history */

interface LogRow {
  at: string;
  employee: string;
  kind: string;
  outcome: "verified" | "not_required" | "corrected" | "refused" | "biometric" | "imported";
  work_mode: string | null;
  location: string | null;
  distance_m: number | null;
  accuracy_m: number | null;
  reason: string | null;
}

const REASON: Record<string, string> = {
  location_required: "No location shared",
  accuracy_low: "Accuracy too low",
  outside_area: "Outside the area",
  day_off: "Not a working day",
};

export function VerificationHistory() {
  const { companyId } = useSession();
  const { data, error, reload, loading } = useLoad(async () => {
    const sb = supabase();
    const [rows, org] = await Promise.all([
      sb.rpc("verification_log", { p_limit: 150 }).then(must<LogRow[]>),
      sb.from("companies").select("timezone, max_accuracy_m").eq("id", companyId!).single<{ timezone: string; max_accuracy_m: number }>().then(must<{ timezone: string; max_accuracy_m: number }>),
    ]);
    return { rows, org };
  }, "vlog");
  const [only, setOnly] = useState<"all" | "refused">("all");

  if (error) return <SectionCard title="Location verification history"><ErrorState body={error} onRetry={reload} /></SectionCard>;
  if (!data) return <LoadingState kind="table" />;
  const rows = only === "refused" ? data.rows.filter((r) => r.outcome === "refused") : data.rows;
  const tz = data.org.timezone;

  return (
    <SectionCard
      title="Location verification history"
      subtitle="Latest 150 check-ins, check-outs and refused attempts. Exact coordinates are not shown here."
      actions={
        <>
          <div className="seg small-seg" role="radiogroup" aria-label="Show">
            <button type="button" role="radio" aria-checked={only === "all"} className={`seg-btn${only === "all" ? " on" : ""}`} onClick={() => setOnly("all")}>All</button>
            <button type="button" role="radio" aria-checked={only === "refused"} className={`seg-btn${only === "refused" ? " on" : ""}`} onClick={() => setOnly("refused")}>Refused</button>
          </div>
          <Button size="sm" variant="ghost" onClick={reload} loading={loading}>Refresh</Button>
        </>
      }
    >
      {rows.length === 0 ? (
        <EmptyState compact title={only === "refused" ? "No refused attempts" : "No check-ins yet"} />
      ) : (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr><th scope="col">When</th><th scope="col">Person</th><th scope="col">Action</th><th scope="col">Result</th><th scope="col">Place</th><th scope="col">Distance</th><th scope="col">Accuracy</th></tr>
            </thead>
            <tbody>
              {rows.map((r, i) => {
                const lvl = r.accuracy_m !== null ? accuracyLevel(r.accuracy_m, data.org.max_accuracy_m) : null;
                return (
                  <tr key={`${r.at}-${i}`}>
                    <td>{shortDate(new Intl.DateTimeFormat("en-CA", { timeZone: tz }).format(new Date(r.at)))} · {clock(r.at, tz)}</td>
                    <th scope="row">{r.employee}</th>
                    <td>{r.kind === "in" ? "Check-in" : "Check-out"}</td>
                    <td>
                      {r.outcome === "verified" ? <StatusBadge status="verified" /> : r.outcome === "refused" ? <StatusBadge status="failed" label={REASON[r.reason ?? ""] ?? "Refused"} /> : r.outcome === "corrected" ? <StatusBadge status="pending" label="Correction" /> : r.outcome === "biometric" ? <span className="badge src-badge src-biometric tone-info" data-source="biometric" title="Recorded by a biometric device for the mapped employee code. Not GPS-verified."><span className="badge-dot" aria-hidden="true" />Biometric · not GPS-verified</span> : r.outcome === "imported" ? <span className="badge src-badge src-import tone-info" data-source="import" title="Taken from an imported device file. Not GPS-verified."><span className="badge-dot" aria-hidden="true" />Imported · not GPS-verified</span> : <StatusBadge status="weekly-off" label="No location needed" />}
                    </td>
                    <td>{r.work_mode === "remote" ? "Remote" : r.location ?? "—"}</td>
                    <td>{r.distance_m !== null ? `${r.distance_m} m` : "—"}</td>
                    <td className={lvl === "near" || lvl === "over" ? "warn" : ""}>
                      {r.accuracy_m !== null ? `±${r.accuracy_m} m` : "—"}
                      {lvl === "near" ? <span className="tiny block">close to limit</span> : lvl === "over" ? <span className="tiny block">over limit</span> : null}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </SectionCard>
  );
}
