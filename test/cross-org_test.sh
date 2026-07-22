#!/usr/bin/env bash
# Tests for recording the author-org for an issue at worker spawn, into
# per-issue provider-assignments.json state. Plain bash, no bats.
# Run: bash test/cross-org_test.sh
set -uo pipefail

ROOST_BIN="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )/bin/roost"
PASS=0
FAIL=0
TDIR=""

ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 ${2:+— $2}"; FAIL=$((FAIL+1)); }

setup() {
  TDIR="$(mktemp -d /tmp/roost-crossorg-test-XXXXXXXX)"
  trap 'rm -rf "$TDIR"' EXIT
}

teardown() {
  rm -rf "$TDIR"
  tmux kill-session -t "roost-p-worker-42" 2>/dev/null || true
  tmux kill-session -t "roost-p-worker-99" 2>/dev/null || true
  trap - EXIT
  TDIR=""
}

CFG='{"project":"p","providers":{"claude-opus":{"harness":"claude","model":"opus"},"gpt":{"harness":"codex","model":"gpt-5.1-codex"}},"roles":{"worker":"gpt","reviewer":["claude-opus","gpt"]}}'

# -- Test: worker spawn records author-org into provider-assignments.json --
setup
mkdir -p "$TDIR/.orchestrator"; printf '%s' "$CFG" > "$TDIR/.orchestrator/config.json"
# gpt resolves to codex which stubs-out at assemble, but recording happens before assemble.
"${ROOST_BIN}" spawn p-worker-42 --role worker --issue 42 --cwd "$TDIR" >/dev/null 2>&1 || true
if [ -f "$TDIR/.orchestrator/provider-assignments.json" ] \
    && jq -e '.["42"].org == "openai"' "$TDIR/.orchestrator/provider-assignments.json" >/dev/null; then
  ok "worker spawn records author-org openai for issue 42"
else
  fail "worker spawn records author-org openai for issue 42" "$(cat "$TDIR/.orchestrator/provider-assignments.json" 2>/dev/null)"
fi
teardown

# -- Test: issue key parsed from channel when --issue omitted --
setup
mkdir -p "$TDIR/.orchestrator"; printf '%s' "$CFG" > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-worker-99 --role worker -c '#p-issue-99' --cwd "$TDIR" >/dev/null 2>&1 || true
if jq -e '.["99"].org == "openai"' "$TDIR/.orchestrator/provider-assignments.json" >/dev/null 2>&1; then
  ok "issue key parsed from #p-issue-99 channel"
else
  fail "issue key parsed from #p-issue-99 channel" "$(cat "$TDIR/.orchestrator/provider-assignments.json" 2>/dev/null)"
fi
teardown

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
