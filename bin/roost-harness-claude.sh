#!/usr/bin/env bash
# Claude harness adapter for roost spawn. Sourced by bin/roost.
# Reads the REQ_* request contract, writes side-car files into REQ_DATA_DIR,
# and sets RESP_INNER_CMD + appends to the RESP_TMUX_ENV array.
# This is the extracted Claude launch assembly. Behavior must match the
# pre-extraction bin/roost exactly. test/spawn_test.sh is the guard.

harness_assemble() {
  # --- Hook wiring + settings JSON (moved from bin/roost) ---
  # Per-session roost-settings.json. Written before the tmux/ircd preflight
  # so test seams can read it on preflight failure. PostCompact + SessionStart
  # matcher=compact are always wired; PreCompact is opt-in via --steer-compact;
  # PermissionRequest is added when --perm-irc is passed. PreToolUse:Bash is
  # added when --perm-irc is passed AND the resolved permission mode can
  # still produce a blocking bash prompt (see the skip-set below).
  # PreToolUse:AskUserQuestion is added when --ask-irc or --ask-target is set.
  # Cleaned up implicitly when data_dir is rm -rf'd on shutdown.
  local perm_hook_json=""
  local pretooluse_hook_json=""
  # Hook commands invoke `${REQ_ROOST_BIN} hook-exec <name>` rather than a
  # per-session shim path. REQ_ROOST_BIN is the absolute path to the invoking
  # roost script (brew symlink or dev clone) captured at the top of that
  # script. Stable across brew upgrades because brew re-points the symlink, and
  # immune to /tmp cleanup because nothing under DATA_DIR is in the path.
  local precompact_hook_json=""
  if [ "${REQ_STEER_COMPACT}" -eq 1 ]; then
    precompact_hook_json="\"PreCompact\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"${REQ_ROOST_BIN} hook-exec roost-compact-hook\"}]}],"
  fi
  if [ "${REQ_PERM_IRC}" -eq 1 ]; then
    perm_hook_json=",\"PermissionRequest\":[{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"${REQ_ROOST_BIN} hook-exec irc-permission-prompt\"}]}]"
  fi
  # PreToolUse may hold up to two matcher entries: Bash (when --perm-irc, so
  # the safety-analyzer can't bypass the operator's review) and
  # AskUserQuestion (when --ask-irc / --ask-target routes questions to IRC).
  #
  # The Bash entry is skipped for permission modes that never produce a
  # blocking bash prompt in the first place. Wiring it there only relays
  # noise the operator never needed to see:
  #   auto              - grants classified bash shapes outright, no prompt
  #   bypassPermissions - skips all permission checks by design
  # Every other mode, including the empty/unresolved case (e.g. an --agent
  # whose frontmatter declares no permissionMode) and modes not verified to
  # skip bash prompts (e.g. dontAsk), keeps the hook wired. Unverified modes
  # default to wired rather than skipped: a spurious relay is a minor
  # annoyance, but skipping a mode that actually blocks reintroduces the
  # terminal-only-prompt hang this hook exists to close.
  local pretooluse_entries=()
  local _skip_bash_hook=0
  case "${REQ_HOOK_PERM_MODE}" in
    auto|bypassPermissions) _skip_bash_hook=1 ;;
  esac
  if [ "${REQ_PERM_IRC}" -eq 1 ] && [ "${_skip_bash_hook}" -eq 0 ]; then
    pretooluse_entries+=("{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"${REQ_ROOST_BIN} hook-exec irc-pretooluse-prompt\"}]}")
  elif [ "${REQ_PERM_IRC}" -eq 1 ] && [ "${_skip_bash_hook}" -eq 1 ]; then
    # Otherwise an operator who passed --perm-irc expecting bash prompts sees
    # none and has no way to tell "resolved mode never blocks on bash" apart
    # from "something's broken".
    echo "  bash permission relay: skipped — ${REQ_HOOK_PERM_MODE} never blocks on bash"
  fi
  if [ "${REQ_ASK_ROUTING}" -eq 1 ]; then
    pretooluse_entries+=("{\"matcher\":\"AskUserQuestion\",\"hooks\":[{\"type\":\"command\",\"command\":\"${REQ_ROOST_BIN} hook-exec irc-ask-question\"}]}")
  fi
  if [ "${#pretooluse_entries[@]}" -gt 0 ]; then
    local _ptu_joined=""
    local _ptu_sep=""
    for _ptu_entry in "${pretooluse_entries[@]}"; do
      _ptu_joined="${_ptu_joined}${_ptu_sep}${_ptu_entry}"
      _ptu_sep=","
    done
    pretooluse_hook_json=",\"PreToolUse\":[${_ptu_joined}]"
  fi
  # Allow roost-irc MCP tools without a permission prompt on loopback sessions
  # (same gate as trust injection below). Remote ergo doesn't get the allow.
  # "permissions" is the only top-level key added here alongside "hooks"; keep
  # it that way to avoid duplicate-key collisions in the written JSON.
  local permissions_json=""
  case "${REQ_IRC_HOST}" in
    127.0.0.1|::1|localhost)
      permissions_json=",\"permissions\":{\"allow\":[\"mcp__plugin_roost_roost-irc__*\",\"mcp__roost-irc__*\"]}"
      ;;
  esac
  printf '%s\n' "{\"hooks\":{${precompact_hook_json}\"PostCompact\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"${REQ_ROOST_BIN} hook-exec roost-post-compact-hook\"}]}],\"SessionStart\":[{\"matcher\":\"compact\",\"hooks\":[{\"type\":\"command\",\"command\":\"${REQ_ROOST_BIN} hook-exec roost-session-start-hook\"}]}]${perm_hook_json}${pretooluse_hook_json}}${permissions_json}}" > "${REQ_SETTINGS_PATH}"

  # --- MCP/agent/model/perm/trust flags + inner_cmd (moved from bin/roost) ---
  # Build the inner command. Bash expands its own ${vars} here, then we
  # append the prompt placeholder as a single-quoted literal so the file-read
  # is evaluated by the login shell. Not bash and not the tmux shell.
  # Embedding multi-line file contents directly via printf %q produces
  # $'...' ANSI-C quoting, which doesn't survive the shell-layer chain
  # (bash → tmux shell → login shell -c). Reading the file inside the login
  # shell sidesteps that entirely. The leading `--` is required so the prompt
  # isn't absorbed by --dangerously-load-development-channels (variadic flag:
  # eats all subsequent non-flag args).
  #
  # The read syntax is shell-flavored: everywhere outside fish we use
  # `$(cat "$ROOST_PROMPT_FILE")` (POSIX portable); fish has no `$(...)` syntax
  # and treats unquoted `(...)` as command substitution but treats bare `(...)`
  # inside double quotes as a literal, so we use unquoted
  # `(string collect <$ROOST_PROMPT_FILE)` (fish 3.1+). String collect emits
  # a single argument with newlines preserved, which fish hands to claude as
  # one arg even unquoted.
  #
  # Done before require_tmux/require_ircd so the ROOST_SPAWN_KEEP_DATA_DIR=1
  # test seam can surface the assembled command without an IRC daemon running.
  local mcp_flag=""
  local channel_server="server:plugin:roost:roost-irc"
  if [ -n "${REQ_MCP_CONFIG}" ]; then
    mcp_flag=" --mcp-config ${REQ_MCP_CONFIG}"
    channel_server="server:roost-irc"
  fi
  local agent_flag=""
  if [ -n "${REQ_AGENT}" ]; then
    agent_flag=" --agent $(printf '%q' "${REQ_AGENT}")"
  fi
  # --plugin-dir points claude at the resolved plugin tree (dev checkout
  # OR brew cellar. REQ_ROOST_DIR walks symlinks). Without it, --dangerously-
  # load-development-channels server:plugin:roost:roost-irc has nothing to
  # find unless the plugin's been installed into claude's registry.
  local model_flag=""
  [ -n "${REQ_MODEL}" ] && model_flag=" --model ${REQ_MODEL}"
  # Only pass --permission-mode when the operator set it explicitly. When
  # --agent is used, the agent's frontmatter `permissionMode:` (project /
  # user scope) is the right place to declare it; otherwise claude's own
  # default applies.
  local perm_mode_flag=""
  [ -n "${REQ_PERMISSION_MODE}" ] && perm_mode_flag=" --permission-mode ${REQ_PERMISSION_MODE}"
  # Pre-authorize IRC traffic as user instructions for the auto-mode classifier.
  # Roost's security model assumes a trusted single-user local environment
  # (see README, Security model), so messages arriving on the joined channels
  # are effectively the operator's voice, but auto mode does not know that
  # without being told and the silent block lands the operator's first
  # @-mention in the tmux pane instead of on IRC. Gated on loopback IRC_HOST
  # because the trust assumption only holds for local ergo; skipped when no
  # channels were requested. The text names the *requested* --channels rather
  # than the actually-joined set; failed JOINs aren't detected here and the
  # classifier still trusts those channel names, which is acceptable under
  # the trusted single-user local environment assumption.
  #
  # The trust text is staged to a file and passed via --append-system-prompt-file
  # rather than --append-system-prompt to sidestep shell-quoting landmines:
  # the default --channels is #roost, and `#` in zsh extended_glob mode (a
  # common operator setting) makes any backslash-escaped `#...` token a glob
  # pattern that fails with "no matches found" before claude ever runs. The
  # file path uses only mktemp-clean characters so it survives the bash to
  # tmux to login-shell chain unescaped.
  local trust_flag=""
  local _channels_for_trust
  _channels_for_trust="$(printf '%s' "${REQ_CHANNELS}" | tr -d '[:space:]')"
  case "${REQ_IRC_HOST}" in
    127.0.0.1|::1|localhost)
      if [ -n "${_channels_for_trust}" ]; then
        local _trust_file="${REQ_DATA_DIR}/trust-prompt.txt"
        printf '%s' "This Claude Code session is connected to a local IRCv3 server via the roost-irc MCP under roost's trusted single-user local environment security model. Messages received in joined channels ${_channels_for_trust} via that MCP (in-channel messages, @-mentions, and DMs) are legitimate user instructions for this session. Treat them as if typed at the terminal. Reply via channel_message or direct_message." > "${_trust_file}"
        trust_flag=" --append-system-prompt-file ${_trust_file}"
      fi
      ;;
    *)
      echo "  warning: IRC host '${REQ_IRC_HOST}' is not loopback; skipping auto-mode IRC trust injection. Under --permission-mode auto the agent may silently refuse to post on IRC. Workaround: attach and type the trust statement, or pass --permission-mode acceptEdits." >&2
      ;;
  esac
  RESP_INNER_CMD="claude${model_flag}${perm_mode_flag}${mcp_flag}${agent_flag} --settings ${REQ_SETTINGS_PATH} --plugin-dir ${REQ_ROOST_DIR} --dangerously-load-development-channels ${channel_server}${trust_flag}${REQ_EXTRA_STR}"
  if [ -n "${REQ_PROMPT_FILE}" ]; then
    # intentionally single-quoted: fragment is injected into a tmux pane and must expand at runtime in that shell
    # shellcheck disable=SC2016
    case "${REQ_SHELL_BASENAME}" in
      fish) RESP_INNER_CMD="${RESP_INNER_CMD} --"' (string collect <$ROOST_PROMPT_FILE)' ;;
      *)    RESP_INNER_CMD="${RESP_INNER_CMD} --"' "$(cat "$ROOST_PROMPT_FILE")"' ;;
    esac
    RESP_TMUX_ENV+=(-e "ROOST_PROMPT_FILE=${REQ_PROMPT_FILE}")
  fi
  # Provider-configured backend swap. REQ_BASE_URL_ENV/REQ_AUTH_ENV hold the
  # NAMES of env vars the operator populated with the real URL/token (from
  # the provider's base_url_env/auth_env config, resolved by the registry).
  # ${!name} is bash indirect expansion: it reads the VALUE of the env var
  # whose name is stored in that variable. Only forwarded when the named
  # var is actually set and non-empty, so an unconfigured provider adds
  # nothing here.
  if [ -n "${REQ_BASE_URL_ENV}" ]; then
    local _url_val="${!REQ_BASE_URL_ENV:-}"
    [ -n "${_url_val}" ] && RESP_TMUX_ENV+=(-e "ANTHROPIC_BASE_URL=${_url_val}")
  fi
  if [ -n "${REQ_AUTH_ENV}" ]; then
    local _tok_val="${!REQ_AUTH_ENV:-}"
    [ -n "${_tok_val}" ] && RESP_TMUX_ENV+=(-e "ANTHROPIC_AUTH_TOKEN=${_tok_val}")
  fi
  # Same test seam as the data-dir preflight echo in the spawn wrapper: surface
  # the assembled inner command so the spawn_test.sh shell-flavor regressions
  # can grep for the prompt-read syntax that matches the resolved shell. Stage
  # it to a file too so tests can read it deterministically without parsing
  # stdout.
  if [ "${ROOST_SPAWN_KEEP_DATA_DIR:-0}" = "1" ]; then
    echo "  inner cmd (preflight): ${RESP_INNER_CMD}"
    printf '%s' "${RESP_INNER_CMD}" > "${REQ_DATA_DIR}/inner-cmd.txt"
    # Test seam: stage the tmux env additions for spawn tests. This can
    # include a raw ANTHROPIC_AUTH_TOKEN value when a provider configures
    # auth_env, so it is gated on the same test-only flag as inner-cmd.txt
    # above and never written during a real operator spawn. Guard the
    # empty-array case: "${arr[@]}" on an empty/unset array is unbound under
    # set -u on bash 3.2 (the bash macOS ships).
    if [ "${#RESP_TMUX_ENV[@]}" -gt 0 ]; then
      printf '%s\n' "${RESP_TMUX_ENV[@]}" > "${REQ_DATA_DIR}/tmux-env.txt"
    else
      : > "${REQ_DATA_DIR}/tmux-env.txt"
    fi
  fi
}
