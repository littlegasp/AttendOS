"use client";

import { useState } from "react";
import { NavIcon } from "@/components/Icons";
import { ModulePage } from "@/components/ModulePage";
import { RosterBoard } from "@/components/RosterBoard";
import { ShiftsPanel } from "@/components/ShiftsPanel";
import { EmptyState } from "@/components/States";
import { Tabs } from "@/components/Tabs";
import { GlassCard } from "@/components/ui";
import { useSession } from "@/lib/session";

type Tab = "roster" | "shifts";

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
        ]}
      />
      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} className="tab-panel">
        {tab === "roster" ? (
          <>
            <p className="page-sub">
              {canEdit
                ? "Set where each person works (office, remote or day off) and which shift they work. Click a day to change one date, or set a weekly pattern."
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
        ) : preview ? (
          <GlassCard>
            <EmptyState icon={<NavIcon name="shift" />} title="Shifts need the company database" body="Once connected, HR creates shifts with start and end times, break and grace period (overnight shifts included) and assigns them in the roster." />
          </GlassCard>
        ) : (
          <ShiftsPanel />
        )}
      </div>
    </ModulePage>
  );
}
