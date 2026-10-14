# Security

This repo runs a real building's hardware (a physical alarm
panel, door locks via automations, a Sonos/Hue smart home), non-critical
stakes. This document exists so the one write credential in the loop is
handled deliberately, not because the repo faces a formal threat model.

## `HA_SYNC_PAT` — the one write credential in the GitOps loop

Everything else in the [GitOps loop](README.md#-the-gitops-loop) is
read-only from GitHub's side (`gitops-sync.sh` only ever `git fetch`es) or
scoped to a token that never leaves the HAOS VM (`SUPERVISOR_TOKEN`, used
locally by `gitops-sync.sh` to call the Supervisor API — never stored in
GitHub). `HA_SYNC_PAT` is the exception: it is a single fine-grained PAT that
exists in **two places** as the same value, and is the only credential that
lets something outside a human's PR review push code into this repo.

### What it's for

Used by three workflows that all need to open or push a PR that GitHub's
default `GITHUB_TOKEN` cannot (see [README → Why `HA_SYNC_PAT` instead of
`GITHUB_TOKEN`](README.md#why-ha_sync_pat-instead-of-github_token) for the
mechanics):

| Consumer | What it does with the PAT |
|---|---|
| `packages/ha_version_sync.yaml` (`rest_command.github_dispatch_version`, runs **on the HAOS VM**) | Uses the PAT (stored there as `github_pat`) to POST a `ha-version-report` `repository_dispatch` event on every `homeassistant_started` |
| [`ha-version-sync.yml`](.github/workflows/ha-version-sync.yml) | `actions/checkout` (push a `ha-version-bump/<version>` branch) + `gh pr create` + `gh pr merge --auto` |
| [`ha-context-sync.yml`](.github/workflows/ha-context-sync.yml) | `actions/checkout`, `gh label create`, `gh pr create` + `gh pr merge --auto` for the `context-sync/*` snapshot branches the VM pushes directly |

### Minimum scope

A **fine-grained** PAT, scoped to this repository only (`lentago/epigaea`) —
never classic, never org-wide:

- **Contents: Read and write** — push the `ha-version-bump/*` and
  `context-sync/*` branches
- **Pull requests: Read and write** — `gh pr create` / `gh pr merge --auto`
- **Issues: Write** — `gh label create` in `ha-context-sync.yml` needs this;
  GitHub's fine-grained permission model puts label management under the
  Issues permission even though these are PR labels

No admin, workflow, secrets, or Actions scopes — the PAT never needs to touch
`.github/workflows/*.yml` itself or repo settings.

### Where it's stored

- **HAOS VM:** `/homeassistant/secrets.yaml` (gitignored, never committed —
  see `secrets.yaml.example` for the documented key), as `github_pat`
- **GitHub:** Settings → Secrets and variables → Actions → `HA_SYNC_PAT`
  (repo-level Actions secret)

Both are the *same token value*. There is no cryptographic separation
between "the copy the VM uses to dispatch" and "the copy GitHub Actions uses
to push" — treat a leak of either location as a leak of the whole thing.

### Blast radius if leaked

- **Repo-scoped, so it cannot reach other `lentago/*` repos** — that's the
  entire point of using a fine-grained, repo-scoped PAT over a classic
  `repo`-scope one.
- **Within this repo, it is push + PR access.** An attacker holding it can
  push a branch and open a PR carrying arbitrary YAML — including automation
  logic that unlocks doors, disarms the alarm, or opens a garage — then arm
  auto-merge on it, same as the legitimate workflows do.
- **The merge gate here is automated status checks, not mandatory human
  review** (see [ADR-0001](docs/adr/0001-pr-canonical-record-no-issue-dispatch.md)
  and the repo's branch Ruleset) — that's a deliberate repo-wide convention
  for *legitimate* dispatch, but it means a schema-valid, maliciously-crafted
  PR (`ha-config-check` validates structure, not intent) would pass CI and
  auto-deploy to the HAOS VM within 5 minutes of merge via
  `scripts/gitops-sync.sh`, with no human in the loop to catch it first.
- **It does not grant HA API/Supervisor access.** `SUPERVISOR_TOKEN` is a
  separate credential, generated locally by HA Core, injected only into the
  `shell_command` environment on the VM, and never stored in GitHub or this
  repo. A leaked `HA_SYNC_PAT` cannot call HA services directly — it has to
  go through a merged PR and wait for the next `gitops-sync.sh` poll.

### Rotation

Rotate `HA_SYNC_PAT` **annually**, or immediately on suspected exposure
(e.g. it turns up in a log, a screen share, or a VM/backup that leaves
Chris's control).

1. **Generate the replacement first, before revoking the old one** — GitHub
   → Settings → Developer settings → Fine-grained tokens → generate a new
   token scoped to `lentago/epigaea` only, with the three permissions listed
   above.
2. **Update the GitHub Actions secret:** repo → Settings → Secrets and
   variables → Actions → `HA_SYNC_PAT` → update value.
3. **Update the HAOS copy:** edit `/homeassistant/secrets.yaml` on the VM
   (via the SSH add-on or File Editor), replace the `github_pat` value.
   `!secret` values are resolved at config load, so this needs
   `ha_call_service homeassistant reload_config_entries` or, if that doesn't
   pick it up, a Core restart before `rest_command.github_dispatch_version`
   will use the new value.
4. **Verify the loop end-to-end** before revoking the old token: manually
   call `rest_command.github_dispatch_version` from Developer Tools →
   Services (or trigger `input_button.ha_context_dump_now` for the context
   loop) and confirm the corresponding workflow run authenticates and, if
   there's drift, opens a PR.
5. **Revoke the old token** — GitHub → Settings → Developer settings →
   Fine-grained tokens → the old token → Delete.

### Reporting a problem

This is a single-operator repo with no external users or SLA. If you spot a
credential accidentally committed, or a way the GitOps loop's automated
merge could be abused, open a GitHub issue (this is the "incidentally
observed latent problem" carve-out in
[ADR-0001](docs/adr/0001-pr-canonical-record-no-issue-dispatch.md) — it
applies even though this repo skips issues for normal change dispatch) or
contact [cpitzi](https://github.com/cpitzi) directly.
