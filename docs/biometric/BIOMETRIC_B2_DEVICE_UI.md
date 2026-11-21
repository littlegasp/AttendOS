# Biometric Phase B2 — Device management UI (demonstration data)

Status: **implemented and locally tested with mock data.** *Since B4 (21 Nov 2026) a connected app shows the company's
real records in these screens (BIOMETRIC_B4_UI_REPORT.md); the demonstration below applies to preview mode only.* No migration, database function, gateway, Sync Agent,
adapter, SDK or device connection. Nothing deployed. Branch `feature/biometric-b1`.

## Where it lives
- Menu: **Configuration → Biometric Devices** (`/biometric`), between Departments and Roles & Permissions.
- Access: new capability `biometric` — Admin and HR; Manager and Employee get Permission denied and no menu item.
- Every screen shows the banner "Demonstration data — no biometric device, Sync Agent or gateway is connected".
  Connection states read "Online · demo", "Offline · demo", etc.; hardware actions (Test connection, Sync now, Retry)
  are visible but disabled with the phase that builds them.

## Screens (tabs share the existing tab pattern; device detail is `/biometric?device=<id>`)
| Screen | Contents |
|---|---|
| Overview | Total, online, offline/error, need attention, last successful sync, unmatched punches; devices needing attention; recent sync runs; Sync Agents |
| Devices | Search (name/model/serial), filters (manufacturer, status, office), table on desktop/tablet, cards on phones, empty states |
| Device detail | Device information, office, connection (method, IP/port or push authentication, last seen/sync, clock drift with the 5-minute flag), Sync Agent, mapping configuration (direction mode, device-specific codes), sync history, error history; disable/enable with confirmation |
| Add device wizard | 8 steps: manufacturer → device → office → method (only methods documented for that manufacturer) → connection (office-network IPs only; push authentication choice) → Sync Agent → direction → review; validates each step; saves a sample device as "Not connected" |
| Employee mapping | Unmapped codes (from the review queue) with "Map this code"; mappings with employee status, scope (company-wide / device), validity; end mapping; history |
| Sync activity | Runs with received, stored, confirmed duplicates, possible duplicates, unmatched, rejected, errors and retry status; filters |
| Review queue | Unmatched codes, ambiguous direction, possible duplicates, punches after an HR correction, invalid/suspicious times; actions per type; history per item (who, when, note) |

## Mock data (`src/lib/biometric-mock.ts`)
- `DemoState = { agents, devices, mappings, mappingHistory, syncs, reviews, errors, seq }`, shapes following
  BIOMETRIC_DATABASE_SCHEMA.md. Seed: 2 agents (online/offline), 5 devices (ZKTeco ×2, eSSL ×2, Matrix ×1; online,
  offline, error, disabled; clock drift over the limit), 9 sync runs (completed, partly stored, failed, retrying,
  duplicates), 8 review items (all five types, one resolved), 6 device errors.
- **People and offices are not invented when connected:** they are read (read-only) from `people_directory` and
  active `locations`; mappings point at real employees by exact id. In preview mode (no database) labelled sample
  people/offices are used.
- All actions run through one local reducer (see "Review corrections" below for the rules). State lives in the
  browser tab; reload or "Reset sample data" restores it; "Show the empty module" shows the first-time screens.

## Review corrections (20 Nov 2026)
**Mapping scope.** Device-specific is the default: a mapping is `(device, code) → employee` with `validFrom`/`validTo`.
Codes are not assumed unique — the seed re-uses 101–103 on Main entrance and Plant shop floor for different people.
Company-wide (`deviceId = null`) is an explicit Admin-only option that needs a confirmation tick. Resolution for a
punch: the device's own mapping in force at the punch time, otherwise a company-wide mapping in force then, otherwise
unmatched. Ending a mapping sets `validTo` (reason required, kept in history); earlier punches stay with the same
person. Code 107 on Main entrance shows a re-used code (former employee, a gap, then a new person); the "Who had this
code?" card shows the rule for any device, code and moment.

**Conflicts before saving** (`mappingConflicts`, shown live under "Before you save"; Save stays disabled while any
blocks): *blocks* — empty or invalid code, no employee, employee not in the company, switched-off employee, the same
code on the same scope in an overlapping period, the same person with a different code on the same device in an
overlapping period; *notices* — a company-wide mapping this device mapping overrides, devices that keep their own
mapping over a new company-wide one, a general company-wide warning, waiting punches the mapping will attribute (at
their original time) and waiting punches earlier than the effective date (stay unmatched).

**Review safeguards.** Raw punches are frozen objects (`RawPunch`) and never edited; decisions only append to the
item's history (who · role, when, decision, reason). Each kind has its own decisions; a decided item cannot be decided
again; Accept time as recorded, Dismiss and Not a duplicate need a reason (≥ 5 characters). Every decision dialog
states its effect. Each item shows employee (name, employee code, device code), device (name, serial), original device
time (device clock and zone), received time, reason and status.

**Roles.** Capabilities in `src/lib/permissions.ts`: `biometric` (view; Admin, HR), `manageBiometricDevices`
(Admin), `mapBiometricCodes` (Admin, HR), `mapBiometricCompanyWide` (Admin), `reviewBiometric` (Admin, HR),
`retryBiometricSync` (Admin, HR). The reducer calls `assertAllowed(role, action)` before every action and throws for
a role without the capability, so hiding buttons is only a convenience. Manager and Employee get the existing
permission-denied page and no menu item.

**Demonstration wording.** The banner (with Reset / Show the empty module) stays at the top of every tab; every dialog
ends with "Demonstration: only this browser tab changes. Nothing is sent to a device or saved to the database."; toasts
say "demonstration — not saved" / "recorded in this demonstration only".

**Phones.** The tab bar (shared `Tabs`, wrapped in `.bio-tabs`) scrolls sideways with edge fades and a › hint; the
selected tab is scrolled fully into view without moving the page; `overflow-y: hidden` on the bar so vertical
scrolling over it scrolls the page (it previously captured a 1-pixel vertical scroll). Long names wrap (`.bio-wrap`);
device names are limited to 60 characters.

## Final verification for sign-off (20 Nov 2026)
Defects found by the verification and fixed (logic only, no visual redesign):
- A back-dated **End mapping** or a back-dated **new mapping** could silently move a punch that had already been
  processed (attributed, reviewed or dismissed) to a different person. Both are now blocked before saving
  (`reassignedPunches`, `endMappingConflicts`) with the reason and the latest affected device time; the reducer enforces
  the same rule. Only open *unmatched* punches are picked up by a new mapping (that is their purpose).
- A decision on a review item that no longer exists returned silently; it now refuses with a message.
- `pgrst.log` (a local PostgREST error log, no data) was committed by mistake in `36fb13a`; removed and ignored.

Sign-off script `e2e/biometric_b2_signoff.py`: role matrix observed in the interface for each role, a full Admin
session with every action while recording every network request, every public table fingerprinted (row count + content
hash) before and after, and a 1440 / 820 / 390 px × light / dark matrix (tabs, device detail, three dialogs,
dropdowns, vertical scroll, empty module).

**What enforces permissions in B2.** The demonstration reducer (`assertAllowed`) refuses every action for a role
without the capability, and the unit tests prove it. This runs in the browser, so it is application-logic
enforcement, not security: B2 has no server actions to protect because nothing is saved. From B3 the same capabilities
must be enforced by the database functions (BIOMETRIC_SECURITY.md §5).

## Tests
- `tests/biometric.test.ts` (17; 4 sign-off tests added: no silent reassignment of processed punches, effective
  dates, repeated/invalid actions and no state mutation, every decision × role with actor/role/time/reason): menu and permission matrix; the reducer refusing every action for Manager/Employee
  and device configuration / company-wide codes for HR; device-specific codes; attribution by punch time (re-used code
  107); device-over-company-wide precedence with effective dates; conflict blocks and notices; company-wide
  confirmation; mapping resolving only covered punches with the raw record unchanged; review decisions (valid set,
  reason, decided once, history appended, raw unchanged); device name/serial; empty module; source scan (no table
  writes, no network calls, no hard-coded colours).
- `e2e/biometric_b2.py` (101 browser checks since the corrections; adds HR (b2) limits, conflicts panel,
  company-wide confirmation, "who had this code", ending a mapping, review context, demonstration wording, empty
  module and reset, loading and error states, 390-px tab bar (reach every tab, fades, vertical scroll), 70-character
  employee names and a 60-character device name, other screens still load. Original 40 checks, local demo stack): access, search/filters/empty state, device detail,
  disabled hardware actions, disable confirmation, wizard validation (public IP refused), mapping (no employee → refused,
  overlap refused), sync states, review actions and history, dark/light, phones/tablet without sideways scrolling,
  no console errors, **database unchanged** and **no write requests**.
- Existing: app checks 48/48 (35 + 13), database 360/360, browser regression 29/29.
