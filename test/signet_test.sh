#!/usr/bin/env bash
# Tests for signet-eval layering: `.signet/` auto-detection wires a
# deterministic policy-gate hook ahead of the IRC permission relay on both
# PreToolUse and PermissionRequest; `--no-signet` opts out. Plain bash, no bats.
# Run: bash test/signet_test.sh
set -uo pipefail

ROOST_BIN="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )/bin/roost"
PASS=0
FAIL=0
TDIR=""

ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 ${2:+— $2}"; FAIL=$((FAIL+1)); }

setup() {
  TDIR="$(mktemp -d /tmp/roost-signet-test-XXXXXXXX)"
  trap 'rm -rf "$TDIR"' EXIT
}

teardown() {
  rm -rf "$TDIR"
  tmux kill-session -t "roost-testnick" 2>/dev/null || true
  trap - EXIT
  TDIR=""
}

# -- Test: .signet/ present → banner announces activation + hook wired ahead of relay --
setup
mkdir -p "$TDIR/.signet"
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn testnick --perm-irc --perm-target op --permission-mode acceptEdits --cwd "$TDIR" 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
if echo "$out" | grep -qF "signet-eval policy active (.signet/ found)" \
    && grep -qF 'signet-eval' "$data_dir/roost-settings.json" 2>/dev/null; then
  ok ".signet present: banner + signet hook wired"
else
  fail ".signet present: banner + signet hook wired" "out=$out settings=$(cat "$data_dir/roost-settings.json" 2>/dev/null)"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown

# -- Test: signet entry precedes the irc relay entry in PreToolUse --
setup
mkdir -p "$TDIR/.signet"
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn testnick --perm-irc --perm-target op --permission-mode acceptEdits --cwd "$TDIR" 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
settings="$(cat "$data_dir/roost-settings.json" 2>/dev/null)"
# signet's byte offset in the Bash matcher entry must be before irc-pretooluse-prompt's.
sig_pos=$(printf '%s' "$settings" | grep -boF 'signet-eval' | head -1 | cut -d: -f1)
irc_pos=$(printf '%s' "$settings" | grep -boF 'irc-pretooluse-prompt' | head -1 | cut -d: -f1)
if [ -n "$sig_pos" ] && [ -n "$irc_pos" ] && [ "$sig_pos" -lt "$irc_pos" ]; then
  ok "signet entry precedes irc relay entry (signet decides first)"
else
  fail "signet entry precedes irc relay entry" "sig=$sig_pos irc=$irc_pos"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown

# -- Test: --no-signet disables even when .signet/ present --
setup
mkdir -p "$TDIR/.signet"
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn testnick --no-signet --cwd "$TDIR" 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
if ! echo "$out" | grep -qF "signet-eval policy active" \
    && ! grep -qF 'signet-eval' "$data_dir/roost-settings.json" 2>/dev/null; then
  ok "--no-signet disables signet even with .signet/ present"
else
  fail "--no-signet disables signet even with .signet/ present" "out=$out"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown

# -- Test: no .signet/ → no signet wiring, unchanged behavior --
setup
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn testnick --cwd "$TDIR" 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
if ! grep -qF 'signet-eval' "$data_dir/roost-settings.json" 2>/dev/null; then
  ok "no .signet/: no signet wiring"
else
  fail "no .signet/: no signet wiring" "settings=$(cat "$data_dir/roost-settings.json" 2>/dev/null)"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
