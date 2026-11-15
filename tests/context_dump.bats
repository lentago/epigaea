#!/usr/bin/env bats
#
# Unit tests for the snapshot transforms in scripts/ha-context-dump.sh.
#
# build_entities / build_areas / build_devices / build_helpers /
# build_dashboards_storage and storage_items are pure jq projections over
# HA's .storage/ registry files. A bug there silently produces a malformed or
# empty context/ snapshot, which everything downstream then trusts. These tests
# source the script (guarded by BASH_SOURCE == $0 so main() does not run) and
# feed each transform fixtures under tests/fixtures/storage/.

setup() {
  # shellcheck source=../scripts/ha-context-dump.sh
  source "${BATS_TEST_DIRNAME}/../scripts/ha-context-dump.sh"
  FIXTURES="${BATS_TEST_DIRNAME}/fixtures/storage"
}

# --- storage_items ---------------------------------------------------------

@test "storage_items returns [] for a missing file" {
  run storage_items "${BATS_TEST_TMPDIR}/does-not-exist"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .)" = "[]" ]
}

@test "storage_items extracts and id-sorts the items array" {
  run storage_items "${FIXTURES}/input_boolean"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq 'length')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].id')" = "away" ]
}

# --- build_entities --------------------------------------------------------

@test "build_entities drops disabled entities and sorts by entity_id" {
  run build_entities "${FIXTURES}/core.entity_registry"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "2" ]
  [ "$(echo "$output" | jq -r '.[0].entity_id')" = "light.kitchen" ]
  [ "$(echo "$output" | jq -r '.[1].entity_id')" = "sensor.aaa" ]
  # the disabled entity must be absent entirely
  [ "$(echo "$output" | jq '[.[] | select(.entity_id == "light.disabled")] | length')" = "0" ]
}

@test "build_entities prefers name over original_name and derives hidden" {
  run build_entities "${FIXTURES}/core.entity_registry"
  # light.kitchen: has name -> "Kitchen Light", hidden_by null -> hidden false
  [ "$(echo "$output" | jq -r '.[0].friendly_name')" = "Kitchen Light" ]
  [ "$(echo "$output" | jq -r '.[0].hidden')" = "false" ]
  # sensor.aaa: name null -> falls back to original_name; hidden_by set -> true
  [ "$(echo "$output" | jq -r '.[1].friendly_name')" = "AAA Sensor" ]
  [ "$(echo "$output" | jq -r '.[1].hidden')" = "true" ]
}

# --- build_areas -----------------------------------------------------------

@test "build_areas maps id->area_id and sorts by name" {
  run build_areas "${FIXTURES}/core.area_registry"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.[0].area_id')" = "kitchen" ]
  [ "$(echo "$output" | jq -r '.[0].name')" = "Kitchen" ]
  [ "$(echo "$output" | jq -r '.[1].area_id')" = "office" ]
}

# --- build_devices ---------------------------------------------------------

@test "build_devices resolves integration domains via the config_entries join" {
  run build_devices "${FIXTURES}/core.device_registry" "${FIXTURES}/core.config_entries"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'length')" = "2" ]
  # dev1 ("My Hue") -> name_by_user wins, ce_hue resolves to "hue"
  [ "$(echo "$output" | jq -r '.[0].name')" = "My Hue" ]
  [ "$(echo "$output" | jq -c '.[0].integrations')" = '["hue"]' ]
}

@test "build_devices falls back to name and drops unknown config entries" {
  run build_devices "${FIXTURES}/core.device_registry" "${FIXTURES}/core.config_entries"
  # dev2: name_by_user null -> falls back to .name "ZHA Sensor"
  [ "$(echo "$output" | jq -r '.[1].name')" = "ZHA Sensor" ]
  # ce_zha -> "zha"; ce_unknown has no matching entry -> filtered out
  [ "$(echo "$output" | jq -c '.[1].integrations')" = '["zha"]' ]
}

@test "build_devices tolerates null config_entries on a device and in the entries file" {
  cat > "${BATS_TEST_TMPDIR}/dev.json" <<'JSON'
{"data": {"devices": [
  {"id": "d1", "name": "Orphan", "name_by_user": null, "manufacturer": null,
   "model": null, "area_id": null, "config_entries": null},
  {"id": "d2", "name": "Hue", "name_by_user": null, "manufacturer": "Signify",
   "model": "x", "area_id": null, "config_entries": ["ce_hue", null, 7]},
  {"id": "d3", "name": "Nulls", "name_by_user": null, "manufacturer": null,
   "model": null, "area_id": null, "config_entries": [null, null]}
]}}
JSON
  run build_devices "${BATS_TEST_TMPDIR}/dev.json" "${FIXTURES}/core.config_entries"
  [ "$status" -eq 0 ]
  # sorted by name: Hue, Nulls, Orphan
  [ "$(echo "$output" | jq -c 'map(.integrations)')" = '[["hue"],[],[]]' ]

  printf '{"data": {"entries": null}}\n' > "${BATS_TEST_TMPDIR}/cfg.json"
  run build_devices "${BATS_TEST_TMPDIR}/dev.json" "${BATS_TEST_TMPDIR}/cfg.json"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c 'map(.integrations)')" = '[[],[],[]]' ]
}

# --- build_helpers ---------------------------------------------------------

@test "build_helpers emits all eight helper types, present ones populated" {
  run build_helpers "$FIXTURES"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq 'keys | length')" = "8" ]
  # input_boolean is present in the fixture dir -> populated and id-sorted
  [ "$(echo "$output" | jq '.input_boolean | length')" = "2" ]
  [ "$(echo "$output" | jq -r '.input_boolean[0].id')" = "away" ]
  # a type with no .storage file -> stable empty array, not missing/null
  [ "$(echo "$output" | jq -c '.timer')" = "[]" ]
  [ "$(echo "$output" | jq -c '.counter')" = "[]" ]
}

@test "build_helpers yields all-empty arrays for an empty storage dir" {
  run build_helpers "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '[.[] | length] | add')" = "0" ]
  [ "$(echo "$output" | jq 'keys | length')" = "8" ]
}

# --- build_dashboards_storage ----------------------------------------------

@test "build_dashboards_storage merges registry, default, and extra dashboards" {
  run build_dashboards_storage "$FIXTURES"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq '.dashboards | length')" = "1" ]
  [ "$(echo "$output" | jq -r '.dashboards[0].url_path')" = "home-ui" ]
  # default dashboard config blob
  [ "$(echo "$output" | jq -r '.configs.lovelace.views[0].title')" = "Main" ]
  # extra storage-mode dashboard, keyed by its .storage filename
  [ "$(echo "$output" | jq -r '.configs["lovelace.home-ui"].views[0].title')" = "HomeUI" ]
}

@test "build_dashboards_storage is presence-stable for an empty storage dir" {
  run build_dashboards_storage "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -c '.dashboards')" = "[]" ]
  [ "$(echo "$output" | jq -c '.configs')" = "{}" ]
}
