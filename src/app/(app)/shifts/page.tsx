"use client";

import { useState } from "react";
import { NavIcon } from "@/components/Icons";
import { ModulePage } from "@/components/ModulePage";
import { RosterBoard } from "@/components/RosterBoard";
import { EmptyState } from "@/components/States";
import { Tabs } from "@/components/Tabs";
import { GlassCard } from "@/components/ui";
import { useSession } from "@/lib/session";

type Tab = "roster" | "shifts" | "assignments";

export default function ShiftsPage() {
  const { preview, role } = useSession();
  const [tab, setTab] = useState<Tab>("roster");
  const canEdit = role === "admin" || role === "hr";

  return (
    <ModulePage href="/shifts">
      <Tabs
        label="Shifts and schedules"
        value={tab}
        onChange={setTab}
        tabs={[
          { id: "roster", label: "Work roster" },
          { id: "shifts", label: "Shifts" },
          { id: "assignments", label: "Shift assignments" },
        ]}
      />
      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} className="tab-panel">
        {tab === "roster" ? (
          <>
            <p className="page-sub">
              {canEdit
                ? "Set who works from which office, who works remotely, and who is off. Check-in follows this roster."
                : role === "manager"
                  ? "Where your team works each day. HR sets the roster."
                  : "Where you work each day. HR sets the roster."}
            </p>
            {preview ? (
              <GlassCard>
                <EmptyState
                  icon={<NavIcon name="shift" />}
                  title="The roster needs the company database"
                  body="This is the design preview, so there are no people to roster yet. Once connected, HR sets a weekly office / remote / off pattern for each person and changes single dates, and check-in follows it."
                />
              </GlassCard>
            ) : (
              <RosterBoard />
            )}
          </>
        ) : (
          <GlassCard>
            <EmptyState
              icon={<NavIcon name="shift" />}
              title={tab === "shifts" ? "Shift timings are built in Phase 4" : "Shift assignments are built in Phase 4"}
              body="Start/end times, breaks, grace periods and overnight shifts arrive with Leave & Shifts. The work roster (office / remote / off) already works."
            />
          </GlassCard>
        )}
      </div>
    </ModulePage>
  );
}
