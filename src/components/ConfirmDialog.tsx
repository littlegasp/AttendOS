"use client";

import { useEffect, useId, useRef } from "react";
import { Button } from "./ui";

/**
 * Confirmation for destructive or irreversible actions. Built on the native <dialog>,
 * so focus is trapped and Escape cancels; focus starts on Cancel to avoid accidents.
 */
export function ConfirmDialog({
  open,
  title,
  consequence,
  confirmLabel = "Confirm",
  danger = false,
  busy = false,
  onConfirm,
  onCancel,
}: {
  open: boolean;
  title: string;
  consequence: React.ReactNode;
  confirmLabel?: string;
  danger?: boolean;
  busy?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const cancel = useRef<HTMLButtonElement>(null);
  const tid = useId();
  const did = useId();

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) {
      d.showModal();
      cancel.current?.focus();
    } else if (!open && d.open) d.close();
  }, [open]);

  return (
    <dialog
      ref={ref}
      className="dialog glass elevated"
      aria-labelledby={tid}
      aria-describedby={did}
      onCancel={(e) => {
        e.preventDefault();
        if (!busy) onCancel();
      }}
    >
      <h2 id={tid} className="card-title">{title}</h2>
      <div id={did} className="dialog-body">{consequence}</div>
      <div className="dialog-actions">
        <Button ref={cancel} variant="ghost" onClick={onCancel} disabled={busy}>Cancel</Button>
        <Button variant={danger ? "danger" : "primary"} loading={busy} onClick={onConfirm}>{confirmLabel}</Button>
      </div>
    </dialog>
  );
}
