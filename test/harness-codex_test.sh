#!/usr/bin/env bash
# Golden tests for the Codex harness adapter. Spawns with ROOST_SPAWN_KEEP_DATA_DIR=1
# and asserts the staged side-cars are byte-correct. No live codex runs. Plain bash.
# Run: bash test/harness-codex_test.sh
set -uo pipefail
ROOST_BIN="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )/bin/roost"
PASS=0; FAIL=0; TDIR=""
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 ${2:+- $2}"; FAIL=$((FAIL+1)); }
setup() { TDIR="$(mktemp -d /tmp/roost-codex-test-XXXXXXXX)"; trap 'rm -rf "$TDIR"' EXIT; }
teardown() { rm -rf "$TDIR"; tmux kill-session -t "roost-testnick" 2>/dev/null || true; trap - EXIT; TDIR=""; }

# -- Test: codex config.toml carries model + roost-irc MCP entry; inner cmd is a codex invocation --
setup
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn testnick --harness codex --model gpt-5.1-codex --cwd "$TDIR" --prompt hello 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
cfg="$data_dir/codex-home/config.toml"
inner="$(cat "$data_dir/inner-cmd.txt" 2>/dev/null)"
if grep -qF 'model = "gpt-5.1-codex"' "$cfg" 2>/dev/null \
    && grep -qF '[mcp_servers.roost-irc]' "$cfg" 2>/dev/null \
    && echo "$inner" | grep -q '^codex ' \
    && echo "$inner" | grep -q -- '--dangerously-bypass-hook-trust' \
    && echo "$inner" | grep -q -- '--ask-for-approval never' \
    && grep -qF "CODEX_HOME=$data_dir/codex-home" "$data_dir/tmux-env.txt" 2>/dev/null; then
  ok "codex config.toml + inner cmd + CODEX_HOME staged"
else
  fail "codex config.toml + inner cmd + CODEX_HOME staged" "cfg=$(cat "$cfg" 2>/dev/null) inner=$inner env=$(cat "$data_dir/tmux-env.txt" 2>/dev/null)"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown

# -- Test: a base_url_env provider emits a [model_providers.roost-provider] backend block --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"alt":{"harness":"codex","model":"gpt-5.1-codex","base_url_env":"ALT_URL","auth_env":"ALT_TOK"}}}' > "$TDIR/.orchestrator/config.json"
out="$(ALT_URL="https://alt.example/v1" ALT_TOK="sk-test" ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn testnick --provider alt --cwd "$TDIR" --prompt hi 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
cfg="$data_dir/codex-home/config.toml"
if grep -qF '[model_providers.roost-provider]' "$cfg" 2>/dev/null \
    && grep -qF 'base_url = "https://alt.example/v1"' "$cfg" 2>/dev/null \
    && grep -qF 'env_key = "ALT_TOK"' "$cfg" 2>/dev/null \
    && grep -qF 'model_provider = "roost-provider"' "$cfg" 2>/dev/null; then
  ok "provider base_url_env/auth_env emit a codex model_providers block"
else
  fail "provider base_url_env/auth_env emit a codex model_providers block" "cfg=$(cat "$cfg" 2>/dev/null)"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown

# -- Test: --perm-irc wires PermissionRequest + PreToolUse permbot hook blocks --
setup
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn testnick --harness codex --model gpt-5.1-codex --perm-irc --perm-target op --cwd "$TDIR" --prompt hi 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
cfg="$data_dir/codex-home/config.toml"
if grep -qF '[[hooks.PermissionRequest]]' "$cfg" 2>/dev/null \
    && grep -qF 'hook-exec irc-permission-prompt' "$cfg" 2>/dev/null \
    && grep -qF '[[hooks.PreToolUse]]' "$cfg" 2>/dev/null \
    && grep -qF 'hook-exec irc-pretooluse-prompt' "$cfg" 2>/dev/null; then
  ok "codex --perm-irc wires permbot PermissionRequest + PreToolUse blocks"
else
  fail "codex --perm-irc wires permbot PermissionRequest + PreToolUse blocks" "cfg=$(cat "$cfg" 2>/dev/null)"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown

# -- Test: .signet/ present wires signet AHEAD of the permbot relay on both surfaces --
setup
mkdir -p "$TDIR/.signet" "$TDIR/.stubs"
cat > "$TDIR/.stubs/signet-eval" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TDIR/.stubs/signet-eval"
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 PATH="$TDIR/.stubs:$PATH" "${ROOST_BIN}" spawn testnick --harness codex --model gpt-5.1-codex --perm-irc --perm-target op --cwd "$TDIR" --prompt hi 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
cfg="$data_dir/codex-home/config.toml"
# signet-eval must appear before the irc relay in both PermissionRequest and PreToolUse.
pr_sig="$(grep -n 'signet-eval --permissionrequest' "$cfg" 2>/dev/null | head -1 | cut -d: -f1)"
pr_irc="$(grep -n 'hook-exec irc-permission-prompt' "$cfg" 2>/dev/null | head -1 | cut -d: -f1)"
ptu_sig="$(grep -n 'signet-eval --pretooluse' "$cfg" 2>/dev/null | head -1 | cut -d: -f1)"
ptu_irc="$(grep -n 'hook-exec irc-pretooluse-prompt' "$cfg" 2>/dev/null | head -1 | cut -d: -f1)"
if [ -n "$pr_sig" ] && [ -n "$pr_irc" ] && [ "$pr_sig" -lt "$pr_irc" ] \
    && [ -n "$ptu_sig" ] && [ -n "$ptu_irc" ] && [ "$ptu_sig" -lt "$ptu_irc" ]; then
  ok "codex signet precedes irc relay on both PermissionRequest and PreToolUse"
else
  fail "codex signet precedes irc relay on both PermissionRequest and PreToolUse" "cfg=$(cat "$cfg" 2>/dev/null)"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown

# -- Test: no .signet/ -> no signet hook in the codex config --
setup
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn testnick --harness codex --model gpt-5.1-codex --perm-irc --perm-target op --cwd "$TDIR" --prompt hi 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
cfg="$data_dir/codex-home/config.toml"
if ! grep -qF 'signet-eval' "$cfg" 2>/dev/null; then
  ok "codex no .signet/: no signet hook wired"
else
  fail "codex no .signet/: no signet hook wired" "cfg=$(cat "$cfg" 2>/dev/null)"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown

echo ""; echo "Results: ${PASS} passed, ${FAIL} failed"; [ "$FAIL" -eq 0 ]
