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

## Instruction cards

- **Cards for the other repurposed controls** — the Office RDM001 switch and
  the two SNZB-01P buttons each carry a mapping nobody has written down.
- **Card index page** — a generated `http://pub.lan/cards/` listing from
  `cards/README.md`'s index table, so a phone can find any card.
- **Card-to-package check in CI** — fail a PR that changes a package named by a
  card's `epigaea-card-package` meta tag without touching that card, and one
  whose meta tag names a package that does not exist.
- **PDF export** — render each card to PDF in CI so a facility without a
  browser on the printer PC still gets the same 7 by 5 output.
- **Facilities-kit extraction** — the card contract is the first staff-facing
  piece of the kit tracked in lentago/.github#129; decide what of `cards/`
  generalises (contract, publisher, index) and what stays house-specific.
