# Windows SignPath integration

This integrates the free Foundation programme; approval is external and pending.
The application was submitted on 2026-10-13 and the site confirmed receipt.
Both Windows CPU candidate jobs passed in
[manual validation run 38345860975](https://github.com/sunshaoxuan/clubTivi4bob/actions/runs/38345860975)
without retaining binary artifacts. Production signing remains disabled until
the Foundation approves the project and the configuration below is supplied.
Official references: [eligibility](https://signpath.org/terms.html),
[GitHub connector](https://docs.signpath.io/trusted-build-systems/github),
[artifact restrictions](https://docs.signpath.io/artifact-configuration/reference).

## Configuration after approval

Create project slug `bobtv`, connect GitHub.com as its trusted build system and
restrict it to `sunshaoxuan/clubTivi4bob`, `main`, and the signing workflow.
All jobs must use GitHub-hosted runners; local or self-hosted build uploads do
not satisfy the free programme's origin verification requirements.

Import `tools/signpath/bobtv-app.xml` as `bobtv-app` and
`tools/signpath/bobtv-setup.xml` as `bobtv-setup`. Configure `test-signing` and
`release-signing` policies. Production requests require the maintainer's manual
approval. GitHub App installation, if requested for audit access, needs an
explicit scope review and is limited to this repository.

Repository variables:

- `SIGNPATH_ORGANIZATION_ID`: organization identifier supplied by SignPath.
- `SIGNPATH_EXPECTED_PUBLISHER`: exact simple name of the approved public
  certificate, obtained from SignPath rather than guessed.
- `SIGNPATH_ARTIFACT_STORAGE_CONFIRMED_FREE`: set to `true` only after verifying
  that retaining this signing run's artifacts is within the account's available,
  non-billable storage. Without this confirmation, upload/signing fails closed.

Repository secret: `SIGNPATH_API_TOKEN`, restricted to submission. Never put it
in source, a chat, an artifact or a public log. Never use an approver token for
automatic submission. The current pipeline intentionally has no signing token
until enrollment succeeds.

## Candidate validation

Manual input `signing_mode=unsigned` builds from source without SignPath access,
removes the legacy proprietary dump helper and exercises privacy/installer
fixtures. By default this validation uploads no binary artifacts. The separate
`retain_unsigned_candidate` opt-in requires checking available artifact storage
before running; do not assume that free runner minutes imply unlimited storage.
Inputs support Windows x64 and ARM64, or both. ARM64 uses the existing
isolated cross-build adapter with verified SDK artifacts. CPU/AOT and Microsoft
CRT checks reject mixed architectures.

`test-signing` uses a test certificate and labels the artifact accordingly.
`release-signing` fails closed without enrollment, credentials and publisher
identity. It verifies the signed main executable, builds Setup from those
bytes, submits Setup for its own approved signature and checks both results.
The packaged ZIP uses normalized forward-slash member names.

The workflow has read-only repository/action permissions and no release-write
permission. Only standard runners are used. It does not raise billing budgets
or enable paid larger runners. Artifacts expire after seven days; inspect
account storage before repeatedly retaining candidates.

## Privacy and compatibility

Setup shows `PrivacyNotice.txt` before installation and offers a first-run
private-favorite backup choice. Application preferences take precedence on
later upgrades; switching backup off retains local favorites and prevents new
backup reads/uploads, even for forced retries. Re-enabling resumes normal
device-private synchronization. Existing releases retain their old behavior
until users install a new release containing these changes.

Program Files installation still needs Windows authorization. Foundation
signing does not replace administrator approval or BobTV's pinned update
signature. Regenerate the latter only after signing, on the owner's Mac, and
publish a new version rather than replacing already distributed release files.
