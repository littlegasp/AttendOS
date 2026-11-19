# AttendOS — feature status (production-readiness pass, 19 Nov 2026)

Columns: **Built** = in the code. **Tested locally** = automated checks on this machine (PostgreSQL 16 +
PostgREST 12 + real Supabase Auth server v2.198.0 + Chrome). **Hosted verified** = checked on a real hosted
Supabase project — **nothing is yet, because no hosted project exists.** **Pending** = not built or needs a decision.

| Area | Built | Tested locally | Hosted verified | Pending / notes |
|---|---|---|---|---|
| Design system, shell, dark/light, phone layouts | ✓ | ✓ 208 screen loads (13 screens × 4 roles × 2 themes × desktop/phone): no console errors, no sideways scrolling | — | — |
| Sign-up for HR-added work e-mails (Auth hook) | ✓ | ✓ real Auth | — | Enable hook in hosted project |
| E-mail confirmation, resend, expired links | ✓ | ✓ real Auth, mail caught locally | — | Real SMTP delivery, templates |
| Sign-in, sign-out, session renewal/expiry | ✓ | ✓ real Auth (60 s tokens) | — | — |
| Password reset (signs out other devices) | ✓ | ✓ real Auth | — | — |
| **Employee invitations** (Send invite → one-time link → set password) | ✓ new | ✓ real Auth: correct company + record, no duplicates in 10 min, sender stays signed in | — | Branded invite wording in the e-mail template |
| Login ↔ employee linking (confirmed work e-mail only, never twice) | ✓ | ✓ DB tests + real Auth | — | — |
| Multi-company isolation | ✓ | ✓ security matrix: 21 tables × 6 users, all writes, 11 functions with other-company ids, catalog rules | — | Repeat a manual spot-check on hosted |
| Roles (Admin / HR / Manager / Employee) enforced in the database | ✓ | ✓ per-role scope checks | — | — |
| Audit log (append-only, real actor, sample-data marking) | ✓ | ✓ | — | — |
| GPS check-in/out: inside, outside, poor accuracy, denied, offline | ✓ | ✓ emulated GPS in Chrome + server checks | — | **Real phones (Android/iOS) in the pilot** |
| GPS read only on check-in/out (never on breaks, never in background) | ✓ | ✓ counted in the browser | — | — |
| Several offices, rostered office, remote exceptions | ✓ | ✓ | — | — |
| Shifts, breaks, overnight shifts, late/early/overtime | ✓ | ✓ DB tests | — | — |
| Weekly roster + date changes (per person; several people at once) | ✓ | ✓ | — | Bulk by department/group, shift templates |
| Holidays (all / per office) | ✓ | ✓ | — | Regional calendars import |
| Corrections (request, approve, reject, cancel) | ✓ | ✓ | — | — |
| Employees: add, edit, IDs, roles, exit, deactivate, reactivate | ✓ | ✓ DB + in-app | — | CSV import |
| Departments, designations (switch off, never delete) | ✓ | ✓ | — | — |
| Leave: types, apply (preview), approve, reject, cancel, record, adjust | ✓ | ✓ DB + in-app | — | Monthly accrual, carry-forward rules, attachments |
| Leave balances per leave year, calendar | ✓ | ✓ | — | — |
| Attendance Register (daily, monthly, person) + CSV | ✓ | ✓ CSV equals the filtered/permitted rows | — | Monthly grid capped at 5,000 rows |
| Reports (7) + CSV + Print/PDF | ✓ | ✓ CSV = database rows for the same scope; PDF shows report only | — | Scheduled / e-mailed reports |
| Analytics (4 charts with table views) | ✓ | ✓ | — | — |
| Roles & Permissions, user access, Settings General/Access | ✓ | ✓ | — | Custom roles |
| Performance | ✓ day calc 13× faster | ✓ measured to 600 people (docs/PERFORMANCE.md) | — | **Daily summary table before ~150+ people** |
| Notifications (e-mail/push on requests and decisions) | ✗ | — | — | Pending |
| Employee Documents | ✗ | — | — | Planned (docs/EMPLOYEE-DOCUMENTS.md) |
| In-app Help guide | ✗ | — | — | Pending |
| Map tiles / address search provider | ✓ (OpenStreetMap/Nominatim) | Tiles unreachable here; pins/radius work | — | Choose provider for production |
