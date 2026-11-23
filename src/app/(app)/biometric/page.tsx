"use client";

import { Suspense, useMemo, useState } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { AddDeviceWizard } from "@/components/biometric/AddDeviceWizard";
import { DatImport } from "@/components/biometric/DatImport";
import { DeviceDetail } from "@/components/biometric/DeviceDetail";
import { DeviceList } from "@/components/biometric/Devices";
import { MappingScreen } from "@/components/biometric/Mapping";
import { Overview } from "@/components/biometric/Overview";
import { ReviewQueue } from "@/components/biometric/ReviewQueue";
import { BioTabs, DemoBanner, DemoProvider, LiveBanner, LiveProvider, useDemo } from "@/components/biometric/shared";
import { SyncActivity } from "@/components/biometric/SyncActivity";
import { ModulePage } from "@/components/ModulePage";
import { EmptyState, ErrorState, LoadingState } from "@/components/States";
import { GlassCard } from "@/components/ui";
import { emptyState, type Office, type Person, PREVIEW_OFFICES, PREVIEW_PEOPLE, seed } from "@/lib/biometric-mock";
import { loadLive, NotInstalled } from "@/lib/biometric-live";
import { useSession } from "@/lib/session";
import { supabase } from "@/lib/supabase";
import { must, useLoad } from "@/lib/use-load";

type Tab = "overview" | "devices" | "mapping" | "sync" | "review" | "import";
const TABS: Tab[] = ["overview", "devices", "mapping", "sync", "review", "import"];

export default function BiometricPage() {
  return (
    <ModulePage href="/biometric">
      <Suspense fallback={<LoadingState kind="cards" />}>
        <Loader />
      </Suspense>
    </ModulePage>
  );
}

/**
 * Preview (no database): the B2 demonstration with labelled sample people. Connected (B4): the company's real
 * biometric records, read under row level security and changed only through the checked database functions.
 */
function Loader() {
  const { preview } = useSession();
  return preview ? <DemoLoader /> : <LiveLoader />;
}

function LiveLoader() {
  const { name, company, role } = useSession();
  const [now] = useState(() => Date.now());
  const { data, error, loading, reload } = useLoad(async () => {
    const sb = supabase();
    const [people, offices] = await Promise.all([
      sb.rpc("people_directory").then(must<(Person & { role: string })[]>),
      sb.from("locations").select("id, name").eq("active", true).order("name").then(must<Office[]>),
    ]);
    const ppl = people.map(({ id, full_name, emp_code, active }) => ({ id, full_name, emp_code, active }));
    try {
      return { people: ppl, offices, state: await loadLive(sb, ppl, offices) };
    } catch (e) {
      if (e instanceof NotInstalled) return { people: ppl, offices, state: null };
      throw e;
    }
  }, "biometric-live");

  if (error && !data) return <GlassCard><ErrorState title="Couldn't load the biometric records" body={error} onRetry={reload} /></GlassCard>;
  if (!data) return <LoadingState kind="cards" />;
  if (!data.state) {
    return (
      <GlassCard>
        <EmptyState title="Biometric attendance is not set up on this database" body="The biometric tables have not been installed for this company yet. Web check-in, corrections and reports work as usual." />
      </GlassCard>
    );
  }
  return (
    <LiveProvider state={data.state} people={data.people} offices={data.offices} role={role} by={name} tz={company?.timezone ?? "Asia/Kolkata"} now={now} reload={reload}>
      <Biometric loading={loading} error={error} />
    </LiveProvider>
  );
}

/** People and offices are labelled samples in preview mode. */
function DemoLoader() {
  const { preview, name, company, role } = useSession();
  const { data, error, reload } = useLoad(async () => {
    if (preview) return { people: PREVIEW_PEOPLE, offices: PREVIEW_OFFICES };
    const sb = supabase();
    const [people, offices] = await Promise.all([
      sb.rpc("people_directory").then(must<(Person & { role: string })[]>),
      sb.from("locations").select("id, name").eq("active", true).order("name").then(must<Office[]>),
    ]);
    return { people: people.map(({ id, full_name, emp_code, active }) => ({ id, full_name, emp_code, active })), offices };
  }, `biometric-lookups-${preview}`);
  const initial = useMemo(() => (data ? seed(data.people, data.offices) : null), [data]);

  if (error) return <GlassCard><ErrorState title="Couldn't load people and offices" body={error} onRetry={reload} /></GlassCard>;
  if (!data || !initial) return <LoadingState kind="cards" />;
  return (
    <DemoProvider initial={initial} people={data.people} offices={data.offices} samplePeople={preview} role={role} by={`${name} (demonstration)`} tz={company?.timezone ?? "Asia/Kolkata"}>
      <Biometric />
    </DemoProvider>
  );
}

function Biometric({ loading = false, error = null }: { loading?: boolean; error?: string | null }) {
  const { state, apply, people, offices, live, may } = useDemo();
  const params = useSearchParams();
  const router = useRouter();
  const path = usePathname();
  const device = params.get("device");
  const tabParam = params.get("tab") as Tab | null;
  const canImport = may("importBiometricFiles");
  const tab: Tab = device ? "devices" : tabParam && TABS.includes(tabParam) && (tabParam !== "import" || canImport) ? tabParam : "overview";
  const [adding, setAdding] = useState(false);

  const go = (q: Record<string, string>) => {
    const s = new URLSearchParams(q).toString();
    router.push(s ? `${path}?${s}` : path, { scroll: false });
  };
  const openDevice = (id: string) => go({ device: id });
  const setTab = (t: Tab) => go(t === "overview" ? {} : { tab: t });

  const open = state.reviews.filter((r) => r.status === "open").length;
  const unmapped = new Set(state.reviews.filter((r) => r.status === "open" && r.kind === "unmatched").map((r) => `${r.raw.deviceId}|${r.raw.code}`)).size;
  const empty = state.devices.length === 0 && state.agents.length === 0;
  const reset = (next: typeof state) => {
    apply({ type: "reset", state: next });
    go({});
  };

  return (
    <div className="stack">
      {live ? <LiveBanner loading={loading} /> : <DemoBanner empty={empty} onReset={() => reset(seed(people, offices))} onEmpty={() => reset(emptyState())} />}
      {error ? <div className="alert danger" role="alert"><p>Couldn&rsquo;t refresh: {error}</p></div> : null}
      <BioTabs
        label="Biometric devices"
        value={tab}
        onChange={setTab}
        tabs={[
          { id: "overview", label: "Overview" },
          { id: "devices", label: "Devices", badge: String(state.devices.length) },
          { id: "mapping", label: "Employee mapping", badge: unmapped ? String(unmapped) : undefined },
          { id: "sync", label: "Sync activity" },
          { id: "review", label: "Review queue", badge: open ? String(open) : undefined },
          ...(canImport ? [{ id: "import" as Tab, label: "File import" }] : []),
        ]}
      />
      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} className="tab-panel">
        {tab === "overview" ? <Overview openDevice={openDevice} goto={setTab} /> : null}
        {tab === "devices" ? device ? <DeviceDetail id={device} back={() => setTab("devices")} /> : <DeviceList openDevice={openDevice} onAdd={() => setAdding(true)} /> : null}
        {tab === "mapping" ? <MappingScreen /> : null}
        {tab === "sync" ? <SyncActivity openDevice={openDevice} /> : null}
        {tab === "review" ? <ReviewQueue /> : null}
        {tab === "import" ? <DatImport /> : null}
      </div>
      <AddDeviceWizard open={adding} onClose={() => setAdding(false)} onSaved={openDevice} />
    </div>
  );
}
