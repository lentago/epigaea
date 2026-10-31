# scripts/

Shell scripts executed by Home Assistant's `shell_command` integration.

## `gitops-sync.sh`

GitOps auto-deploy script. Called every 5 minutes by the `gitops_sync_poll` automation via `shell_command.gitops_sync`. Requires the `SUPERVISOR_TOKEN` environment variable (injected automatically by the HA shell_command integration).

### What it does

1. **Lock acquisition** — creates `.gitops-sync.lock` to prevent concurrent runs from overlapping polls
2. **Branch guard** — verifies the working tree is on `main` before touching anything; aborts if not
3. **Fetch** — runs `git fetch origin main`
4. **Drift check** — compares `HEAD` to `origin/main`; exits silently if already up to date (no-op polls produce no log entries)
5. **Reset** — `git reset --hard origin/main` applies the new commits
6. **Validate** — `POST /core/check` via Supervisor API; evaluates the HTTP response code
7. **On success** — routes to the lightest applicable reload:
   - Dashboard YAML changes only → `lovelace.reload_resources` + `frontend.reload_themes`
   - Automation changes → `automation.reload`
   - Script changes → `script.reload`
   - Scene changes → `scene.reload`
   - Any other config change → `core.restart`
   - Sends a success notification via the HA notify service
8. **On failure** — rolls back to the pre-sync SHA (`git reset --hard <pre-sync-sha>`), sends a failure notification; HA Core is never restarted on a failed check

### Operational details

- **Upper-bound deploy time:** 5 minutes from merge to running config
- **Log:** `/config/gitops-sync.log` — timestamped, leveled entries; rotates at 1 MB to `gitops-sync.log.1`
- **Disable:** toggle the `GitOps: Poll and deploy` automation off in Developer Tools
- **Force sync:** call `shell_command.gitops_sync` from Developer Tools → Services

### Why this approach

Polling from inside HA (rather than pushing from a GitHub Actions webhook) avoids exposing the HA instance to inbound internet traffic and sidesteps NAT traversal entirely. The tradeoff is a maximum 5-minute latency on deploys — acceptable for a home automation context. The Supervisor API validation step (`/core/check`) runs the same config validator as a normal HA startup, so a bad merge is caught before the service is disrupted.

## `sync-home-codesign.sh`

Regenerates `dashboards/home-codesign.yaml` as a one-way mirror of
`dashboards/home.yaml`. The co-design dashboard
(`/dashboard-home-codesign/home`) is a preview twin of the production home
dashboard used for live design iteration; making production the single source
of truth stops it drifting behind (fixes used to land in `home.yaml` and never
get back-ported). The dashboard-family scheme it serves is documented in
[`dashboards/README.md`](../dashboards/README.md#the-home-dashboard-family--one-master-two-clones).

The script copies `home.yaml` verbatim and prepends a `DO NOT EDIT BY HAND`
banner, swapping only three cosmetic lines on the first view: tab title
`Home`→`Co-design`, icon `mdi:monitor-dashboard`→`mdi:monitor-edit`, and theme
`Home Polish`→`Home Codesign` (so the sandbox renders the
`themes/home_codesign.yaml` instrument-panel study without forking any cards).
Every card, template, and entity reference stays identical to production.

```bash
scripts/sync-home-codesign.sh           # regenerate in place (default)
scripts/sync-home-codesign.sh --check   # exit non-zero if drifted; no writes (CI)
scripts/sync-home-codesign.sh --help
```

Pure shell (`sed` + `diff`) — runs anywhere the repo is checked out, no HA
access needed. `--check` is wired into CI as `Tests › Codesign Sync`, so a
`home.yaml` change that skips the regen fails the build. `HOME_SRC` / `HOME_DST`
override the paths for testing. **Workflow:** edit `home.yaml`, run the script,
commit both files in the same PR.

## `import-dashboard-to-storage.sh`

Ad-hoc helper that copies a git-managed YAML dashboard into a storage-mode
(UI-managed) Lovelace dashboard, so you can hand-tweak it in the HA UI while
still starting from the repo's "official" dashboard paradigm. After it runs,
the next `ha-context-dump.sh` snapshot picks the dashboard up in
`context/dashboards-storage.json`, which makes it visible to assistants
working against `context/`.

The import is a structurally lossless round-trip — `yaml.safe_load` →
`lovelace/config/save` persists the exact parsed config — so the UI copy
matches the source view-for-view. (Only holds for self-contained dashboards;
HA custom tags like `!include`/`!secret` would break `safe_load`.)

Must run inside the HA Core container (Python 3, `aiohttp`, and `PyYAML` are
part of Core's runtime; the SSH add-on's Alpine shell has none of them):

```bash
# default: seed dashboards/home.yaml -> "Home (UI Edit)" at /home-ui-edit
docker exec homeassistant /config/scripts/import-dashboard-to-storage.sh

# any dashboard, by name (resolved to /config/dashboards/<name>.yaml)
docker exec homeassistant /config/scripts/import-dashboard-to-storage.sh kiosk

# full control over the storage dashboard's url_path / title / icon
docker exec homeassistant /config/scripts/import-dashboard-to-storage.sh \
    home home-ui-edit "Home (UI Edit)" mdi:home-edit
```

From the workstation in one shot (the HAOS host has `docker`, the SSH add-on
does not — note port 22 + `docker exec`, not `ha`):

```bash
ssh -p 22 root@homeassistant.local \
  "docker exec homeassistant /config/scripts/import-dashboard-to-storage.sh <name>"
```

### Positional arguments

Each falls back to its env var, then to a value derived from the source name:

| # | Arg | Env | Default |
|---|-----|-----|---------|
| 1 | `<source>` | `SOURCE_YAML` | `home` — a bare **name** resolves to `/config/dashboards/<name>.yaml`; an explicit path passes through |
| 2 | `<url_path>` | `URL_PATH` | `<name>-ui-edit` |
| 3 | `<title>` | `TITLE` | `"<Name> (UI Edit)"` |
| 4 | `<icon>` | `ICON` | `mdi:view-dashboard-edit` |

### Authentication

Core's websocket auth does NOT accept `SUPERVISOR_TOKEN` in current HA
versions (that token is for outbound Core-to-Supervisor calls, not inbound
Core API). A long-lived access token is required:

1. In the HA UI: profile avatar (bottom-left) → **Security** tab →
   **Long-Lived Access Tokens** → **Create Token** → copy the value (shown
   only once).
2. Add it to `/config/secrets.yaml` so future runs need no env flag:
   ```yaml
   ha_token: "Bearer <paste-the-token-here>"
   ```
   The `Bearer ` prefix matches the project convention for stored
   Authorization header values (see *Script auth conventions* below).
   The script strips the prefix before sending to the websocket.

The script resolves the token in this order: `HA_TOKEN` env var → `ha_token`
in `secrets.yaml` → `SUPERVISOR_TOKEN` (last-resort fallback that will
almost certainly fail). For a one-shot run without modifying `secrets.yaml`:

```bash
docker exec -e HA_TOKEN='<paste-token-here>' homeassistant /config/scripts/import-dashboard-to-storage.sh
```

### Overrides and behavior

Beyond the positional args above, `HA_WS_URL` and `SECRETS_YAML` are
env-overridable. **Idempotent** — re-running overwrites the saved config but
does not duplicate the registry entry; this is a **reseed-from-source**
operation, so any hand-edits made in the UI copy are clobbered on the next
import. That's the intended flow: edit the official YAML, reseed, hand-tweak;
or hand-tweak, then port the changes back into the YAML as the durable
source-of-truth.

The git-managed source dashboard and its `lovelace.dashboards` registration
in `configuration.yaml` are left in place — the YAML and storage copies
coexist (e.g. `/dashboard-home/home` from YAML, `/home-ui-edit` from
storage). The storage copy is gitignored `.storage/` runtime state and will
**drift** from the YAML once you edit it; git remains the source of truth.

## `validate-ha-version.sh` / `validate-context-branch.sh`

Tiny input validators used by the sync workflows, factored out of inline
workflow YAML so the regexes have a single source of truth that CI can test.

- `validate-ha-version.sh <version>` — accepts a stable (`YYYY.MM.N`) or beta
  (`YYYY.MM.NbN`) HA version, rejects everything else; echoes the validated
  version on success. Called by `ha-version-sync.yml` before it commits
  `.ha-version`.
- `validate-context-branch.sh <branch>` — accepts only
  `context-sync/YYYYMMDD-HHMMSS`. The branch is an externally-supplied
  `repository_dispatch` payload that `ha-context-sync.yml` turns into a PR, so
  this is a trust boundary. Echoes the branch on success.

Both expose a sourceable function (`validate_ha_version` /
`validate_context_branch`) guarded by `BASH_SOURCE == $0`, exercised by
`tests/validate_inputs.bats`. Because the workflows now call these scripts, they
checkout the repo *before* validating the payload (an early checkout for an
invalid payload is the only behavioral change; the payload isn't used in
checkout, so there's no security impact).

## `force-sync.sh`

Collapses the cross-layer latency windows on demand: fires an immediate
`shell_command.gitops_sync` (deploy now, rather than waiting for the 5-minute
poll) and presses `input_button.ha_context_dump_now` (snapshot now, rather than
the 6-hour dump). Use it after a coordinated LIVE + INTENT change so the layers
reconcile in seconds — see `docs/cross-layer-changes.md` (rename recipe,
steps 3–4). Runs inside the HA Core container; uses `SUPERVISOR_TOKEN` like
`gitops-sync.sh`.

## `publish-card.sh`

Copies an instruction card from `cards/<slug>.html` to the LAN web drop as
`<web-root>/cards/<slug>/index.html`, so Caddy on `pub.lan` serves it at
`http://pub.lan/cards/<slug>/` with no deploy step. Write-then-rename, so a
reader never sees a half-copied page. Refuses a slug that is not
lowercase-hyphenated, a card that does not exist, a web root that does not
exist, and a web root that is not on a network filesystem (`smb2`, `cifs`,
`nfs`), which is what an unmounted NAS looks like from the workstation;
`CARDS_ALLOW_LOCAL=1` publishes to a local directory on purpose (the tests use
it). The web root is the second argument or `CARDS_WEB_ROOT`,
defaulting to `/mnt/lentago/web` (the NAS share as the workstation mounts it;
fleet hosts see it at `/mnt/neptune-lentago/web`). Runs on the workstation, not
on HAOS. Card contract and index: `cards/README.md`.

## `check-card-size.sh`

Checks that each instruction card fits the 7 by 5 inch card contract. It opens
`cards/<slug>.html` in headless Chrome, waits for the Google Fonts, and reads
the height of the `.card` element. That height is the printed height, because
the card is 7 inches wide on screen and on paper and the print stylesheet's
`min-height: 5in` only pads a short card. It prints `<slug>: <height>in, fits`
or `too tall` per card and exits 1 if any card is over `CARD_MAX_IN` (default
5.0). No arguments checks every card; slugs check just those. Exit 3 means it
could not measure: no Chrome or Chromium on `PATH` (`CHROME` names the binary),
or the web fonts did not load, which would change the line breaks. The `Bats`
suite runs it in CI (`tests/card_size.bats`). Added for #560.

## Script auth conventions

Three conventions learned the hard way during context-sync work. Future scripts
that talk to GitHub or the HA Supervisor from inside the HA Core container
should follow these without re-deriving them.

### `secrets.yaml` stores complete Authorization header values

The `github_pat` secret in `/config/secrets.yaml` is stored as the **full
Authorization header value**, including the auth scheme prefix:

    github_pat: "Bearer github_pat_xxxxxxxxxx..."

This is the HA `rest_command` integration convention — it allows direct use as
`headers: { authorization: !secret github_pat }` in rest_command definitions
(see `packages/ha_version_sync.yaml` for the canonical example).

Bash scripts consuming this secret should extract the quoted value cleanly:

    GITHUB_AUTH=$(awk -F'"' '/^github_pat:/ {print $2}' /config/secrets.yaml)

The naive `awk '{print $2}'` (whitespace-split, no quote awareness) returns
`"Bearer` — the opening quote plus the scheme word. It's non-empty (passes
naive checks) but unusable. Always use `-F'"'`.

When a bare token is needed (e.g., for git URL-embedded auth), strip the prefix:

    GITHUB_TOKEN="${GITHUB_AUTH#Bearer }"

### Git HTTPS push needs URL-embedded credentials, not extraheader

For `git push` over HTTPS from inside the Core container, use URL-embedded auth:

    git -C "$WORKTREE" push \
        "https://x-access-token:${GITHUB_TOKEN}@github.com/${OWNER}/${REPO}.git" \
        "$branch"

**Do not use** the `git -c http.extraheader=...` or
`git -c http.<url>.extraheader=...` patterns for push. They work for fetch and
`ls-remote` but git 2.52 drops the extraheader on the auth challenge during the
receive-pack handshake, falling back to credential helper or interactive prompt
— which has no terminal in shell_command context, so it hangs.

The URL-embedded form is what GitHub Actions uses internally for its own git
operations. It puts the bare token briefly in `ps` output, but on a single-user
HAOS VM this is acceptable. The push is one-shot — the URL is constructed inline,
not persisted to git config; `git remote -v` continues to show only the bare
HTTPS origin URL afterward.

### GitHub REST API uses Bearer auth (the stored format works as-is)

For curl calls to `api.github.com` endpoints (firing `repository_dispatch`,
checking PR state, etc.), use the full stored value directly as the
Authorization header:

    curl -H "Authorization: ${GITHUB_AUTH}" \
        https://api.github.com/repos/${OWNER}/${REPO}/dispatches \
        ...

No prefix manipulation — the `Bearer ` is already in the value. Adding
`token ` or `Bearer ` prefixes in the script produces malformed headers.

### Public-repo `ls-remote` is not a valid auth test

`git ls-remote https://github.com/<owner>/<public-repo>.git HEAD` succeeds
anonymously — GitHub serves refs for public repos without authentication. If
you're testing whether a PAT works for git operations, the only valid test is
an authenticated operation that the public-anonymous path can't satisfy:

- A push (`git push ...`)
- A REST API call requiring auth (e.g., `GET /user`, `GET /repos/.../dispatches`
  with a body)
- A clone of a private repo

Don't conclude auth works just because `ls-remote` returns a SHA.
