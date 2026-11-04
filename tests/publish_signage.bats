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
  # Most tests check the page copy alone; the PDF tests turn this back on.
  export SIGNAGE_PDF=0
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

@test "index mode builds signage/index.html and prints the signage URL" {
  run publish_index "$WEB_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "http://pub.lan/signage/" ]
  [ -f "$WEB_ROOT/signage/index.html" ]
  grep -q 'href="cards/kitchen-speaker-dial/"' "$WEB_ROOT/signage/index.html"
  grep -q 'href="sheets/meeting-light/"' "$WEB_ROOT/signage/index.html"
  [ ! -e "$WEB_ROOT/signage/index.html.partial" ]
}

@test "index mode overwrites a stale page in place" {
  mkdir -p "$WEB_ROOT/signage"
  echo stale > "$WEB_ROOT/signage/index.html"
  run publish_index "$WEB_ROOT"
  [ "$status" -eq 0 ]
  ! grep -q stale "$WEB_ROOT/signage/index.html"
}

@test "index mode refuses a missing web root and a local one without SIGNAGE_ALLOW_LOCAL" {
  run publish_index "${BATS_TEST_TMPDIR}/not-mounted"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a directory"* ]]
  run env -u SIGNAGE_ALLOW_LOCAL bash -c "source '$SCRIPT'; publish_index '$WEB_ROOT'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not on a network share"* ]]
  [ ! -e "$WEB_ROOT/signage" ]
}

@test "CLI index form honours SIGNAGE_WEB_ROOT and takes an optional web root" {
  run env SIGNAGE_WEB_ROOT="$WEB_ROOT" bash "$SCRIPT" index
  [ "$status" -eq 0 ]
  [ -f "$WEB_ROOT/signage/index.html" ]
  rm -rf "$WEB_ROOT/signage"
  run bash "$SCRIPT" index "$WEB_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$WEB_ROOT/signage/index.html" ]
}

@test "CLI index form rejects extra arguments" {
  run bash "$SCRIPT" index "$WEB_ROOT" extra
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "SIGNAGE_PDF=0 publishes the page only, with no PDF and a single URL line" {
  run env SIGNAGE_PDF=0 bash "$SCRIPT" cards kitchen-speaker-dial "$WEB_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "http://pub.lan/signage/cards/kitchen-speaker-dial/" ]
  [ ! -e "$WEB_ROOT/signage/cards/kitchen-speaker-dial/kitchen-speaker-dial.pdf" ]
}

@test "the PDF lands beside the page and its URL is printed on a second line" {
  run env SIGNAGE_PDF=1 bash "$SCRIPT" sheets meeting-light "$WEB_ROOT"
  if [[ "$output" == *"warning: no PDF"* ]] && [ -z "${CI:-}" ]; then
    skip "cannot render signage here: $output"
  fi
  echo "$output"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "http://pub.lan/signage/sheets/meeting-light/" ]
  [ "${lines[1]}" = "http://pub.lan/signage/sheets/meeting-light/meeting-light.pdf" ]
  [ -f "$WEB_ROOT/signage/sheets/meeting-light/index.html" ]
  [ -s "$WEB_ROOT/signage/sheets/meeting-light/meeting-light.pdf" ]
  [ ! -e "$WEB_ROOT/signage/sheets/meeting-light/meeting-light.pdf.partial" ]
  pdfinfo "$WEB_ROOT/signage/sheets/meeting-light/meeting-light.pdf" | grep -Eq '^Pages: +1$'
}

@test "a PDF that cannot be rendered here warns and still publishes the page" {
  # CHROME=true is an executable that exits 0 and writes no PDF: exit 3.
  run env SIGNAGE_PDF=1 CHROME=true bash "$SCRIPT" cards kitchen-speaker-dial "$WEB_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: no PDF for cards/kitchen-speaker-dial"* ]]
  [[ "$output" == *"http://pub.lan/signage/cards/kitchen-speaker-dial/"* ]]
  [ -f "$WEB_ROOT/signage/cards/kitchen-speaker-dial/index.html" ]
  [ ! -e "$WEB_ROOT/signage/cards/kitchen-speaker-dial/kitchen-speaker-dial.pdf" ]
}
