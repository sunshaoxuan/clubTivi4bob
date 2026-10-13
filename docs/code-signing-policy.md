# Code signing policy

Status: SignPath integration prepared; Foundation approval and production
credentials are pending. Existing published installers are unchanged and do not
gain Windows trust from this document. Candidate builds are labeled separately.

## Maintainers and signing approval

- Author/committer: [sunshaoxuan](https://github.com/sunshaoxuan).
- Reviewer: [sunshaoxuan](https://github.com/sunshaoxuan).
- Signing approver: [sunshaoxuan](https://github.com/sunshaoxuan).

The maintainer authorizes the release source and each production signing request.
Account multi-factor authentication is required by the Foundation. No approval
or certificate is assumed before the application has been reviewed.

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
