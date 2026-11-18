import type { IconName } from "@/lib/nav";

/** Line icons. Decorative: a text label always sits beside them or is read out when hidden. */
const P = {
  width: 20,
  height: 20,
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.8,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
  "aria-hidden": true,
};

const PATHS: Record<IconName, React.ReactNode> = {
  dashboard: <><rect x="3.5" y="3.5" width="7" height="8" rx="2" /><rect x="13.5" y="3.5" width="7" height="5" rx="2" /><rect x="13.5" y="11.5" width="7" height="9" rx="2" /><rect x="3.5" y="14.5" width="7" height="6" rx="2" /></>,
  clock: <><circle cx="12" cy="12" r="8.5" /><path d="M12 7.5V12l3 2" /></>,
  register: <><rect x="4" y="3.5" width="16" height="17" rx="2.5" /><path d="M8 8h8M8 12h8M8 16h5" /></>,
  people: <><circle cx="9" cy="8.5" r="3.2" /><path d="M3.5 19.5a5.5 5.5 0 0 1 11 0" /><circle cx="17" cy="9.5" r="2.5" /><path d="M16 14.2a4.5 4.5 0 0 1 5 4.8" /></>,
  leave: <><rect x="3.5" y="5" width="17" height="15" rx="2.5" /><path d="M3.5 9.5h17M8 3.5v3M16 3.5v3M9 14.5l2 2 4-4" /></>,
  shift: <><path d="M4 12a8 8 0 0 1 13.7-5.6L20 8.5" /><path d="M20 4v4.5h-4.5" /><path d="M20 12a8 8 0 0 1-13.7 5.6L4 15.5" /><path d="M4 20v-4.5h4.5" /></>,
  holiday: <><path d="M12 3.5v2M12 18.5v2M3.5 12h2M18.5 12h2M6 6l1.4 1.4M16.6 16.6 18 18M6 18l1.4-1.4M16.6 7.4 18 6" /><circle cx="12" cy="12" r="3.8" /></>,
  report: <><path d="M6 3.5h8l4 4v13H6z" /><path d="M14 3.5v4h4M9 13h6M9 16.5h6" /></>,
  analytics: <><path d="M4 20V10M10 20V4M16 20v-7M21 20H3" /></>,
  department: <><rect x="4" y="3.5" width="16" height="17" rx="2" /><path d="M8 7.5h2M14 7.5h2M8 11.5h2M14 11.5h2M10 20.5v-4h4v4" /></>,
  shield: <><path d="M12 3.5 19 6v5.5c0 4.3-3 7.7-7 9-4-1.3-7-4.7-7-9V6z" /><path d="m9 12 2 2 4-4" /></>,
  gear: <><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z" /></>,
};

export function NavIcon({ name }: { name: IconName }) {
  return <svg {...P}>{PATHS[name]}</svg>;
}

export const IconSearch = () => <svg {...P}><circle cx="11" cy="11" r="6.5" /><path d="m20 20-4.2-4.2" /></svg>;
export const IconBell = () => <svg {...P}><path d="M6 16.5V11a6 6 0 1 1 12 0v5.5l1.5 2H4.5zM10 20.5a2.2 2.2 0 0 0 4 0" /></svg>;
export const IconSun = () => <svg {...P}><circle cx="12" cy="12" r="4.2" /><path d="M12 2.5v2.2M12 19.3v2.2M2.5 12h2.2M19.3 12h2.2M5.3 5.3l1.6 1.6M17.1 17.1l1.6 1.6M5.3 18.7l1.6-1.6M17.1 6.9l1.6-1.6" /></svg>;
export const IconMoon = () => <svg {...P}><path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z" /></svg>;
export const IconFold = ({ open }: { open: boolean }) => <svg {...P}><rect x="3.5" y="4.5" width="17" height="15" rx="3" /><path d="M9 4.5v15" />{open ? <path d="m15.5 10-2 2 2 2" /> : <path d="m13.5 10 2 2-2 2" />}</svg>;
export const IconMenu = () => <svg {...P}><path d="M4 7h16M4 12h16M4 17h16" /></svg>;
export const IconClose = () => <svg {...P}><path d="M6 6l12 12M18 6 6 18" /></svg>;
export const IconChevron = () => <svg {...P} width={16} height={16}><path d="m9 6 6 6-6 6" /></svg>;
export const IconCheck = () => <svg {...P} width={16} height={16}><path d="m5 12.5 4.5 4.5L19 7.5" /></svg>;
export const IconAlert = () => <svg {...P}><path d="M12 4 2.8 19.5h18.4z" /><path d="M12 10v4.5M12 17h.01" /></svg>;
export const IconLock = () => <svg {...P}><rect x="5" y="10.5" width="14" height="10" rx="2.5" /><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5" /></svg>;
export const IconInbox = () => <svg {...P}><path d="M4 13.5 6.5 5h11l2.5 8.5V19a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 19z" /><path d="M4 13.5h4.5l1.5 2.5h4l1.5-2.5H20" /></svg>;
export const IconUser = () => <svg {...P}><circle cx="12" cy="8.5" r="3.8" /><path d="M4.5 20a7.5 7.5 0 0 1 15 0" /></svg>;
export const IconMore = () => <svg {...P}><circle cx="5.5" cy="12" r="1.4" /><circle cx="12" cy="12" r="1.4" /><circle cx="18.5" cy="12" r="1.4" /></svg>;
export const IconInfo = () => <svg {...P}><circle cx="12" cy="12" r="8.5" /><path d="M12 11v5M12 8h.01" /></svg>;
export const IconX = () => <svg {...P}><circle cx="12" cy="12" r="8.5" /><path d="m9 9 6 6M15 9l-6 6" /></svg>;
