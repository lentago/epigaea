#!/usr/bin/env bats
#
# Unit tests for apply_reload() in scripts/gitops-sync.sh.
#
# apply_reload() is the smart-routing decision tree the GitOps loop uses to pick
# the lightest safe reload for a given change set (dashboards -> themes ->
# automations -> scripts -> scenes -> full restart, with no-op and fallback
# cases). It is pure path-matching logic with no HA dependency, so it can be
# exercised in isolation by sourcing the script and stubbing its side-effecting
# helpers (log / ha_call_service / ha_core_restart / ha_notify) plus `git diff`.
#
# Each stub appends a token to $CALLS_FILE; tests assert on the recorded calls.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/gitops-sync.sh"

  # Source the script. The `BASH_SOURCE == $0` guard at the bottom prevents the
  # lock-acquire + main() from firing when sourced, so only the functions load.
  # shellcheck source=../scripts/gitops-sync.sh
  source "$SCRIPT"

  CALLS_FILE="${BATS_TEST_TMPDIR}/calls"
  : > "$CALLS_FILE"

  # --- stubs over the script's side-effecting helpers ---
  log()           { :; }                                   # silence /config logging
  ha_notify()     { :; }
  ha_call_service() { printf 'CALL %s %s\n' "$1" "$2" >> "$CALLS_FILE"; }
  ha_core_restart() { printf 'RESTART\n'        >> "$CALLS_FILE"; }

  # Stub `git diff` so the changed-file list is injectable via $MOCK_DIFF.
  # Everything else falls through to the real git.
  git() {
    if [[ "$1" == "diff" ]]; then
      printf '%s' "$MOCK_DIFF"
    else
      command git "$@"
    fi
  }

  export CALLS_FILE
}

# Convenience: run apply_reload with a non-empty old_sha and the given diff.
run_with_diff() {
  MOCK_DIFF="$1"
  run apply_reload "OLDSHA" "NEWSHA"
}

@test "empty old_sha falls back to a full restart" {
  run apply_reload "" "NEWSHA"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS_FILE")" = "RESTART" ]
}

@test "empty diff falls back to a full restart" {
  run_with_diff ""
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS_FILE")" = "RESTART" ]
}

@test "dashboard-only change reloads lovelace resources and themes" {
  run_with_diff "dashboards/home.yaml"
  [ "$status" -eq 0 ]
  grep -qx "CALL lovelace reload_resources" "$CALLS_FILE"
  grep -qx "CALL frontend reload_themes"    "$CALLS_FILE"
  ! grep -q "RESTART" "$CALLS_FILE"
}

@test "theme-only change reloads themes" {
  run_with_diff "themes/noctis-home.yaml"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS_FILE")" = "CALL frontend reload_themes" ]
}

@test "top-level automations.yaml reloads automations" {
  run_with_diff "automations.yaml"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS_FILE")" = "CALL automation reload" ]
}

@test "automations subdir yaml reloads automations" {
  run_with_diff "automations/exterior_doors_night.yaml"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS_FILE")" = "CALL automation reload" ]
}

@test "scripts.yaml reloads scripts" {
  run_with_diff "scripts.yaml"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS_FILE")" = "CALL script reload" ]
}

@test "scenes.yaml reloads scenes" {
  run_with_diff "scenes.yaml"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS_FILE")" = "CALL scene reload" ]
}

@test "shell scripts under scripts/ are a no-op (not a script.reload)" {
  # scripts/*.sh must NOT be confused with scripts/*.yaml -> script.reload.
  run_with_diff "scripts/gitops-sync.sh"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS_FILE" ]
}

@test "docs, context, .github, esphome, and dotfiles are no-ops" {
  run_with_diff "$(printf '%s\n' \
    "README.md" \
    "context/entities.json" \
    ".github/workflows/lint.yml" \
    "esphome/konnected-56ac70.yaml" \
    ".gitignore" \
    ".yamllint.yml")"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS_FILE" ]
}

@test "cards, tests, assets, agent tooling and CI-only files are no-ops" {
  # None of these is read by HA Core at runtime (#550). cards/ was the trigger:
  # a printable-card-only merge used to restart Core.
  run_with_diff "$(printf '%s\n' \
    "cards/office-wall-switch.html" \
    "tests/apply_reload.bats" \
    "assets/banner.svg" \
    ".claude/settings.json" \
    ".ha-version" \
    "secrets.fake.yaml" \
    "secrets.yaml.example")"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS_FILE" ]
}

@test "a card alongside a package change still restarts" {
  # The no-op set must not mask a heavy file in the same diff.
  run_with_diff "$(printf '%s\n' \
    "cards/office-wall-switch.html" \
    "packages/office_zen77.yaml")"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS_FILE")" = "RESTART" ]
}

@test "mixed lightweight changes trigger each matching reload, no restart" {
  run_with_diff "$(printf '%s\n' \
    "dashboards/home.yaml" \
    "automations.yaml" \
    "scenes.yaml")"
  [ "$status" -eq 0 ]
  grep -qx "CALL lovelace reload_resources" "$CALLS_FILE"
  grep -qx "CALL frontend reload_themes"    "$CALLS_FILE"
  grep -qx "CALL automation reload"         "$CALLS_FILE"
  grep -qx "CALL scene reload"              "$CALLS_FILE"
  ! grep -q "RESTART" "$CALLS_FILE"
}

@test "a file outside the lightweight set forces a full restart" {
  run_with_diff "configuration.yaml"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS_FILE")" = "RESTART" ]
}

@test "restart wins even when mixed with lightweight changes" {
  # configuration.yaml (heavy) alongside a dashboard (light): the heavy file
  # must short-circuit to a single full restart with no partial reloads.
  run_with_diff "$(printf '%s\n' \
    "configuration.yaml" \
    "dashboards/home.yaml")"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS_FILE")" = "RESTART" ]
}
