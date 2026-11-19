"use client";

import { NavIcon } from "@/components/Icons";
import { ModulePage } from "@/components/ModulePage";
import { Analytics } from "@/components/reports/ReportScreens";
import { EmptyState } from "@/components/States";
import { GlassCard } from "@/components/ui";
import { useSession } from "@/lib/session";

export default function AnalyticsPage() {
  const { preview } = useSession();
  return (
    <ModulePage href="/analytics">
      {preview ? (
        <GlassCard>
          <EmptyState icon={<NavIcon name="analytics" />} title="Analytics need the company database" body="Once connected: attendance and working-hours trends, status distribution and department comparison, each with a table view." />
        </GlassCard>
      ) : (
        <Analytics />
      )}
    </ModulePage>
  );
}
