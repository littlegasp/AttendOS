"use client";

import { useState } from "react";
import { MODE_LABEL, locate, LOCATE_MESSAGES, type LocateError } from "@/lib/attendance";
import { WEEK_ORDER, WEEKDAY_SHORT, type Location, type Org } from "@/lib/roster";
import { useSession } from "@/lib/session";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";
import { must, useLoad } from "@/lib/use-load";
import { Modal } from "./Modal";
import { EmptyState, ErrorState, LoadingState } from "./States";
import { Button, FormInput, FormSelect, SectionCard, StatusBadge } from "./ui";

/** Office locations (geofences) and the attendance rules check-in uses. */
export function LocationsPanel() {
  const { role } = useSession();
  const isAdmin = role === "admin";
  const { data, error, reload } = useLoad(async () => {
    const sb = supabase();
    const [locations, org] = await Promise.all([
      sb.from("locations").select("*").order("name").then(must<Location[]>),
      sb.from("organization").select("timezone, max_accuracy_m, remote_location_required, default_work_mode, weekly_off").single<Org>().then(must<Org>),
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
        actions={<Button variant="primary" size="sm" onClick={() => setEdit("new")}>Add location</Button>}
      >
        {data.locations.length === 0 ? (
          <EmptyState title="No office locations yet" body="Add each office or site with its map point and an area size. Until one exists, office check-ins are refused." action={<Button variant="primary" onClick={() => setEdit("new")}>Add the first location</Button>} />
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr><th scope="col">Name</th><th scope="col">Address</th><th scope="col">Map point</th><th scope="col">Area</th><th scope="col">Status</th><th scope="col"><span className="sr-only">Actions</span></th></tr>
              </thead>
              <tbody>
                {data.locations.map((l) => (
                  <tr key={l.id}>
                    <th scope="row">{l.name}</th>
                    <td className="muted">{l.address || "—"}</td>
                    <td className="mono">{l.lat.toFixed(5)}, {l.lng.toFixed(5)}</td>
                    <td>{l.radius_m} m</td>
                    <td>{l.active ? <StatusBadge status="verified" label="In use" /> : <StatusBadge status="weekly-off" label="Not in use" />}</td>
                    <td><Button size="sm" variant="ghost" onClick={() => setEdit(l)}>Edit</Button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </SectionCard>

      <RulesCard org={data.org} canEdit={isAdmin} onSaved={reload} />

      {edit ? <LocationModal loc={edit === "new" ? null : edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); reload(); }} /> : null}
    </>
  );
}

function LocationModal({ loc, onClose, onSaved }: { loc: Location | null; onClose: () => void; onSaved: () => void }) {
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

  async function useHere() {
    setLocating(true);
    setErr(null);
    try {
      const p = await locate();
      setF((x) => ({ ...x, lat: p.lat.toFixed(6), lng: p.lng.toFixed(6) }));
      toast({ tone: "info", title: "Map point filled from this device", body: `Accuracy about ±${Math.round(p.accuracy)} m. Stand in the middle of the office for the best point.` });
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
    <Modal open title={loc ? `Edit ${loc.name}` : "Add office location"} subtitle="Tip: open Google Maps, long-press the office, and copy the two numbers shown." onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <FormInput label="Name" required value={f.name} onChange={set("name")} error={tried ? errors.name : undefined} placeholder="e.g. Andheri Head Office" maxLength={80} />
        <FormInput label="Address" value={f.address} onChange={set("address")} helper="Optional, for people's reference." />
        <div className="form-2">
          <FormInput label="Latitude" required inputMode="decimal" value={f.lat} onChange={set("lat")} error={tried ? errors.lat : undefined} placeholder="19.110000" />
          <FormInput label="Longitude" required inputMode="decimal" value={f.lng} onChange={set("lng")} error={tried ? errors.lng : undefined} placeholder="72.880000" />
        </div>
        <Button size="sm" onClick={useHere} loading={locating}>Use this device&apos;s location</Button>
        <FormInput label="Area size (metres)" required type="number" min={25} max={2000} value={f.radius} onChange={set("radius")} error={tried ? errors.radius : undefined} helper="How far from the map point a check-in still counts. 100–200 m suits most offices." />
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
  const [f, setF] = useState({ acc: String(org.max_accuracy_m), remoteLoc: org.remote_location_required, mode: org.default_work_mode, off: org.weekly_off });
  const [busy, setBusy] = useState(false);
  const acc = Number(f.acc);
  const accErr = !Number.isInteger(acc) || acc < 10 || acc > 2000 ? "Use a whole number from 10 to 2000." : undefined;
  const dirty = acc !== org.max_accuracy_m || f.remoteLoc !== org.remote_location_required || f.mode !== org.default_work_mode || [...f.off].sort().join() !== [...org.weekly_off].sort().join();

  async function save() {
    if (accErr) return;
    setBusy(true);
    const { error } = await supabase().from("organization").update({ max_accuracy_m: acc, remote_location_required: f.remoteLoc, default_work_mode: f.mode, weekly_off: f.off, updated_at: new Date().toISOString() }).eq("id", 1);
    setBusy(false);
    if (error) return toast({ tone: "danger", title: "Not saved", body: friendlyError(error) });
    toast({ tone: "success", title: "Attendance rules saved" });
    onSaved();
  }

  return (
    <SectionCard title="Attendance rules" subtitle={canEdit ? "Applies to everyone's check-in" : "Only an administrator can change these"}>
      <fieldset className="form-grid rules" disabled={!canEdit}>
        <div className="form-2">
          <FormInput label="Location accuracy needed (metres)" type="number" value={f.acc} onChange={(e) => setF((x) => ({ ...x, acc: e.target.value }))} error={accErr} helper="Check-ins with a less precise location are refused." />
          <FormSelect label="When HR hasn't set a day" value={f.mode} onChange={(e) => setF((x) => ({ ...x, mode: e.target.value as "office" | "remote" }))} options={[{ value: "office", label: `${MODE_LABEL.office} (person's home office or any office)` }, { value: "remote", label: MODE_LABEL.remote }]} />
        </div>
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
        {canEdit ? <div className="row"><Button variant="primary" loading={busy} disabled={!dirty || Boolean(accErr)} onClick={save}>Save rules</Button></div> : null}
      </fieldset>
    </SectionCard>
  );
}
