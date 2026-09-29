#!/bin/bash
set -euo pipefail

mkdir -p "$HOME/Library/Application Support"
fixture="$(mktemp -d "$HOME/Library/Application Support/BobTVUpdaterTest.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
root="$fixture/Update"
app="$fixture/BobTV.app"
backup="$root/Backups/previous"
pid=99999999
version='0.9.2+1'
mkdir -p "$app/Contents/MacOS" "$backup/BobTV.app/Contents/MacOS"
printf 'new' > "$app/Contents/MacOS/BobTV"
printf 'old' > "$backup/BobTV.app/Contents/MacOS/BobTV"
printf '%s\n%s\n0\n%s\n' "$version" "$backup" "$app" > "$root/candidate.txt"

for expected in 1 2; do
  printf '%s' "$pid" > "$root/startup.marker"
  bash assets/updater/mac_worker.sh monitor "$root" "$app" "$pid"
  actual="$(sed -n '3p' "$root/candidate.txt")"
  [[ "$actual" == "$expected" ]] || exit 1
done

printf '%s' "$pid" > "$root/startup.marker"
bash assets/updater/mac_worker.sh monitor "$root" "$app" "$pid"
[[ "$(cat "$app/Contents/MacOS/BobTV")" == 'old' ]]
[[ "$(cat "$root/skipped_versions.txt")" == "$version" ]]
[[ ! -f "$root/candidate.txt" ]]

# A healthy startup clears the candidate without changing the installed app.
printf 'new' > "$app/Contents/MacOS/BobTV"
printf '%s\n%s\n0\n%s\n' '0.9.2+2' "$backup" "$app" > "$root/candidate.txt"
printf '%s' "$pid" > "$root/startup.healthy"
bash assets/updater/mac_worker.sh monitor "$root" "$app" "$pid"
[[ ! -f "$root/candidate.txt" ]]
[[ "$(cat "$app/Contents/MacOS/BobTV")" == 'new' ]]
