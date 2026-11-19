"use client";

import { useState } from "react";
import { ActivityLog } from "@/components/ActivityLog";
import { NavIcon } from "@/components/Icons";
import { AssignmentsPanel, LocationsPanel, SettingsAccessNote, VerificationHistory } from "@/components/LocationsPanel";
import { ModulePage } from "@/components/ModulePage";
import { EmptyState } from "@/components/States";
import { Tabs } from "@/components/Tabs";
import { GlassCard } from "@/components/ui";
import { can } from "@/lib/permissions";
import { useSession } from "@/lib/session";

type Tab = "locations" | "assignments" | "history" | "activity" | "general" | "access";

export default function SettingsPage() {
  const { preview, role } = useSession();
  const [tab, setTab] = useState<Tab>("locations");
  const tabs: { id: Tab; label: string }[] = [
    { id: "locations", label: "Locations & GPS" },
    { id: "assignments", label: "Assignments & exceptions" },
    ...(can(role, "verificationHistory") ? [{ id: "history" as Tab, label: "Verification history" }] : []),
    ...(can(role, "viewAudit") ? [{ id: "activity" as Tab, label: "Activity log" }] : []),
    { id: "general", label: "General" },
    { id: "access", label: "Access" },
  ];
  return (
    <ModulePage href="/settings">
      <Tabs label="Settings" value={tab} onChange={setTab} tabs={tabs} />
      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} className="tab-panel">
        {tab === "general" || tab === "access" ? (
          <GlassCard>
            <EmptyState
              icon={<NavIcon name="gear" />}
              title={tab === "general" ? "General settings are built in Phase 5" : "Access settings are built in Phase 5"}
              body={tab === "general" ? "Company name, logo and colours, and date format. The time zone is under Locations & GPS → Attendance rules." : "Custom permission sets. Roles are already assigned per person on their Employees profile."}
            />
          </GlassCard>
        ) : preview ? (
          <GlassCard>
            <EmptyState icon={<NavIcon name="department" />} title="This needs the company database" body="Once connected, HR and Admin manage offices on a map, each person's assigned office and shift, remote-work exceptions and the verification history here. Company rules stay Admin-only." />
          </GlassCard>
        ) : (
          <>
            <SettingsAccessNote />
            {tab === "locations" ? <LocationsPanel /> : tab === "assignments" ? <AssignmentsPanel /> : tab === "activity" ? <ActivityLog /> : <VerificationHistory />}
          </>
        )}
      </div>
    </ModulePage>
  );
}
