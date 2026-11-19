#!/usr/bin/env bats
#
# Tests for scripts/sms-inbox-export.sh, which mirrors sensor.sms_inbox's
# `messages` to sms_inbox.json on the NAS job share for the agent fleet. The
# suite sources the script, stubs `curl` to return a canned entity state, and
# points the export at a temp directory (SMS_EXPORT_ALLOW_LOCAL=1, since the
# temp dir is local disk, not the share).
#
# What it guards: message text is arbitrary and reaches the file through jq
# only, unchanged; nothing printed or logged carries text; a sensor with no
# list or a failed read leaves the last file alone; the file is replaced by
# rename; the script never deletes a file (the share's recycle bin would keep
# it); and the package wiring passes no template to the shell and stores no
# automation traces.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/sms-inbox-export.sh"
  PACKAGE="${BATS_TEST_DIRNAME}/../packages/sms_inbox.yaml"
  # shellcheck source=../scripts/sms-inbox-export.sh
  source "$SCRIPT"

  EXPORT_DIR="${BATS_TEST_TMPDIR}/sources"
  mkdir -p "$EXPORT_DIR"
  TARGET="${EXPORT_DIR}/sms_inbox.json"
  STATE_FILE="${BATS_TEST_TMPDIR}/state.json"
  export SMS_EXPORT_LOG="${BATS_TEST_TMPDIR}/export.log"
  LOG_FILE="$SMS_EXPORT_LOG"
  export SMS_EXPORT_ALLOW_LOCAL=1
  export HA_TOKEN=test-token
  export STATE_FILE
  ARGS_LOG="${BATS_TEST_TMPDIR}/args.log"; AUTH_LOG="${BATS_TEST_TMPDIR}/auth.log"
  export ARGS_LOG AUTH_LOG

  # Text a shell would mangle or run if it ever passed through a command line.
  SENTINEL="SENTINEL-7f3a9c"
  NASTY=$'it\'s "quoted" $(touch /tmp/pwned) `id` \\ back\\slash\nnew line\ttab %s %n -- --help 🙂 ünïcödé '"$SENTINEL"
  export SENTINEL NASTY

  # The Core API's answer for sensor.sms_inbox: three entries, one hidden.
  jq -n --arg nasty "$NASTY" '{
    entity_id: "sensor.sms_inbox",
    state: "3",
    attributes: {
      messages: [
        {received: "2026-11-17T09:00:00.000001-05:00", posted: 1763388000000,
         sender: "Bob; rm -rf /", text: $nasty, hidden: false},
        {received: "2026-11-17T09:05:00.000001-05:00", posted: 1763388300000,
         sender: null, text: "Sensitive notification content hidden", hidden: true},
        {received: "2026-11-17T09:10:00.000001-05:00", posted: 1763388600000,
         sender: "{\"json\": \"in a name\"}", text: "", hidden: false}
      ],
      retention: "72h, newest 50"
    }
  }' >"$STATE_FILE"

  # curl stub: print the canned state, or fail like `curl -f` on an HTTP error.
  curl() {
    # What curl was given: its arguments, and the -K config on stdin.
    printf '%s\n' "$*" >>"${ARGS_LOG}"
    if [[ " $* " == *" -K "* ]]; then cat >"${AUTH_LOG}"; fi
    if [[ "${CURL_FAIL:-0}" == "1" ]]; then
      echo "curl: (22) The requested URL returned error: 502" >&2
      return 22
    fi
    cat "$STATE_FILE"
  }
  export -f curl
}

# A previous export holding one text, stamped with the given exported_at.
write_prior_export() {
  jq -n --arg at "$1" --arg s "$SENTINEL" \
    '{exported_at: $at, messages: [{received: "x", sender: "Al", text: $s}]}' >"$TARGET"
}

@test "writes exported_at and the sensor's messages, unchanged" {
  run sms_inbox_export "$EXPORT_DIR"
  [ "$status" -eq 0 ]
  [ -f "$TARGET" ]
  jq -e --slurpfile s "$STATE_FILE" '.messages == $s[0].attributes.messages' "$TARGET"
  jq -e 'keys == ["exported_at", "messages"]' "$TARGET"
  jq -e '.exported_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$TARGET"
}

@test "arbitrary message text survives byte for byte" {
  run sms_inbox_export "$EXPORT_DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -j '.messages[0].text' "$TARGET")" == "$NASTY" ]
  [ "$(jq -r '.messages[0].sender' "$TARGET")" == "Bob; rm -rf /" ]
  jq -e '.messages[1].hidden == true and .messages[1].sender == null' "$TARGET"
}

@test "replaces an existing file by rename and leaves no partial" {
  echo '{"exported_at":"old","messages":[]}' >"$TARGET"
  run sms_inbox_export "$EXPORT_DIR"
  [ "$status" -eq 0 ]
  jq -e '.messages | length == 3' "$TARGET"
  [ ! -e "${EXPORT_DIR}/.sms_inbox.json.partial" ]
}

@test "an empty inbox is written as an empty list" {
  jq '.state = "0" | .attributes.messages = []' "$STATE_FILE" >"${STATE_FILE}.new"
  mv "${STATE_FILE}.new" "$STATE_FILE"
  echo '{"exported_at":"old","messages":[{"text":"x"}]}' >"$TARGET"
  run sms_inbox_export "$EXPORT_DIR"
  [ "$status" -eq 0 ]
  jq -e '.messages == []' "$TARGET"
}

@test "a sensor with no messages list leaves a recent file alone" {
  echo '{"entity_id":"sensor.sms_inbox","state":"unavailable","attributes":{}}' >"$STATE_FILE"
  write_prior_export "$(date -u -d '-71 hours' +%Y-%m-%dT%H:%M:%SZ)"
  cp "$TARGET" "${BATS_TEST_TMPDIR}/before"
  run sms_inbox_export "$EXPORT_DIR"
  [ "$status" -eq 1 ]
  cmp -s "$TARGET" "${BATS_TEST_TMPDIR}/before"
  [[ "$output" == *"no messages list"* ]]
}

@test "a failed read leaves a recent file alone" {
  write_prior_export "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
  cp "$TARGET" "${BATS_TEST_TMPDIR}/before"
  CURL_FAIL=1 run sms_inbox_export "$EXPORT_DIR"
  [ "$status" -eq 1 ]
  cmp -s "$TARGET" "${BATS_TEST_TMPDIR}/before"
  [[ "$output" == *"curl exit 22"* ]]
}

@test "a failed read empties a file whose last export is past retention" {
  write_prior_export "2020-01-01T00:00:00Z"
  CURL_FAIL=1 run sms_inbox_export "$EXPORT_DIR"
  [ "$status" -eq 1 ]
  jq -e '.messages == [] and .exported_at == "2020-01-01T00:00:00Z"' "$TARGET"
  [ ! -e "${EXPORT_DIR}/.sms_inbox.json.partial" ]
  [[ "$output" == *"have expired"* ]]
  [[ "$output" != *"$SENTINEL"* ]]
}

@test "an unavailable sensor empties a file whose last export is past retention" {
  echo '{"entity_id":"sensor.sms_inbox","state":"unavailable","attributes":{}}' >"$STATE_FILE"
  write_prior_export "$(date -u -d '-73 hours' +%Y-%m-%dT%H:%M:%SZ)"
  run sms_inbox_export "$EXPORT_DIR"
  [ "$status" -eq 1 ]
  jq -e '.messages == []' "$TARGET"
}

@test "the script's retention matches the package's" {
  pkg="$(grep -E '^[[:space:]]+max_age_hours:' "$PACKAGE" | grep -oE '[0-9]+')"
  [ "$pkg" = "$RETENTION_HOURS" ]
}

@test "a share that does not answer ends the run with a log line" {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/bin/sh\nsleep 5\n' >"${BATS_TEST_TMPDIR}/bin/stat"
  chmod +x "${BATS_TEST_TMPDIR}/bin/stat"
  PATH="${BATS_TEST_TMPDIR}/bin:$PATH" SMS_EXPORT_SHARE_TIMEOUT=1 run bash "$SCRIPT" "$EXPORT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"did not answer within 1 s"* ]]
}

@test "nothing printed or logged carries message text" {
  run sms_inbox_export "$EXPORT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$SENTINEL"* ]]
  # A list jq cannot use: the error path must not quote it either.
  jq --arg s "$SENTINEL" '.attributes.messages = ("text " + $s)' "$STATE_FILE" >"${STATE_FILE}.new"
  mv "${STATE_FILE}.new" "$STATE_FILE"
  run sms_inbox_export "$EXPORT_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" != *"$SENTINEL"* ]]
  ! grep -q "$SENTINEL" "$LOG_FILE"
}

@test "runs end to end as a command" {
  run bash "$SCRIPT" "$EXPORT_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrote 3 messages"* ]]
  jq -e --slurpfile s "$STATE_FILE" '.messages == $s[0].attributes.messages' "$TARGET"
}

@test "refuses an export dir that does not exist" {
  run sms_inbox_export "${BATS_TEST_TMPDIR}/missing"
  [ "$status" -eq 2 ]
  [[ "$output" == *"export dir not found"* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/missing" ]
}

@test "refuses a local export dir unless told it is on purpose" {
  unset SMS_EXPORT_ALLOW_LOCAL
  run sms_inbox_export "$EXPORT_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not on a network share"* ]]
  [ ! -e "$TARGET" ]
}

@test "usage errors and a missing token exit 2" {
  run sms_inbox_export
  [ "$status" -eq 2 ]
  run sms_inbox_export "$EXPORT_DIR" extra
  [ "$status" -eq 2 ]
  unset HA_TOKEN
  run sms_inbox_export "$EXPORT_DIR"
  [ "$status" -eq 2 ]
  [ ! -e "$TARGET" ]
}

@test "the script never deletes a file" {
  # The NAS share's recycle bin keeps every deleted file, so a deleted copy of
  # the texts would outlive the 72-hour retention. Rename and truncate only.
  run bash -c "grep -vE '^[[:space:]]*#' '$SCRIPT' | grep -nE '(^|[^[:alnum:]_.-])(rm|unlink|shred)([[:space:]]|\$)'"
  [ "$status" -eq 1 ]
}

@test "the package passes no template to the shell and stores no traces" {
  line="$(grep -E '^[[:space:]]+sms_inbox_export:' "$PACKAGE")"
  [[ "$line" == *"/config/scripts/sms-inbox-export.sh /share/claude_jobs/sources\""* ]]
  [[ "$line" != *"{{"* && "$line" != *"{%"* ]]
  [[ "$line" != *"/web"* ]]
  grep -qE '^[[:space:]]+stored_traces: 0$' "$PACKAGE"
}

@test "the token goes to curl on stdin, never on its command line" {
  run sms_inbox_export "$EXPORT_DIR"
  [ "$status" -eq 0 ]
  grep -q 'Authorization: Bearer test-token' "$AUTH_LOG"
  ! grep -q 'test-token' "$ARGS_LOG"
}

@test "with no HA_TOKEN it reads ha_token from secrets.yaml and strips Bearer" {
  printf 'wifi_ssid: "x"\nha_token: "Bearer from-secrets"\n' >"${BATS_TEST_TMPDIR}/secrets.yaml"
  unset HA_TOKEN
  run env SMS_SECRETS_YAML="${BATS_TEST_TMPDIR}/secrets.yaml" bash "$SCRIPT" "$EXPORT_DIR"
  [ "$status" -eq 0 ]
  grep -q 'Authorization: Bearer from-secrets' "$AUTH_LOG"
  ! grep -q 'from-secrets' "$ARGS_LOG"
}

@test "the scripts no longer use the Supervisor token or proxy" {
  ! grep -n 'SUPERVISOR' "$SCRIPT" "${BATS_TEST_DIRNAME}/../scripts/sms-flags-sync.sh" | grep -v '^[^:]*:[0-9]*:#'
}
