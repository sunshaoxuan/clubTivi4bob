#!/bin/bash
set -euo pipefail

# Builds the macOS-only AirPlay components and then embeds them in BobTV.app.
# Usage: tools/macos/build.sh /path/to/clean/fpsap-source

source_dir="${1:-}"
if [[ -z "$source_dir" || ! -d "$source_dir/.git" ]]; then
  echo 'Provide a clean FPSAP source checkout as the first argument.' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
expected='370f9db2e26b21b4a710bdba5d51012c1239e736'
if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$expected" ||
      -n "$(git -C "$source_dir" status --porcelain)" ]]; then
  echo 'FPSAP source must be the exact clean pinned revision.' >&2
  exit 2
fi

for command in flutter xcodebuild python3 go; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing build dependency: $command" >&2
    exit 2
  fi
done

venv="$root/build/airplay-macos-venv"
python3 -m venv "$venv"
"$venv/bin/python" -m pip install -r "$root/tools/airplay/requirements.txt"
"$venv/bin/python" -m PyInstaller --noconfirm --clean --onedir --console \
  --name bobtv-airplay --collect-all pyatv --recursive-copy-metadata pyatv \
  --distpath "$root/build/airplay-macos-dist" \
  --workpath "$root/build/airplay-macos-work" \
  --specpath "$root/build" "$root/tools/airplay/bobtv_airplay.py"

helper="$root/build/airplay-macos-dist/bobtv-airplay"
(
  cd "$source_dir"
  go mod download
  GOPROXY=off CGO_ENABLED=0 go build -trimpath \
    -o "$helper/fpsap-auth" "$root/tools/airplay/fpsap_auth.go"
  git archive --format=zip --output="$helper/fpsap-upstream-source.zip" "$expected"
)
cp "$root/tools/airplay/fpsap_auth.go" "$helper/"
cp "$root/tools/macos/build.sh" "$helper/build-macos.sh"
cp "$root/tools/airplay/AIRSPAN-LICENSE.txt" "$helper/"
for name in LICENSE COPYING.GPL-3.0 LICENSE.BlueOak-1.0.0 NOTICE.md; do
  cp "$source_dir/$name" "$helper/FPSAP-$name"
done

(
  cd "$root"
  flutter pub get
  flutter build macos --release
)
app="$root/build/macos/Build/Products/Release/BobTV.app"
if [[ ! -d "$app/Contents/MacOS" ]]; then
  echo 'BobTV.app was not produced.' >&2
  exit 1
fi
mkdir -p "$app/Contents/Resources/AirPlay"
mkdir -p "$app/Contents/Resources/Updater"
progress_app="$app/Contents/Resources/Updater/BobTVUpdateProgress.app"
mkdir -p "$progress_app/Contents/MacOS"
cp "$root/tools/macos/update_progress_info.plist" "$progress_app/Contents/Info.plist"
deployment='10.15'
[[ "$(uname -m)" == arm64 ]] && deployment='11.0'
xcrun swiftc -target "$(uname -m)-apple-macos$deployment" -O "$root/tools/macos/update_progress.swift" \
  -o "$progress_app/Contents/MacOS/BobTVUpdateProgress"
ditto "$helper" "$app/Contents/Resources/AirPlay/bobtv-airplay"
if [[ -n "${BOBTV_FFMPEG_BIN:-}" ]]; then
  if [[ ! -f "$BOBTV_FFMPEG_BIN" || ! -f "${BOBTV_FFMPEG_LICENSE:-}" ||
        ! -f "${BOBTV_FFMPEG_SOURCE:-}" ]]; then
    echo 'A bundled FFmpeg requires its executable, license and corresponding source archive.' >&2
    exit 2
  fi
  if otool -L "$BOBTV_FFMPEG_BIN" | grep -E '/(opt/homebrew|usr/local)/' >/dev/null; then
    echo 'FFmpeg depends on Homebrew libraries; provide a self-contained build.' >&2
    exit 2
  fi
  mkdir -p "$app/Contents/Resources/Tools"
  cp "$BOBTV_FFMPEG_BIN" "$app/Contents/Resources/Tools/ffmpeg"
  cp "$BOBTV_FFMPEG_LICENSE" "$app/Contents/Resources/Tools/FFMPEG-LICENSE.txt"
  cp "$BOBTV_FFMPEG_SOURCE" "$app/Contents/Resources/Tools/FFMPEG-SOURCE.zip"
fi
if [[ -n "${BOBTV_CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --sign "$BOBTV_CODESIGN_IDENTITY" \
    "$progress_app"
  if [[ -f "$app/Contents/Resources/Tools/ffmpeg" ]]; then
    codesign --force --options runtime --sign "$BOBTV_CODESIGN_IDENTITY" \
      "$app/Contents/Resources/Tools/ffmpeg"
  fi
  codesign --force --options runtime --sign "$BOBTV_CODESIGN_IDENTITY" \
    "$app/Contents/Resources/AirPlay/bobtv-airplay/fpsap-auth"
  codesign --force --options runtime --sign "$BOBTV_CODESIGN_IDENTITY" \
    "$app/Contents/Resources/AirPlay/bobtv-airplay/bobtv-airplay"
  codesign --force --deep --options runtime \
    --entitlements "$root/macos/Runner/Release.entitlements" \
    --sign "$BOBTV_CODESIGN_IDENTITY" "$app"
else
  codesign --force --sign - "$progress_app"
  # A local publisher-signed update still needs an internally valid app bundle.
  if [[ -f "$app/Contents/Resources/Tools/ffmpeg" ]]; then
    codesign --force --sign - "$app/Contents/Resources/Tools/ffmpeg"
  fi
  codesign --force --sign - \
    "$app/Contents/Resources/AirPlay/bobtv-airplay/fpsap-auth"
  codesign --force --sign - \
    "$app/Contents/Resources/AirPlay/bobtv-airplay/bobtv-airplay"
  codesign --force --deep --entitlements "$root/macos/Runner/Release.entitlements" \
    --sign - "$app"
fi
codesign --verify --deep --strict "$app"
echo "Built $app"
echo 'FFmpeg must be available at a supported system path for AirPlay transcoding.'
