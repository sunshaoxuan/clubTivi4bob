# Code signing policy

Status: The free SignPath Foundation application was submitted on 2026-10-13
and was not approved. The review email cited insufficient public trust and
visibility signals. No Foundation certificate or production credentials were
issued. Existing published installers are unchanged and do not
gain Windows trust from this document. Candidate builds are labeled separately.

Unsigned Windows x64 and ARM64 source builds and candidate packaging passed in
[manual validation run 38345860975](https://github.com/sunshaoxuan/clubTivi4bob/actions/runs/38345860975)
at source commit `7e89f136aeb71f122cfb4c8f768710de1c967270`.
No binary artifacts were uploaded by this validation run. This result does not
validate a production certificate or replace Surface hardware testing.

## Maintainers and signing approval

- Author/committer: [sunshaoxuan](https://github.com/sunshaoxuan).
- Reviewer: [sunshaoxuan](https://github.com/sunshaoxuan).
- Signing approver: [sunshaoxuan](https://github.com/sunshaoxuan).

The maintainer authorizes the release source and each production signing request.
Account multi-factor authentication is required by the Foundation. Any future
application requires a new review; no approval or certificate is assumed.

## Proposed signing provider

The application requests the free open-source programme. After approval, the
required attribution will be:

Free code signing provided by [SignPath.io](https://signpath.io), certificate by
[SignPath Foundation](https://signpath.org).

The certificate publisher is SignPath Foundation. BobTV remains the product
name. Its signing policy, eligibility and revocation rules are defined by the
[Foundation terms](https://signpath.org/terms.html).

## Verifiable build and signed scope

Only the `BobTV Windows Manual Code Signing` workflow is enabled. It accepts
manual dispatch on this repository's `main` branch, builds from checked-out
source on standard GitHub-hosted Windows runners, pins Flutter and action
revisions, and records source/build provenance. Push, pull-request, scheduled
test and automatic release workflows remain disabled.

The application and Setup are uploaded as separate GitHub artifacts before
SignPath signs them. App signing precedes Setup compilation, so the installer
contains the signed app. Metadata restrictions enforce BobTV's name and build
version. Production signatures require Windows trust-chain validation, a
timestamp and the approved publisher identity. Test-signed and unsigned outputs
must never be described or published as publicly trusted releases.

Only `BobTV.exe` and the BobTV Setup executable are signed by this project.
Unchanged third-party DLLs, runtimes and helper executables are not re-signed.
Their source/license notices are retained. The optional, proprietary Microsoft
ProcDump executable in older releases is excluded from free-signing candidates.
BobTV's native crash handler continues using the Windows DbgHelp system library.

## Publication and keys

The workflow stores review candidates for seven days and does not create a
release or change update feeds. Package hashes and BobTV's separate update
signatures must be generated again after Authenticode signing. Published release
assets are immutable; a newly signed build belongs to a new reviewed release.
The update-signing private key stays on the owner's Mac and is never placed in
the repository or GitHub workflow. The SignPath submitter token belongs in a
restricted GitHub Actions secret; it is not an approver credential.

See the [privacy policy](https://bobtv.briconbric.com/privacy) and
[Windows integration guide](windows-code-signing.md). Signing authenticates the
publisher and package; it does not guarantee that external streams are lawful,
available, or safe, and does not guarantee immediate SmartScreen reputation.
