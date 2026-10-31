# automations/

Git-managed automations. This directory is the pipeline's exclusive domain — the HA UI editor never writes here. HA merges all `.yaml` files in this directory at startup via `!include_dir_merge_list automations/` in `configuration.yaml`.

## Governance model

Automations in this project are split by authority:

| Location | Authority | Edit surface |
|----------|-----------|-------------|
| `automations.yaml` | HA UI editor | Settings → Automations (UI drift is expected and reconciled manually) |
| `automations/` | Git / PR | This directory only — never touched via the HA UI |

This partition prevents the GitOps pipeline from silently clobbering UI edits. The `git reset --hard origin/main` in the deploy script would overwrite any UI change to a git-tracked file. The separation makes the authority explicit.

## Files

### `sonoff_button_kitchen_family.yaml` — Sonoff Button 1

Three automations: single press → Downstairs + Hallways on; double press → off; long press → all lights to 25%. The printed card posted by the button is [`cards/downstairs-lights-button.html`](../cards/downstairs-lights-button.html), published with `scripts/publish-card.sh downstairs-lights-button`; it changes in the same PR as the presses ([`cards/README.md`](../cards/README.md)).

The **meeting indicator** used to live here as `meeting.yaml`. It moved to `packages/meeting_indicator.yaml` once it grew helper scripts and cross-cutting logic with the office scene controller — packages are the home for automations bundled with scripts or helpers.

## Adding automations

Create a new `.yaml` file in this directory. HA will pick it up on the next restart or reload. No changes to `configuration.yaml` are needed.

Name files by functional domain (e.g., `lighting.yaml`, `climate.yaml`) rather than creating one file per automation.
