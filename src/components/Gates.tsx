"use client";

import { can, type Capability, type Role } from "@/lib/permissions";
import { useSession } from "@/lib/session";
import { PermissionDenied } from "./States";

/**
 * Interface-level gates. They hide what a role can't use, but they are NOT security:
 * every read and write is also checked on the server from Phase 2.
 */
export function RoleGate({ roles, children, fallback = null }: { roles: Role[]; children: React.ReactNode; fallback?: React.ReactNode }) {
  const { role } = useSession();
  return <>{roles.includes(role) ? children : fallback}</>;
}

export function PermissionGate({ cap, children, what, quiet = false }: { cap: Capability | Capability[]; children: React.ReactNode; what?: string; quiet?: boolean }) {
  const { role } = useSession();
  const caps = Array.isArray(cap) ? cap : [cap];
  const ok = caps.some((c) => can(role, c));
  if (ok) return <>{children}</>;
  return quiet ? null : <PermissionDenied what={what} />;
}
