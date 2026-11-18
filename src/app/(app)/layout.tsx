import { AppShell } from "@/components/AppShell";

/** Every signed-in screen shares the shell. Sign-in pages live outside this group. */
export default function AppLayout({ children }: { children: React.ReactNode }) {
  return <AppShell>{children}</AppShell>;
}
