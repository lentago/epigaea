# tests/

Fast, dependency-light tests for the repo's shell logic. They run on a stock
Ubuntu runner with `shellcheck` + `bats` — **no Home Assistant instance and no
secrets required** — via the `Tests` workflow (`.github/workflows/tests.yml`).

This complements, rather than replaces, the existing gates:

| Gate | Scope |
|---|---|
| `YAML Lint` (`lint.yml`) | yamllint syntax/style across all YAML |
| `check-config` (`ha-config-check.yml`) | Real HA validates the proposed config |
| **`ShellCheck` (`tests.yml`)** | Static analysis of every `scripts/*.sh` |
| **`Bats` (`tests.yml`)** | Behavioral unit tests for shell logic |

## Running locally

```bash
sudo apt-get install -y shellcheck bats   # one-time
shellcheck scripts/*.sh
bats tests/
```

## What's covered

- **`apply_reload.bats`** — the smart-reload routing tree in
  `scripts/gitops-sync.sh` (`apply_reload`). This is the GitOps loop's decision
  about the lightest safe reload for a change set (dashboards → themes →
  automations → scripts → scenes → full restart, plus no-op and fallback cases).
  A bug here means a deploy silently doesn't take effect, or HA gets needlessly
  restarted. The function is pure path-matching with no HA dependency, so the
  suite sources the script and stubs its side-effecting helpers
  (`log` / `ha_call_service` / `ha_core_restart` / `ha_notify`) and `git diff`.

- **`publish_card.bats`** — `scripts/publish-card.sh`, the instruction-card
  publisher. Publishes the first card into a temp web root and checks the
  copy, the printed URL, the in-place overwrite, and every refusal (bad slug,
  missing card, missing web root, a web root that is not on a network share, CLI usage), since the refusals are what
  keep a typo off the live `pub.lan` share.

- **`card_size.bats`**: runs `scripts/check-card-size.sh` over every card and
  fails if one prints taller than 5 inches (the card contract in
  `cards/README.md`, #560). It also checks that an over-limit card is named and
  that an unknown card is a usage error. The measurement needs headless Chrome
  (preinstalled on the Ubuntu runner) and the cards' Google Fonts. Without
  either, the script exits 3 and the size tests skip rather than judge a
  height measured with fallback fonts.

- **`context_dump.bats`** — the snapshot transforms in
  `scripts/ha-context-dump.sh` (`build_entities`, `build_areas`,
  `build_devices`, `build_helpers`, `build_dashboards_storage`,
  `storage_items`). These are pure jq projections over HA's `.storage/` registry
  files; a bug silently produces a malformed or empty `context/` snapshot that
  everything downstream trusts. The suite feeds each transform JSON fixtures
  under `tests/fixtures/storage/` — covering the device↔config_entry integration
  join, `name`/`name_by_user` precedence, disabled-entity filtering, and the
  presence-stable empty-array behavior for absent `.storage` files.

- **`secrets_coverage.bats`** — asserts every `!secret` reference in the HA
  config resolves in `secrets.fake.yaml`, so a new reference can't pass locally
  yet break the `check-config` gate with an opaque error. (`esphome/` is
  excluded — it isn't part of HA's `check-config`.)

- **`dashboard_entities.bats`** — tests `scripts/check-dashboard-entities.py`,
  the dashboard entity-reference checker. HA does not validate dashboard entity
  IDs at config-check time, so a typo'd/renamed entity renders a silent
  blank/unavailable card. The script cross-references the IDs in
  `dashboards/*.yaml` against `context/entities.json` (which includes YAML
  template entities and light groups, since they carry a `unique_id`). The suite
  proves it catches a bad reference, resolves the `entity` / `entities` /
  `entity_id` forms, ignores templated values, honors `dashboards/entity-allowlist.txt`,
  and flags a stale allowlist entry once its entity enters the snapshot.

  The `Dashboard Entities` CI job runs the checker `--strict` against the real
  snapshot. The allowlist exempts entities that are valid-but-unregistered (a
  YAML entity with no `unique_id`) or pending an integration that isn't set up
  yet; prune it as the checker's "can be removed" note directs.

- **`validate_inputs.bats`** — tests `scripts/validate-ha-version.sh` and
  `scripts/validate-context-branch.sh`, the regex validators the sync workflows
  use to gate what gets auto-committed (`.ha-version`) and which externally-
  supplied `repository_dispatch` branch becomes a PR. Covers accept/reject cases
  (dev builds, prefixes, partials, wrong separators, path traversal, trailing
  whitespace, injection-shaped input) plus the CLI exit-code/stdout contract the
  workflows depend on.

- **`force_sync.bats`** — tests `scripts/force-sync.sh`, the helper that
  collapses the cross-layer latency windows. Sources the script, stubs
  `ha_call_service`, and asserts `force_sync` deploys (gitops) *before*
  reconciling the snapshot (dump button), plus that the CLI refuses to run
  without `SUPERVISOR_TOKEN`.

## Making a script testable

Scripts that self-execute at the bottom should guard that call so the file can
be sourced without side effects:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_locked
fi
```

Sourcing then loads only the function definitions, letting a bats `setup()`
override the side-effecting helpers before calling the function under test.
