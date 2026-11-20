"use client";

import { Suspense, useMemo, useState } from "react";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { AddDeviceWizard } from "@/components/biometric/AddDeviceWizard";
import { DeviceDetail } from "@/components/biometric/DeviceDetail";
import { DeviceList } from "@/components/biometric/Devices";
import { MappingScreen } from "@/components/biometric/Mapping";
import { Overview } from "@/components/biometric/Overview";
import { ReviewQueue } from "@/components/biometric/ReviewQueue";
import { DemoBanner, DemoProvider, useDemo } from "@/components/biometric/shared";
import { SyncActivity } from "@/components/biometric/SyncActivity";
import { ModulePage } from "@/components/ModulePage";
import { ErrorState, LoadingState } from "@/components/States";
import { Tabs } from "@/components/Tabs";
import { GlassCard } from "@/components/ui";
import { type Office, type Person, PREVIEW_OFFICES, PREVIEW_PEOPLE, seed } from "@/lib/biometric-mock";
import { useSession } from "@/lib/session";
import { supabase } from "@/lib/supabase";
import { must, useLoad } from "@/lib/use-load";

type Tab = "overview" | "devices" | "mapping" | "sync" | "review";
const TABS: Tab[] = ["overview", "devices", "mapping", "sync", "review"];

export default function BiometricPage() {
  return (
    <ModulePage href="/biometric">
      <Suspense fallback={<LoadingState kind="cards" />}>
        <Loader />
      </Suspense>
    </ModulePage>
  );
}

/** People and offices: the company's real records (read-only) when connected; labelled samples in preview mode. */
function Loader() {
  const { preview, name, company } = useSession();
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
    <DemoProvider initial={initial} people={data.people} offices={data.offices} samplePeople={preview} by={`${name} (demonstration)`} tz={company?.timezone ?? "Asia/Kolkata"}>
      <Biometric samplePeople={preview} />
    </DemoProvider>
  );
}

function Biometric({ samplePeople }: { samplePeople: boolean }) {
  const { state } = useDemo();
  const params = useSearchParams();
  const router = useRouter();
  const path = usePathname();
  const device = params.get("device");
  const tabParam = params.get("tab") as Tab | null;
  const tab: Tab = device ? "devices" : tabParam && TABS.includes(tabParam) ? tabParam : "overview";
  const [adding, setAdding] = useState(false);

  const go = (q: Record<string, string>) => {
    const s = new URLSearchParams(q).toString();
    router.push(s ? `${path}?${s}` : path, { scroll: false });
  };
  const openDevice = (id: string) => go({ device: id });
  const setTab = (t: Tab) => go(t === "overview" ? {} : { tab: t });

  const open = state.reviews.filter((r) => r.status === "open").length;
  const unmapped = new Set(state.reviews.filter((r) => r.status === "open" && r.kind === "unmatched").map((r) => r.code)).size;

  return (
    <div className="stack">
      <DemoBanner samplePeople={samplePeople} />
      <Tabs
        label="Biometric devices"
        value={tab}
        onChange={setTab}
        tabs={[
          { id: "overview", label: "Overview" },
          { id: "devices", label: "Devices", badge: String(state.devices.length) },
          { id: "mapping", label: "Employee mapping", badge: unmapped ? String(unmapped) : undefined },
          { id: "sync", label: "Sync activity" },
          { id: "review", label: "Review queue", badge: open ? String(open) : undefined },
        ]}
      />
      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} className="tab-panel">
        {tab === "overview" ? <Overview openDevice={openDevice} goto={setTab} /> : null}
        {tab === "devices" ? device ? <DeviceDetail id={device} back={() => setTab("devices")} /> : <DeviceList openDevice={openDevice} onAdd={() => setAdding(true)} /> : null}
        {tab === "mapping" ? <MappingScreen /> : null}
        {tab === "sync" ? <SyncActivity openDevice={openDevice} /> : null}
        {tab === "review" ? <ReviewQueue /> : null}
      </div>
      <AddDeviceWizard open={adding} onClose={() => setAdding(false)} onSaved={openDevice} />
    </div>
  );
}
