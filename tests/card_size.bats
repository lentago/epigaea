#!/usr/bin/env bats
#
# Tests for scripts/check-card-size.sh, which measures each instruction card
# in headless Chrome and fails when one prints taller than the 7 by 5 inch
# card contract (cards/README.md, lentago/epigaea#560). The measurement needs
# a browser and the cards' Google Fonts. Where either is missing the script
# exits 3. On a workstation the size tests then skip; in CI (where GitHub sets
# CI=true and the runner has Chrome) they fail, so the limit is never skipped
# silently where it is meant to be enforced.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/check-card-size.sh"
}

# Skip on "cannot measure" locally; let the assertion fail in CI.
skip_unless_measured() {
  if [ "$status" -eq 3 ] && [ -z "${CI:-}" ]; then
    skip "cannot measure cards here: $output"
  fi
}

@test "every card fits the 7 by 5 inch card" {
  run bash "$SCRIPT"
  skip_unless_measured
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "a card taller than the limit fails and is named" {
  run env CARD_MAX_IN=1 bash "$SCRIPT" kitchen-speaker-dial
  skip_unless_measured
  [ "$status" -eq 1 ]
  [[ "$output" == "kitchen-speaker-dial: "*"too tall (limit 1in)" ]]
}

@test "a browser that gives no measurement is reported, not read as too tall" {
  run env CHROME=false bash "$SCRIPT" kitchen-speaker-dial
  [ "$status" -eq 3 ]
  [[ "$output" == *"could not measure kitchen-speaker-dial"* ]]
}

@test "an unknown card is a usage error" {
  run env CHROME=true bash "$SCRIPT" no-such-card
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such card"* ]]
}
