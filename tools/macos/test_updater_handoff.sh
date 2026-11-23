#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture="$(mktemp -d "$HOME/Library/Application Support/BobTVUpdaterHandoffTest.XXXXXX")"
player='';installer=''
cleanup() {
  [[ -z "$player" ]] || kill "$player" 2>/dev/null || true
  [[ -z "$installer" ]] || kill "$installer" 2>/dev/null || true
  rm -rf "$fixture"
}
trap cleanup EXIT
create_app() {
  local target="$1" marker="$2"
  mkdir -p "$target/Contents/MacOS" "$target/Contents/Resources/AirPlay/bobtv-airplay"
  cp /usr/bin/true "$target/Contents/MacOS/BobTV"
  for name in bobtv-airplay fpsap-auth; do
    cp /usr/bin/true "$target/Contents/Resources/AirPlay/bobtv-airplay/$name"
    codesign --force --sign - "$target/Contents/Resources/AirPlay/bobtv-airplay/$name" >/dev/null 2>&1
  done
  for pair in 'CFBundleIdentifier string com.briconbric.bobtv' 'CFBundleExecutable string BobTV' 'CFBundlePackageType string APPL' 'CFBundleShortVersionString string 0.9.3' 'CFBundleVersion string 1'; do
    /usr/libexec/PlistBuddy -c "Add :$pair" "$target/Contents/Info.plist"
  done
  printf '%s' "$marker" > "$target/Contents/Resources/version-marker"
  /usr/bin/openssl rand -out "$target/Contents/Resources/payload" 1100000
}
package="$fixture/Package/BobTV.app"
create_app "$package" new
assets="$package/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/updater"
mkdir -p "$assets"
cp assets/updater/mac-updater-handoff-v1 "$assets/"
# An independently signed future worker proves the actual exec and inherited
# lock. It otherwise runs the unmodified production installation implementation.
python3 - "$assets/mac_worker.sh" <<'PY'
from pathlib import Path
import sys
s=Path('assets/updater/mac_worker.sh').read_text()
s=s.replace('[[ -z "$run_id"', '''if /usr/bin/lockf -t 0 "$root/update.lock" true; then exit 98; fi
printf executed > "$root/new-worker-executed"
[[ -z "$run_id"''', 1)
Path(sys.argv[1]).write_text(s)
PY
helper="$package/Contents/Resources/Updater/BobTVUpdateProgress.app"
mkdir -p "$helper/Contents/MacOS"
cp /usr/bin/true "$helper/Contents/MacOS/BobTVUpdateProgress"
cp tools/macos/update_progress_info.plist "$helper/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.9.3' "$helper/Contents/Info.plist"
codesign --force --sign - "$helper" >/dev/null 2>&1
framework="$package/Contents/Frameworks/App.framework"
cp /usr/bin/true "$framework/App"
for pair in 'CFBundleIdentifier string com.briconbric.fixture.app' 'CFBundleExecutable string App' 'CFBundlePackageType string FMWK'; do
  /usr/libexec/PlistBuddy -c "Add :$pair" "$framework/Resources/Info.plist"
done
codesign --force --sign - "$framework"
codesign --force --sign - "$package"
codesign --verify --deep --strict "$package"
/usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out "$fixture/signing.pem"
ditto -c -k --norsrc --keepParent "$package" "$fixture/good.zip"
/usr/bin/openssl dgst -sha256 -sign "$fixture/signing.pem" -out "$fixture/signature.der" "$fixture/good.zip"
signature="$(/usr/bin/base64 < "$fixture/signature.der" | tr -d '\n')"
curl() { printf download >> "$root/download-count"; cp "$BOBTV_TEST_ARCHIVE" "$partial"; }
export -f curl
for scenario in good corrupt; do
  root="$fixture/$scenario/Update";app="$fixture/$scenario/BobTV.app"
  mkdir -p "$root"
  create_app "$app" old
  codesign --force --sign - "$app" >/dev/null 2>&1
  export BOBTV_TEST_ARCHIVE="$fixture/$scenario.zip"
  if [[ "$scenario" == corrupt ]]; then cp "$fixture/good.zip" "$BOBTV_TEST_ARCHIVE"; printf x >> "$BOBTV_TEST_ARCHIVE"; fi
  /usr/bin/openssl pkey -in "$fixture/signing.pem" -pubout -out "$root/update-signing-public.pem"
  digest="$(/usr/bin/openssl dgst -sha256 "$BOBTV_TEST_ARCHIVE")";bytes="$(stat -f%z "$BOBTV_TEST_ARCHIVE")"
  result=0;watched=99999999
  if [[ "$scenario" == good ]]; then sleep 60 & player=$!;watched="$player";fi
  bash assets/updater/mac_worker.sh update "$root" "$app" "$watched" '0.9.3+1' \
    'https://bobtv.briconbric.com/updates/files/handoff.zip' "${digest##* }" "$bytes" "$signature" &
  installer=$!
  if [[ "$scenario" == good ]]; then
    for ((attempt=0;attempt<30;attempt++)); do
      if [[ -f "$root/status.json" ]] && grep -q '"phase":"ready"' "$root/status.json"; then break;fi
      kill -0 "$installer" || { cat "$root/worker.log";exit 1; }
      sleep 1
    done
    [[ -f "$root/new-worker-executed" && "$(cat "$app/Contents/Resources/version-marker")" == old && ! -e "$root/candidate.txt" ]]
    grep -q '"phase":"ready"' "$root/status.json"
    kill "$player";wait "$player" 2>/dev/null || true;player=''
  fi
  wait "$installer" || result=$?;installer=''
  if [[ "$scenario" == good ]]; then
    [[ "$result" == 0 && -f "$root/new-worker-executed" && "$(cat "$root/download-count")" == download &&
       "$(cat "$app/Contents/Resources/version-marker")" == new && -f "$root/candidate.txt" ]] || {
      cat "$root/worker.log";exit 1;
    }
    [[ "$(grep -c 'handing off to verified updater' "$root/worker.log")" == 1 ]]
    backup="$(sed -n '2p' "$root/candidate.txt")"
    [[ "$(cat "$backup/BobTV.app/Contents/Resources/version-marker")" == old ]]
  else
    [[ "$result" == 8 && ! -e "$root/new-worker-executed" && ! -e "$root/candidate.txt" &&
       "$(cat "$app/Contents/Resources/version-marker")" == old ]] || { cat "$root/worker.log";exit 1; }
  fi
  echo "PASS: $scenario updater handoff"
done
