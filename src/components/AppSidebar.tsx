"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { Suspense, useEffect, useState } from "react";
import { navFor, normalise } from "@/lib/nav";
import { useSession } from "@/lib/session";
import { IconFold, NavIcon } from "./Icons";
import { SlidingHighlight } from "./SlidingHighlight";
import { MENU_KEY } from "./ThemeToggle";

function isOn(path: string, href: string) {
  return href === "/" ? path === "/" : path === href || path.startsWith(href + "/");
}

/** Brand mark: an orange "A" ring. Plain SVG so it themes with the tokens. */
export function BrandMark() {
  return (
    <svg className="brand-mark" viewBox="0 0 32 32" width="34" height="34" aria-hidden="true">
      <rect x="1" y="1" width="30" height="30" rx="9" className="bm-bg" />
      <path d="M10 22.5 16 9l6 13.5M12.4 17.5h7.2" className="bm-a" />
      <circle cx="23.5" cy="8.5" r="2.4" className="bm-dot" />
    </svg>
  );
}

/** Grouped navigation for the signed-in role. Used by the desktop sidebar and the mobile drawer. */
export function NavList({ onNavigate }: { onNavigate?: () => void }) {
  const { role } = useSession();
  const path = normalise(usePathname());
  return (
    <div className="nav-groups">
      <Suspense fallback={null}>
        <SlidingHighlight selector=".nav-link.on" />
      </Suspense>
      {navFor(role).map((g) => (
        <div key={g.label} className="nav-group" role="group" aria-label={g.label}>
          <div className="nav-label">{g.label}</div>
          {g.items.map((it) => {
            const on = isOn(path, it.href);
            return (
              <Link
                key={it.href}
                href={it.href}
                className={`nav-link${on ? " on" : ""}`}
                aria-current={on ? "page" : undefined}
                data-tip={it.label}
                onClick={onNavigate}
              >
                <span className="nav-ic"><NavIcon name={it.icon} /></span>
                <span className="nav-tx">{it.label}</span>
              </Link>
            );
          })}
        </div>
      ))}
    </div>
  );
}

/** Fold the sidebar to a 76px icon rail, or open it again. Remembered on this device. */
function FoldButton() {
  const [folded, setFolded] = useState(false);
  useEffect(() => {
    const root = document.documentElement;
    const read = () => {
      const m = root.dataset.menu;
      // Tablets start folded unless the user opened the menu.
      const tablet = window.matchMedia("(max-width: 1199px)").matches;
      setFolded(m === "folded" || (tablet && m !== "open"));
    };
    read();
    const mq = window.matchMedia("(max-width: 1199px)");
    mq.addEventListener("change", read);
    return () => mq.removeEventListener("change", read);
  }, []);
  function flip() {
    const next = !folded;
    setFolded(next);
    document.documentElement.dataset.menu = next ? "folded" : "open";
    try {
      localStorage.setItem(MENU_KEY, next ? "folded" : "open");
    } catch {
      /* not remembered */
    }
  }
  return (
    <button
      type="button"
      className="icon-btn fold-btn"
      onClick={flip}
      aria-label={folded ? "Expand the menu" : "Collapse the menu"}
      aria-expanded={!folded}
      title={folded ? "Expand menu" : "Collapse menu"}
    >
      <IconFold open={!folded} />
    </button>
  );
}

export function AppSidebar() {
  return (
    <nav className="sidebar" aria-label="Main">
      <div className="brand-row">
        <Link href="/" className="brand" aria-label="AttendOS home">
          <BrandMark />
          <span className="brand-tx">
            <strong>AttendOS</strong>
            <small>Attendance &amp; Workforce</small>
          </span>
        </Link>
        <FoldButton />
      </div>
      <NavList />
      <div className="sidebar-foot">
        <Link href="/design" className="foot-link" data-tip="Design system">
          <span className="nav-ic"><NavIcon name="dashboard" /></span>
          <span className="nav-tx">Design system</span>
        </Link>
        <span className="nav-tx tiny muted foot-ver">v0.1 · Phase 1 foundation</span>
      </div>
    </nav>
  );
}
