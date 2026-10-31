#!/usr/bin/env bats
#
# Tests for scripts/publish-card.sh — the helper that copies an instruction
# card from cards/<slug>.html into the pub.lan web drop as
# <web-root>/cards/<slug>/index.html. The copy is a filesystem side effect, so
# the suite points the function at a temp web root and checks the result; the
# refusals (bad slug, missing card, unmounted root, CLI usage) are checked
# end-to-end because they are what protects the live share from a typo.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/publish-card.sh"
  # shellcheck source=../scripts/publish-card.sh
  source "$SCRIPT"
  WEB_ROOT="${BATS_TEST_TMPDIR}/web"
  mkdir -p "$WEB_ROOT"
  export WEB_ROOT
}

@test "publishes the first card under cards/<slug>/index.html and prints its URL" {
  run publish_card kitchen-speaker-dial "$WEB_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "http://pub.lan/cards/kitchen-speaker-dial/" ]
  [ -f "$WEB_ROOT/cards/kitchen-speaker-dial/index.html" ]
  cmp -s "$WEB_ROOT/cards/kitchen-speaker-dial/index.html" "${BATS_TEST_DIRNAME}/../cards/kitchen-speaker-dial.html"
  # no half-copied file left behind
  [ ! -e "$WEB_ROOT/cards/kitchen-speaker-dial/index.html.partial" ]
}

@test "republishing overwrites in place" {
  publish_card kitchen-speaker-dial "$WEB_ROOT"
  echo stale > "$WEB_ROOT/cards/kitchen-speaker-dial/index.html"
  run publish_card kitchen-speaker-dial "$WEB_ROOT"
  [ "$status" -eq 0 ]
  cmp -s "$WEB_ROOT/cards/kitchen-speaker-dial/index.html" "${BATS_TEST_DIRNAME}/../cards/kitchen-speaker-dial.html"
}

@test "refuses a slug that is not lowercase-hyphenated" {
  run publish_card "Kitchen Dial" "$WEB_ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"slug must be lowercase"* ]]
  run publish_card "../etc" "$WEB_ROOT"
  [ "$status" -eq 2 ]
  [ ! -e "$WEB_ROOT/cards" ]
}

@test "refuses a card that does not exist" {
  run publish_card no-such-card "$WEB_ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such card"* ]]
  [ ! -e "$WEB_ROOT/cards" ]
}

@test "refuses a web root that is not a directory (share not mounted)" {
  run publish_card kitchen-speaker-dial "${BATS_TEST_TMPDIR}/not-mounted"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a directory"* ]]
}

@test "CLI usage error without a slug" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "CLI honours CARDS_WEB_ROOT when no web root is given" {
  run env CARDS_WEB_ROOT="$WEB_ROOT" bash "$SCRIPT" kitchen-speaker-dial
  [ "$status" -eq 0 ]
  [ -f "$WEB_ROOT/cards/kitchen-speaker-dial/index.html" ]
}
