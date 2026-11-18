import Link from "next/link";
import { PageContainer } from "@/components/PageContainer";
import { EmptyState } from "@/components/States";
import { GlassCard } from "@/components/ui";

export default function NotFound() {
  return (
    <PageContainer title="Page not found">
      <GlassCard>
        <EmptyState
          title="This page doesn't exist"
          body="The link may be old or mistyped."
          action={<Link href="/" className="btn primary md">Go to Dashboard</Link>}
        />
      </GlassCard>
    </PageContainer>
  );
}
