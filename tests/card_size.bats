#!/usr/bin/env bats
#
# Tests for scripts/check-card-size.sh, which measures each instruction card
# in headless Chrome and fails when one prints taller than the 7 by 5 inch
# card contract (cards/README.md, lentago/epigaea#560). The measurement needs
# a browser and the cards' Google Fonts. Where either is missing the script
# exits 3, and these tests skip rather than report a height the fallback fonts
# would get wrong.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/check-card-size.sh"
}

@test "every card fits the 7 by 5 inch card" {
  run bash "$SCRIPT"
  [ "$status" -ne 3 ] || skip "cannot measure cards here: $output"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "a card taller than the limit fails and is named" {
  run env CARD_MAX_IN=1 bash "$SCRIPT" kitchen-speaker-dial
  [ "$status" -ne 3 ] || skip "cannot measure cards here: $output"
  [ "$status" -eq 1 ]
  [[ "$output" == "kitchen-speaker-dial: "*"too tall (limit 1in)" ]]
}

@test "an unknown card is a usage error" {
  run env CHROME=true bash "$SCRIPT" no-such-card
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such card"* ]]
}
