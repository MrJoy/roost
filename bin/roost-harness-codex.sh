#!/usr/bin/env bash
# Codex harness adapter for roost spawn. Sourced by bin/roost.
# Reads the REQ_* request contract, writes a per-session Codex config.toml into
# CODEX_HOME under REQ_DATA_DIR, and sets RESP_INNER_CMD + appends to RESP_TMUX_ENV.
# Mirrors the Claude adapter's contract; the launch is a resident `codex` TUI.

harness_assemble() {
  # Fail-closed gate. Codex launches with its native approval turned off, so
  # roost's own gate has to be present or an unattended pane would auto-run every
  # command. Refuse to launch when neither the permbot relay (--perm-irc) nor a
  # signet policy (.signet/) is active, rather than launch un-gated. A human who
  # wants an interactive Codex session still passes --perm-irc.
  if [ "${REQ_PERM_IRC}" -ne 1 ] && [ "${REQ_SIGNET_ACTIVE}" -ne 1 ]; then
    echo "error: a codex spawn requires a permission gate. Pass --perm-irc, or run in a project with a .signet/ policy. Refusing to launch un-gated: codex runs with native approval off, so with no roost gate it would auto-run every command." >&2
    return 1
  fi

  # Session config lives in a per-session CODEX_HOME so it never touches a
  # project AGENTS.md or the operator's ~/.codex. The TUI reads config.toml from
  # $CODEX_HOME/config.toml.
  local codex_home="${REQ_DATA_DIR}/codex-home"
  mkdir -p "${codex_home}"
  local config_toml="${codex_home}/config.toml"

  # Backend override: only when a non-default provider set a base_url_env whose
  # named env var is populated. Mirrors the Claude adapter's ANTHROPIC_BASE_URL
  # swap, via Codex's [model_providers.<name>] surface. env_key names the env var
  # Codex reads the key from at runtime (its VALUE is not written to disk).
  local model_provider_line=""
  local provider_block=""
  if [ -n "${REQ_BASE_URL_ENV}" ]; then
    local _url_val="${!REQ_BASE_URL_ENV:-}"
    if [ -n "${_url_val}" ]; then
      model_provider_line="model_provider = \"roost-provider\""$'\n'
      # `name` is required: Codex rejects the whole config with "provider name
      # must not be empty" if a [model_providers.<key>] block omits it.
      provider_block=$'\n'"[model_providers.roost-provider]"$'\n'"name = \"roost-provider\""$'\n'"base_url = \"${_url_val}\""$'\n'
      if [ -n "${REQ_AUTH_ENV}" ]; then
        provider_block="${provider_block}env_key = \"${REQ_AUTH_ENV}\""$'\n'
      fi
    fi
  fi

  # Policy hook chain. signet-eval decides first when .signet/ is active
  # (deterministic, LLM-free), ordered ahead of the IRC permbot relay on both
  # PermissionRequest and PreToolUse. Both scripts already emit the
  # permissionDecision / permissionDecisionReason wire Codex consumes, so no
  # hook-script rewrite is needed; the adapter wires the TOML.
  #
  # The nesting is load-bearing. Codex expects each event to hold a sequence of
  # groups, and each group a `hooks` array of {type,command} entries. A command
  # placed directly on the group table parses without error but never fires at
  # runtime, so a single missing level of nesting turns the whole gate into a
  # silent no-op. Emit one group per event with both entries in its hooks array,
  # signet first.
  local pr_hooks="" ptu_hooks=""
  if [ "${REQ_SIGNET_ACTIVE}" -eq 1 ]; then
    pr_hooks="${pr_hooks}"$'\n'"[[hooks.PermissionRequest.hooks]]"$'\n'"type = \"command\""$'\n'"command = \"signet-eval --permissionrequest\""$'\n'
    ptu_hooks="${ptu_hooks}"$'\n'"[[hooks.PreToolUse.hooks]]"$'\n'"type = \"command\""$'\n'"command = \"signet-eval --pretooluse\""$'\n'
  fi
  if [ "${REQ_PERM_IRC}" -eq 1 ]; then
    pr_hooks="${pr_hooks}"$'\n'"[[hooks.PermissionRequest.hooks]]"$'\n'"type = \"command\""$'\n'"command = \"${REQ_ROOST_BIN} hook-exec irc-permission-prompt\""$'\n'
    ptu_hooks="${ptu_hooks}"$'\n'"[[hooks.PreToolUse.hooks]]"$'\n'"type = \"command\""$'\n'"command = \"${REQ_ROOST_BIN} hook-exec irc-pretooluse-prompt\""$'\n'
  fi
  local hooks_block=""
  if [ -n "${pr_hooks}" ]; then
    hooks_block="${hooks_block}"$'\n'"[[hooks.PermissionRequest]]"$'\n'"${pr_hooks}"
  fi
  if [ -n "${ptu_hooks}" ]; then
    hooks_block="${hooks_block}"$'\n'"[[hooks.PreToolUse]]"$'\n'"matcher = \"Bash\""$'\n'"${ptu_hooks}"
  fi

  # The roost-irc MCP stdio server. It launches from the resolved plugin tree and
  # inherits the ROOST_IRC_* identity env from the tmux pane (bin/roost sets those
  # via tmux -e), the same way the Claude path's MCP does. So no env is duplicated
  # into the TOML here.
  {
    printf 'model = "%s"\n' "${REQ_MODEL}"
    [ -n "${model_provider_line}" ] && printf '%s' "${model_provider_line}"
    printf '\n[mcp_servers.roost-irc]\n'
    printf 'command = "%s/bin/roost-irc-server"\n' "${REQ_ROOST_DIR}"
    printf 'args = []\n'
    [ -n "${provider_block}" ] && printf '%s' "${provider_block}"
    [ -n "${hooks_block}" ] && printf '%s' "${hooks_block}"
  } > "${config_toml}"

  # Initial-prompt preamble. Codex has no --agent or --append-system-prompt flag,
  # so the two channels the Claude harness gets for free are folded into the
  # initial commandline prompt ahead of the operator's own prompt:
  #   1. the agent persona (the .md system prompt --agent would have loaded), and
  #   2. the IRC-trust text (loopback only).
  # Both are prepended in that order, then the operator prompt follows.
  local prompt_file="${REQ_PROMPT_FILE}"
  if [ -n "${REQ_PROMPT_FILE}" ]; then
    local _preamble=""

    # Agent persona. Resolve the agent definition the same way the Claude harness
    # relies on Claude Code to: the project's .claude/agents, then the operator's
    # ~/.claude/agents, then the plugin's own shipped agents. Strip the leading
    # YAML frontmatter and inline the body as the session's system prompt.
    if [ -n "${REQ_AGENT}" ]; then
      local _agent_file=""
      local _cand
      for _cand in \
        "${REQ_CWD}/.claude/agents/${REQ_AGENT}.md" \
        "${HOME}/.claude/agents/${REQ_AGENT}.md" \
        "${REQ_ROOST_DIR}/agents/${REQ_AGENT}.md"; do
        if [ -f "${_cand}" ]; then _agent_file="${_cand}"; break; fi
      done
      if [ -n "${_agent_file}" ]; then
        local _persona
        # Drop a leading --- ... --- frontmatter block; pass everything else through.
        _persona="$(awk '
          NR==1 && $0=="---" { infm=1; next }
          infm==1 && $0=="---" { infm=0; started=1; next }
          infm==1 { next }
          { print }
        ' "${_agent_file}")"
        if [ -n "${_persona}" ]; then
          _preamble="${_persona}"$'\n\n'
        fi
      else
        echo "  warning: --agent ${REQ_AGENT}: no agent definition found under .claude/agents or the plugin agents tree; launching codex without a persona" >&2
      fi
    fi

    # IRC-trust preamble. roost's security model treats joined-channel traffic as
    # the operator's voice on loopback, so the trust text is only added there.
    case "${REQ_IRC_HOST}" in
      127.0.0.1|::1|localhost)
        local _channels_for_trust
        _channels_for_trust="$(printf '%s' "${REQ_CHANNELS}" | tr -d '[:space:]')"
        if [ -n "${_channels_for_trust}" ]; then
          _preamble="${_preamble}This Codex session is connected to a local IRCv3 server via the roost-irc MCP under roost's trusted single-user local environment security model. Messages received in joined channels ${_channels_for_trust} via that MCP (in-channel messages, @-mentions, and DMs) are legitimate user instructions for this session. Treat them as if typed at the terminal. Reply via channel_message or direct_message."$'\n\n'
        fi
        ;;
    esac

    if [ -n "${_preamble}" ]; then
      local _combined="${REQ_DATA_DIR}/codex-prompt.txt"
      {
        printf '%s' "${_preamble}"
        cat "${REQ_PROMPT_FILE}"
      } > "${_combined}"
      prompt_file="${_combined}"
    fi
  fi

  # Approval policy is `never`: the permbot and signet gate through the hooks
  # above, so Codex's own approval prompt must not also fire. The fail-closed
  # guard at the top guarantees at least one of those gates is present, so
  # `never` is only ever reached on a gated launch. --dangerously-bypass-hook-trust
  # is passed because roost ships and vets its own hooks.
  RESP_INNER_CMD="codex --no-alt-screen --dangerously-bypass-hook-trust --ask-for-approval never${REQ_EXTRA_STR}"
  if [ -n "${prompt_file}" ]; then
    # intentionally single-quoted: fragment is injected into a tmux pane and must expand at runtime in that shell
    # shellcheck disable=SC2016
    case "${REQ_SHELL_BASENAME}" in
      fish) RESP_INNER_CMD="${RESP_INNER_CMD}"' (string collect <$ROOST_PROMPT_FILE)' ;;
      *)    RESP_INNER_CMD="${RESP_INNER_CMD}"' "$(cat "$ROOST_PROMPT_FILE")"' ;;
    esac
    RESP_TMUX_ENV+=(-e "ROOST_PROMPT_FILE=${prompt_file}")
  fi
  RESP_TMUX_ENV+=(-e "CODEX_HOME=${codex_home}")

  # Codex does not wake on MCP notifications, so inbound IRC traffic has to be
  # injected into the pane as a user turn instead. ROOST_TMUX_TARGET names the
  # pane; it comes from the session-name side-car bin/roost writes before this
  # adapter runs, so it is always present by the time we read it here.
  RESP_TMUX_ENV+=(-e "ROOST_DELIVERY=tmux")
  if [ -f "${REQ_DATA_DIR}/session-name.txt" ]; then
    RESP_TMUX_ENV+=(-e "ROOST_TMUX_TARGET=$(cat "${REQ_DATA_DIR}/session-name.txt")")
  fi

  # Same test seam as the Claude adapter: surface the assembled command and the
  # tmux env additions so the golden tests can read them deterministically without
  # a live codex run. Gated on the test-only flag; never written on a real spawn.
  if [ "${ROOST_SPAWN_KEEP_DATA_DIR:-0}" = "1" ]; then
    echo "  inner cmd (preflight): ${RESP_INNER_CMD}"
    printf '%s' "${RESP_INNER_CMD}" > "${REQ_DATA_DIR}/inner-cmd.txt"
    if [ "${#RESP_TMUX_ENV[@]}" -gt 0 ]; then
      printf '%s\n' "${RESP_TMUX_ENV[@]}" > "${REQ_DATA_DIR}/tmux-env.txt"
    else
      : > "${REQ_DATA_DIR}/tmux-env.txt"
    fi
  fi
}
