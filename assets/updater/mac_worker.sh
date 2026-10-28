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
candidate_token="${11:-}"
[[ -z "$run_id" || "$run_id" =~ ^[A-Za-z0-9-]{1,100}$ ]] || exit 2
[[ -z "$candidate_token" || "$candidate_token" =~ ^[a-f0-9]{64}$ ]] || exit 2

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
  if [[ "${last_phase:-}" != "$phase" ]]; then
    last_phase="$phase"
    printf '%s phase=%s version=%s run=%s\n' "$(date -u +%FT%TZ)" "$phase" "$shown_version" "$run_id"
  fi
  if [[ -z "$message" ]]; then
    case "$phase" in
      starting) message='正在准备更新' ;;
      downloading) message='正在下载更新' ;;
      verifying) message='正在校验文件、签章和安装包内容' ;;
      ready) message='已下载并校验通过，关闭 BobTV 后自动安装' ;;
      backingUp) message='正在准备临时回退文件，请稍候' ;;
      installing) message='正在安装更新，请稍候' ;;
      installed) message='安装完成，新版通过启动检查后自动清理临时回退文件' ;;
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

wait_for_app_idle() {
  local active found
  while true; do
    active=false
    while IFS= read -r found; do
      [[ -z "$found" ]] && continue
      if [[ "$(ps -p "$found" -o comm= 2>/dev/null || true)" == "$app/Contents/MacOS/BobTV" ]]; then active=true; fi
    done < <(pgrep -x BobTV || true)
    [[ "$active" == false ]] && return 0
    sleep 2
  done
}

failure_exit() {
  local code=$? message
  [[ -z "${signature_file:-}" ]] || rm -f "$signature_file"
  (( code != 0 )) || return 0
  case "$code" in
    6) message='更新包完整性校验失败，请重新下载' ;;
    7) message='安装包内容、版本或平台不匹配，已停止安装' ;;
    8) message='更新签章校验未通过，已停止安装' ;;
    9) message='安装目录无法写入，请将 BobTV 放到当前用户可写的应用程序目录' ;;
    11) message='当前版本的启动检查未完成，请稍后重试' ;;
    12) message='另一份 BobTV 正在运行，请关闭另一份后重试更新' ;;
    22|28|35|56) message='更新下载连接失败或超时，请检查网络后重试' ;;
    *) message="更新未完成（错误码 $code），请查看 worker.log 后重试" ;;
  esac
  write_status failed "$version" 0 "$message"
}

candidate_digest() {
  local digest
  digest="$(/usr/bin/openssl dgst -sha256 "$candidate")" || return 1
  printf '%s' "${digest##* }"
}

valid_rollback_path() {
  local leaf
  [[ "$backup" == "$root/Backups/"* && ! -L "$root" &&
     ! -L "$root/Backups" && ! -L "$backup" ]] || return 1
  leaf="${backup#"$root/Backups/"}"
  [[ "$leaf" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

finish_startup() {
  /usr/bin/lockf -t 10 "$root/startup.lock" /bin/bash "$0" \
    startup-locked "$root" "$app" "$watched_pid" '' '' '' '' '' '' "$candidate_token"
}

if [[ "$mode" == 'monitor' ]]; then
  [[ -f "$candidate" ]] || exit 0
  candidate_token="$(candidate_digest)"
  seconds=0
  while kill -0 "$watched_pid" 2>/dev/null; do
    [[ -f "$candidate" ]] || exit 0
    [[ -f "$healthy" && "$(cat "$healthy")" == "$watched_pid" ]] && break
    sleep 2
    seconds=$((seconds + 2))
    (( seconds < 43200 )) || exit 3
  done
  finish_startup
  exit 0
fi

if [[ "$mode" == 'startup-locked' ]]; then
  [[ -f "$candidate" ]] || exit 0
  # A monitor from an earlier launch must never remove a newer candidate.
  [[ -n "$candidate_token" && "$(candidate_digest)" == "$candidate_token" ]] || exit 0
  candidate_version="$(sed -n '1p' "$candidate")"
  backup="$(sed -n '2p' "$candidate")"
  previous_attempts="$(sed -n '3p' "$candidate")"
  candidate_app="$(sed -n '4p' "$candidate")"
  [[ "$candidate_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ &&
     "$previous_attempts" =~ ^[0-2]$ &&
     "$candidate_app" == "$app" ]] || exit 4
  valid_rollback_path || exit 4
  if [[ -f "$healthy" && "$(cat "$healthy")" == "$watched_pid" ]]; then
    # This is the sole pending rollback, not a permanent per-version backup.
    # Keep the small PID receipt so startup checks can observe it. The app
    # removes its own marker after writing the receipt.
    rm -rf "$backup"
    rm -f "$candidate"
    printf '%s temporary rollback cleared after healthy startup version=%s\n' \
      "$(date -u +%FT%TZ)" "$candidate_version"
    exit 0
  fi
  kill -0 "$watched_pid" 2>/dev/null && exit 11
  [[ -f "$marker" && "$(cat "$marker")" == "$watched_pid" ]] || exit 0
  attempts=$(( previous_attempts + 1 ))
  rm -f "$marker"
  if (( attempts < 3 )); then
    printf '%s\n%s\n%s\n%s\n' "$candidate_version" "$backup" \
      "$attempts" "$app" > "$candidate.tmp"
    mv -f "$candidate.tmp" "$candidate"
    exit 0
  fi
  [[ -d "$backup/BobTV.app" && ! -L "$backup/BobTV.app" &&
     -w "$(dirname "$app")" ]] || exit 4
  failed="$root/FailedApps/$candidate_version-$(date +%s)"
  mkdir -p "$failed"
  mv "$app" "$failed/BobTV.app"
  if ! mv "$backup/BobTV.app" "$app"; then
    mv "$failed/BobTV.app" "$app"
    exit 5
  fi
  rmdir "$backup"
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
[[ ( "$archive_url" == https://bobtv.briconbric.com/updates/*.zip ||
     "$archive_url" == https://cndrp.com/bobtv/updates/*.zip ) &&
   "$archive_url" != *'?'* && "$archive_url" != *'#'* ]] || exit 2
if [[ -f "$skipped" ]] && grep -Fxq "$version" "$skipped"; then exit 0; fi
trap failure_exit EXIT
# A shared support directory may contain a pending record from a test build or
# another installation. Keep its rollback evidence, without blocking this app.
if [[ -f "$candidate" && "$(sed -n '4p' "$candidate")" != "$app" ]]; then
  foreign_app="$(sed -n '4p' "$candidate")"
  while IFS= read -r other_pid; do
    [[ -z "$other_pid" ]] && continue
    if [[ "$(ps -p "$other_pid" -o comm= 2>/dev/null || true)" == "$foreign_app/Contents/MacOS/BobTV" ]]; then
      exit 12
    fi
  done < <(pgrep -x BobTV || true)
  mkdir -p "$root/DeferredCandidates"
  deferred="$(mktemp -d "$root/DeferredCandidates/foreign.XXXXXX")"
  mv "$candidate" "$deferred/candidate.txt"
  for receipt in "$marker" "$healthy"; do
    [[ ! -f "$receipt" ]] || mv "$receipt" "$deferred/"
  done
  printf '%s foreign installation startup state preserved in %s\n' "$(date -u +%FT%TZ)" "$deferred"
fi
if [[ -f "$candidate" ]]; then
  candidate_token="$(candidate_digest)"
  write_status starting "$version" 0 '等待当前版本完成启动检查'
  for (( attempt=0; attempt<90; attempt++ )); do
    [[ ! -f "$candidate" ]] && break
    [[ -f "$healthy" && "$(cat "$healthy")" == "$watched_pid" ]] && break
    sleep 1
  done
  if [[ -f "$candidate" ]]; then
    [[ -f "$healthy" && "$(cat "$healthy")" == "$watched_pid" &&
        "$(sed -n '4p' "$candidate")" == "$app" ]] || exit 11
    finish_startup
    [[ ! -f "$candidate" ]] || exit 11
  fi
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
printf 'integrity bytes actual=%s expected=%s\n' "$received_bytes" "$expected_bytes"
[[ "$received_bytes" == "$expected_bytes" ]] || exit 6
# Use the system crypto binary, independent of the player's inherited PATH or
# Perl environment. The same binary verifies the publisher signature below.
digest_output="$(/usr/bin/openssl dgst -sha256 "$partial")"
actual_hash="${digest_output##* }"
expected_hash="$(printf '%s' "$expected_hash" | tr '[:upper:]' '[:lower:]')"
printf 'integrity sha256 actual=%s expected=%s\n' "$actual_hash" "$expected_hash"
[[ "$actual_hash" =~ ^[a-f0-9]{64}$ ]] || exit 6
[[ "$actual_hash" == "$expected_hash" ]] || exit 6
mv -f "$partial" "$archive"
public_key="$root/update-signing-public.pem"
[[ -f "$public_key" && ! -L "$public_key" ]] || exit 8
signature_file="$root/package-signature-$$.der"
trap failure_exit EXIT
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
# Preserve an installed certificate-backed app identity. Never replace it with
# ad-hoc code or another publisher, even if the update archive is authenticated.
installed_signing="$(codesign -d -r- --verbose=2 "$app" 2>&1 || true)"
installed_team="$(printf '%s\n' "$installed_signing" | sed -n 's/^TeamIdentifier=//p')"
if [[ -n "$installed_team" && "$installed_team" != 'not set' ]]; then
  installed_requirement="$(printf '%s\n' "$installed_signing" | sed -n 's/^designated => //p')"
  [[ -n "$installed_requirement" ]] || exit 7
  codesign --verify --strict -R "$installed_requirement" "$replacement"
fi

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$app/Contents/Info.plist")" == 'com.briconbric.bobtv' ]] || exit 8
write_status ready "$version" 100

wait_for_exit
[[ -w "$(dirname "$app")" ]] || exit 9
wait_for_app_idle
backup="$root/Backups/${version//+/_}-$(date +%s)-$$"
valid_rollback_path || exit 9
write_status backingUp "$version" 0
mkdir -p "$backup"
# Move the existing bundle once; do not make another full copy of every release.
mv "$app" "$backup/BobTV.app"
write_status installing "$version" 100
if ! mv "$replacement" "$app"; then
  mv "$backup/BobTV.app" "$app"
  rmdir "$backup"
  write_status failed "$version" 0
  exit 10
fi
rm -f "$marker" "$healthy"
printf '%s\n%s\n0\n%s\n' "$version" "$backup" "$app" > "$candidate.tmp"
mv -f "$candidate.tmp" "$candidate"
write_status installed "$version" 100
