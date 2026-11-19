#!/usr/bin/env bash
#
# Keep the "Texts to answer" to-do list (todo.texts_to_answer) in step with
# three inputs, so unanswered texts are flagged and a reply or a glance clears
# them. Called by the `sms_flags_sync` automation in packages/sms_flags.yaml
# (via shell_command.sms_flags_sync) when sensor.sms_answered changes, every 15
# minutes and at HA start. Runs inside the HA Core container, where
# SUPERVISOR_TOKEN is injected (same auth as sms-inbox-export.sh).
#
# Usage: sms-flags-sync.sh <sources-dir>
#
# Inputs
#   <sources-dir>/sms_flags.json   written by the Claude pass (the judgment
#       layer, on a claytonia worker):
#         { "generated_at", "inbox_exported_at",
#           "flags": [ { "sender", "received", "gist" } ] }
#       `sender` and `received` are copied verbatim from the inbox entry the
#       flag is about; `gist` is one line on what the sender needs, never the
#       text. A missing or unreadable file is "no flags".
#   sensor.sms_inbox               the texts, to check each flag names a real
#                                  inbox entry and that its gist is not the text
#   sensor.sms_answered            the answered ledger: { peer, name, at, via }
#   todo.texts_to_answer           the open and completed stubs
#
# What one run does
#   1. Complete every open stub answered since it arrived: a ledger entry
#      whose peer or name matches the stub's sender and whose `at` is not
#      before the stub's `received`.
#   2. Add a stub for every valid flag that has none (open or completed), is
#      under 72 h old, and has not been answered.
#   3. Remove completed stubs 96 h after their text arrived. The text left the
#      inbox at 72 h, so nothing can re-flag it.
# A stub is { summary: "<sender>: <gist>", description: {"s": sender,
# "r": received} as JSON }. It holds no message text, which is what lets it
# outlive the 72-hour inbox window.
#
# Rules it keeps
#   - Message text is read in one jq process and never reaches a file, a shell
#     variable, a command line or a log. The inbox state reaches jq through a
#     process substitution, and jq's stderr is discarded (a jq error can quote
#     the value it failed on). Log lines carry counts only.
#   - If any read fails, nothing is changed: a half-read ledger must not
#     complete stubs, and a missing inbox must not add them.
#   - The script never deletes a file. It only reads the share.
#
# Environment: SUPERVISOR_TOKEN (required), SUPERVISOR_BASE, SMS_FLAGS_LOG
# (default /config/sms-flags-sync.log), SMS_EXPORT_ALLOW_LOCAL=1 and
# SMS_EXPORT_SHARE_TIMEOUT (tests; shared with sms-inbox-export.sh).
#
# Exit codes: 0 synced; 1 a read or a write failed; 2 usage error or the
# sources dir refused.
set -euo pipefail

# shellcheck source=sms-inbox-export.sh disable=SC1091
source "${BASH_SOURCE[0]%/*}/sms-inbox-export.sh"
# shellcheck disable=SC2034  # read by log() and rotate_log() in sms-inbox-export.sh
LOG_FILE="${SMS_FLAGS_LOG:-/config/sms-flags-sync.log}"

readonly FLAGS_FILE_NAME="sms_flags.json"
readonly TODO_ENTITY="todo.texts_to_answer"
readonly ANSWERED_ENTITY="sensor.sms_answered"
readonly FLAG_MAX_AGE_HOURS=72
readonly STUB_KEEP_HOURS=96

api() { # <path> [json-body]
  local path="$1"
  if (($# > 1)); then
    curl -fsS --max-time 20 -X POST \
      -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
      -H 'Content-Type: application/json' \
      --data "$2" "${SUPERVISOR_BASE}/core/api/${path}"
  else
    curl -fsS --max-time 20 \
      -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
      "${SUPERVISOR_BASE}/core/api/${path}"
  fi
}

fetch_todo() {
  api 'services/todo/get_items?return_response' \
    "{\"entity_id\":\"${TODO_ENTITY}\",\"status\":[\"needs_action\",\"completed\"]}"
}

# stdin: nothing. Args: --argjson now, --argjson max_age, --argjson keep.
# Inputs by name: $flags (array), $todo, $ans, $inbox (entity state objects).
# Output: {complete: [uid], add: [{item, description}], remove: [uid],
#          dropped: n}. Errors (and so changes nothing) when an input is not
# the shape it should be.
# shellcheck disable=SC2016  # $vars below are jq's
readonly PLAN_JQ='
def ts: capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$")
  | (.d + "Z" | fromdateiso8601)
    - (if .z == "Z" then 0
       else ((.z[1:3] | tonumber) * 3600 + (.z[4:6] | tonumber) * 60)
            * (if .z[0:1] == "-" then -1 else 1 end) end);
def tsn: try ts catch null;
def norm: tostring | ascii_downcase
  | if test("^[+0-9 ()._-]{7,}$") then gsub("[^0-9]"; "") | .[-10:]
    else gsub("[^a-z0-9]"; "") end;
def lbl: if . == null or . == "" then "Unknown sender" else tostring end;
def meta: (.description // "" | try fromjson catch {}) | select(type == "object");

($todo.service_response[$ENTITY].items // error("no todo items")) as $items
| ($ans.attributes.answers // error("no answered ledger")) as $answers
| ($inbox.attributes.messages // error("no inbox")) as $msgs
| ($items | map(select(.status == "needs_action"))) as $open
| ($items | map(meta | select(.s != null and .r != null) | "\(.s)|\(.r)")) as $have
| def answered($s; $r):
    ($r | tsn) as $rt
    | $rt != null and any($answers[];
        ((.at | tsn) // 0) >= $rt
        and (([.peer, .name] | map(select(. != null and . != "") | norm))
             | any(. == ($s | norm))));
  {
    complete: [ $open[] | (meta) as $m
      | select($m != null and $m.s != null and $m.r != null and answered($m.s; $m.r))
      | .uid ],
    remove: [ $items[] | select(.status == "completed") | (meta) as $m
      | select($m != null and (($m.r | tsn) // $now) < ($now - $keep * 3600))
      | .uid ],
    add: ( [ $flags[]
        | select(type == "object" and (.received | type) == "string" and (.gist | type) == "string")
        | (.sender | lbl) as $s
        | (.gist | gsub("[\\r\\n\\t]+"; " ") | gsub("^ +| +$"; "") | .[0:160]) as $g
        | select($g != "")
        | . as $f
        | select(($f.received | tsn) as $rt | $rt != null and $rt > ($now - $max_age * 3600))
        # Must name a real inbox entry, and say something other than its text.
        | select(any($msgs[]; ((.sender | lbl) == $s) and .received == $f.received
              and ((.text // "") as $t | ($t | length) < 12 or ($g | contains($t) | not))))
        | select(($have | index("\($s | .[0:80])|\($f.received)")) == null)
        | select(answered($s; $f.received) | not)
        | {item: "\($s | .[0:80]): \($g)",
           description: ({s: ($s | .[0:80]), r: $f.received} | tojson)} ]
      | unique_by(.description) ),
    dropped: ($flags | length)
  }'

sms_flags_sync() {
  local dir="${1:-}"
  if [[ -z "$dir" || $# -ne 1 ]]; then
    echo "usage: sms-flags-sync.sh <sources-dir>" >&2
    return 2
  fi
  dir="${dir%/}"
  if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
    log ERROR "SUPERVISOR_TOKEN is not set; run inside the HA Core container"
    return 2
  fi
  check_export_dir "$dir" || return

  # The flags file holds gists and senders, never text. No file, a bad file or
  # the wrong shape is "no flags".
  local flags
  flags="$(timeout "$SHARE_TIMEOUT" jq -c 'if (.flags | type) == "array" then .flags else [] end' \
    "${dir}/${FLAGS_FILE_NAME}" 2>/dev/null)" || flags='[]'
  [[ -n "$flags" ]] || flags='[]'

  local plan rc=0
  # Stored on its own line so jq's exit status survives; the sensor states pass
  # through process substitutions, never a variable or a file.
  # shellcheck disable=SC2016
  plan="$(jq -n -c \
    --arg ENTITY "$TODO_ENTITY" \
    --argjson now "$(date -u +%s)" \
    --argjson max_age "$FLAG_MAX_AGE_HOURS" \
    --argjson keep "$STUB_KEEP_HOURS" \
    --argjson flags "$flags" \
    --slurpfile todo <(fetch_todo 2>/dev/null) \
    --slurpfile ans <(api "states/${ANSWERED_ENTITY}" 2>/dev/null) \
    --slurpfile inbox <(api "states/sensor.sms_inbox" 2>/dev/null) \
    "(\$todo[0]) as \$todo | (\$ans[0]) as \$ans | (\$inbox[0]) as \$inbox | ${PLAN_JQ}" \
    2>/dev/null)" || rc=$?
  if ((rc != 0)) || [[ -z "$plan" ]]; then
    log ERROR "could not build the sync plan (a read failed or an input was not the expected shape, jq exit ${rc}); changed nothing"
    return 1
  fi

  local n_add=0 n_done=0 n_rm=0 failed=0 line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if api 'services/todo/update_item' \
      "$(jq -c --arg e "$TODO_ENTITY" '{entity_id: $e, item: ., status: "completed"}' <<<"$line")" >/dev/null 2>&1; then
      n_done=$((n_done + 1))
    else failed=$((failed + 1)); fi
  done < <(jq -c '.complete[]' <<<"$plan")
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if api 'services/todo/add_item' \
      "$(jq -c --arg e "$TODO_ENTITY" '. + {entity_id: $e}' <<<"$line")" >/dev/null 2>&1; then
      n_add=$((n_add + 1))
    else failed=$((failed + 1)); fi
  done < <(jq -c '.add[]' <<<"$plan")
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if api 'services/todo/remove_item' \
      "$(jq -c --arg e "$TODO_ENTITY" '{entity_id: $e, item: [.]}' <<<"$line")" >/dev/null 2>&1; then
      n_rm=$((n_rm + 1))
    else failed=$((failed + 1)); fi
  done < <(jq -c '.remove[]' <<<"$plan")

  if ((failed > 0)); then
    log ERROR "synced with ${failed} failed write(s): added ${n_add}, completed ${n_done}, removed ${n_rm}"
    return 1
  fi
  log INFO "synced: added ${n_add}, completed ${n_done}, removed ${n_rm} (of $(jq '.dropped' <<<"$plan") flags in the file)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rotate_log
  sms_flags_sync "$@"
fi
