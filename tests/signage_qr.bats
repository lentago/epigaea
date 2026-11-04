#!/usr/bin/env bats
#
# Tests for scripts/signage-qr.py, which writes each piece of signage's QR
# code (a link to its own page on pub.lan) into the piece as inline SVG, and
# with --check fails when a code is missing or out of date (#548). It needs
# the segno library. Where segno is missing the script exits 3: the tests then
# skip on a workstation and fail in CI (CI=true, segno installed by the Bats
# job), so a stale code is never waved through where it is meant to be caught.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/signage-qr.py"
}

skip_without_segno() {
  if [ "$status" -eq 3 ] && [ -z "${CI:-}" ]; then
    skip "segno is not installed here: $output"
  fi
}

@test "every piece's QR code is present and points at its own page" {
  run python3 "$SCRIPT" --check
  skip_without_segno
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cards/kitchen-speaker-dial: QR up to date (http://pub.lan/signage/cards/kitchen-speaker-dial/)"* ]]
  [[ "$output" == *"sheets/meeting-light: QR up to date (http://pub.lan/signage/sheets/meeting-light/)"* ]]
}

@test "a code for a different address is reported as out of date, and --check writes nothing" {
  before="$(cksum "${BATS_TEST_DIRNAME}/../signage/cards/meeting-button.html")"
  run env SIGNAGE_URL_BASE=http://example.invalid/signage python3 "$SCRIPT" --check cards/meeting-button
  skip_without_segno
  [ "$status" -eq 1 ]
  [[ "$output" == "cards/meeting-button: QR out of date"* ]]
  [ "$(cksum "${BATS_TEST_DIRNAME}/../signage/cards/meeting-button.html")" = "$before" ]
}

@test "a bad name anywhere in the list stops the run before any piece is written" {
  before="$(cksum "${BATS_TEST_DIRNAME}/../signage/cards/meeting-button.html")"
  run env SIGNAGE_URL_BASE=http://example.invalid/signage python3 "$SCRIPT" cards/meeting-button cards/no-such-card
  skip_without_segno
  [ "$status" -eq 2 ]
  [ "$(cksum "${BATS_TEST_DIRNAME}/../signage/cards/meeting-button.html")" = "$before" ]
}

@test "a piece named without its type, or an unknown piece, is a usage error" {
  run python3 "$SCRIPT" --check kitchen-speaker-dial
  skip_without_segno
  [ "$status" -eq 2 ]
  [[ "$output" == *"<type>/<slug>"* ]]
  run python3 "$SCRIPT" --check cards/no-such-card
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such piece"* ]]
}
