# Windows legacy crash monitor retirement

Date: 2026-10-24, Asia/Tokyo. Target: SUNSX-PC, BobTV 1.1.10+103.

## Applied scope

- Disabled the app-scoped scheduled tasks `Hotel TV Crash Monitor` and `BobTV-CrashMonitor-Test86` after exporting their XML.
- Stopped only the old monitor PowerShell process and its app-local ProcDump process.
- Replaced the monitor script with an inert compatibility entry point.
- Patched the installed portable and managed updater assets and the existing staged updater cache. Updates, rollbacks and failure finalizers no longer retain or execute monitor restart logic.
- Kept the scoped stop helper for obsolete processes that may remain during a future upgrade.
- Updated x64 and ARM64 packaging to overlay the inert shim when reusing an older support bundle. The historical manual installation helper no longer restarts the monitor.
- Preserved installed EXE, AOT payload and Flutter runtime hashes. The in-process crash handler and startup registration are unchanged.
- Did not delete crash records or ProcDump binaries, change playback preferences, or publish a new release.

## Verification

- Eight regression runs passed on Windows PowerShell 5.1 and PowerShell 7: update helpers, retired monitor, portable startup rollback, and managed update/rollback.
- Managed tests intercepted Setup launch. No real Setup installation or player launch occurred.
- The additional packaging-overlay regression passed under both Windows shells and local PowerShell.
- A native GUI-subsystem observer ran on the logged-in desktop, session 4. WinEvent hooks and window enumeration detected zero new visible console windows during ten controlled child-process checks.
- Checks included three installed shim executions, three executions of the actual BOM-staged updater's startup-monitor mode, and native healthy/synthetic-crash probes.
- The native probe compiled the unchanged crash handler, used isolated LOCALAPPDATA, and generated startup/shutdown records, an exception record with `result=written`, and a valid MDMP dump.
- No media or audio was opened.

The first desktop fixture incorrectly executed the raw Flutter asset directly with Windows PowerShell 5.1. That UTF-8 asset is staged by the client with a BOM before execution. The fixture reported a parser error, with zero new visible console windows. It was corrected to use the actual staged path, and all ten checks passed. The failed receipt was retained.

## Recovery and evidence

Verified original scripts and task XML are preserved at:

    C:\Users\sunsx\AppData\Local\HotelTV\Update\Backups\legacy-monitor-retirement-20261024

Local evidence:

    outputs/BobTV-legacy-monitor-retirement-20261024

Receipts: `deploy-v2-receipt.json`, `tests-receipt.json`, `desktop-tests-v2.json`, `packaging-validation.json` and `final-check-receipt.json`. Both temporary desktop observer tasks are removed after acceptance.

## Boundaries

The original Windows host is patched immediately. Repository source contains the fix for subsequent builds; public 1.1.10 packages have not been replaced. Installed playback, full interactive app startup and a host reboot were not performed. Window checks cover the retired monitor and updater startup paths, without making guarantees about unrelated applications.
