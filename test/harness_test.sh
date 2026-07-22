#!/usr/bin/env bash
# Tests for `roost spawn --harness`. Plain bash, no bats.
# Run: bash test/harness_test.sh
set -uo pipefail
ROOST_BIN="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )/bin/roost"
PASS=0; FAIL=0; TDIR=""
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 ${2:+— $2}"; FAIL=$((FAIL+1)); }
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

# -- Test: codex harness fails fast with a spec pointer --
setup
err="$("${ROOST_BIN}" spawn testnick --harness codex --cwd "$TDIR" 2>&1)"; ec=$?
if [ "$ec" -ne 0 ] \
    && echo "$err" | grep -q "codex harness not yet implemented" \
    && echo "$err" | grep -q "docs/superpowers/specs"; then
  ok "codex harness fails fast with follow-on spec pointer"
else
  fail "codex harness fails fast with follow-on spec pointer" "ec=$ec err=$err"
fi
teardown

echo ""; echo "Results: ${PASS} passed, ${FAIL} failed"; [ "$FAIL" -eq 0 ]
