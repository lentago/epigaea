# CLAUDE.md — epigaea (lentago/epigaea)

Renamed from `homeassistant-config` on 2026-08-17 ([lentago/.github#116](https://github.com/lentago/.github/issues/116)) — it graduated into the fleet's botanical codename tier because it stopped being a config dump and became the base for the cold-chain and facilities product line.

Git-controlled Home Assistant OS deployment on a Proxmox VM. YAML-driven —
the HA UI is used only for integration setup (which HA stores in `.storage/`,
excluded from git).

- **Config dir:** `/homeassistant/` on the VM, accessible as `/config/` from
  the SSH add-on.
- **Owner:** Chris Pitzi (GitHub: cpitzi, org: lentago).
- **Roadmap:** see `ROADMAP.md`.

## Persona — introduce yourself

When Claude initializes in this directory, open the first response with a
brief self-introduction as **Epigaea Claude** — curator of the HAOS YAML
source-of-truth (automations, packages, dashboards, dashboard YAML, ESPHome,
scripts) and the GitOps pipeline that deploys it. The HAOS VM itself is
Home Claude's turf — see `~/CLAUDE.md`. One sentence is plenty; don't make a
meal of it.

Subdirectory READMEs are the canonical reference for their domain — defer
to them when implementing:

| Subdir | When to read |
|---|---|
| `esphome/README.md` | Konnected alarm panels, ESPHome firmware, RTTTL annunciator |
| `automations/README.md` | UI-vs-git authorship split for automations |
| `packages/README.md` | HA Version Sync, Meeting Indicator, scene controllers |
| `dashboards/README.md` | All three Lovelace dashboards (Home, Home Co-design, Lentago Lab Status) |
| `themes/README.md` | Noctis Home theme, home_polish tokens |
| `scripts/README.md` | gitops-sync.sh, ha-context-dump.sh, Script auth conventions |
| `context/README.md` | What each `context/*.json` file is |
| `docs/` | Long-form design notes, migration write-ups |

---

## Three-Layer State Model

This repo treats Home Assistant state as three coordinated layers. Each has a
distinct job, and intent flows from right to left:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ LIVE (MCP)      │     │ SNAPSHOT        │     │ INTENT (YAML)   │
│ ha-mcp server   │  →  │ context/*.json  │  ←  │ /config/*.yaml  │
│ read + write    │     │ 6h dump, RO     │     │ git, PR-gated   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

**1. Intent (YAML, this repo)** — `/config/*.yaml` is the durable source of
truth for everything that should survive a rebuild: `automations/`, `packages/`,
`dashboards/`, `themes/`, `configuration.yaml`, ESPHome firmware, shell
scripts. Changes land via PR; the GitOps loop deploys merged main commits
within 5 minutes. **If a feature should survive a rebuild, it lives here.**

**2. Snapshot (`context/`)** — A generated artifact dumped from the live HA
instance every 6 hours (or on `input_button.ha_context_dump_now`) via
`scripts/ha-context-dump.sh`. Captures the entity/device/area registries,
the UI-managed `automations.yaml`, and storage-mode scripts/scenes/helpers/
dashboards. **Read-only** — `.claude/hooks/block-context-writes.sh` rejects
tool calls that would mutate it. The `ha-context-sync.yml` workflow opens
an auto-merging PR when the snapshot drifts from main, so the registry
state in git is never more than ~6 hours stale.

**3. Live (HA-MCP)** — The HA MCP server (`homeassistant-ai/ha-mcp` HACS
integration, running inside HA) exposes the REST and WebSocket APIs as
`mcp__*__ha_*` tools. State is current to the second; history, logs, and
service calls are accurate. Writes here (`ha_config_set_*`, `ha_set_entity`,
`ha_update_device`, area/floor creation) land in `.storage/` (gitignored).
Use it to **prototype and inspect**, never as a substitute for committing
YAML.

**Layer selection rule**: read from the cheapest layer that's still accurate
enough. YAML for *intent* ("what should be true"). `context/` for fast,
grep-friendly structural lookups. MCP only when staleness would mislead you,
or when you need history, logs, templates, or service calls.

**Drift resolution**: if `context/` and MCP disagree, MCP wins — the snapshot
is stale; ask the user to press `input_button.ha_context_dump_now` and re-run.
If YAML and the live runtime diverge for something that should be in YAML
(automation, dashboard, package), the YAML is canonical — reconcile by editing
YAML and letting GitOps redeploy. The *Drift guardrail* subsection under
*HA Runtime Access* below catalogs which object types live in `.storage/`
vs YAML.

**Mutating across layers**: a change that spans LIVE, INTENT, and SNAPSHOT
(e.g. an entity rename) needs a deliberate order, or one layer ends up
referencing state another doesn't have. The runbook — ordering by change
type, the rename recipe, and the `scripts/force-sync.sh` window-collapse
helper — is in `docs/cross-layer-changes.md`.

---

## Key Patterns & Conventions

- **Git is source of truth.** All YAML config is committed. `.storage/` is
  runtime state excluded from git.
- **Secrets pattern.** Real values in `secrets.yaml` (gitignored), documented
  keys in `secrets.yaml.example` (committed). Same pattern in `esphome/`.
  `secrets.fake.yaml` provides safe dummy values for CI `check_config`.
- **ESPHome configs are fully inlined.** No `github://` remote package
  references. Every pin, sensor, and setting is explicit in the local YAML.
  See `esphome/README.md`.
- **Entity IDs retain original adoption names.** The siren is
  `switch.alarm_panel_56ac70_siren` (not `switch.main_panel_siren`) because
  ESPHome entity IDs are set at first adoption and don't change when the
  device is renamed. Same convention applies to other adopted devices
  (`switch.bonus_room` is the play room Hue-bulb power switch despite the
  device being renamed).
- **Authoritative entity list:** `context/entities.json`. Query with `jq` —
  see *HA Runtime State Context* below. The CLAUDE.md no longer maintains
  an entity reference table because it drifts; the snapshot doesn't.
- **Template entities live in `configuration.yaml > template:`.** Four
  groups: Sonos-leader binary sensors (group-coordinator detection),
  per-room light-activity binary sensors, per-room "lights on" count
  sensors, and the composite `light.floor_lamp_composite` + a
  trigger-based daily weather forecast sensor. Light *groups*
  (`light.outdoor`, `light.downstairs`) sit in the top-level `light:`
  block, not under `template:`.
- **Sonos group-awareness.** `binary_sensor.sonos_*_leader` template sensors
  detect group coordinators on the Home view; only the coordinator's media
  card renders, preventing duplicate cards when speakers are grouped.
- **Home view uses conditionals.** Light/switch tiles in the Home view are
  wrapped in `type: conditional` so each tile appears only when the entity
  is on; per-room "All off" tiles use `binary_sensor.*_lights_on` template
  sensors.
- **Home dashboard uses HA-native `sections`, no hard pixel-fit.** The home view
  is `type: sections` (`max_columns: 3`) — cards size to their content,
  sections reflow responsively, and the page scrolls if content exceeds
  the screen. There is deliberately **no** `custom:grid-layout`, no
  `custom:mod-card` height-cascade wrappers, and no fixed-pixel "fit
  2560x1440 without a scrollbar" sizing (that pixel-fit design was
  retired 2026-06-11 — abandoning the size-fit requirement was a
  deliberate call). Each cell is still a typed card (`button-card`,
  `mushroom-*`, `mini-media-player`, `clock-weather-card`, `thermostat`
  dial); state-driven colors live in per-card `state` blocks + theme
  tokens — no Jinja-templated HTML, no DOMPurify fight. Unavailable
  handling lives inside each card's state list.
- **Alarm color semantics (home hero):** green = disarmed, amber =
  arming/armed_home/armed_away, red = pending/triggered, with a pulse
  animation on triggered. State-driven via `button-card` `state` blocks.
- **Frontend HACS card loading.** In `configuration.yaml >
  frontend.extra_module_url`, only `kiosk-mode.js` and `card-mod.js` are
  explicitly loaded. Other HACS cards (mushroom, mini-media-player,
  layout-card, button-card, better-thermostat-ui-card, clock-weather-card)
  are auto-loaded by HACS — do NOT add them to `extra_module_url` or
  they'll double-register and throw "already been used with this registry"
  errors.

---

## GitOps Auto-Deploy

`shell_command.gitops_sync` invokes `scripts/gitops-sync.sh` every 5 minutes
via the `gitops_sync_poll` automation in `automations.yaml`. The script:

1. Acquires a lock file (prevents concurrent runs)
2. Verifies branch is `main` before touching anything
3. Fetches `origin/main`; exits 0 (silent) if already up to date
4. On divergence: resets working tree to `origin/main`
5. Calls `POST /core/check` via Supervisor API
6. On success: smart-routes to the lightest reload (lovelace → automation →
   script → scene → full restart based on changed paths), sends success
   notification
7. On failure: rolls back to pre-sync SHA, sends failure notification; HA
   Core is never restarted on a failed check

**Log:** `/config/gitops-sync.log` — timestamped, leveled; rotates at 1 MB.
Full pipeline details and failure-handling in `scripts/README.md`.

The complementary `ha-context-dump.sh` (driven by
`packages/ha_context_dump.yaml`) runs in the opposite direction — live HA →
`context/` snapshot → drift PR — see `scripts/README.md` and
*HA Runtime State Context* below.

## Home dashboard display & live-preview loop — RETIRED 2026-06-23

pve2's Chromium wall-display and everything that drove it were **torn down on
2026-06-23** when Chris abandoned the household wall monitor (see `~/CLAUDE.md`
→ *pve2 display host — RETIRED*). pve2 is now a headless quorum node — no
X/Chromium, no `snapshot-server` (`pve2.local:9999`), no `dashboard-home-gitops`
loop — and the `office-presence` repo that held the display plumbing
(`display-show`, `dashboard-home.{sh,service}`, the `surface` CLI) is archived.
There is no physical screen to render to anymore.

**What this means here:**

- **`dashboards/home.yaml` is unaffected.** The HA Lovelace home dashboard is
  still deployed to HAOS by the **HA-side** gitops loop
  (`scripts/gitops-sync.sh`) and still viewable in the HA web UI / companion
  app. It just no longer feeds a wall monitor.
- **`home-host/` (`home-preview`, `home-snapshot`) has been removed** (every
  path in it SSHed to pve2's X `:0` session — `xdotool` F5, `scrot` on
  `DISPLAY=:0`, fetch from `pve2.local:9999` — all gone).
- **To iterate the home dashboard now**, render the dashboard URL headlessly
  (Playwright/Chromium against `http://homeassistant.local:8123/…`) or just
  open it in the HA web UI — the old "capture the live frame the wall monitor
  is showing" rationale is moot without a monitor. *Interim guidance: confirm
  the preferred preview path with Chris before relying on it.*

The entity-validation habit the old loop enforced still stands: before adding a
card that references an entity, confirm it exists via
`mcp__Local-HA__ha_search_entities` (live) rather than trusting
`context/entities.json` (a grep snapshot, not a validator).

---

## PR Authoring Without Issues

PR workflow + auto-merge arming protocol is fleet-wide; see
`~/repos/CLAUDE.md`. Restated locally below so it survives that file being
out of context, followed by two repo-specific deviations.

### Always arm auto-merge

Arm **every** PR you open for auto-merge (squash) immediately after creating
it — `gh pr merge --auto --squash <pr>`, or the `enable_pr_auto_merge` MCP
tool with `mergeMethod: SQUASH`. If the PR's checks have already gone green by
then (arming returns "already clean"), merge it directly with squash instead —
same outcome. The required checks still gate the merge; auto-merge just lands
it the instant they pass, with no human round-trip. This is the
fleet-wide rule restated here precisely so it can't fall out of context.

### No issues for change dispatch — PRs are the canonical record

Changes to this repo are dispatched by talking to Claude Code directly. There
is no issue step *for change requests*. The PR itself is the canonical record
of intent. Required status checks are set by the `.github` meta-repo's
Terraform (`fleet-ops/required-checks.json`, enforced on the live `main`
ruleset): as of 2026-10-06, `check-config`, `docs-check / docs-check`, and
`shellcheck / shellcheck` (every tracked `*.sh`, severity style). The repo's
other CI (`YAML Lint`, `Bats`, `ESPHome Config`, and the rest) runs on every PR
as an advisory signal. The `claude-review` workflow was
retired fleet-wide on 2026-10-06; CodeRabbit is the org's advisory reviewer.
Check the live set with `gh api repos/lentago/epigaea/rules/branches/main`.

### Do file issues for incidentally-observed latent problems

The "no issues" rule above is about change *dispatch* — it does not mean
the repo doesn't use issues at all. **When Claude (or anyone) notices a
latent infrastructure problem during unrelated work — a silent failure,
a memory leak, a degrading component, a stale reference that's not in
scope of the current task — file a GitHub issue with the symptom,
relevant logs/measurements, and any candidate fixes.** Do not stop at a
verbal "heads-up" in the chat: those vanish, the issue persists. The
issue is the durable triage queue for follow-up work that doesn't yet
have a fix attached.

Use bug/dashboard/automation/etc. labels as appropriate. A future
session will pick up the issue, do the actual diagnosis, and open the
PR that closes it. Origin: home dashboard OOM observation 2026-05-31, issue #308.

### PR summary voice — fleet-wide

The fleet convention is a **neutral, objective, action-oriented PR summary**
that carries the who/what/why woven in — not a separate `## Origin` section,
and no `Prompt-Origin:` commit trailer. The canonical format and full guidance
live in `shared-workflows/CLAUDE.md` → "Fleet PR-workflow (canonical source)" —
follow it; this file no longer restates the details.

The one HA-specific emphasis worth keeping: because this repo dispatches
changes **without issues** (see above), the PR summary is the *only* durable
record of intent here — so the who/what/why carries more weight than in repos
where a linked issue also captures the ask. Don't skip it.

---

## HA Runtime Access (HA-MCP)

The "Live" layer of the *Three-Layer State Model*. The HA MCP server is
provided by the `homeassistant-ai/ha-mcp` HACS integration running inside
HA itself; the Claude client connects to it at
`http://homeassistant.local:9583/...`. Local sessions typically see tools
prefixed `mcp__Local-HA__*` (or whatever name the user gave the server in
their MCP client config); cloud sessions surface it under a UUID prefix
(`mcp__<uuid>__ha_*`). The tool *names* after the prefix are stable —
`ha_get_state`, `ha_search_entities`, `ha_call_service`, etc.

Unlike `context/` — which is a cached snapshot refreshed every 6 hours —
MCP queries hit the live HA process: state values are current to the second,
history is accurate, and service calls actually fire.

### Skill discipline (REQUIRED before HA config work)

The server bundles a skill named `home-assistant-best-practices`. **Before**
creating or editing any automation, script, scene, helper, or dashboard, call
`mcp__Local-HA__ha_get_skill_home_assistant_best_practices` to fetch the
reference-file index, then read the specific references that apply via
`mcp__Local-HA__ha_read_resource`. The skill enforces native conditions over
Jinja templates, `entity_id` over `device_id`, correct automation modes, and a
safe-refactoring workflow for renames. Skipping the skill is the single most
common cause of buggy or fragile HA config — do not skip it.

Reference file URIs:

| URI | Read when |
|-----|-----------|
| `skill://home-assistant-best-practices/SKILL.md` | Always — decision workflow + anti-pattern table |
| `skill://home-assistant-best-practices/references/automation-patterns.md` | Writing triggers, conditions, modes, `wait_for_trigger` |
| `skill://home-assistant-best-practices/references/helper-selection.md` | Choosing between a built-in helper and a template sensor |
| `skill://home-assistant-best-practices/references/template-guidelines.md` | Confirming a template IS appropriate; template sensor best practices |
| `skill://home-assistant-best-practices/references/device-control.md` | Service calls, Zigbee button/remote automations, ZHA vs Z2M |
| `skill://home-assistant-best-practices/references/safe-refactoring.md` | Renaming entities, replacing helpers, restructuring automations |
| `skill://home-assistant-best-practices/references/dashboard-guide.md` | Designing/modifying Lovelace dashboards |
| `skill://home-assistant-best-practices/references/dashboard-cards.md` | Looking up specific card types |
| `skill://home-assistant-best-practices/references/domain-docs.md` | Integration/domain reference for service calls and attributes |
| `skill://home-assistant-best-practices/references/examples.yaml` | Compound examples that combine multiple practices |

### Tool selection: MCP vs `context/`

| Need | Prefer |
|------|--------|
| Bulk grep over entities/devices/areas (no real-time accuracy needed) | `context/*.json` via `jq` |
| Current state of a specific entity (e.g. "is the basement door open *right now*?") | `ha_get_state` |
| Entity lookup with fuzzy or area filtering | `ha_search_entities` (more current than `context/entities.json`) |
| Search inside automation/script/scene/helper/dashboard configs by *behavior* | `ha_deep_search` (pass `search_types: ['dashboard']` to include cards) |
| Time-series ("what time did motion fire last night?") | `ha_get_history` |
| Long-term aggregates ("avg basement humidity for the month") | `ha_get_history(source="statistics")` |
| Test a Jinja template before committing it to YAML | `ha_eval_template` |
| System/integration/add-on logs for debugging | `ha_get_logs` (sources: `logbook`, `system`, `error_log`, `supervisor`, `system_service`, `logger`) |
| Trigger a service to verify behavior end-to-end | `ha_call_service` |
| Big-picture system overview | `ha_get_overview` (start with `detail_level="minimal"`) |
| Validate the currently deployed config | `ha_check_config` (validates LIVE config, not your working tree — see below) |

Rule of thumb: **use `context/` for exploration that doesn't need live
accuracy** (faster, free, grep-friendly); **use MCP when staleness would mislead
you** or when you need history, logs, templates, or service calls. If `context/`
and MCP disagree, MCP wins — the snapshot is stale.

### Validation workflow

`ha_check_config` validates the **live deployed config**, not your local
working tree. HA reads from `/config/` on the HAOS VM; your edits in your
local checkout (or the cloud-session worktree) are invisible to it until
gitops-sync deploys them. Therefore:

- **Before writing YAML:** use `ha_eval_template` to verify Jinja,
  `ha_search_entities` / `ha_get_state` to confirm entity IDs exist, and
  `ha_call_service` to confirm services exist and behave as expected.
- **PR validation:** trust the `ha-config-check.yml` workflow — it spins up a
  clean HA instance against the proposed YAML and runs `check_config` there.
  That is what gates the merge.
- **Post-deploy sanity check (within 5 minutes of merge):** run
  `ha_check_config` to confirm the live system is healthy, and
  `ha_get_logs(source="system", level="ERROR", hours_back=1)` to scan for
  anything new the validator didn't catch (runtime errors only show up at load
  time).

### Drift guardrail: `.storage/` writes vs git source-of-truth

The `ha_config_set_*` tools (`ha_config_set_automation`,
`ha_config_set_script`, `ha_config_set_scene`, `ha_config_set_helper`,
`ha_config_set_dashboard`) write to HA's `.storage/` directory, which is
gitignored. Anything you create this way will:

1. **Not appear in git** — it's runtime state, not config-as-code
2. **Be captured in the next `context/` snapshot** — visible in
   `context/scripts.json`, `context/scenes.json`, `context/helpers.json`, or
   `context/dashboards-storage.json` within 6 hours
3. **Drift** from the git source-of-truth if a corresponding file exists

Repo conventions for where each kind of object lives:

- **Automations** → `/config/automations/*.yaml` (git, merge-list) or
  `/config/automations.yaml` (UI-editable, reconciled to git manually). **Do
  not** use `ha_config_set_automation` for anything that should survive a
  rebuild. Prototype, then write the YAML and PR it.
- **Scripts** → `/config/scripts.yaml` (placeholder today). If
  `ha_config_set_script` writes to `.storage/`, the snapshot pipeline surfaces
  it in `context/scripts.json` — codify into `scripts.yaml` via PR before
  relying on it long-term.
- **Scenes** → `/config/scenes.yaml`, same pattern as scripts.
- **Helpers** → `.storage/` is the normal home (no YAML helpers exist in this
  repo). Using `ha_config_set_helper` is aligned with existing pattern; the
  snapshot captures helpers in `context/helpers.json`.
- **Dashboards** → `/config/dashboards/*.yaml` (git). The four YAML
  dashboards this repo ships are NOT captured in
  `context/dashboards-storage.json` — git is their source of truth.
  `ha_config_set_dashboard` would create a storage-mode dashboard, which is
  fine for experimentation but should be migrated to YAML for anything the
  household relies on.

When in doubt: **if a feature should survive a rebuild, it goes in git. If it's
prototyping or genuinely user-managed (like a one-off helper), `.storage/` is
fine.** Either way, follow up by re-reading the relevant `context/` snapshot to
confirm the change landed where you expected.

### Destructive actions — always confirm first

These tools change state visibly or are hard to reverse — get user confirmation
before invoking, even if the user authorized similar actions earlier in the
conversation:

- `ha_restart`, `ha_reload_core` — restarts HA Core (briefly disrupts everything)
- `ha_remove_entity`, `ha_remove_device`, `ha_remove_area_or_floor`,
  `ha_remove_zone`, `ha_delete_helpers_integrations`
- `ha_config_remove_*` and `ha_config_delete_*` (automation/script/scene/helper/
  dashboard/category/label/group)
- `ha_backup_restore` — restores from a backup, overwriting current state
- `ha_hacs_download`, `ha_manage_addon` — installs/updates/removes packages
- `ha_set_integration_enabled` with `enabled=false`

The gitops-sync loop picks up YAML changes and reloads HA automatically; a
manual `ha_restart` should not be the default reaction to "I want to see my
change live" — wait for the auto-reload, or call the relevant
`automation.reload` / `script.reload` / `lovelace.reload_resources` service via
`ha_call_service` if you're impatient.

---

## HA Runtime State Context (`context/`)

The "Snapshot" layer of the *Three-Layer State Model*. `context/` is an
auto-generated, **read-only** snapshot of HA runtime state — entity, area,
and device registries, the UI-editable `automations.yaml`, plus storage-mode
scripts, scenes, helpers, and dashboards. It's populated by
`scripts/ha-context-dump.sh` (driven by `packages/ha_context_dump.yaml`) and
refreshed every 6 hours, plus on demand via
`input_button.ha_context_dump_now`. See `context/README.md` for the per-file
schema.

**The full pipeline:** the dump script pushes a `context-sync/<timestamp>`
branch when content changes, then fires a `ha-context-report` repository
dispatch. The `ha-context-sync.yml` workflow opens a PR from that branch with
the `context-snapshot` label and arms auto-merge. Both the dump script and the
workflow use `HA_SYNC_PAT` — same reasoning as `ha-version-sync.yml`
(GITHUB_TOKEN-opened PRs don't fire downstream workflows; see
`packages/README.md`).

**Hook guard against accidental writes:** `.claude/hooks/block-context-writes.sh`
runs as a `PreToolUse` hook on Edit/Write/Bash and rejects anything that would
mutate `context/`. The snapshot is the runtime's output, not Claude's; if a
fact in `context/` is wrong, fix the source in HA (via MCP) and let the next
dump propagate it.

### Working with `context/` efficiently

The files can be large — `entities.json` is typically 200KB+. Prefer targeted
`jq` queries over a full `Read`:

```bash
# Specific entity
jq '.[] | select(.entity_id == "light.meeting_light")' context/entities.json

# All entities in an area
jq '.[] | select(.area_id == "office")' context/entities.json

# Entities in a domain
jq '.[] | select(.entity_id | startswith("light.")) | .entity_id' context/entities.json

# Devices by manufacturer / model
jq '.[] | select(.manufacturer == "Konnected")' context/devices.json
jq '.[] | select(.model | test("ratgdo"))' context/devices.json

# Devices missing area assignment (dashboard-gap source)
jq '.[] | select(.area_id == null) | {name, manufacturer, model}' context/devices.json

# Helpers of a domain (before proposing a new one)
jq '.input_boolean[] | .id' context/helpers.json
jq '[.[][] | .id] | index("guest_mode")' context/helpers.json

# Storage-mode script / scene by alias
jq '.[] | select(.alias == "Morning routine")' context/scripts.json
jq '.[] | select(.name == "Movie night")' context/scenes.json
```

`context/areas.json`, `context/automations-ui.yaml`, `context/scripts.json`,
`context/scenes.json`, `context/helpers.json`, and (typically)
`context/dashboards-storage.json` are small enough that reading them in full is
fine when needed.

### Handling stale or missing context

Snapshots refresh every 6 hours and on manual button press. If config you
propose based on `context/` produces "entity not found" errors, the snapshot
may be stale relative to recent HA UI changes. Recommend the user press
`input_button.ha_context_dump_now` and re-run.

If an entity_id genuinely doesn't appear in `context/entities.json` (not
stale, just absent), it likely doesn't exist yet — propose creating the
corresponding device/integration first, or ask the user to confirm the entity
name.

### When NOT to consult `context/`

Skip the lookup for:

- Pure shell/Python/Terraform/Docker work unrelated to HA entity references
- Documentation, README, or comment-only edits
- Workflow file changes (the token scope blocks you from writing those anyway)
- General HA architecture or troubleshooting discussions
- Issues that explicitly provide entity_ids in the request — those are the
  source of truth, not the snapshot
