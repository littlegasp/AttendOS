"use client";

import { IconAlert, IconInbox, IconLock } from "./Icons";

/** Explains why nothing is listed and, where it helps, offers the next action. */
export function EmptyState({
  title,
  body,
  action,
  icon,
  compact = false,
}: {
  title: string;
  body?: React.ReactNode;
  action?: React.ReactNode;
  icon?: React.ReactNode;
  compact?: boolean;
}) {
  return (
    <div className={`state${compact ? " compact" : ""}`}>
      <span className="state-ic" aria-hidden="true">{icon ?? <IconInbox />}</span>
      <p className="state-title">{title}</p>
      {body ? <p className="state-body">{body}</p> : null}
      {action ? <div className="state-action">{action}</div> : null}
    </div>
  );
}

/** Human-readable error with a retry when retrying is safe. */
export function ErrorState({ title = "Something went wrong", body, onRetry }: { title?: string; body?: string; onRetry?: () => void }) {
  return (
    <div className="state error" role="alert">
      <span className="state-ic" aria-hidden="true"><IconAlert /></span>
      <p className="state-title">{title}</p>
      {body ? <p className="state-body">{body}</p> : null}
      {onRetry ? (
        <div className="state-action">
          <button type="button" className="btn secondary" onClick={onRetry}>Try again</button>
        </div>
      ) : null}
    </div>
  );
}

/** Says access is restricted without revealing anything about the protected data. */
export function PermissionDenied({ what = "this screen" }: { what?: string }) {
  return (
    <div className="state denied" role="note">
      <span className="state-ic" aria-hidden="true"><IconLock /></span>
      <p className="state-title">You don&apos;t have access to {what}</p>
      <p className="state-body">Your role doesn&apos;t include this. If you need it for your work, ask an administrator.</p>
    </div>
  );
}

/** Skeleton placeholders shaped roughly like what is loading. */
export function LoadingState({ kind = "page", label = "Loading" }: { kind?: "page" | "cards" | "table"; label?: string }) {
  return (
    <div className="skel" aria-busy="true" aria-live="polite">
      {kind === "cards" ? (
        <div className="grid-kpi">{[0, 1, 2, 3].map((n) => <i key={n} className="skel-tile" />)}</div>
      ) : kind === "table" ? (
        <div className="skel-table">{[0, 1, 2, 3, 4].map((n) => <i key={n} />)}</div>
      ) : (
        <>
          <i className="skel-line w40" />
          <i className="skel-line w25" />
          <div className="grid-2"><i className="skel-block" /><i className="skel-block" /></div>
        </>
      )}
      <span className="sr-only">{label}…</span>
    </div>
  );
}
