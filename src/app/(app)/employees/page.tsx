"use client";

import { Suspense, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { EmployeeDirectory } from "@/components/employees/EmployeeDirectory";
import { EmployeeFormModal } from "@/components/employees/EmployeeFormModal";
import { EmployeeProfile } from "@/components/employees/EmployeeProfile";
import { useLookups } from "@/components/employees/lookups";
import { NavIcon } from "@/components/Icons";
import { ModulePage } from "@/components/ModulePage";
import { EmptyState, ErrorState, LoadingState } from "@/components/States";
import { GlassCard, SectionCard, StatusBadge } from "@/components/ui";
import { initials, statusLabel, type EmploymentStatus } from "@/lib/employees";
import { can, roleLabel, type Role } from "@/lib/permissions";
import { useSession } from "@/lib/session";
import { supabase } from "@/lib/supabase";
import { must, useLoad } from "@/lib/use-load";

export default function EmployeesPage() {
  const { preview, role } = useSession();
  return (
    <ModulePage href="/employees">
      {preview ? (
        <GlassCard>
          <EmptyState
            icon={<NavIcon name="people" />}
            title="The employee directory needs the company database"
            body="Once connected, HR adds people with their employee ID, department, designation, reporting manager, joining date, office and default shift; Admins assign roles; anyone can be deactivated without losing history."
          />
        </GlassCard>
      ) : role === "employee" ? (
        <MyProfile />
      ) : (
        <Suspense fallback={<LoadingState kind="table" />}>
          <People />
        </Suspense>
      )}
    </ModulePage>
  );
}

function People() {
  const router = useRouter();
  const params = useSearchParams();
  const id = params.get("id");
  const { role } = useSession();
  const [adding, setAdding] = useState(false);
  const [bump, setBump] = useState(0);
  const { data: lookups, error, reload } = useLookups(`lookups:${bump}`);

  if (error) return <GlassCard><ErrorState body={error} onRetry={reload} /></GlassCard>;
  if (!lookups) return <LoadingState kind="table" label="Loading people" />;

  const open = (pid: string) => router.push(`/employees?id=${pid}`);
  return (
    <>
      {role === "manager" && !id ? <p className="page-sub">Your direct reports. HR keeps their records up to date.</p> : null}
      {id ? (
        <EmployeeProfile id={id} lookups={lookups} onBack={() => router.push("/employees")} onChanged={() => setBump((b) => b + 1)} />
      ) : (
        <EmployeeDirectory lookups={lookups} onOpen={open} onAdd={() => setAdding(true)} refreshKey={bump} />
      )}
      {adding && can(role, "manageEmployees") ? (
        <EmployeeFormModal
          employee={null}
          lookups={lookups}
          onClose={() => setAdding(false)}
          onSaved={(newId) => {
            setAdding(false);
            setBump((b) => b + 1);
            open(newId);
          }}
        />
      ) : null}
    </>
  );
}

interface Profile {
  emp_code: string | null;
  full_name: string;
  email: string;
  phone: string | null;
  role: Role;
  employment_status: EmploymentStatus;
  joining_date: string | null;
  department: string | null;
  designation: string | null;
  manager: string | null;
  manager_email: string | null;
  office: string | null;
  default_shift: string | null;
  company: string;
}

/** Employees see their own record (read-only), including names they can't otherwise look up. */
function MyProfile() {
  const { data, error, reload } = useLoad(async () => must(await supabase().rpc("my_profile")) as Profile, "me");
  if (error) return <GlassCard><ErrorState body={error} onRetry={reload} /></GlassCard>;
  if (!data) return <LoadingState />;
  const p = data;
  const day = (d: string | null) => (d ? new Date(`${d}T12:00:00Z`).toLocaleDateString("en-IN", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" }) : "—");
  return (
    <>
      <GlassCard className="profile-head-card">
        <span className="avatar xl" aria-hidden="true">{initials(p.full_name)}</span>
        <div className="ph-main">
          <h2 className="section-title">{p.full_name}</h2>
          <p className="meta">{[p.emp_code, p.designation, p.department].filter(Boolean).join(" · ") || p.company}</p>
          <div className="row ph-badges">
            <StatusBadge status="verified" label={statusLabel(p.employment_status)} />
            <span className="role-tag">{roleLabel(p.role)}</span>
          </div>
        </div>
      </GlassCard>
      <div className="grid-2">
        <SectionCard title="My work details">
          <dl className="rules-view">
            <dt>Employee ID</dt><dd className="mono">{p.emp_code ?? "—"}</dd>
            <dt>Company</dt><dd>{p.company}</dd>
            <dt>Department</dt><dd>{p.department ?? "—"}</dd>
            <dt>Designation</dt><dd>{p.designation ?? "—"}</dd>
            <dt>Reporting manager</dt><dd>{p.manager ? `${p.manager}${p.manager_email ? ` · ${p.manager_email}` : ""}` : "—"}</dd>
            <dt>Assigned office</dt><dd>{p.office ?? "Any company office"}</dd>
            <dt>Default shift</dt><dd>{p.default_shift ?? "Company default"}</dd>
            <dt>Joining date</dt><dd>{day(p.joining_date)}</dd>
          </dl>
        </SectionCard>
        <SectionCard title="Contact">
          <dl className="rules-view">
            <dt>Work e-mail</dt><dd>{p.email}</dd>
            <dt>Phone</dt><dd>{p.phone ?? "—"}</dd>
          </dl>
          <p className="meta privacy-note">Something wrong here? Ask HR to update it — changes are recorded.</p>
        </SectionCard>
      </div>
    </>
  );
}
