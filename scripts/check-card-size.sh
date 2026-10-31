#!/usr/bin/env bash
#
# Check that each instruction card fits the 7 by 5 inch card contract.
#
# Opens cards/<slug>.html in headless Chrome, waits for its web fonts, and
# reads the height of the .card element. The print stylesheet pads a short
# card out to 5 inches with min-height but never shrinks a tall one, and the
# card is 7 inches wide on screen and on paper, so this height is the printed
# height. Prints one line per card and exits 1 if any card is too tall.
# See cards/README.md for the contract (lentago/epigaea#560).
#
# Usage: check-card-size.sh [slug...]
#   No slugs checks every card in cards/.
#   CARD_MAX_IN  height limit in inches (default 5.0)
#   CHROME       browser binary (default: google-chrome, chromium or
#                chromium-browser, whichever is on PATH first)
#
# Exit: 0 every card fits; 1 a card is too tall or has no .card element;
#       2 usage error or unknown card; 3 cannot measure here (no browser, or
#       the web fonts did not load, which would change the line breaks).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly CARDS_DIR="${REPO_ROOT}/cards"
readonly CARD_MAX_IN="${CARD_MAX_IN:-5.0}"

# Appended before </body> of a temporary copy. Writes "<height> <fonts>" in
# inches and loaded-font count onto <html>, which --dump-dom then prints.
readonly MEASURE_JS='<script>document.fonts.ready.then(function () {
  var c = document.querySelector(".card");
  var n = 0; document.fonts.forEach(function (f) { if (f.status === "loaded") n++; });
  document.documentElement.setAttribute("data-card-size",
    c ? (c.getBoundingClientRect().height / 96).toFixed(2) + " " + n : "none");
});</script>'

find_chrome() {
  if [[ -n "${CHROME:-}" ]]; then
    command -v "$CHROME" || return 1
    return 0
  fi
  command -v google-chrome || command -v chromium || command -v chromium-browser
}

# Print "<height-in> <loaded-fonts>" for one card, or "none" without a .card.
# Args: <chrome> <card-file> <work-dir>
measure_card() {
  local chrome="$1" card="$2" work="$3" page
  page="${work}/$(basename "$card")"
  awk -v js="$MEASURE_JS" '{ sub(/<\/body>/, js "</body>") } 1' "$card" > "$page"
  "$chrome" --headless=new --no-sandbox --disable-gpu --hide-scrollbars \
    --user-data-dir="${work}/profile" --window-size=1000,2000 \
    --virtual-time-budget=10000 --dump-dom "file://${page}" 2>/dev/null \
    | grep -o 'data-card-size="[^"]*"' | head -n 1 | cut -d'"' -f2
}

main() {
  local chrome
  if ! chrome="$(find_chrome)"; then
    echo "check-card-size: no headless Chrome or Chromium on PATH (set CHROME)" >&2
    return 3
  fi

  local -a slugs=("$@")
  if [[ ${#slugs[@]} -eq 0 ]]; then
    local f
    for f in "${CARDS_DIR}"/*.html; do slugs+=("$(basename "$f" .html)"); done
  fi

  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: work is local to main
  trap "rm -rf '${work}'" EXIT

  local slug card result height fonts rc=0
  for slug in "${slugs[@]}"; do
    card="${CARDS_DIR}/${slug}.html"
    if [[ ! -f "$card" ]]; then
      echo "check-card-size: no such card: ${card}" >&2
      return 2
    fi
    result="$(measure_card "$chrome" "$card" "$work")"
    if [[ -z "$result" ]]; then
      echo "check-card-size: could not measure ${slug} (browser gave no result)" >&2
      return 3
    fi
    if [[ "$result" == "none" ]]; then
      echo "${slug}: no .card element"
      rc=1
      continue
    fi
    read -r height fonts <<< "$result"
    if [[ "$fonts" -eq 0 ]]; then
      echo "check-card-size: web fonts did not load for ${slug}; the height would be wrong" >&2
      return 3
    fi
    if awk -v h="$height" -v m="$CARD_MAX_IN" 'BEGIN { exit !(h > m) }'; then
      echo "${slug}: ${height}in, too tall (limit ${CARD_MAX_IN}in)"
      rc=1
    else
      echo "${slug}: ${height}in, fits"
    fi
  done
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
