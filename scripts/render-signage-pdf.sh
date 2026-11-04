#!/usr/bin/env bash
#
# Render each piece of signage to a PDF, so a facility with no browser on the
# printer PC gets the same output.
#
# Prints signage/<type>/<slug>.html in headless Chrome (--print-to-pdf, no
# header or footer, with time for the Google Fonts) to <out>/<type>/<slug>.pdf.
# Then checks each PDF with pdfinfo: exactly one page, US Letter (612 by 792
# pts). A piece that spills onto a second page fails. Prints one line per piece.
# See signage/README.md for the contract (lentago/epigaea#548).
#
# Usage: render-signage-pdf.sh [--out <dir>] [<type>/<slug>...]
#   No pieces renders every piece in signage/cards, signage/sheets and
#   signage/labels (when it exists). --out defaults to ./signage-pdf.
#   CHROME  browser binary (default: google-chrome, chromium or
#           chromium-browser, whichever is on PATH first)
#
# Exit: 0 every piece is one Letter page; 1 a piece has the wrong page count
#       or size; 2 usage error or unknown piece; 3 cannot render here (no
#       browser, no pdfinfo or pdffonts, no PDF produced, or the web fonts
#       did not load, which would change the line breaks).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SIGNAGE_DIR="${REPO_ROOT}/signage"
readonly SIGNAGE_TYPES="cards sheets labels"
# The Google fonts every piece loads. pdffonts names embedded fonts without
# spaces, e.g. AtkinsonHyperlegible-Regular. A PDF with neither fell back.
readonly FONT_PATTERN='Atkinson|Bricolage'

find_chrome() {
  if [[ -n "${CHROME:-}" ]]; then
    command -v "$CHROME" || return 1
    return 0
  fi
  command -v google-chrome || command -v chromium || command -v chromium-browser
}

usage() {
  echo "Usage: $(basename "$0") [--out <dir>] [<type>/<slug>...]   (type: ${SIGNAGE_TYPES})" >&2
}

main() {
  local out="signage-pdf"
  local -a pieces=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        if [[ $# -lt 2 ]]; then
          usage
          return 2
        fi
        out="$2"
        shift 2
        ;;
      -h | --help)
        usage
        return 2
        ;;
      -*)
        echo "render-signage-pdf: unknown option '$1'" >&2
        usage
        return 2
        ;;
      *)
        pieces+=("$1")
        shift
        ;;
    esac
  done

  # Check the pieces before looking for tools, so a typo is a usage error
  # even on a machine with no browser.
  if [[ ${#pieces[@]} -eq 0 ]]; then
    local f type
    for type in ${SIGNAGE_TYPES}; do
      for f in "${SIGNAGE_DIR}/${type}"/*.html; do
        [[ -e "$f" ]] && pieces+=("${type}/$(basename "$f" .html)")
      done
    done
  fi
  local piece
  for piece in "${pieces[@]}"; do
    if [[ ! "$piece" =~ ^(cards|sheets|labels)/[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
      echo "render-signage-pdf: name a piece as <type>/<slug> with type cards, sheets or labels, got '${piece}'" >&2
      return 2
    fi
    if [[ ! -f "${SIGNAGE_DIR}/${piece}.html" ]]; then
      echo "render-signage-pdf: no such piece: ${SIGNAGE_DIR}/${piece}.html" >&2
      return 2
    fi
  done

  local chrome
  if ! chrome="$(find_chrome)"; then
    echo "render-signage-pdf: no headless Chrome or Chromium on PATH (set CHROME)" >&2
    return 3
  fi
  local tool
  for tool in pdfinfo pdffonts; do
    if ! command -v "$tool" > /dev/null; then
      echo "render-signage-pdf: ${tool} not found (install poppler-utils)" >&2
      return 3
    fi
  done

  local work
  work="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand now: work is local to main
  trap "rm -rf '${work}'" EXIT

  local pdf tmp info pages size rc=0
  for piece in "${pieces[@]}"; do
    pdf="${out}/${piece}.pdf"
    tmp="${work}/$(basename "$piece").pdf"
    timeout 90 "$chrome" --headless=new --no-sandbox --disable-gpu \
      --user-data-dir="${work}/profile" --no-pdf-header-footer \
      --virtual-time-budget=10000 --print-to-pdf="$tmp" \
      "file://${SIGNAGE_DIR}/${piece}.html" > /dev/null 2>&1 || true
    if [[ ! -s "$tmp" ]] || ! info="$(pdfinfo "$tmp" 2> /dev/null)"; then
      echo "render-signage-pdf: could not render ${piece} (browser gave no PDF)" >&2
      return 3
    fi
    if ! pdffonts "$tmp" 2> /dev/null | grep -Eq "$FONT_PATTERN"; then
      echo "render-signage-pdf: web fonts did not load for ${piece}; the layout would be wrong" >&2
      return 3
    fi
    mkdir -p "$(dirname "$pdf")"
    cp "$tmp" "${pdf}.partial"
    mv -f "${pdf}.partial" "$pdf"

    pages="$(awk '/^Pages:/ { print $2 }' <<< "$info")"
    size="$(awk '/^Page size:/ { print $3 "x" $5 }' <<< "$info")"
    if [[ "$pages" != "1" ]]; then
      echo "${piece}: ${pages} pages, spills past one page"
      rc=1
    elif [[ "$size" != "612x792" ]]; then
      echo "${piece}: page size ${size} pts, not US Letter (612x792)"
      rc=1
    else
      echo "${piece}: 1 page, 612x792 pts, ${pdf}"
    fi
  done
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
