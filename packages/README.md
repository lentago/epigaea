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

The button toggles `switch.meeting_button_in_meeting` on the device: one press starts a meeting, the next ends it. Its ESPHome config is not in git yet (#551). The printed card posted by the button is [`cards/meeting-button.html`](../cards/meeting-button.html), published with `scripts/publish-card.sh meeting-button`; it changes in the same PR as the press behaviour or the lights it drives ([`cards/README.md`](../cards/README.md)).

## `hue_tap_dial_kitchen_sonos.yaml` — Hue Tap Dial → Kitchen Sonos

The Hue Tap Dial (RDM002, ZHA, `device_ieee 00:17:88:01:0d:35:c4:85`) is the physical volume knob for `media_player.kitchen`, and it moves only the Kitchen. Turning it steps the volume 2% per event, up to 6% on a fast spin, clamped to 0-100%; turning up while muted unmutes first. Button 1 is the music and buttons 2-4 are volume: a single tap acts on the Kitchen speaker, a double tap on everyone sharing its music on the first floor. Single taps: 1 play/pause; 2, 3 and 4 set the Kitchen's volume to 20%, 30% and 40% (unmuting first). Double 1 skips to the next track; double 2, 3 and 4 apply the same preset to every first-floor room (Kitchen, Dining Room, Office) in the Kitchen's group. Long 1 is a join/leave toggle: on its own, the Kitchen joins the first playing group among the nearby rooms (Dining Room, then Office) as a member, taking that stream without interrupting it; grouped, the Kitchen leaves. With nothing nearby playing, long 1 does nothing. Long 2, 3 and 4 are unassigned and there are no triple presses. The dial no longer pulls other rooms into the Kitchen's group (the long 2/3 room toggles and the double/triple 1 group presets were retired 2026-10-31): those rooms have their own controls, and the Basement, bedroom and Roam are grouped from the Sonos app. The file header documents the ZHA event shapes (including the 300 ms multi-press queue), the speed-tuning knobs, and the inverted `media_player.office` / `media_player.office_office` ids tracked in #544. The printed fridge card for this mapping is [`cards/kitchen-speaker-dial.html`](../cards/kitchen-speaker-dial.html), published with `scripts/publish-card.sh kitchen-speaker-dial`; it changes in the same PR as the mapping ([`cards/README.md`](../cards/README.md)).

Until 2026-10-30 the dial drove the Play Room lights. Those automations were retired; what the playroom still uses lives in `playroom_lights.yaml`.

## `office_zen77.yaml` — Office wall switch

The Zooz ZEN77 in-wall paddle (Z-Wave, Central Scene) is the office's wall control for the six office lamps; it replaced the Signify RDM001. Up tap turns the lamps on at scene 1 (Bright) or, when they are already on, steps to the next scene; down tap turns them off; holding up or down ramps the current scene's brightness until the paddle is released (floored at 10%). It shares the scene counter and the apply script with `sonoff_button_office.yaml`, so the two controls cycle from the same scene. An automation in the file re-applies the two Z-Wave parameters (Scene Control, Smart Switch Mode) the paddle needs on every start. The printed card posted by the switch is [`cards/office-wall-switch.html`](../cards/office-wall-switch.html), published with `scripts/publish-card.sh office-wall-switch`; it changes in the same PR as the paddle mapping or the scene catalog ([`cards/README.md`](../cards/README.md)).

## `sonoff_button_office.yaml` — Office scene button and scene catalog

Sonoff Button 2 (SNZB-01P, ZHA, `device_ieee 18:69:0a:ff:fe:13:a1:01`) is the office's wireless scene button, and the file owns the office scene machinery both office controls use: the scene counter, the brightness helper, the apply script, the nine-scene catalog (three static, six flicker), the flicker driver loop, and the guard that lets an off command from outside the office controls stop the loop. Single press turns the lamps on at scene 1 (Bright) or, when they are already on, steps to the next scene; double press turns them off; long press jumps straight back to Bright. The printed card posted by the button is [`cards/office-scene-button.html`](../cards/office-scene-button.html), published with `scripts/publish-card.sh office-scene-button`; [`cards/office-wall-switch.html`](../cards/office-wall-switch.html) also prints the scene catalog. Both change in the same PR as the presses or the catalog ([`cards/README.md`](../cards/README.md)).

## `playroom_lights.yaml` — Play Room lights helpers

`script.playroom_lights_power_on` (turns on the Wemo wall switch that feeds the four Hue bulbs and waits for them to rejoin), `script.playroom_color_loop` (software four-colour wash), and the `playroom_color_loop_external_off_guard` automation that lets a plain `light.turn_off` stop the loop. No controller drives them right now; they are kept so the playroom scenes can be rebuilt on another button without re-deriving the wiring.
