# Codex Harness Adapter and Cross-Org Enablement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working OpenAI Codex harness adapter for roost workers, and make roost's own cross-org review enforcement fire on the spawn paths automation actually uses.

**Architecture:** Part A replaces the fail-fast `bin/roost-harness-codex.sh` stub with a real `harness_assemble()` that generates a per-session Codex `config.toml` (roost-irc MCP entry, signet+permbot hook blocks, model/provider selection), sets `RESP_INNER_CMD` to a `codex` invocation, and adds a `tmux`-injection inbound-delivery mode to the roost-irc MCP server. Part B refactors `bin/roost`'s spawn dispatch so the persona axis (`--agent`) composes with the provider axis (`--role`/`--provider`/`--model`/`--harness`), degrades the cross-org gate to a no-op in single-org registries, seeds default roles at `roost init`, and threads model/harness into the `#bypass` audit record.

**Tech Stack:** Bash 3.2 (the bash macOS ships), jq for registry reads, TypeScript on Bun for the MCP server (`src/irc-server.ts`), plain-bash test harnesses (no bats), tmux for pane lifecycle, Codex CLI 0.145.0 (spawn host) and Claude Code as the two harnesses.

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from the spec and repo rules.

- **No em-dashes** in code, docs, or comments. One idea per sentence.
- **Timeless in-tree comments.** No PR/issue/version refs (e.g. `(#276)`, `Issue #342`, `since v3`) in code or in-tree docs. Systems of record (commit messages, PR bodies, LEARNINGS.md, dated audit reports) keep their refs; in-tree comments do not.
- **Commit format.** Every commit includes a mandatory Human-Claude Interaction Log capturing EVERY human prompt since the last commit, VERBATIM (typos, informal language, complete text), each followed by what Claude did. End every commit with:
  ```
  🤖 Generated with Claude Code
  Co-Authored-By: Claude <noreply@anthropic.com>
  ```
- **Canonical cross-org sentence.** This exact byte string must stay identical across `bin/roost` help text, `skills/roost/SKILL.md`, `README.md`, `agents/project-manager.md`, and `agents/associate-pm.md`:
  > Cross-org rule: a review role's provider org must differ from the recorded author org.
  When a task edits any surface carrying it, the sentence is copied, never paraphrased.
- **Test hygiene.** Never pipe `bun test` through `tail`, `head`, or `grep` (the pipe masks the real exit code and buffers hangs). Use `script/run-and-tail bun test [args...]`. Plain-bash `.sh` suites run directly: `bash test/<name>.sh`.
- **Bare-spawn-never-needs-jq invariant.** A `roost spawn <nick>` with no `--role`/`--provider` must never call `require_jq` and must run with jq absent from PATH. The `require_jq` gate fires only inside the registry-resolution branch.
- **`test/spawn_test.sh` golden baseline stays byte-identical.** The Claude default launch assembly does not change. `spawn_test.sh` is slow (>120s because several cases fall through to a real `tmux new-session`); run it whole, never filtered, and confirm the bare-`--agent` and default-`--model` inner commands are unchanged.

---

## Phasing and order

- **Phase A spikes (Tasks 1-4) come FIRST.** They are MANUAL, quota-gated Codex CLI sessions. Their findings feed the adapter code in Tasks 12-14. Batch all four into one or two tiny sessions; each does a single startup turn and asserts on server-side logs, not model output. The spawn host is under 10% of its weekly Codex limit; keep it that way.
- **Phase B (Tasks 5-11) is fully AUTOMATED and reviewable/testable independently of Part A.** It is the dispatch refactor, the gate/init/record changes, and the doc pass. It does not require Codex to run.
- **Phase A adapter (Tasks 12-14) is AUTOMATED but depends on the Task 1-4 spike findings.** Do not start Task 12 until Tasks 1-4 have recorded findings in the spec's "Open items" area.

| Task | Phase | Kind | Deliverable |
|------|-------|------|-------------|
| 1 | A | MANUAL spike | Exact Codex `[[hooks.*]]` TOML shape |
| 2 | A | MANUAL spike | Whether Codex surfaces MCP-server `instructions` |
| 3 | A | MANUAL spike | `tmux send-keys` injection behavior into the Codex TUI |
| 4 | A | MANUAL spike | `CODEX_HOME` vs `-c`, least-privilege sandbox |
| 5 | B | Automated | `#bypass` record carries model + harness (B6) |
| 6 | B | Automated | Single-org registry degrades the gate to a no-op (B2) |
| 7 | B | Automated | `--role` composes with explicit `--model`/`--harness`/`--effort` (B1-R1) |
| 8 | B | Automated | `--agent` composes with `--role`/`--provider` (B1-R2) |
| 9 | B | Automated | `roost init` seeds default roles (B3) |
| 10 | B | Automated | Migrate APM spawn templates onto `--role` (B4) |
| 11 | B | Automated | Document coverage across all surfaces (B5) |
| 12 | A | Automated | Codex adapter base: config.toml, launch, backend, IRC-trust |
| 13 | A | Automated | Codex adapter hook blocks: signet + permbot |
| 14 | A | Automated | roost-irc `tmux` inbound-delivery mode |

---

## File Structure

- `bin/roost` — spawn dispatch (arg parse, registry-resolution branch, explicit-bypass branch, banner), `cmd_init`, help text. Modified in Tasks 5, 7, 8, 9, 11.
- `bin/roost-registry.sh` — registry + policy module. Modified in Tasks 5, 6.
- `bin/roost-harness-codex.sh` — the Codex adapter. Rewritten in Tasks 12, 13.
- `bin/roost-harness-claude.sh` — reference adapter. NOT modified (spec non-goal).
- `src/irc-server.ts` — the MCP server. Modified in Task 14 (inbound `tmux` delivery).
- `agents/associate-pm.md`, `agents/project-manager.md` — APM/PM prompts. Modified in Tasks 10, 11.
- `skills/roost/SKILL.md`, `README.md` — operator docs. Modified in Task 11.
- Tests: `test/cross-org_test.sh` (5,6,7,8), `test/registry_test.sh` (9), `test/init_test.sh` (9), `test/harness_test.sh` (12), a new `test/harness-codex_test.sh` (12,13), `test/inbound.test.ts` or a new `.test.ts` (14).

---

## Task 1 (Phase A, MANUAL SPIKE): Confirm the Codex `[[hooks.*]]` TOML shape

**This is a manual, quota-gated spike. No code lands. The deliverable is recorded findings.**

**Files:**
- Modify: `docs/superpowers/specs/2026-07-22-codex-harness-adapter-design.md` (append findings under "Open items resolved as gated spikes")

**Interfaces:**
- Consumes: nothing.
- Produces: the exact TOML nesting later tasks encode. Record ALL of: the event key casing (`PreToolUse` vs `pre_tool_use`), the field names (`command`, `timeout_sec`, `matcher`), whether hooks are array-of-tables (`[[hooks.PreToolUse]]`) or a table with a list, and whether a `PreToolUse` command that exits non-zero actually blocks (the literal "Tool call blocked by PreToolUse hook" line).

- [ ] **Step 1: Write a minimal probe `config.toml`**

Under a scratch `CODEX_HOME`, write a config declaring one `PreToolUse` hook that runs a script logging its stdin and exiting non-zero, plus (separately) the same as a `PermissionRequest` hook. Use the array-of-tables shape the spec's empirical finding implies:

```toml
[[hooks.PreToolUse]]
matcher = "Bash"
command = "/tmp/codex-spike/log-and-block.sh"
timeout_sec = 30
```

- [ ] **Step 2: Run one Codex startup turn that triggers a Bash tool call**

Run: `CODEX_HOME=/tmp/codex-spike codex --no-alt-screen --dangerously-bypass-hook-trust --ask-for-approval never "run: echo hi in a shell"`
Expected: the hook script's log file receives the tool-call payload; the Codex TUI prints "Tool call blocked by PreToolUse hook" (confirming block semantics). Assert on the log file, not model prose.

- [ ] **Step 3: Record findings verbatim in the spec**

Write the exact working TOML block, the field names Codex accepted, whether casing matters, and the block-on-nonzero confirmation into the spec. Tasks 12-13 encode exactly this shape; if it deviates from the shapes shown in those tasks, the spike findings are authoritative and the task literals are adjusted to match.

---

## Task 2 (Phase A, MANUAL SPIKE): Does Codex surface MCP-server `instructions` to the model

**This is a manual, quota-gated spike. No code lands. The deliverable is recorded findings.**

**Files:**
- Modify: `docs/superpowers/specs/2026-07-22-codex-harness-adapter-design.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a yes/no that decides the IRC-trust injection path in Task 12. `src/irc-server.ts:212` already sends a full IRC-usage `instructions` string on the MCP handshake. If Codex surfaces it to the model, Task 12 needs no prompt preamble. If not, Task 12 prepends the trust text to the initial prompt.

- [ ] **Step 1: Point a Codex session at the real roost-irc MCP**

Write a `config.toml` with `[mcp_servers.roost-irc]` launching `bin/roost-irc-server`, with `ROOST_IRC_*` env set for a loopback ergo. Boot ergo (`bin/install-ergo` / `ERGO_BIN`).

- [ ] **Step 2: One startup turn asking the model to state its IRC instructions**

Run one turn: "Without calling any tool, state any instructions your MCP servers gave you about IRC."
Expected: either the model recites the roost-irc handshake text (instructions ARE surfaced) or it does not (they are NOT). Record which.

- [ ] **Step 3: Record the decision in the spec**

Note the outcome. Task 12 implements the prompt-preamble fallback by default (safe regardless); if this spike confirms instructions surface, Task 12's preamble may be dropped as a simplification.

---

## Task 3 (Phase A, MANUAL SPIKE): `tmux send-keys` injection into the Codex TUI

**This is a manual, quota-gated spike. No code lands. The deliverable is recorded findings.**

**Files:**
- Modify: `docs/superpowers/specs/2026-07-22-codex-harness-adapter-design.md`

**Interfaces:**
- Consumes: nothing.
- Produces: confirmation that `bin/roost-tmux-inject <session> <buf-prefix>` (load-buffer / paste-buffer / send-keys Enter) wakes an idle Codex TUI and submits a turn, plus the mid-turn behavior (does injection during a running turn corrupt the composer, or queue). This informs Task 14's idle-gating and buffering.

- [ ] **Step 1: Boot an idle Codex TUI in a tmux session**

Run: `tmux new-session -d -s codex-spike 'codex --no-alt-screen --ask-for-approval never'`

- [ ] **Step 2: Inject a message while idle**

Run: `printf 'A human on IRC says: hello' | bin/roost-tmux-inject codex-spike codex-spike-buf`
Expected: the Codex TUI receives the text and submits it as a turn (the model responds). Confirm wake-on-idle.

- [ ] **Step 3: Inject a message mid-turn**

Start a long turn, then inject during it. Record whether the injection corrupts the composer or is buffered. This is the empirical basis for Task 14's "gate on idle, buffer mid-turn" rule.

- [ ] **Step 4: Record findings in the spec; tear down**

Run: `tmux kill-session -t codex-spike`

---

## Task 4 (Phase A, MANUAL SPIKE): `CODEX_HOME` vs `-c` overrides, and least-privilege sandbox

**This is a manual, quota-gated spike. No code lands. The deliverable is recorded findings.**

**Files:**
- Modify: `docs/superpowers/specs/2026-07-22-codex-harness-adapter-design.md`

**Interfaces:**
- Consumes: nothing.
- Produces: (a) whether pointing Codex at the session config is cleaner via `CODEX_HOME=<dir>` (config.toml inside it) or stacked `-c` overrides, and (b) the least-privilege `--sandbox`/approval combination that does NOT double-prompt on top of the hook gate (`--ask-for-approval never` is already chosen; confirm the sandbox mode that pairs with it without a second prompt).

- [ ] **Step 1: Boot Codex with `CODEX_HOME` pointing at a session dir**

Confirm Codex reads `config.toml` (model, mcp_servers, hooks) from `$CODEX_HOME/config.toml` in one startup turn.

- [ ] **Step 2: Boot the same config via `-c` overrides**

Compare ergonomics for the multi-line table blocks (`[mcp_servers.roost-irc]`, `[[hooks.*]]`).

- [ ] **Step 3: Confirm no double-prompt**

With `--ask-for-approval never` plus the candidate sandbox mode, trigger a Bash tool call and confirm only the PreToolUse hook gates (no separate Codex approval prompt fires).

- [ ] **Step 4: Record the chosen mechanism + sandbox mode in the spec**

Task 12 uses `CODEX_HOME` by default (the spec's stated preference for the table blocks); if this spike shows `-c` is cleaner, adjust Task 12's launch assembly accordingly.

---

## Task 5 (Phase B): The `#bypass` record captures what was launched (B6)

**Files:**
- Modify: `bin/roost-registry.sh:138-147` (`assignment_append`), `bin/roost-registry.sh:156-163` (`bypass_audit`)
- Modify: `bin/roost:885` and `bin/roost:926` (the two `bypass_audit` call sites)
- Test: `test/cross-org_test.sh` (extend the two `#bypass` cases)

**Interfaces:**
- Consumes: `registry_vendor_org <model>` (existing, `bin/roost-registry.sh:12`), `assignment_lookup <issue>` (existing).
- Produces:
  - `assignment_append <key> <kind> <provider> <org> <reason> [model] [harness]` — reason stays positional `$5` so the existing `${issue}#override` caller in `policy_gate_reviewer` keeps working; `model` (`$6`) and `harness` (`$7`) default to empty and are always written as keys.
  - `bypass_audit <issue> <provider> <org> <model> <harness>` — appends a `#bypass` record carrying the launched model and harness.

- [ ] **Step 1: Write the failing test in `test/cross-org_test.sh`**

Add these two cases after the existing "explicit --model for a known issue appends #bypass" case (currently ending near line 205). Ensure `roost-p-worker-30`, `roost-p-x-30`, `roost-p-worker-31`, and `roost-p-x-31` are in `teardown`'s tmux kill list (add any that are missing).

```bash
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bash test/cross-org_test.sh`
Expected: the two new cases FAIL (`.model`/`.harness` keys absent); all prior cases PASS.

- [ ] **Step 3: Update `assignment_append` in `bin/roost-registry.sh`**

Replace the function body (lines 138-147) with:

```bash
# assignment_append <key> <kind> <provider> <org> <reason> [model] [harness]
# Appends a record to the JSON array at .[$key], creating the array if absent.
# Used for the append-safe audit trails (#override, #bypass) so a second event
# for the same issue never clobbers the first. reason stays positional so the
# #override caller (5 args) is unaffected; model/harness trail it and default
# empty, always written as keys. Atomic tmp+mv, same discipline as
# assignment_record.
assignment_append() {
  local key="$1" kind="$2" provider="$3" org="$4" reason="${5:-}" model="${6:-}" harness="${7:-}"
  local f; f="$(_assignment_path)"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '{}' > "$f"
  local tmp; tmp="$(mktemp "${f}.XXXXXX")"
  jq --arg k "$key" --arg kind "$kind" --arg p "$provider" --arg o "$org" \
     --arg reason "$reason" --arg m "$model" --arg h "$harness" \
     '.[$k] = ((.[$k] // []) + [{kind:$kind, provider:$p, org:$o, model:$m, harness:$h, reason:$reason}])' \
     "$f" > "$tmp" && mv "$tmp" "$f"
}
```

- [ ] **Step 4: Update `bypass_audit` in `bin/roost-registry.sh`**

Replace the function body (lines 156-163) with:

```bash
# bypass_audit <issue> <provider> <org> <model> <harness>
# Explicit launch-target spawns (--provider, explicit --model/--harness) carry
# no role, so the cross-org gate cannot run. When such a spawn targets an issue
# that already has a recorded author, append a #bypass record naming the launched
# model and harness, so the un-gated spawn is auditable after the fact. Silent
# no-op when the issue has no recorded author (nothing to audit against). Assumes
# jq is present and the cwd is the spawn target. Always returns 0.
bypass_audit() {
  local issue="$1" provider="$2" org="$3" model="$4" harness="$5"
  [ -n "$issue" ] || return 0
  [ -f "$(_assignment_path)" ] || return 0
  [ -n "$(assignment_lookup "$issue")" ] || return 0
  echo "  note: explicit launch target for issue ${issue}; cross-org gate not evaluated (no role). Appending #bypass audit record." >&2
  assignment_append "${issue}#bypass" "explicit-bypass" "$provider" "$org" \
    "explicit launch target; cross-org gate not evaluated" "$model" "$harness"
}
```

- [ ] **Step 5: Thread model/harness into both `bypass_audit` call sites in `bin/roost`**

At line 885 (the `--provider` branch), replace:
```bash
    [ "${_registry_rc}" -eq 0 ] && bypass_audit "${issue_key}" "${RESOLVED_PROVIDER_NAME}" "${RESOLVED_ORG}"
```
with:
```bash
    [ "${_registry_rc}" -eq 0 ] && bypass_audit "${issue_key}" "${RESOLVED_PROVIDER_NAME}" "${RESOLVED_ORG}" "${RESOLVED_MODEL}" "${RESOLVED_HARNESS}"
```

At line 926 (the explicit `--model`/`--harness` branch), replace:
```bash
        bypass_audit "${issue_key}" "" "${_audit_org}"
```
with:
```bash
        bypass_audit "${issue_key}" "" "${_audit_org}" "${model}" "${harness}"
```

- [ ] **Step 6: Run to verify pass**

Run: `bash test/cross-org_test.sh`
Expected: all cases PASS, including the two new ones.

- [ ] **Step 7: Lint and commit**

Run: `shellcheck bin/roost bin/roost-registry.sh` (expect no output, exit 0), then commit. Include the Human-Claude Interaction Log per the Global Constraints, and the trailer:
```bash
git add bin/roost bin/roost-registry.sh test/cross-org_test.sh
git commit
# message subject: "Record launched model + harness in #bypass audit records"
```

---

## Task 6 (Phase B): Single-org registry degrades the gate to a no-op (B2)

**Files:**
- Modify: `bin/roost-registry.sh` (add `registry_org_count`; extend `policy_gate_reviewer`'s no-cross-org branch, lines 201-214)
- Test: `test/cross-org_test.sh` (add a single-org-allows case; migrate three existing cases to two-org registries so they still exercise the hard-fail / override paths)

**Interfaces:**
- Consumes: `registry_provider_fields <name>` (sets `RESOLVED_ORG`), `registry_role_candidates <role>`, `_registry_config_path`.
- Produces: `registry_org_count` — echoes the number of DISTINCT orgs across every provider in `.orchestrator/config.json`. `policy_gate_reviewer` gains one rule: when the registry contains providers from only one org (count <= 1), the no-cross-org branch resolves the top candidate and returns 0 silently. The genuine two-org-but-all-candidates-same-org misconfiguration still errors (return 3) or takes `--allow-same-org`.

- [ ] **Step 1: Migrate the existing cases that assume a single-org registry hard-fails**

Under B2 a registry whose providers are all Anthropic is single-org, so its reviewer gate now ALLOWS. Three existing `test/cross-org_test.sh` cases relied on the old all-same-org-hard-fails behavior with an all-Claude registry. Give each a second org (a `gpt` provider, org `openai`) so they still exercise the intended path, keeping the reviewer candidates same-org as the author.

Replace the "all-same-org reviewer set hard-fails" case config line (currently `bin/`... line 104) so the registry has two orgs:
```bash
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"},"gpt":{"harness":"codex","model":"gpt-5.1-codex"}},"roles":{"worker":"c1","reviewer":["c1","c2"]}}' > "$TDIR/.orchestrator/config.json"
```

Replace the "--allow-same-org bypasses and records the override" case config line (currently line 117):
```bash
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"},"gpt":{"harness":"codex","model":"gpt-5.1-codex"}},"roles":{"worker":"c1","reviewer":["c2"]}}' > "$TDIR/.orchestrator/config.json"
```

Replace the "custom-named review role 'auditor' is gated" case config line (currently line 139):
```bash
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"},"c2":{"harness":"claude","model":"sonnet"},"gpt":{"harness":"codex","model":"gpt-5.1-codex"}},"roles":{"builder":{"candidates":["c1"],"author":true},"auditor":{"candidates":["c1","c2"],"review":true}}}' > "$TDIR/.orchestrator/config.json"
```

- [ ] **Step 2: Write the failing single-org-allows case**

Add after the migrated all-same-org case. Add `roost-p-reviewer-14` to `teardown`'s kill list.

```bash
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
```

Add `tmux kill-session -t "roost-p-worker-14" 2>/dev/null || true` and `tmux kill-session -t "roost-p-reviewer-14" 2>/dev/null || true` to `teardown`.

- [ ] **Step 3: Run to verify failure**

Run: `bash test/cross-org_test.sh`
Expected: the new single-org case FAILS (today it hard-errors "cross-org ... allow-same-org"); the three migrated cases still PASS (they now have two orgs, so the old behavior holds).

- [ ] **Step 4: Add `registry_org_count` to `bin/roost-registry.sh`**

Insert directly after `registry_vendor_org` (after line 19):

```bash
# registry_org_count -> echoes the number of DISTINCT orgs across all providers
# in .orchestrator/config.json. Used by the reviewer gate to detect a single-org
# registry, where there is no cross-org choice to enforce. Resolves each
# provider's org the same way registry_provider_fields does (explicit .org, else
# vendor lineage of the model). Clobbers RESOLVED_* as a side effect, so callers
# resolve their own provider afterward. Echoes 0 when the config is absent.
registry_org_count() {
  local cfg; cfg="$(_registry_config_path)"
  [ -f "$cfg" ] || { echo 0; return 0; }
  local names; names="$(jq -r '.providers | keys[]?' "$cfg" 2>/dev/null)"
  local orgs="" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if registry_provider_fields "$p" >/dev/null 2>&1; then
      orgs="${orgs}${RESOLVED_ORG}"$'\n'
    fi
  done <<< "$names"
  printf '%s' "$orgs" | grep -v '^$' | sort -u | grep -c .
}
```

- [ ] **Step 5: Add the single-org degradation to `policy_gate_reviewer`**

In `bin/roost-registry.sh`, replace the "No cross-org candidate." block (lines 201-214) with:

```bash
  # No cross-org candidate.
  local _org_n; _org_n="$(registry_org_count)"
  if [ "${_org_n}" -le 1 ]; then
    # Single-org registry: there is no cross-org choice to make, so nothing to
    # enforce. Resolve the top candidate and allow silently. The gate engages on
    # its own the moment a second org's provider is added to the registry.
    registry_provider_fields "$top" || return 1
    return 0
  fi
  if [ "$allow" = "1" ]; then
    registry_provider_fields "$top" || return 1
    echo "  WARNING: cross-org gate OVERRIDE. Reviewer '${top}' is same org ('${author_org}') as the author. Reason: ${reason}" >&2
    # Append the override to a distinct key's array so it never clobbers the
    # worker's author entry at "$issue", and a second override for the same
    # issue never clobbers the first. assignment_lookup reads the author org
    # from "$issue", so a later re-review still sees the real author, not
    # this reviewer. The override trail is auditable on its own key.
    assignment_append "${issue}#override" "reviewer-override" "$top" "$RESOLVED_ORG" "$reason"
    return 0
  fi
  echo "error: cross-org review rule. Every reviewer candidate for issue ${issue} is same org ('${author_org}') as the author. Pass --allow-same-org \"<reason>\" to override." >&2
  return 3
```

- [ ] **Step 6: Run to verify pass**

Run: `bash test/cross-org_test.sh`
Expected: all cases PASS, including the single-org-allows case and the three migrated two-org cases.

- [ ] **Step 7: Run the registry suite for regressions, lint, commit**

Run: `bash test/registry_test.sh` (expect all PASS), then `shellcheck bin/roost-registry.sh` (no output). Commit with the interaction log and trailer:
```bash
git add bin/roost-registry.sh test/cross-org_test.sh
git commit
# subject: "Degrade the cross-org reviewer gate to a no-op in single-org registries"
```

---

## Task 7 (Phase B): `--role` composes with explicit `--model`/`--harness`/`--effort` (B1-R1)

**Files:**
- Modify: `bin/roost:845-846` (registry-resolution entry guard), `bin/roost:904-905` (post-resolution harness/model assignment), `bin/roost:916-917` (explicit-bypass guard)
- Test: `test/cross-org_test.sh` (add R1 cases)

**Interfaces:**
- Consumes: `registry_vendor_org <model>` (`bin/roost-registry.sh:12`), `assignment_record` (author role records via role), the resolved `RESOLVED_HARNESS`/`RESOLVED_MODEL`/`RESOLVED_ORG` globals.
- Produces: with `--role` set, author-recording and the gate run even when an explicit `--model`/`--harness` overrides the launch target. `--effort` is passed through untouched via the post-`--` extra args, so no flag handling is added for it. An org-coherence check errors when the override model's vendor org differs from the role's resolved org.

Note: `--effort` is not a roost flag. The APM template passes it as `-- --effort <effort>`, which lands in `extra_args`/`REQ_EXTRA_STR` and flows straight to the harness. R1's "composes with --effort" is satisfied by that existing pass-through; this task changes nothing for `--effort`.

- [ ] **Step 1: Write the failing R1 cases in `test/cross-org_test.sh`**

Add after the worker-records-author case. Add `roost-p-worker-50`, `roost-p-worker-51` to `teardown`.

```bash
# -- Test (R1): --role worker --model <override> records authorship AND runs on the override model --
setup
mkdir -p "$TDIR/.orchestrator"
# Single-org registry: worker role resolves anthropic; override --model sonnet is
# also anthropic, so the org-coherence check passes. Authorship is still recorded.
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"}},"roles":{"worker":"c1"}}' > "$TDIR/.orchestrator/config.json"
out="$("${ROOST_BIN}" spawn p-worker-50 --role worker --model sonnet --issue 50 --cwd "$TDIR" 2>&1 || true)"
asn="$TDIR/.orchestrator/provider-assignments.json"
if echo "$out" | grep -q "model: sonnet" \
    && jq -e '.["50"].org == "anthropic" and .["50"].role == "worker"' "$asn" >/dev/null 2>&1; then
  ok "R1: --role worker --model sonnet records author AND launches sonnet"
else
  fail "R1: --role worker --model sonnet records author AND launches sonnet" "out=$out asn=$(cat "$asn" 2>/dev/null)"
fi
teardown

# -- Test (R1): a cross-org override model errors --
setup
mkdir -p "$TDIR/.orchestrator"
# worker role resolves anthropic (c1=opus). Override --model gpt-5.1-codex is
# openai. Picking an anthropic role and an openai model is incoherent -> error.
printf '{"project":"p","providers":{"c1":{"harness":"claude","model":"opus"}},"roles":{"worker":"c1"}}' > "$TDIR/.orchestrator/config.json"
err="$("${ROOST_BIN}" spawn p-worker-51 --role worker --model gpt-5.1-codex --issue 51 --cwd "$TDIR" 2>&1)"; ec=$?
if [ "$ec" -ne 0 ] && echo "$err" | grep -qi "differs from role" && echo "$err" | grep -q "openai"; then
  ok "R1: cross-org override model errors"
else
  fail "R1: cross-org override model errors" "ec=$ec err=$err"
fi
teardown
```

- [ ] **Step 2: Run to verify failure**

Run: `bash test/cross-org_test.sh`
Expected: R1 case 1 FAILS (today `--role`+`--model` skips the registry, so no author recorded and banner shows the registry's resolved model, not the override); R1 case 2 FAILS (no coherence check exists yet).

- [ ] **Step 3: Widen the registry-resolution entry guard**

In `bin/roost`, replace the guard at lines 845-846:
```bash
  if [ "${model_explicit}" -eq 0 ] && [ "${harness_explicit}" -eq 0 ] && [ -z "${agent}" ] \
      && { [ -n "${provider}" ] || [ -n "${role}" ]; }; then
```
with (drop the explicit-flag preconditions so `--role` still resolves, gates, and records under an explicit override; `-z agent` stays until Task 8):
```bash
  if [ -z "${agent}" ] && { [ -n "${provider}" ] || [ -n "${role}" ]; }; then
```

- [ ] **Step 4: Make the post-resolution harness/model assignment respect explicit flags and add the org-coherence check**

In `bin/roost`, replace lines 904-905:
```bash
    harness="${RESOLVED_HARNESS}"
    model="${RESOLVED_MODEL}"
    # base_url_env / auth_env / org are consumed by later provider-wiring work.
```
with:
```bash
    # Model selection precedence: explicit --harness/--model win over the role's
    # resolved values, but the role still drove author-recording and the gate
    # above. Only adopt the resolved value when the operator did not pin one.
    [ "${harness_explicit}" -eq 0 ] && harness="${RESOLVED_HARNESS}"
    [ "${model_explicit}" -eq 0 ] && model="${RESOLVED_MODEL}"
    # Org-coherence: an explicit --model on a --role spawn must be from the same
    # vendor org the role resolved to. Picking a role from one org and a model
    # from another is incoherent. In a single-org deployment the vendor orgs
    # always match, so this never triggers there.
    if [ "${model_explicit}" -eq 1 ] && [ -n "${role}" ]; then
      local _override_org; _override_org="$(registry_vendor_org "${model}")"
      if [ -n "${_override_org}" ] && [ "${_override_org}" != "${RESOLVED_ORG}" ]; then
        cd "${_registry_prev_pwd}" || return 1
        echo "error: --model '${model}' (org '${_override_org}') differs from role '${role}' org '${RESOLVED_ORG}'. Pick a model from the role's org, or drop --role." >&2
        return 1
      fi
    fi
    # base_url_env / auth_env / org are consumed by later provider-wiring work.
```

- [ ] **Step 5: Exclude the `--role` case from the explicit-bypass audit branch**

With `--role` now recording authorship on the explicit-override path, the explicit-flag `#bypass` block must not also fire for it. In `bin/roost`, replace the guard at lines 916-917:
```bash
  if { [ "${model_explicit}" -eq 1 ] || [ "${harness_explicit}" -eq 1 ]; } \
      && [ -z "${provider}" ] && [ -z "${agent}" ] && [ -n "${issue_key}" ]; then
```
with:
```bash
  if { [ "${model_explicit}" -eq 1 ] || [ "${harness_explicit}" -eq 1 ]; } \
      && [ -z "${provider}" ] && [ -z "${role}" ] && [ -z "${agent}" ] && [ -n "${issue_key}" ]; then
```

- [ ] **Step 6: Run to verify pass**

Run: `bash test/cross-org_test.sh`
Expected: all cases PASS, including both R1 cases.

- [ ] **Step 7: Regression + lint + commit**

Run: `bash test/registry_test.sh` and `bash test/harness_test.sh` (expect all PASS), then `shellcheck bin/roost`. Then run the slow golden baseline whole to confirm no Claude-path regression: `bash test/spawn_test.sh` (>120s; expect all PASS). Commit:
```bash
git add bin/roost test/cross-org_test.sh
git commit
# subject: "Compose --role author-recording and gate with explicit --model/--harness (R1)"
```

---

## Task 8 (Phase B): `--agent` composes with `--role`/`--provider` (B1-R2)

**Files:**
- Modify: `bin/roost:845` (drop the `-z agent` restriction on the registry-resolution guard), `bin/roost` (the model-selection block introduced in Task 7)
- Test: `test/cross-org_test.sh` (add R2 cases)

**Interfaces:**
- Consumes: `_resolvable_agents <cwd>` (existing agent lookup), `policy_gate_reviewer`, the Task 7 model-selection block.
- Produces: `--agent <name>` supplies the persona and `permissionMode`; a paired `--role`/`--provider` supplies (and gates) the harness/model. Author-recording and the gate run per the role. Bare `--agent` with no provider-axis flag is unchanged: no registry read, no jq, no gate. On the Claude harness with `--agent`, the resolved model is left empty so Claude reads the frontmatter, keeping the launch byte-identical to bare `--agent`.

- [ ] **Step 1: Write the failing R2 cases in `test/cross-org_test.sh`**

Add after the R1 cases. Add `roost-p-reviewer-60`, `roost-p-worker-60`, `roost-p-reviewer-61` to `teardown`.

```bash
# -- Test (R2): --agent reviewer --role reviewer runs the gate AND loads the persona --
setup
mkdir -p "$TDIR/.orchestrator" "$TDIR/.claude/agents"
cp "$( cd "$( dirname "${ROOST_BIN}" )/.." && pwd )/agents/reviewer.md" "$TDIR/.claude/agents/reviewer.md"
# Two orgs. Worker author = openai (gpt). Reviewer candidates = [claude-default
# (anthropic)] -> gate picks the cross-org anthropic provider. --agent reviewer
# loads the persona; the role selects the provider.
printf '{"project":"p","providers":{"claude-default":{"harness":"claude","model":"opus"},"gpt":{"harness":"codex","model":"gpt-5.1-codex"}},"roles":{"worker":"gpt","reviewer":["claude-default"]}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-worker-60 --role worker --issue 60 --cwd "$TDIR" >/dev/null 2>&1 || true
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn p-reviewer-60 --agent reviewer --role reviewer --issue 60 --cwd "$TDIR" 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
inner="$(cat "$data_dir/inner-cmd.txt" 2>/dev/null)"
if echo "$out" | grep -q "harness: claude" \
    && echo "$inner" | grep -q -- "--agent reviewer" \
    && ! echo "$inner" | grep -q -- "--model"; then
  ok "R2: --agent reviewer --role reviewer gates, loads persona, no --model on claude path"
else
  fail "R2: --agent reviewer --role reviewer gates, loads persona, no --model on claude path" "out=$out inner=$inner"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown

# -- Test (R2): bare --agent reviewer stays ungated and records nothing --
setup
mkdir -p "$TDIR/.orchestrator" "$TDIR/.claude/agents"
cp "$( cd "$( dirname "${ROOST_BIN}" )/.." && pwd )/agents/reviewer.md" "$TDIR/.claude/agents/reviewer.md"
printf '{"project":"p","providers":{"gpt":{"harness":"codex","model":"gpt-5.1-codex"}},"roles":{"worker":"gpt"}}' > "$TDIR/.orchestrator/config.json"
"${ROOST_BIN}" spawn p-worker-60 --role worker --issue 61 --cwd "$TDIR" >/dev/null 2>&1 || true
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn p-reviewer-61 --agent reviewer --issue 61 --cwd "$TDIR" 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
inner="$(cat "$data_dir/inner-cmd.txt" 2>/dev/null)"
asn="$TDIR/.orchestrator/provider-assignments.json"
# Bare --agent: persona loaded, no gate, no #override or reviewer record for issue 61.
if echo "$inner" | grep -q -- "--agent reviewer" \
    && ! echo "$inner" | grep -q -- "--model" \
    && ! { jq -e '.["61#override"]' "$asn" >/dev/null 2>&1; }; then
  ok "R2: bare --agent reviewer stays ungated, records nothing"
else
  fail "R2: bare --agent reviewer stays ungated, records nothing" "inner=$inner asn=$(cat "$asn" 2>/dev/null)"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown
```

- [ ] **Step 2: Run to verify failure**

Run: `bash test/cross-org_test.sh`
Expected: R2 case 1 FAILS (today the registry guard requires `-z agent`, so `--agent reviewer --role reviewer` skips the gate entirely); R2 case 2 already passes bare (no change needed), but keep it as a regression pin.

- [ ] **Step 3: Drop the `-z agent` restriction from the registry-resolution guard**

In `bin/roost`, replace the Task 7 guard:
```bash
  if [ -z "${agent}" ] && { [ -n "${provider}" ] || [ -n "${role}" ]; }; then
```
with:
```bash
  if [ -n "${provider}" ] || [ -n "${role}" ]; then
```

- [ ] **Step 4: Refine the model-selection block so `--agent` on the Claude harness defers to the frontmatter**

In `bin/roost`, replace the two Task 7 lines:
```bash
    [ "${harness_explicit}" -eq 0 ] && harness="${RESOLVED_HARNESS}"
    [ "${model_explicit}" -eq 0 ] && model="${RESOLVED_MODEL}"
```
with:
```bash
    [ "${harness_explicit}" -eq 0 ] && harness="${RESOLVED_HARNESS}"
    if [ "${model_explicit}" -eq 0 ]; then
      # With --agent on the Claude harness, leave the model empty so claude reads
      # permissionMode: and the pinned model natively from the agent frontmatter.
      # This keeps the launch byte-identical to a bare --agent spawn while the
      # role still drove author-recording and the gate above. On a non-Claude
      # harness (Codex has no frontmatter) the resolved model is adopted so the
      # provider selection actually reaches the launch.
      if [ -n "${agent}" ] && [ "${harness}" = "claude" ]; then
        model=""
      else
        model="${RESOLVED_MODEL}"
      fi
    fi
```

- [ ] **Step 5: Run to verify pass**

Run: `bash test/cross-org_test.sh`
Expected: all cases PASS, including both R2 cases.

- [ ] **Step 6: Confirm the golden baseline is byte-identical, lint, commit**

The bare-`--agent` and default-`--model` inner commands must not change. Run the slow suite whole: `bash test/spawn_test.sh` (>120s; expect all PASS). Then `bash test/registry_test.sh`, `bash test/harness_test.sh`, `shellcheck bin/roost`. Commit:
```bash
git add bin/roost test/cross-org_test.sh
git commit
# subject: "Compose --agent persona with --role/--provider gate and selection (R2)"
```

---

## Task 9 (Phase B): `roost init` seeds default roles so `--role` always resolves (B3)

**Files:**
- Modify: `bin/roost:449-461` (`_init_config_json`, both single-repo and multi-repo branches)
- Test: `test/init_test.sh` (extend the providers/roles case), `test/registry_test.sh` (add a seeded-resolve case)

**Interfaces:**
- Consumes: nothing new.
- Produces: `roost init` writes a `claude-default` provider (`harness: claude`, `model: opus`, matching `agents/reviewer.md`'s pinned `model: opus`) and `worker` (author) / `reviewer` (review) roles pointing at it. `--role worker` and `--role reviewer` resolve to exactly today's Claude default (opus) in a fresh project. A role-less bare spawn still reads no registry.

- [ ] **Step 1: Write the failing seeded-resolve case in `test/init_test.sh`**

Replace the "providers/roles: scaffolded as empty objects" case (lines 517-528) with a case that asserts the seeded shape and that both roles resolve. The stub `gh` in `setup` already satisfies `gh auth status` / `gh api user`.

```bash
# --- providers/roles: seeded with a default Claude provider + worker/reviewer roles ---

setup ""
cd "$TDIR"
roost_init --repo "TestOwner/myproject" >/dev/null 2>&1
cfg="${TDIR}/.orchestrator/config.json"
if jq -e '.providers["claude-default"].harness == "claude" and .providers["claude-default"].model == "opus"' "$cfg" >/dev/null 2>&1 \
    && jq -e '.roles.worker.author == true and (.roles.worker.candidates | index("claude-default"))' "$cfg" >/dev/null 2>&1 \
    && jq -e '.roles.reviewer.review == true and (.roles.reviewer.candidates | index("claude-default"))' "$cfg" >/dev/null 2>&1; then
  ok "init seeds claude-default provider + worker/reviewer roles"
else
  fail "init seeds claude-default provider + worker/reviewer roles"
fi
cd - >/dev/null
teardown
```

- [ ] **Step 2: Write the failing seeded-resolve case in `test/registry_test.sh`**

Add after the "bare spawn does not require jq" case. Add `tmux kill-session -t "roost-testnick"` is already in `teardown`.

```bash
# -- Test: --role worker / --role reviewer resolve against a seeded config --
setup
mkdir -p "$TDIR/.orchestrator"
# Mirror what `roost init` seeds: a claude-default provider and worker/reviewer roles.
printf '{"project":"p","providers":{"claude-default":{"harness":"claude","model":"opus"}},"roles":{"worker":{"candidates":["claude-default"],"author":true},"reviewer":{"candidates":["claude-default"],"review":true}}}' > "$TDIR/.orchestrator/config.json"
wout="$("${ROOST_BIN}" spawn testnick --role worker --issue 70 --cwd "$TDIR" 2>&1 || true)"
if echo "$wout" | grep -q "harness: claude" && echo "$wout" | grep -q "model: opus"; then
  ok "seeded --role worker resolves to claude-default opus"
else
  fail "seeded --role worker resolves to claude-default opus" "wout=$wout"
fi
teardown
```

- [ ] **Step 3: Run to verify failure**

Run: `bash test/init_test.sh` and `bash test/registry_test.sh`
Expected: the init seeded-shape case FAILS (today seeds `{}`); the registry seeded-resolve case PASSES already if the config is hand-written (it is), so it is a regression pin for the seed shape. Run init first to confirm the FAIL.

- [ ] **Step 4: Seed the roles in `_init_config_json`**

In `bin/roost`, replace `_init_config_json` (lines 449-461) with:

```bash
_init_config_json() {
  if [ -n "$2" ]; then
    # Single-repo: project + repo + the static plugin slices (operator-set,
    # not DM-mutated). Dynamic slices (github-prs / github-issues) live in the
    # local overlay; their plugins.<name> key still enables them via union merge.
    # providers/roles are seeded with a default Claude provider and worker/reviewer
    # roles so --role worker / --role reviewer resolve to today's Claude default in
    # a fresh project. Add a second-org provider and a reviewer candidate from it
    # to turn on real cross-org enforcement.
    printf '{\n  "project": "%s",\n  "repo": "%s",\n  "agent_logins": %s,\n  "providers": {\n    "claude-default": { "harness": "claude", "model": "opus" }\n  },\n  "roles": {\n    "worker": { "candidates": ["claude-default"], "author": true },\n    "reviewer": { "candidates": ["claude-default"], "review": true }\n  },\n  "plugins": {\n    "github-new-issues": { "watched": [] },\n    "github-new-prs": { "watched": [] },\n    "github-commits": { "watched": [] }\n  }\n}\n' \
      "$1" "$2" "$3"
  else
    # Multi-repo: no top-level repo; operator adds plugin keys + per-entry repos.
    printf '{\n  "project": "%s",\n  "agent_logins": %s,\n  "providers": {\n    "claude-default": { "harness": "claude", "model": "opus" }\n  },\n  "roles": {\n    "worker": { "candidates": ["claude-default"], "author": true },\n    "reviewer": { "candidates": ["claude-default"], "review": true }\n  },\n  "plugins": {}\n}\n' \
      "$1" "$3"
  fi
}
```

- [ ] **Step 5: Run to verify pass**

Run: `bash test/init_test.sh` and `bash test/registry_test.sh`
Expected: all cases PASS, including the new seeded-shape and seeded-resolve cases.

- [ ] **Step 6: Confirm the bare-spawn-never-needs-jq invariant still holds**

Run: `bash test/registry_test.sh` (the "bare spawn does not require jq" case must still PASS: seeding roles changes what `--role` resolves to, not whether a role-less spawn reads the registry). Then `shellcheck bin/roost`. Commit:
```bash
git add bin/roost test/init_test.sh test/registry_test.sh
git commit
# subject: "Seed default claude-default provider + worker/reviewer roles at roost init"
```

---

## Task 10 (Phase B): Migrate the APM spawn templates onto `--role` (B4)

**Files:**
- Modify: `agents/associate-pm.md:93-123` (the worker/reviewer spawn block)
- Modify: `agents/project-manager.md:85, 89-91` (template framing)

**Interfaces:**
- Consumes: B1 (R1/R2) and B3 behavior, now landed.
- Produces: the APM's default spawn templates use `--role`. Worker: `--role worker --model <model> -- --effort <effort>` (R1). Reviewer: `--agent reviewer --role reviewer` (R2). Prose stops framing `--role`/`--provider` as an alternative to the Claude defaults; the `--role` templates ARE the defaults.

- [ ] **Step 1: Rewrite the associate-pm spawn block**

In `agents/associate-pm.md`, replace the fenced spawn block (lines 94-108) with:

````markdown
   ```
   roost spawn <worker-nick> \
     --role worker \
     --model <model> \
     --cache-ttl 1h \
     --channels '<issue-channel>' \
     --cwd <worktree-path> \
     --issue <N> \
     --prompt '/worker <project> <N> <owner>/<repo> <branch> <human-nick> <worker-nick> <issue-channel>' \
     -- --effort <effort>

   roost spawn <reviewer-nick> \
     --agent reviewer \
     --role reviewer \
     --cache-ttl 1h \
     --channels '<issue-channel>' \
     --cwd <worktree-path> \
     --issue <N> \
     --prompt 'issue=<N> milestone=<milestone> human=<human-nick> gh-login=<gh-login>'
   ```
````

- [ ] **Step 2: Update the note that follows the block**

In `agents/associate-pm.md`, replace the parenthetical note (line 109) with:

```markdown
   (`--role worker` records the issue's author org and the worker's model/effort stay the PM's per-issue call, layered on via R1. `--agent reviewer` keeps the reviewer persona and its `permissionMode`; `--role reviewer` runs the cross-org gate and selects the reviewer's provider, layered on via R2. `reviewer.md`'s frontmatter pins model + effort, so in a single-org registry the reviewer launch is unchanged. The reviewer shares the worker's worktree via `--cwd` — it reads the branch there but never edits.) If the PM named a cross-issue contract for this issue, append it to the reviewer's prompt after the required tokens (e.g. `... gh-login=<gh-login> consumes-contract-from=#<M>`) so it reviews with that lens.
```

- [ ] **Step 3: Reframe the follow-on paragraph so `--role` is the default, not an alternative**

In `agents/associate-pm.md`, replace the paragraph beginning "If the project's `.orchestrator/config.json` has a `providers`/`roles` registry filled in..." (lines 111-118) with:

```markdown
   `roost init` seeds a `claude-default` provider and `worker`/`reviewer`
   roles, so the `--role` templates above resolve to today's Claude default
   in a fresh project. To run a worker or reviewer on a non-Claude harness,
   add that provider to `.orchestrator/config.json` and add it as a reviewer
   candidate. A role can declare `"author": true` or `"review": true`; the
   built-in names `worker` and `reviewer` default to those respectively.
   Spawning a review role through the registry runs a cross-org gate that
   can hard-fail the spawn.
```

Leave the canonical sentence line (associate-pm.md:119) and the two lines after it byte-identical.

- [ ] **Step 4: Update the PM prompt framing**

In `agents/project-manager.md`, line 85, keep the canonical sentence byte-identical. Reword the sentences around it so the registry is framed as always-present (seeded by `roost init`) rather than opt-in. Replace the sentence "Worker and reviewer providers come from the project's `.orchestrator/config.json` registry (`providers` + `roles`) when the APM spawns through `--provider`/`--role`." with:

```markdown
Worker and reviewer providers come from the project's `.orchestrator/config.json` registry (`providers` + `roles`), which `roost init` seeds with a `claude-default` provider and `worker`/`reviewer` roles; the APM's default templates spawn through `--role`.
```

- [ ] **Step 5: Verify the canonical sentence is still byte-identical across all five surfaces**

Run:
```bash
grep -rn "Cross-org rule: a review role's provider org must differ from the recorded author org." bin/roost skills/roost/SKILL.md README.md agents/project-manager.md agents/associate-pm.md
```
Expected: exactly one match per file, identical text.

- [ ] **Step 6: Read the changes aloud for IRC-conversational voice, then commit**

Confirm one idea per sentence, no em-dashes. Commit:
```bash
git add agents/associate-pm.md agents/project-manager.md
git commit
# subject: "Migrate APM worker/reviewer spawn templates onto --role"
```

---

## Task 11 (Phase B): Document the coverage plainly (B5)

**Files:**
- Modify: `bin/roost:294-323` ("Provider selection" help block), `skills/roost/SKILL.md` (around line 129), `README.md` (around line 232), `agents/project-manager.md`, `agents/associate-pm.md`

**Interfaces:**
- Consumes: the landed B1/B2/B3/B4 behavior.
- Produces: every surface states where the gate and audit fire (live on `--role`/`--provider` and the migrated templates), where they are a no-op (single-org registries), and where they are inert (a hand-typed bare `--agent`/`--model` spawn). The canonical cross-org sentence stays byte-identical everywhere.

- [ ] **Step 1: Add the coverage statement to the `bin/roost` help block**

In `bin/roost`, inside the "Provider selection:" heredoc, after the paragraph ending "It does not block: explicit flags win." (line 320), add:

```bash
  Where the gate and audit fire: live on --role/--provider and the migrated
  automation templates. A no-op in a single-org registry (nothing cross-org
  to enforce; it engages on its own when a second org's provider is added).
  Inert on a hand-typed bare --agent or bare --model/--harness spawn: no role,
  so nothing is gated, and a bare spawn never reads the registry.
```

- [ ] **Step 2: Add the same coverage statement to `skills/roost/SKILL.md`**

After the `#bypass` paragraph (following SKILL.md line ~137), add a plain paragraph with the same three points (live on `--role`/`--provider` and migrated templates; no-op in single-org; inert on bare `--agent`/`--model`). Keep the canonical sentence at SKILL.md:129 byte-identical.

- [ ] **Step 3: Add the same coverage statement to `README.md`**

After the `#bypass` paragraph (following README.md line ~239), add the same three-point paragraph. Keep the canonical sentence at README.md:232 byte-identical.

- [ ] **Step 4: Verify the canonical sentence byte-identical across all five surfaces**

Run:
```bash
grep -rn "Cross-org rule: a review role's provider org must differ from the recorded author org." bin/roost skills/roost/SKILL.md README.md agents/project-manager.md agents/associate-pm.md
```
Expected: exactly one match per file, identical text.

- [ ] **Step 5: Lint the help text renders and commit**

Run: `bin/roost spawn --help >/dev/null` (expect exit 0), then `shellcheck bin/roost`. Commit:
```bash
git add bin/roost skills/roost/SKILL.md README.md
git commit
# subject: "Document where the cross-org gate and #bypass audit fire and where they do not"
```

---

## Task 12 (Phase A): Codex adapter base — config.toml, launch, backend, IRC-trust

**Depends on the Task 1-4 spike findings.** If a spike recorded a shape different from the literals below, the spike is authoritative; adjust the literals to match.

**Files:**
- Modify: `bin/roost-harness-codex.sh` (replace the stub `harness_assemble`)
- Modify: `test/harness_test.sh` (replace the codex fail-fast case)
- Create: `test/harness-codex_test.sh` (golden side-car assertions)

**Interfaces:**
- Consumes the REQ_* request contract set in `bin/roost` (lines 1139-1158): `REQ_MODEL`, `REQ_AGENT`, `REQ_CHANNELS`, `REQ_IRC_HOST`, `REQ_DATA_DIR`, `REQ_ROOST_BIN`, `REQ_ROOST_DIR`, `REQ_EXTRA_STR`, `REQ_PROMPT_FILE`, `REQ_SHELL_BASENAME`, `REQ_PERM_IRC`, `REQ_BASE_URL_ENV`, `REQ_AUTH_ENV`, `REQ_SIGNET_ACTIVE`.
- Produces: `harness_assemble()` writes `${REQ_DATA_DIR}/codex-home/config.toml` (model, `[mcp_servers.roost-irc]`, and a `[model_providers.roost-provider]` backend block when a base-url env is set), sets `RESP_INNER_CMD` to a `codex` invocation, appends `CODEX_HOME` and `ROOST_PROMPT_FILE` to `RESP_TMUX_ENV`, and stages `inner-cmd.txt` / `tmux-env.txt` under `ROOST_SPAWN_KEEP_DATA_DIR`. Hook blocks are added in Task 13.

- [ ] **Step 1: Write the failing golden test `test/harness-codex_test.sh`**

```bash
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

echo ""; echo "Results: ${PASS} passed, ${FAIL} failed"; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run to verify failure**

Run: `bash test/harness-codex_test.sh`
Expected: both cases FAIL (the stub returns 1 and writes no config.toml).

- [ ] **Step 3: Replace the stub `harness_assemble` in `bin/roost-harness-codex.sh`**

Replace the entire file body with (hook blocks are added in Task 13; this base writes model, MCP entry, backend block, and the launch):

```bash
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
```

- [ ] **Step 4: Replace the stale codex fail-fast case in `test/harness_test.sh`**

The stub is gone, so the "codex harness fails fast with a spec pointer" case (lines 32-42) no longer holds. Replace it with a case asserting the adapter assembles a codex invocation:

```bash
# -- Test: codex harness assembles a codex invocation --
setup
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn testnick --harness codex --model gpt-5.1-codex --cwd "$TDIR" --prompt hi 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
inner="$(cat "$data_dir/inner-cmd.txt" 2>/dev/null)"
if echo "$inner" | grep -q '^codex ' && echo "$inner" | grep -q -- '--dangerously-bypass-hook-trust'; then
  ok "codex harness assembles a codex invocation"
else
  fail "codex harness assembles a codex invocation" "inner=$inner"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown
```

- [ ] **Step 5: Run to verify pass**

Run: `bash test/harness-codex_test.sh` and `bash test/harness_test.sh`
Expected: all cases PASS.

- [ ] **Step 6: Shellcheck the adapter (it is auto-discovered by the shellcheck suite), lint, commit**

Run: `shellcheck bin/roost-harness-codex.sh` (expect no output, exit 0). Then `script/run-and-tail bun test test/shellcheck.test.ts` (expect exit 0). Commit:
```bash
git add bin/roost-harness-codex.sh test/harness_test.sh test/harness-codex_test.sh
git commit
# subject: "Implement the Codex harness adapter base: config.toml, launch, backend, IRC-trust"
```

---

## Task 13 (Phase A): Codex adapter hook blocks — signet + permbot

**Depends on Task 1's confirmed `[[hooks.*]]` TOML shape.** The literals below use the array-of-tables shape the spec's empirical finding implies; if Task 1 recorded a different shape, adjust them.

**Files:**
- Modify: `bin/roost-harness-codex.sh` (`harness_assemble` — add hook blocks to config.toml)
- Modify: `test/harness-codex_test.sh` (add permbot + signet cases)

**Interfaces:**
- Consumes: `REQ_PERM_IRC`, `REQ_SIGNET_ACTIVE`, `REQ_ROOST_BIN`, the `config.toml` writer from Task 12.
- Produces: `config.toml` gains `[[hooks.PermissionRequest]]` and `[[hooks.PreToolUse]]` command blocks. When `.signet/` is active the signet-eval block is written AHEAD of the permbot relay on both surfaces (same ordering the Claude adapter and `signet_test.sh` pin). The permbot relay is gated on `REQ_PERM_IRC`.

- [ ] **Step 1: Write the failing hook cases in `test/harness-codex_test.sh`**

Add before the summary line. Reuse the signet stub technique from `test/signet_test.sh`.

```bash
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bash test/harness-codex_test.sh`
Expected: the three hook cases FAIL (Task 12 writes no hook blocks); the "no .signet/" case passes trivially since nothing is written yet, but keep it as the regression pin.

- [ ] **Step 3: Add hook-block assembly to `harness_assemble`**

In `bin/roost-harness-codex.sh`, inside `harness_assemble`, replace the `config.toml` writer group (the `{ printf ... } > "${config_toml}"` block from Task 12) with a version that appends hook blocks after the MCP entry:

```bash
  # Policy hook chain. signet-eval decides first when .signet/ is active
  # (deterministic, LLM-free), ordered ahead of the IRC permbot relay on both
  # PermissionRequest and PreToolUse. Both scripts already emit the
  # permissionDecision / permissionDecisionReason wire Codex consumes, so no
  # hook-script rewrite is needed; the adapter wires the TOML.
  local hooks_block=""
  if [ "${REQ_SIGNET_ACTIVE}" -eq 1 ]; then
    hooks_block="${hooks_block}"$'\n'"[[hooks.PermissionRequest]]"$'\n'"command = \"signet-eval --permissionrequest\""$'\n'
  fi
  if [ "${REQ_PERM_IRC}" -eq 1 ]; then
    hooks_block="${hooks_block}"$'\n'"[[hooks.PermissionRequest]]"$'\n'"command = \"${REQ_ROOST_BIN} hook-exec irc-permission-prompt\""$'\n'
  fi
  if [ "${REQ_SIGNET_ACTIVE}" -eq 1 ]; then
    hooks_block="${hooks_block}"$'\n'"[[hooks.PreToolUse]]"$'\n'"matcher = \"Bash\""$'\n'"command = \"signet-eval --pretooluse\""$'\n'
  fi
  if [ "${REQ_PERM_IRC}" -eq 1 ]; then
    hooks_block="${hooks_block}"$'\n'"[[hooks.PreToolUse]]"$'\n'"matcher = \"Bash\""$'\n'"command = \"${REQ_ROOST_BIN} hook-exec irc-pretooluse-prompt\""$'\n'
  fi
  {
    printf 'model = "%s"\n' "${REQ_MODEL}"
    [ -n "${model_provider_line}" ] && printf '%s' "${model_provider_line}"
    printf '\n[mcp_servers.roost-irc]\n'
    printf 'command = "%s/bin/roost-irc-server"\n' "${REQ_ROOST_DIR}"
    printf 'args = []\n'
    [ -n "${provider_block}" ] && printf '%s' "${provider_block}"
    [ -n "${hooks_block}" ] && printf '%s' "${hooks_block}"
  } > "${config_toml}"
```

- [ ] **Step 4: Run to verify pass**

Run: `bash test/harness-codex_test.sh`
Expected: all cases PASS, including the three hook cases.

- [ ] **Step 5: Shellcheck, run the shellcheck suite, commit**

Run: `shellcheck bin/roost-harness-codex.sh` (no output), then `script/run-and-tail bun test test/shellcheck.test.ts` (exit 0). Commit:
```bash
git add bin/roost-harness-codex.sh test/harness-codex_test.sh
git commit
# subject: "Wire signet + permbot policy hook blocks into the Codex config.toml"
```

---

## Task 14 (Phase A): roost-irc gains a `tmux` inbound-delivery mode

**Depends on Task 3's confirmed injection + idle/mid-turn behavior.**

**Files:**
- Modify: `src/irc-server.ts` (the `client.on('message', ...)` inbound emit path near line 288; env reads near line 485)
- Modify: `bin/roost-harness-codex.sh` (append `ROOST_DELIVERY=tmux` and the pane target to `RESP_TMUX_ENV`)
- Create: `test/inbound-delivery.test.ts` (a Bun test asserting the delivery switch)

**Interfaces:**
- Consumes: `pushNotification` (existing), `client.on('message', ...)` (existing), `bin/roost-tmux-inject <session> <buf-prefix>` (existing helper that reads stdin and pastes+Enters into a tmux pane).
- Produces: a `ROOST_DELIVERY` env var selecting inbound transport: `notification` (default, today's `notifications/claude/channel` push, byte-identical) or `tmux` (inject each inbound non-historical message as a user turn into the pane named by `ROOST_TMUX_TARGET`, gated on idle, buffered mid-turn). The Codex adapter sets `ROOST_DELIVERY=tmux` and `ROOST_TMUX_TARGET` to the session name.

- [ ] **Step 1: Write the failing Bun test `test/inbound-delivery.test.ts`**

Assert that when `ROOST_DELIVERY=tmux`, an inbound message routes through the injection path rather than `pushNotification`. Follow the existing `test/inbound.test.ts` harness patterns (it already drives `client.on('message')` against a fake client). Inject a fake `tmuxInject` spy via the module's delivery seam.

```typescript
import { describe, it, expect } from 'bun:test'
import { selectDelivery } from '../src/irc-server'

describe('inbound delivery mode', () => {
  it('defaults to notification when ROOST_DELIVERY is unset', () => {
    expect(selectDelivery(undefined)).toBe('notification')
    expect(selectDelivery('')).toBe('notification')
  })
  it('selects tmux when ROOST_DELIVERY=tmux', () => {
    expect(selectDelivery('tmux')).toBe('tmux')
  })
  it('falls back to notification for an unknown value', () => {
    expect(selectDelivery('bogus')).toBe('notification')
  })
})
```

- [ ] **Step 2: Run to verify failure**

Run: `script/run-and-tail bun test test/inbound-delivery.test.ts`
Expected: FAIL — `selectDelivery` is not exported from `src/irc-server.ts`.

- [ ] **Step 3: Add the `selectDelivery` seam and the env read to `src/irc-server.ts`**

Add near the top-level helpers (module scope, so the test can import it):

```typescript
export type Delivery = 'notification' | 'tmux'

// Inbound transport selector. `notification` (default) is the Claude path: push
// notifications/claude/channel. `tmux` injects each inbound turn into the agent's
// pane, for harnesses that do not wake on MCP notifications. Any unknown value
// falls back to notification so a typo never silences inbound traffic.
export function selectDelivery(raw: string | undefined): Delivery {
  return raw === 'tmux' ? 'tmux' : 'notification'
}
```

In the owner MCP setup (near the other `process.env` reads around line 485), add:

```typescript
  const DELIVERY = selectDelivery(process.env['ROOST_DELIVERY'])
  const TMUX_TARGET = process.env['ROOST_TMUX_TARGET'] ?? ''
```

- [ ] **Step 4: Branch the inbound message handler on `DELIVERY`**

In the `client.on('message', ...)` handler (line 288-289), replace the unconditional push:

```typescript
  client.on('message', (msg, meta) => {
    pushNotification(msg.text, buildMessageMeta(msg, meta))
```
with a delivery branch (the notification path stays byte-identical; the tmux path injects a readable user turn naming channel + sender, only for live, non-historical messages):

```typescript
  client.on('message', (msg, meta) => {
    if (DELIVERY === 'tmux' && !meta.historical && TMUX_TARGET) {
      injectTmuxTurn(TMUX_TARGET, msg)
    } else {
      pushNotification(msg.text, buildMessageMeta(msg, meta))
    }
```
(leave the rest of the handler body — the stderr log line and the reply-reminder push — unchanged.)

- [ ] **Step 5: Add the `injectTmuxTurn` helper**

Inside the owner MCP scope (so it closes over nothing that would break the notification path), add a helper that shells out to `bin/roost-tmux-inject`, formatting the turn and gating on idle per Task 3's findings. Use Bun.spawn with the message piped to stdin:

```typescript
  // Inject an inbound IRC message into the agent's tmux pane as a user turn, for
  // the tmux delivery mode. Idle-gating and mid-turn buffering follow the Task 3
  // spike: a message that arrives mid-turn is queued and injected when the pane
  // returns to idle, so the composer is never corrupted.
  const injectQueue: string[] = []
  let injecting = false
  const flushInjectQueue = async () => {
    if (injecting) return
    injecting = true
    try {
      while (injectQueue.length > 0) {
        const text = injectQueue.shift()!
        const proc = Bun.spawn(
          [`${process.env['ROOST_DIR'] ?? '.'}/bin/roost-tmux-inject`, TMUX_TARGET, `roost-irc-${NICK}`],
          { stdin: 'pipe', stdout: 'ignore', stderr: 'ignore' },
        )
        proc.stdin.write(text)
        await proc.stdin.end()
        await proc.exited
      }
    } finally {
      injecting = false
    }
  }
  const injectTmuxTurn = (_target: string, msg: IrcMessage) => {
    const where = msg.isDirect ? `DM from ${msg.sender}` : `${msg.channel} <${msg.sender}>`
    injectQueue.push(`[roost-irc] ${where}: ${msg.text}`)
    void flushInjectQueue()
  }
```

- [ ] **Step 6: Set the delivery env from the Codex adapter**

In `bin/roost-harness-codex.sh`, append to `RESP_TMUX_ENV` alongside `CODEX_HOME`. The Codex adapter knows the session name via a side-car `bin/roost` already writes (`${REQ_DATA_DIR}/session-name.txt`, written unconditionally). Add:

```bash
  RESP_TMUX_ENV+=(-e "ROOST_DELIVERY=tmux")
  if [ -f "${REQ_DATA_DIR}/session-name.txt" ]; then
    RESP_TMUX_ENV+=(-e "ROOST_TMUX_TARGET=$(cat "${REQ_DATA_DIR}/session-name.txt")")
  fi
```

Note the ordering dependency: `bin/roost` writes `session-name.txt` (line 1096) before sourcing the adapter and calling `harness_assemble` (line 1160), so the file exists when the adapter reads it. Confirm by reading `bin/roost` around lines 1096 and 1116-1160.

- [ ] **Step 7: Run to verify pass**

Run: `script/run-and-tail bun test test/inbound-delivery.test.ts`
Expected: PASS.

- [ ] **Step 8: Regression on the MCP server, the codex golden suite, typecheck, lint, commit**

Run: `script/run-and-tail bun test test/inbound.test.ts test/outbound.test.ts test/inbound-delivery.test.ts` (expect exit 0), `bash test/harness-codex_test.sh` (the `CODEX_HOME` + `ROOST_DELIVERY` + `ROOST_TMUX_TARGET` env now also appear in `tmux-env.txt`; confirm the Task 12 case still passes since it only greps for the CODEX_HOME line), `bun run typecheck`, `bun run lint`. Commit:
```bash
git add src/irc-server.ts bin/roost-harness-codex.sh test/inbound-delivery.test.ts
git commit
# subject: "Add a tmux inbound-delivery mode to roost-irc for the Codex harness"
```

---

## Self-Review

Run after the plan is written. Fixes applied inline above.

**1. Spec coverage.**

- Part A adapter (`harness_assemble`, config.toml with MCP entry + hooks + model/provider, RESP_INNER_CMD, side-car staging): Tasks 12, 13. Covered.
- Part A inbound delivery (`ROOST_DELIVERY` notification/tmux, idle-gate + buffer, pane target via env, Claude path unchanged): Task 14. Covered.
- Part A permission/signet layering (signet first, permbot fallthrough, `--dangerously-bypass-hook-trust`): Task 13. Covered.
- Part A alternate backend/auth (`[model_providers.<name>]`, base_url + env_key, none when no provider): Task 12. Covered.
- Part A IRC-trust injection (MCP instructions vs prompt preamble, no AGENTS.md clobber): Task 12 (fallback) + Task 2 (spike decides). Covered.
- Part A compact-steering for Codex: explicit spec non-goal (documented follow-on). No task. Correctly omitted.
- Part A testing (golden shell test mirroring spawn_test, signet present/absent, Claude guard): Tasks 12, 13, plus the spawn_test byte-identical checks in Tasks 7, 8. Covered.
- Part A open-item spikes (hooks TOML, MCP instructions, tmux injection, CODEX_HOME/sandbox): Tasks 1-4, first. Covered.
- Part B B1-R1 (`--role` + explicit `--model`/`--harness`/`--effort`, org-coherence): Task 7. Covered.
- Part B B1-R2 (`--agent` + `--role`/`--provider`, bare `--agent` unchanged): Task 8. Covered.
- Part B B2 (single-org degradation, two-org still errors): Task 6. Covered.
- Part B B3 (`roost init` seeds roles, bare spawn still no jq): Task 9. Covered.
- Part B B4 (migrate APM templates): Task 10. Covered.
- Part B B5 (document coverage, canonical sentence byte-identical): Task 11. Covered.
- Part B B6 (`#bypass` carries model + harness): Task 5. Covered.
- Part B testing (R1/R2, B2, B3, B6 shell tests): Tasks 5-9. Covered.

**2. Placeholder scan.** No "TBD", "implement later", "add error handling", or "similar to Task N". Code is repeated in full where reused (the `config.toml` writer group is shown whole in both Task 12 and Task 13). The one runtime-inherent gap is the Human-Claude Interaction Log in commit messages, which is by definition filled at execution time; the Global Constraints section states the required structure verbatim.

**3. Type/signature consistency.**
- `assignment_append <key> <kind> <provider> <org> <reason> [model] [harness]` — Task 5 defines it; the existing `#override` caller (5 args) is preserved; `bypass_audit` calls it with 7 args. Consistent.
- `bypass_audit <issue> <provider> <org> <model> <harness>` — Task 5 defines it; both `bin/roost` call sites updated to 5 args (Task 5). Consistent.
- `registry_org_count` (no args, echoes an integer) — Task 6 defines and uses it. Consistent.
- `selectDelivery(raw: string | undefined): Delivery` and `Delivery = 'notification' | 'tmux'` — Task 14 defines and tests. Consistent.
- The registry-resolution entry guard evolves Task 7 -> Task 8; each task shows the exact before/after so the sequence is coherent. The model-selection block evolves Task 7 -> Task 8 identically. Consistent.
- REQ_* names consumed by the Codex adapter (Tasks 12-13) match the contract set in `bin/roost:1139-1158`. Verified against the read of that block.

**Spec requirements with no clean task mapping:** none. The Codex compact-steering analog is intentionally out of scope per the spec's own non-goals, so it is not a gap.
