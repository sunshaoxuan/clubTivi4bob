#!/bin/bash
set -euo pipefail

# Run on a Mac after building BobTV.app with a Developer ID identity.
# NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER are App Store Connect API values.
app="${1:-}"
arch="${2:-}"
output="${3:-}"
if [[ ! -d "$app/Contents" || ! -d "$output" ||
      "$arch" != 'x64' && "$arch" != 'arm64' ]]; then
  echo 'Usage: package_signed_update.sh BobTV.app x64|arm64 output-directory' >&2
  exit 2
fi
: "${NOTARY_KEY:?Set NOTARY_KEY to an App Store Connect private key path}"
: "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER:?Set NOTARY_ISSUER}"

codesign --verify --deep --strict "$app"
team="$(codesign -dv --verbose=4 "$app" 2>&1 |
  sed -n 's/^TeamIdentifier=\([A-Z0-9]*\)$/\1/p' | head -1)"
[[ -n "$team" ]] || { echo 'Developer ID team is missing' >&2; exit 3; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$app/Contents/Info.plist")"
[[ "$version+$build" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]] || exit 3
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$app/Contents/Info.plist")" == 'com.briconbric.bobtv' ]] || exit 3
machine_arch='x86_64'
if [[ "$arch" == 'arm64' ]]; then machine_arch='arm64'; fi
for binary in \
  "$app/Contents/MacOS/BobTV" \
  "$app/Contents/Resources/AirPlay/bobtv-airplay/bobtv-airplay" \
  "$app/Contents/Resources/AirPlay/bobtv-airplay/fpsap-auth"; do
  [[ -f "$binary" && " $(lipo -archs "$binary") " == *" $machine_arch "* ]] || exit 3
done

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
ditto -c -k --keepParent "$app" "$temporary/notarize.zip"
xcrun notarytool submit "$temporary/notarize.zip" --key "$NOTARY_KEY" \
  --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute "$app"

archive="$output/BobTV-$version+$build-macos-$arch.zip"
ditto -c -k --keepParent "$app" "$archive"
echo "Signed and notarized update archive: $archive"
shasum -a 256 "$archive"
python3 - "$archive" "$arch" "$version+$build" "$output/BobTV-update-metadata.json" <<'PY'
import hashlib
import json
import pathlib
import sys

archive = pathlib.Path(sys.argv[1])
platform = 'macos-' + sys.argv[2]
version = sys.argv[3]
digest = hashlib.sha256()
with archive.open('rb') as source:
    while chunk := source.read(1024 * 1024):
        digest.update(chunk)
payload = {'schema': 1, 'version': version, 'packages': [{
    'platform': platform, 'filename': archive.name,
    'sha256': digest.hexdigest(), 'bytes': archive.stat().st_size,
}]}
pathlib.Path(sys.argv[4]).write_text(json.dumps(payload, separators=(',', ':')),
                                   encoding='utf-8')
PY
