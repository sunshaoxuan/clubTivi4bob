# Windows updater and region navigation fixes

## Scope and source

Local repair branch `fix/windows-update-region`, based on the clean 1.1.14 release
source `582a5b8`. The older `work/bobtv-site-catalog` checkout contains extensive
uncommitted work and was not modified. Both supplied screenshots were materialized
on the Mac and visually inspected. No version bump, push, binary publication,
production catalog mutation, or deployment was performed.

## Findings and changes

Automatic startup and manual retry both enter `WindowsUpdateService.checkNow`.
Neither download worker previously retried a failed connection. Both now use the
same bounded retry helper, reset partial-transfer counters, recreate the partial
file for each attempt and explicitly permit TLS 1.2 for Windows PowerShell.
Persistent failure remains a failure after three attempts. URL restrictions,
size/hash checks, publisher signature checks and consent requirements remain.
The original first-download failure cannot be attributed conclusively without
its Windows worker/launcher logs; transient connectivity and legacy TLS remain
possible causes, not proven incident diagnoses.

A confirmed portable-worker defect left a `ready` receipt when the target version
was already installed: it returned without publishing `installed`. That path now
requires the exact version and app data, then publishes completion. A newer or
incomplete installation is not misreported as the requested successful update.
The Dart observer and independent progress window reread receipts after observing
worker exit to avoid rejecting a final receipt published between two reads.
The progress window adds an explicit close button/Escape, and custom button text
painting retains white text even while launch is disabled. Launch still checks
receipt identity, version, worker ID and installed application data. Successful
completion still closes automatically after 20 seconds.

Mainland region navigation previously used full category paths, so Shanghai/news
and Shanghai/finance appeared as separate regions. Known province paths now map
to their province for navigation while the original stored group remains intact.
The database candidate query includes those province descendants; regression tests
verify that all matching channels remain visible and unrelated provinces do not.
Only known region labels are collapsed. Custom manual paths remain stored.

Machine classification removes programme-type descendants beneath a confirmed
region, and retains country/media structure for international stations and known
radio regions. Programme-type evidence remains in decision metadata. Unknown
geography stays pending. Both continuous and batch application paths enforce the
rule; existing manual data is not bulk deleted or migrated.

## Validation on the selected Mac

- Final Flutter run: 72 passed, 1 existing preview test skipped. Includes region
  projection, real SQLite membership, manual paths, updater exit/authorization
  polling, update feedback/tile, classifier, compact menu, manifest validation,
  and shared catalog service tests.
- Python: 26 passed across catalog taxonomy, automatic taxonomy worker and batch
  reclassification tests. Includes manual-change protection, publication rollback,
  unknown geography, radio geography and programme-type decision metadata.
- PowerShell recovery logic: transient failures recover; persistent failures stop
  after three attempts; successful transfer runs once; exact installed no-op emits
  completion; missing app data/newer version rejects completion.
- All three changed updater PowerShell scripts parse successfully.
- Dart analysis of the original four focused files found no issues. Expanded
  analysis including database.dart reports 12 pre-existing informational brace
  style findings on unchanged lines, with no errors or warnings.
- `git diff --check` passes.

Logs from this task: `/tmp/bobtv-final-regression.log`,
`/tmp/bobtv-final-analyze.log`, `/tmp/bobtv-region-db-regression.log`.
Python test environment: `/tmp/bobtv-fix-tests-20261027`.

## Remaining native verification

No Windows executor was used. Windows PowerShell 5.1 runtime compilation and native
painting of the custom button, actual UAC cancellation/repeated clicks, real setup
installation/rollback and the final window close/launch flow remain unverified.
The existing Windows native UI and installer fixtures can be run when Windows QA
is authorized. These source changes have not been packaged into a new release,
and cannot repair updater scripts already running on the affected installation.
