#!/bin/bash
set -euo pipefail
repository="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:?Provide a new output directory}"
: "${BOBTV_ANDROID_KEYSTORE:?Set the private release keystore path}"
: "${BOBTV_ANDROID_STORE_PASSWORD:?Set the keystore password in the environment}"
: "${BOBTV_ANDROID_KEY_PASSWORD:?Set the key password in the environment}"
: "${BOBTV_ANDROID_KEY_ALIAS:?Set the release key alias}"
[[ -f "$BOBTV_ANDROID_KEYSTORE" && ! -L "$BOBTV_ANDROID_KEYSTORE" ]] || exit 2
[[ ! -e "$output" ]] || { echo 'Preserve the existing output directory' >&2; exit 2; }
cd "$repository"
version="$(rg '^version:' pubspec.yaml | awk '{print $2}')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]] || exit 3
"${BOBTV_FLUTTER:-flutter}" build apk --release --no-pub --split-per-abi \
  --target-platform android-arm,android-arm64,android-x64
mkdir -p "$output"
for entry in 'armeabi-v7a:arm' 'arm64-v8a:arm64' 'x86_64:x64'; do
  abi="${entry%:*}"
  architecture="${entry#*:}"
  cp "build/app/outputs/flutter-apk/app-$abi-release.apk" \
    "$output/BobTV-$version-android-$architecture.apk"
done
"${BOBTV_ANDROID_PYTHON:-python3}" tools/finalize_desktop_update_metadata.py \
  "$output" "$version" --platforms android-arm64 android-arm android-x64
shasum -a 256 "$output"/*.apk
