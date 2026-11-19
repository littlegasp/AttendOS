# Pilot 01 — what is done, tested and pending (19 Nov 2026)

| Mark | Meaning |
|---|---|
| **DONE** | Written and committed to `phase-4-5` (code, migration, script or document). |
| **LOCAL** | Tested on this machine: PostgreSQL 16, PostgREST, the real Supabase Auth server, the real app build in Chrome. |
| **HOSTED** | Tested on the hosted Supabase (Mumbai) + Cloudflare project. **Nothing is HOSTED yet.** |
| **PENDING** | Not done yet; needs the owner's approval and/or the hosted project, real e-mail or real phones. |

Nothing has been deployed, no hosted migration has run, no live company exists, no production credential has been
created or changed, and `phase-4-5` is not merged into `main`.

| Item | Done | Local | Hosted | Notes |
|---|---|---|---|---|
| Migrations 0001–0008 | DONE | LOCAL — database suites (360 checks in all, with 0009) | PENDING | 01 §B |
| Migration 0009 (link on reactivation, defect fix) | DONE | LOCAL — 4 new database checks; 26/26 invitation edge cases; 36/36 sign-in flows | PENDING | 01 §B row 9 |
| `verify_hosted.sql` | DONE | LOCAL (row 9 needs hosted Auth role) | PENDING | detects 0009 present/missing |
| `create_pilot_company.sql` | DONE | LOCAL | PENDING | 01 §E |
| `check_auth_links.sql` / `relink_logins.sql` | DONE | LOCAL — restored-without-link and link-to-deleted-login repaired | PENDING | 05 §2.4 |
| `delete_company.sql` | DONE | LOCAL — demo copy and real-Auth copy; other company unchanged (fingerprint + counts) | PENDING | 07 §4; test company T in 03 §12.5 |
| Auth settings, hook, SMTP, templates | DONE (documented) | LOCAL (same settings on the Auth server) | PENDING | 02 §2–4 |
| Invitations: send, expiry, re-invite, changed e-mail, duplicate, linked, other company | DONE | LOCAL — 26/26 | PENDING | 03 §2, 2b |
| Session ending by SQL (no secret key) | DONE (documented) | LOCAL — refresh token refused after | PENDING | 05 §4.2 |
| Key rotation, DB password reset, JWT key rotation | DONE (documented from Supabase docs) | — (Supabase dashboard only) | PENDING (only if needed) | 05 §4.1 |
| Whole-database restore / restore to new project | DONE (documented) | — (Supabase feature) | PENDING — rehearse once (01 A5) | 05 §2.1–2.2 |
| Office check independent of the map provider | DONE | LOCAL — OpenStreetMap blocked; forged far call refused | PENDING (03 4.9) | 02 §7 |
| GPS on real phones | — | Simulated in Chrome only | PENDING | 03 §4 |
| Real e-mail delivery | — | Local mail catcher only | PENDING | 03 §1–2 |
| Front-end build without secret key | DONE | LOCAL — build scan clean | PENDING | 01 D4 |
| Data retention agreement with the pilot company | DONE (template) | — | PENDING | 07 §2 |
| Daily summary table (larger companies) | Requirement only | — | — | docs/requirements/DAILY-SUMMARY.md |

Local results on the final commit: database 360/360, real sign-in flows 36/36, invitation edge cases 26/26,
browser regression 29/29, app checks and build passing.
