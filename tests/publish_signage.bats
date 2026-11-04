#!/usr/bin/env bats
#
# Tests for scripts/publish-signage.sh — the helper that copies a piece of
# signage from signage/<type>/<slug>.html into the pub.lan web drop as
# <web-root>/signage/<type>/<slug>/index.html. The copy is a filesystem side
# effect, so the suite points the function at a temp web root and checks the
# result; the refusals (bad type, bad slug, missing piece, unmounted root, CLI
# usage) are checked end-to-end because they are what protects the live share
# from a typo.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/publish-signage.sh"
  SIGNAGE="${BATS_TEST_DIRNAME}/../signage"
  # shellcheck source=../scripts/publish-signage.sh
  source "$SCRIPT"
  WEB_ROOT="${BATS_TEST_TMPDIR}/web"
  mkdir -p "$WEB_ROOT"
  export WEB_ROOT
  # The temp web root is local disk, not the NAS share; say so on purpose.
  export SIGNAGE_ALLOW_LOCAL=1
}

@test "publishes a card under signage/cards/<slug>/index.html and prints its URL" {
  run publish_signage cards kitchen-speaker-dial "$WEB_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "http://pub.lan/signage/cards/kitchen-speaker-dial/" ]
  [ -f "$WEB_ROOT/signage/cards/kitchen-speaker-dial/index.html" ]
  cmp -s "$WEB_ROOT/signage/cards/kitchen-speaker-dial/index.html" "$SIGNAGE/cards/kitchen-speaker-dial.html"
  # no half-copied file left behind
  [ ! -e "$WEB_ROOT/signage/cards/kitchen-speaker-dial/index.html.partial" ]
}

@test "publishes a sheet under signage/sheets/<slug>/index.html" {
  run publish_signage sheets meeting-light "$WEB_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "http://pub.lan/signage/sheets/meeting-light/" ]
  cmp -s "$WEB_ROOT/signage/sheets/meeting-light/index.html" "$SIGNAGE/sheets/meeting-light.html"
}

@test "republishing overwrites in place" {
  publish_signage cards kitchen-speaker-dial "$WEB_ROOT"
  echo stale > "$WEB_ROOT/signage/cards/kitchen-speaker-dial/index.html"
  run publish_signage cards kitchen-speaker-dial "$WEB_ROOT"
  [ "$status" -eq 0 ]
  cmp -s "$WEB_ROOT/signage/cards/kitchen-speaker-dial/index.html" "$SIGNAGE/cards/kitchen-speaker-dial.html"
}

@test "refuses a type that is not a signage directory" {
  run publish_signage posters kitchen-speaker-dial "$WEB_ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"type must be one of"* ]]
  run publish_signage ../cards kitchen-speaker-dial "$WEB_ROOT"
  [ "$status" -eq 2 ]
  [ ! -e "$WEB_ROOT/signage" ]
}

@test "refuses a slug that is not lowercase-hyphenated" {
  run publish_signage cards "Kitchen Dial" "$WEB_ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"slug must be lowercase"* ]]
  run publish_signage cards "../etc" "$WEB_ROOT"
  [ "$status" -eq 2 ]
  [ ! -e "$WEB_ROOT/signage" ]
}

@test "refuses a piece that does not exist, including one filed under the wrong type" {
  run publish_signage cards no-such-card "$WEB_ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such piece"* ]]
  run publish_signage sheets kitchen-speaker-dial "$WEB_ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such piece"* ]]
  [ ! -e "$WEB_ROOT/signage" ]
}

@test "refuses a web root that does not exist" {
  run publish_signage cards kitchen-speaker-dial "${BATS_TEST_TMPDIR}/not-mounted"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a directory"* ]]
}

@test "refuses a local directory as web root unless SIGNAGE_ALLOW_LOCAL=1 (share not mounted)" {
  run env -u SIGNAGE_ALLOW_LOCAL bash -c "source '$SCRIPT'; publish_signage cards kitchen-speaker-dial '$WEB_ROOT'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not on a network share"* ]]
  [ ! -e "$WEB_ROOT/signage" ]
}

@test "CLI usage error without a type and slug" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
  run bash "$SCRIPT" kitchen-speaker-dial
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "CLI honours SIGNAGE_WEB_ROOT when no web root is given" {
  run env SIGNAGE_WEB_ROOT="$WEB_ROOT" bash "$SCRIPT" cards kitchen-speaker-dial
  [ "$status" -eq 0 ]
  [ -f "$WEB_ROOT/signage/cards/kitchen-speaker-dial/index.html" ]
}
