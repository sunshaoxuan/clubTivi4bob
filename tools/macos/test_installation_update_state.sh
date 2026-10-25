#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture="$(mktemp -d "$HOME/Library/Application Support/BobTVInstallationStateTest.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
legacy="$fixture/Update";app="$fixture/Applications/BobTV.app";other="$fixture/Other/BobTV.app"
mkdir -p "$legacy/Backups/previous/BobTV.app/Contents/MacOS" "$legacy/Backups/historical" "$app/Contents/MacOS" "$other/Contents/MacOS"
printf 'new-app' > "$app/Contents/MacOS/BobTV"
printf 'other-app' > "$other/Contents/MacOS/BobTV"
printf 'old-app' > "$legacy/Backups/previous/BobTV.app/Contents/MacOS/BobTV"
printf 'keep' > "$legacy/Backups/historical/keep.txt"
key="$(printf '%s' "$app" | /usr/bin/openssl dgst -sha256)";root="$legacy/Installations/${key##* }"
other_key="$(printf '%s' "$other" | /usr/bin/openssl dgst -sha256)";other_root="$legacy/Installations/${other_key##* }"
version='1.1.13+108';pid=99999999
prepare(){ bash assets/updater/mac_worker.sh prepare "$1" "$2" "$pid" "$version" "$legacy"; }
# A test build's legacy record cannot block or become the production app's proof.
printf '%s\n%s\n0\n%s\n' "$version" "$legacy/Backups/previous" "$other" > "$legacy/candidate.txt"
printf '12345' > "$legacy/startup.healthy"
prepare "$root" "$app"
[[ ! -f "$root/candidate.txt" && -f "$legacy/candidate.txt" && ! -f "$root/startup.healthy" ]]
# Only its owning installation adopts legacy rollback protection.
prepare "$other_root" "$other"
[[ -f "$other_root/candidate.txt" && ! -f "$legacy/candidate.txt" ]]
backup="$(sed -n '2p' "$other_root/candidate.txt")"
[[ "$backup" == "$other_root/Backups/"* && "$(cat "$backup/BobTV.app/Contents/MacOS/BobTV")" == old-app ]]
[[ "$(cat "$legacy/Backups/previous/BobTV.app/Contents/MacOS/BobTV")" == old-app ]]
[[ ! -f "$other_root/startup.healthy" && ! -f "$other_root/startup.marker" ]]
[[ "$(cat "$legacy/Backups/historical/keep.txt")" == keep ]]
prepare "$other_root" "$other"
[[ "$(sed -n '2p' "$other_root/candidate.txt")" == "$backup" ]]
# Failed starts still roll back the owning installation after three attempts.
for n in 1 2; do
 printf '%s' "$pid" > "$other_root/startup.marker"
 bash assets/updater/mac_worker.sh monitor "$other_root" "$other" "$pid"
 [[ "$(sed -n '3p' "$other_root/candidate.txt")" == "$n" ]]
done
printf '%s' "$pid" > "$other_root/startup.marker"
bash assets/updater/mac_worker.sh monitor "$other_root" "$other" "$pid"
[[ "$(cat "$other/Contents/MacOS/BobTV")" == old-app ]]
[[ "$(cat "$app/Contents/MacOS/BobTV")" == new-app && ! -f "$root/skipped_versions.txt" ]]
[[ "$(cat "$legacy/skipped_versions.txt")" == "$version" ]]
# Healthy records are cleared without touching the other installation.
mkdir -p "$root/Backups/owned/BobTV.app"
printf '%s\n%s\n0\n%s\n' "$version" "$root/Backups/owned" "$app" > "$root/candidate.txt"
printf '%s' "$pid" > "$root/startup.healthy"
bash assets/updater/mac_worker.sh monitor "$root" "$app" "$pid"
[[ ! -f "$root/candidate.txt" && -d "$root/Backups/owned" && -f "$other_root/skipped_versions.txt" ]]
# Obsolete scoped records are preserved, and never mistaken for this startup.
printf '1.1.12+107\n%s\n0\n%s\n' "$root/Backups/owned" "$app" > "$root/candidate.txt"
printf '12345' > "$root/startup.marker"
prepare "$root" "$app"
[[ ! -f "$root/candidate.txt" && ! -f "$root/startup.marker" && -d "$root/Backups/owned" ]]
# Unsafe legacy backup pointers are quarantined without moving external files.
mkdir -p "$fixture/protected/BobTV.app";printf 'preserve' > "$fixture/protected/keep"
printf '%s\n%s\n0\n%s\n' "$version" "$fixture/protected" "$app" > "$legacy/candidate.txt"
prepare "$root" "$app"
[[ ! -f "$root/candidate.txt" && ! -f "$legacy/candidate.txt" && "$(cat "$fixture/protected/keep")" == preserve ]]
# Every app is restricted to the directory derived from its own canonical path.
if prepare "$other_root" "$app"; then echo 'Cross-installation state accepted' >&2;exit 1;fi
printf 'PASS: installation isolation, legacy migration, stale/unsafe state quarantine, independent rollback and healthy startup\n'
# An active installer owns its pending candidate even if an old app starts.
printf '1.1.14+109\n%s\n0\n%s\n' "$root/Backups/owned" "$app" > "$root/candidate.txt"
/usr/bin/lockf -t 1 "$root/update.lock" sleep 3 &
holder=$!;sleep 1
prepare "$root" "$app"
[[ "$(sed -n '1p' "$root/candidate.txt")" == '1.1.14+109' ]]
wait "$holder"
# A delayed monitor cannot clear a replacement candidate.
token="$(/usr/bin/openssl dgst -sha256 "$root/candidate.txt")"
printf '%s\n%s\n0\n%s\n' "$version" "$root/Backups/owned" "$app" > "$root/candidate.txt"
bash assets/updater/mac_worker.sh startup-locked "$root" "$app" "$pid" "$version" "${token##* }"
[[ -f "$root/candidate.txt" ]]
# Healthy confirmation completes while the app is running, and stays observable.
sleep 10 &
live=$!
printf '%s' "$live" > "$root/startup.healthy"
bash assets/updater/mac_worker.sh monitor "$root" "$app" "$live" "$version"
kill -0 "$live";kill "$live";wait "$live" 2>/dev/null || true
[[ ! -f "$root/candidate.txt" && "$(cat "$root/startup.healthy")" == "$live" ]]
# A stale PID receipt must not fail a new launch before its fresh health signal.
mkdir -p "$fixture/bin"
printf '#!/bin/bash\nexit 28\n' > "$fixture/bin/curl";chmod +x "$fixture/bin/curl"
printf '%s\n%s\n0\n%s\n' "$version" "$root/Backups/owned" "$app" > "$root/candidate.txt"
printf '12345' > "$root/startup.healthy"
sig='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
set +e
PATH="$fixture/bin:$PATH" bash assets/updater/mac_worker.sh update-locked "$root" "$app" "$pid" '1.1.14+109' 'https://bobtv.briconbric.com/updates/files/test.zip' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 1000000 "$sig" fresh-health-test &
updater=$!
set -e
sleep 1
kill -0 "$updater"
printf '%s' "$pid" > "$root/startup.healthy"
set +e
wait "$updater";code=$?
set -e
[[ "$code" == 28 && ! -f "$root/candidate.txt" ]]
printf 'PASS: active install protection, monitor generation checks, live healthy confirmation and stale PID receipt retry\n'
# A rollback to the new protocol keeps skip state scoped to its installation.
rm -f "$legacy/skipped_versions.txt"
mkdir -p "$root/Backups/v2/BobTV.app/Contents/MacOS" "$root/Backups/v2/BobTV.app/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/updater"
printf v2-app > "$root/Backups/v2/BobTV.app/Contents/MacOS/BobTV"
printf 2 > "$root/Backups/v2/BobTV.app/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/updater/mac-installation-state-v2"
printf '%s\n%s\n2\n%s\n' "$version" "$root/Backups/v2" "$app" > "$root/candidate.txt"
printf '%s' "$pid" > "$root/startup.marker"
rm -f "$root/startup.healthy"
bash assets/updater/mac_worker.sh monitor "$root" "$app" "$pid" "$version"
[[ "$(cat "$app/Contents/MacOS/BobTV")" == v2-app && ! -f "$legacy/skipped_versions.txt" ]]
printf 'PASS: interrupted migration preserves original backup and rollback skip protocol stays compatible\n'
