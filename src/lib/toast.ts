/** Fire-and-forget toast messages, picked up by <Toaster /> (same event pattern as studio-crm). */
export type ToastTone = "success" | "info" | "warning" | "danger";

export interface ToastMsg {
  title: string;
  body?: string;
  tone?: ToastTone;
}

export const TOAST_EVENT = "attendos:toast";

export function toast(msg: ToastMsg) {
  if (typeof window === "undefined") return;
  window.dispatchEvent(new CustomEvent<ToastMsg>(TOAST_EVENT, { detail: msg }));
}
