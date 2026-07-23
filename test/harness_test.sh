#!/usr/bin/env bash
# Tests for `roost spawn --harness`. Plain bash, no bats.
# Run: bash test/harness_test.sh
set -uo pipefail
ROOST_BIN="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )/bin/roost"
PASS=0; FAIL=0; TDIR=""
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 ${2:+- $2}"; FAIL=$((FAIL+1)); }
setup() { TDIR="$(mktemp -d /tmp/roost-harness-test-XXXXXXXX)"; trap 'rm -rf "$TDIR"' EXIT; }
teardown() { rm -rf "$TDIR"; tmux kill-session -t "roost-testnick" 2>/dev/null || true; trap - EXIT; TDIR=""; }

# -- Test: default harness is claude, echoed in banner --
setup
out="$("${ROOST_BIN}" spawn testnick --cwd "$TDIR" 2>&1 || true)"
if echo "$out" | grep -q "harness: claude"; then
  ok "default harness claude echoed in banner"
else
  fail "default harness claude echoed in banner" "out=$out"
fi
teardown

# -- Test: invalid harness is rejected --
setup
err="$("${ROOST_BIN}" spawn testnick --harness bogus --cwd "$TDIR" 2>&1)"; ec=$?
if [ "$ec" -ne 0 ] && echo "$err" | grep -q "unknown harness 'bogus'" && echo "$err" | grep -q "claude, codex"; then
  ok "invalid harness rejected with clear message"
else
  fail "invalid harness rejected with clear message" "ec=$ec err=$err"
fi
teardown

# -- Test: codex harness assembles a codex invocation --
# --perm-irc satisfies the fail-closed gate so the spawn is not refused.
setup
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn testnick --harness codex --model gpt-5.1-codex --perm-irc --perm-target op --cwd "$TDIR" --prompt hi 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
inner="$(cat "$data_dir/inner-cmd.txt" 2>/dev/null)"
if echo "$inner" | grep -q '^codex ' && echo "$inner" | grep -q -- '--dangerously-bypass-hook-trust'; then
  ok "codex harness assembles a codex invocation"
else
  fail "codex harness assembles a codex invocation" "inner=$inner"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown

echo ""; echo "Results: ${PASS} passed, ${FAIL} failed"; [ "$FAIL" -eq 0 ]
