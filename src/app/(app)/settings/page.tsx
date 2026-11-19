"use client";

import Link from "next/link";
import { useState } from "react";
import { GeneralSettings, RoleMatrix, UserAccess } from "@/components/AccessScreens";
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
          preview ? (
            <GlassCard>
              <EmptyState icon={<NavIcon name="gear" />} title="This needs the company database" body="Once connected: company details, branding, date format, the half-day rule and leave year (General); roles and who can sign in (Access)." />
            </GlassCard>
          ) : tab === "general" ? (
            <div className="stack">
              <GeneralSettings />
              <p className="meta">Shifts and weekly offs: <Link href="/shifts">Shifts &amp; Schedules</Link> · Holidays: <Link href="/holidays">Holidays</Link> · Leave types: <Link href="/leave">Leave Management</Link></p>
            </div>
          ) : (
            <div className="stack">
              <UserAccess />
              <RoleMatrix />
            </div>
          )
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
