/** Dates as plain YYYY-MM-DD strings (company calendar days), formatted with the company's date format. */

const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
export const DATE_FORMATS = ["DD MMM YYYY", "DD/MM/YYYY", "MM/DD/YYYY", "YYYY-MM-DD"] as const;
export type DateFormat = (typeof DATE_FORMATS)[number];

export function formatDay(day: string | null | undefined, fmt: string = "DD MMM YYYY"): string {
  if (!day) return "—";
  const [y, m, d] = day.slice(0, 10).split("-");
  if (!y || !m || !d) return day;
  switch (fmt) {
    case "DD/MM/YYYY": return `${d}/${m}/${y}`;
    case "MM/DD/YYYY": return `${m}/${d}/${y}`;
    case "YYYY-MM-DD": return `${y}-${m}-${d}`;
    default: return `${d} ${MON[Number(m) - 1]} ${y}`;
  }
}

/** Short form for tables and calendars: "19 Nov" (or "19/11" style for numeric formats). */
export function shortFormat(day: string, fmt: string = "DD MMM YYYY"): string {
  const [, m, d] = day.split("-");
  if (fmt === "MM/DD/YYYY") return `${m}/${d}`;
  if (fmt === "DD/MM/YYYY") return `${d}/${m}`;
  if (fmt === "YYYY-MM-DD") return `${m}-${d}`;
  return `${Number(d)} ${MON[Number(m) - 1]}`;
}

export function addDays(day: string, n: number): string {
  const [y, m, d] = day.split("-").map(Number);
  const t = new Date(Date.UTC(y!, m! - 1, d! + n));
  return t.toISOString().slice(0, 10);
}

export function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(b + "T00:00:00Z") - Date.parse(a + "T00:00:00Z")) / 86400000);
}

export function monthOf(day: string): { from: string; to: string; label: string } {
  const [y, m] = day.split("-").map(Number);
  const from = `${y}-${String(m).padStart(2, "0")}-01`;
  const last = new Date(Date.UTC(y!, m!, 0)).getUTCDate();
  return { from, to: `${y}-${String(m).padStart(2, "0")}-${String(last).padStart(2, "0")}`, label: `${MON[m! - 1]} ${y}` };
}

export function shiftMonth(day: string, n: number): string {
  const [y, m] = day.split("-").map(Number);
  const t = new Date(Date.UTC(y!, m! - 1 + n, 1));
  return t.toISOString().slice(0, 10);
}

export function weekday(day: string): number {
  return new Date(day + "T00:00:00Z").getUTCDay();
}

export type RangePreset = "today" | "7d" | "this_month" | "last_month" | "custom";
/** Report ranges; at most 93 days (the database refuses longer ones). */
export function presetRange(p: RangePreset, today: string): { from: string; to: string } {
  if (p === "today") return { from: today, to: today };
  if (p === "7d") return { from: addDays(today, -6), to: today };
  if (p === "last_month") { const m = monthOf(shiftMonth(today, -1)); return { from: m.from, to: m.to }; }
  const m = monthOf(today);
  return { from: m.from, to: today };
}
export const MAX_RANGE_DAYS = 93;
