"use client";

import { useEffect, useId, useRef, useState } from "react";

/**
 * A button that opens a small floating panel (notifications, profile menu).
 * Closes on outside click and Escape, and returns focus to the button.
 */
export function Popover({
  label,
  button,
  className = "",
  align = "end",
  children,
}: {
  label: string;
  button: React.ReactNode;
  className?: string;
  align?: "start" | "end";
  children: (close: () => void) => React.ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const wrap = useRef<HTMLDivElement>(null);
  const btn = useRef<HTMLButtonElement>(null);
  const id = useId();

  useEffect(() => {
    if (!open) return;
    const onDown = (e: PointerEvent) => {
      if (!wrap.current?.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setOpen(false);
        btn.current?.focus();
      }
    };
    document.addEventListener("pointerdown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("pointerdown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const close = () => {
    setOpen(false);
    btn.current?.focus();
  };

  return (
    <div className={`pop-wrap ${className}`} ref={wrap}>
      <button
        ref={btn}
        type="button"
        className="icon-btn"
        aria-label={label}
        title={label}
        aria-expanded={open}
        aria-controls={id}
        onClick={() => setOpen((o) => !o)}
      >
        {button}
      </button>
      {open ? (
        <div id={id} className={`popover glass elevated align-${align}`} role="dialog" aria-label={label}>
          {children(close)}
        </div>
      ) : null}
    </div>
  );
}
