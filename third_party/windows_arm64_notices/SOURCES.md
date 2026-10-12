# Windows ARM64 binary sources and notices

This directory is included in the ARM64 application bundle. The media-kit
wrapper's MIT license is included separately. Microsoft runtime files are
distributed from Visual Studio's ARM64 release CRT, with a per-file hash and
version manifest in the application root.

## libmpv

- Binary provider and build recipes:
  https://github.com/media-kit/libmpv-win32-video-cmake
- Release and architecture:
  https://github.com/media-kit/libmpv-win32-video-cmake/releases/tag/20241021
- Build recipe at the release tag:
  https://github.com/media-kit/libmpv-win32-video-cmake/tree/8ddbe5472465950b87853789f7173f2eedc5586a
- Binary archive: `mpv-dev-aarch64-20241021-git-0f78584.7z`
- Archive SHA-256:
  `d445d02ab2ee60b1b5988f08ce4d2394cdcc594e98321b746a313313e96133ae`
- mpv source commit identified by the binary's release name:
  https://github.com/mpv-player/mpv/tree/0f7858451817c5fd5ebdb74a807a7c997662c390
- Source archive:
  https://github.com/mpv-player/mpv/archive/0f7858451817c5fd5ebdb74a807a7c997662c390.tar.gz
- FFmpeg source and licensing:
  https://git.ffmpeg.org/ffmpeg.git
  https://ffmpeg.org/legal.html

The bundled MPV/Copyright and GPL/LGPL texts come from the identified mpv
source revision. libmpv incorporates FFmpeg and other dependencies; their
build configuration is maintained by the binary provider above. These source
links and notices do not assert a separate legal review of every dependency.

## ANGLE

- Binary provider:
  https://github.com/mmozeiko/build-angle/releases/tag/2026-10-11
- Archive: `angle-arm64-2026-10-11.zip`
- Archive SHA-256:
  `15a036bcd95022e64f8fcaddd8e492b978d7deb1afb22c77deda40755026fa97`
- Source commit declared by that release:
  https://github.com/google/angle/tree/34ffa963ca9cb3d40617ebf144c4cfb671701d68
- Source archive:
  https://github.com/google/angle/archive/34ffa963ca9cb3d40617ebf144c4cfb671701d68.tar.gz

ANGLE/LICENSE, AUTHORS, DEPS and the included third-party notices are copied
from that exact source revision. DEPS records upstream dependency references.
The Microsoft D3D compiler library is part of the binary provider's package.
