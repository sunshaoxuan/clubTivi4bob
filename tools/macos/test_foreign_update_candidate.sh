#!/bin/bash
set -euo pipefail
source_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture="$(mktemp -d "$HOME/Library/Application Support/BobTVForeignCandidateTest.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
root="$fixture/Update"; app="$fixture/BobTV.app"; backup="$root/Backups/foreign-backup"; foreign="$fixture/Other/BobTV.app"
mkdir -p "$app/Contents/MacOS" "$backup/BobTV.app" "$fixture/bin"
printf 'app' > "$app/Contents/MacOS/BobTV"
printf 'preserve' > "$backup/BobTV.app/keep.txt"
printf '1.1.11+106\n%s\n0\n%s\n' "$backup" "$foreign" > "$root/candidate.txt"
printf '99999999' > "$root/startup.healthy"
printf '#!/bin/bash\nexit 28\n' > "$fixture/bin/curl";chmod +x "$fixture/bin/curl"
sig='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
set +e
PATH="$fixture/bin:$PATH" bash "$source_root/assets/updater/mac_worker.sh" update-locked "$root" "$app" 99999999 '1.1.12+107' 'https://bobtv.briconbric.com/updates/files/test.zip' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 1000000 "$sig" foreign-test
code=$?
set -e
[[ "$code" == 28 && ! -e "$root/candidate.txt" ]]
[[ "$(cat "$backup/BobTV.app/keep.txt")" == preserve ]]
saved=("$root"/DeferredCandidates/foreign.*/candidate.txt)
[[ ${#saved[@]} == 1 && "$(sed -n '4p' "${saved[0]}")" == "$foreign" ]]
[[ -f "$(dirname "${saved[0]}")/startup.healthy" ]]
# The owning installation still requires its own successful health receipt.
printf '1.1.11+106\n%s\n0\n%s\n' "$backup" "$app" > "$root/candidate.txt"
printf '99999998' > "$root/startup.healthy"
set +e
PATH="$fixture/bin:$PATH" bash "$source_root/assets/updater/mac_worker.sh" update-locked "$root" "$app" 99999999 '1.1.12+107' 'https://bobtv.briconbric.com/updates/files/test.zip' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' 1000000 "$sig" owned-test &
worker=$!
set -e
# An invalid receipt must not allow downloading. Stop the intentionally waiting fixture.
sleep 2
kill "$worker" 2>/dev/null || true
wait "$worker" 2>/dev/null || true
[[ -f "$root/candidate.txt" && "$(cat "$backup/BobTV.app/keep.txt")" == preserve ]]
echo 'PASS: foreign state archived, backups preserved, owning-app health protection retained'
