/**
 * CSV for exports (opens in Excel and Google Sheets). Values that a spreadsheet would treat as a
 * formula (= + - @, tab, carriage return) are prefixed with ' so an export can't run anything.
 */
export function csvCell(v: unknown): string {
  if (v === null || v === undefined) return "";
  let s = typeof v === "number" || typeof v === "boolean" ? String(v) : String(v);
  if (/^[=+\-@\t\r]/.test(s) && !/^-?\d+(\.\d+)?$/.test(s)) s = "'" + s;
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

export function toCsv<T>(rows: T[], cols: { label: string; value: (r: T) => unknown }[]): string {
  const head = cols.map((c) => csvCell(c.label)).join(",");
  const body = rows.map((r) => cols.map((c) => csvCell(c.value(r))).join(","));
  return "﻿" + [head, ...body].join("\r\n") + "\r\n";
}

export function downloadCsv(name: string, csv: string) {
  const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name.endsWith(".csv") ? name : `${name}.csv`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
