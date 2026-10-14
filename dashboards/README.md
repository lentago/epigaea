# dashboards/

YAML-managed Lovelace dashboards. The git-tracked dashboards — `home.yaml`, `home-codesign.yaml`, and `lentago-lab-status.yaml` — are registered in `configuration.yaml` under `lovelace.dashboards` in `mode: yaml` and deploy automatically via the GitOps pipeline. Git is their source of truth; no UI editor involvement.

## The Home dashboard family — one master, two clones

The Home dashboard follows a deliberate **single-master / two-clone** scheme so
design iteration and ad-hoc UI tweaks never put the live wall display at
risk. Intent flows in one direction — **out from the master** — and each clone
has a single job:

```
┌──────────────────────┐   sync-home-codesign.sh   ┌──────────────────────────┐
│ MASTER (git)         │ ─────────────────────────▶│ CO-DESIGN CLONE (git)    │
│ dashboards/home.yaml │      one-way mirror        │ dashboards/              │
│ mode: yaml           │   (CI-enforced, no drift)  │   home-codesign.yaml     │
│ /dashboard-home/home │                            │ mode: yaml               │
│ SOURCE OF TRUTH      │                            │ /dashboard-home-codesign │
└──────────┬───────────┘                            │ live-preview iteration   │
           │                                        └──────────────────────────┘
           │ import-dashboard-to-storage.sh
           │  one-way export (reseed)
           ▼
┌──────────────────────────┐
│ UI-EDITABLE CLONE        │
│ .storage/ (gitignored)   │
│ mode: storage            │
│ /home-ui-edit            │
│ ad-hoc drag/drop tweaks  │
│ DRIFTS BY DESIGN         │
└──────────────────────────┘
```

| Dashboard | File / location | Mode | Role |
|---|---|---|---|
| **Home (master)** | `dashboards/home.yaml` (git) | `yaml` | **The source of truth.** Everything flows from here. All real changes land here via PR and deploy through GitOps. |
| **Home (Co-design)** | `dashboards/home-codesign.yaml` (git) | `yaml` | Safe live-preview iteration target. A generated mirror of the master with only the first view's tab title/icon and theme swapped. |
| **Home (UI-editable)** | `.storage/` (gitignored runtime state) | `storage` | Ad-hoc UI tweaks via drag/drop. A one-way snapshot exported from the master — **not** a source of truth, never in git, drifts by design. |

### Drift & source-of-truth policy

- **Master is canonical.** If any clone disagrees with `home.yaml`, the master
  wins. Reconcile by editing `home.yaml` and re-syncing/re-exporting the clone —
  never the reverse as an implicit "the clone is newer" merge.
- **The co-design clone must not drift.** It is regenerated from the master, and
  CI (`Tests › Codesign Sync`) fails the build if it lags. See sync procedure
  below.
- **The UI-editable clone drifts by design.** It lives in gitignored `.storage/`
  runtime state (per the CLAUDE.md three-layer state model), so it will never
  appear in git and will diverge from the master the moment anyone hand-edits it
  in the UI. That divergence is expected — it is a disposable scratch copy, not
  the git source of truth.

### Keeping the co-design clone in sync (master → co-design)

The co-design twin is **generated, never hand-edited**. It is produced by
[`scripts/sync-home-codesign.sh`](../scripts/README.md#sync-home-codesignsh),
which copies `home.yaml` verbatim and swaps only three cosmetic lines on the
first view (tab title `Home`→`Co-design`, icon `mdi:monitor-dashboard`→
`mdi:monitor-edit`, theme `Home Polish`→`Home Codesign`). Every card, template,
and entity reference is identical to production.

Workflow:

1. Make the real change in **`home.yaml`** (master).
2. Run `scripts/sync-home-codesign.sh` to regenerate `home-codesign.yaml`.
3. Commit both files in the same PR.

`scripts/sync-home-codesign.sh --check` runs in CI (`Tests › Codesign Sync`) and
fails if the mirror has drifted, so a master change that skips the regen is
caught before merge. The `AUTO-GENERATED — DO NOT EDIT BY HAND` banner at the
top of `home-codesign.yaml` is the in-file reminder.

**Iterating in co-design:** to preview a design study, open
`http://homeassistant.local:8123/dashboard-home-codesign/home` (retired pve2
wall display no longer figures in this — it renders in the HA web UI / companion
app). Because the clone is generated, iterate by editing `home.yaml` and
re-running the sync; the co-design view then reflects your changes without ever
touching the live `/dashboard-home/home` tab. When happy, that same `home.yaml`
edit *is* the master change — nothing to "fold back."

### Refreshing the UI-editable clone (master → `.storage`)

The storage-mode UI-editable clone is exported from the master by
[`scripts/import-dashboard-to-storage.sh`](../scripts/README.md#import-dashboard-to-storagesh),
which must run **inside the HA Core container** (it needs Core's Python +
`aiohttp` + PyYAML and a long-lived token):

```bash
# from the HAOS host (has docker; the SSH add-on does not):
docker exec homeassistant /config/scripts/import-dashboard-to-storage.sh
# → seeds dashboards/home.yaml into a storage dashboard "Home (UI Edit)" at /home-ui-edit
```

This registers (or, on re-run, overwrites the config of) a `mode: storage`
Lovelace dashboard at `/home-ui-edit`. It is a **reseed-from-source** operation:
re-running clobbers any hand-edits in the UI copy and restamps it from the
current `home.yaml`. The next `ha-context-dump.sh` snapshot captures it in
`context/dashboards-storage.json`.

**Folding UI edits back into the master:** there is no automated path — by
design. The UI-editable clone is `.storage/` runtime state and will not appear
in git. If a UI tweak is worth keeping, transcribe the change into `home.yaml`
by hand and PR it; that PR is the durable record. Then re-export to reseed the
UI copy from the now-updated master. Anything left only in the UI copy is
disposable and will be lost on the next reseed (or a rebuild).

## `home.yaml` — Home view (`/dashboard-home/home`)

Mobile-first control interface. Design principle: show only what's active.

- **Masonry layout** — standard scrollable column layout
- **Conditional lighting cards** — each light appears only when on; all-off rooms show an "All off" chip using template sensors from `configuration.yaml`
- **Sonos group-awareness** — 6 media player cards, each gated on a `binary_sensor.sonos_*_leader` template sensor; only the group coordinator shows when speakers are grouped
- **Alarm panel** — always visible at top, with a 3×2 sensor grid showing all door/motion contacts
- **Weather forecast** — daily summary from Met.no

- **Native `sections` view — no hard layout** — the view is `type: sections` (`max_columns: 3`). Cards size to their content, sections reflow responsively, and the page scrolls if content exceeds the screen. There is **no** `custom:grid-layout`, no `custom:mod-card` height-cascade wrapper, and no fixed-pixel "fit 2560x1440 without a scrollbar" math. The previous pixel-fit grid-layout design was retired 2026-06-11 — the size-fit requirement was deliberately abandoned.
- **Typed cards per section** — every tile is a typed Lovelace card (`button-card`, `mushroom-light-card`, `mushroom-chips-card`, `mini-media-player`, `clock-weather-card`, `thermostat` dial). Multi-tile rows use nested `type: grid` cards.
- **State-driven styling** — colors live in per-card `state` blocks (`button-card`) + theme tokens, not Jinja-templated HTML. The alarm hero pulses on triggered.
- **Interactive** — light tiles toggle on tap (hold = more-info); sensors, alarm, TVs, and the climate standby tiles open more-info dialogs; thermostat dials expose +/- and menu controls; mini-media-player tiles show transport + volume overlaid on artwork; the meeting indicator toggles `switch.meeting_button_in_meeting` on tap.
- **Unavailable handling** — declared inside each card's `state` list (e.g. a `value: unavailable` block on a button-card), not via wrapper conditionals.

**Sections** (reflow across `max_columns: 3`, each introduced by a native `heading` card):

| Section | Contents |
|------|----------|
| Weather | single `clock-weather-card` (clock + current conditions + 5-row forecast) |
| Security | `button-card` alarm hero for `alarm_control_panel.home_alarm` + arm/disarm row (3 buttons) + front-door camera (`picture-entity`, snapshot) |
| Openings | 8 `button-card` tiles in a 2-col grid (4 doors + 2 garage covers + 2 motion) |
| Presence | meeting-indicator `button-card` (taps `switch.meeting_button_in_meeting`) + Chris/Rachel presence tiles |
| Climate | 2 `thermostat` dials (Upstairs/Downstairs), each with a `mushroom-chips-card` strip (humidity, setpoint, HVAC action); standby mode swaps the dial for a large current-temp tile |
| Lights | 18 `mushroom-light-card` tiles grouped into 5 room sub-grids (Family, Kitchen, Office, Hallways, Outdoor) under `heading` subtitles |
| Media | 5 `mini-media-player` cards (album art via `artwork: full-cover-fit`) in a 2-col grid + a TV `button-card` |

### kiosk-mode (third-party HACS card)

The `kiosk_mode` block at the top of `home.yaml` hides header and sidebar **only for the `Kiosk` non-admin user**. The pve2 wall display that used the Kiosk account was retired 2026-06-23; the block remains in place so it takes effect if a kiosk user is ever re-added. Normal admin sessions see the sidebar and header as usual.

## `lentago-lab-status.yaml` — Lentago Lab Status (mental-map fleet view)

Multi-tab dashboard at `/dashboard-lentago-lab-status/`. Built as a **manifest of `!include`d view files** so each "lens" lives in its own file and can be evolved, added, or retired independently.

```
dashboards/
├── lentago-lab-status.yaml      ← manifest: just a list of !include lines
└── lentago-lab-views/
    ├── hardware.yaml            ← Lens 1: physical fleet
    ├── repos.yaml               ← Lens 2: lentago/* commit / PR / issue activity
    ├── smart_home.yaml          ← Lens 3: rooms as objects, alarm hero
    ├── networks.yaml            ← Lens 4: Zigbee / Z-Wave / WiFi / LAN meshes
    ├── automations.yaml         ← Lens 5: silent-failure detection
    ├── backups.yaml             ← Lens 6: PVE jobs, NAS scrub, HAOS backup
    ├── issues.yaml              ← Lens 7: queue (alarms + GitHub + depletion)
    └── details/
        ├── pve.yaml             ← (one per fleet member that has detail)
        ├── pve2.yaml … pve5.yaml
        ├── haos.yaml
        ├── grafana-stack.yaml
        └── ups.yaml
```

### Lens model

Each lens answers a single "what am I looking at?" question. The user can have many lenses without their content fighting for canvas — switching lenses is a tab click. Lenses can be added, refined, or obsoleted over time without dashboard-wide refactoring; each lens is one file.

### Drill-down pattern (subviews)

Files under `lentago-lab-views/details/` set `subview: true`, which hides them from the top tab strip and adds an automatic back-arrow. Tiles in a lens use `tap_action: navigate, navigation_path: /dashboard-lentago-lab-status/<view-path>` to drill in. `hold_action: more-info` keeps HA's built-in entity dialog one long-press away.

Add a drill-down by dropping a new file under `details/` with a unique `path:`, then add it to the include list in `lentago-lab-status.yaml`.

### Iteration workflow

Edit any `lentago-lab-views/**` file and push. The GitOps loop deploys within 5 minutes. Key flag to know: HA's yaml-mode cache is keyed off the manifest's mtime (not the `!include` child's), so changing only a child view won't bust the cache. Touch `lentago-lab-status.yaml` (or use `scripts/force-sync.sh`) to force a reload.

## HACS Dependencies

| Card | Used by |
|------|---------|
| [Mushroom](https://github.com/piitaya/lovelace-mushroom) | Home view light/entity/alarm cards; `mushroom-light-card` per light on home dashboard |
| [mini-media-player](https://github.com/kalkih/mini-media-player) | Sonos cards on Home view; home dashboard media cells with `artwork: full-cover-fit` |
| [layout-card](https://github.com/thomasloven/lovelace-layout-card) | No longer used by the home dashboard (it moved to native `type: sections` 2026-06-11); retained as a HACS dep for other views |
| [card-mod](https://github.com/thomasloven/lovelace-card-mod) | Theme-level CSS (`card-mod-root`) + per-card `card_mod` (e.g. the home media-tile group-dimming) |
| [button-card](https://github.com/custom-cards/button-card) | Sensor tiles, alarm hero, heater, TVs row in home view |
| [better-thermostat-ui-card](https://github.com/KartoffelToby/better-thermostat-ui-card) | No longer used by the home dashboard (native `thermostat` dial since #354); retained as a HACS dep |
| [kiosk-mode](https://github.com/NemesisRE/kiosk-mode) | Sidebar/header hiding for the Kiosk non-admin user |
| [clock-weather-card](https://github.com/pkissling/clock-weather-card) | Combined clock + 4-day forecast on home dashboard top strip |
