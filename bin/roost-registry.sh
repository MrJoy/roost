#!/usr/bin/env bash
# Registry + policy module for roost spawn. Sourced by bin/roost.
# Reads .orchestrator/config.json (providers + roles) via jq. Spawn-time only.
# shellcheck disable=SC2034  # RESOLVED_* globals are read by the sourcing caller (bin/roost), not within this file.

# Path to the project config, relative to the spawn cwd.
_registry_config_path() { echo ".orchestrator/config.json"; }

# registry_vendor_org <model> -> echoes the org by vendor lineage, or empty if
# unknown. Bare aliases (opus/sonnet/haiku/fable) are Claude models used by
# the default Claude path, so they map to anthropic same as claude-*.
registry_vendor_org() {
  local m="$1"
  case "$m" in
    claude-*|opus|sonnet|haiku|fable) echo "anthropic" ;;
    gpt-*|o1|o1-*|o3|o3-*|o4|o4-*|o[0-9]*) echo "openai" ;;
    *) echo "" ;;
  esac
}

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
  RESOLVED_ORG="$(printf '%s' "$entry" | jq -r '.org // empty')"
  [ -n "$RESOLVED_MODEL" ] || { echo "error: provider '${name}' has no model in .orchestrator/config.json" >&2; return 1; }
  if [ -z "$RESOLVED_ORG" ]; then
    RESOLVED_ORG="$(registry_vendor_org "$RESOLVED_MODEL")"
  fi
  if [ -z "$RESOLVED_ORG" ]; then
    echo "error: cannot determine org for model '${RESOLVED_MODEL}' by vendor lineage. Set an explicit \"org\" on provider '${RESOLVED_PROVIDER_NAME}' in .orchestrator/config.json" >&2
    return 1
  fi
  return 0
}

# registry_role_candidates <role> -> prints provider names, one per line, in preference order.
registry_role_candidates() {
  local role="$1" cfg; cfg="$(_registry_config_path)"
  [ -f "$cfg" ] || { echo "error: no .orchestrator/config.json in $(pwd). Cannot resolve role '${role}'" >&2; return 1; }
  local val
  val="$(jq -c --arg r "$role" '.roles[$r] // empty' "$cfg")"
  [ -n "$val" ] || { echo "error: unknown role '${role}'. Not found in .orchestrator/config.json roles" >&2; return 1; }
  # A role value is a string, an array, or an object carrying .candidates
  # (itself a string or array) plus optional author/review properties. Unwrap
  # the object to its candidates, then flatten string-or-array to a line list.
  printf '%s' "$val" | jq -r '
    (if type=="object" then (.candidates // []) else . end)
    | if type=="array" then .[] else . end'
}

# registry_role_is_author <role> -> exit 0 if the role records authorship.
# A role records authorship when its config object sets "author": true; when
# the object omits "author" (or the value is the bare string/array form) the
# built-in default applies: a role literally named "worker" is an author role.
registry_role_is_author() {
  local role="$1" cfg explicit; cfg="$(_registry_config_path)"
  if [ -f "$cfg" ]; then
    explicit="$(jq -r --arg r "$role" '.roles[$r] | if type=="object" and has("author") then (.author|tostring) else "unset" end' "$cfg" 2>/dev/null)"
  else
    explicit="unset"
  fi
  case "$explicit" in
    true)  return 0 ;;
    false) return 1 ;;
    *)     [ "$role" = "worker" ] && return 0 || return 1 ;;
  esac
}

# registry_role_is_review <role> -> exit 0 if the role is cross-org gated.
# Mirror of registry_role_is_author: "review": true in the object, else the
# built-in default that a role literally named "reviewer" is a review role.
registry_role_is_review() {
  local role="$1" cfg explicit; cfg="$(_registry_config_path)"
  if [ -f "$cfg" ]; then
    explicit="$(jq -r --arg r "$role" '.roles[$r] | if type=="object" and has("review") then (.review|tostring) else "unset" end' "$cfg" 2>/dev/null)"
  else
    explicit="unset"
  fi
  case "$explicit" in
    true)  return 0 ;;
    false) return 1 ;;
    *)     [ "$role" = "reviewer" ] && return 0 || return 1 ;;
  esac
}

# registry_resolve_role <role>: resolve to the FIRST candidate (a later task
# replaces this with the policy gate for reviewer roles).
registry_resolve_role() {
  local role="$1" first
  first="$(registry_role_candidates "$role" | head -1)" || return 1
  [ -n "$first" ] || { echo "error: role '${role}' has an empty candidate set" >&2; return 1; }
  registry_provider_fields "$first"
}

# Path to the per-issue provider assignment state, relative to the spawn cwd.
_assignment_path() { echo ".orchestrator/provider-assignments.json"; }

# assignment_record <issue> <role> <provider> <org> [override] [reason]
# Atomic read-modify-write: writes to a tempfile then renames into place, so
# a concurrent reader never sees a half-written file.
assignment_record() {
  local issue="$1" role="$2" provider="$3" org="$4" override="${5:-false}" reason="${6:-}"
  local f; f="$(_assignment_path)"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '{}' > "$f"
  local tmp; tmp="$(mktemp "${f}.XXXXXX")"
  jq --arg i "$issue" --arg role "$role" --arg p "$provider" --arg o "$org" \
     --argjson ov "$override" --arg reason "$reason" \
     '.[$i] = {provider:$p, org:$o, role:$role, override:$ov, reason:$reason}' \
     "$f" > "$tmp" && mv "$tmp" "$f"
}

# assignment_append <key> <kind> <provider> <org> [reason]
# Appends a record to the JSON array at .[$key], creating the array if absent.
# Used for the append-safe audit trails (#override, #bypass) so a second event
# for the same issue never clobbers the first. Atomic tmp+mv, same discipline
# as assignment_record.
assignment_append() {
  local key="$1" kind="$2" provider="$3" org="$4" reason="${5:-}"
  local f; f="$(_assignment_path)"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '{}' > "$f"
  local tmp; tmp="$(mktemp "${f}.XXXXXX")"
  jq --arg k "$key" --arg kind "$kind" --arg p "$provider" --arg o "$org" --arg reason "$reason" \
     '.[$k] = ((.[$k] // []) + [{kind:$kind, provider:$p, org:$o, reason:$reason}])' \
     "$f" > "$tmp" && mv "$tmp" "$f"
}

# assignment_lookup <issue> -> echoes the recorded org, or empty if none.
assignment_lookup() {
  local issue="$1" f; f="$(_assignment_path)"
  [ -f "$f" ] || return 0
  jq -r --arg i "$issue" '.[$i].org // empty' "$f"
}

# policy_gate_reviewer <issue> <role> <allow_same_org:0|1> <reason>
# Walks the role's candidate set, picks the first provider whose lineage org
# differs from the recorded author-org. Sets RESOLVED_* on success.
# Return codes: 0 ok; 2 no recorded author; 3 all same-org (no override).
policy_gate_reviewer() {
  local issue="$1" role="$2" allow="$3" reason="$4"
  local author_org; author_org="$(assignment_lookup "$issue")"
  if [ -z "$author_org" ]; then
    echo "error: no recorded author for issue ${issue}. Spawn the worker first" >&2
    return 2
  fi
  local candidates; candidates="$(registry_role_candidates "$role")" || return 1
  local top="" chosen=""
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    [ -z "$top" ] && top="$cand"
    registry_provider_fields "$cand" || return 1
    if [ "$RESOLVED_ORG" != "$author_org" ]; then
      chosen="$cand"; break
    fi
  done <<< "$candidates"
  if [ -n "$chosen" ]; then
    if [ "$chosen" != "$top" ]; then
      echo "  cross-org gate: chose '${chosen}' over top candidate '${top}' (author org '${author_org}')"
    fi
    # RESOLVED_* already set to the chosen provider by the loop's last fields call.
    registry_provider_fields "$chosen"
    return 0
  fi
  # No cross-org candidate.
  if [ "$allow" = "1" ]; then
    registry_provider_fields "$top" || return 1
    echo "  WARNING: cross-org gate OVERRIDE. Reviewer '${top}' is same org ('${author_org}') as the author. Reason: ${reason}" >&2
    # Append the override to a distinct key's array so it never clobbers the
    # worker's author entry at "$issue", and a second override for the same
    # issue never clobbers the first. assignment_lookup reads the author org
    # from "$issue", so a later re-review still sees the real author, not
    # this reviewer. The override trail is auditable on its own key.
    assignment_append "${issue}#override" "reviewer-override" "$top" "$RESOLVED_ORG" "$reason"
    return 0
  fi
  echo "error: cross-org review rule. Every reviewer candidate for issue ${issue} is same org ('${author_org}') as the author. Pass --allow-same-org \"<reason>\" to override." >&2
  return 3
}
