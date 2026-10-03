#!/bin/bash
set -euo pipefail

mode="${1:-}"
root="${2:-}"
app="${3:-}"
watched_pid="${4:-}"
version="${5:-}"
archive_url="${6:-}"
expected_hash="${7:-}"
expected_bytes="${8:-}"
package_signature="${9:-}"
run_id="${10:-}"
[[ -z "$run_id" || "$run_id" =~ ^[A-Za-z0-9-]{1,100}$ ]] || exit 2

if [[ "$root" != "$HOME/Library/Application Support/"* ||
      "$app" != *.app || "$app" == '/' ||
      ! "$watched_pid" =~ ^[1-9][0-9]*$ ]]; then
  exit 2
fi
if [[ ! -f "$app/Contents/MacOS/BobTV" ]]; then
  exit 2
fi
mkdir -p "$root"
exec >> "$root/worker.log" 2>&1
printf '%s worker mode=%s version=%s pid=%s run=%s\n' "$(date -u +%FT%TZ)" "$mode" "$version" "$$" "$run_id"
status="$root/status.json"
candidate="$root/candidate.txt"
marker="$root/startup.marker"
healthy="$root/startup.healthy"
skipped="$root/skipped_versions.txt"

write_status() {
  local phase="$1" shown_version="$2" percent="$3" message="${4:-}" path
  if [[ -z "$message" ]]; then
    case "$phase" in
      starting) message='正在准备更新' ;;
      downloading) message='正在下载更新' ;;
      verifying) message='正在校验文件、签章和安装包内容' ;;
      ready) message='已下载并校验通过，关闭 BobTV 后自动安装' ;;
      backingUp) message='正在备份旧版，请稍候' ;;
      installing) message='正在安装更新，请稍候' ;;
      installed) message='安装完成，旧版已备份，下次启动即为新版本' ;;
      failed) message='更新未完成，请查看 worker.log 并重试' ;;
    esac
  fi
  message="${message//\\/\\\\}"; message="${message//\"/\\\"}"
  local payload
  payload="$(printf '{"phase":"%s","version":"%s","percent":%s,"message":"%s","runId":"%s","workerPid":%s,"receivedBytes":%s,"totalBytes":%s}' \
    "$phase" "$shown_version" "$percent" "$message" "$run_id" "$$" "${received_bytes:-0}" "${expected_bytes:-0}")"
  if [[ -z "$run_id" || "$mode" != 'update' ]]; then
    printf '%s\n' "$payload" > "$status.tmp"; mv -f "$status.tmp" "$status"
  fi
  if [[ -n "$run_id" ]]; then
    path="$root/status-$run_id.json"
    printf '%s\n' "$payload" > "$path.tmp"; mv -f "$path.tmp" "$path"
  fi
}

if [[ "$mode" == 'update' ]]; then
  write_status starting "$version" 0
  if /usr/bin/lockf -t 0 "$root/update.lock" /bin/bash "$0" \
    update-locked "$root" "$app" "$watched_pid" "$version" \
    "$archive_url" "$expected_hash" "$expected_bytes" "$package_signature" "$run_id"; then
    exit 0
  else
    code=$?
    if [[ -n "$run_id" && ! -f "$root/status-$run_id.json" ]] ||
        [[ -n "$run_id" && "$(cat "$root/status-$run_id.json")" == *'"phase":"starting"'* ]]; then
      write_status failed "$version" 0 '更新任务未能启动，请查看 worker.log 后重试'
    fi
    exit "$code"
  fi
fi

wait_for_exit() {
  local seconds=0
  while kill -0 "$watched_pid" 2>/dev/null; do
    sleep 2
    seconds=$((seconds + 2))
    if (( seconds >= 43200 )); then exit 3; fi
  done
}

if [[ "$mode" == 'monitor' ]]; then
  wait_for_exit
  [[ -f "$candidate" ]] || exit 0
  candidate_version="$(sed -n '1p' "$candidate")"
  backup="$(sed -n '2p' "$candidate")"
  previous_attempts="$(sed -n '3p' "$candidate")"
  candidate_app="$(sed -n '4p' "$candidate")"
  [[ "$candidate_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ &&
     "$previous_attempts" =~ ^[0-2]$ &&
     "$candidate_app" == "$app" ]] || exit 4
  if [[ -f "$healthy" && "$(cat "$healthy")" == "$watched_pid" ]]; then
    rm -f "$candidate" "$healthy" "$marker"
    exit 0
  fi
  [[ -f "$marker" && "$(cat "$marker")" == "$watched_pid" ]] || exit 0
  attempts=$(( previous_attempts + 1 ))
  rm -f "$marker"
  if (( attempts < 3 )); then
    printf '%s\n%s\n%s\n%s\n' "$candidate_version" "$backup" \
      "$attempts" "$app" > "$candidate.tmp"
    mv -f "$candidate.tmp" "$candidate"
    exit 0
  fi
  [[ "$backup" == "$root/Backups/"* &&
     -d "$backup/BobTV.app" && -w "$(dirname "$app")" ]] || exit 4
  failed="$root/FailedApps/$candidate_version-$(date +%s)"
  mkdir -p "$failed"
  mv "$app" "$failed/BobTV.app"
  if ! mv "$backup/BobTV.app" "$app"; then
    mv "$failed/BobTV.app" "$app"
    exit 5
  fi
  printf '%s\n' "$candidate_version" >> "$skipped"
  printf '{"schema":1,"failedVersion":"%s"}\n' "$candidate_version" \
    > "$root/failure-${candidate_version//+/_}.json"
  rm -f "$candidate" "$healthy" "$marker"
  write_status failed "$candidate_version" 0
  exit 0
fi

[[ "$mode" == 'update-locked' ]] || exit 2
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ &&
   "$expected_hash" =~ ^[a-fA-F0-9]{64}$ &&
   "$expected_bytes" =~ ^[0-9]+$ &&
   "$package_signature" =~ ^[A-Za-z0-9+/]{80,120}={0,2}$ ]] || exit 2
(( expected_bytes >= 1000000 && expected_bytes <= 2000000000 )) || exit 2
[[ "$archive_url" == https://bobtv.briconbric.com/updates/*.zip &&
   "$archive_url" != *'?'* && "$archive_url" != *'#'* ]] || exit 2
if [[ -f "$skipped" ]] && grep -Fxq "$version" "$skipped"; then exit 0; fi
trap 'code=$?; if (( code != 0 )); then write_status failed "$version" 0 "更新未完成（错误码 $code），请查看 worker.log 后重试"; fi' EXIT
if [[ -f "$candidate" ]]; then
  write_status starting "$version" 0 '等待当前版本完成启动检查'
  for (( attempt=0; attempt<90; attempt++ )); do
    [[ -f "$healthy" ]] && break
    sleep 1
  done
  [[ -f "$healthy" && "$(cat "$healthy")" == "$watched_pid" &&
      "$(sed -n '4p' "$candidate")" == "$app" ]] || exit 11
  rm -f "$candidate" "$marker" "$healthy"
fi
[[ -w "$(dirname "$app")" ]] || exit 9

archive="$root/BobTV-${version//+/_}-macos.zip"
partial="$archive.part"
write_status downloading "$version" 0
curl --fail --silent --show-error --proto '=https' --max-redirs 0 \
  --user-agent 'BobTV/0.9.1 updater' --connect-timeout 10 --max-time 14400 \
  --speed-time 30 --speed-limit 1 --output "$partial" "$archive_url" &
download_pid=$!
while kill -0 "$download_pid" 2>/dev/null; do
  received_bytes="$(stat -f%z "$partial" 2>/dev/null || echo 0)"
  percent=$(( received_bytes * 100 / expected_bytes ))
  (( percent > 99 )) && percent=99
  write_status downloading "$version" "$percent"
  sleep 1
done
wait "$download_pid"
received_bytes="$(stat -f%z "$partial")"
write_status verifying "$version" 100
[[ "$(stat -f%z "$partial")" == "$expected_bytes" ]] || exit 6
actual_hash="$(shasum -a 256 "$partial" | awk '{print tolower($1)}')"
expected_hash="$(printf '%s' "$expected_hash" | tr '[:upper:]' '[:lower:]')"
[[ "$actual_hash" == "$expected_hash" ]] || exit 6
mv -f "$partial" "$archive"
public_key="$root/update-signing-public.pem"
[[ -f "$public_key" && ! -L "$public_key" ]] || exit 8
signature_file="$root/package-signature-$$.der"
trap 'code=$?; rm -f "$signature_file"; if (( code != 0 )); then write_status failed "$version" 0 "更新未完成（错误码 $code），请查看 worker.log 后重试"; fi' EXIT
printf '%s' "$package_signature" | /usr/bin/base64 -D > "$signature_file"
/usr/bin/openssl dgst -sha256 -verify "$public_key" \
  -signature "$signature_file" "$archive" >/dev/null || exit 8
rm -f "$signature_file"

# The Mac archive has exactly one BobTV.app root; never extract another path.
unzip -tqq "$archive"
read -r entry_count _ expanded_bytes _ <<< "$(unzip -Z -t "$archive")"
[[ "$entry_count" =~ ^[0-9]+$ && "$expanded_bytes" =~ ^[0-9]+$ ]] || exit 7
(( entry_count <= 5000 && expanded_bytes <= 2000000000 )) || exit 7
while IFS= read -r entry; do
  [[ "$entry" == BobTV.app/* && "$entry" != *'../'* &&
     "$entry" != *'\'* && "$entry" != *//* ]] || exit 7
done < <(unzip -Z1 "$archive")

stage="$root/Stage/${version//+/_}-$$"
mkdir -p "$stage"
ditto -x -k "$archive" "$stage"
while IFS= read -r -d '' link; do
  resolved="$(/bin/realpath "$link")" || exit 7
  [[ "$resolved" == "$stage/"* ]] || exit 7
done < <(find "$stage" -type l -print0)
replacement="$stage/BobTV.app"
[[ -f "$replacement/Contents/MacOS/BobTV" ]] || exit 7
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$replacement/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$replacement/Contents/Info.plist")"
[[ "$short_version+$build_number" == "$version" ]] || exit 7
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$replacement/Contents/Info.plist")" == 'com.briconbric.bobtv' ]] || exit 7
machine_arch="$(uname -m)"
for binary in \
  "$replacement/Contents/MacOS/BobTV" \
  "$replacement/Contents/Resources/AirPlay/bobtv-airplay/bobtv-airplay" \
  "$replacement/Contents/Resources/AirPlay/bobtv-airplay/fpsap-auth"; do
  [[ -f "$binary" && " $(lipo -archs "$binary") " == *" $machine_arch "* ]] || exit 7
done
codesign --verify --deep --strict "$replacement"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$app/Contents/Info.plist")" == 'com.briconbric.bobtv' ]] || exit 8
write_status ready "$version" 100

wait_for_exit
[[ -w "$(dirname "$app")" ]] || exit 9
backup="$root/Backups/${version//+/_}-$(date +%s)-$$"
write_status backingUp "$version" 0
mkdir -p "$backup"
ditto "$app" "$backup/BobTV.app"
diff -qr "$app" "$backup/BobTV.app" >/dev/null || exit 9
old="$app.bobtv-previous-$$"
write_status installing "$version" 100
mv "$app" "$old"
if ! mv "$replacement" "$app"; then
  mv "$old" "$app"
  write_status failed "$version" 0
  exit 10
fi
printf '%s\n%s\n0\n%s\n' "$version" "$backup" "$app" > "$candidate.tmp"
mv -f "$candidate.tmp" "$candidate"
rm -rf "$old"
write_status installed "$version" 100
