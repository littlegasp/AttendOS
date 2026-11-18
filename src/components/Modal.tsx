"use client";

import { useEffect, useId, useRef } from "react";
import { IconClose } from "./Icons";

/** A titled dialog for small forms (native <dialog>: focus stays inside, Escape closes). */
export function Modal({ open, title, subtitle, onClose, children, wide = false }: { open: boolean; title: string; subtitle?: string; onClose: () => void; children: React.ReactNode; wide?: boolean }) {
  const ref = useRef<HTMLDialogElement>(null);
  const tid = useId();
  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    else if (!open && d.open) d.close();
  }, [open]);
  return (
    <dialog
      ref={ref}
      className={`dialog glass elevated${wide ? " wide" : ""}`}
      aria-labelledby={tid}
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
    >
      <div className="modal-head">
        <div>
          <h2 id={tid} className="card-title">{title}</h2>
          {subtitle ? <p className="meta">{subtitle}</p> : null}
        </div>
        <button type="button" className="icon-btn" onClick={onClose} aria-label="Close"><IconClose /></button>
      </div>
      {open ? children : null}
    </dialog>
  );
}
