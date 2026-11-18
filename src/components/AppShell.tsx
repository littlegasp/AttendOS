"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { allowed, ALL_ITEMS, normalise } from "@/lib/nav";
import { roleLabel } from "@/lib/permissions";
import { SessionProvider, useSession } from "@/lib/session";
import { AppHeader } from "./AppHeader";
import { AppSidebar, BrandMark, NavList } from "./AppSidebar";
import { ClickFeel } from "./ClickFeel";
import { IconClose, IconMore, NavIcon } from "./Icons";
import { Toaster } from "./Toaster";

/** Phones: slide-in drawer holding the full grouped menu. */
function MobileDrawer({ open, onClose }: { open: boolean; onClose: () => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    else if (!open && d.open) d.close();
  }, [open]);
  return (
    <dialog
      ref={ref}
      className="drawer glass elevated"
      aria-label="Menu"
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onClick={(e) => e.target === e.currentTarget && onClose()}
    >
      <div className="drawer-inner">
        <div className="brand-row">
          <span className="brand">
            <BrandMark />
            <span className="brand-tx">
              <strong>AttendOS</strong>
              <small>Attendance &amp; Workforce</small>
            </span>
          </span>
          <button type="button" className="icon-btn" onClick={onClose} aria-label="Close the menu"><IconClose /></button>
        </div>
        {open ? <NavList onNavigate={onClose} /> : null}
      </div>
    </dialog>
  );
}

/** Phones: bottom bar with the daily actions, and Menu for everything else. */
function TabBar({ onMore }: { onMore: () => void }) {
  const { role } = useSession();
  const path = normalise(usePathname());
  const want = ["/", "/my-attendance", "/leave"];
  const tabs = ALL_ITEMS.filter((i) => want.includes(i.href) && allowed(role, i));
  const labels: Record<string, string> = { "/": "Home", "/my-attendance": "Attendance", "/leave": "Leave" };
  return (
    <nav className="tabbar glass elevated" aria-label="Quick">
      {tabs.map((t) => {
        const on = t.href === "/" ? path === "/" : path.startsWith(t.href);
        return (
          <Link key={t.href} href={t.href} className={`tab${on ? " on" : ""}${t.href === "/my-attendance" ? " tab-main" : ""}`} aria-current={on ? "page" : undefined}>
            <span className="tab-ic"><NavIcon name={t.icon} /></span>
            <span className="tab-tx">{labels[t.href]}</span>
          </Link>
        );
      })}
      <button type="button" className="tab" onClick={onMore} aria-haspopup="dialog">
        <span className="tab-ic"><IconMore /></span>
        <span className="tab-tx">Menu</span>
      </button>
    </nav>
  );
}

function PreviewBanner() {
  const { preview, role } = useSession();
  if (!preview) return null;
  return (
    <div className="preview-banner" role="note">
      <strong>Design preview</strong>
      <span>Not connected to a database yet. Viewing as <b>{roleLabel(role)}</b>. Change it from the profile menu.</span>
    </div>
  );
}

function Frame({ children }: { children: React.ReactNode }) {
  const [drawer, setDrawer] = useState(false);
  const path = usePathname();
  useEffect(() => setDrawer(false), [path]);
  return (
    <div className="shell">
      <a href="#main" className="skip-link">Skip to content</a>
      <ClickFeel />
      <Toaster />
      <AppSidebar />
      <div className="workspace">
        <AppHeader onOpenMenu={() => setDrawer(true)} />
        <PreviewBanner />
        <main id="main" className="main" tabIndex={-1}>
          {children}
        </main>
      </div>
      <TabBar onMore={() => setDrawer(true)} />
      <MobileDrawer open={drawer} onClose={() => setDrawer(false)} />
    </div>
  );
}

/** ResponsiveShell: sidebar + header + content for every route. */
export function AppShell({ children }: { children: React.ReactNode }) {
  return (
    <SessionProvider>
      <Frame>{children}</Frame>
    </SessionProvider>
  );
}
