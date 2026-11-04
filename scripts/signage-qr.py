#!/usr/bin/env python3
"""Write each piece of signage's QR code: a link to its own live page.

A printed card or sheet goes stale the day its behaviour changes. The QR code
on it opens the piece's current version on pub.lan, so whoever is standing at
the control can check the paper against it. The code is committed in the HTML
as inline SVG, so a piece still needs nothing but a browser to read or print.

Each piece marks where its code goes with a slot:

    <!-- signage-qr -->...<!-- /signage-qr -->

This script fills the slot with a link to the piece's URL,
http://pub.lan/signage/<type>/<slug>/ (the address publish-signage.sh serves
it at), around the QR code for that URL. A label is the exception: its job is
to say where the device's card is, so its code opens that card, named in the
label's <meta name="epigaea-label-card" content="cards/<slug>">. With --check it changes nothing and
exits 1 when a slot is missing or out of date, for CI. See signage/README.md.

Usage: signage-qr.py [--check] [<type>/<slug> ...]
  No pieces names every piece in signage/cards, signage/sheets and signage/labels.
  SIGNAGE_URL_BASE overrides the URL prefix (default http://pub.lan/signage).

Needs segno (pip install segno). Exit: 0 ok; 1 --check found a stale or
missing slot; 2 usage error or unknown piece; 3 segno is not installed.
"""

import argparse
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SIGNAGE_DIR = REPO_ROOT / "signage"
TYPES = ("cards", "sheets", "labels")
URL_BASE = os.environ.get("SIGNAGE_URL_BASE", "http://pub.lan/signage").rstrip("/")
SLOT = re.compile(r"<!-- signage-qr -->.*?<!-- /signage-qr -->", re.DOTALL)
NOUN = {"cards": "card", "sheets": "sheet"}
LABEL_CARD = re.compile(r'<meta name="epigaea-label-card" content="([^"]*)">')


def piece_url(piece_type: str, slug: str) -> str:
    return f"{URL_BASE}/{piece_type}/{slug}/"


def target(piece_type: str, slug: str, html: str) -> tuple[str, str]:
    """The page a piece's code opens, and how to describe it.

    A card or sheet opens its own page. A label opens the card it names.
    Raises ValueError when a label names no card, or one that does not exist.
    """
    if piece_type != "labels":
        return piece_url(piece_type, slug), f"The current version of this {NOUN[piece_type]}"
    found = LABEL_CARD.findall(html)
    if len(found) != 1:
        raise ValueError(f"needs exactly one epigaea-label-card meta tag, found {len(found)}")
    card_type, _, card_slug = found[0].partition("/")
    if card_type != "cards" or not (SIGNAGE_DIR / "cards" / f"{card_slug}.html").is_file():
        raise ValueError(f"epigaea-label-card names no card in signage/cards: '{found[0]}'")
    return piece_url("cards", card_slug), "The card for this device"


def slot_html(segno, url: str, label: str) -> str:
    """The filled slot: the QR code as inline SVG inside a link to the page."""
    # Error correction M survives a scuffed or folded print; border 2 is the
    # quiet zone inside the SVG, and the white paper around it adds the rest.
    svg = segno.make(url, error="m", micro=False).svg_inline(
        scale=1, border=2, svgclass=None, lineclass=None, omitsize=True, dark="#000"
    )
    svg = svg.replace("<svg ", '<svg role="img" aria-hidden="true" shape-rendering="crispEdges" ', 1)
    label = f"{label}: {url}"
    return (
        "<!-- signage-qr -->"
        f'<a class="qr" href="{url}" aria-label="{label}">{svg}</a>'
        "<!-- /signage-qr -->"
    )


def all_pieces() -> list[str]:
    pieces = []
    for piece_type in TYPES:
        for path in sorted((SIGNAGE_DIR / piece_type).glob("*.html")):
            pieces.append(f"{piece_type}/{path.stem}")
    return pieces


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Write or check each piece's QR code.")
    parser.add_argument("--check", action="store_true", help="change nothing; exit 1 if a slot is stale or missing")
    parser.add_argument("pieces", nargs="*", metavar="<type>/<slug>")
    args = parser.parse_args(argv)

    try:
        import segno
    except ImportError:
        print("signage-qr: segno is not installed (pip install segno)", file=sys.stderr)
        return 3

    # Validate every name before writing anything, so a typo in the last
    # argument can't leave the earlier pieces rewritten and the rest not.
    targets = []
    for piece in args.pieces or all_pieces():
        piece_type, _, slug = piece.partition("/")
        if piece_type not in TYPES or not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", slug):
            print(f"signage-qr: name a piece as <type>/<slug> with type {' or '.join(TYPES)}, got '{piece}'", file=sys.stderr)
            return 2
        path = SIGNAGE_DIR / piece_type / f"{slug}.html"
        if not path.is_file():
            print(f"signage-qr: no such piece: {path}", file=sys.stderr)
            return 2
        targets.append((piece, piece_type, slug, path))

    rc = 0
    for piece, piece_type, slug, path in targets:
        html = path.read_text(encoding="utf-8")
        slots = SLOT.findall(html)
        if len(slots) != 1:
            print(f"{piece}: needs exactly one <!-- signage-qr --> slot, found {len(slots)}")
            rc = 1
            continue
        try:
            url, label = target(piece_type, slug, html)
        except ValueError as err:
            print(f"{piece}: {err}")
            rc = 1
            continue
        want = slot_html(segno, url, label)
        if slots[0] == want:
            print(f"{piece}: QR up to date ({url})")
            continue
        if args.check:
            print(f"{piece}: QR out of date; run scripts/signage-qr.py {piece}")
            rc = 1
            continue
        path.write_text(SLOT.sub(lambda _m: want, html, count=1), encoding="utf-8")
        print(f"{piece}: QR written ({url})")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
