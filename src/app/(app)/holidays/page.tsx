"use client";

import { useState } from "react";
import { ConfirmDialog } from "@/components/ConfirmDialog";
import { NavIcon } from "@/components/Icons";
import { Modal } from "@/components/Modal";
import { ModulePage } from "@/components/ModulePage";
import { EmptyState, ErrorState, LoadingState } from "@/components/States";
import { Button, FormInput, FormSelect, GlassCard, SectionCard } from "@/components/ui";
import { shortDate } from "@/lib/attendance";
import { can } from "@/lib/permissions";
import { todayIn, type Holiday, type Location } from "@/lib/roster";
import { useSession } from "@/lib/session";
import { friendlyError, supabase } from "@/lib/supabase";
import { toast } from "@/lib/toast";
import { must, useLoad } from "@/lib/use-load";

export default function HolidaysPage() {
  const { preview } = useSession();
  return (
    <ModulePage href="/holidays">
      {preview ? (
        <GlassCard>
          <EmptyState icon={<NavIcon name="holiday" />} title="Holidays need the company database" body="Once connected, HR adds company-wide or office-specific holidays here. Check-in is blocked on them and they show on everyone's dashboard." />
        </GlassCard>
      ) : (
        <HolidayList />
      )}
    </ModulePage>
  );
}

function HolidayList() {
  const { role } = useSession();
  const canEdit = can(role, "manageShifts");
  const { data, error, reload } = useLoad(async () => {
    const sb = supabase();
    const [hol, locations, org] = await Promise.all([
      sb.from("holidays").select("*").order("day").then(must<Holiday[]>),
      sb.from("locations").select("id, name").order("name").then(must<Pick<Location, "id" | "name">[]>),
      sb.from("organization").select("timezone").single<{ timezone: string }>().then(must<{ timezone: string }>),
    ]);
    return { hol, locations, today: todayIn(org.timezone) };
  }, "holidays");
  const [adding, setAdding] = useState(false);
  const [del, setDel] = useState<Holiday | null>(null);
  const [busy, setBusy] = useState(false);

  if (error) return <GlassCard><ErrorState body={error} onRetry={reload} /></GlassCard>;
  if (!data) return <LoadingState kind="table" />;
  const upcoming = data.hol.filter((h) => h.day >= data.today);
  const past = data.hol.filter((h) => h.day < data.today).reverse().slice(0, 10);
  const locName = (id: string | null) => (id ? data.locations.find((l) => l.id === id)?.name ?? "One office" : "All offices");

  async function remove() {
    if (!del) return;
    setBusy(true);
    const { error: e } = await supabase().from("holidays").delete().eq("id", del.id);
    setBusy(false);
    setDel(null);
    if (e) return toast({ tone: "danger", title: "Not removed", body: friendlyError(e) });
    toast({ tone: "info", title: "Holiday removed", body: del.name });
    reload();
  }

  const list = (rows: Holiday[], editable: boolean) => (
    <ul className="hol-list wide">
      {rows.map((h) => (
        <li key={h.id}>
          <span className="hol-date">
            <strong>{new Date(`${h.day}T12:00:00Z`).getUTCDate()}</strong>
            <span>{new Date(`${h.day}T12:00:00Z`).toLocaleDateString("en-IN", { month: "short", timeZone: "UTC" })}</span>
          </span>
          <span className="hol-main">
            <strong>{h.name}</strong>
            <span className="meta block">{shortDate(h.day)} · {locName(h.location_id)}</span>
          </span>
          {editable && canEdit ? <Button size="sm" variant="ghost" onClick={() => setDel(h)}>Remove</Button> : null}
        </li>
      ))}
    </ul>
  );

  return (
    <>
      <SectionCard title="Upcoming holidays" subtitle="Check-in is blocked on these days unless HR rosters someone to work" actions={canEdit ? <Button variant="primary" size="sm" onClick={() => setAdding(true)}>Add holiday</Button> : null}>
        {upcoming.length ? list(upcoming, true) : <EmptyState compact title="No upcoming holidays" body={canEdit ? "Add the year's holidays so they show on dashboards and block check-in." : "HR hasn't added any yet."} />}
      </SectionCard>
      {past.length ? <SectionCard title="Recent holidays">{list(past, false)}</SectionCard> : null}
      <p className="meta">Regional calendars and leave arrive with Leave &amp; Shifts (Phase 4).</p>
      {adding ? <AddHoliday locations={data.locations} onClose={() => setAdding(false)} onSaved={() => { setAdding(false); reload(); }} /> : null}
      <ConfirmDialog open={Boolean(del)} danger title="Remove this holiday?" consequence={<p>{del?.name} on {del ? shortDate(del.day) : ""} becomes a normal day; rostered people will be expected to check in.</p>} confirmLabel="Remove" busy={busy} onCancel={() => setDel(null)} onConfirm={remove} />
    </>
  );
}

function AddHoliday({ locations, onClose, onSaved }: { locations: Pick<Location, "id" | "name">[]; onClose: () => void; onSaved: () => void }) {
  const [day, setDay] = useState("");
  const [name, setName] = useState("");
  const [loc, setLoc] = useState("");
  const [tried, setTried] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function save() {
    setTried(true);
    if (!day || name.trim().length < 2) return;
    setBusy(true);
    const { error } = await supabase().from("holidays").insert({ day, name: name.trim(), location_id: loc || null });
    setBusy(false);
    if (error) return setErr(/duplicate|unique/i.test(error.message) ? "There is already a holiday on that date for that office." : friendlyError(error));
    toast({ tone: "success", title: "Holiday added", body: `${name.trim()} · ${shortDate(day)}` });
    onSaved();
  }
  return (
    <Modal open title="Add holiday" onClose={onClose}>
      <div className="form-grid">
        {err ? <div className="alert danger" role="alert">{err}</div> : null}
        <FormInput label="Date" type="date" required value={day} onChange={(e) => setDay(e.target.value)} error={tried && !day ? "Choose a date." : undefined} />
        <FormInput label="Name" required value={name} onChange={(e) => setName(e.target.value)} error={tried && name.trim().length < 2 ? "Enter a name." : undefined} placeholder="e.g. Diwali" maxLength={80} />
        <FormSelect label="Applies to" value={loc} onChange={(e) => setLoc(e.target.value)} options={[{ value: "", label: "All offices" }, ...locations.map((l) => ({ value: l.id, label: `${l.name} only` }))]} helper="Office-specific holidays apply to people whose assigned office it is." />
        <div className="dialog-actions">
          <Button variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button variant="primary" loading={busy} onClick={save}>Add holiday</Button>
        </div>
      </div>
    </Modal>
  );
}
