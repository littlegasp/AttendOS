"use client";

import { useState } from "react";
import { NavIcon } from "@/components/Icons";
import { LeaveBalance, LeaveCalendar, LeaveTypes, MyLeaves, TeamRequests } from "@/components/leave/LeaveScreens";
import { ModulePage } from "@/components/ModulePage";
import { EmptyState } from "@/components/States";
import { Tabs } from "@/components/Tabs";
import { GlassCard } from "@/components/ui";
import { can } from "@/lib/permissions";
import { useSession } from "@/lib/session";

type Tab = "mine" | "team" | "balance" | "calendar" | "types";

export default function LeavePage() {
  const { role, preview } = useSession();
  const [tab, setTab] = useState<Tab>("mine");
  const tabs: { id: Tab; label: string }[] = [
    { id: "mine", label: "My Leaves" },
    ...(can(role, "decideLeave") ? [{ id: "team" as Tab, label: role === "manager" ? "Team Requests" : "Requests" }] : []),
    { id: "balance", label: "Leave Balance" },
    { id: "calendar", label: "Leave Calendar" },
    ...(can(role, "manageLeave") ? [{ id: "types" as Tab, label: "Leave Types" }] : []),
  ];
  const current = tabs.some((t) => t.id === tab) ? tab : "mine";
  return (
    <ModulePage href="/leave">
      <Tabs label="Leave" value={current} onChange={setTab} tabs={tabs} />
      <div role="tabpanel" id={`panel-${current}`} aria-labelledby={`tab-${current}`} className="tab-panel">
        {preview ? (
          <GlassCard>
            <EmptyState icon={<NavIcon name="leave" />} title="Leave needs the company database" body="Once connected: apply for leave, approvals by the manager or HR, balances, the team calendar and leave types." />
          </GlassCard>
        ) : current === "mine" ? <MyLeaves /> : current === "team" ? <TeamRequests /> : current === "balance" ? <LeaveBalance /> : current === "calendar" ? <LeaveCalendar /> : <LeaveTypes />}
      </div>
    </ModulePage>
  );
}
