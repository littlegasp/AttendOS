# Company data retention and deletion (Pilot 01)

Status: **process written; deletion script tested locally** (dry run, refusals, real deletion on a copy of the
demo database and on a copy with the real Supabase Auth schema — the other company's rows, logins, sessions and
identities were byte-for-byte unchanged). **Not yet run on a hosted project.** Deleting live data needs the
pilot company's written instruction and the owner's explicit approval. This is a process description, not legal
advice; the pilot company decides what it must keep for its own legal duties.

## 1. Roles
- **The pilot company** decides why its staff data is collected and how long it is kept, and instructs deletion.
- **The AttendOS owner** runs the service, keeps the data only for providing it, and carries out the company's
  written instructions. Nobody at the pilot company gets Supabase or Cloudflare access.

## 2. What AttendOS holds for a company, and how long
| Data | Where | Kept while the company uses AttendOS | After the pilot ends |
|---|---|---|---|
| Company settings, offices, shifts, holidays, departments, designations, leave types | `public` tables | Yes | Deleted with the company (§4) |
| Employees (name, work e-mail, phone, role, manager, dates) | `public.employees` | Yes, including people who left (history) | Deleted |
| Attendance: check-ins/outs, exact point (once per check-in/out), distance, accuracy, refused attempts, corrections | `public.attendance_*` | Yes | Deleted |
| Leave requests, balances, adjustments | `public.leave_*` | Yes | Deleted |
| Rosters, shift assignments, remote-work days, invitations | `public.*` | Yes | Deleted |
| Activity log (who changed what) | `public.audit_log` | Yes — append-only in normal operation: no one using the app, of any role, can change or delete an entry | Removed only by the approved company-deletion procedure (§4), after the export |
| Logins (e-mail, password hash, sessions) | Supabase Auth (`auth` schema) | While the person has a login | Deleted (§4 step 5) |
| CSV / PDF exports | HR's devices | The company's responsibility | The company deletes its copies |
| Owner's `pg_dump` copies | Owner's encrypted storage | 30 days each (export register below) | Deleted within 30 days |
| Supabase backups / PITR | Supabase | Daily backups 7 days on Pro; PITR window as configured | Expire on their own; the data is fully gone when the last backup taken before the deletion has expired |
| Supabase / Cloudflare logs | Providers | Short, plan-dependent | Expire on their own |

Not collected: ID numbers, dates of birth, family details, bank details, photos, background location.

**Agree before day 1 (01-DEPLOYMENT-CHECKLIST F4a):** how long data is kept after the pilot (suggested: export
within 7 days of the end, deletion within 30 days of the end unless the company asks to continue), and who at
the company may ask for exports or deletion.

## 3. Exports
- In the app: HR/Admin export the register and reports as CSV (their own company only — enforced by the
  database). Managers export only their team, employees only their own.
- Full company export (owner, on the company's written request): the company's rows from each table as CSV
  (SQL editor → run → download), or a `pg_dump` filtered to the company. Hand over by an agreed secure channel.
- **Export register** (owner keeps it): date, company, what, why, who received it, where the owner's copy is
  stored, the file's SHA-256, and the date the owner's copy was deleted.

## 4. Deleting a company (end of pilot or on request)
1. **Instruction:** written request from the company's authorised person (name, date, company slug). Owner's
   approval recorded.
2. **Final export** (§3) delivered and acknowledged — including the Activity log, which is the company's audit
   evidence of who did what. Record the SHA-256 of each file in the deletion record.
3. **Stop use:** the Admin switches all staff off (or the owner does it), then the owner ends their sessions
   (05-ROLLBACK.md §4.2).
4. **Dry run:** `supabase/deploy/delete_company.sql` with the slug and `DRY RUN`. Check the company name, id and
   counts; confirm the count of logins to delete. Nothing changes.
5. **Delete:** same script with the company id and `DELETE <slug>`. In one transaction it removes the company's
   rows from all 21 tables — including its Activity log entries, the one deliberate exception to the log being
   append-only; the database owner switches the protection off for that transaction only and it is back on before
   commit (tested) and its logins in Supabase Auth (with their
   sessions and identities). It compares **every other company's** row counts before and after and rolls
   everything back if anything outside this company changed. E-mails are unique across AttendOS and every
   login belongs to exactly one employee record, so no other company's login can be selected.
6. **Evidence:** save the result grid (counts per table, "other companies before/after", time). Then run
   `verify_hosted.sql` and `check_auth_links.sql` (all true / ok) and save those results too.
7. **Backups and copies:** note the date when the last Supabase backup containing the company expires (deletion
   date + backup retention, or + PITR window) and delete the owner's `pg_dump` copies (export register).
8. **Deletion record** sent to the company: company, slug, id, instruction date, export file hashes, deletion
   time, the per-table counts, the backup expiry date, and the owner's signature. Keep it — it contains no
   personal data, so it can be kept after the data is gone.

## 5. Not built (pilot)
- Deleting or anonymising **one person's** data from inside the app (people who leave are switched off and their
  history is kept for the company's records). A person's request is handled by the company; if the company
  instructs deletion of one person, the owner does it by hand with a reviewed script — ask before the pilot if
  this is expected.
- Automatic deletion after a set period. Deletion is a deliberate, approved, owner-run step.
