"use client";

import { useEffect, useState } from "react";
import { TOAST_EVENT, type ToastMsg } from "@/lib/toast";
import { IconAlert, IconCheck, IconInfo, IconX } from "./Icons";

const SHOW_FOR = 6000;
const MAX = 3;

/** Toasts slide in at the corner (bottom on phones), are read out by screen readers, and leave on their own. */
export function Toaster() {
  const [items, setItems] = useState<(ToastMsg & { id: number })[]>([]);

  useEffect(() => {
    const timers = new Set<ReturnType<typeof setTimeout>>();
    const on = (e: Event) => {
      const id = Date.now() + Math.random();
      setItems((xs) => [...xs, { ...(e as CustomEvent<ToastMsg>).detail, id }].slice(-MAX));
      const t = setTimeout(() => {
        setItems((xs) => xs.filter((x) => x.id !== id));
        timers.delete(t);
      }, SHOW_FOR);
      timers.add(t);
    };
    window.addEventListener(TOAST_EVENT, on);
    return () => {
      window.removeEventListener(TOAST_EVENT, on);
      timers.forEach(clearTimeout);
    };
  }, []);

  return (
    <div className="toasts" role="status" aria-live="polite">
      {items.map((t) => {
        const tone = t.tone ?? "info";
        return (
          <div key={t.id} className={`toast glass elevated tone-${tone}`}>
            <span className="toast-ic" aria-hidden="true">
              {tone === "success" ? <IconCheck /> : tone === "danger" ? <IconX /> : tone === "warning" ? <IconAlert /> : <IconInfo />}
            </span>
            <div className="toast-text">
              <strong>{t.title}</strong>
              {t.body ? <span>{t.body}</span> : null}
            </div>
            <button type="button" className="toast-x" aria-label="Dismiss" onClick={() => setItems((xs) => xs.filter((x) => x.id !== t.id))}>×</button>
          </div>
        );
      })}
    </div>
  );
}
