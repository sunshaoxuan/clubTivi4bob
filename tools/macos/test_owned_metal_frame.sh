#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
framework_args=()
run_args=()
sources=("$root/third_party/media_kit_video/macos/Classes/plugin/OwnedMetalFrame.mm")
if [[ $# -gt 0 ]]; then
  framework_args=(-F "$1/Contents/Frameworks" -framework FlutterMacOS
    -Wl,-rpath,"$1/Contents/Frameworks")
  run_args=(--runtime)
  plugin="$1/Contents/Frameworks/media_kit_video.framework/media_kit_video"
  if [[ -f "$plugin" ]] && nm -gU "$plugin" | grep -q '_BobTVCreateOwnedMetalView'; then
    # Exercise the compiled plugin, including its actual dyld +load hook.
    sources=()
    framework_args+=(-framework media_kit_video)
    echo 'Testing the packaged media_kit_video Metal adapter.'
  fi
fi
clang++ -std=c++17 -fobjc-arc -framework Foundation -framework CoreVideo -framework Metal \
  "${framework_args[@]}" \
  "${sources[@]}" \
  "$root/tools/macos/test_owned_metal_frame.mm" -o "$test_dir/owned-metal-frame-test"
"$test_dir/owned-metal-frame-test" "${run_args[@]}"
