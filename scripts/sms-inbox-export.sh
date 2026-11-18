#!/usr/bin/env bash
#
# Mirror sensor.sms_inbox's `messages` to a JSON file on the NAS job share, so
# the agent fleet reads Chris's texts from a copy and no worker holds an HA
# token. Called by the `sms_inbox_export` automation in
# packages/sms_inbox.yaml (via shell_command.sms_inbox_export) on every change
# to the sensor, every 15 minutes and at HA start. Runs inside the HA Core
# container, where SUPERVISOR_TOKEN is injected (same auth as force-sync.sh).
#
# Usage: sms-inbox-export.sh <export-dir>
#
# Writes <export-dir>/sms_inbox.json:
#   { "exported_at": "<UTC, ISO 8601>", "messages": [ <the sensor's entries, unchanged> ] }
#
# Rules it keeps (packages/sms_inbox.yaml, "The NAS copy"):
#   - Message text never passes through a shell string or a command line. The
#     state goes from curl to jq through a pipe, and jq writes the file.
#   - Nothing it prints or logs carries message text. jq's stderr is discarded,
#     because a jq error can quote the value it failed on; log lines name only
#     counts, paths and exit codes.
#   - Write-then-rename, never in place: jq writes .sms_inbox.json.partial,
#     which is renamed over sms_inbox.json only once jq has succeeded, so a
#     reader sees the old file or the new one, never half of one.
#   - It never deletes a file on the share. The share's Samba recycle bin keeps
#     every deleted file, so a deleted copy would outlive the 72-hour retention.
#     A rename over the target does not reach the recycle bin (checked on the
#     live share, 2026-11-17); a failed run leaves the partial for the next run
#     to overwrite.
#   - The export dir must already exist and be on a network share (smb2, cifs
#     or nfs). An unmounted share looks like an empty local directory, and the
#     texts would land on HAOS's own disk. SMS_EXPORT_ALLOW_LOCAL=1 lifts the
#     network check for tests.
#   - A sensor with no `messages` list (unavailable, or HA still starting)
#     leaves the last file alone: an unavailable sensor is not an empty inbox.
#     An empty list is written as an empty list.
#
# Environment: SUPERVISOR_TOKEN (required), SUPERVISOR_BASE (default
# http://supervisor), SMS_EXPORT_LOG (default /config/sms-inbox-export.log),
# SMS_EXPORT_ALLOW_LOCAL=1 (tests).
#
# Exit codes: 0 written; 1 the state could not be read or the file could not be
# written (the last file is left alone); 2 usage error or export dir refused.
set -euo pipefail

readonly SUPERVISOR_BASE="${SUPERVISOR_BASE:-http://supervisor}"
readonly ENTITY="sensor.sms_inbox"
readonly FILE_NAME="sms_inbox.json"
readonly LOG_MAX_BYTES=262144

LOG_FILE="${SMS_EXPORT_LOG:-/config/sms-inbox-export.log}"

log() {
  local level="$1"
  shift
  local line
  line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$level] $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
}

rotate_log() {
  if [[ -f "$LOG_FILE" ]] && (($(wc -c <"$LOG_FILE") >= LOG_MAX_BYTES)); then
    mv -f "$LOG_FILE" "${LOG_FILE}.1"
  fi
}

# Refuse an export dir that is missing or (unless allowed) not on a network
# share. statfs's type number, not its name: BusyBox and GNU stat both print
# the hex, and they name SMB2 differently. smb2 fe534d42, cifs ff534d42,
# nfs 6969.
check_export_dir() {
  local dir="$1" fstype
  if [[ ! -d "$dir" ]]; then
    log ERROR "export dir not found: ${dir}. Is the NAS share mounted (Settings > System > Storage)? Its sources/ folder must exist on the NAS."
    return 2
  fi
  fstype="$(stat -f -c '%t' "$dir" 2>/dev/null || echo unknown)"
  case "$fstype" in
    fe534d42 | ff534d42 | 6969) ;;
    *)
      if [[ "${SMS_EXPORT_ALLOW_LOCAL:-0}" != "1" ]]; then
        log ERROR "export dir is not on a network share (filesystem type ${fstype}); is the NAS share mounted? ${dir}"
        return 2
      fi
      ;;
  esac
}

fetch_state() {
  curl -fsS --max-time 20 \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    "${SUPERVISOR_BASE}/core/api/states/${ENTITY}"
}

# stdin: the entity's state object from the Core API. stdout: the file.
build_export() {
  jq -e --arg exported_at "$1" '
    if (.attributes.messages | type) == "array"
    then {exported_at: $exported_at, messages: .attributes.messages}
    else error("no messages list")
    end'
}

sms_inbox_export() {
  local dir="${1:-}"
  if [[ -z "$dir" || $# -ne 1 ]]; then
    echo "usage: sms-inbox-export.sh <export-dir>" >&2
    return 2
  fi
  dir="${dir%/}"
  if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
    log ERROR "SUPERVISOR_TOKEN is not set; run inside the HA Core container"
    return 2
  fi
  check_export_dir "$dir" || return

  local target="${dir}/${FILE_NAME}"
  local partial="${dir}/.${FILE_NAME}.partial"
  local exported_at
  exported_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Truncating, not deleting: see the recycle-bin rule above.
  if ! { : >"$partial"; } 2>/dev/null; then
    log ERROR "cannot write ${partial}; left the last file alone"
    return 1
  fi

  set +e
  fetch_state 2>>"$LOG_FILE" | build_export "$exported_at" >"$partial" 2>/dev/null
  local -a rc=("${PIPESTATUS[@]}")
  set -e
  if ((rc[0] != 0)); then
    log ERROR "could not read ${ENTITY} from the Core API (curl exit ${rc[0]}); left the last file alone"
    return 1
  fi
  if ((rc[1] != 0)); then
    log ERROR "${ENTITY} has no messages list (unavailable or starting?) or the partial could not be written (jq exit ${rc[1]}); left the last file alone"
    return 1
  fi

  if ! mv -f "$partial" "$target"; then
    log ERROR "could not rename ${partial} over ${target}; left the last file alone"
    return 1
  fi

  local count
  count="$(jq '.messages | length' "$target" 2>/dev/null || echo '?')"
  log INFO "wrote ${count} messages to ${target}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rotate_log
  sms_inbox_export "$@"
fi
