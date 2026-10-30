# packages/

HA [packages](https://www.home-assistant.io/docs/configuration/packages/) — self-contained YAML units that bundle related entities, automations, and services. Loaded via `!include_dir_named packages` in `configuration.yaml`, which merges each file's keys into the top-level config namespace.

## `ha_version_sync.yaml` — HA Version Sync

Automatically tracks the running HA version and opens a PR to update `.ha-version` when it drifts from the pinned CI value.

### Components

**`sensor.ha_core_version`** — `command_line` sensor reading `/config/.HA_VERSION` (HA's own runtime version file, distinct from the git-tracked `.ha-version` pin). Updated hourly. Provides a queryable entity for the running version; the startup dispatch is event-driven, not polled from this sensor.

**`rest_command.github_dispatch_version`** — POSTs a `ha-version-report` repository dispatch event to the GitHub API with `client_payload.version` set to the current HA version. Uses `!secret github_pat` (a PAT with `Contents: Write` on this repo).

**`automation.ha_version_sync_on_start`** — Fires on `homeassistant_started`, calls `rest_command.github_dispatch_version`. `mode: single` prevents duplicate dispatches on rapid-reboot bursts.

### How the full loop works

```
homeassistant_started
  → rest_command POSTs dispatch to GitHub API
  → ha-version-sync.yml workflow validates version format
  → compares incoming version to .ha-version on main
  → if equal: exits 0 (no-op)
  → if drift: creates ha-version-bump/<version> branch
               bumps .ha-version
               opens PR via HA_SYNC_PAT
  → PR triggers ha-config-check against the new version
  → auto-merge fires on check pass
```

### Why `HA_SYNC_PAT` instead of `GITHUB_TOKEN`

Two constraints force a PAT:

1. `GITHUB_TOKEN`-created PRs do not trigger other GitHub Actions workflows (intentional anti-loop guard). The version-bump PR needs to fire `ha-config-check` and the Claude review — both run on `pull_request` events. A PAT-opened PR bypasses this.
2. `actions/checkout` uses its `token:` input for all `git push` calls in the job. `github-actions[bot]` lacks write access to this repo under branch protection, so the push to the bump branch fails with 403 unless the PAT is substituted.

The same PAT lives in two places: `secrets.yaml` on the HA instance as `github_pat` (for the dispatch POST) and in repo Actions secrets as `HA_SYNC_PAT` (for checkout and PR creation).

## `meeting_indicator.yaml` — Meeting Indicator

A physical "in a meeting" signal for Rachel's office. An ESP32 button (`switch.meeting_button_in_meeting`) drives two lights red while a meeting is on:

- **`light.meeting_light`** — a dedicated hallway indicator. Simply red (on) or off.
- **`light.corner_lamp`** — one of the six office lamps. Turned red as an in-room indicator while a meeting is active, then handed back to the office scene controller when the meeting ends.

### corner_lamp ownership

`corner_lamp` is normally driven by the office scene controller (`office_zen77.yaml` + `sonoff_button_office.yaml`). While a meeting is active the meeting indicator owns it exclusively — the office controller drops `corner_lamp` from every scene-apply and office-off action, so cycling the office scene mid-meeting cannot disturb the red.

`light.meeting_light` being on is the shared "a meeting is active" signal: nothing else ever turns it on, and both this package and the office controller read it via `is_state('light.meeting_light', ...)`.

### Components

**`script.meeting_indicator_show`** — turns the hallway light and `corner_lamp` red. If the office is mid-flicker it waits ~1 s for the candle loop's `corner_lamp` branch to bow out before claiming the lamp, and skips `corner_lamp` if the meeting ended during that wait.

**`script.meeting_indicator_clear`** — turns the hallway light off, then hands `corner_lamp` back: off if the rest of the office is off, otherwise re-renders the current office scene via `script.office_sonoff_apply_scene` so `corner_lamp` rejoins it.

**Four automations** — `meeting_status_on` / `meeting_status_off` (button on/off), `meeting_button_offline` (unavailable 10 s — fail-safe clear), `meeting_button_reconnect` (re-sync after a WiFi blip). Each just calls one of the two scripts.

## `hue_tap_dial_kitchen_sonos.yaml` — Hue Tap Dial → Kitchen Sonos

The Hue Tap Dial (RDM002, ZHA, `device_ieee 00:17:88:01:0d:35:c4:85`) is the physical volume knob for `media_player.kitchen`. Turning it steps the volume 2% per event, up to 6% on a fast spin, clamped to 0-100%; turning up while muted unmutes first. Short presses: 1 play/pause, 2 next track, 3 previous track, 4 mute toggle. Long presses are unmapped. The file header documents the ZHA event shapes and the speed-tuning knobs.

Until 2026-10-30 the dial drove the Play Room lights. Those automations were retired; what the playroom still uses lives in `playroom_lights.yaml`.

## `playroom_lights.yaml` — Play Room lights helpers

`script.playroom_lights_power_on` (turns on the Wemo wall switch that feeds the four Hue bulbs and waits for them to rejoin), `script.playroom_color_loop` (software four-colour wash), and the `playroom_color_loop_external_off_guard` automation that lets a plain `light.turn_off` stop the loop. No controller drives them right now; they are kept so the playroom scenes can be rebuilt on another button without re-deriving the wiring.
