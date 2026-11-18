"use client";

import { useEffect, useState } from "react";
import { IconMoon, IconSun } from "./Icons";

/**
 * Day/night switch, same mechanism as studio-crm: one `data-theme` attribute on <html>,
 * remembered per device in localStorage, applied before first paint by THEME_BOOT.
 * Dark is the AttendOS default.
 */
export const THEME_KEY = "attendos.theme";
export const MENU_KEY = "attendos.menu";

export function ThemeToggle() {
  const [dark, setDark] = useState(true);
  useEffect(() => setDark(document.documentElement.dataset.theme !== "light"), []);
  function flip() {
    const next = !dark;
    setDark(next);
    const root = document.documentElement;
    root.classList.add("theme-switching");
    root.dataset.theme = next ? "dark" : "light";
    window.setTimeout(() => root.classList.remove("theme-switching"), 320);
    try {
      localStorage.setItem(THEME_KEY, next ? "dark" : "light");
    } catch {
      /* storage blocked: works until reload */
    }
  }
  return (
    <button
      type="button"
      className="icon-btn theme-toggle"
      onClick={flip}
      aria-label={dark ? "Switch to light theme" : "Switch to dark theme"}
      title={dark ? "Light theme" : "Dark theme"}
    >
      <span className="theme-icon" key={dark ? "sun" : "moon"}>{dark ? <IconSun /> : <IconMoon />}</span>
    </button>
  );
}

/** Runs before the page paints, so a light-theme device never flashes dark (and the menu never jumps). */
export const THEME_BOOT = `try{var r=document.documentElement,t=localStorage.getItem("${THEME_KEY}");r.dataset.theme=t==="light"?"light":"dark";var m=localStorage.getItem("${MENU_KEY}");if(m==="folded"||m==="open")r.dataset.menu=m}catch(e){document.documentElement.dataset.theme="dark"}`;
