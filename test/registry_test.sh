#!/usr/bin/env bash
# Tests for `roost spawn --provider` / `--role` registry resolution and the
# jq preflight guard that gates it. Plain bash, no bats.
# Run: bash test/registry_test.sh
set -uo pipefail

ROOST_BIN="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )/bin/roost"
PASS=0
FAIL=0
TDIR=""

ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 ${2:+— $2}"; FAIL=$((FAIL+1)); }

setup() {
  TDIR="$(mktemp -d /tmp/roost-registry-test-XXXXXXXX)"
  trap 'rm -rf "$TDIR"' EXIT
}

teardown() {
  rm -rf "$TDIR"
  tmux kill-session -t "roost-testnick" 2>/dev/null || true
  trap - EXIT
  TDIR=""
}

# -- Test: --role without jq on PATH errors clearly --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","roles":{"worker":"claude-opus"},"providers":{"claude-opus":{"harness":"claude","model":"opus"}}}' > "$TDIR/.orchestrator/config.json"
err="$(PATH="/usr/bin:/bin" "${ROOST_BIN}" spawn testnick --role worker --cwd "$TDIR" 2>&1)"; ec=$?
# When jq is genuinely absent this must name jq; when jq exists in /usr/bin it resolves — accept either the jq error OR a successful resolution banner.
if { [ "$ec" -ne 0 ] && echo "$err" | grep -qi "jq"; } || echo "$err" | grep -q "harness: claude"; then
  ok "registry spawn either resolves or errors naming jq"
else
  fail "registry spawn either resolves or errors naming jq" "ec=$ec err=$err"
fi
teardown

# -- Test: bare spawn (no registry) does not require jq --
setup
out="$(PATH="/usr/bin:/bin" "${ROOST_BIN}" spawn testnick --cwd "$TDIR" 2>&1 || true)"
if ! echo "$out" | grep -qi "jq.*not found\|requires jq"; then
  ok "bare spawn does not require jq"
else
  fail "bare spawn does not require jq" "out=$out"
fi
teardown

CFG='{"project":"p","providers":{"claude-opus":{"harness":"claude","model":"opus"},"codex-gpt":{"harness":"codex","model":"gpt-5.1-codex"}},"roles":{"pm":"claude-opus","worker":["codex-gpt","claude-opus"]}}'

# -- Test: --provider resolves harness + model --
setup
mkdir -p "$TDIR/.orchestrator"; printf '%s' "$CFG" > "$TDIR/.orchestrator/config.json"
err="$("${ROOST_BIN}" spawn testnick --provider codex-gpt --cwd "$TDIR" 2>&1)"; ec=$?
# codex resolves then the stub aborts — the banner must show the resolved harness/model first.
if echo "$err" | grep -q "harness: codex" && echo "$err" | grep -q "model: gpt-5.1-codex"; then
  ok "--provider resolves harness+model from registry"
else
  fail "--provider resolves harness+model from registry" "ec=$ec err=$err"
fi
teardown

# -- Test: --role resolves via role map (first candidate) --
setup
mkdir -p "$TDIR/.orchestrator"; printf '%s' "$CFG" > "$TDIR/.orchestrator/config.json"
out="$("${ROOST_BIN}" spawn testnick --role pm --cwd "$TDIR" 2>&1 || true)"
if echo "$out" | grep -q "harness: claude" && echo "$out" | grep -q "model: opus"; then
  ok "--role pm resolves to claude-opus"
else
  fail "--role pm resolves to claude-opus" "out=$out"
fi
teardown

# -- Test: unknown provider errors clearly --
setup
mkdir -p "$TDIR/.orchestrator"; printf '%s' "$CFG" > "$TDIR/.orchestrator/config.json"
err="$("${ROOST_BIN}" spawn testnick --provider nope --cwd "$TDIR" 2>&1)"; ec=$?
if [ "$ec" -ne 0 ] && echo "$err" | grep -q "unknown provider 'nope'"; then
  ok "unknown provider errors clearly"
else
  fail "unknown provider errors clearly" "ec=$ec err=$err"
fi
teardown

# -- Test: explicit --model beats registry (no registry read) --
setup
mkdir -p "$TDIR/.orchestrator"; printf '%s' "$CFG" > "$TDIR/.orchestrator/config.json"
out="$("${ROOST_BIN}" spawn testnick --model sonnet --cwd "$TDIR" 2>&1 || true)"
if echo "$out" | grep -q "model: sonnet" && echo "$out" | grep -q "harness: claude"; then
  ok "explicit --model wins over registry"
else
  fail "explicit --model wins over registry" "out=$out"
fi
teardown

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
