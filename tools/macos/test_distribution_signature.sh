#!/bin/bash
set -euo pipefail
repository="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repository"
fixture="$(mktemp -d "$HOME/Library/Application Support/BobTVSigningTest.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
  local label="$1" expected="$2" result=0
  shift 2
  "$@" > "$fixture/$label.log" 2>&1 || result=$?
  [[ "$result" == "$expected" ]] || {
    cat "$fixture/$label.log" >&2
    fail "$label returned $result, expected $expected"
  }
}

create_app() {
  local app="$1" publisher="$2" marker="$3" identifier="${4:-com.briconbric.bobtv}"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/AirPlay/bobtv-airplay"
  /bin/cp /usr/bin/true "$app/Contents/MacOS/BobTV"
  for helper in bobtv-airplay fpsap-auth; do
    /bin/cp /usr/bin/true "$app/Contents/Resources/AirPlay/bobtv-airplay/$helper"
    /usr/bin/codesign --force --sign - "$app/Contents/Resources/AirPlay/bobtv-airplay/$helper" >/dev/null 2>&1
  done
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $identifier" "$app/Contents/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string BobTV' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.9.3' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :BobTVTestPublisher string $publisher" "$app/Contents/Info.plist"
  printf '%s' "$marker" > "$app/Contents/Resources/version-marker"
  /usr/bin/openssl rand -out "$app/Contents/Resources/payload" 1100000
  /usr/bin/codesign --force --sign - --identifier "$identifier" \
    --requirements "=designated => identifier \"$identifier\" and info[BobTVTestPublisher] = \"$publisher\"" \
    "$app" >/dev/null 2>&1
  /usr/bin/codesign --verify --deep --strict "$app"
}

package_a="$fixture/PackageA/BobTV.app"
package_b="$fixture/PackageB/BobTV.app"
create_app "$package_a" A new
create_app "$package_b" B new

# These tests use the actual system parser and evaluator. No signing identity,
# real Keychain item, network access, installed app or release key is required.
/usr/bin/codesign --verify --strict -R '=identifier "com.briconbric.bobtv"' "$package_a"
expect_failure wrong-inline 3 /usr/bin/codesign --verify --strict \
  -R '=identifier "com.example.wrong"' "$package_a"
expect_failure default-profile 3 env -u BOBTV_MAC_DISTRIBUTION \
  bash tools/macos/verify_distribution_signature.sh "$package_a"
BOBTV_MAC_DISTRIBUTION=self-hosted bash tools/macos/verify_distribution_signature.sh "$package_a"
expect_failure invalid-profile 2 env BOBTV_MAC_DISTRIBUTION=invalid \
  bash tools/macos/verify_distribution_signature.sh "$package_a"
wrong_bundle="$fixture/WrongBundle/BobTV.app"
create_app "$wrong_bundle" A new com.example.wrong
expect_failure wrong-bundle 3 env BOBTV_MAC_DISTRIBUTION=self-hosted \
  bash tools/macos/verify_distribution_signature.sh "$wrong_bundle"
wrong_code="$fixture/WrongCode/BobTV.app"
/usr/bin/ditto "$package_a" "$wrong_code"
/usr/bin/codesign --force --sign - --identifier com.example.wrong \
  --requirements '=designated => identifier "com.example.wrong"' "$wrong_code" >/dev/null 2>&1
expect_failure wrong-code 3 env BOBTV_MAC_DISTRIBUTION=self-hosted \
  bash tools/macos/verify_distribution_signature.sh "$wrong_code"

# Exercise the real update worker using signed synthetic ZIPs. Only the
# certificate's TeamIdentifier display is substituted: the installed designated
# requirement and every codesign verification are real. A custom plist field
# models identity continuity without pretending to test an Apple certificate.
/usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out "$fixture/signing.pem"
curl() { /bin/cp "$BOBTV_TEST_ARCHIVE" "$partial"; }
codesign() {
  if [[ "$1" == -d ]]; then
    /usr/bin/codesign "$@" 2>&1 | sed 's/^TeamIdentifier=not set$/TeamIdentifier=TESTTEAM/'
  else
    /usr/bin/codesign "$@"
  fi
}
export -f curl codesign
for outcome in pinned-match pinned-mismatch; do
  install_root="$fixture/$outcome/Update"
  installed="$fixture/$outcome/BobTV.app"
  mkdir -p "$install_root"
  create_app "$installed" A old
  export BOBTV_TEST_ARCHIVE="$fixture/$outcome.zip"
  package="$package_a"
  [[ "$outcome" != pinned-mismatch ]] || package="$package_b"
  /usr/bin/ditto -c -k --norsrc --keepParent "$package" "$BOBTV_TEST_ARCHIVE"
  /usr/bin/openssl dgst -sha256 -sign "$fixture/signing.pem" \
    -out "$fixture/signature.der" "$BOBTV_TEST_ARCHIVE"
  signature="$(/usr/bin/base64 < "$fixture/signature.der" | tr -d '\n')"
  digest="$(/usr/bin/openssl dgst -sha256 "$BOBTV_TEST_ARCHIVE")"
  hash="${digest##* }"
  bytes="$(stat -f%z "$BOBTV_TEST_ARCHIVE")"
  /usr/bin/openssl pkey -in "$fixture/signing.pem" -pubout \
    -out "$install_root/update-signing-public.pem"
  old_inode="$(stat -f%i "$installed/Contents/MacOS/BobTV")"
  result=0
  bash assets/updater/mac_worker.sh update "$install_root" "$installed" 99999999 \
    '0.9.3+1' 'https://bobtv.briconbric.com/updates/files/BobTV-signing-test.zip' \
    "$hash" "$bytes" "$signature" || result=$?
  if [[ "$outcome" == pinned-match ]]; then
    [[ "$result" == 0 && -f "$install_root/candidate.txt" ]] || {
      cat "$install_root/worker.log" >&2; fail 'matching identity update rejected'
    }
    [[ "$(cat "$installed/Contents/Resources/version-marker")" == new ]] || fail 'replacement missing'
    backup="$(sed -n '2p' "$install_root/candidate.txt")"
    [[ "$(cat "$backup/BobTV.app/Contents/Resources/version-marker")" == old ]] || fail 'backup missing'
  else
    [[ "$result" == 3 && ! -f "$install_root/candidate.txt" ]] || {
      cat "$install_root/worker.log" >&2; fail 'identity mismatch accepted or wrong failure'
    }
    [[ "$(cat "$installed/Contents/Resources/version-marker")" == old ]] || fail 'old app modified'
    [[ "$(stat -f%i "$installed/Contents/MacOS/BobTV")" == "$old_inode" ]] || fail 'old app moved'
    [[ ! -d "$install_root/Backups" ]] || fail 'identity mismatch reached backup stage'
  fi
  echo "PASS: $outcome with real designated-requirement evaluation"
done

echo 'PASS: default Developer ID policy, explicit self-hosted profile, identifiers, literal requirements, and update identity continuity'
