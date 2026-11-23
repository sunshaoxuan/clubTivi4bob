# BobTV release requirements

- Public releases use `1.4.m`, with no plus sign or build suffix in screens, release notes, website or download filenames. Increment `m` for each release. Keep a cumulative internal native build counter for compatibility with existing update clients, including repeated official build attempts. A larger minor or major version is reserved for a substantial feature release.
- The user explicitly authorized 1.4.4 for the four currently public desktop variants only. Preserve all Android packages and feeds for this release.
- The imported build-counter baseline is `1.4.1+1`. Allocate each new build above every counter already recorded, and record every consumed build number in `docs/release-build-ledger.json` before starting an official build. Routine updates continue forward in the 1.4 series.
- Commit and push every application source change to the remote main branch before building any official release. Verify that the exact frozen release commit is already present on remote main; a local-only commit or an uncommitted working tree cannot be released.
- Local development builds and isolated tests may precede the push, but they are not official release artifacts. After integration changes, rebuild and retest the exact committed source before publication.
- Every official release must publish Windows x64/ARM64, macOS Intel/Apple Silicon, and Android ARM32/ARM64/x64 with the same semantic version and base build number.
- Build all platforms from the same application source commit. Keep platform-specific packaging transformations documented.
- Do not substitute a previous platform binary or update feed when another platform advances. An incomplete platform matrix blocks official publication.
- Platform build jobs may generate intermediate metadata with `--staging`. This output is not a complete official release.
- Before publication run `python tools/verify_release_alignment.py PACKAGES VERSION --android-build-tools SDK_BUILD_TOOLS` and complete each platform's existing native/package/signature checks.
- Update GitHub assets, checksums, homepage, downloads and all seven website locales together; verify all seven update feeds, preserving mobile feeds for an explicitly desktop-only release. Wait for mirror success and verify public downloads before reporting completion.

- Before finalizing a new desktop release, run `tools/canonicalize_desktop_release.py PACKAGES NATIVE_VERSION`. Public filenames and `displayVersion` use the semantic version only. Native update identities and compatibility aliases retain the internal build counter so installed clients can update.

- Playback tests must mute only through BobTV’s own volume controls. Never change system or Windows application mixer volume, and never add a test-only forced-mute switch to shipped code.

- At every release, audit all seven website locales and static fallback pages for stale feature-version badges. Omit version numbers from general feature copy. Required current-release labels must come from release metadata and match the published package; preserve accurate historical versions in dated release notes.
