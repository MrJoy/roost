# Cross-Org Enforcement Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move roost's cross-org review gate and author-recording off the hard-coded role names `reviewer`/`worker` onto config-declared role properties, and add an auditable bypass record for explicit-launch-target spawns that touch a known issue.

**Architecture:** Roles in `.orchestrator/config.json` gain an object form `{"candidates": [...], "author": true, "review": true}` alongside the existing bare string/array form. Two new predicate functions in `bin/roost-registry.sh` decide whether a role records authorship or is gated, with built-in name defaults (`worker`→author, `reviewer`→review) that apply even in bare form. The spawn dispatch in `bin/roost` calls those predicates instead of comparing role strings. Explicit launch-target spawns (`--provider`, explicit `--model`/`--harness`) that target a known issue with a recorded author append a `#bypass` audit record. Override and bypass records become append-safe arrays.

**Tech Stack:** Bash (`bin/roost`, `bin/roost-registry.sh`), `jq` for config/state reads, plain-bash test suites (`test/registry_test.sh`, `test/cross-org_test.sh`), `shellcheck`.

## Global Constraints

- **In-tree comments are timeless.** No PR/issue/version references in code or doc comments. Systems of record (commit messages, this plan) keep refs; in-tree text does not.
- **No em-dashes** in new code, docs, or comments. Read each new sentence aloud; if it has more than one connector, split it.
- **shellcheck clean per file.** `test/shellcheck.test.ts` lints each `bin/` file individually with bare `shellcheck`. Match the existing `# shellcheck` directive style already in `roost-registry.sh` (the `SC2034` disable for `RESOLVED_*`).
- **Do not regress `spawn_test.sh`** (51 golden byte-identical tests) or any existing suite. Run `script/run-and-tail bash test/<suite>.sh`; the exit code is the only honest signal. Never pipe `bun test`/suites through `tail`/`head`/`grep`.
- **Config data model (exact):** a role value in `.roles[name]` is one of:
  - a string: candidates = `[that string]`, no properties;
  - an array: candidates = that array, no properties;
  - an object `{"candidates": <string|array>, "author": <bool>, "review": <bool>}`: candidates from `.candidates`, properties from `.author`/`.review` when present.
- **Built-in defaults apply by name, even in bare form:** a role literally named `worker` is an author role unless an object explicitly sets `"author": false`; a role literally named `reviewer` is a review role unless an object explicitly sets `"review": false`. So `"reviewer": ["c2"]` stays gated (Phase 1 zero-config preserved); renaming is the only way to ungate.
- **The three `--role` outcomes are crisp:** a review role runs the gate; an author role records authorship; a role that is neither does neither.
- **Bypass-audit trigger is narrow:** fires only when the launch target was chosen explicitly (`--provider`, explicit `--model`/`--harness`) AND an issue key is derivable AND an author is already recorded for that issue. `--agent` is out of scope (model comes from agent frontmatter, a separate path).
- **`--allow-same-org` semantics are unchanged:** it stays scoped to the review-role gate. This redesign does NOT overload it onto the explicit path. The explicit path is warn-plus-audit only, never require-ack, never refuse.
- **Bare-spawn invariant holds:** a spawn with no `--provider`/`--role` and no `.orchestrator/provider-assignments.json` must never require `jq`. The bypass-audit engages `jq` only when that state file already exists; if the file exists but `jq` is absent, it warns and skips the audit rather than failing.
- **Commit discipline:** every commit carries the Human-Claude Interaction Log and the `🤖 Generated with Claude Code` / `Co-Authored-By: Claude <noreply@anthropic.com>` trailer. Work stays on `feat/multi-provider-harnesses`.

---

## File Structure

- `bin/roost-registry.sh` — registry/policy module (sourced by `bin/roost`). Gains `registry_role_is_author`, `registry_role_is_review`, `assignment_append`, `bypass_audit`; `registry_role_candidates` learns the object form; `policy_gate_reviewer`'s override write becomes append-safe.
- `bin/roost` — spawn dispatch (~809-866) and `spawn --help` heredoc (~294-307). `issue_key` derivation hoists above the registry block; the gate/record branches call the new predicates; a bypass-audit step covers explicit `--model`/`--harness`.
- `test/registry_test.sh` — new coverage for object-form candidates and the two predicates.
- `test/cross-org_test.sh` — updated `#override` assertions (array form), new coverage for custom-named review/author roles, neutral roles, and the bypass-audit (including the fully-explicit negative case).
- `skills/roost/SKILL.md`, `README.md`, `agents/project-manager.md`, `agents/associate-pm.md` — doc surfaces for the cross-org rule and role shape, kept verbatim per the canonical-wording rule.

---

### Task 1: Role-property predicates and object-form candidates

**Files:**
- Modify: `bin/roost-registry.sh` (`registry_role_candidates` ~46-55; add two functions after it)
- Test: `test/registry_test.sh`

**Interfaces:**
- Consumes: `_registry_config_path` (existing), `.orchestrator/config.json` `.roles` map.
- Produces:
  - `registry_role_candidates <role>` — prints candidate provider names one per line; now also unwraps the object form.
  - `registry_role_is_author <role>` — exits 0 if the role records authorship, 1 otherwise.
  - `registry_role_is_review <role>` — exits 0 if the role is gated, 1 otherwise.

- [ ] **Step 1: Write failing tests for object-form candidates and the predicates**

Append to `test/registry_test.sh` (before the final `echo`/results block; follow the file's existing `setup`/`teardown`/`ok`/`fail` and config-writing pattern). Source `roost-registry.sh` the same way the existing tests in that file do:

```bash
# -- Test: object-form role unwraps .candidates (array) --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"a":{"harness":"claude","model":"opus"},"b":{"harness":"codex","model":"gpt-5.1-codex"}},"roles":{"auditor":{"candidates":["a","b"],"review":true}}}' > "$TDIR/.orchestrator/config.json"
out="$(cd "$TDIR" && source "$REG" && registry_role_candidates auditor)"
if [ "$out" = "$(printf 'a\nb')" ]; then
  ok "object-form role unwraps .candidates array in order"
else
  fail "object-form role unwraps .candidates array in order" "out=$out"
fi
teardown

# -- Test: object-form role with a string .candidates --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"a":{"harness":"claude","model":"opus"}},"roles":{"builder":{"candidates":"a","author":true}}}' > "$TDIR/.orchestrator/config.json"
out="$(cd "$TDIR" && source "$REG" && registry_role_candidates builder)"
if [ "$out" = "a" ]; then
  ok "object-form role unwraps a string .candidates"
else
  fail "object-form role unwraps a string .candidates" "out=$out"
fi
teardown

# -- Test: object with no candidates resolves to an empty set --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{},"roles":{"empty":{"review":true}}}' > "$TDIR/.orchestrator/config.json"
out="$(cd "$TDIR" && source "$REG" && registry_role_candidates empty)"
if [ -z "$out" ]; then
  ok "object without candidates yields an empty candidate list"
else
  fail "object without candidates yields an empty candidate list" "out=$out"
fi
teardown

# -- Test: built-in name defaults apply in bare form --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"a":{"harness":"claude","model":"opus"}},"roles":{"worker":"a","reviewer":["a"],"auditor":["a"]}}' > "$TDIR/.orchestrator/config.json"
cd "$TDIR" && source "$REG"
if registry_role_is_author worker && ! registry_role_is_review worker \
   && registry_role_is_review reviewer && ! registry_role_is_author reviewer \
   && ! registry_role_is_author auditor && ! registry_role_is_review auditor; then
  ok "bare-form worker=author, reviewer=review, auditor=neither"
else
  fail "bare-form worker=author, reviewer=review, auditor=neither"
fi
cd / ; teardown

# -- Test: object properties override the name default --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"a":{"harness":"claude","model":"opus"}},"roles":{"worker":{"candidates":["a"],"author":false},"auditor":{"candidates":["a"],"review":true,"author":true}}}' > "$TDIR/.orchestrator/config.json"
cd "$TDIR" && source "$REG"
if ! registry_role_is_author worker \
   && registry_role_is_review auditor && registry_role_is_author auditor; then
  ok "explicit author:false disables worker default; explicit props enable a custom role"
else
  fail "explicit author:false disables worker default; explicit props enable a custom role"
fi
cd / ; teardown
```

Add `REG="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )/bin/roost-registry.sh"` near the top of `test/registry_test.sh` if it is not already defined (check the file first; reuse the existing path variable if one exists).

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `script/run-and-tail bash test/registry_test.sh`
Expected: the five new cases FAIL (object form prints raw JSON or nothing useful; the predicate functions are undefined).

- [ ] **Step 3: Teach `registry_role_candidates` the object form**

In `bin/roost-registry.sh`, replace the normalize line in `registry_role_candidates` (currently `printf '%s' "$val" | jq -r 'if type=="array" then .[] else . end'`) with:

```bash
  # A role value is a string, an array, or an object carrying .candidates
  # (itself a string or array) plus optional author/review properties. Unwrap
  # the object to its candidates, then flatten string-or-array to a line list.
  printf '%s' "$val" | jq -r '
    (if type=="object" then (.candidates // []) else . end)
    | if type=="array" then .[] else . end'
```

- [ ] **Step 4: Add the two predicate functions**

In `bin/roost-registry.sh`, immediately after `registry_role_candidates`, add:

```bash
# registry_role_is_author <role> -> exit 0 if the role records authorship.
# A role records authorship when its config object sets "author": true; when
# the object omits "author" (or the value is the bare string/array form) the
# built-in default applies: a role literally named "worker" is an author role.
registry_role_is_author() {
  local role="$1" cfg explicit; cfg="$(_registry_config_path)"
  if [ -f "$cfg" ]; then
    explicit="$(jq -r --arg r "$role" '.roles[$r] | if type=="object" and has("author") then (.author|tostring) else "unset" end' "$cfg" 2>/dev/null)"
  else
    explicit="unset"
  fi
  case "$explicit" in
    true)  return 0 ;;
    false) return 1 ;;
    *)     [ "$role" = "worker" ] && return 0 || return 1 ;;
  esac
}

# registry_role_is_review <role> -> exit 0 if the role is cross-org gated.
# Mirror of registry_role_is_author: "review": true in the object, else the
# built-in default that a role literally named "reviewer" is a review role.
registry_role_is_review() {
  local role="$1" cfg explicit; cfg="$(_registry_config_path)"
  if [ -f "$cfg" ]; then
    explicit="$(jq -r --arg r "$role" '.roles[$r] | if type=="object" and has("review") then (.review|tostring) else "unset" end' "$cfg" 2>/dev/null)"
  else
    explicit="unset"
  fi
  case "$explicit" in
    true)  return 0 ;;
    false) return 1 ;;
    *)     [ "$role" = "reviewer" ] && return 0 || return 1 ;;
  esac
}
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `script/run-and-tail bash test/registry_test.sh`
Expected: all cases PASS, including the pre-existing ones.

- [ ] **Step 6: Per-file shellcheck**

Run: `shellcheck bin/roost-registry.sh`
Expected: no output (clean). Fix any finding without adding blanket disables.

- [ ] **Step 7: Commit**

```bash
git add bin/roost-registry.sh test/registry_test.sh
git commit
```
Commit message: `feat(roost): object-form roles + author/review predicates` plus the interaction log and attribution trailer.

---

### Task 2: Append-safe override/bypass records

**Files:**
- Modify: `bin/roost-registry.sh` (`assignment_record` ~72-82; `policy_gate_reviewer` override branch ~121-130)
- Test: `test/cross-org_test.sh` (the `--allow-same-org` test ~101-118)

**Interfaces:**
- Consumes: `_assignment_path`, `assignment_lookup` (existing).
- Produces: `assignment_append <key> <kind> <provider> <org> [reason]` — appends `{kind,provider,org,reason}` to the array at `.[$key]`, creating it if absent. Atomic tmp+mv, same as `assignment_record`.

- [ ] **Step 1: Rewrite the `--allow-same-org` test to expect an append-safe array**

In `test/cross-org_test.sh`, replace the assertion block of the "`--allow-same-org` bypasses and records the override" test (currently asserting `.["9#override"].override == true`) so it expects an array whose first element is the override, and prove a second override appends rather than clobbers. Replace the test body (keep `setup`/config/`teardown`) with:

```bash
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
```

Add `tmux kill-session -t "roost-p-reviewer-9b" 2>/dev/null || true` to the `teardown` function's session list.

- [ ] **Step 2: Run to confirm it fails**

Run: `script/run-and-tail bash test/cross-org_test.sh`
Expected: the override test FAILS (`.["9#override"]` is currently a single object, not a length-2 array).

- [ ] **Step 3: Add `assignment_append`**

In `bin/roost-registry.sh`, immediately after `assignment_record`, add:

```bash
# assignment_append <key> <kind> <provider> <org> [reason]
# Appends a record to the JSON array at .[$key], creating the array if absent.
# Used for the append-safe audit trails (#override, #bypass) so a second event
# for the same issue never clobbers the first. Atomic tmp+mv, same discipline
# as assignment_record.
assignment_append() {
  local key="$1" kind="$2" provider="$3" org="$4" reason="${5:-}"
  local f; f="$(_assignment_path)"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '{}' > "$f"
  local tmp; tmp="$(mktemp "${f}.XXXXXX")"
  jq --arg k "$key" --arg kind "$kind" --arg p "$provider" --arg o "$org" --arg reason "$reason" \
     '.[$k] = ((.[$k] // []) + [{kind:$kind, provider:$p, org:$o, reason:$reason}])' \
     "$f" > "$tmp" && mv "$tmp" "$f"
}
```

- [ ] **Step 4: Point the override write at `assignment_append`**

In `policy_gate_reviewer`, replace the override-record line (currently `assignment_record "${issue}#override" "reviewer-override" "$top" "$RESOLVED_ORG" true "$reason"`) with:

```bash
    assignment_append "${issue}#override" "reviewer-override" "$top" "$RESOLVED_ORG" "$reason"
```

Update the comment above it if it names a single "override entry" so it reads as an append-safe trail (keep it timeless).

- [ ] **Step 5: Run to confirm it passes**

Run: `script/run-and-tail bash test/cross-org_test.sh`
Expected: all cases PASS.

- [ ] **Step 6: Per-file shellcheck**

Run: `shellcheck bin/roost-registry.sh`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add bin/roost-registry.sh test/cross-org_test.sh
git commit
```
Commit message: `feat(roost): append-safe override/bypass assignment records` plus log and trailer.

---

### Task 3: Dispatch gate/record onto role properties

**Files:**
- Modify: `bin/roost` (hoist `issue_key` above the registry block ~816; dispatch branches ~840-857)
- Test: `test/cross-org_test.sh`

**Interfaces:**
- Consumes: `registry_role_is_review`, `registry_role_is_author` (Task 1), `policy_gate_reviewer`, `registry_resolve_role`, `assignment_record` (existing).
- Produces: no new functions; the `--role` path now gates any review role and records any author role.

- [ ] **Step 1: Write failing tests for custom-named review/author/neutral roles**

Append to `test/cross-org_test.sh` (before the results block). Add the tmux sessions used below to `teardown`.

```bash
# -- Test: a custom-named review role is gated (not just "reviewer") --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"}},"roles":{"builder":{"candidates":["c1"],"author":true},"auditor":{"candidates":["c1","c2"],"review":true}}}' > "$TDIR/.orchestrator/config.json"
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
```

Add to `teardown`: `roost-p-builder-20`, `roost-p-auditor-20`, `roost-p-builder-21`, `roost-p-scout-22`.

- [ ] **Step 2: Run to confirm the new cases fail**

Run: `script/run-and-tail bash test/cross-org_test.sh`
Expected: the three new cases FAIL (dispatch still keys off literal `reviewer`/`worker`, so `auditor` is ungated, `builder` records nothing, `scout` may misbehave).

- [ ] **Step 3: Hoist `issue_key` derivation above the registry block**

In `bin/roost`, move the `issue_key` derivation out of the registry block so both the block and the later bypass-audit step (Task 4) can use it. Delete the `local issue_key=...` derivation currently inside the block (~836-839) and insert it just after the `--model`/`--agent` mutual-exclusivity check (after line ~816, before the `if [ "${model_explicit}" -eq 0 ] ...` registry guard):

```bash
  # Derive the issue key once, before any resolution path: explicit --issue
  # wins, else parse the first #<project>-issue-<N> channel out of --channels.
  # Needed by the reviewer cross-org gate, worker author-recording, and the
  # explicit-path bypass audit, so it lives above all of them.
  local issue_key="${issue}"
  if [ -z "${issue_key}" ]; then
    issue_key="$(printf '%s' "${channels}" | grep -oE '#[a-zA-Z0-9_-]+-issue-[0-9]+' | head -1 | grep -oE '[0-9]+$' || true)"
  fi
```

Confirm the block's own `cd "${cwd}"` still precedes any use of `issue_key` for state reads (issue_key derivation itself needs no cwd; it only parses strings).

- [ ] **Step 4: Switch the dispatch branches to the predicates**

In `bin/roost`, replace the resolution branch (currently `elif [ "${role}" = "reviewer" ]; then ... policy_gate_reviewer "${issue_key}" "reviewer" ...`) and the recording condition (`[ "${role}" = "worker" ]`). The registry is already sourced at this point, so the predicates are available. New form:

```bash
    if [ -n "${provider}" ]; then
      registry_provider_fields "${provider}"; _registry_rc=$?
    elif registry_role_is_review "${role}"; then
      policy_gate_reviewer "${issue_key}" "${role}" "${allow_same_org}" "${allow_same_org_reason}"
      _registry_rc=$?
    else
      registry_resolve_role "${role}"; _registry_rc=$?
    fi
    # Record the resolved author-org for any author role (config "author": true
    # or the built-in "worker" default), not just the literal name "worker".
    # Must run before hopping back out of --cwd: assignment_record writes a
    # cwd-relative path.
    if [ "${_registry_rc}" -eq 0 ] && [ -z "${provider}" ] && registry_role_is_author "${role}"; then
      if [ -n "${issue_key}" ]; then
        assignment_record "${issue_key}" "${role}" "${RESOLVED_PROVIDER_NAME}" "${RESOLVED_ORG}"
        echo "  recorded author-org '${RESOLVED_ORG}' for issue ${issue_key} (provider ${RESOLVED_PROVIDER_NAME})"
      fi
    fi
```

Note: `registry_role_is_review`/`registry_role_is_author` are given `${role}`, which is empty on the `--provider` path; the `[ -n "${provider}" ]` branch is checked first for the gate, and the author-record condition guards on `[ -z "${provider}" ]`, so the predicates are only evaluated with a real role.

- [ ] **Step 5: Run to confirm all cases pass**

Run: `script/run-and-tail bash test/cross-org_test.sh`
Expected: all cases PASS, including the pre-existing `reviewer`/`worker` cases (backward compatible via the name defaults).

- [ ] **Step 6: Run the golden spawn suite to confirm no regression**

Run: `script/run-and-tail bash test/spawn_test.sh`
Expected: `51 passed, 0 failed`. (Slow, >120s; do not filter through `tail`/`head`.)

- [ ] **Step 7: Per-file shellcheck**

Run: `shellcheck bin/roost`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add bin/roost test/cross-org_test.sh
git commit
```
Commit message: `feat(roost): gate/record on role properties, not magic names` plus log and trailer.

---

### Task 4: Bypass audit for explicit launch-target spawns

**Files:**
- Modify: `bin/roost-registry.sh` (add `bypass_audit` after `assignment_append`)
- Modify: `bin/roost` (call `bypass_audit` on the `--provider` path inside the block; add an explicit `--model`/`--harness` audit step after the registry block)
- Test: `test/cross-org_test.sh`

**Interfaces:**
- Consumes: `assignment_lookup`, `assignment_append` (Task 2), `registry_vendor_org` (existing), `_assignment_path`.
- Produces: `bypass_audit <issue> <provider> <org>` — if an author is recorded for `issue`, emits a note and appends a `#bypass` record; otherwise a silent no-op. Returns 0. Assumes `jq` present and cwd is the spawn target.

- [ ] **Step 1: Write failing tests for the bypass audit**

Append to `test/cross-org_test.sh` (before results). Add the tmux sessions to `teardown`.

```bash
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
```

Add to `teardown`: `roost-p-x-30`, `roost-p-worker-30`, `roost-p-x-31`, `roost-p-worker-31`, `roost-p-x-32a`, `roost-p-x-32b`, `roost-p-x-33`.

- [ ] **Step 2: Run to confirm the new cases fail**

Run: `script/run-and-tail bash test/cross-org_test.sh`
Expected: the two positive bypass cases FAIL (no `#bypass` written yet); the two negative cases likely already pass. Confirm the positives fail before implementing.

- [ ] **Step 3: Add the `bypass_audit` helper**

In `bin/roost-registry.sh`, immediately after `assignment_append`, add:

```bash
# bypass_audit <issue> <provider> <org>
# Explicit launch-target spawns (--provider, explicit --model/--harness) carry
# no role, so the cross-org gate cannot run. When such a spawn targets an issue
# that already has a recorded author, append a #bypass record and note it, so
# the un-gated spawn is auditable after the fact. Silent no-op when the issue
# has no recorded author (nothing to audit against). Assumes jq is present and
# the cwd is the spawn target. Always returns 0.
bypass_audit() {
  local issue="$1" provider="$2" org="$3"
  [ -n "$issue" ] || return 0
  [ -f "$(_assignment_path)" ] || return 0
  [ -n "$(assignment_lookup "$issue")" ] || return 0
  echo "  note: explicit launch target for issue ${issue}; cross-org gate not evaluated (no role). Appending #bypass audit record." >&2
  assignment_append "${issue}#bypass" "explicit-bypass" "$provider" "$org" "explicit launch target; cross-org gate not evaluated"
}
```

- [ ] **Step 4: Call `bypass_audit` on the `--provider` path**

In `bin/roost`, inside the registry block, extend the `--provider` branch so it audits after a successful resolve. Replace:

```bash
    if [ -n "${provider}" ]; then
      registry_provider_fields "${provider}"; _registry_rc=$?
```

with:

```bash
    if [ -n "${provider}" ]; then
      registry_provider_fields "${provider}"; _registry_rc=$?
      # Explicit launch target: no role, so the gate never ran. Audit if this
      # touches a known issue with a recorded author.
      [ "${_registry_rc}" -eq 0 ] && bypass_audit "${issue_key}" "${RESOLVED_PROVIDER_NAME}" "${RESOLVED_ORG}"
```

(Leave the `elif`/`else` branches from Task 3 intact.)

- [ ] **Step 5: Add the explicit `--model`/`--harness` bypass-audit step**

In `bin/roost`, after the registry block closes and after the `opus` default is applied (after the `if [ -z "${model}" ] && [ -z "${agent}" ]; then model="opus"; fi` line ~864-866), add:

```bash
  # Bypass audit for explicit --model/--harness (the --provider path is audited
  # inside the registry block). These flags skip the registry entirely, so this
  # engages jq only when .orchestrator/provider-assignments.json already exists,
  # preserving the "a bare spawn never needs jq" invariant. --agent is excluded:
  # its model comes from the agent frontmatter, a separate path.
  if { [ "${model_explicit}" -eq 1 ] || [ "${harness_explicit}" -eq 1 ]; } \
      && [ -z "${provider}" ] && [ -z "${agent}" ] && [ -n "${issue_key}" ]; then
    local _audit_prev_pwd; _audit_prev_pwd="$(pwd)"
    cd "${cwd}" || return 1
    if [ -f ".orchestrator/provider-assignments.json" ]; then
      if command -v jq &>/dev/null; then
        # shellcheck source=bin/roost-registry.sh disable=SC1091
        source "$(dirname "${ROOST_BIN}")/roost-registry.sh"
        local _audit_org; _audit_org="$(registry_vendor_org "${model}")"
        [ -n "${_audit_org}" ] || _audit_org="unknown"
        bypass_audit "${issue_key}" "" "${_audit_org}"
      else
        echo "  note: issue ${issue_key} has .orchestrator state but jq is absent; skipping #bypass audit." >&2
      fi
    fi
    cd "${_audit_prev_pwd}" || return 1
  fi
```

- [ ] **Step 6: Run to confirm all bypass cases pass**

Run: `script/run-and-tail bash test/cross-org_test.sh`
Expected: all cases PASS.

- [ ] **Step 7: Run the golden spawn suite and the registry suite**

Run: `script/run-and-tail bash test/spawn_test.sh`
Expected: `51 passed, 0 failed`.
Run: `script/run-and-tail bash test/registry_test.sh`
Expected: all PASS (including the jq-absent bare-spawn case, which must still require no jq).

- [ ] **Step 8: Per-file shellcheck**

Run: `shellcheck bin/roost bin/roost-registry.sh`
Expected: clean.

- [ ] **Step 9: Commit**

```bash
git add bin/roost bin/roost-registry.sh test/cross-org_test.sh
git commit
```
Commit message: `feat(roost): #bypass audit for explicit launch-target spawns` plus log and trailer.

---

### Task 5: Documentation and canonical cross-org wording

**Files:**
- Modify: `bin/roost` (`spawn --help` heredoc, the "Provider selection" block ~294-307)
- Modify: `skills/roost/SKILL.md`
- Modify: `README.md`
- Modify: `agents/project-manager.md`, `agents/associate-pm.md`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Update the `spawn --help` cross-org section**

In `bin/roost`, replace the "Cross-org rule" paragraph (~301-304) so it states the role-object shape, the three `--role` outcomes, the built-in name defaults, and the explicit-path bypass audit. Keep the prose one-idea-per-sentence, no em-dashes:

```
  Cross-org rule: a review role's provider org must differ from the recorded
  author org. Roles are declared in .orchestrator/config.json .roles. A role
  value is a provider name, a list of candidates, or an object
  {"candidates": [...], "author": true, "review": true}. An author role
  records the author org for its issue. A review role is gated: the spawn
  picks the first candidate whose org differs from the author, and fails when
  every candidate is same-org. A role that is neither records nothing and is
  not gated. The names "worker" and "reviewer" default to author and review
  respectively, even in the bare form, so an existing "reviewer": [...] stays
  gated; rename the role or set "review": false to opt out.

  --allow-same-org "<reason>" overrides the review gate and records the reason.
  Explicit launch targets (--provider, --model, --harness) carry no role, so
  the gate cannot run. When one targets an issue that already has a recorded
  author, roost notes it and appends a #bypass audit record. It does not block:
  explicit flags win.
```

Pick the single sentence "a review role's provider org must differ from the recorded author org" as the canonical statement of the invariant. Use it verbatim in every surface below (this is a 4+ surface invariant, so it must be byte-identical per the canonicalize-wording rule).

- [ ] **Step 2: Update `skills/roost/SKILL.md`**

Read `skills/roost/SKILL.md`, find where it documents `--role`/`--provider`/the cross-org gate, and update it to match: the role-object shape, the three outcomes, the name defaults, and the bypass audit. Use the canonical invariant sentence verbatim. Keep the shipped-artifact voice (this installs into projects that are not roost; no "edit here" instructions, generic language).

- [ ] **Step 3: Update `README.md`**

Read `README.md`, find the provider/role/cross-org section, and update it the same way. Canonical invariant sentence verbatim.

- [ ] **Step 4: Update the agent prompts**

Read `agents/project-manager.md` and `agents/associate-pm.md`. If either references the reviewer/worker cross-org gate or how reviewers are chosen, update it to the role-property model and use the canonical invariant sentence verbatim. If a prompt does not mention the gate, leave it unchanged (do not manufacture a reference).

- [ ] **Step 5: Add the migration note**

In whichever doc carries the config reference most fully (README.md provider/role section is the likely home; confirm by reading), add a short migration note: a custom-named review role (for example `auditor`) must declare `"review": true` to be gated; a custom-named author role must declare `"author": true` to record authorship. Bare `"worker"`/`"reviewer"` keep their Phase 1 behavior by name.

- [ ] **Step 6: Grep for cross-org wording drift**

Run: `grep -rn "must differ from the recorded author org" bin/roost skills/roost/SKILL.md README.md agents/`
Expected: the canonical sentence appears identically in every surface that states the invariant. Any near-miss paraphrase is drift; fix it to the verbatim form.

- [ ] **Step 7: Per-file shellcheck (help text lives in `bin/roost`)**

Run: `shellcheck bin/roost`
Expected: clean (the heredoc edit must not break quoting).

- [ ] **Step 8: Commit**

```bash
git add bin/roost skills/roost/SKILL.md README.md agents/project-manager.md agents/associate-pm.md
git commit
```
Commit message: `docs(roost): cross-org role-property model across CLI, skill, README, prompts` plus log and trailer.

---

## Self-Review Notes

- **Spec coverage:** (a) config-declared roles → Tasks 1+3; (b) warn-plus-audit-record → Task 4; (c) explicit-flag-wins preserved (bypass never blocks) → Task 4; append-safe `#override`/`#bypass` → Tasks 2+4; three `--role` outcomes → Task 3 tests; fully-explicit negative case → Task 4 negative test; built-in-defaults-by-name migration note → Task 5.
- **Type consistency:** `registry_role_is_author`/`registry_role_is_review` are exit-code predicates (used in `if`), consistent across Tasks 1, 3, 4. `assignment_append` signature `<key> <kind> <provider> <org> [reason]` is consistent between Task 2 (override) and Task 4 (bypass and the `bypass_audit` caller).
- **Bare-spawn invariant:** only Task 4's explicit `--model`/`--harness` step could newly touch `jq`; it is guarded by the assignment-file existence check and degrades to a warning when `jq` is absent, so a genuine bare spawn (no state file) still needs no `jq`. Task 4 Step 7 re-runs `registry_test.sh` to confirm the jq-absent case.
- **`--agent` boundary:** excluded from the bypass audit by the explicit `[ -z "${agent}" ]` guard in Task 4 Step 5, matching the confirmed trigger set.
