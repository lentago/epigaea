#!/usr/bin/env bash
#
# Publish a piece of signage to the LAN web drop folder.
#
# Copies signage/<type>/<slug>.html to <web-root>/signage/<type>/<slug>/index.html
# so Caddy on pub.lan serves it at http://pub.lan/signage/<type>/<slug>/ with
# no deploy step. <type> is the signage directory: cards, sheets or labels. The
# web root is the Neptune NAS `lentago` share: /mnt/lentago/web as mounted on
# the workstation, /mnt/neptune-lentago/web on the fleet hosts. See
# signage/README.md for the signage contract.
#
# Usage: publish-signage.sh <type> <slug> [web-root]
#        publish-signage.sh index [web-root]
#   `index` builds the index page with scripts/build-signage-index.py and writes
#   it to <web-root>/signage/index.html (http://pub.lan/signage/). The page is
#   generated, not committed.
#   web-root defaults to $SIGNAGE_WEB_ROOT, else /mnt/lentago/web.
#   SIGNAGE_URL_BASE overrides the printed URL prefix (default http://pub.lan/signage).
#   SIGNAGE_ALLOW_LOCAL=1 accepts a web root that is not on a network share (tests).
#   SIGNAGE_PDF=0 skips the PDF. Otherwise scripts/render-signage-pdf.sh renders
#   the piece and the PDF is written beside the page as <slug>.pdf, with its URL
#   printed on a second line. If the PDF cannot be rendered here (no browser,
#   no pdfinfo, no fonts) the page is still published and a warning is printed;
#   a PDF that renders but is not one Letter page fails the publish.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SIGNAGE_DIR="${REPO_ROOT}/signage"
readonly SIGNAGE_URL_BASE="${SIGNAGE_URL_BASE:-http://pub.lan/signage}"
readonly SIGNAGE_TYPES="cards sheets labels"

# Validate the web root: it must exist and be on a network share.
# Args: <web-root>
check_web_root() {
  local web_root="$1"
  if [[ ! -d "$web_root" ]]; then
    echo "publish-signage: web root is not a directory: ${web_root}" >&2
    return 2
  fi
  # A plain local folder at the web root path (share not mounted, automount
  # failed) would take the copy silently. Require a network filesystem unless
  # the caller says a local directory is intended.
  local fstype
  fstype="$(stat -f -c '%T' "$web_root" 2>/dev/null || echo unknown)"
  case "$fstype" in
    smb2|cifs|nfs|nfs4) ;;
    *)
      if [[ "${SIGNAGE_ALLOW_LOCAL:-0}" != "1" ]]; then
        echo "publish-signage: web root is not on a network share (filesystem: ${fstype}); is the NAS mounted? Set SIGNAGE_ALLOW_LOCAL=1 to publish to a local directory on purpose: ${web_root}" >&2
        return 2
      fi
      ;;
  esac
}

# Build the index page and write it to <web-root>/signage/index.html.
# Args: <web-root>
publish_index() {
  local web_root="$1" rc=0
  check_web_root "$web_root" || return $?
  local dst_dir="${web_root}/signage"
  mkdir -p "$dst_dir"
  # Build to the .partial file, then rename, so a reader never sees half a page
  # and a failed build leaves the live page alone.
  python3 "${REPO_ROOT}/scripts/build-signage-index.py" --out "${dst_dir}/index.html.partial" || rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f "${dst_dir}/index.html.partial"
    return "$rc"
  fi
  mv -f "${dst_dir}/index.html.partial" "${dst_dir}/index.html"
  chmod 755 "$dst_dir" 2>/dev/null || true
  chmod 644 "${dst_dir}/index.html" 2>/dev/null || true

  echo "${SIGNAGE_URL_BASE}/"
}

# Copy one piece into the web root and print its URL.
# Args: <type> <slug> <web-root>
publish_signage() {
  local type="$1" slug="$2" web_root="$3"

  if [[ " ${SIGNAGE_TYPES} " != *" ${type} "* ]]; then
    echo "publish-signage: type must be one of: ${SIGNAGE_TYPES}; got '${type}'" >&2
    return 2
  fi
  if [[ ! "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "publish-signage: slug must be lowercase words joined by hyphens, got '${slug}'" >&2
    return 2
  fi
  local src="${SIGNAGE_DIR}/${type}/${slug}.html"
  local dst_dir="${web_root}/signage/${type}/${slug}"
  if [[ ! -f "$src" ]]; then
    echo "publish-signage: no such piece: ${src}" >&2
    return 2
  fi
  check_web_root "$web_root" || return $?

  # Render the PDF first, so a piece that spills past a page publishes nothing.
  local pdf_dir="" pdf_rc=0
  if [[ "${SIGNAGE_PDF:-1}" != "0" ]]; then
    pdf_dir="$(mktemp -d)"
    local render_out
    render_out="$("${REPO_ROOT}/scripts/render-signage-pdf.sh" --out "$pdf_dir" "${type}/${slug}")" || pdf_rc=$?
    case "$pdf_rc" in
      0) ;;
      3)
        echo "publish-signage: warning: no PDF for ${type}/${slug}; publishing the page only" >&2
        rm -rf "$pdf_dir"
        pdf_dir=""
        ;;
      *)
        rm -rf "$pdf_dir"
        echo "$render_out" >&2
        echo "publish-signage: PDF render failed for ${type}/${slug}; nothing published" >&2
        return 1
        ;;
    esac
  fi

  mkdir -p "$dst_dir"
  # Stage both files first, then rename them into place: a reader never sees a
  # half-copied file, and a failed copy leaves the published pair as it was.
  cp "$src" "${dst_dir}/index.html.partial"
  if [[ -n "$pdf_dir" ]]; then
    cp "${pdf_dir}/${type}/${slug}.pdf" "${dst_dir}/${slug}.pdf.partial"
    rm -rf "$pdf_dir"
  fi
  mv -f "${dst_dir}/index.html.partial" "${dst_dir}/index.html"
  local wrote_pdf=0
  if [[ -n "$pdf_dir" ]]; then
    mv -f "${dst_dir}/${slug}.pdf.partial" "${dst_dir}/${slug}.pdf"
    wrote_pdf=1
  elif [[ -e "${dst_dir}/${slug}.pdf" ]]; then
    # No new PDF this time. An old one beside the new page would print the
    # old layout from the same URL, so take it down.
    rm -f "${dst_dir}/${slug}.pdf"
    echo "publish-signage: removed the previous ${slug}.pdf, which no longer matches the page" >&2
  fi
  # Modes are advisory on the SMB mount (the server decides); best effort.
  chmod 755 "$dst_dir" 2>/dev/null || true
  chmod 644 "${dst_dir}/index.html" 2>/dev/null || true

  echo "${SIGNAGE_URL_BASE}/${type}/${slug}/"
  if [[ "$wrote_pdf" == 1 ]]; then
    chmod 644 "${dst_dir}/${slug}.pdf" 2>/dev/null || true
    echo "${SIGNAGE_URL_BASE}/${type}/${slug}/${slug}.pdf"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  default_root="${SIGNAGE_WEB_ROOT:-/mnt/lentago/web}"
  if [[ "${1:-}" == "index" ]]; then
    if [[ $# -gt 2 ]]; then
      echo "Usage: $(basename "$0") index [web-root]" >&2
      exit 2
    fi
    publish_index "${2:-$default_root}"
  else
    if [[ $# -lt 2 || $# -gt 3 ]]; then
      echo "Usage: $(basename "$0") <type> <slug> [web-root]   (type: ${SIGNAGE_TYPES})" >&2
      echo "       $(basename "$0") index [web-root]" >&2
      exit 2
    fi
    publish_signage "$1" "$2" "${3:-$default_root}"
  fi
fi
