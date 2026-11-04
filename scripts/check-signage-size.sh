#!/usr/bin/env bash
#
# Check that each piece of signage fits its type's printed size.
#
# Opens signage/<type>/<slug>.html in headless Chrome, waits for its web
# fonts, and reads the height of the piece's root element: .card for a card
# (limit 5 in, the 7 by 5 inch card), .sheet for a sheet (limit 10 in, one
# Letter page inside half-inch margins), .label for a label's sheet form
# (limit 1.5 in, the 3.5 by 1.5 inch sheet label; the label-maker strip is
# typed, not printed, so it is not measured here). The print stylesheet pads a short
# piece out with min-height but never shrinks a tall one, and a piece is the
# same width on screen and on paper, so this height is the printed height.
# Prints one line per piece and exits 1 if any piece is too tall.
# See signage/README.md for the contract (lentago/epigaea#560, #548).
#
# Usage: check-signage-size.sh [<type>/<slug>...]
#   No arguments checks every piece in signage/cards, signage/sheets and
#   signage/labels.
#   SIGNAGE_MAX_IN  height limit in inches for every piece checked (default:
#                   the type's own limit)
#   CHROME          browser binary (default: google-chrome, chromium or
#                   chromium-browser, whichever is on PATH first)
#
# Exit: 0 every piece fits; 1 a piece is too tall or has no root element;
#       2 usage error or unknown piece; 3 cannot measure here (no browser, or
#       the web fonts did not load, which would change the line breaks).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SIGNAGE_DIR="${REPO_ROOT}/signage"

# The root element and the height limit, in inches, of each signage type.
root_selector() {
  case "$1" in
    cards) echo ".card" ;;
    sheets) echo ".sheet" ;;
    labels) echo ".label" ;;
    *) return 1 ;;
  esac
}
type_limit() {
  case "$1" in
    cards) echo "5.0" ;;
    sheets) echo "10.0" ;;
    labels) echo "1.5" ;;
    *) return 1 ;;
  esac
}

# Appended before </body> of a temporary copy, with ROOT_SELECTOR replaced by
# the type's root element. Writes "<height> <fonts>" in inches and loaded-font
# count onto <html>, which --dump-dom then prints.
readonly MEASURE_JS='<script>document.fonts.ready.then(function () {
  var c = document.querySelector("ROOT_SELECTOR");
  var n = 0; document.fonts.forEach(function (f) { if (f.status === "loaded") n++; });
  document.documentElement.setAttribute("data-signage-size",
    c ? (c.getBoundingClientRect().height / 96).toFixed(2) + " " + n : "none");
});</script>'

find_chrome() {
  if [[ -n "${CHROME:-}" ]]; then
    command -v "$CHROME" || return 1
    return 0
  fi
  command -v google-chrome || command -v chromium || command -v chromium-browser
}

# Print "<height-in> <loaded-fonts>" for one piece, or "none" without its
# root element. Prints nothing, and still returns 0, when the browser crashes,
# times out or gives no measurement, so the caller can report it as "cannot
# measure".
# Args: <chrome> <piece-file> <root-selector> <work-dir>
measure_piece() {
  local chrome="$1" piece="$2" selector="$3" work="$4" page dom js
  page="${work}/$(basename "$piece")"
  js="${MEASURE_JS//ROOT_SELECTOR/$selector}"
  awk -v js="$js" '{ sub(/<\/body>/, js "</body>") } 1' "$piece" > "$page"
  dom="$(timeout 60 "$chrome" --headless=new --no-sandbox --disable-gpu --hide-scrollbars \
    --user-data-dir="${work}/profile" --window-size=1000,2000 \
    --virtual-time-budget=10000 --dump-dom "file://${page}" 2>/dev/null)" || true
  if [[ "$dom" =~ data-signage-size=\"([^\"]*)\" ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
  return 0
}

main() {
  local chrome
  if ! chrome="$(find_chrome)"; then
    echo "check-signage-size: no headless Chrome or Chromium on PATH (set CHROME)" >&2
    return 3
  fi

  local -a pieces=("$@")
  if [[ ${#pieces[@]} -eq 0 ]]; then
    local f type
    for type in cards sheets labels; do
      for f in "${SIGNAGE_DIR}/${type}"/*.html; do
        [[ -e "$f" ]] && pieces+=("${type}/$(basename "$f" .html)")
      done
    done
  fi

  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: work is local to main
  trap "rm -rf '${work}'" EXIT

  local piece type file selector limit result height fonts rc=0
  for piece in "${pieces[@]}"; do
    type="${piece%%/*}"
    if [[ "$piece" != */* ]] || ! selector="$(root_selector "$type")"; then
      echo "check-signage-size: name a piece as <type>/<slug> with type cards, sheets or labels, got '${piece}'" >&2
      return 2
    fi
    limit="${SIGNAGE_MAX_IN:-$(type_limit "$type")}"
    file="${SIGNAGE_DIR}/${piece}.html"
    if [[ ! -f "$file" ]]; then
      echo "check-signage-size: no such piece: ${file}" >&2
      return 2
    fi
    result="$(measure_piece "$chrome" "$file" "$selector" "$work")"
    if [[ -z "$result" ]]; then
      echo "check-signage-size: could not measure ${piece} (browser gave no result)" >&2
      return 3
    fi
    if [[ "$result" == "none" ]]; then
      echo "${piece}: no ${selector} element"
      rc=1
      continue
    fi
    read -r height fonts <<< "$result"
    if [[ "$fonts" -eq 0 ]]; then
      echo "check-signage-size: web fonts did not load for ${piece}; the height would be wrong" >&2
      return 3
    fi
    if awk -v h="$height" -v m="$limit" 'BEGIN { exit !(h > m) }'; then
      echo "${piece}: ${height}in, too tall (limit ${limit}in)"
      rc=1
    else
      echo "${piece}: ${height}in, fits (limit ${limit}in)"
    fi
  done
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
