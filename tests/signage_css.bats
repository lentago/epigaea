#!/usr/bin/env bats
#
# Tests for scripts/sync-signage-css.py, which copies signage/signage.css (the
# look every piece of signage shares) into each piece's first style block, and
# with --check fails when a copy is missing or differs (#548). A piece is one
# standalone file, so the shared stylesheet travels inside it; this is what
# keeps the copies from drifting apart.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/sync-signage-css.py"
}

@test "every piece carries the current signage/signage.css" {
  run python3 "$SCRIPT" --check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cards/kitchen-speaker-dial: shared stylesheet up to date"* ]]
  [[ "$output" == *"sheets/meeting-light: shared stylesheet up to date"* ]]
}

@test "a piece whose copy differs is reported, and --check writes nothing" {
  work="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$work/scripts" "$work/signage/cards"
  cp "$SCRIPT" "$work/scripts/"
  cp "${BATS_TEST_DIRNAME}/../signage/signage.css" "$work/signage/"
  sed 's/--accent: #0e6b76;/--accent: #ff0000;/' \
    "${BATS_TEST_DIRNAME}/../signage/cards/meeting-button.html" > "$work/signage/cards/meeting-button.html"
  before="$(cksum < "$work/signage/cards/meeting-button.html")"
  run python3 "$work/scripts/sync-signage-css.py" --check
  [ "$status" -eq 1 ]
  [[ "$output" == "cards/meeting-button: shared stylesheet out of date"* ]]
  [ "$(cksum < "$work/signage/cards/meeting-button.html")" = "$before" ]
  # Without --check the copy is rewritten, and then it checks clean.
  run python3 "$work/scripts/sync-signage-css.py"
  [ "$status" -eq 0 ]
  run python3 "$work/scripts/sync-signage-css.py" --check
  [ "$status" -eq 0 ]
}

@test "a piece without the shared block is reported" {
  work="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$work/scripts" "$work/signage/sheets"
  cp "$SCRIPT" "$work/scripts/"
  cp "${BATS_TEST_DIRNAME}/../signage/signage.css" "$work/signage/"
  printf '<!doctype html><style>body{}</style>\n' > "$work/signage/sheets/bare.html"
  run python3 "$work/scripts/sync-signage-css.py" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"sheets/bare: needs exactly one <style data-signage-css> block, found 0"* ]]
}

@test "a piece named without its type, or an unknown piece, is a usage error" {
  run python3 "$SCRIPT" --check meeting-button
  [ "$status" -eq 2 ]
  run python3 "$SCRIPT" --check cards/no-such-card
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such piece"* ]]
}
