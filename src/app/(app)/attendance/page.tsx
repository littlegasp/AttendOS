"use client";

import { NavIcon } from "@/components/Icons";
import { ModulePage } from "@/components/ModulePage";
import { Register } from "@/components/register/Register";
import { EmptyState } from "@/components/States";
import { GlassCard } from "@/components/ui";
import { useSession } from "@/lib/session";

export default function AttendancePage() {
  const { preview } = useSession();
  return (
    <ModulePage href="/attendance">
      {preview ? (
        <GlassCard>
          <EmptyState icon={<NavIcon name="register" />} title="The register needs the company database" body="Once connected: daily and monthly attendance for everyone you may see, filters, and CSV export." />
        </GlassCard>
      ) : (
        <Register />
      )}
    </ModulePage>
  );
}
