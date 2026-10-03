#!/bin/bash
set -euo pipefail
[[ "${CI:-}" == true ]]
helper="${1:?Pass the compiled native progress helper}"
fixture="$(mktemp -d)"
observer=''
cleanup() {
  [[ "$observer" =~ ^[1-9][0-9]*$ ]] && kill "$observer" 2>/dev/null || true
}
trap cleanup EXIT
state() {
  printf '{"phase":"%s","version":"0.9.1+73","runId":"preview","workerPid":%s,"percent":37,"receivedBytes":25000000,"totalBytes":68000000,"message":"Native updater window test"}' "$1" "$$" > "$fixture/status-preview.json.tmp"
  mv "$fixture/status-preview.json.tmp" "$fixture/status-preview.json"
}
state downloading
"$helper" "$fixture" "$fixture/BobTV.app" 99999999 "$$" '0.9.1+73' preview > "$fixture/launcher.log" 2>&1 &
observer=$!
for ((n=0; n<20; n++)); do
  kill -0 "$observer"
  [[ -f "$fixture/progress-ui.log" ]] && grep -q window_shown "$fixture/progress-ui.log" && break
  sleep 1
done
grep -q window_shown "$fixture/progress-ui.log"
for phase in downloading verifying backingUp installing installed failed; do
  state "$phase"
  sleep 2
  grep -q "phase=$phase " "$fixture/progress-ui.log"
done
cat "$fixture/progress-ui.log"
echo 'PASS: native Mac observer showed its window and reported all six update stages.'
