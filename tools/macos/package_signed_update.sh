#!/bin/bash
set -euo pipefail

# Run on a Mac after building BobTV.app. Apple notarization is optional.
# The BobTV publisher key is required for self-hosted automatic updates.
app="${1:-}"
arch="${2:-}"
output="${3:-}"
if [[ ! -d "$app/Contents" || ! -d "$output" ||
      "$arch" != 'x64' && "$arch" != 'arm64' ]]; then
  echo 'Usage: package_signed_update.sh BobTV.app x64|arm64 output-directory' >&2
  exit 2
fi
: "${BOBTV_UPDATE_SIGNING_KEY:?Set BOBTV_UPDATE_SIGNING_KEY to the local private key path}"
[[ -f "$BOBTV_UPDATE_SIGNING_KEY" && ! -L "$BOBTV_UPDATE_SIGNING_KEY" ]] || exit 2

codesign --verify --deep --strict "$app"
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
if [[ -n "${NOTARY_KEY:-}${NOTARY_KEY_ID:-}${NOTARY_ISSUER:-}" ]]; then
  : "${NOTARY_KEY:?Set all three notarization variables or leave all unset}"
  : "${NOTARY_KEY_ID:?Set all three notarization variables or leave all unset}"
  : "${NOTARY_ISSUER:?Set all three notarization variables or leave all unset}"
  ditto -c -k --keepParent "$app" "$temporary/notarize.zip"
  xcrun notarytool submit "$temporary/notarize.zip" --key "$NOTARY_KEY" \
    --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute "$app"
fi

archive="$output/BobTV-$version+$build-macos-$arch.zip"
ditto -c -k --keepParent "$app" "$archive"
/usr/bin/openssl dgst -sha256 -sign "$BOBTV_UPDATE_SIGNING_KEY" \
  -out "$temporary/update-signature.der" "$archive"
/usr/bin/openssl dgst -sha256 -verify \
  "$(cd "$(dirname "$0")/../.." && pwd)/assets/updater/update-signing-public.pem" \
  -signature "$temporary/update-signature.der" "$archive" >/dev/null
echo "Publisher-signed update archive: $archive"
shasum -a 256 "$archive"
python3 - "$archive" "$arch" "$version+$build" \
  "$output/BobTV-update-metadata.json" "$temporary/update-signature.der" <<'PY'
import base64
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
entry = {
    'platform': platform, 'filename': archive.name,
    'sha256': digest.hexdigest(), 'bytes': archive.stat().st_size,
    'signature': base64.b64encode(pathlib.Path(sys.argv[5]).read_bytes()).decode('ascii'),
}
path = pathlib.Path(sys.argv[4])
if path.exists():
    payload = json.loads(path.read_text(encoding='utf-8'))
    if (payload.get('schema') != 1 or payload.get('version') != version or
            not isinstance(payload.get('packages'), list)):
        raise SystemExit('Existing update metadata has a different version or schema')
    payload['packages'] = [item for item in payload['packages']
                           if item.get('platform') != platform]
else:
    payload = {'schema': 1, 'version': version, 'packages': []}
payload['packages'].append(entry)
path.write_text(json.dumps(payload, separators=(',', ':')), encoding='utf-8')
PY
