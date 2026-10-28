#!/bin/bash
set -euo pipefail
app="${1:?Provide BobTV.app}"
# A publisher archive signature authenticates the download, but cannot provide
# a stable macOS Keychain identity. Public packages also require Developer ID.
codesign --verify --deep --strict "$app"
codesign --verify --strict -R 'anchor apple generic and identifier "com.briconbric.bobtv" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app" || {
  echo 'Public macOS packages require Developer ID Application signing. Ad-hoc signing cannot preserve Keychain identity across upgrades.' >&2
  exit 3
}
