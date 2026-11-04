#!/usr/bin/env python3
"""Copy signage/signage.css into every piece of signage, or check the copies.

Every piece is one standalone HTML file, so the shared look can't be a linked
stylesheet: a card opened from disk, printed, or pasted into an artifact
would lose it. Instead each piece carries a verbatim copy of
signage/signage.css in its first style block,

    <style data-signage-css>
    ...signage/signage.css...
    </style>

followed by a second <style> block with the piece's own rules. This script
rewrites the first block from the file. With --check it changes nothing and
exits 1 when a piece's copy differs or the block is missing, for CI. See
signage/README.md.

Usage: sync-signage-css.py [--check] [<type>/<slug> ...]
  No pieces names every piece in signage/cards, signage/sheets and signage/labels.

Exit: 0 every copy current; 1 --check found a stale or missing block;
2 usage error or unknown piece.
"""

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SIGNAGE_DIR = REPO_ROOT / "signage"
SHARED = SIGNAGE_DIR / "signage.css"
TYPES = ("cards", "sheets", "labels")
BLOCK = re.compile(r"<style data-signage-css>\n.*?</style>", re.DOTALL)


def all_pieces() -> list[str]:
    return [
        f"{piece_type}/{path.stem}"
        for piece_type in TYPES
        for path in sorted((SIGNAGE_DIR / piece_type).glob("*.html"))
    ]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Copy or check the shared signage stylesheet.")
    parser.add_argument("--check", action="store_true", help="change nothing; exit 1 if a copy is stale or missing")
    parser.add_argument("pieces", nargs="*", metavar="<type>/<slug>")
    args = parser.parse_args(argv)

    css = SHARED.read_text(encoding="utf-8")
    if not css.endswith("\n"):
        css += "\n"
    want = f"<style data-signage-css>\n{css}</style>"

    rc = 0
    for piece in args.pieces or all_pieces():
        piece_type, _, slug = piece.partition("/")
        if piece_type not in TYPES or not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", slug):
            print(f"sync-signage-css: name a piece as <type>/<slug> with type {', '.join(TYPES)}, got '{piece}'", file=sys.stderr)
            return 2
        path = SIGNAGE_DIR / piece_type / f"{slug}.html"
        if not path.is_file():
            print(f"sync-signage-css: no such piece: {path}", file=sys.stderr)
            return 2

        html = path.read_text(encoding="utf-8")
        blocks = BLOCK.findall(html)
        if len(blocks) != 1:
            print(f"{piece}: needs exactly one <style data-signage-css> block, found {len(blocks)}")
            rc = 1
            continue
        if blocks[0] == want:
            print(f"{piece}: shared stylesheet up to date")
            continue
        if args.check:
            print(f"{piece}: shared stylesheet out of date; run scripts/sync-signage-css.py {piece}")
            rc = 1
            continue
        path.write_text(BLOCK.sub(lambda _m: want, html, count=1), encoding="utf-8")
        print(f"{piece}: shared stylesheet written")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
