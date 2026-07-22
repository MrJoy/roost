#!/usr/bin/env bash
# Registry + policy module for roost spawn. Sourced by bin/roost.
# Reads .orchestrator/config.json (providers + roles) via jq. Spawn-time only.
# shellcheck disable=SC2034  # RESOLVED_* globals are read by the sourcing caller (bin/roost), not within this file.

# Path to the project config, relative to the spawn cwd.
_registry_config_path() { echo ".orchestrator/config.json"; }

# registry_provider_fields <provider-name>
# Sets RESOLVED_* from the provider entry. Returns 1 if the provider is absent.
registry_provider_fields() {
  local name="$1" cfg; cfg="$(_registry_config_path)"
  [ -f "$cfg" ] || { echo "error: no .orchestrator/config.json in $(pwd). Cannot resolve provider '${name}'" >&2; return 1; }
  local entry
  entry="$(jq -c --arg n "$name" '.providers[$n] // empty' "$cfg")"
  [ -n "$entry" ] || { echo "error: unknown provider '${name}'. Not found in .orchestrator/config.json providers" >&2; return 1; }
  RESOLVED_PROVIDER_NAME="$name"
  RESOLVED_HARNESS="$(printf '%s' "$entry" | jq -r '.harness // "claude"')"
  RESOLVED_MODEL="$(printf '%s' "$entry" | jq -r '.model // empty')"
  RESOLVED_BASE_URL_ENV="$(printf '%s' "$entry" | jq -r '.base_url_env // empty')"
  RESOLVED_AUTH_ENV="$(printf '%s' "$entry" | jq -r '.auth_env // empty')"
  RESOLVED_ORG="$(printf '%s' "$entry" | jq -r '.org // empty')"  # may be empty; filled by vendor lineage in a later task
  [ -n "$RESOLVED_MODEL" ] || { echo "error: provider '${name}' has no model in .orchestrator/config.json" >&2; return 1; }
  return 0
}

# registry_role_candidates <role> -> prints provider names, one per line, in preference order.
registry_role_candidates() {
  local role="$1" cfg; cfg="$(_registry_config_path)"
  [ -f "$cfg" ] || { echo "error: no .orchestrator/config.json in $(pwd). Cannot resolve role '${role}'" >&2; return 1; }
  local val
  val="$(jq -c --arg r "$role" '.roles[$r] // empty' "$cfg")"
  [ -n "$val" ] || { echo "error: unknown role '${role}'. Not found in .orchestrator/config.json roles" >&2; return 1; }
  # Normalize string-or-array to a newline list.
  printf '%s' "$val" | jq -r 'if type=="array" then .[] else . end'
}

# registry_resolve_role <role>: resolve to the FIRST candidate (a later task
# replaces this with the policy gate for reviewer roles).
registry_resolve_role() {
  local role="$1" first
  first="$(registry_role_candidates "$role" | head -1)" || return 1
  [ -n "$first" ] || { echo "error: role '${role}' has an empty candidate set" >&2; return 1; }
  registry_provider_fields "$first"
}
