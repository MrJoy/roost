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
fail() { echo "FAIL: $1 ${2:+- $2}"; FAIL=$((FAIL+1)); }

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
  tmux kill-session -t "roost-p-worker-14" 2>/dev/null || true
  tmux kill-session -t "roost-p-reviewer-14" 2>/dev/null || true
  tmux kill-session -t "roost-p-worker-8" 2>/dev/null || true
  tmux kill-session -t "roost-p-reviewer-8" 2>/dev/null || true
  tmux kill-session -t "roost-p-worker-9" 2>/dev/null || true
  tmux kill-session -t "roost-p-reviewer-9" 2>/dev/null || true
  tmux kill-session -t "roost-p-reviewer-9b" 2>/dev/null || true
  tmux kill-session -t "roost-p-builder-20" 2>/dev/null || true
  tmux kill-session -t "roost-p-auditor-20" 2>/dev/null || true
  tmux kill-session -t "roost-p-builder-21" 2>/dev/null || true
  tmux kill-session -t "roost-p-scout-22" 2>/dev/null || true
  tmux kill-session -t "roost-p-x-30" 2>/dev/null || true
  tmux kill-session -t "roost-p-worker-30" 2>/dev/null || true
  tmux kill-session -t "roost-p-x-31" 2>/dev/null || true
  tmux kill-session -t "roost-p-worker-31" 2>/dev/null || true
  tmux kill-session -t "roost-p-x-32a" 2>/dev/null || true
  tmux kill-session -t "roost-p-x-32b" 2>/dev/null || true
  tmux kill-session -t "roost-p-x-33" 2>/dev/null || true
  tmux kill-session -t "roost-p-both-40" 2>/dev/null || true
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
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"},"gpt":{"harness":"codex","model":"gpt-5.1-codex"}},"roles":{"worker":"c1","reviewer":["c1","c2"]}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-worker-8 --role worker --issue 8 --cwd "$TDIR" >/dev/null 2>&1 || true
err="$("${ROOST_BIN}" spawn p-reviewer-8 --role reviewer --issue 8 --cwd "$TDIR" 2>&1)"; ec=$?
if [ "$ec" -ne 0 ] && echo "$err" | grep -q "cross-org" && echo "$err" | grep -q "allow-same-org"; then
  ok "all-same-org reviewer set hard-fails, names the override"
else
  fail "all-same-org reviewer set hard-fails, names the override" "ec=$ec err=$err"
fi
teardown

# -- Test: single-org registry allows a same-org reviewer with no error, no override --
setup
mkdir -p "$TDIR/.orchestrator"
# Registry has exactly one org (all anthropic). There is no cross-org choice to
# make, so the gate is a silent no-op: no error, no --allow-same-org, no override record.
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"}},"roles":{"worker":"c1","reviewer":["c2"]}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-worker-14 --role worker --issue 14 --cwd "$TDIR" >/dev/null 2>&1 || true
out="$("${ROOST_BIN}" spawn p-reviewer-14 --role reviewer --issue 14 --cwd "$TDIR" 2>&1 || true)"
asn="$TDIR/.orchestrator/provider-assignments.json"
if echo "$out" | grep -q "harness: claude" && echo "$out" | grep -q "model: sonnet" \
    && ! echo "$out" | grep -qi "cross-org" \
    && ! { jq -e '.["14#override"]' "$asn" >/dev/null 2>&1; }; then
  ok "single-org registry allows same-org reviewer, no error, no override record"
else
  fail "single-org registry allows same-org reviewer, no error, no override record" "out=$out asn=$(cat "$asn" 2>/dev/null)"
fi
teardown

# -- Test: --allow-same-org bypasses and records the override --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"},"gpt":{"harness":"codex","model":"gpt-5.1-codex"}},"roles":{"worker":"c1","reviewer":["c2"]}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-worker-9 --role worker --issue 9 --cwd "$TDIR" >/dev/null 2>&1 || true
out="$("${ROOST_BIN}" spawn p-reviewer-9 --role reviewer --issue 9 --allow-same-org "only reviewer available" --cwd "$TDIR" 2>&1 || true)"
"${ROOST_BIN}" spawn p-reviewer-9b --role reviewer --issue 9 --allow-same-org "second pass" --cwd "$TDIR" >/dev/null 2>&1 || true
asn="$TDIR/.orchestrator/provider-assignments.json"
# The override array under "9#override" preserves every override (newest
# appended); the worker's author entry at "9" survives untouched so a later
# re-review still reads the real author.
if echo "$out" | grep -qi "override" \
    && jq -e '.["9#override"] | type == "array" and length == 2' "$asn" >/dev/null \
    && jq -e '.["9#override"][0].kind == "reviewer-override" and .["9#override"][0].reason == "only reviewer available"' "$asn" >/dev/null \
    && jq -e '.["9#override"][1].reason == "second pass"' "$asn" >/dev/null \
    && jq -e '.["9"].role == "worker" and .["9"].provider == "c1" and .["9"].override == false' "$asn" >/dev/null; then
  ok "--allow-same-org appends override records; worker author survives"
else
  fail "--allow-same-org appends override records; worker author survives" "out=$out asn=$(cat "$asn" 2>/dev/null)"
fi
teardown

# -- Test: a custom-named review role is gated (not just "reviewer") --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"},"gpt":{"harness":"codex","model":"gpt-5.1-codex"}},"roles":{"builder":{"candidates":["c1"],"author":true},"auditor":{"candidates":["c1","c2"],"review":true}}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-builder-20 --role builder --issue 20 --cwd "$TDIR" >/dev/null 2>&1 || true
err="$("${ROOST_BIN}" spawn p-auditor-20 --role auditor --issue 20 --cwd "$TDIR" 2>&1)"; ec=$?
# author c1 is anthropic; auditor candidates c1,c2 are both anthropic -> gate hard-fails.
if [ "$ec" -ne 0 ] && echo "$err" | grep -q "cross-org" && echo "$err" | grep -q "allow-same-org"; then
  ok "custom-named review role 'auditor' is gated"
else
  fail "custom-named review role 'auditor' is gated" "ec=$ec err=$err"
fi
teardown

# -- Test: a custom-named author role records authorship (not just "worker") --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"gpt":{"harness":"codex","model":"gpt-5.1-codex"}},"roles":{"builder":{"candidates":["gpt"],"author":true}}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-builder-21 --role builder --issue 21 --cwd "$TDIR" >/dev/null 2>&1 || true
if jq -e '.["21"].org == "openai" and .["21"].role == "builder"' "$TDIR/.orchestrator/provider-assignments.json" >/dev/null 2>&1; then
  ok "custom-named author role 'builder' records author-org"
else
  fail "custom-named author role 'builder' records author-org" "$(cat "$TDIR/.orchestrator/provider-assignments.json" 2>/dev/null)"
fi
teardown

# -- Test: a neutral role (neither author nor review) records nothing and is ungated --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"}},"roles":{"scout":["c1","c2"]}}' > "$TDIR/.orchestrator/config.json"
out="$("${ROOST_BIN}" spawn p-scout-22 --role scout --issue 22 --cwd "$TDIR" 2>&1 || true)"
asn="$TDIR/.orchestrator/provider-assignments.json"
# scout resolves to its first candidate with no gate and writes no author record.
if echo "$out" | grep -q "harness: claude" \
    && ! { [ -f "$asn" ] && jq -e '.["22"]' "$asn" >/dev/null 2>&1; }; then
  ok "neutral role 'scout' is ungated and records nothing"
else
  fail "neutral role 'scout' is ungated and records nothing" "out=$out asn=$(cat "$asn" 2>/dev/null)"
fi
teardown

# -- Test: --provider path for a known issue with a recorded author appends #bypass --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"}},"roles":{"worker":"c1"}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-worker-30 --role worker --issue 30 --cwd "$TDIR" >/dev/null 2>&1 || true
out="$("${ROOST_BIN}" spawn p-x-30 --provider c2 --issue 30 --cwd "$TDIR" 2>&1 || true)"
asn="$TDIR/.orchestrator/provider-assignments.json"
if echo "$out" | grep -qi "gate not evaluated" \
    && jq -e '.["30#bypass"] | type == "array" and length == 1 and .[0].kind == "explicit-bypass" and .[0].provider == "c2"' "$asn" >/dev/null 2>&1; then
  ok "--provider path for a known issue appends a #bypass audit record"
else
  fail "--provider path for a known issue appends a #bypass audit record" "out=$out asn=$(cat "$asn" 2>/dev/null)"
fi
teardown

# -- Test: explicit --model for a known issue appends #bypass --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"}},"roles":{"worker":"c1"}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-worker-31 --role worker --issue 31 --cwd "$TDIR" >/dev/null 2>&1 || true
out="$("${ROOST_BIN}" spawn p-x-31 --model sonnet --issue 31 --cwd "$TDIR" 2>&1 || true)"
asn="$TDIR/.orchestrator/provider-assignments.json"
if echo "$out" | grep -qi "gate not evaluated" \
    && jq -e '.["31#bypass"][0].kind == "explicit-bypass" and .["31#bypass"][0].org == "anthropic"' "$asn" >/dev/null 2>&1; then
  ok "explicit --model for a known issue appends a #bypass audit record"
else
  fail "explicit --model for a known issue appends a #bypass audit record" "out=$out asn=$(cat "$asn" 2>/dev/null)"
fi
teardown

# -- Test: #bypass record carries the launched model and harness (--provider) --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"}},"roles":{"worker":"c1"}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-worker-30 --role worker --issue 30 --cwd "$TDIR" >/dev/null 2>&1 || true
"${ROOST_BIN}" spawn p-x-30 --provider c2 --issue 30 --cwd "$TDIR" >/dev/null 2>&1 || true
asn="$TDIR/.orchestrator/provider-assignments.json"
if jq -e '.["30#bypass"][0].model == "sonnet" and .["30#bypass"][0].harness == "claude"' "$asn" >/dev/null 2>&1; then
  ok "#bypass (--provider) records launched model + harness"
else
  fail "#bypass (--provider) records launched model + harness" "asn=$(cat "$asn" 2>/dev/null)"
fi
teardown

# -- Test: #bypass record carries the launched model and harness (explicit --model) --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"}},"roles":{"worker":"c1"}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-worker-31 --role worker --issue 31 --cwd "$TDIR" >/dev/null 2>&1 || true
"${ROOST_BIN}" spawn p-x-31 --model sonnet --issue 31 --cwd "$TDIR" >/dev/null 2>&1 || true
asn="$TDIR/.orchestrator/provider-assignments.json"
if jq -e '.["31#bypass"][0].model == "sonnet" and .["31#bypass"][0].harness == "claude"' "$asn" >/dev/null 2>&1; then
  ok "#bypass (explicit --model) records launched model + harness"
else
  fail "#bypass (explicit --model) records launched model + harness" "asn=$(cat "$asn" 2>/dev/null)"
fi
teardown

# -- Test (NEGATIVE): fully-explicit worker+reviewer leaves no #bypass mark --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"}},"roles":{}}' > "$TDIR/.orchestrator/config.json"
# Worker spawned explicitly (--provider), so NO author is recorded; the later
# explicit reviewer spawn therefore has no recorded author to trigger against.
"${ROOST_BIN}" spawn p-x-32a --provider c1 --issue 32 --cwd "$TDIR" >/dev/null 2>&1 || true
"${ROOST_BIN}" spawn p-x-32b --provider c2 --issue 32 --cwd "$TDIR" >/dev/null 2>&1 || true
asn="$TDIR/.orchestrator/provider-assignments.json"
# The audit is inherently limited: with no recorded author, there is nothing to
# audit against, so no #bypass record exists. This pins that it does not
# over-trigger on an unknown issue.
if ! { [ -f "$asn" ] && jq -e '.["32#bypass"]' "$asn" >/dev/null 2>&1; } \
    && ! { [ -f "$asn" ] && jq -e '.["32"]' "$asn" >/dev/null 2>&1; }; then
  ok "fully-explicit worker+reviewer leaves no author and no #bypass mark"
else
  fail "fully-explicit worker+reviewer leaves no author and no #bypass mark" "asn=$(cat "$asn" 2>/dev/null)"
fi
teardown

# -- Test: --provider with no recorded author writes no #bypass --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"c2":{"harness":"claude","model":"sonnet"}},"roles":{}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-x-33 --provider c2 --issue 33 --cwd "$TDIR" >/dev/null 2>&1 || true
asn="$TDIR/.orchestrator/provider-assignments.json"
if ! { [ -f "$asn" ] && jq -e '.["33#bypass"]' "$asn" >/dev/null 2>&1; }; then
  ok "--provider with no recorded author writes no #bypass"
else
  fail "--provider with no recorded author writes no #bypass" "asn=$(cat "$asn" 2>/dev/null)"
fi
teardown


# -- Test: a role declaring both author and review fails fast --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"}},"roles":{"both":{"candidates":["c1"],"author":true,"review":true}}}' > "$TDIR/.orchestrator/config.json"
err="$("${ROOST_BIN}" spawn p-both-40 --role both --issue 40 --cwd "$TDIR" 2>&1)"; ec=$?
if [ "$ec" -ne 0 ] && echo "$err" | grep -q "role 'both' declares both author and review"; then
  ok "role declaring both author and review fails fast"
else
  fail "role declaring both author and review fails fast" "ec=$ec err=$err"
fi
teardown

# -- Test: name-default collision attributes the conflict to the right source --
setup
mkdir -p "$TDIR/.orchestrator"
# A role named "worker" that declares review:true inherits author:true from its
# name default. The error must say review was declared and author inherited,
# and point at the "author: false" remedy, not claim both were declared.
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"}},"roles":{"worker":{"candidates":["c1"],"review":true}}}' > "$TDIR/.orchestrator/config.json"
err="$("${ROOST_BIN}" spawn p-worker-41 --role worker --issue 41 --cwd "$TDIR" 2>&1)"; ec=$?
if [ "$ec" -ne 0 ] \
    && echo "$err" | grep -q "declares review and inherits author from its name" \
    && echo "$err" | grep -q "author: false" \
    && ! echo "$err" | grep -q "declares both author and review"; then
  ok "name-default collision attributes review-declared, author-inherited"
else
  fail "name-default collision attributes review-declared, author-inherited" "ec=$ec err=$err"
fi
teardown

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
