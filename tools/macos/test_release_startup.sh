#!/bin/bash
set -euo pipefail
app="${1:?Pass the release BobTV.app}"
arch="${2:?Pass x64 or arm64}"
[[ "$arch" == x64 || "$arch" == arm64 ]]
machine_arch="$(uname -m)"
expected='x86_64'
if [[ "$arch" == arm64 ]]; then expected='arm64'; fi
[[ "$machine_arch" == "$expected" ]]
[[ -f "$app/Contents/MacOS/BobTV" ]]
codesign --verify --deep --strict "$app"
for binary in "$app/Contents/MacOS/BobTV" \
  "$app/Contents/Resources/AirPlay/bobtv-airplay/bobtv-airplay" \
  "$app/Contents/Resources/AirPlay/bobtv-airplay/fpsap-auth"; do
  [[ " $(lipo -archs "$binary") " == *" $expected "* ]]
done
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")+$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]]
root="$HOME/Library/Application Support/com.briconbric.bobtv/Update"
mkdir -p "$root"
[[ ! -e "$root/candidate.txt" ]]
[[ ! -e "$root/startup.healthy" ]]
# A fresh runner uses a rollback candidate to exercise the real health monitor.
printf '%s\n%s\n0\n%s\n' "$version" "$root/Backups/smoke-previous" "$app" > "$root/candidate.txt"
"$app/Contents/MacOS/BobTV" > "$root/startup-smoke-console.log" 2>&1 &
app_pid=$!
trap 'kill -TERM "$app_pid" 2>/dev/null || true' EXIT
healthy=false
for (( attempt=0; attempt<90; attempt++ )); do
  kill -0 "$app_pid"
  if [[ -f "$root/startup.healthy" && "$(cat "$root/startup.healthy")" == "$app_pid" ]]; then
    healthy=true
    break
  fi
  sleep 1
done
[[ "$healthy" == true ]]
# Keep the native renderer alive beyond its first frame and initialization.
for (( attempt=0; attempt<20; attempt++ )); do kill -0 "$app_pid"; sleep 1; done
printf '{"version":"%s","architecture":"%s","startupHealthy":true,"pid":%s}\n' \
  "$version" "$expected" "$app_pid" > "$root/startup-smoke.json"
kill -TERM "$app_pid"
# Some GUI runners ignore TERM. Keep test cleanup bounded to this exact app.
for (( attempt=0; attempt<10; attempt++ )); do
  kill -0 "$app_pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$app_pid" 2>/dev/null; then
  echo 'The native startup check passed; force-stopping only the smoke-test app.'
  kill -KILL "$app_pid"
fi
wait "$app_pid" || true
for (( attempt=0; attempt<15; attempt++ )); do
  [[ ! -e "$root/candidate.txt" ]] && break
  sleep 1
done
[[ ! -e "$root/candidate.txt" ]]
[[ ! -e "$root/skipped_versions.txt" ]]
echo "Native $expected release $version acknowledged a healthy startup and cleared its rollback candidate."
