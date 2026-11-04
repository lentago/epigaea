#!/usr/bin/env bats
#
# Tests for scripts/check-signage-size.sh, which measures each piece of
# signage in headless Chrome and fails when one prints taller than its type
# allows: 5 inches for a card, 10 inches for a sheet, 1.5 inches for a sheet
# label (signage/README.md,
# lentago/epigaea#560, #548). The measurement needs a browser and the pieces'
# Google Fonts. Where either is missing the script exits 3. On a workstation
# the size tests then skip; in CI (where GitHub sets CI=true and the runner has
# Chrome) they fail, so the limit is never skipped silently where it is meant
# to be enforced.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/check-signage-size.sh"
}

# Skip on "cannot measure" locally; let the assertion fail in CI.
skip_unless_measured() {
  if [ "$status" -eq 3 ] && [ -z "${CI:-}" ]; then
    skip "cannot measure signage here: $output"
  fi
}

@test "every piece fits its type's size, cards, sheets and labels all checked" {
  run bash "$SCRIPT"
  skip_unless_measured
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cards/kitchen-speaker-dial: "*"fits (limit 5.0in)"* ]]
  [[ "$output" == *"sheets/meeting-light: "*"fits (limit 10.0in)"* ]]
  [[ "$output" == *"labels/kitchen-speaker-dial: "*"fits (limit 1.5in)"* ]]
}

@test "a piece taller than the limit fails and is named" {
  run env SIGNAGE_MAX_IN=1 bash "$SCRIPT" cards/kitchen-speaker-dial
  skip_unless_measured
  [ "$status" -eq 1 ]
  [[ "$output" == "cards/kitchen-speaker-dial: "*"too tall (limit 1in)" ]]
}

@test "a browser that gives no measurement is reported, not read as too tall" {
  run env CHROME=false bash "$SCRIPT" cards/kitchen-speaker-dial
  [ "$status" -eq 3 ]
  [[ "$output" == *"could not measure cards/kitchen-speaker-dial"* ]]
}

@test "an unknown piece is a usage error" {
  run env CHROME=true bash "$SCRIPT" cards/no-such-card
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such piece"* ]]
}

@test "a piece named without its type is a usage error" {
  run env CHROME=true bash "$SCRIPT" kitchen-speaker-dial
  [ "$status" -eq 2 ]
  [[ "$output" == *"<type>/<slug>"* ]]
  run env CHROME=true bash "$SCRIPT" posters/kitchen-speaker-dial
  [ "$status" -eq 2 ]
}
