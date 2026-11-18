"use client";

import { useState } from "react";
import { NavIcon } from "@/components/Icons";
import { LocationsPanel } from "@/components/LocationsPanel";
import { ModulePage } from "@/components/ModulePage";
import { EmptyState } from "@/components/States";
import { Tabs } from "@/components/Tabs";
import { GlassCard } from "@/components/ui";
import { useSession } from "@/lib/session";

type Tab = "locations" | "general" | "access";

export default function SettingsPage() {
  const { preview } = useSession();
  const [tab, setTab] = useState<Tab>("locations");
  return (
    <ModulePage href="/settings">
      <Tabs
        label="Settings"
        value={tab}
        onChange={setTab}
        tabs={[
          { id: "locations", label: "Locations & GPS" },
          { id: "general", label: "General" },
          { id: "access", label: "Access" },
        ]}
      />
      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} className="tab-panel">
        {tab === "locations" ? (
          preview ? (
            <GlassCard>
              <EmptyState icon={<NavIcon name="department" />} title="Office locations need the company database" body="Once connected, HR and Admin add each office with its map point and area size here, and set the location rules check-in uses." />
            </GlassCard>
          ) : (
            <LocationsPanel />
          )
        ) : (
          <GlassCard>
            <EmptyState
              icon={<NavIcon name="gear" />}
              title={tab === "general" ? "General settings are built in Phase 5" : "Access settings are built in Phase 5"}
              body={tab === "general" ? "Organization details, date format and holidays." : "Roles, permissions and user access."}
            />
          </GlassCard>
        )}
      </div>
    </ModulePage>
  );
}
