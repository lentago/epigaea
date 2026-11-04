#!/usr/bin/env bats
#
# Tests for the label contract in signage/README.md (#548). A label has two
# forms in one file: a label-maker strip, typed rather than printed, and a
# sheet label that prints with a QR code opening the device's card. The size
# check measures the sheet label; these tests check what a browser cannot:
# the strip's text fits the tape, and the label names a card that exists.

setup() {
  LABELS="${BATS_TEST_DIRNAME}/../signage/labels"
  CARDS="${BATS_TEST_DIRNAME}/../signage/cards"
}

# Print the strip's lines (the <li> items of <ul class="type-this">), one per line.
strip_lines() {
  python3 - "$1" <<'PY'
import re, sys, html
text = open(sys.argv[1], encoding="utf-8").read()
block = re.search(r'<ul class="type-this">(.*?)</ul>', text, re.S)
if block:
    for item in re.findall(r"<li>(.*?)</li>", block.group(1), re.S):
        print(html.unescape(item.strip()))
PY
}

@test "every label's strip is one or two lines of at most 24 characters" {
  for f in "$LABELS"/*.html; do
    run strip_lines "$f"
    [ "$status" -eq 0 ]
    n="${#lines[@]}"
    if [ "$n" -lt 1 ] || [ "$n" -gt 2 ]; then
      echo "$(basename "$f"): $n strip lines, want 1 or 2"; return 1
    fi
    for line in "${lines[@]}"; do
      if [ "${#line}" -gt 24 ]; then
        echo "$(basename "$f"): strip line too long (${#line} > 24): $line"; return 1
      fi
    done
  done
}

@test "the strip preview shows the same lines the reader is told to type" {
  for f in "$LABELS"/*.html; do
    typed="$(strip_lines "$f")"
    preview="$(python3 -c '
import re, sys, html
text = open(sys.argv[1], encoding="utf-8").read()
strip = re.search(r"<div class=\"strip\"[^>]*>(.*?)</div>", text, re.S).group(1)
print("\n".join(html.unescape(s.strip()) for s in re.findall(r"<span>(.*?)</span>", strip, re.S)))
' "$f")"
    [ "$typed" = "$preview" ] || { echo "$(basename "$f"): preview differs from the typed lines"; return 1; }
  done
}

@test "every label names exactly one card that exists" {
  for f in "$LABELS"/*.html; do
    run grep -o '<meta name="epigaea-label-card" content="[^"]*">' "$f"
    [ "${#lines[@]}" -eq 1 ] || { echo "$(basename "$f"): ${#lines[@]} epigaea-label-card tags"; return 1; }
    card="$(sed -E 's/.*content="cards\/([^"]*)".*/\1/' <<< "${lines[0]}")"
    [ -f "$CARDS/$card.html" ] || { echo "$(basename "$f"): no card $card"; return 1; }
  done
}
