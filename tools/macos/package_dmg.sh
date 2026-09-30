#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo 'Usage: package_dmg.sh /path/to/BobTV.app /path/to/BobTV.dmg' >&2
  exit 2
fi

app="$1"
output="$2"
root="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ ! -d "$app/Contents/MacOS" || "$(basename "$app")" != 'BobTV.app' ]]; then
  echo 'Expected a built BobTV.app bundle.' >&2
  exit 2
fi
if ! command -v dmgbuild >/dev/null 2>&1; then
  echo 'Install the pinned dmgbuild version before packaging.' >&2
  exit 2
fi

mkdir -p "$(dirname "$output")"
dmgbuild -s "$root/tools/macos/dmg_settings.py" -D "app=$app" \
  'BobTV' "$output"
hdiutil verify "$output"
