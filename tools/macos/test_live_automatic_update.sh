#!/bin/bash
set -euo pipefail
arch="${1:?Pass x64 or arm64}"
version="${2:?Pass the expected website version}"
fixture_app="${3:-}"
close_during_download="${4:-false}"
[[ "${CI:-}" == true && "$arch" =~ ^(x64|arm64)$ ]]
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]]
site='https://bobtv.briconbric.com'
root="$HOME/Library/Application Support/com.briconbric.bobtv/Update"
app="$HOME/Applications/BobTV.app"
[[ ! -e "$root" && ! -e "$app" ]]
mkdir -p "$root" "$HOME/Applications"
fixture="$(mktemp -d)"
mount="$fixture/old-image"
mkdir -p "$mount"
if [[ -n "$fixture_app" ]]; then
  ditto "$fixture_app" "$app"
else
  curl --fail --silent --show-error --max-time 300 \
    "$site/downloads/BobTV-0.9.1+68-macos-$arch.dmg" -o "$fixture/old.dmg"
  hdiutil verify "$fixture/old.dmg"
  hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$fixture/old.dmg"
  ditto "$mount/BobTV.app" "$app"
  hdiutil detach "$mount"
fi
codesign --verify --deep --strict "$app"
app_version() {
  printf '%s+%s' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist")" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist")"
}
[[ "$(app_version "$app")" == '0.9.1+68' ]]
app_pid=''
stop_test_app() {
  [[ "$app_pid" =~ ^[1-9][0-9]*$ ]] || return 0
  kill -TERM "$app_pid" 2>/dev/null || true
  for ((n=0; n<10; n++)); do
    kill -0 "$app_pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -KILL "$app_pid" 2>/dev/null || true
}
trap stop_test_app EXIT
launch_test_app() {
  open -n --stdout "$root/live-update-console.log" \
    --stderr "$root/live-update-errors.log" "$app"
  app_pid=''
  for ((n=0; n<15; n++)); do
    app_pid="$(pgrep -x BobTV | while read -r found; do
      [[ "$(ps -p "$found" -o comm=)" == "$app/Contents/MacOS/BobTV" ]] && echo "$found"
    done | head -1 || true)"
    [[ "$app_pid" =~ ^[1-9][0-9]*$ ]] && return 0
    sleep 1
  done
  return 1
}
launch_test_app
echo "Launched previous app PID $app_pid; waiting for its own update discovery."
ready=false
closed_early=false
for ((n=0; n<300; n++)); do
  [[ "$closed_early" == true ]] || kill -0 "$app_pid"
  if [[ "$close_during_download" == true && "$closed_early" != true && -f "$root/status.json" ]] &&
      grep -q '"phase":"downloading"' "$root/status.json"; then
    stop_test_app
    closed_early=true
    echo 'Closed the player while the updater was downloading.'
  fi
  if [[ -f "$root/status.json" ]] && python3 - "$root/status.json" "$version" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
raise SystemExit(0 if data.get('phase') in ('ready','installed') and data.get('version') == sys.argv[2] else 1)
PY
  then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]]
[[ "$closed_early" == true || "$(app_version "$app")" == '0.9.1+68' ]]
echo 'Old application discovered and verified the update, without installing while running.'
stop_test_app
installed=false
for ((n=0; n<120; n++)); do
  if [[ -f "$app/Contents/Info.plist" && "$(app_version "$app")" == "$version" ]] &&
      { [[ -z "$fixture_app" ]] || grep -q '"phase":"installed"' "$root/status.json"; }; then
    installed=true; break
  fi
  sleep 1
done
[[ "$installed" == true && -f "$root/candidate.txt" ]]
if [[ -n "$fixture_app" ]]; then
  python3 - "$root/status.json" "$version" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
assert data['phase']=='installed' and data['version']==sys.argv[2],data
PY
  for ((n=0; n<20; n++)); do
    [[ -f "$root/progress-ui.log" ]] && grep -q window_shown "$root/progress-ui.log" && break
    sleep 1
  done
  grep -q window_shown "$root/progress-ui.log"
fi
backup="$(sed -n '2p' "$root/candidate.txt")"
[[ "$backup" == "$root/Backups/"* && "$(app_version "$backup/BobTV.app")" == '0.9.1+68' ]]
codesign --verify --deep --strict "$app"
launch_test_app
healthy=false
for ((n=0; n<120; n++)); do
  kill -0 "$app_pid"
  if [[ -f "$root/startup.healthy" && "$(cat "$root/startup.healthy")" == "$app_pid" ]]; then
    healthy=true; break
  fi
  sleep 1
done
[[ "$healthy" == true ]]
for ((n=0; n<20; n++)); do kill -0 "$app_pid"; sleep 1; done
printf '{"version":"%s","architecture":"%s","previousVersion":"0.9.1+68","discoveredByOldApplication":true,"installedAfterExit":true,"backupVerified":true,"startupHealthy":true}\n' \
  "$version" "$arch" > "$root/live-update-result.json"
echo "PASS: $arch old client discovered the website update, verified, installed $version after exit and acknowledged healthy startup."
