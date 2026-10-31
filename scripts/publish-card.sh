#!/usr/bin/env bash
#
# Publish an instruction card to the LAN web drop folder.
#
# Copies cards/<slug>.html to <web-root>/cards/<slug>/index.html so Caddy on
# pub.lan serves it at http://pub.lan/cards/<slug>/ with no deploy step. The
# web root is the Neptune NAS `lentago` share: /mnt/lentago/web as mounted on
# the workstation, /mnt/neptune-lentago/web on the fleet hosts. See
# cards/README.md for the card contract.
#
# Usage: publish-card.sh <slug> [web-root]
#   web-root defaults to $CARDS_WEB_ROOT, else /mnt/lentago/web.
#   CARDS_URL_BASE overrides the printed URL prefix (default http://pub.lan/cards).
#   CARDS_ALLOW_LOCAL=1 accepts a web root that is not on a network share (tests).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly CARDS_DIR="${REPO_ROOT}/cards"
readonly CARDS_URL_BASE="${CARDS_URL_BASE:-http://pub.lan/cards}"

# Copy one card into the web root and print its URL.
# Args: <slug> <web-root>
publish_card() {
  local slug="$1" web_root="$2"
  local src="${CARDS_DIR}/${slug}.html"
  local dst_dir="${web_root}/cards/${slug}"

  if [[ ! "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "publish-card: slug must be lowercase words joined by hyphens, got '${slug}'" >&2
    return 2
  fi
  if [[ ! -f "$src" ]]; then
    echo "publish-card: no such card: ${src}" >&2
    return 2
  fi
  if [[ ! -d "$web_root" ]]; then
    echo "publish-card: web root is not a directory: ${web_root}" >&2
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
      if [[ "${CARDS_ALLOW_LOCAL:-0}" != "1" ]]; then
        echo "publish-card: web root is not on a network share (filesystem: ${fstype}); is the NAS mounted? Set CARDS_ALLOW_LOCAL=1 to publish to a local directory on purpose: ${web_root}" >&2
        return 2
      fi
      ;;
  esac

  mkdir -p "$dst_dir"
  # Write-then-rename so a reader never sees a half-copied page.
  cp "$src" "${dst_dir}/index.html.partial"
  mv -f "${dst_dir}/index.html.partial" "${dst_dir}/index.html"
  # Modes are advisory on the SMB mount (the server decides); best effort.
  chmod 755 "$dst_dir" 2>/dev/null || true
  chmod 644 "${dst_dir}/index.html" 2>/dev/null || true

  echo "${CARDS_URL_BASE}/${slug}/"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $(basename "$0") <slug> [web-root]" >&2
    exit 2
  fi
  publish_card "$1" "${2:-${CARDS_WEB_ROOT:-/mnt/lentago/web}}"
fi
