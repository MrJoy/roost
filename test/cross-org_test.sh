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
  tmux kill-session -t "roost-p-worker-7" 2>/dev/null || true
  tmux kill-session -t "roost-p-reviewer-7" 2>/dev/null || true
  tmux kill-session -t "roost-p-reviewer-13" 2>/dev/null || true
  tmux kill-session -t "roost-p-worker-8" 2>/dev/null || true
  tmux kill-session -t "roost-p-reviewer-8" 2>/dev/null || true
  tmux kill-session -t "roost-p-worker-9" 2>/dev/null || true
  tmux kill-session -t "roost-p-reviewer-9" 2>/dev/null || true
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

# -- Test: reviewer auto-picks the cross-org candidate --
setup
mkdir -p "$TDIR/.orchestrator"; printf '%s' "$CFG" > "$TDIR/.orchestrator/config.json"
# Author is openai (worker=gpt). reviewer candidates [claude-opus (anthropic), gpt (openai)].
# Gate must pick claude-opus (anthropic != openai) even though... it is already first here;
# reorder to prove selection: put gpt first.
printf '{"project":"p","providers":{"claude-opus":{"harness":"claude","model":"opus"},"gpt":{"harness":"codex","model":"gpt-5.1-codex"}},"roles":{"worker":"gpt","reviewer":["gpt","claude-opus"]}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-worker-7 --role worker --issue 7 --cwd "$TDIR" >/dev/null 2>&1 || true
out="$("${ROOST_BIN}" spawn p-reviewer-7 --role reviewer --issue 7 --cwd "$TDIR" 2>&1 || true)"
if echo "$out" | grep -q "harness: claude" && echo "$out" | grep -q "model: opus"; then
  ok "reviewer gate skips same-org gpt, picks cross-org claude-opus"
else
  fail "reviewer gate skips same-org gpt, picks cross-org claude-opus" "out=$out"
fi
teardown

# -- Test: reviewer with no recorded author errors --
setup
mkdir -p "$TDIR/.orchestrator"; printf '%s' "$CFG" > "$TDIR/.orchestrator/config.json"
err="$("${ROOST_BIN}" spawn p-reviewer-13 --role reviewer --issue 13 --cwd "$TDIR" 2>&1)"; ec=$?
if [ "$ec" -ne 0 ] && echo "$err" | grep -q "no recorded author for issue 13"; then
  ok "reviewer without recorded author errors, tells you to spawn worker first"
else
  fail "reviewer without recorded author errors, tells you to spawn worker first" "ec=$ec err=$err"
fi
teardown

# -- Test: all-same-org reviewer set hard-fails without override --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"}},"roles":{"worker":"c1","reviewer":["c1","c2"]}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-worker-8 --role worker --issue 8 --cwd "$TDIR" >/dev/null 2>&1 || true
err="$("${ROOST_BIN}" spawn p-reviewer-8 --role reviewer --issue 8 --cwd "$TDIR" 2>&1)"; ec=$?
if [ "$ec" -ne 0 ] && echo "$err" | grep -q "cross-org" && echo "$err" | grep -q "allow-same-org"; then
  ok "all-same-org reviewer set hard-fails, names the override"
else
  fail "all-same-org reviewer set hard-fails, names the override" "ec=$ec err=$err"
fi
teardown

# -- Test: --allow-same-org bypasses and records the override --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"}},"roles":{"worker":"c1","reviewer":["c2"]}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-worker-9 --role worker --issue 9 --cwd "$TDIR" >/dev/null 2>&1 || true
out="$("${ROOST_BIN}" spawn p-reviewer-9 --role reviewer --issue 9 --allow-same-org "only reviewer available" --cwd "$TDIR" 2>&1 || true)"
if echo "$out" | grep -qi "override" \
    && jq -e '.["9"].override == true and .["9"].reason == "only reviewer available"' "$TDIR/.orchestrator/provider-assignments.json" >/dev/null; then
  ok "--allow-same-org proceeds and records override + reason"
else
  fail "--allow-same-org proceeds and records override + reason" "out=$out asn=$(cat "$TDIR/.orchestrator/provider-assignments.json" 2>/dev/null)"
fi
teardown

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
