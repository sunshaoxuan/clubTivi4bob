#!/bin/bash
set -euo pipefail
app="${1:?Pass the compiled BobTV.app}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
sources=()
flutter_sdk="${FLUTTER_ROOT:?Flutter SDK root is required}"
flutter_framework="$flutter_sdk/bin/cache/artifacts/engine/darwin-x64-release/FlutterMacOS.xcframework/macos-arm64_x86_64"
while IFS= read -r source; do sources+=("$source"); done < <(
  find "$root/third_party/media_kit_video/macos/Classes/plugin" -name '*.swift' -type f
)
swiftc -O "${sources[@]}" "$root/tools/macos/test_native_video_disposal.swift" \
  -F "$flutter_framework" -F "$app/Contents/Frameworks" \
  -framework FlutterMacOS -framework Mpv -framework OpenGL -framework CoreVideo \
  -I "$root/third_party/media_kit_video/macos/Headers" \
  -import-objc-header "$root/tools/macos/video_disposal_bridge.h" \
  -Xlinker -rpath -Xlinker "$app/Contents/Frameworks" \
  -o "$test_dir/native-video-disposal-test"
"$test_dir/native-video-disposal-test"
