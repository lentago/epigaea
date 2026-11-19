#!/usr/bin/env bash
#
# Mirror sensor.sms_inbox's `messages` to a JSON file on the NAS job share, so
# the agent fleet reads Chris's texts from a copy and no worker holds an HA
# token. Called by the `sms_inbox_export` automation in
# packages/sms_inbox.yaml (via shell_command.sms_inbox_export) on every change
# to the sensor, every 15 minutes and at HA start. Runs inside the HA Core
# container. It reads the sensor from Core's own API at 127.0.0.1:8123 with a
# long-lived access token (below): Core's SUPERVISOR_TOKEN is for calls out to
# the Supervisor, and Core's API does not accept it.
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
#   - A sensor with no `messages` list (unavailable, or HA still starting), or
#     a failed read, leaves the last file alone: an unavailable sensor is not
#     an empty inbox. That holds until the last good export is older than the
#     retention window. By then every entry in the file has expired, since all
#     of them arrived before its exported_at, so the run empties `messages` and
#     keeps exported_at, which still tells a reader the export has stalled. An
#     empty inbox is written as an empty list.
#   - Every call that touches the share has a timeout (SHARE_TIMEOUT seconds),
#     so a hung mount ends the run with a log line rather than at HA's
#     60-second shell_command limit.
#
# Token: HA_TOKEN in the environment, else `ha_token` in /config/secrets.yaml
# (the repo's convention, scripts/README.md "Authentication"; a long-lived
# access token, with or without the "Bearer " prefix). It is handed to curl on
# stdin, never on a command line.
#
# Environment: HA_TOKEN, SMS_SECRETS_YAML (default /config/secrets.yaml),
# CORE_API_BASE (default http://127.0.0.1:8123/api), SMS_EXPORT_LOG (default /config/sms-inbox-export.log),
# SMS_EXPORT_ALLOW_LOCAL=1 and SMS_EXPORT_SHARE_TIMEOUT (tests).
#
# Exit codes: 0 written; 1 the state could not be read or the file could not be
# written (the last file is left alone, or emptied once expired); 2 usage error
# or export dir refused.
set -euo pipefail

readonly CORE_API_BASE="${CORE_API_BASE:-http://127.0.0.1:8123/api}"
readonly SMS_SECRETS_YAML="${SMS_SECRETS_YAML:-/config/secrets.yaml}"
readonly ENTITY="sensor.sms_inbox"
readonly FILE_NAME="sms_inbox.json"
readonly LOG_MAX_BYTES=262144
# Must match max_age_hours in packages/sms_inbox.yaml; a test checks it.
readonly RETENTION_HOURS=72
readonly SHARE_TIMEOUT="${SMS_EXPORT_SHARE_TIMEOUT:-15}"

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
  local dir="$1" fstype rc=0
  fstype="$(timeout "$SHARE_TIMEOUT" stat -f -c '%t' "$dir" 2>/dev/null)" || rc=$?
  if ((rc == 124)); then
    log ERROR "export dir did not answer within ${SHARE_TIMEOUT} s; is the NAS reachable? ${dir}"
    return 2
  fi
  if ((rc != 0)) || [[ ! -d "$dir" ]]; then
    log ERROR "export dir not found: ${dir}. Is the NAS share mounted (Settings > System > Storage)? Its sources/ folder must exist on the NAS."
    return 2
  fi
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

# The long-lived token, bare. Sets HA_BARE_TOKEN; returns 1 when there is none.
resolve_ha_token() {
  local t="${HA_TOKEN:-}"
  if [[ -z "$t" && -f "$SMS_SECRETS_YAML" ]]; then
    t="$(awk -F'"' '/^ha_token:/ {print $2; exit}' "$SMS_SECRETS_YAML" 2>/dev/null)" || t=""
  fi
  t="${t#Bearer }"
  [[ -n "$t" ]] || return 1
  HA_BARE_TOKEN="$t"
}

# curl against Core's API with the token on stdin (-K -), so it never shows in
# a process list. Arguments are curl's own.
core_curl() {
  printf 'header = "Authorization: Bearer %s"\n' "$HA_BARE_TOKEN" | curl -K - "$@"
}

fetch_state() {
  core_curl -fsS --max-time 20 "${CORE_API_BASE}/states/${ENTITY}"
}

# stdin: the entity's state object from the Core API. stdout: the file.
build_export() {
  jq -e --arg exported_at "$1" '
    if (.attributes.messages | type) == "array"
    then {exported_at: $exported_at, messages: .attributes.messages}
    else error("no messages list")
    end'
}

# Called when the sensor could not be read. If the last good export is older
# than the retention window, every entry in the file has expired: empty
# `messages`, keep exported_at, and write-then-rename like any update. A file
# that is recent, already empty or unreadable is left alone.
expire_stale_copy() {
  local target="$1" partial="$2"
  [[ -f "$target" ]] || return 0
  # $max is a jq variable, not a shell one (shellcheck exempts bare jq calls,
  # not jq under timeout).
  # shellcheck disable=SC2016
  if ! timeout "$SHARE_TIMEOUT" jq -e --argjson max "$((RETENTION_HOURS * 3600))" \
    '(.messages | length) > 0 and (now - (.exported_at | fromdateiso8601)) > $max' \
    "$target" >/dev/null 2>&1; then
    return 0
  fi
  if timeout "$SHARE_TIMEOUT" jq '.messages = []' "$target" >"$partial" 2>/dev/null &&
    timeout "$SHARE_TIMEOUT" mv -f "$partial" "$target"; then
    log WARNING "the last export is older than ${RETENTION_HOURS} h, so its texts have expired; emptied messages and kept exported_at in ${target}"
  else
    log ERROR "the last export is older than ${RETENTION_HOURS} h, but ${target} could not be emptied"
  fi
}

sms_inbox_export() {
  local dir="${1:-}"
  if [[ -z "$dir" || $# -ne 1 ]]; then
    echo "usage: sms-inbox-export.sh <export-dir>" >&2
    return 2
  fi
  dir="${dir%/}"
  if ! resolve_ha_token; then
    log ERROR "no HA token: set ha_token in ${SMS_SECRETS_YAML} (a long-lived access token; scripts/README.md, Authentication)"
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
    expire_stale_copy "$target" "$partial"
    return 1
  fi
  if ((rc[1] != 0)); then
    log ERROR "${ENTITY} has no messages list (unavailable or starting?) or the partial could not be written (jq exit ${rc[1]}); left the last file alone"
    expire_stale_copy "$target" "$partial"
    return 1
  fi

  if ! timeout "$SHARE_TIMEOUT" mv -f "$partial" "$target"; then
    log ERROR "could not rename ${partial} over ${target} within ${SHARE_TIMEOUT} s; left the last file alone"
    return 1
  fi

  local count
  count="$(timeout "$SHARE_TIMEOUT" jq '.messages | length' "$target" 2>/dev/null || echo '?')"
  log INFO "wrote ${count} messages to ${target}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rotate_log
  sms_inbox_export "$@"
fi
