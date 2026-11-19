#!/usr/bin/env bats
#
# Tests for scripts/sms-flags-sync.sh, which keeps todo.texts_to_answer in step
# with the Claude pass's flags file, the answered ledger and the inbox. The
# suite sources the script, stubs `curl` with canned entity states and a canned
# to-do response, records every write the script makes, and points it at a
# temp sources dir (SMS_EXPORT_ALLOW_LOCAL=1).
#
# What it guards: a flag is added only if it names a real inbox entry, is not
# the text, is under 72 h old, has no stub and was not answered; a ledger entry
# completes a matching stub (by name or by phone number) but never one that
# arrived after the reply; completed stubs are removed at 96 h; a failed read
# changes nothing; message text reaches no log line, no write and no file.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/sms-flags-sync.sh"
  PACKAGE="${BATS_TEST_DIRNAME}/../packages/sms_flags.yaml"
  # shellcheck source=../scripts/sms-flags-sync.sh
  source "$SCRIPT"

  DIR="${BATS_TEST_TMPDIR}/sources"
  mkdir -p "$DIR"
  export SMS_FLAGS_LOG="${BATS_TEST_TMPDIR}/sync.log"
  LOG_FILE="$SMS_FLAGS_LOG"
  export SMS_EXPORT_ALLOW_LOCAL=1 HA_TOKEN=test-token
  WRITES="${BATS_TEST_TMPDIR}/writes.jsonl"
  : >"$WRITES"
  export WRITES

  SENTINEL="SENTINEL-4c1e8b"
  export SENTINEL
  NOW="$(date -u +%s)"
  iso() { date -u -d "@$((NOW - $1 * 3600))" +%Y-%m-%dT%H:%M:%S.123456+00:00; }
  # The same instants as local time at -05:00, to test the offset arithmetic.
  iso_est() { date -u -d "@$((NOW - $1 * 3600 - 18000))" +%Y-%m-%dT%H:%M:%S.123456-05:00; }
  R_AL="$(iso 5)"; R_BOB="$(iso 4)"; R_CAL="$(iso 3)"; R_OLD="$(iso 80)"
  export R_AL R_BOB R_CAL R_OLD

  INBOX="${BATS_TEST_TMPDIR}/inbox.json"
  jq -n --arg al "$R_AL" --arg bob "$R_BOB" --arg cal "$R_CAL" --arg s "$SENTINEL" '{
    attributes: {messages: [
      {received: $al,  sender: "Al",          text: ("Can you send the form tonight? " + $s)},
      {received: $bob, sender: "+1 (555) 010-2000", text: "ok"},
      {received: $cal, sender: "Cal",         text: "Sensitive notification content hidden", hidden: true}
    ]}}' >"$INBOX"

  ANSWERS="${BATS_TEST_TMPDIR}/answers.json"
  echo '{"attributes":{"answers":[]}}' >"$ANSWERS"
  TODO="${BATS_TEST_TMPDIR}/todo.json"
  echo '{"service_response":{"todo.texts_to_answer":{"items":[]}}}' >"$TODO"
  FLAGS="${DIR}/sms_flags.json"
  jq -n --arg al "$R_AL" --arg bob "$R_BOB" --arg cal "$R_CAL" '{flags: [
    {sender: "Al",  received: $al,  gist: "needs the form sent tonight"},
    {sender: "+1 (555) 010-2000", received: $bob, gist: "asks if Tuesday works"},
    {sender: "Cal", received: $cal, gist: "something Android hid"}]}' >"$FLAGS"
  export INBOX ANSWERS TODO

  curl() {
    local url="${*: -1}" body="" a prev=""
    for a in "$@"; do [[ "$prev" == "--data" ]] && body="$a"; prev="$a"; done
    if [[ "${CURL_FAIL:-}" == "1" ]]; then return 22; fi
    case "$url" in
      */services/todo/get_items*) cat "$TODO" ;;
      */states/sensor.sms_answered) [[ "${ANSWERS_FAIL:-}" == "1" ]] && return 22; cat "$ANSWERS" ;;
      */states/sensor.sms_inbox) [[ "${INBOX_FAIL:-}" == "1" ]] && return 22; cat "$INBOX" ;;
      */services/todo/*) jq -c --arg u "${url##*/}" '. + {svc: $u}' <<<"$body" >>"$WRITES"; echo '[]' ;;
      *) return 22 ;;
    esac
  }
  export -f curl
}

stub() { # status uid sender received  -> one todo item
  jq -n --arg st "$1" --arg uid "$2" --arg s "$3" --arg r "$4" \
    '{uid: $uid, summary: "x", status: $st, description: ({s: $s, r: $r} | tojson)}'
}
set_todo() { jq -s '{service_response: {"todo.texts_to_answer": {items: .}}}' >"$TODO"; }
writes() { jq -r --arg k "$1" 'select(.svc == $k)' "$WRITES"; }

@test "adds a stub for each valid flag, with sender and gist but no text" {
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -s 'map(select(.svc == "add_item")) | length' "$WRITES")" -eq 3 ]
  jq -e -s 'map(select(.svc == "add_item" and .entity_id == "todo.texts_to_answer"
      and .item == "Al: needs the form sent tonight")) | length == 1' "$WRITES"
  jq -e -s 'map(select(.item == "Al: needs the form sent tonight"))[0].description | fromjson | .s == "Al"' "$WRITES"
  ! grep -q "$SENTINEL" "$WRITES"
  [[ "$output" == *"added 3"* ]]
}

@test "does not re-add a flag that has an open or a completed stub" {
  { stub needs_action u1 Al "$R_AL"; stub completed u2 "+1 (555) 010-2000" "$R_BOB"; } | set_todo
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -s 'map(select(.svc == "add_item")) | length' "$WRITES")" -eq 1 ]
  jq -e -s '.[0].item | startswith("Cal:")' "$WRITES"
}

@test "drops a flag that names no inbox entry, or whose gist is the text" {
  jq --arg al "$R_AL" --arg s "$SENTINEL" '.flags = [
    {sender: "Al", received: "2020-01-01T00:00:00+00:00", gist: "no such text"},
    {sender: "Al", received: $al, gist: ("Can you send the form tonight? " + $s)},
    {sender: "Zed", received: $al, gist: "wrong sender"}]' "$FLAGS" >"${FLAGS}.n" && mv "${FLAGS}.n" "$FLAGS"
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  [ ! -s "$WRITES" ]
}

@test "drops a flag whose text is older than 72 hours" {
  jq --arg r "$R_OLD" '.messages = null' "$INBOX" >/dev/null
  jq --arg r "$R_OLD" '.attributes.messages += [{received: $r, sender: "Dee", text: "old"}]' "$INBOX" >"${INBOX}.n" && mv "${INBOX}.n" "$INBOX"
  jq --arg r "$R_OLD" '.flags = [{sender: "Dee", received: $r, gist: "too old"}]' "$FLAGS" >"${FLAGS}.n" && mv "${FLAGS}.n" "$FLAGS"
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  [ ! -s "$WRITES" ]
}

@test "a reply after the text completes its stub; one before it does not" {
  { stub needs_action u1 Al "$R_AL"; stub needs_action u2 Cal "$R_CAL"; } | set_todo
  jq -n --arg a "$(iso 1)" --arg b "$(iso 4)" \
    '{attributes: {answers: [{peer: "Al", at: $a, via: "reply"}, {peer: "Cal", at: $b, via: "reply"}]}}' >"$ANSWERS"
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -s 'map(select(.svc == "update_item")) | length' "$WRITES")" -eq 1 ]
  jq -e -s 'map(select(.svc == "update_item"))[0] | .item == "u1" and .status == "completed"' "$WRITES"
}

@test "a reply is matched by phone number whatever its formatting, or by name" {
  { stub needs_action u1 "+1 (555) 010-2000" "$R_BOB"; stub needs_action u2 Al "$R_AL"; } | set_todo
  jq -n --arg a "$(iso 1)" \
    '{attributes: {answers: [{peer: "5550102000", at: $a, via: "reply"}, {peer: "+15550001111", name: "al", at: $a, via: "reply"}]}}' >"$ANSWERS"
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -s 'map(select(.svc == "update_item")) | length' "$WRITES")" -eq 2 ]
}

@test "a flag already answered is not added" {
  jq -n --arg a "$(iso 1)" '{attributes: {answers: [{peer: "Al", at: $a, via: "reply"}]}}' >"$ANSWERS"
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  [ "$(jq -s 'map(select(.svc == "add_item")) | length' "$WRITES")" -eq 2 ]
  ! jq -e -s 'any(.[]; (.item // "") | startswith("Al:"))' "$WRITES"
}

@test "stamps with an offset compare as instants" {
  { stub needs_action u1 Al "$(iso_est 5)"; } | set_todo
  jq -n --arg a "$(iso_est 1)" '{attributes: {answers: [{peer: "Al", at: $a, via: "reply"}]}}' >"$ANSWERS"
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  jq -e -s 'map(select(.svc == "update_item")) | length == 1' "$WRITES"
}

@test "removes a completed stub 96 hours after its text, keeps a younger one" {
  { stub completed u1 Al "$(iso 97)"; stub completed u2 Al "$(iso 90)"; } | set_todo
  echo '{"flags":[]}' >"$FLAGS"
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  jq -e -s 'map(select(.svc == "remove_item")) | length == 1 and .[0].item == ["u1"]' "$WRITES"
}

@test "an open stub outlives the 72-hour window" {
  { stub needs_action u1 Al "$(iso 100)"; } | set_todo
  echo '{"flags":[]}' >"$FLAGS"
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  [ ! -s "$WRITES" ]
}

@test "no flags file means no flags, but answered stubs still complete" {
  rm "$FLAGS"
  { stub needs_action u1 Al "$R_AL"; } | set_todo
  jq -n --arg a "$(iso 1)" '{attributes: {answers: [{peer: "Al", at: $a, via: "reply"}]}}' >"$ANSWERS"
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  jq -e -s 'length == 1 and .[0].svc == "update_item"' "$WRITES"
}

@test "a failed read changes nothing" {
  { stub needs_action u1 Al "$R_AL"; } | set_todo
  for v in CURL_FAIL ANSWERS_FAIL INBOX_FAIL; do
    env "$v=1" bash -c 'source "$0"; LOG_FILE=/dev/null; sms_flags_sync "$1"' "$SCRIPT" "$DIR" || true
  done
  [ ! -s "$WRITES" ]
  ANSWERS_FAIL=1 run sms_flags_sync "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed nothing"* ]]
}

@test "nothing printed or logged carries message text" {
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$SENTINEL"* ]]
  ! grep -q "$SENTINEL" "$LOG_FILE"
  # A malformed inbox must not be quoted back either.
  jq --arg s "$SENTINEL" '.attributes.messages = ("text " + $s)' "$INBOX" >"${INBOX}.n" && mv "${INBOX}.n" "$INBOX"
  run sms_flags_sync "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" != *"$SENTINEL"* ]]
  ! grep -q "$SENTINEL" "$LOG_FILE"
}

@test "usage errors, a missing token and a missing dir exit 2" {
  run sms_flags_sync
  [ "$status" -eq 2 ]
  run sms_flags_sync "${BATS_TEST_TMPDIR}/missing"
  [ "$status" -eq 2 ]
  unset HA_TOKEN
  run sms_flags_sync "$DIR"
  [ "$status" -eq 2 ]
}

@test "the script never deletes a file" {
  run bash -c "grep -vE '^[[:space:]]*#' '$SCRIPT' | grep -nE '(^|[^[:alnum:]_.-])(rm|unlink|shred)([[:space:]]|\$)'"
  [ "$status" -eq 1 ]
}

@test "the package passes no template to the shell, stores no traces, and keeps the stated times" {
  line="$(grep -E '^[[:space:]]+sms_flags_sync:' "$PACKAGE")"
  [[ "$line" == *"/config/scripts/sms-flags-sync.sh /share/claude_jobs/sources\""* ]]
  [[ "$line" != *"{{"* && "$line" != *"{%"* ]]
  grep -qE '^[[:space:]]+stored_traces: 0$' "$PACKAGE"
  [ "$(grep -cE '^[[:space:]]+- trigger: time$' "$PACKAGE")" -ge 1 ]
  [ "$(grep -cE '^[[:space:]]+at: "[0-9]{2}:[0-9]{2}:00"$' "$PACKAGE")" -ge 3 ]
}

# HAOS's BusyBox flock is `flock [-sxun] FD | { FILE [-c] PROG ARGS }`, with no
# -w. GNU flock, which this runner has, hid that once, so these tests put a
# BusyBox-shaped flock first on PATH.
busybox_flock() {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/flock" <<'STUB'
#!/bin/bash
# Accepts only -s -x -u -n and a numeric FD, like BusyBox.
for a in "$@"; do
  case "$a" in
    -[sxun]) ;;
    -*) echo "flock: unrecognized option: ${a#-}" >&2
        echo "BusyBox v1.37.0 multi-call binary." >&2
        echo "Usage: flock [-sxun] FD | { FILE [-c] PROG ARGS }" >&2
        exit 1 ;;
  esac
done
[[ "${FLOCK_HELD:-0}" == "1" ]] && exit 1
exit 0
STUB
  chmod +x "${BATS_TEST_TMPDIR}/bin/flock"
}

@test "the run lock works with BusyBox flock, which has no -w" {
  busybox_flock
  PATH="${BATS_TEST_TMPDIR}/bin:$PATH" run bash "$SCRIPT" "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"synced:"* ]]
  [[ "$output" != *"flock"* ]]
}

@test "a lock held past the wait is reported as held, not as a flock failure" {
  busybox_flock
  FLOCK_HELD=1 SMS_FLAGS_LOCK_WAIT=2 PATH="${BATS_TEST_TMPDIR}/bin:$PATH" run bash "$SCRIPT" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"another sync held the lock for 2 s"* ]]
}

@test "a flock that cannot run is its own error" {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/bin/sh\necho "flock: unrecognized option: n" >&2\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/flock"
  chmod +x "${BATS_TEST_TMPDIR}/bin/flock"
  PATH="${BATS_TEST_TMPDIR}/bin:$PATH" run bash "$SCRIPT" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"flock could not run"* ]]
  [[ "$output" != *"held the lock"* ]]
}

@test "a real held lock makes a second run wait, then give up as held" {
  exec 8>"${LOG_FILE}.lock"
  flock -n -x 8
  SMS_FLAGS_LOCK_WAIT=1 run bash "$SCRIPT" "$DIR"
  exec 8>&-
  [ "$status" -eq 1 ]
  [[ "$output" == *"held the lock for 1 s"* ]]
}

@test "with no flags file the sync is a quiet success" {
  rm -f "$FLAGS"
  run bash "$SCRIPT" "$DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"added 0, completed 0, removed 0"* ]]
}

@test "any message from flock, whatever its wording, is a flock failure" {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/bin/sh\necho "flock: Bad file descriptor" >&2\nexit 1\n' >"${BATS_TEST_TMPDIR}/bin/flock"
  chmod +x "${BATS_TEST_TMPDIR}/bin/flock"
  SMS_FLAGS_LOCK_WAIT=30 PATH="${BATS_TEST_TMPDIR}/bin:$PATH" run bash "$SCRIPT" "$DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"flock could not run (flock: Bad file descriptor)"* ]]
}

@test "an emoji-only name never matches: not another emoji-only sender, not itself" {
  { stub needs_action u1 "❤️" "$R_AL"; stub needs_action u2 "🏠" "$R_BOB"; } | set_todo
  jq -n --arg a "$(iso 1)" \
    '{attributes: {answers: [{peer: "🏠", at: $a, via: "reply"}, {peer: "", name: "!!!", at: $a, via: "reply"}]}}' >"$ANSWERS"
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  ! jq -e -s 'any(.[]; .svc == "update_item")' "$WRITES"
}

@test "a flag from an emoji-only sender is not suppressed by an unrelated emoji-only reply" {
  jq --arg al "$R_AL" '.attributes.messages[0].sender = "❤️"' "$INBOX" >"${INBOX}.n" && mv "${INBOX}.n" "$INBOX"
  jq --arg al "$R_AL" '.flags = [{sender: "❤️", received: $al, gist: "wants a call"}]' "$FLAGS" >"${FLAGS}.n" && mv "${FLAGS}.n" "$FLAGS"
  jq -n --arg a "$(iso 1)" '{attributes: {answers: [{peer: "🏠", at: $a, via: "reply"}]}}' >"$ANSWERS"
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  jq -e -s 'any(.[]; .svc == "add_item" and (.item | startswith("❤️:")))' "$WRITES"
}

@test "names that differ only in non-ASCII letters stay distinct, in any script" {
  { stub needs_action u1 "Zoé" "$R_AL"; stub needs_action u2 "Иван" "$R_BOB"; stub needs_action u3 "Zoë" "$R_CAL"; } | set_todo
  jq -n --arg a "$(iso 1)" \
    '{attributes: {answers: [{peer: "Zoë", at: $a, via: "reply"}, {peer: "Иван", at: $a, via: "reply"}]}}' >"$ANSWERS"
  echo '{"flags":[]}' >"$FLAGS"
  run sms_flags_sync "$DIR"
  [ "$status" -eq 0 ]
  jq -e -s 'map(select(.svc == "update_item") | .item) | sort == ["u2", "u3"]' "$WRITES"
}
