"use client";

import { RoleMatrix, UserAccess } from "@/components/AccessScreens";
import { ModulePage } from "@/components/ModulePage";
import { useSession } from "@/lib/session";

export default function RolesPage() {
  const { preview } = useSession();
  return (
    <ModulePage href="/roles">
      <div className="stack">
        <RoleMatrix />
        {preview ? <p className="meta">User access (who can sign in, last sign-in) appears here once a database is connected.</p> : <UserAccess />}
      </div>
    </ModulePage>
  );
}
