"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { NavIcon } from "@/components/Icons";
import { PageContainer } from "@/components/PageContainer";
import { EmptyState } from "@/components/States";
import { GlassCard, SectionCard } from "@/components/ui";
import { ALL_ITEMS, allowed } from "@/lib/nav";
import { SCOPE_LABEL, scopeOf } from "@/lib/permissions";
import { useSession } from "@/lib/session";

function greeting(h: number) {
  return h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening";
}

/** Quick actions from the guide; each one only appears if the role can open its screen. */
const QUICK = [
  { href: "/my-attendance", label: "Mark Attendance" },
  { href: "/leave", label: "Apply Leave" },
  { href: "/attendance", label: "Team Attendance" },
  { href: "/reports", label: "Generate Report" },
];

export default function DashboardPage() {
  const { role } = useSession();
  // Date is drawn in the browser so the static build never bakes in a stale day.
  const [now, setNow] = useState<Date | null>(null);
  useEffect(() => setNow(new Date()), []);

  const quick = QUICK.map((q) => ({ ...q, item: ALL_ITEMS.find((i) => i.href === q.href)! })).filter((q) => allowed(role, q.item));
  const scope = SCOPE_LABEL[scopeOf(role, "dashboard")];

  return (
    <PageContainer
      title={now ? greeting(now.getHours()) : "Dashboard"}
      subtitle={now ? now.toLocaleDateString("en-IN", { weekday: "long", day: "numeric", month: "long", year: "numeric" }) : " "}
    >
      <div className="quick-grid">
        {quick.map((q, i) => (
          <Link key={q.href} href={q.href} className={`card glass quick${i === 0 ? " quick-primary" : ""}`}>
            <span className="quick-ic" aria-hidden="true"><NavIcon name={q.item.icon} /></span>
            <span className="quick-tx">
              <strong>{q.label}</strong>
              <span className="meta">{q.item.blurb}</span>
            </span>
          </Link>
        ))}
      </div>

      <div className="grid-2">
        <SectionCard title="Today's attendance" subtitle={`Scope: ${scope}`}>
          <EmptyState
            title="No attendance data yet"
            body="Present, Absent, Late and On Leave counts appear here once check-in is live (Phase 2) and employees are added (Phase 3). They are always calculated from real records in your organization's time zone."
          />
        </SectionCard>
        <SectionCard title="Recent activity" subtitle="Check-ins, late arrivals and pending leave">
          <EmptyState title="Nothing to show yet" body="Activity starts appearing when people check in or apply for leave." />
        </SectionCard>
      </div>

      <GlassCard className="note-card">
        <p className="small">
          <strong>Phase 1 foundation.</strong> You&apos;re looking at the shared shell, theme and building blocks. See the{" "}
          <Link href="/design">design system page</Link> for every component in both themes.
        </p>
      </GlassCard>
    </PageContainer>
  );
}
