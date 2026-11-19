# Employee Documents — assessment and plan (not built)

**Recommendation:** build it as its own small phase after Phase 4 is approved. It needs a new table, a
private Storage bucket with its own access rules, an upload/download screen and a clean-up job — more than a
tweak to Phase 3, and it adds the most sensitive personal data AttendOS would hold.

## What it would do
A **Documents** tab on the employee profile: offer letter, contract, ID proof, certificates, exit papers.
HR/Admin upload and remove; the employee can see the documents HR marks as visible to them; managers see
nothing by default.

## Design
| Part | Plan |
|---|---|
| Files | Supabase Storage bucket `employee-documents`, **private** (no public URLs ever). Path `company_id/employee_id/<random-id>.<ext>` — no names or ID numbers in paths. |
| Records | Table `employee_documents`: `company_id` (default `my_company()`), `employee_id`, `category`, `title`, `storage_path`, `size_bytes`, `mime_type`, `visible_to_employee`, `expires_on`, `uploaded_by` (employee), `uploaded_at`. `check_company_refs`, `freeze_company_id`, audit trigger — same pattern as every Phase 3 table. |
| Who can do what | Row level security: HR/Admin of the same company read/add/remove; the employee reads their own rows where `visible_to_employee`; nobody else. Storage policies on `storage.objects` repeat the same rule from the path (`(storage.foldername(name))[1] = my_company()::text` and HR/Admin, or folder 2 = `my_employee_id()` with a visible row). |
| Downloads | Short-lived signed URLs (about 60 seconds) created per click; the file is never embedded or cached publicly. |
| Uploads | PDF, JPG, PNG only; size limit (e.g. 10 MB) set on the bucket and checked in the app. Supabase does not virus-scan files — note this to HR, or add a scanning step later. |
| ID documents | Store only what HR needs. For Aadhaar, accept **masked Aadhaar only** (last 4 digits visible), never the full number in a field. Confirm the company's exact obligations with its legal adviser. |
| Deleting | Removing a document deletes the Storage object too (database rows don't cascade into Storage, so this is done by a database function plus an Edge Function or scheduled clean-up). Retention after exit is a company setting (e.g. delete N months after the exit date). |
| Audit | Upload, visibility change and removal go into the existing audit log (append-only). Storage access is also in Supabase's logs. |
| Backups | Storage files are not part of the database point-in-time backup; decide backup expectations before go-live. |

## Tests it would need
Database: HR of company A cannot list or read B's documents or objects; an employee sees only their own
visible documents; a manager sees none; an exited employee sees none; paths outside `company/employee` are
refused. Real-stack check (like `supabase/authcheck`): upload, signed download, expired link refused,
delete removes the object. Requires a local Supabase Storage server or the real project.

## Effort
About one phase: 1 migration + storage policies, 1 profile tab with upload/list/download, clean-up job, tests,
docs. No change to attendance, roster or Phase 3 screens beyond adding the tab.
