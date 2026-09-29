#!/bin/bash
set -euo pipefail

mode="${1:-}"
root="${2:-}"
app="${3:-}"
watched_pid="${4:-}"
version="${5:-}"
archive_url="${6:-}"
expected_hash="${7:-}"
expected_bytes="${8:-}"

if [[ "$root" != "$HOME/Library/Application Support/"* ||
      "$app" != *.app || "$app" == '/' ||
      ! "$watched_pid" =~ ^[1-9][0-9]*$ ]]; then
  exit 2
fi
if [[ ! -f "$app/Contents/MacOS/BobTV" ]]; then
  exit 2
fi
mkdir -p "$root"
if [[ "$mode" == 'update' ]]; then
  exec /usr/bin/lockf -t 0 "$root/update.lock" /bin/bash "$0" \
    update-locked "$root" "$app" "$watched_pid" "$version" \
    "$archive_url" "$expected_hash" "$expected_bytes"
fi
status="$root/status.json"
candidate="$root/candidate.txt"
marker="$root/startup.marker"
healthy="$root/startup.healthy"
skipped="$root/skipped_versions.txt"

write_status() {
  local phase="$1" shown_version="$2" percent="$3"
  printf '{"phase":"%s","version":"%s","percent":%s}\n' \
    "$phase" "$shown_version" "$percent" > "$status.tmp"
  mv -f "$status.tmp" "$status"
}

wait_for_exit() {
  local seconds=0
  while kill -0 "$watched_pid" 2>/dev/null; do
    sleep 2
    seconds=$((seconds + 2))
    if (( seconds >= 43200 )); then exit 3; fi
  done
}

team_id() {
  codesign -dv --verbose=4 "$1" 2>&1 |
    sed -n 's/^TeamIdentifier=\([A-Z0-9]*\)$/\1/p' | head -1
}

if [[ "$mode" == 'monitor' ]]; then
  wait_for_exit
  [[ -f "$candidate" ]] || exit 0
  candidate_version="$(sed -n '1p' "$candidate")"
  backup="$(sed -n '2p' "$candidate")"
  previous_attempts="$(sed -n '3p' "$candidate")"
  candidate_app="$(sed -n '4p' "$candidate")"
  [[ "$candidate_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ &&
     "$previous_attempts" =~ ^[0-2]$ &&
     "$candidate_app" == "$app" ]] || exit 4
  if [[ -f "$healthy" && "$(cat "$healthy")" == "$watched_pid" ]]; then
    rm -f "$candidate" "$healthy" "$marker"
    exit 0
  fi
  [[ -f "$marker" && "$(cat "$marker")" == "$watched_pid" ]] || exit 0
  attempts=$(( previous_attempts + 1 ))
  rm -f "$marker"
  if (( attempts < 3 )); then
    printf '%s\n%s\n%s\n%s\n' "$candidate_version" "$backup" \
      "$attempts" "$app" > "$candidate.tmp"
    mv -f "$candidate.tmp" "$candidate"
    exit 0
  fi
  [[ "$backup" == "$root/Backups/"* &&
     -d "$backup/BobTV.app" && -w "$(dirname "$app")" ]] || exit 4
  failed="$root/FailedApps/$candidate_version-$(date +%s)"
  mkdir -p "$failed"
  mv "$app" "$failed/BobTV.app"
  if ! mv "$backup/BobTV.app" "$app"; then
    mv "$failed/BobTV.app" "$app"
    exit 5
  fi
  printf '%s\n' "$candidate_version" >> "$skipped"
  printf '{"schema":1,"failedVersion":"%s"}\n' "$candidate_version" \
    > "$root/failure-${candidate_version//+/_}.json"
  rm -f "$candidate" "$healthy" "$marker"
  write_status failed "$candidate_version" 0
  exit 0
fi

[[ "$mode" == 'update-locked' ]] || exit 2
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ &&
   "$expected_hash" =~ ^[a-fA-F0-9]{64}$ &&
   "$expected_bytes" =~ ^[0-9]+$ ]] || exit 2
(( expected_bytes >= 1000000 && expected_bytes <= 2000000000 )) || exit 2
[[ "$archive_url" == https://bobtv.briconbric.com/updates/*.zip &&
   "$archive_url" != *'?'* && "$archive_url" != *'#'* ]] || exit 2
if [[ -f "$skipped" ]] && grep -Fxq "$version" "$skipped"; then exit 0; fi
[[ ! -f "$candidate" ]] || exit 0
trap 'code=$?; if (( code != 0 )); then write_status failed "$version" 0; fi' EXIT
[[ -w "$(dirname "$app")" ]] || exit 9

archive="$root/BobTV-${version//+/_}-macos.zip"
partial="$archive.part"
write_status downloading "$version" 0
curl --fail --silent --show-error --proto '=https' --max-redirs 0 \
  --connect-timeout 10 --max-time 14400 --output "$partial" "$archive_url"
[[ "$(stat -f%z "$partial")" == "$expected_bytes" ]] || exit 6
actual_hash="$(shasum -a 256 "$partial" | awk '{print tolower($1)}')"
expected_hash="$(printf '%s' "$expected_hash" | tr '[:upper:]' '[:lower:]')"
[[ "$actual_hash" == "$expected_hash" ]] || exit 6
mv -f "$partial" "$archive"

# The Mac archive has exactly one BobTV.app root; never extract another path.
unzip -tqq "$archive"
read -r entry_count _ expanded_bytes _ <<< "$(unzip -Z -t "$archive")"
[[ "$entry_count" =~ ^[0-9]+$ && "$expanded_bytes" =~ ^[0-9]+$ ]] || exit 7
(( entry_count <= 5000 && expanded_bytes <= 2000000000 )) || exit 7
while IFS= read -r entry; do
  [[ "$entry" == BobTV.app/* && "$entry" != *'../'* &&
     "$entry" != *'\'* && "$entry" != *//* ]] || exit 7
done < <(unzip -Z1 "$archive")

stage="$root/Stage/${version//+/_}-$$"
mkdir -p "$stage"
ditto -x -k "$archive" "$stage"
replacement="$stage/BobTV.app"
[[ -f "$replacement/Contents/MacOS/BobTV" ]] || exit 7
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$replacement/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$replacement/Contents/Info.plist")"
[[ "$short_version+$build_number" == "$version" ]] || exit 7
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$replacement/Contents/Info.plist")" == 'com.briconbric.bobtv' ]] || exit 7
machine_arch="$(uname -m)"
for binary in \
  "$replacement/Contents/MacOS/BobTV" \
  "$replacement/Contents/Resources/AirPlay/bobtv-airplay/bobtv-airplay" \
  "$replacement/Contents/Resources/AirPlay/bobtv-airplay/fpsap-auth"; do
  [[ -f "$binary" && " $(lipo -archs "$binary") " == *" $machine_arch "* ]] || exit 7
done
codesign --verify --deep --strict "$replacement"
spctl --assess --type execute "$replacement"
old_team="$(team_id "$app")"
new_team="$(team_id "$replacement")"
[[ -n "$new_team" ]] || exit 8
if [[ -n "$old_team" ]]; then
  [[ "$old_team" == "$new_team" ]] || exit 8
else
  # The first signed release may replace an earlier ad-hoc Mac test package.
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$app/Contents/Info.plist")" == 'com.briconbric.bobtv' ]] || exit 8
  codesign --verify --strict "$app"
  codesign -dv --verbose=4 "$app" 2>&1 | grep -Fxq 'Signature=adhoc' || exit 8
fi
write_status ready "$version" 100

wait_for_exit
[[ -w "$(dirname "$app")" ]] || exit 9
backup="$root/Backups/${version//+/_}-$(date +%s)-$$"
mkdir -p "$backup"
ditto "$app" "$backup/BobTV.app"
codesign --verify --deep --strict "$backup/BobTV.app"
old="$app.bobtv-previous-$$"
write_status installing "$version" 100
mv "$app" "$old"
if ! mv "$replacement" "$app"; then
  mv "$old" "$app"
  write_status failed "$version" 0
  exit 10
fi
printf '%s\n%s\n0\n%s\n' "$version" "$backup" "$app" > "$candidate.tmp"
mv -f "$candidate.tmp" "$candidate"
rm -rf "$old"
write_status ready "$version" 100
