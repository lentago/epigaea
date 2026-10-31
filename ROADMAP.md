# Roadmap

Aspirational work for this HA instance. Items here are not commitments —
they're prompts for the next conversation. Promote to a GitHub issue when
work actually starts.

## Integrations

- **Firewalla HA integration** — Toggle kids' internet rules, show active
  rulesets, time remaining on scheduled blocks.
- **`firewalla-network-guardian`** — Anomaly detection module (planned
  Lentago Labs repo).
- **Roku integration** — Two Rokus unreachable; possible Firewalla Smart
  Protect interference. Diagnose, then decide whether to whitelist or drop.

## Presence

- **Firewalla `consider_home` tuning** — Default window flaps Android
  device_trackers to `not_home` during routine doze (observed on
  Rachel-s-S23; see #365). Person aggregation now papers over it for
  Rachel via the laptop tracker, but bumping the Firewalla integration's
  `consider_home` to ~900s would also debounce single-source phone
  trackers (`device_tracker.galaxy_s22_presence`,
  `device_tracker.chris_phone_presence`).

## Dashboards

- **Roblox activity detector** — Query Loki for Zeek DNS logs matching
  `roblox.com` / `rbxcdn.com`, surface as a conditional tile on the
  dashboard showing which child's device is playing.
- **Home dashboard polish** — Ongoing iteration on layout, colors, card sizing.

## Signage

Signage is the paper half of an automation: printed, posted at the point of
use, and read by someone who doesn't have the app. It changes in the same PR
as the behaviour it describes. The screen is brasenia's; nothing here renders
to a display. The work is tracked in
[#548](https://github.com/lentago/epigaea/issues/548).

- **Card**: what this control does, posted next to the control. Shipped in
  [`cards/`](cards/).
- **Label**: what this device is and where its card is, on the device or its
  wall plate.
- **Sheet**: what this signal means and what to do about it, one Letter page
  posted by the thing that signals.
