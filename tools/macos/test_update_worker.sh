#!/bin/bash
set -euo pipefail

mkdir -p "$HOME/Library/Application Support"
fixture="$(mktemp -d "$HOME/Library/Application Support/BobTVUpdaterTest.XXXXXX")"
live_pid=''
cleanup() {
  if [[ -n "$live_pid" ]]; then
    kill "$live_pid" 2>/dev/null || true
    wait "$live_pid" 2>/dev/null || true
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT
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
[[ ! -d "$backup" ]]

# Healthy startup clears the sole rollback while the app is still running.
mkdir -p "$backup/BobTV.app/Contents/MacOS" "$root/Backups/historical"
printf 'old' > "$backup/BobTV.app/Contents/MacOS/BobTV"
printf 'preserve' > "$root/Backups/historical/keep.txt"
printf 'new' > "$app/Contents/MacOS/BobTV"
printf '%s\n%s\n0\n%s\n' '0.9.2+2' "$backup" "$app" > "$root/candidate.txt"
sleep 120 &
live_pid=$!
printf '%s' "$live_pid" > "$root/startup.healthy"
bash assets/updater/mac_worker.sh monitor "$root" "$app" "$live_pid"
kill -0 "$live_pid"
[[ ! -f "$root/candidate.txt" ]]
[[ ! -e "$backup" ]]
[[ "$(cat "$app/Contents/MacOS/BobTV")" == 'new' ]]
[[ "$(cat "$root/Backups/historical/keep.txt")" == 'preserve' ]]
[[ "$(cat "$root/startup.healthy")" == "$live_pid" ]]

# An unhealthy launch must retain rollback protection, including a stale receipt.
mkdir -p "$backup/BobTV.app/Contents/MacOS"
printf 'old' > "$backup/BobTV.app/Contents/MacOS/BobTV"
printf '%s\n%s\n0\n%s\n' '0.9.2+3' "$backup" "$app" > "$root/candidate.txt"
printf '%s' "$pid" > "$root/startup.marker"
bash assets/updater/mac_worker.sh monitor "$root" "$app" "$pid"
[[ "$(sed -n '3p' "$root/candidate.txt")" == 1 ]]
[[ -f "$backup/BobTV.app/Contents/MacOS/BobTV" ]]

# A delayed monitor cannot clear a newer candidate, even with a healthy PID.
digest="$(/usr/bin/openssl dgst -sha256 "$root/candidate.txt")"
token="${digest##* }"
printf '%s\n%s\n0\n%s\n' '0.9.2+4' "$backup" "$app" > "$root/candidate.txt"
bash assets/updater/mac_worker.sh startup-locked "$root" "$app" "$live_pid" \
  '' '' '' '' '' '' "$token"
[[ "$(sed -n '1p' "$root/candidate.txt")" == '0.9.2+4' ]]
[[ -d "$backup" ]]

# Refuse traversal, a broad backup root, and symlinked rollback directories.
mkdir -p "$fixture/protected"
printf 'preserve' > "$fixture/protected/keep.txt"
ln -s "$fixture/protected" "$root/Backups/linked"
for unsafe in "$root/Backups/../../protected" "$root/Backups/" "$root/Backups/linked"; do
  printf '%s\n%s\n0\n%s\n' '0.9.2+5' "$unsafe" "$app" > "$root/candidate.txt"
  if bash assets/updater/mac_worker.sh monitor "$root" "$app" "$live_pid"; then
    echo 'Unsafe rollback path was accepted' >&2
    exit 1
  fi
  [[ -f "$root/candidate.txt" ]]
  [[ "$(cat "$fixture/protected/keep.txt")" == preserve ]]
  [[ -d "$backup/BobTV.app" ]]
done
rm -f "$root/candidate.txt"

/usr/bin/lockf -t 1 "$root/update.lock" sleep 3 &
holder=$!
sleep 1
if bash assets/updater/mac_worker.sh update "$root" "$app" "$pid" \
  '0.9.2+3' 'https://bobtv.briconbric.com/updates/files/BobTV-test.zip' \
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  '1000000'; then
  echo 'Concurrent Mac update unexpectedly acquired the worker lock' >&2
  exit 1
fi
wait "$holder"

# Full worker install in an isolated fixture. Network and Apple signing checks
# are stubbed; real ZIP, size, SHA-256, publisher signature, and architecture
# validation still run. Forbid ditto from copying the previous application.
package="$fixture/Package/BobTV.app"
mkdir -p "$package/Contents/MacOS" "$package/Contents/Resources/AirPlay/bobtv-airplay"
cp /usr/bin/true "$package/Contents/MacOS/BobTV"
cp /usr/bin/true "$package/Contents/Resources/AirPlay/bobtv-airplay/bobtv-airplay"
cp /usr/bin/true "$package/Contents/Resources/AirPlay/bobtv-airplay/fpsap-auth"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.9.3' "$package/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$package/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.briconbric.bobtv' "$package/Contents/Info.plist"
/usr/bin/openssl rand -out "$package/Contents/Resources/payload" 1100000
export BOBTV_TEST_ARCHIVE="$fixture/package.zip"
/usr/bin/ditto -c -k --norsrc --keepParent "$package" "$BOBTV_TEST_ARCHIVE"
/usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out "$fixture/signing.pem"
/usr/bin/openssl dgst -sha256 -sign "$fixture/signing.pem" -out "$fixture/signature.der" "$BOBTV_TEST_ARCHIVE"
signature="$(/usr/bin/base64 < "$fixture/signature.der" | tr -d '\n')"
digest="$(/usr/bin/openssl dgst -sha256 "$BOBTV_TEST_ARCHIVE")"
hash="${digest##* }"
bytes="$(stat -f%z "$BOBTV_TEST_ARCHIVE")"
curl() { /bin/cp "$BOBTV_TEST_ARCHIVE" "$partial"; }
codesign() {
  if [[ "$1" == -d && "${BOBTV_TEST_SIGNING:-}" == pinned ]]; then
    printf '%s\n' 'TeamIdentifier=TESTTEAM' 'designated => identifier "com.briconbric.bobtv" and anchor apple generic and certificate leaf[subject.OU] = "TESTTEAM"' >&2
    return 0
  fi
  if [[ "$1" == --verify && "$3" == -R ]]; then return 7; fi
  [[ "$1" == --verify && -f "$4/Contents/MacOS/BobTV" ]]
}
ditto() {
  [[ "$1" == -x && "$2" == -k ]] || { echo 'Unexpected full app copy' >&2; return 90; }
  /usr/bin/ditto "$@"
}
mv() {
  if [[ "${BOBTV_TEST_FAIL_INSTALL:-}" == true && "$1" == */Stage/*/BobTV.app &&
        "${2:-}" == "$BOBTV_TEST_APP" ]]; then return 1; fi
  /bin/mv "$@"
}
export -f curl codesign ditto mv
for outcome in success failure signing-mismatch; do
  export BOBTV_TEST_SIGNING=adhoc
  [[ "$outcome" != signing-mismatch ]] || BOBTV_TEST_SIGNING=pinned
  install_root="$fixture/$outcome/Update"
  export BOBTV_TEST_APP="$fixture/$outcome/BobTV.app"
  export BOBTV_TEST_FAIL_INSTALL=false
  [[ "$outcome" == success ]] || BOBTV_TEST_FAIL_INSTALL=true
  mkdir -p "$install_root" "$BOBTV_TEST_APP/Contents/MacOS"
  printf old > "$BOBTV_TEST_APP/Contents/MacOS/BobTV"
  /bin/cp "$package/Contents/Info.plist" "$BOBTV_TEST_APP/Contents/Info.plist"
  old_inode="$(stat -f%i "$BOBTV_TEST_APP/Contents/MacOS/BobTV")"
  /usr/bin/openssl pkey -in "$fixture/signing.pem" -pubout -out "$install_root/update-signing-public.pem"
  if [[ "$outcome" == failure ]]; then
    # The next update must also retire a healthy legacy candidate when its
    # original monitor has stopped, without resetting rollback accounting.
    legacy="$install_root/Backups/legacy"
    mkdir -p "$legacy/BobTV.app/Contents/MacOS"
    printf older > "$legacy/BobTV.app/Contents/MacOS/BobTV"
    printf '%s\n%s\n0\n%s\n' '0.9.2+8' "$legacy" "$BOBTV_TEST_APP" > "$install_root/candidate.txt"
    printf '%s' "$pid" > "$install_root/startup.healthy"
  fi
  result=0
  bash assets/updater/mac_worker.sh update "$install_root" "$BOBTV_TEST_APP" "$pid" \
    '0.9.3+1' 'https://bobtv.briconbric.com/updates/files/BobTV-test.zip' \
    "$hash" "$bytes" "$signature" || result=$?
  if [[ "$outcome" == success ]]; then
    [[ "$result" == 0 && -f "$install_root/candidate.txt" ]]
    rollback="$(sed -n '2p' "$install_root/candidate.txt")"
    [[ "$(stat -f%i "$rollback/BobTV.app/Contents/MacOS/BobTV")" == "$old_inode" ]]
    printf '%s' "$live_pid" > "$install_root/startup.healthy"
    bash assets/updater/mac_worker.sh monitor "$install_root" "$BOBTV_TEST_APP" "$live_pid"
    [[ ! -e "$rollback" && ! -f "$install_root/candidate.txt" ]]
    kill -0 "$live_pid"
  elif [[ "$outcome" == signing-mismatch ]]; then
    [[ "$result" != 0 && ! -f "$install_root/candidate.txt" ]]
    [[ "$(cat "$BOBTV_TEST_APP/Contents/MacOS/BobTV")" == old ]]
    [[ "$(stat -f%i "$BOBTV_TEST_APP/Contents/MacOS/BobTV")" == "$old_inode" ]]
  else
    [[ "$result" == 10 && ! -f "$install_root/candidate.txt" ]]
    [[ "$(cat "$BOBTV_TEST_APP/Contents/MacOS/BobTV")" == old ]]
    [[ "$(stat -f%i "$BOBTV_TEST_APP/Contents/MacOS/BobTV")" == "$old_inode" ]]
    [[ ! -e "$legacy" ]]
    [[ -z "$(find "$install_root/Backups" -mindepth 1 -print -quit)" ]]
  fi
done
echo 'PASS: Mac update moves without copying, cleans healthy rollback, preserves pending rollback and historical files, rejects unsafe cleanup, restores failed installs, and rejects a signing identity mismatch before replacement.'
