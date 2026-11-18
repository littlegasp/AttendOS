"use client";

import { ALL_ITEMS, allowed } from "@/lib/nav";
import { useSession } from "@/lib/session";
import { NavIcon } from "./Icons";
import { PageContainer } from "./PageContainer";
import { EmptyState, PermissionDenied } from "./States";
import { GlassCard } from "./ui";

/**
 * Shared frame for a module whose real screen arrives in a later phase. It is honest about
 * that: no fake numbers, no buttons that do nothing. Access follows the role matrix.
 */
export function ModulePage({ href, children }: { href: string; children?: React.ReactNode }) {
  const { role } = useSession();
  const item = ALL_ITEMS.find((i) => i.href === href);
  if (!item) return null;
  const group = item.href === "/" ? undefined : [{ label: "Home", href: "/" }, { label: item.label }];

  return (
    <PageContainer title={item.label} subtitle={item.blurb} crumbs={group}>
      {!allowed(role, item) ? (
        <GlassCard><PermissionDenied what={item.label} /></GlassCard>
      ) : (
        children ?? (
          <GlassCard>
            <EmptyState
              icon={<NavIcon name={item.icon} />}
              title={`${item.label} is built in Phase ${item.phase}`}
              body="The shell, navigation and access rules for this screen are in place. Its data and actions are added in that phase, so nothing here shows made-up figures."
            />
          </GlassCard>
        )
      )}
    </PageContainer>
  );
}
