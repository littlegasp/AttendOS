"use client";

import { useState } from "react";
import { AttendanceCard, Timeline, VerificationCard } from "@/components/AttendanceCard";
import { MyCorrections } from "@/components/Corrections";
import { HistoryPanel } from "@/components/HistoryPanel";
import { NavIcon } from "@/components/Icons";
import { PageContainer } from "@/components/PageContainer";
import { EmptyState, ErrorState, LoadingState } from "@/components/States";
import { Tabs } from "@/components/Tabs";
import { GlassCard, SectionCard } from "@/components/ui";
import { longDate } from "@/lib/attendance";
import { useSession } from "@/lib/session";
import { useAttendance } from "@/lib/use-attendance";

type Tab = "today" | "history" | "corrections";

export default function MyAttendancePage() {
  const { preview } = useSession();
  return (
    <PageContainer title="My Attendance" subtitle="Check in and check out with location verification" crumbs={[{ label: "Home", href: "/" }, { label: "My Attendance" }]}>
      {preview ? (
        <GlassCard>
          <EmptyState
            icon={<NavIcon name="clock" />}
            title="Check-in works once this copy is connected to its database"
            body="This is the design preview, so there is no account to record attendance against. As soon as the company's database is connected and you sign in, this screen shows your roster and shift for today and lets you check in, take breaks and check out."
          />
        </GlassCard>
      ) : (
        <Attendance />
      )}
    </PageContainer>
  );
}

function Attendance() {
  const att = useAttendance();
  const { employeeId } = useSession();
  const [tab, setTab] = useState<Tab>("today");
  const [bump, setBump] = useState(0);
  const t = att.today;

  if (att.loadError) return <GlassCard><ErrorState title="Couldn't load your attendance" body={att.loadError} onRetry={att.load} /></GlassCard>;
  if (!t) return <LoadingState label="Loading your attendance" />;

  return (
    <>
      <p className="sr-only" aria-live="assertive" role="status">{att.announce}</p>
      <Tabs
        label="My attendance"
        value={tab}
        onChange={setTab}
        tabs={[
          { id: "today", label: "Today" },
          { id: "history", label: "History" },
          { id: "corrections", label: "Corrections", badge: t.summary.pending_correction ? "1" : undefined },
        ]}
      />
      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} className="tab-panel">
        {tab === "today" ? (
          <>
            <div className="att-grid">
              <AttendanceCard att={att} />
              <VerificationCard att={att} />
            </div>
            <SectionCard title="Today's timeline" subtitle={longDate(att.serverNow, t.timezone)}>
              <Timeline t={t} />
            </SectionCard>
            <p className="meta">Missed a check-out or something looks wrong? Open History and use “Request correction” on that day. Your original entries are never edited away.</p>
          </>
        ) : tab === "history" ? (
          <HistoryPanel employeeId={employeeId!} tz={t.timezone} onRequested={() => { setBump((b) => b + 1); att.load(); }} />
        ) : (
          <MyCorrections tz={t.timezone} refreshKey={bump} />
        )}
      </div>
    </>
  );
}
