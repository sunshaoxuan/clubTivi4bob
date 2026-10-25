#!/bin/bash
set -euo pipefail
app="${1:?Provide BobTV.app}"
profile="${BOBTV_MAC_DISTRIBUTION:-developer-id}"
case "$profile" in
  developer-id|self-hosted) ;;
  *) echo "Unknown macOS distribution profile: $profile" >&2; exit 2 ;;
esac

# Both distribution profiles require an intact BobTV bundle. The publisher
# archive signature is checked separately by the packaging and update workers.
codesign --verify --deep --strict "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == 'com.briconbric.bobtv' ]] || {
  echo 'macOS packages require the BobTV bundle identifier.' >&2
  exit 3
}
codesign --verify --strict -R '=identifier "com.briconbric.bobtv"' "$app"
if [[ "$profile" == developer-id ]]; then
  codesign --verify --strict -R '=anchor apple generic and identifier "com.briconbric.bobtv" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app" || {
    echo 'The developer-id profile requires Developer ID Application signing. Ad-hoc signing cannot preserve Keychain identity across upgrades.' >&2
    exit 3
  }
else
  echo 'Verified explicit self-hosted macOS profile; Apple Developer ID and notarization are not implied.'
fi
