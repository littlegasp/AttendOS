/**
 * Everything that makes one company's copy look like their own system.
 * Each company gets its own copy of AttendOS (own database, own address); to set one
 * up, change this file and drop their logo in public/ — nothing else names a company.
 *
 * Colours: only the accent is branded. Status colours (present/late/absent…) stay the
 * same for every company so they always mean the same thing.
 */
export interface Brand {
  /** Company name, used in page titles and sign-in. */
  company: string;
  /** What the app is called for this company (shown in the menu and browser tab). */
  appName: string;
  /** Small line under the name in the menu. */
  tagline: string;
  /** Logo file in public/, e.g. "/logo.png". Leave empty to use the built-in mark. */
  logo: string;
  /** Accent colour for buttons, active menu item and highlights, per theme. */
  accent: { dark: string; light: string; darkSoft: string; lightSoft: string };
  /** Who staff contact for access problems. */
  supportContact: string;
}

export const BRAND: Brand = {
  company: "AttendOS",
  appName: "AttendOS",
  tagline: "Attendance & Workforce",
  logo: "",
  accent: { dark: "#FF7A00", light: "#F97316", darkSoft: "#FFB366", lightSoft: "#FDBA74" },
  supportContact: "your HR team",
};

const HEX = /^#[0-9a-fA-F]{6}$/;

/** CSS that applies the brand accent over the default tokens (validated, so a typo can't break the page). */
export function brandCss(b: Brand = BRAND): string {
  const { dark, light, darkSoft, lightSoft } = b.accent;
  if (![dark, light, darkSoft, lightSoft].every((c) => HEX.test(c))) return "";
  const ring = (hex: string, a: number) => {
    const n = parseInt(hex.slice(1), 16);
    return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
  };
  return (
    `html[data-theme="dark"]{--color-primary:${dark};--color-secondary:${darkSoft};--active-bg:${ring(dark, 0.14)};--ring:0 0 0 3px ${ring(dark, 0.35)};--ambient-a:${ring(dark, 0.1)}}` +
    `html[data-theme="light"]{--color-primary:${light};--color-secondary:${lightSoft};--active-bg:${ring(light, 0.1)};--ring:0 0 0 3px ${ring(light, 0.3)};--ambient-a:${ring(light, 0.08)}}`
  );
}
