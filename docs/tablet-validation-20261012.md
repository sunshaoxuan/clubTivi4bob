# Tablet development validation, 2026-10-12

Initial development snapshot for test version 1.1.0+93, recorded before
publication. Existing desktop apps were left running. Subsequent publication
and final delivery checks are recorded in
[1.1.0 publication validation](releases/1.1.0-validation.md).

## Automated checks

- Final Flutter suite: 387 passed, 8 skipped. Includes two independent local
  HTTP clients exchanging metadata, weights, retirements and channel merges.
- Website Python suite: 124 passed; one existing Starlette/httpx deprecation
  warning.
- Website download-menu suite: 2 passed. Unpublished platforms never create
  phantom download buttons; old desktop assets remain available.
- Full static analysis: no errors, 224 informational/warning findings.
- Network audit: 140 Dart files, zero unguarded public constructors. Native
  playback uses the website gateway; no direct public fallback is enabled.
- Live read-only gateway test: GOOD TV yielded 65,536 media bytes through
  three server hops; CCTV-1 yielded 65,536 bytes through two. Private upstream
  origins were rejected. Logo index had 1,836 entries at the time of testing.
- Portable C++ aspect-ratio fixture passed landscape, portrait, 4:3,
  ultrawide, 4K and invalid-dimension cases.
- PowerShell syntax and PE fixtures passed native ARM64/x64 detection,
  rejection of mixed root DLLs, and malformed executable rejection. The
  installer/build scripts parsed successfully without running a native build.
- Newly added platform modules passed focused static analysis with no findings.
- Android surface ownership regression checks prevent manually enabling
  `vo=gpu` before the native Surface exists.

## Signed Android artifacts

Final APKs are in `outputs/BobTV-tablet-test-93/android-packages-final` outside
the source repository. All three were validated with Android `apksigner`,
`aapt`, `zipalign` and ELF load-header checks. Minimum API is 24; target API is
36; application ID is `com.briconbric.bobtv`; label is BobTV. Signing and
password files were excluded from the package and repository.

| APK | Bytes | SHA-256 |
| --- | --- | --- |
| android-arm64 | 43,069,298 | `a82332569c232d5723cee6855aac3e0d2237a99c23f84db55f1bdaba8a364ddb` |
| android-arm | 40,400,874 | `99e0209c1d1015bcd8ea3e81324936a734e1e5aa99f47933c5d50ee2a1209df5` |
| android-x64 | 48,104,144 | `57893c324a4f203ad3fd2613e9ec2ce8e9bad360c7b985e508c0ca2d916bac4f` |

Publisher certificate SHA-256:
`163f6e8d1474816420774d24ac3c08e7b5ac5d00759d65e0d2c1e517684bb714`.

ARM64 and x64 native libraries have at least 16 KiB ELF load alignment. All
APKs pass 16 KiB ZIP native alignment. ARM32 sqlite3 uses 4 KiB alignment;
the ARM32 package is separate from the ARM64 package. Exact architecture APK
updates retain Flutter's ABI-specific Android version-code prefixes. The
in-app installer compares actual package version codes and publisher signatures.

Update metadata and SHA256SUMS were finalized locally for all three APKs.
No production Android feed has been exposed or tested on a device.

## Surface ARM dependency inspection

The ARM64 libmpv and ANGLE archives match their pinned SHA-256 values. The
loaded `libmpv-2.dll`, `libEGL.dll`, `libGLESv2.dll` and `d3dcompiler_47.dll`
all have ARM64 PE machine `0xAA64`. ANGLE source commit:
`34ffa963ca9cb3d40617ebf144c4cfb671701d68`.

The installed Flutter SDK's matching Windows ARM64 Dart artifact responded
HTTP 200. Flutter selects Windows build architecture from its native Dart
host. Build scripts explicitly require that runtime and reject x64 output.
Native application compilation, installer creation and actual ARM GPU/runtime
tests remain pending an ARM64 Windows host.

## Unperformed tests

- Xiaomi Pad APK installation, real audio/video, rotation, preview promotion,
  long-press interaction, PiP and system-confirmed update installation.
- Mainland China download speed and sustained gateway playback.
- Surface native compilation, setup installation, AirPlay helper emulation,
  native fullscreen/PiP and automatic update/rollback.
- Formal GitHub release, website deployment and public platform feed updates.

No GitHub Actions workflow was enabled. No installed Mac or Windows app was
replaced or restarted.
