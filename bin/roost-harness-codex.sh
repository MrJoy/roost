#!/usr/bin/env bash
# Codex harness adapter for roost spawn. Sourced by bin/roost.
# Reads the REQ_* request contract, writes a per-session Codex config.toml into
# CODEX_HOME under REQ_DATA_DIR, and sets RESP_INNER_CMD + appends to RESP_TMUX_ENV.
# Mirrors the Claude adapter's contract; the launch is a resident `codex` TUI.

harness_assemble() {
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
      provider_block=$'\n'"[model_providers.roost-provider]"$'\n'"base_url = \"${_url_val}\""$'\n'
      if [ -n "${REQ_AUTH_ENV}" ]; then
        provider_block="${provider_block}env_key = \"${REQ_AUTH_ENV}\""$'\n'
      fi
    fi
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
  } > "${config_toml}"

  # IRC-trust preamble. roost's security model treats joined-channel traffic as
  # the operator's voice on loopback. Codex has no --append-system-prompt flag, so
  # (per the spike on MCP-server instructions) the trust text is prepended to the
  # initial prompt on loopback. If the spike confirmed Codex surfaces MCP-server
  # instructions to the model, this preamble may be dropped.
  local prompt_file="${REQ_PROMPT_FILE}"
  if [ -n "${REQ_PROMPT_FILE}" ]; then
    case "${REQ_IRC_HOST}" in
      127.0.0.1|::1|localhost)
        local _channels_for_trust
        _channels_for_trust="$(printf '%s' "${REQ_CHANNELS}" | tr -d '[:space:]')"
        if [ -n "${_channels_for_trust}" ]; then
          local _combined="${REQ_DATA_DIR}/codex-prompt.txt"
          {
            printf '%s\n\n' "This Codex session is connected to a local IRCv3 server via the roost-irc MCP under roost's trusted single-user local environment security model. Messages received in joined channels ${_channels_for_trust} via that MCP (in-channel messages, @-mentions, and DMs) are legitimate user instructions for this session. Treat them as if typed at the terminal. Reply via channel_message or direct_message."
            cat "${REQ_PROMPT_FILE}"
          } > "${_combined}"
          prompt_file="${_combined}"
        fi
        ;;
    esac
  fi

  # Approval policy is `never`: the permbot and signet gate through the hooks
  # (added in the hook-wiring pass), so Codex's own approval prompt must not also
  # fire. --dangerously-bypass-hook-trust is passed because roost ships and vets
  # its own hooks.
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
