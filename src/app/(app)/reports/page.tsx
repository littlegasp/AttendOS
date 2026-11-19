"use client";

import { NavIcon } from "@/components/Icons";
import { ModulePage } from "@/components/ModulePage";
import { Reports } from "@/components/reports/ReportScreens";
import { EmptyState } from "@/components/States";
import { GlassCard } from "@/components/ui";
import { useSession } from "@/lib/session";

export default function ReportsPage() {
  const { preview } = useSession();
  return (
    <ModulePage href="/reports">
      {preview ? (
        <GlassCard>
          <EmptyState icon={<NavIcon name="report" />} title="Reports need the company database" body="Once connected: daily, monthly, employee-wise, department-wise, late arrival, overtime and leave reports with CSV and PDF export." />
        </GlassCard>
      ) : (
        <Reports />
      )}
    </ModulePage>
  );
}
