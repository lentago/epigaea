#!/usr/bin/env bats
#
# Tests for scripts/check-signage-packages.py, which checks each piece of
# signage's epigaea-card-package meta tags against the files they name: the
# file exists, it links back to the piece, and (with --base) a changed file
# comes with a changed piece (signage/README.md, lentago/epigaea#548). The
# real repo must pass checks 1 and 2. Failure cases run against fixture trees
# built in a temp dir, passed with --root.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/check-signage-packages.py"
  FIX="$(mktemp -d)"
  mkdir -p "${FIX}/signage/cards" "${FIX}/packages"
  cat > "${FIX}/signage/cards/dial.html" <<'EOF'
<!doctype html>
<html><head>
<meta name="epigaea-card-package" content="packages/dial.yaml">
<meta name="epigaea-card-package" content="packages/scenes.yaml">
</head><body>card</body></html>
EOF
  echo "# card: signage/cards/dial.html" > "${FIX}/packages/dial.yaml"
  echo "# card: signage/cards/dial.html" > "${FIX}/packages/scenes.yaml"
}

teardown() {
  rm -rf "$FIX"
}

# Commit the fixture tree as the base, then branch for the change under test.
init_repo() {
  git -C "$FIX" init -q -b main
  git -C "$FIX" config user.email t@example.com
  git -C "$FIX" config user.name t
  git -C "$FIX" add -A
  git -C "$FIX" commit -q -m base
  git -C "$FIX" checkout -q -b change
}

@test "every real piece passes checks 1 and 2" {
  run python3 "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == "signage packages ok: "* ]]
}

@test "the fixture tree passes as built" {
  run python3 "$SCRIPT" --root "$FIX"
  [ "$status" -eq 0 ]
}

@test "a meta tag naming a missing file fails and names both" {
  rm "${FIX}/packages/scenes.yaml"
  run python3 "$SCRIPT" --root "$FIX"
  [ "$status" -eq 1 ]
  [ "$output" = "signage/cards/dial.html: names packages/scenes.yaml, which does not exist" ]
}

@test "a named file that does not mention the piece fails" {
  echo "# no link here" > "${FIX}/packages/dial.yaml"
  run python3 "$SCRIPT" --root "$FIX"
  [ "$status" -eq 1 ]
  [ "$output" = "signage/cards/dial.html: packages/dial.yaml does not mention signage/cards/dial.html" ]
}

@test "a piece with no meta tag fails" {
  echo "<html><head></head><body>x</body></html>" > "${FIX}/signage/cards/bare.html"
  run python3 "$SCRIPT" --root "$FIX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"signage/cards/bare.html: no epigaea-card-package meta tag"* ]]
}

@test "a sheet and a label are checked like a card" {
  mkdir -p "${FIX}/signage/sheets" "${FIX}/signage/labels"
  echo '<meta name="epigaea-card-package" content="packages/gone.yaml">' > "${FIX}/signage/sheets/s.html"
  echo '<meta name="epigaea-card-package" content="packages/gone.yaml">' > "${FIX}/signage/labels/l.html"
  run python3 "$SCRIPT" --root "$FIX"
  [ "$status" -eq 1 ]
  [[ "$output" == *"signage/sheets/s.html: names packages/gone.yaml"* ]]
  [[ "$output" == *"signage/labels/l.html: names packages/gone.yaml"* ]]
}

@test "a changed package with an unchanged piece fails and names the piece" {
  init_repo
  echo "# edit" >> "${FIX}/packages/dial.yaml"
  git -C "$FIX" commit -q -am edit
  run python3 "$SCRIPT" --root "$FIX" --base main
  [ "$status" -eq 1 ]
  [ "$output" = "packages/dial.yaml: changed, but no piece that names it changed; review signage/cards/dial.html" ]
}

@test "a package changed together with its piece passes" {
  init_repo
  echo "# edit" >> "${FIX}/packages/dial.yaml"
  echo "<!-- edit -->" >> "${FIX}/signage/cards/dial.html"
  git -C "$FIX" commit -q -am edit
  run python3 "$SCRIPT" --root "$FIX" --base main
  [ "$status" -eq 0 ]
}

@test "a change to a file no piece names passes" {
  init_repo
  echo "x" > "${FIX}/packages/other.yaml"
  git -C "$FIX" add -A
  git -C "$FIX" commit -q -m other
  run python3 "$SCRIPT" --root "$FIX" --base main
  [ "$status" -eq 0 ]
}

@test "the skip reason passes check 3 and is printed" {
  init_repo
  echo "# edit" >> "${FIX}/packages/dial.yaml"
  git -C "$FIX" commit -q -am edit
  run python3 "$SCRIPT" --root "$FIX" --base main --skip-changed-together "comment only"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"*"comment only"* ]]
}

@test "the skip reason does not hide a missing file" {
  init_repo
  rm "${FIX}/packages/scenes.yaml"
  run python3 "$SCRIPT" --root "$FIX" --base main --skip-changed-together "reason"
  [ "$status" -eq 1 ]
  [[ "$output" == *"which does not exist"* ]]
}

@test "usage errors exit 2" {
  run python3 "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  run python3 "$SCRIPT" --skip-changed-together "reason"
  [ "$status" -eq 2 ]
  run python3 "$SCRIPT" --root "${FIX}/nowhere"
  [ "$status" -eq 2 ]
  init_repo
  run python3 "$SCRIPT" --root "$FIX" --base no-such-ref
  [ "$status" -eq 2 ]
}
