#!/usr/bin/env bats
#
# Tests for scripts/build-signage-index.py: the generator that turns the index
# tables in signage/README.md into one standalone page listing every piece by
# room. Most cases run against a fixture README and fixture pieces in a temp
# directory; the last checks the real README so a new row that points at a
# missing file fails here.

setup() {
  BUILD="${BATS_TEST_DIRNAME}/../scripts/build-signage-index.py"
  FIX="${BATS_TEST_TMPDIR}/signage"
  mkdir -p "$FIX/cards" "$FIX/sheets"
  printf '<!doctype html><title>Pantry Dial</title>\n' > "$FIX/cards/pantry-dial.html"
  printf '<!doctype html><title>Front Door Light</title>\n' > "$FIX/sheets/front-door-light.html"
  printf '<!doctype html><title>Pantry Switch</title>\n' > "$FIX/cards/pantry-switch.html"
  cat > "$FIX/README.md" <<'MD'
# fixture

## Index

### Cards

| Card | Room | Control | Files | Posted |
|---|---|---|---|---|
| [`pantry-dial.html`](cards/pantry-dial.html) | Pantry | Dial | [`packages/a.yaml`](../packages/a.yaml) | On the shelf; publishes to `http://pub.lan/signage/cards/pantry-dial/` |
| [`pantry-switch.html`](cards/pantry-switch.html) | Pantry | Wall switch | [`packages/b.yaml`](../packages/b.yaml) | By the door; publishes to `http://pub.lan/signage/cards/pantry-switch/` |

### Sheets

| Sheet | Room | Signal | Files | Posted |
|---|---|---|---|---|
| [`front-door-light.html`](sheets/front-door-light.html) | Porch | Blue light | [`packages/c.yaml`](../packages/c.yaml) | Beside the door; publishes to `http://pub.lan/signage/sheets/front-door-light/` |

## Not yet

| Not | An index | Table | At | All |
|---|---|---|---|---|
| [`x.html`](cards/x.html) | Nowhere | x | x | x |
MD
}

@test "lists every row of the README tables with its title" {
  run python3 "$BUILD" --readme "$FIX/README.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pantry Dial"* ]]
  [[ "$output" == *"Pantry Switch"* ]]
  [[ "$output" == *"Front Door Light"* ]]
  [ "$(grep -c 'class="piece"' <<<"$output")" -eq 3 ]
  # a table outside the Cards/Sheets/Labels sections is not an index
  [[ "$output" != *"Nowhere"* ]]
}

@test "links are relative and no host is hard-coded" {
  run python3 "$BUILD" --readme "$FIX/README.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'href="cards/pantry-dial/"'* ]]
  [[ "$output" == *'href="sheets/front-door-light/"'* ]]
  [[ "$output" != *"pub.lan"* ]]
  ! grep -E '<a [^>]*href="(/|https?:)' <<<"$output"
}

@test "groups pieces under their room, shows type, control and posting" {
  run python3 "$BUILD" --readme "$FIX/README.md"
  [ "$status" -eq 0 ]
  [ "$(grep -c '<section class="room">' <<<"$output")" -eq 2 ]
  # both pantry pieces sit between the Pantry heading and the Porch heading
  pantry="$(sed -n '/<h2>Pantry<\/h2>/,/<h2>Porch<\/h2>/p' <<<"$output")"
  [[ "$pantry" == *"Pantry Dial"* && "$pantry" == *"Pantry Switch"* ]]
  [[ "$pantry" != *"Front Door Light"* ]]
  [[ "$output" == *"<b>Posted:</b> On the shelf</span>"* ]]
  [[ "$output" == *">sheet</span>"* && "$output" == *">card</span>"* ]]
  [[ "$output" == *"<b>Signal:</b> Blue light"* ]]
  [[ "$output" == *"<b>Control:</b> Dial"* ]]
}

@test "carries the provenance footer and no script" {
  run python3 "$BUILD" --readme "$FIX/README.md" --date 2026-01-02
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated from signage/README.md on 2026-01-02"* ]]
  [[ "$output" != *"<script"* ]]
}

@test "--out writes the page to a file and prints nothing" {
  run python3 "$BUILD" --readme "$FIX/README.md" --out "$BATS_TEST_TMPDIR/out.html"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q "Pantry Dial" "$BATS_TEST_TMPDIR/out.html"
}

@test "fails with exit 1 when a piece file is missing" {
  rm "$FIX/cards/pantry-dial.html"
  run python3 "$BUILD" --readme "$FIX/README.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"piece file is missing: cards/pantry-dial.html"* ]]
}

@test "fails with exit 1 when a piece file name is not a valid slug" {
  mv "$FIX/cards/pantry-dial.html" "$FIX/cards/Pantry_Dial.html"
  sed -i 's/cards\/pantry-dial.html/cards\/Pantry_Dial.html/' "$FIX/README.md"
  run python3 "$BUILD" --readme "$FIX/README.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a valid slug"* ]]
}

@test "fails with exit 1 on a row with the wrong number of columns" {
  sed -i 's/| Dial | \[/| [/' "$FIX/README.md"
  run python3 "$BUILD" --readme "$FIX/README.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"5 columns"* ]]
}

@test "fails with exit 1 when a row's first cell is not a link" {
  sed -i 's/| \[`pantry-dial.html`\](cards\/pantry-dial.html) |/| pantry-dial |/' "$FIX/README.md"
  run python3 "$BUILD" --readme "$FIX/README.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a link"* ]]
}

@test "fails with exit 1 when the README has no index tables" {
  printf '# nothing here\n' > "$FIX/empty.md"
  run python3 "$BUILD" --readme "$FIX/empty.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no index tables"* ]]
}

@test "usage errors exit 2" {
  run python3 "$BUILD" --bogus
  [ "$status" -eq 2 ]
  run python3 "$BUILD" --readme "$BATS_TEST_TMPDIR/nope.md"
  [ "$status" -eq 2 ]
}

@test "the real README builds, and lists every piece file in signage/" {
  run python3 "$BUILD"
  [ "$status" -eq 0 ]
  for f in "${BATS_TEST_DIRNAME}"/../signage/cards/*.html "${BATS_TEST_DIRNAME}"/../signage/sheets/*.html; do
    type="$(basename "$(dirname "$f")")"
    [[ "$output" == *"href=\"${type}/$(basename "$f" .html)/\""* ]]
  done
}
