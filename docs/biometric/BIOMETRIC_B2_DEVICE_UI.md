# Biometric Phase B2 — Device management UI (demonstration data)

Status: **implemented and locally tested with mock data.** No migration, database function, gateway, Sync Agent,
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
- All actions run through one local reducer with the design rules: exact employee id only (never a name match),
  active employees only, no overlapping mapping for the same code and scope, one company-wide code per person,
  device-specific mapping wins over company-wide, ending a mapping keeps earlier punches with the same person,
  dismissing a review item needs a reason, duplicate serials refused. State lives in the browser tab; reload resets it.

## Tests
- `tests/biometric.test.ts` (9): permissions and menu, seed coverage, mapping rules, precedence, review history,
  device duplicate/serial, and a source scan proving no table writes, no network calls and no hard-coded colours.
- `e2e/biometric_b2.py` (40 browser checks, local demo stack): access, search/filters/empty state, device detail,
  disabled hardware actions, disable confirmation, wizard validation (public IP refused), mapping (no employee → refused,
  overlap refused), sync states, review actions and history, dark/light, phones/tablet without sideways scrolling,
  no console errors, **database unchanged** and **no write requests**.
- Existing: app checks 44/44 (35 + 9), database 360/360, browser regression 29/29.
