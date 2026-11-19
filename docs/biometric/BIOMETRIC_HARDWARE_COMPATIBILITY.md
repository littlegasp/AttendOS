# Biometric hardware compatibility (Phase B1)

**No device has been tested. Nothing on this page is "hardware-verified".** Statuses:
`documented` (an official or manufacturer-published source describes the method) · `third-party claim` (only
integrators or resellers say so) · `mock-tested` · `hardware-verified` (model + firmware tested by us, with date).

## ZKTeco
| Item | Finding | Status |
|---|---|---|
| Pull SDK | ZKTeco **Standalone SDK** (Windows DLL `zkemkeeper`, COM; samples in C#/VB), device on the LAN, TCP port **4370** by default. Published by ZKTeco on GitHub (github.com/ZKTeco/Standalone-SDK). Requires registering the DLL on the agent PC (32/64-bit). | documented |
| Push | **PUSH SDK / ADMS**: HTTP protocol where the device connects to a configured server (`/iclock/cdata` for handshake and attendance logs, `/iclock/getrequest` for commands). ZKTeco publishes a "General Introduction of PUSH SDK Protocol"; T&A and access-control firmware differ. | documented (protocol document seen via a distributor copy; full spec to be obtained from ZKTeco) |
| Models | ADMS support listed for many models (e.g. SpeedFace, ProFace X, SenseFace, MB160, F22, iClock series); per model and firmware. | documented (lists vary by source) |
| Direction | Attendance log carries a state field on many models; whether staff press keys is site-dependent. | to verify |
| Log capacity / overwrite | Per model. | to verify on hardware |
| Unofficial libraries | Reverse-engineered TCP 4370 clients exist (Python, Node.js). **Not used** without an owner decision. | n/a |
| Agent required | Yes for SDK pull (LAN). For ADMS: agent as local push server (recommended); direct to cloud only after D6. | — |

## eSSL (India)
| Item | Finding | Status |
|---|---|---|
| Relation to ZKTeco | Integrators report many eSSL models (e.g. AiFace range, K990, X990, uFace 302, F22, iFace 102, MB160) run the ZKTeco platform and speak the same ADMS push protocol. | third-party claim — confirm per model with eSSL |
| Push | ADMS ("Cloud server" setting on the device). | third-party claim |
| Vendor software | **eTimeTrackLite** (eSSL's bundled Windows T&A software) — an agent could read its export/database if eSSL documents it. | to obtain documentation |
| Pull SDK | Likely the ZKTeco Standalone SDK on ZK-platform models. | to verify per model |
| Agent required | Yes (same as ZKTeco). | — |

## Matrix (COSEC)
| Item | Finding | Status |
|---|---|---|
| Device API | Matrix publishes a **COSEC Devices Push API Guide** (device-level API, events can be pushed to a third-party server) and states "API integration at three levels — function, platform and device". | documented (Matrix-published PDF) |
| Platform | **COSEC Web API 2.0** (on COSEC CENTRA) for third-party apps; database-to-database integration (MS SQL / Oracle) and export templates; COSEC INTEGRATE can export device event logs to a database. | documented |
| Models | ARGO, VEGA, PATH and others; per model and firmware. | to verify |
| Agent required | Yes for device push into the LAN; or the agent reads COSEC CENTRA's Web API / integration database where the company already runs it. | — |

## Other manufacturers
Only through the same adapter contract, after official documentation is obtained.

## Recommended first hardware (decision D9)
1. One **eSSL or ZKTeco ADMS-capable** fingerprint/face machine (most common in Indian offices) — tests both the
   local-push adapter and, if the model supports it, the Standalone SDK pull adapter.
2. Matrix COSEC later, when a customer has one and Matrix's API documentation is in hand.
Needed from the owner: model name, firmware version (device "System info" screen), whether it is already connected
to any software, and the vendor's SDK/API documents if supplied with the machine.

## Test record (filled in during B5/B7)
| Date | Manufacturer | Model | Firmware | Method | Records | Offline test | Duplicate test | Drift test | Result | Tester |
|---|---|---|---|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — | — | — | — | — |
