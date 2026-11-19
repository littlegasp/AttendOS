# Pilot 01 — verification checklist (hosted site)

Run on the hosted site after 01-DEPLOYMENT-CHECKLIST.md. Use real people and real phones. Record Pass/Fail,
the device/browser and a screenshot for anything that fails. Sections 1–4 must pass before day 1; the rest during
the first week.

People needed: **A** Admin, **H** HR, **M** a manager with 2+ reports, **E1/E2** employees (one Android, one iPhone),
**X** an outside test address that is not an employee. For section 12 a second test company **T** (created with
`create_pilot_company.sql`, deactivated after the test).

## 1. Admin setup
| # | Step | Expected | Result |
|---|---|---|---|
| 1.1 | A signs up at `/login?company=<slug>` with the Admin e-mail | Confirmation e-mail arrives in Inbox; link opens the Dashboard as Admin | |
| 1.2 | X tries "Create your login" with a private e-mail | "This e-mail isn't set up in AttendOS yet"; no account created | |
| 1.3 | A sets offices (map pin + radius), accuracy limit, weekly offs, time zone Asia/Kolkata | Saved; Activity log shows A as the actor | |
| 1.4 | A adds shifts, holidays, departments, designations, leave types | Saved; visible in pickers | |
| 1.5 | Settings → General: date format, half-day rule, leave year | Dates on screens follow the format | |

## 2. HR creation and invitations
| # | Step | Expected | Result |
|---|---|---|---|
| 2.1 | A adds H with role HR, presses **Send invite** | Toast "Invitation sent"; profile shows Invitation Sent | |
| 2.2 | A presses Send invite again at once | "Wait 10 minutes"; no second e-mail | |
| 2.3 | H adds M (role set by A), E1, E2 with work e-mails, departments, manager, office, shift | Employee IDs E000x; Sign-in "No login yet" | |
| 2.4 | H invites E1, E2, M | One e-mail each, Inbox | |
| 2.5 | H tries to give someone the Manager role | Refused (Admin only) | |

## 3. Password setup and sign-in
| # | Step | Expected | Result |
|---|---|---|---|
| 3.1 | E1 opens the invite on the phone | "Welcome — choose your password"; after saving, the Dashboard | |
| 3.2 | E1 signs out and signs in with the new password | Works; sign-out returns to `/login` | |
| 3.3 | E1 uses "Forgot password?" | Reset e-mail; new password works; old one doesn't; other devices signed out within the hour | |
| 3.4 | E1 opens the invite link a second time | "Link has expired or was already used" | |
| 3.5 | H's profile view of E1 | "Signs in with this e-mail", Invitation Accepted | |

## 4. Employee GPS check-in / check-out (each phone, outdoors and indoors)
| # | Step | Expected | Result |
|---|---|---|---|
| 4.1 | First Check In: browser asks for location | Prompt appears only after pressing Check In | |
| 4.2 | Deny the permission | "Location access is blocked" with how to allow; nothing recorded | |
| 4.3 | Inside the office area | Checked in; accuracy shown; Verification history (H) shows place and distance | |
| 4.4 | ~1 km away | Refused "outside the area"; attempt in Verification history | |
| 4.5 | Indoors far from windows | Either accepted or "accuracy too low" — note the accuracy shown (decide the limit) | |
| 4.6 | Airplane mode, press Check In | "Couldn't reach the server"; works after reconnecting | |
| 4.7 | Remote day (H sets a remote exception) | Check in from home accepted as Remote | |
| 4.8 | Check Out | Worked time correct; location read once | |

## 5. Breaks and shifts
| # | Step | Expected | Result |
|---|---|---|---|
| 5.1 | Start / End break | No location prompt; break time counted | |
| 5.2 | Check in after shift start + grace | Marked Late with minutes | |
| 5.3 | Leave before shift end | Early leaving shown | |
| 5.4 | Overnight shift person checks out after midnight | Counts on the shift's start date | |
| 5.5 | H changes one date in the roster (Office → Remote) | Employee sees it on My Attendance | |

## 6. Leave
| # | Step | Expected | Result |
|---|---|---|---|
| 6.1 | E1 applies for 2 days | Form shows days counted, balance, overlap warning if any; Pending | |
| 6.2 | M approves with a comment | Approved; E1's balance updated; day shows On leave | |
| 6.3 | E2 applies; M rejects without a reason | Asked for a reason; rejection saved with it | |
| 6.4 | E1 cancels approved future leave | Cancelled; days returned | |
| 6.5 | H records leave for someone and adjusts a balance (+1 with reason) | Approved at once "Recorded by HR"; adjustment in balance and Activity log | |
| 6.6 | E1 tries to check in on a full leave day | Refused with the reason | |

## 7. Attendance corrections
| # | Step | Expected | Result |
|---|---|---|---|
| 7.1 | E1 requests a missing check-out | Pending; appears for M and on the dashboard | |
| 7.2 | M approves | Corrected time added beside the original (original kept) | |
| 7.3 | E2 requests; H rejects with a note | Rejected; note visible to E2 | |

## 8. Attendance register
| # | Step | Expected | Result |
|---|---|---|---|
| 8.1 | H: Daily view, filter by department and status | Rows match the filter; times in IST | |
| 8.2 | Monthly grid | Letters match each person's days; totals right | |
| 8.3 | M opens the register | Only M's team | |
| 8.4 | Export CSV and open in Excel | Same rows/columns as on screen; Indian dates readable | |

## 9. Monthly reports and CSV
| # | Step | Expected | Result |
|---|---|---|---|
| 9.1 | H: Reports → This month: Summary, Employee-wise, Late, Overtime, Leave | Loads within ~5 s at pilot size; note the time | |
| 9.2 | Export CSV for Employee-wise; HR compares 5 people with their own records | Matches | |
| 9.3 | Print / PDF | Report only, readable on A4 | |
| 9.4 | M and E1 open Reports | Team only / own only; exports the same | |

## 10. Role permissions
| # | Step | Expected | Result |
|---|---|---|---|
| 10.1 | E1 types `/settings`, `/roles`, `/departments` | Permission denied pages | |
| 10.2 | M opens Employees | Own team only, read-only | |
| 10.3 | H opens Roles & Permissions | Not available (Admin only) | |
| 10.4 | A deactivates E2 while E2 is signed in | E2 is signed out on the next screen with "switched off"; E2's history kept; reactivate works | |
| 10.5 | H opens Activity log | Each change above with the right person | |

## 11. Mobile browsers
| # | Step | Expected | Result |
|---|---|---|---|
| 11.1 | Android Chrome and iPhone Safari: every screen the role can open | No sideways scrolling; bottom bar; menu | |
| 11.2 | Dark and light theme on both | Readable, consistent | |
| 11.3 | Slow network (3G) on My Attendance | Loading states; no double check-in when tapping twice | |

## 12. Company isolation (with test company T, then deactivate T)
| # | Step | Expected | Result |
|---|---|---|---|
| 12.1 | T's Admin signs in | Sees only T: no pilot people, offices, leave, reports, audit | |
| 12.2 | T's Admin opens a pilot employee's profile link | "This person isn't available" | |
| 12.3 | Pilot H searches for T's people | Nothing | |
| 12.4 | Run `verify_hosted.sql` again | All rows true | |

Sign-off: ____________________ (owner) ____________________ (pilot company HR) Date: __________
