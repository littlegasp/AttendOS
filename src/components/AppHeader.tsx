"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useId, useRef, useState } from "react";
import { NAV, itemFor, normalise, searchNav } from "@/lib/nav";

/** Screens outside the main menu. */
const EXTRA_TITLES: Record<string, string> = { "/design": "Design system" };
import { ROLES, roleLabel, type Role } from "@/lib/permissions";
import { useSession } from "@/lib/session";
import { IconBell, IconMenu, IconSearch, NavIcon } from "./Icons";
import { Popover } from "./Popover";
import { ThemeToggle } from "./ThemeToggle";
import { BrandMark } from "./AppSidebar";
import { EmptyState } from "./States";
import { BRAND } from "@/lib/brand";

/** Jump to any screen the signed-in role can open. Ctrl/⌘ + K focuses it. */
function GlobalSearch() {
  const { role } = useSession();
  const router = useRouter();
  const [q, setQ] = useState("");
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const input = useRef<HTMLInputElement>(null);
  const listId = useId();
  const results = searchNav(role, q);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        input.current?.focus();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  function go(href: string) {
    setOpen(false);
    setQ("");
    input.current?.blur();
    router.push(href);
  }

  return (
    <div className="search" role="search">
      <label className="sr-only" htmlFor="global-search">Search screens</label>
      <span className="search-ic"><IconSearch /></span>
      <input
        ref={input}
        id="global-search"
        type="search"
        className="search-input"
        placeholder="Search screens…"
        autoComplete="off"
        role="combobox"
        aria-expanded={open}
        aria-controls={listId}
        aria-activedescendant={open && results[active] ? `${listId}-${active}` : undefined}
        value={q}
        onChange={(e) => {
          setQ(e.target.value);
          setActive(0);
          setOpen(true);
        }}
        onFocus={() => setOpen(true)}
        onBlur={() => window.setTimeout(() => setOpen(false), 120)}
        onKeyDown={(e) => {
          if (e.key === "ArrowDown") {
            e.preventDefault();
            setActive((a) => Math.min(a + 1, results.length - 1));
          } else if (e.key === "ArrowUp") {
            e.preventDefault();
            setActive((a) => Math.max(a - 1, 0));
          } else if (e.key === "Enter" && results[active]) {
            e.preventDefault();
            go(results[active].href);
          } else if (e.key === "Escape") {
            setOpen(false);
          }
        }}
      />
      <kbd className="search-kbd" aria-hidden="true">Ctrl K</kbd>
      {open ? (
        <ul id={listId} className="search-results popover glass elevated" role="listbox" aria-label="Screens">
          {results.length === 0 ? (
            <li className="search-empty muted small">No screen matches “{q}”.</li>
          ) : (
            results.map((r, i) => (
              <li
                key={r.href}
                id={`${listId}-${i}`}
                role="option"
                aria-selected={i === active}
                className={`search-row${i === active ? " on" : ""}`}
                onMouseDown={(e) => {
                  e.preventDefault();
                  go(r.href);
                }}
                onMouseEnter={() => setActive(i)}
              >
                <span className="search-row-ic"><NavIcon name={r.icon} /></span>
                <span>
                  <span className="search-row-t">{r.label}</span>
                  <span className="search-row-b">{r.blurb}</span>
                </span>
              </li>
            ))
          )}
        </ul>
      ) : null}
    </div>
  );
}

function Notifications() {
  return (
    <Popover label="Notifications" button={<IconBell />}>
      {() => (
        <div className="pop-body">
          <div className="pop-head"><strong>Notifications</strong></div>
          <EmptyState
            compact
            title="You're all caught up"
            body="Leave decisions, late alerts and correction requests will appear here once those modules are live."
          />
        </div>
      )}
    </Popover>
  );
}

function initials(name: string) {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((p) => p[0]!.toUpperCase())
    .join("");
}

function ProfileMenu() {
  const s = useSession();
  return (
    <Popover
      label={`Account menu for ${s.name}`}
      className="profile"
      button={<span className="avatar" aria-hidden="true">{initials(s.name)}</span>}
    >
      {(close) => (
        <div className="pop-body">
          <div className="pop-head profile-head">
            <span className="avatar lg" aria-hidden="true">{initials(s.name)}</span>
            <span>
              <strong>{s.name}</strong>
              <span className="tiny muted block">{s.email}</span>
              <span className="tiny muted block">{roleLabel(s.role)}</span>
            </span>
          </div>
          {s.preview ? (
            <fieldset className="role-switch">
              <legend className="tiny muted">Preview as role</legend>
              <div className="seg" role="radiogroup" aria-label="Preview as role">
                {ROLES.map((r) => (
                  <button
                    key={r.id}
                    type="button"
                    role="radio"
                    aria-checked={s.role === r.id}
                    className={`seg-btn${s.role === r.id ? " on" : ""}`}
                    onClick={() => s.setPreviewRole(r.id as Role)}
                  >
                    {r.label}
                  </button>
                ))}
              </div>
              <p className="tiny muted">Design preview only. In a connected copy the role comes from sign-in.</p>
            </fieldset>
          ) : null}
          <div className="menu-list">
            <Link href="/my-attendance" className="menu-item" onClick={close}>My Attendance</Link>
            {s.preview ? (
              <button type="button" className="menu-item" disabled title="No sign-in in design preview">Sign out</button>
            ) : (
              <button type="button" className="menu-item" onClick={() => s.signOut()}>Sign out</button>
            )}
          </div>
        </div>
      )}
    </Popover>
  );
}

export function AppHeader({ onOpenMenu }: { onOpenMenu: () => void }) {
  const path = usePathname();
  const current = itemFor(path ?? "/");
  return (
    <header className="app-header">
      <button type="button" className="icon-btn menu-btn" onClick={onOpenMenu} aria-label="Open the menu">
        <IconMenu />
      </button>
      <Link href="/" className="header-brand" aria-label={`${BRAND.appName} home`}>
        <BrandMark />
        <strong>{BRAND.appName}</strong>
      </Link>
      <div className="header-context">
        <span className="tiny muted">{current ? sectionOf(current.href) : BRAND.appName}</span>
        <strong className="header-title">{current?.label ?? EXTRA_TITLES[normalise(path)] ?? BRAND.appName}</strong>
      </div>
      <GlobalSearch />
      <div className="header-actions">
        <Notifications />
        <ThemeToggle />
        <ProfileMenu />
      </div>
    </header>
  );
}

function sectionOf(href: string) {
  return NAV.find((g) => g.items.some((i) => i.href === href))?.label ?? "";
}
