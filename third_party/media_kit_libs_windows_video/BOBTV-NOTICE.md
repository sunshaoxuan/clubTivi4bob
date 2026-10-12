# BobTV Windows architecture isolation

This is the installed `media_kit_libs_windows_video` 1.0.11 source, licensed
under the included MIT LICENSE. The original x64 dependency pins are retained.
Only the `windows-arm64` branch loads `windows/bobtv_arm64.cmake`.

Pinned ARM64 dependencies, inspected on 2026-10-12:

| Component | Upstream binary | SHA-256 |
| --- | --- | --- |
| libmpv | [media-kit 20241021 ARM64 build](https://github.com/media-kit/libmpv-win32-video-cmake/releases/download/20241021/mpv-dev-aarch64-20241021-git-0f78584.7z) | `d445d02ab2ee60b1b5988f08ce4d2394cdcc594e98321b746a313313e96133ae` |
| ANGLE | [mmozeiko 2026-10-11 ARM64 build](https://github.com/mmozeiko/build-angle/releases/download/2026-10-11/angle-arm64-2026-10-11.zip) | `15a036bcd95022e64f8fcaddd8e492b978d7deb1afb22c77deda40755026fa97` |

The libmpv binary is distributed by the media-kit build project, which links
mpv and FFmpeg. Retain the applicable upstream GPL/LGPL notices and source
availability when redistributing a completed Windows ARM64 package. ANGLE is
BSD-licensed with third-party components. Its build includes Microsoft's
D3D compiler redistributable. Include the relevant license files and notices
when packaging the first verified native ARM64 release.

The binaries are fetched at build time, checked with SHA-256 and TLS, and
bundled into the app. End users do not fetch them from GitHub during playback.
No native ARM64 release has been compiled or hardware-tested as of this change.
