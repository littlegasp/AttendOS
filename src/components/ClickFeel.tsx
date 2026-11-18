"use client";

import { useEffect } from "react";

const PRESSABLE = ".btn, .nav-link, .icon-btn, .chip, .tab, .menu-item";

/**
 * Makes taps feel physical across the whole app (carried over from studio-crm): a soft ripple spreads from
 * where you pressed, and on phones that support it, main actions give a tiny
 * vibration. Nothing here changes what a button does.
 */
export function ClickFeel() {
  useEffect(() => {
    const calm = window.matchMedia("(prefers-reduced-motion: reduce)");
    function onDown(e: PointerEvent) {
      if (e.button !== 0) return;
      const el = (e.target as Element | null)?.closest<HTMLElement>(PRESSABLE);
      if (!el || (el as HTMLButtonElement).disabled) return;
      if (!calm.matches) {
        const r = el.getBoundingClientRect();
        const size = Math.max(r.width, r.height) * 2.2;
        const dot = document.createElement("span");
        dot.className = "ripple";
        dot.style.cssText = `width:${size}px;height:${size}px;left:${e.clientX - r.left - size / 2}px;top:${e.clientY - r.top - size / 2}px`;
        el.classList.add("has-ripple");
        el.appendChild(dot);
        dot.addEventListener("animationend", () => dot.remove(), { once: true });
      }
      // A light tick on phones for the actions that change something.
      if (e.pointerType === "touch" && el.matches(".btn.primary, .btn.danger") && "vibrate" in navigator) {
        try {
          navigator.vibrate(8);
        } catch {
          /* not allowed: fine */
        }
      }
    }
    document.addEventListener("pointerdown", onDown, { passive: true });
    return () => document.removeEventListener("pointerdown", onDown);
  }, []);
  return null;
}
