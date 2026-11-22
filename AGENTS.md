# BobTV release requirements

- Routine releases stay on `1.3.m+n`. Increment `m` for each release and keep `n` cumulative across the entire 1.3 series, including repeat official build attempts. One aligned multi-platform build batch consumes one shared build number. Do not reset `n` when `m` changes. A larger minor or major version is reserved for a substantial feature release.
- Published numbering anchors are `1.3.0+0` and `1.3.1+1`. Record subsequent consumed build numbers in `docs/release-build-ledger.json` before an official build. Treat the published 1.4.1 numbering as a migration case: existing clients reject a numerically lower version, so verify the chosen transition path before changing public feeds.
- Commit and push every application source change to the remote main branch before building any official release. Verify that the exact frozen release commit is already present on remote main; a local-only commit or an uncommitted working tree cannot be released.
- Local development builds and isolated tests may precede the push, but they are not official release artifacts. After integration changes, rebuild and retest the exact committed source before publication.
- Every official release must publish Windows x64/ARM64, macOS Intel/Apple Silicon, and Android ARM32/ARM64/x64 with the same semantic version and base build number.
- Build all platforms from the same application source commit. Keep platform-specific packaging transformations documented.
- Do not substitute a previous platform binary or update feed when another platform advances. An incomplete platform matrix blocks official publication.
- Platform build jobs may generate intermediate metadata with `--staging`. This output is not a complete official release.
- Before publication run `python tools/verify_release_alignment.py PACKAGES VERSION --android-build-tools SDK_BUILD_TOOLS` and complete each platform's existing native/package/signature checks.
- Update GitHub assets, checksums, homepage, downloads, four locales and all seven update feeds together. Wait for mirror success and verify public downloads before reporting completion.
