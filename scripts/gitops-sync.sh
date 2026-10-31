#!/usr/bin/env bash
set -euo pipefail

readonly LOCK_FILE="/config/.gitops-sync.lock"
readonly LOG_FILE="/config/gitops-sync.log"
readonly LOG_MAX_BYTES=1048576
readonly SUPERVISOR_BASE="http://supervisor"
readonly NOTIFY_TARGET="mobile_app_sm_s926u1"

log() {
  local level="$1"
  shift
  local ts line
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  line="[$ts] [$level] $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$LOG_FILE"
}

rotate_log() {
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -c%s "$LOG_FILE")
    if (( size >= LOG_MAX_BYTES )); then
      mv "$LOG_FILE" "${LOG_FILE}.1"
    fi
  fi
}

ha_notify() {
  local body
  body=$(jq -n --arg msg "$1" '{"message": $msg}')
  curl -s -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "${SUPERVISOR_BASE}/core/api/services/notify/${NOTIFY_TARGET}" \
    > /dev/null || true
}

ha_call_service() {
  local domain="$1" service="$2"
  curl -s -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{}' \
    "${SUPERVISOR_BASE}/core/api/services/${domain}/${service}" \
    > /dev/null || true
}

ha_core_restart() {
  curl -s -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" \
    "${SUPERVISOR_BASE}/core/restart" \
    > /dev/null || true
}

# Inspect changed files and call the lightest reload path safe for that change set.
# Falls back to full core restart if diff is unavailable or any file falls outside
# the lightweight set (dashboards, automations, scripts, scenes).
apply_reload() {
  local old_sha="$1" new_sha="$2"

  if [[ -z "$old_sha" ]]; then
    log INFO "Routing: OLD_SHA unavailable → full restart (safe fallback)"
    ha_core_restart
    return
  fi

  local changed_files
  changed_files=$(git diff --name-only "${old_sha}..${new_sha}") || true

  if [[ -z "$changed_files" ]]; then
    log INFO "Routing: empty diff → full restart (safe fallback)"
    ha_core_restart
    return
  fi

  local needs_restart=false
  local reload_dashboard=false
  local reload_themes=false
  local reload_automations=false
  local reload_scripts=false
  local reload_scenes=false

  while IFS= read -r f; do
    if [[ -z "$f" ]]; then
      continue
    fi
    # No-op: files that don't affect HA Core runtime. cards/ is printed signage,
    # tests/ and assets/ are CI and README material, .claude/ is agent tooling,
    # and .ha-version plus the two secrets templates are read only by CI.
    if   [[ "$f" =~ ^context/ ]] || \
         [[ "$f" =~ ^\.github/ ]] || \
         [[ "$f" =~ ^esphome/ ]] || \
         [[ "$f" =~ ^scripts/.*\.sh$ ]] || \
         [[ "$f" =~ ^cards/ ]] || \
         [[ "$f" =~ ^tests/ ]] || \
         [[ "$f" =~ ^assets/ ]] || \
         [[ "$f" =~ ^\.claude/ ]] || \
         [[ "$f" =~ \.md$ ]] || \
         [[ "$f" == ".gitignore" || "$f" == ".yamllint.yml" || \
            "$f" == "LICENSE"    || "$f" == ".gitattributes" || \
            "$f" == ".ha-version" || "$f" == "secrets.fake.yaml" || \
            "$f" == "secrets.yaml.example" ]]; then
      continue
    elif [[ "$f" =~ ^dashboards/.*\.yaml$ ]]; then
      reload_dashboard=true
    elif [[ "$f" =~ ^themes/ ]]; then
      reload_themes=true
    elif [[ "$f" == "automations.yaml" || "$f" =~ ^automations/.*\.yaml$ ]]; then
      reload_automations=true
    elif [[ "$f" == "scripts.yaml"     || "$f" =~ ^scripts/.*\.yaml$ ]]; then
      reload_scripts=true
    elif [[ "$f" == "scenes.yaml"      || "$f" =~ ^scenes/.*\.yaml$ ]]; then
      reload_scenes=true
    else
      log INFO "Routing: ${f} outside lightweight set → full restart"
      needs_restart=true
    fi
  done <<< "$changed_files"

  if [[ "$needs_restart" == true ]]; then
    log INFO "Routing: changes outside lightweight set → full restart"
    ha_core_restart
    return
  fi

  if [[ "$reload_dashboard" == false && "$reload_themes" == false && \
        "$reload_automations" == false && "$reload_scripts" == false && \
        "$reload_scenes" == false ]]; then
    log INFO "Routing: all changes outside HA runtime scope → no reload needed"
    return
  fi

  if [[ "$reload_dashboard" == true ]]; then
    log INFO "Routing: dashboards → lovelace.reload_resources + frontend.reload_themes"
    ha_call_service lovelace reload_resources
    ha_call_service frontend reload_themes
  fi
  if [[ "$reload_themes" == true ]]; then
    log INFO "Routing: themes → frontend.reload_themes"
    ha_call_service frontend reload_themes
  fi
  if [[ "$reload_automations" == true ]]; then
    log INFO "Routing: automations.yaml → automation.reload"
    ha_call_service automation reload
  fi
  if [[ "$reload_scripts" == true ]]; then
    log INFO "Routing: scripts.yaml → script.reload"
    ha_call_service script reload
  fi
  if [[ "$reload_scenes" == true ]]; then
    log INFO "Routing: scenes.yaml → scene.reload"
    ha_call_service scene reload
  fi
}

main() {
  rotate_log

  if [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
    log ERROR "SUPERVISOR_TOKEN is not set. HA must expose it to shell_command context."
    log ERROR "See: https://www.home-assistant.io/integrations/shell_command/"
    exit 1
  fi

  cd /config

  local current_branch
  current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
  if [[ "$current_branch" != "main" ]]; then
    log ERROR "Expected branch 'main', got '${current_branch}'. Aborting to avoid deploying wrong branch."
    exit 1
  fi

  local rollback_sha
  rollback_sha=$(git rev-parse HEAD)

  if ! git fetch --quiet origin; then
    log ERROR "git fetch failed — check network or SSH access"
    ha_notify "⚠️ GitOps fetch failed. See /config/gitops-sync.log"
    exit 1
  fi

  if ! git rev-parse --verify "origin/main" > /dev/null 2>&1; then
    log ERROR "origin/main not found after fetch. Default branch may not be 'main'."
    exit 1
  fi

  local remote_sha
  remote_sha=$(git rev-parse origin/main)

  if [[ "$rollback_sha" == "$remote_sha" ]]; then
    log INFO "no-op, up to date at ${rollback_sha:0:7}"
    exit 0
  fi

  local commit_count delta
  commit_count=$(git rev-list --count HEAD..origin/main)
  delta=$(git log --oneline HEAD..origin/main)
  log INFO "Applying ${commit_count} commit(s):"
  log INFO "${delta}"

  git reset --hard origin/main

  local new_sha
  new_sha=$(git rev-parse HEAD)
  log INFO "Reset to ${new_sha:0:7}, running Supervisor config check"

  local tmp_resp http_code check_body
  tmp_resp=$(mktemp)
  http_code=$(curl -s -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" \
    -o "$tmp_resp" \
    -w "%{http_code}" \
    "${SUPERVISOR_BASE}/core/check")
  check_body=$(cat "$tmp_resp")
  rm -f "$tmp_resp"

  if [[ "$http_code" == "200" ]]; then
    local commit_info
    commit_info=$(git log -1 --pretty=format:'%h %s')
    log INFO "Config validated."
    ha_notify "HA config deployed: ${commit_info}"
    apply_reload "$rollback_sha" "$new_sha"
    exit 0
  else
    local truncated
    truncated=$(printf '%s' "$check_body" | head -c 2048)
    log ERROR "Config check failed (HTTP ${http_code}): ${truncated}"
    log INFO "Rolling back to ${rollback_sha:0:7}"
    git reset --hard "$rollback_sha"
    log INFO "Rollback complete"
    ha_notify "⚠️ HA config validation FAILED — rolled back to ${rollback_sha:0:7}. See /config/gitops-sync.log"
    exit 1
  fi
}

# Acquire exclusive lock — exit silently if a previous run is still in progress,
# then run main. Wrapped in a function so the script can be sourced (e.g. by the
# bats suite in tests/) without acquiring the lock or deploying.
main_locked() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    exit 0
  fi
  main
}

# Only self-execute when run directly, not when sourced for testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main_locked
fi
