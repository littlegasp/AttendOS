"use client";

import { useId } from "react";

/**
 * Small SVG charts drawn with the theme tokens (no chart library). Every chart has a text summary for
 * screen readers and a "Show as table" equivalent, as the guide asks.
 */
export interface Point { label: string; value: number | null }

export function LineChart({ points, unit = "", max, title, summary, tone = "primary" }: { points: Point[]; unit?: string; max?: number; title: string; summary: string; tone?: "primary" | "info" | "success" }) {
  const id = useId();
  const W = 640, H = 220, L = 40, R = 12, T = 12, B = 30;
  const vals = points.map((p) => p.value).filter((v): v is number => v !== null);
  const top = max ?? Math.max(1, ...vals) * 1.1;
  const x = (i: number) => L + (points.length <= 1 ? (W - L - R) / 2 : (i * (W - L - R)) / (points.length - 1));
  const y = (v: number) => T + (H - T - B) * (1 - v / top);
  const segs: string[] = [];
  let cur = "";
  points.forEach((p, i) => {
    if (p.value === null) { if (cur) segs.push(cur); cur = ""; return; }
    cur += `${cur ? "L" : "M"}${x(i).toFixed(1)},${y(p.value).toFixed(1)}`;
  });
  if (cur) segs.push(cur);
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => Math.round(top * f * 10) / 10);
  const every = Math.max(1, Math.ceil(points.length / 8));
  return (
    <figure className={`chart tone-${tone}`} aria-labelledby={`${id}-t`}>
      <figcaption id={`${id}-t`} className="sr-only">{title}. {summary}</figcaption>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`${title}. ${summary}`} preserveAspectRatio="none">
        {ticks.map((t) => (
          <g key={t}>
            <line x1={L} x2={W - R} y1={y(t)} y2={y(t)} className="ch-grid" />
            <text x={L - 6} y={y(t) + 4} className="ch-axis" textAnchor="end">{t}{unit}</text>
          </g>
        ))}
        {segs.map((d, i) => <path key={i} d={d} className="ch-line" />)}
        {points.map((p, i) => p.value === null ? null : <circle key={i} cx={x(i)} cy={y(p.value)} r={3} className="ch-dot"><title>{`${p.label}: ${p.value}${unit}`}</title></circle>)}
        {points.map((p, i) => (i % every === 0 || i === points.length - 1 ? <text key={`l${i}`} x={x(i)} y={H - 8} className="ch-axis" textAnchor="middle">{p.label}</text> : null))}
      </svg>
      <ChartTable rows={points.map((p) => [p.label, p.value === null ? "—" : `${p.value}${unit}`])} head={["Date", title]} />
    </figure>
  );
}

export function BarList({ rows, unit = "", max, title }: { rows: { label: string; value: number | null; note?: string }[]; unit?: string; max?: number; title: string }) {
  const top = max ?? Math.max(1, ...rows.map((r) => r.value ?? 0));
  return (
    <figure className="chart">
      <figcaption className="sr-only">{title}</figcaption>
      <ul className="bar-list">
        {rows.map((r) => (
          <li key={r.label}>
            <span className="bl-label">{r.label}</span>
            <span className="bl-track" aria-hidden="true"><span className="bl-fill" style={{ width: `${Math.max(0, Math.min(100, ((r.value ?? 0) / top) * 100))}%` }} /></span>
            <span className="bl-value">{r.value === null ? "—" : `${r.value}${unit}`}{r.note ? <span className="tiny muted"> {r.note}</span> : null}</span>
          </li>
        ))}
      </ul>
    </figure>
  );
}

const MIX_TONE: Record<string, string> = { present: "success", late: "warning", absent: "danger", on_leave: "info" };

export function StackBar({ parts, title }: { parts: { key: string; label: string; value: number }[]; title: string }) {
  const total = parts.reduce((a, p) => a + p.value, 0);
  const summary = parts.map((p) => `${p.label} ${p.value}`).join(", ");
  return (
    <div className="dist">
      <div className="dist-bar" role="img" aria-label={`${title}: ${summary}`}>
        {parts.filter((p) => p.value).map((p) => <span key={p.key} className={`dist-seg t-${MIX_TONE[p.key] ?? "neutral"}`} style={{ flexGrow: p.value }} title={`${p.label}: ${p.value}`} />)}
      </div>
      <ul className="dist-legend">
        {parts.map((p) => (
          <li key={p.key}>
            <span className={`dist-dot t-${MIX_TONE[p.key] ?? "neutral"}`} aria-hidden="true" />
            <span>{p.label}</span>
            <strong>{p.value}</strong>
            <span className="meta">{total ? Math.round((100 * p.value) / total) : 0}%</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

function ChartTable({ rows, head }: { rows: string[][]; head: string[] }) {
  return (
    <details className="chart-table">
      <summary>Show as table</summary>
      <div className="table-wrap">
        <table className="table">
          <thead><tr>{head.map((h) => <th key={h} scope="col">{h}</th>)}</tr></thead>
          <tbody>{rows.map((r, i) => <tr key={i}>{r.map((c, j) => (j === 0 ? <th key={j} scope="row">{c}</th> : <td key={j}>{c}</td>))}</tr>)}</tbody>
        </table>
      </div>
    </details>
  );
}
