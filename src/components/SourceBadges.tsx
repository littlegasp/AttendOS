import { isSource, SOURCE_LABEL, SOURCE_TONE, type DaySources } from "@/lib/sources";

/** The sources counted on a day, as small labelled badges (text + shape, never colour alone). */
export function SourceBadges({ day }: { day: DaySources | undefined | null }) {
  if (!day || day.sources.length === 0) return <span className="muted">—</span>;
  return (
    <span className="src-cell" aria-label={`Source: ${day.sources.map((s) => (isSource(s) ? SOURCE_LABEL[s] : s)).join(", ")}`}>
      {day.sources.map((s) => (
        <span key={s} className={`badge tone-${isSource(s) ? SOURCE_TONE[s] : "neutral"}`} data-source={s}>
          <span className="badge-dot" aria-hidden="true" />
          {isSource(s) ? SOURCE_LABEL[s] : s}
        </span>
      ))}
    </span>
  );
}

/** Shown where a check-out would be when a biometric check-out is only provisional (not counted until the day closes). */
export function ProvisionalOut() {
  return (
    <span className="prov-out" data-testid="provisional-out">
      <span className="badge tone-warning"><span className="badge-dot" aria-hidden="true" />Provisional</span>
      <span className="tiny muted" title="Not counted in working hours, overtime or early leaving until the day closes">Check-out, final at day close</span>
    </span>
  );
}
