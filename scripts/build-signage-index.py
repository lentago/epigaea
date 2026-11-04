#!/usr/bin/env python3
"""Build the signage index page from the index tables in signage/README.md.

Reads the `### Cards`, `### Sheets` and `### Labels` tables (Piece | Room |
Control or Signal | Files | Posted), looks up each piece's display name in its
file's <title>, and writes one standalone HTML page that lists every piece by
room. Links are relative (cards/<slug>/, sheets/<slug>/) because the page is
served at /signage/index.html and the host name is not fixed.

Usage: build-signage-index.py [--readme FILE] [--out FILE]
  --readme  README to read (default: signage/README.md in this repo)
  --out     write the page here (default: stdout)
Exit 0 on success, 1 on a malformed table or a missing piece file, 2 on usage.
Stdlib only. The page is generated at publish time and is not committed.
"""
import argparse
import datetime
import html
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TYPES = {"cards": "card", "sheets": "sheet", "labels": "label"}
LINK_RE = re.compile(r"\[`?([^\]`]+)`?\]\(([^)]+)\)")
TITLE_RE = re.compile(r"<title>(.*?)</title>", re.S | re.I)


class IndexError_(Exception):
    pass


def split_row(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def parse_readme(text):
    """Return a list of dicts, one per table row."""
    rows = []
    section = None
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"^###\s+(\w+)\s*$", line)
        if m:
            section = m.group(1).lower()
            i += 1
            continue
        if re.match(r"^##\s", line):
            section = None
        if section in TYPES and line.startswith("|"):
            header = split_row(line)
            if len(header) != 5:
                raise IndexError_(f"{section}: table header needs 5 columns, got {len(header)}: {line}")
            i += 1
            if i >= len(lines) or not re.match(r"^\|[\s|:-]+\|?\s*$", lines[i]):
                raise IndexError_(f"{section}: table has no separator row")
            i += 1
            while i < len(lines) and lines[i].startswith("|"):
                cells = split_row(lines[i])
                if len(cells) != 5:
                    raise IndexError_(f"{section}: row needs 5 columns, got {len(cells)}: {lines[i]}")
                link = LINK_RE.match(cells[0])
                if not link:
                    raise IndexError_(f"{section}: first cell is not a link: {cells[0]}")
                if not cells[1]:
                    raise IndexError_(f"{section}: row has no room: {lines[i]}")
                rows.append({
                    "type": TYPES[section],
                    "dir": section,
                    "href": link.group(2),
                    "room": cells[1],
                    "control": cells[2],
                    "posted": cells[4].split(";")[0].strip(),
                })
                i += 1
            continue
        i += 1
    if not rows:
        raise IndexError_("no index tables found (expected ### Cards, ### Sheets or ### Labels)")
    return rows


def resolve(rows, readme_dir):
    for r in rows:
        path = (readme_dir / r["href"]).resolve()
        if not path.is_file():
            raise IndexError_(f"piece file is missing: {r['href']} (from the {r['dir']} table)")
        t = TITLE_RE.search(path.read_text(encoding="utf-8"))
        if not t or not t.group(1).strip():
            raise IndexError_(f"piece has no <title>: {r['href']}")
        r["title"] = " ".join(html.unescape(t.group(1)).split())
        r["url"] = f"{r['dir']}/{path.stem}/"
    return rows


def strip_md(s):
    return LINK_RE.sub(r"\1", s).replace("`", "")


CSS = """
  :root {
    --surround: #e8ecef;
    --surround-fg: #4a5560;
    --paper: #ffffff;
    --ink: #10181f;
    --ink-soft: #4a5560;
    --rule: #c9d1d8;
    --tint: #edf3f4;
    --accent: #0e6b76;
    --display: "Bricolage Grotesque", "Avenir Next", "Helvetica Neue", Arial, sans-serif;
    --body: "Atkinson Hyperlegible", "Segoe UI", Verdana, sans-serif;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) { --surround: #1a1f25; --surround-fg: #a3adb8; color-scheme: dark; }
  }
  :root[data-theme="dark"] { --surround: #1a1f25; --surround-fg: #a3adb8; color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--surround);
    color: var(--ink);
    font-family: var(--body);
    font-size: 16px;
    line-height: 1.35;
    padding: 24px max(16px, env(safe-area-inset-right, 0px)) 24px max(16px, env(safe-area-inset-left, 0px));
  }
  main { max-width: 640px; margin: 0 auto; display: grid; gap: 16px; }
  h1 { font-family: var(--display); font-weight: 800; font-size: 28px; line-height: 1.05; margin: 0; letter-spacing: -0.01em; color: var(--surround-fg); }
  .lede { margin: 0; color: var(--surround-fg); font-size: 14px; }
  .room { background: var(--paper); border-radius: 6px; box-shadow: 0 2px 12px rgba(0, 0, 0, 0.18); padding: 16px; display: grid; gap: 4px; }
  .room h2 { font-family: var(--display); font-weight: 700; font-size: 14px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--accent); margin: 0 0 4px; overflow-wrap: anywhere; }
  .piece { display: block; min-height: 44px; padding: 10px 0; border-top: 1px solid var(--rule); color: var(--ink); text-decoration: none; overflow-wrap: anywhere; }
  .piece:first-of-type { border-top: 1.5px solid var(--ink); }
  .piece:hover .name, .piece:focus-visible .name { text-decoration: underline; }
  .piece:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  .name { font-family: var(--display); font-weight: 800; font-size: 20px; line-height: 1.1; }
  .type { display: inline-block; margin-left: 6px; padding: 1px 7px; border: 1px solid var(--accent); border-radius: 10px; color: var(--accent); font-family: var(--body); font-weight: 700; font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; vertical-align: 3px; }
  .meta { display: block; color: var(--ink-soft); font-size: 14px; margin-top: 3px; }
  .meta b { color: var(--ink); font-weight: 700; }
  footer { color: var(--surround-fg); font-size: 12px; font-variant-numeric: tabular-nums; }
"""


def render(rows, today):
    rooms = {}
    for r in rows:
        rooms.setdefault(r["room"], []).append(r)
    e = html.escape
    out = []
    for room in sorted(rooms, key=str.lower):
        out.append(f'<section class="room"><h2>{e(room)}</h2>')
        for r in sorted(rooms[room], key=lambda x: x["title"].lower()):
            label = "Signal" if r["type"] == "sheet" else "Control"
            out.append(
                f'<a class="piece" href="{e(r["url"], quote=True)}">'
                f'<span class="name">{e(r["title"])}</span>'
                f'<span class="type">{e(r["type"])}</span>'
                f'<span class="meta"><b>{label}:</b> {e(strip_md(r["control"]))}</span>'
                f'<span class="meta"><b>Posted:</b> {e(strip_md(r["posted"]))}</span>'
                f"</a>"
            )
        out.append("</section>")
    body = "\n".join(out)
    n = len(rows)
    plural = "" if n == 1 else "s"
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Signage Index</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:wght@400;700&family=Bricolage+Grotesque:wght@700;800&display=swap">
<style>{CSS}</style>
</head>
<body>
<main>
<h1>Signage</h1>
<p class="lede">{n} piece{plural}, by room. Tap one to open it.</p>
{body}
<footer>Generated from signage/README.md on {today} &middot; epigaea</footer>
</main>
</body>
</html>
"""


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build the signage index page.")
    ap.add_argument("--readme", default=str(REPO_ROOT / "signage" / "README.md"))
    ap.add_argument("--out")
    ap.add_argument("--date", help=argparse.SUPPRESS)
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    readme = Path(args.readme)
    try:
        text = readme.read_text(encoding="utf-8")
    except OSError as e:
        print(f"build-signage-index: cannot read {readme}: {e.strerror}", file=sys.stderr)
        return 2
    try:
        rows = resolve(parse_readme(text), readme.resolve().parent)
    except IndexError_ as e:
        print(f"build-signage-index: {e}", file=sys.stderr)
        return 1
    page = render(rows, args.date or datetime.date.today().isoformat())
    if args.out:
        Path(args.out).write_text(page, encoding="utf-8")
    else:
        sys.stdout.write(page)
    return 0


if __name__ == "__main__":
    sys.exit(main())
