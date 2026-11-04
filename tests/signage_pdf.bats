#!/usr/bin/env bats
#
# Tests for scripts/render-signage-pdf.sh, which prints each piece of signage
# to PDF in headless Chrome and checks that it is exactly one US Letter page
# (signage/README.md, lentago/epigaea#548). Rendering needs a browser,
# pdfinfo, pdffonts and the pieces' Google Fonts. Where any is missing the
# script exits 3. On a workstation the render tests then skip; in CI (where
# GitHub sets CI=true and the runner has Chrome and poppler-utils) they fail,
# so the one-page rule is never skipped silently where it is meant to be
# enforced.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/render-signage-pdf.sh"
  SIGNAGE="${BATS_TEST_DIRNAME}/../signage"
  OUT="${BATS_TEST_TMPDIR}/pdf"
}

# Skip on "cannot render" locally; let the assertion fail in CI.
skip_unless_rendered() {
  if [ "$status" -eq 3 ] && [ -z "${CI:-}" ]; then
    skip "cannot render signage here: $output"
  fi
}

@test "every piece renders to one Letter page, cards and sheets both" {
  run bash "$SCRIPT" --out "$OUT"
  skip_unless_rendered
  echo "$output"
  [ "$status" -eq 0 ]
  local f type slug
  for f in "$SIGNAGE"/cards/*.html "$SIGNAGE"/sheets/*.html; do
    type="$(basename "$(dirname "$f")")"
    slug="$(basename "$f" .html)"
    [ -s "$OUT/$type/$slug.pdf" ]
    [[ "$output" == *"${type}/${slug}: 1 page, 612x792 pts"* ]]
    # check the file itself, not just the script's report
    pdfinfo "$OUT/$type/$slug.pdf" | grep -Eq '^Pages: +1$'
    pdfinfo "$OUT/$type/$slug.pdf" | grep -Eq '^Page size: +612 x 792 pts'
  done
}

@test "a named piece renders alone, and only that PDF is written" {
  run bash "$SCRIPT" --out "$OUT" sheets/meeting-light
  skip_unless_rendered
  [ "$status" -eq 0 ]
  [ -s "$OUT/sheets/meeting-light.pdf" ]
  [ ! -e "$OUT/cards" ]
}

@test "a browser that produces nothing is reported as cannot render, exit 3" {
  # CHROME=true is an executable that exits 0 and writes no PDF.
  run env CHROME=true bash "$SCRIPT" --out "$OUT" cards/kitchen-speaker-dial
  [ "$status" -eq 3 ]
  [ ! -e "$OUT/cards/kitchen-speaker-dial.pdf" ]
}

@test "no browser on PATH is reported as cannot render, exit 3" {
  run env CHROME=no-such-browser-here bash "$SCRIPT" --out "$OUT" cards/kitchen-speaker-dial
  [ "$status" -eq 3 ]
  [[ "$output" == *"no headless Chrome"* ]]
}

@test "an unknown piece is a usage error" {
  run env CHROME=true bash "$SCRIPT" --out "$OUT" cards/no-such-card
  [ "$status" -eq 2 ]
  [[ "$output" == *"no such piece"* ]]
}

@test "a piece named without its type is a usage error" {
  run env CHROME=true bash "$SCRIPT" --out "$OUT" kitchen-speaker-dial
  [ "$status" -eq 2 ]
  [[ "$output" == *"<type>/<slug>"* ]]
  run env CHROME=true bash "$SCRIPT" --out "$OUT" posters/kitchen-speaker-dial
  [ "$status" -eq 2 ]
}

@test "an unknown option, or --out without a directory, is a usage error" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
  run bash "$SCRIPT" --out
  [ "$status" -eq 2 ]
}
