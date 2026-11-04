#!/usr/bin/env python3
"""Check that signage meta tags and the files they name agree.

Each piece of signage (signage/{cards,sheets,labels}/<slug>.html) declares the
file or files that implement it, one tag per file:

    <meta name="epigaea-card-package" content="packages/<file>.yaml">

Three checks run over every piece:

  1. Exists: every file a meta tag names exists in the repo.
  2. Links back: every named file mentions the piece's repo path
     (signage/<type>/<slug>.html) somewhere in its text.
  3. Changed together (only with --base): every file changed in
     <base>...HEAD that some piece names has at least one of those pieces
     changed in the same diff. A piece that is not touched may be stale.

Prints one line per finding. See signage/README.md for the contract
(lentago/epigaea#548).

Usage: check-signage-packages.py [--root DIR] [--base GIT_REF]
                                 [--skip-changed-together REASON]
  --root DIR    repo root to check (default: the repo this script lives in)
  --base REF    run check 3 against the diff <REF>...HEAD
  --skip-changed-together REASON
                pass check 3: print REASON and do not compare changes. The CI
                workflow passes the `Signage-unaffected: <reason>` line of the
                PR body here.

Exit: 0 clean; 1 findings; 2 usage error.
"""
import argparse
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path

META_NAME = "epigaea-card-package"
SIGNAGE_TYPES = ("cards", "sheets", "labels")


class MetaParser(HTMLParser):
    """Collect the content of every epigaea-card-package meta tag."""

    def __init__(self):
        super().__init__()
        self.packages = []

    def handle_starttag(self, tag, attrs):
        if tag != "meta":
            return
        a = dict(attrs)
        if a.get("name") == META_NAME and a.get("content"):
            self.packages.append(a["content"].strip())

    handle_startendtag = handle_starttag


def find_pieces(root):
    """Return {repo path of piece: [named file, ...]} for every piece."""
    pieces = {}
    for kind in SIGNAGE_TYPES:
        for f in sorted((root / "signage" / kind).glob("*.html")):
            parser = MetaParser()
            parser.feed(f.read_text(encoding="utf-8", errors="replace"))
            pieces[f"signage/{kind}/{f.name}"] = parser.packages
    return pieces


def changed_files(root, base):
    """Files changed in <base>...HEAD, or None if git cannot say."""
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "diff", "--name-only", f"{base}...HEAD"],
            capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        detail = getattr(e, "stderr", "") or str(e)
        print(f"check-signage-packages: git diff {base}...HEAD failed: "
              f"{detail.strip()}", file=sys.stderr)
        return None
    return set(out.split("\n")) - {""}


def main(argv):
    ap = argparse.ArgumentParser(
        description="Check signage meta tags against the files they name.")
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--base")
    ap.add_argument("--skip-changed-together", metavar="REASON")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    if args.skip_changed_together is not None and not args.base:
        print("check-signage-packages: --skip-changed-together needs --base",
              file=sys.stderr)
        return 2
    if args.skip_changed_together is not None and not args.skip_changed_together.strip():
        print("check-signage-packages: --skip-changed-together needs a reason",
              file=sys.stderr)
        return 2

    root = Path(args.root)
    if not (root / "signage").is_dir():
        print(f"check-signage-packages: no signage/ directory in {root}",
              file=sys.stderr)
        return 2

    findings = []
    pieces = find_pieces(root)

    for piece, packages in pieces.items():
        if not packages:
            findings.append(f"{piece}: no {META_NAME} meta tag")
        for pkg in packages:
            target = root / pkg
            if not target.is_file():
                findings.append(f"{piece}: names {pkg}, which does not exist")
            elif piece not in target.read_text(encoding="utf-8", errors="replace"):
                findings.append(f"{piece}: {pkg} does not mention {piece}")

    if args.base:
        if args.skip_changed_together is not None:
            print("changed-together check skipped (Signage-unaffected): "
                  f"{args.skip_changed_together.strip()}")
        else:
            changed = changed_files(root, args.base)
            if changed is None:
                return 2
            named = {}
            for piece, packages in pieces.items():
                for pkg in packages:
                    named.setdefault(pkg, []).append(piece)
            for pkg in sorted(named):
                if pkg in changed and not changed & set(named[pkg]):
                    findings.append(
                        f"{pkg}: changed, but no piece that names it changed; "
                        f"review {', '.join(sorted(named[pkg]))}")

    for line in findings:
        print(line)
    if not findings:
        print(f"signage packages ok: {len(pieces)} pieces")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
