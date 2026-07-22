# Multi-provider harnesses — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the seams in `bin/roost` so an agent's provider and model come from a role→provider registry, enforce a cross-org review hard-gate by vendor lineage, layer signet-eval in front of the existing permission relay, and register (but stub) a Codex harness — all with zero behavior change on today's Claude path.

**Architecture:** `bin/roost spawn` gains a `--harness` concept. The Claude-specific launch assembly moves behind a sourced adapter file (`bin/roost-harness-claude.sh`) that fills a fixed request→response contract. A sourced registry module (`bin/roost-registry.sh`) resolves `--role`/`--provider` against `.orchestrator/config.json`, computes vendor-lineage org, records per-issue author-org, and enforces the cross-org gate before a reviewer spawns. The Codex adapter is a fail-fast stub. signet-eval is wired ahead of the untouched classifyBash/IRC-permbot path when `.signet/` exists.

**Tech Stack:** Bash (spawn wrapper + adapters + registry, tested with plain-bash `test/*_test.sh`), `jq` (JSON reads, gated by a preflight), TypeScript/Bun (existing MCP + orchestrator, untouched in Phase 1 except optional config scaffolding).

## Global Constraints

Copy these verbatim into every task's mental checklist. They come from the spec and the repo's standing rules.

- **Zero behavior change on the Claude path.** The full existing `test/spawn_test.sh` suite (Tests 1–42) MUST stay green after every task. It is the golden baseline for the refactor.
- **No registry present = exactly today's behavior.** Resolution order, first match wins: explicit `--harness`/`--model` flags → `--provider <name>` → `--role <name>` → default `claude`/`opus`.
- **`--model` and `--agent` remain mutually exclusive** (existing rule at `bin/roost:718`). A resolved provider sets `--model`, so it conflicts with `--agent` the same way.
- **Org = model vendor lineage.** Default map: `claude-*` → `anthropic`; `gpt-*`, `o1`, `o3`, `o4`, and other `o<digit>*` → `openai`. Unknown model with no explicit `org` in the provider entry = spawn error, never a silent guess (§#548).
- **Cross-org rule = hard gate + logged override.** Same-org review is refused unless `--allow-same-org "<reason>"` is passed; the override is recorded to assignment state and printed loudly. `bin/roost` never posts to IRC itself.
- **signet-eval layers, never rewrites.** classifyBash and the IRC permbot relay are not modified. signet runs first; ALLOW/DENY short-circuit; ASK or no-match falls through unchanged. This preserves the §#598 TUI-parity guarantee by construction.
- **signet activation is auto-on when `.signet/` exists**, made visible (a banner line) and reversible (`--no-signet`).
- **`jq` is a spawn-time dependency behind a preflight**, not a hook-runtime dependency. Do NOT add `jq` to any hook script (`bin/roost-compact-hook`, `bin/_dispatcher-pid-lib.sh` deliberately avoid it). The registry/gate run at spawn time only.
- **Timeless in-tree comments.** No PR/issue/version refs in code or shipped docs (`(#276)`, `since v3`, etc.). Dated design/plan docs and commit messages keep their refs; code and `SKILL.md`/`README.md`/agent prompts do not.
- **IRC-conversational prose.** One idea per sentence. No em-dashes. Concrete instruction next to any jargon.
- **Doc sync when `bin/roost` changes** (§#608): update `skills/roost/SKILL.md`, and glance at `README.md` and `agents/*.md`.
- **Commit discipline (CLAUDE.md).** Every commit carries the Human-Claude Interaction Log and the Claude attribution trailer.
- **Test hygiene.** Never pipe `bun test` through `tail`/`head`/`grep`; use `script/run-and-tail`. Shell tests run with `bash test/<name>_test.sh`.

---

## File Structure

**Create:**
- `bin/roost-harness-claude.sh` — Claude adapter. Defines `harness_assemble`. Holds the launch-command assembly, settings-JSON hook wiring, trust injection, and MCP wiring extracted from `bin/roost`.
- `bin/roost-harness-codex.sh` — Codex adapter stub. Defines `harness_assemble` that prints a fail-fast pointer to the follow-on spec and exits non-zero.
- `bin/roost-registry.sh` — Registry + policy module. Defines `registry_resolve` (role/provider → provider fields), `registry_vendor_org` (model → org), `assignment_record` / `assignment_lookup` (per-issue author-org state), and `policy_gate_reviewer` (cross-org enforcement).
- `test/harness_test.sh` — `--harness` flag validation + codex stub behavior.
- `test/registry_test.sh` — provider/role resolution, precedence, vendor-lineage org, unknown-model error, env backend swap.
- `test/cross-org_test.sh` — assignment recording + cross-org gate + override.
- `test/signet_test.sh` — signet layering, `.signet/` detection, `--no-signet`, banner.

**Modify:**
- `bin/roost` — new flags (`--harness`, `--provider`, `--role`, `--issue`, `--allow-same-org`, `--no-signet`); source adapter + registry; replace inline Claude assembly with `harness_assemble`; jq preflight; signet wiring + `.signet/` banner; extend `spawn --help`; extend `_init_config_json` with empty `providers`/`roles`; add `provider-assignments.json` to the `.orchestrator/.gitignore` writer.
- `skills/roost/SKILL.md`, `README.md`, `agents/associate-pm.md`, `agents/project-manager.md` — doc sync for the new spawn surface.
- `.claude/rules/project-learnings.md` — no change in Phase 1 (learning is captured post-merge).

**Contract globals** (the request→response interface between `bin/roost` and every adapter):
- Request (set by `bin/roost`, read by the adapter): `REQ_MODEL`, `REQ_AGENT`, `REQ_PERMISSION_MODE`, `REQ_HOOK_PERM_MODE`, `REQ_CHANNELS`, `REQ_IRC_HOST`, `REQ_DATA_DIR`, `REQ_SETTINGS_PATH`, `REQ_ROOST_BIN`, `REQ_ROOST_DIR`, `REQ_MCP_CONFIG`, `REQ_EXTRA_STR`, `REQ_PROMPT_FILE`, `REQ_SHELL_BASENAME`, `REQ_PERM_IRC`, `REQ_ASK_ROUTING`, `REQ_STEER_COMPACT`, `REQ_SIGNET_ACTIVE`, `REQ_BASE_URL_ENV`, `REQ_AUTH_ENV`.
- Response (set by the adapter, read by `bin/roost`): `RESP_INNER_CMD` (string), `RESP_TMUX_ENV` (bash array of `-e KEY=VAL` pairs to append), plus side-car files written into `REQ_DATA_DIR` (`roost-settings.json`, `trust-prompt.txt`, `inner-cmd.txt`).

---

## Task 1: `--harness` flag, validation, and banner

**Files:**
- Modify: `bin/roost` (arg parse near `:664-724`; banner near `:867`; `spawn --help` near `:157-227`)
- Test: `test/harness_test.sh`

**Interfaces:**
- Produces: a `harness` shell local, defaulting to `claude`, validated to the set `{claude, codex}`. Consumed by Task 2/3 dispatch.

- [ ] **Step 1: Write the failing test**

Create `test/harness_test.sh` (model it on `test/spawn_test.sh`'s `ok`/`fail`/`setup`/`teardown` scaffold — copy lines 1–26 of that file verbatim for the harness):

```bash
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

echo ""; echo "Results: ${PASS} passed, ${FAIL} failed"; [ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/harness_test.sh`
Expected: FAIL — `--harness` is an unknown flag, banner has no `harness:` field.

- [ ] **Step 3: Add the flag, validation, and banner field**

In `bin/roost`'s `cmd_spawn` local declarations (near `:664`), add:

```bash
  local harness="claude"
```

In the arg-parse `case` (near `:692-711`, alongside `-m|--model)`), add:

```bash
      --harness)        harness="$2"; shift 2 ;;
```

After the arg-parse loop, before the model default at `:722`, add validation:

```bash
  case "${harness}" in
    claude|codex) ;;
    *) echo "error: unknown harness '${harness}' — must be one of: claude, codex" >&2; return 1 ;;
  esac
```

In the spawn banner `echo` (near `:867`), add `harness: ${harness}` after `model: ${model}`:

```bash
  echo "spawning ${nick} in ${channels} (session ${session_name}, model: ${model}, harness: ${harness}, permission-mode: ${permission_mode:-(claude default)}, cache-ttl: ${cache_ttl:-(claude default)}, shell: ${shell_basename}, cwd: ${cwd})"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/harness_test.sh`
Expected: PASS (both cases).

- [ ] **Step 5: Confirm the golden suite still passes**

Run: `bash test/spawn_test.sh`
Expected: `Results: N passed, 0 failed` (the banner gained a field but all existing assertions match on substrings, so they still hold).

- [ ] **Step 6: Commit**

```bash
git add bin/roost test/harness_test.sh
git commit -m "$(cat <<'EOF'
feat(roost): add --harness flag (claude|codex) with validation + banner

<Human-Claude Interaction Log + attribution trailer per CLAUDE.md>
EOF
)"
```

---

## Task 2: Extract the Claude adapter (behavior-preserving move-refactor)

**Files:**
- Create: `bin/roost-harness-claude.sh`
- Modify: `bin/roost` (`:895-1094` region — hook wiring, settings write, MCP/agent/model/trust flags, `inner_cmd` assembly)
- Test: `test/spawn_test.sh` (unchanged — it is the golden guard)

**Interfaces:**
- Consumes: the `REQ_*` contract globals listed in File Structure.
- Produces: `harness_assemble` sets `RESP_INNER_CMD`, appends to the `RESP_TMUX_ENV` array, and writes `roost-settings.json` + `trust-prompt.txt` + `inner-cmd.txt` into `REQ_DATA_DIR`.

This task is a pure extraction. The code that moves is already correct and golden-tested. Do NOT rewrite its logic — relocate it verbatim into a function and replace the call site. The safety net is that `test/spawn_test.sh` must stay byte-for-byte green.

- [ ] **Step 1: Confirm the golden baseline is green before touching anything**

Run: `bash test/spawn_test.sh`
Expected: `Results: N passed, 0 failed`. If not green, STOP — fix the environment first (ergo/tmux), do not start the refactor against a red baseline.

- [ ] **Step 2: Create the adapter file with the contract entrypoint**

Create `bin/roost-harness-claude.sh`:

```bash
#!/usr/bin/env bash
# Claude harness adapter for roost spawn. Sourced by bin/roost.
# Reads the REQ_* request contract, writes side-car files into REQ_DATA_DIR,
# and sets RESP_INNER_CMD + appends to the RESP_TMUX_ENV array.
# This is the extracted Claude launch assembly. Behavior must match the
# pre-extraction bin/roost exactly — test/spawn_test.sh is the guard.

harness_assemble() {
  # --- BEGIN moved block: hook wiring + settings JSON (from bin/roost :895-966) ---
  # (paste lines 895-966 verbatim, renaming the referenced locals to REQ_*:
  #   ${perm_irc}         -> ${REQ_PERM_IRC}
  #   ${ask_routing}      -> ${REQ_ASK_ROUTING}     (compute from REQ_ASK_ROUTING)
  #   ${steer_compact}    -> ${REQ_STEER_COMPACT}
  #   ${hook_perm_mode}   -> ${REQ_HOOK_PERM_MODE}
  #   ${ROOST_BIN}        -> ${REQ_ROOST_BIN}
  #   ${IRC_HOST}         -> ${REQ_IRC_HOST}
  #   ${ROOST_DATA_DIR}   -> ${REQ_DATA_DIR}
  #   ${ROOST_SETTINGS}   -> ${REQ_SETTINGS_PATH}
  #   perm_sock / perm_hook_json stay as adapter-locals)
  # --- END moved block ---

  # --- BEGIN moved block: MCP/agent/model/perm/trust flags + inner_cmd (from :1005-1094) ---
  # (paste lines 1025-1094 verbatim, renaming:
  #   ${mcp_config}       -> ${REQ_MCP_CONFIG}
  #   ${agent}            -> ${REQ_AGENT}
  #   ${model}            -> ${REQ_MODEL}
  #   ${permission_mode}  -> ${REQ_PERMISSION_MODE}
  #   ${channels}         -> ${REQ_CHANNELS}
  #   ${extra_str}        -> ${REQ_EXTRA_STR}
  #   ${prompt_file}      -> ${REQ_PROMPT_FILE}
  #   ${shell_basename}   -> ${REQ_SHELL_BASENAME}
  #   ${ROOST_DIR}        -> ${REQ_ROOST_DIR}
  #  and change `local inner_cmd=...` to `RESP_INNER_CMD=...`,
  #  and change `tmux_env+=(...)` to `RESP_TMUX_ENV+=(...)`)
  # --- END moved block ---

  # Stage inner-cmd.txt for the test seam (was bin/roost :1094-ish).
  printf '%s' "${RESP_INNER_CMD}" > "${REQ_DATA_DIR}/inner-cmd.txt"
}
```

Then physically move lines `:895-966` and `:1025-1094` from `bin/roost` into the two marked blocks, applying the local→`REQ_*` renames noted. Keep the `perm_sock`, `perm_hook_json`, `precompact_hook_json`, `pretooluse_*`, `permissions_json` locals inside the function.

- [ ] **Step 3: Wire `bin/roost` to source and call the adapter**

In `bin/roost`, near the top-level source lines (where `ROOST_DIR`/`ROOST_BIN` resolve), source the module directory:

```bash
# shellcheck source=bin/roost-harness-claude.sh
source "$(dirname "${ROOST_BIN}")/bin/roost-harness-${harness}.sh" 2>/dev/null || {
  echo "error: no adapter for harness '${harness}'" >&2; return 1;
}
```

Note: source AFTER `harness` is validated (Task 1) and AFTER `ROOST_DATA_DIR`/`ROOST_SETTINGS` are set. Place the `source` immediately before the old `:895` hook-wiring block used to start.

At the old call site (where `:895-966` and `:1025-1094` were), set the request globals and call the entrypoint:

```bash
  local RESP_INNER_CMD=""
  local RESP_TMUX_ENV=()
  REQ_MODEL="${model}" REQ_AGENT="${agent}" REQ_PERMISSION_MODE="${permission_mode}" \
  REQ_HOOK_PERM_MODE="${hook_perm_mode}" REQ_CHANNELS="${channels}" REQ_IRC_HOST="${IRC_HOST}" \
  REQ_DATA_DIR="${ROOST_DATA_DIR}" REQ_SETTINGS_PATH="${ROOST_SETTINGS}" REQ_ROOST_BIN="${ROOST_BIN}" \
  REQ_ROOST_DIR="${ROOST_DIR}" REQ_MCP_CONFIG="${mcp_config}" REQ_EXTRA_STR="${extra_str}" \
  REQ_PROMPT_FILE="${prompt_file}" REQ_SHELL_BASENAME="${shell_basename}" REQ_PERM_IRC="${perm_irc}" \
  REQ_ASK_ROUTING="${ask_routing}" REQ_STEER_COMPACT="${steer_compact}"
  harness_assemble
  local inner_cmd="${RESP_INNER_CMD}"
  tmux_env+=("${RESP_TMUX_ENV[@]}")
```

(Export the `REQ_*` as needed so the sourced function sees them; since it is sourced in the same shell, plain assignment before the call is sufficient — set them on their own lines rather than as a one-line prefix if the function is not a subshell.)

- [ ] **Step 4: Run the golden suite — must be byte-identical behavior**

Run: `bash test/spawn_test.sh`
Expected: `Results: N passed, 0 failed` — identical pass count to Step 1. Any regression here means the extraction changed behavior; diff the moved block against the original.

- [ ] **Step 5: Lint**

Run: `bun run lint` (runs `shellcheck bin/*` — the new `bin/roost-harness-claude.sh` is covered by `bin/*`).
Expected: no new shellcheck findings.

- [ ] **Step 6: Commit**

```bash
git add bin/roost bin/roost-harness-claude.sh
git commit -m "refactor(roost): extract Claude launch assembly behind harness_assemble contract"
# (+ interaction log + attribution)
```

---

## Task 3: Codex adapter stub (fail-fast)

**Files:**
- Create: `bin/roost-harness-codex.sh`
- Test: `test/harness_test.sh` (extend)

**Interfaces:**
- Produces: `harness_assemble` for the codex harness that exits non-zero with a pointer to the follow-on spec.

- [ ] **Step 1: Write the failing test** (append to `test/harness_test.sh` before the results line)

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/harness_test.sh`
Expected: FAIL — sourcing `bin/roost-harness-codex.sh` currently errors generically or the message text is absent.

- [ ] **Step 3: Create the stub**

Create `bin/roost-harness-codex.sh`:

```bash
#!/usr/bin/env bash
# Codex harness adapter — STUB. The adapter contract slot is real; the body is
# deferred to its own follow-on spec (see docs/superpowers/specs/ for the Codex
# adapter design and its two feasibility spikes). This is intentionally a hard,
# specific failure so a codex-* provider in the registry points at real work
# rather than looking like a config typo.

harness_assemble() {
  echo "error: codex harness not yet implemented — see docs/superpowers/specs/ for the Codex adapter follow-on spec" >&2
  return 1
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash test/harness_test.sh`
Expected: PASS. Also confirm the source line in `bin/roost` propagates the non-zero return (the spawn aborts).

- [ ] **Step 5: Commit**

```bash
git add bin/roost-harness-codex.sh test/harness_test.sh
git commit -m "feat(roost): register Codex harness as a fail-fast stub"
```

---

## Task 4: `jq` preflight

**Files:**
- Modify: `bin/roost` (add a `require_jq`-style check invoked in `cmd_spawn` before registry use)
- Test: `test/registry_test.sh`

**Interfaces:**
- Produces: a guard that errors clearly if `jq` is absent, ONLY when registry resolution is actually needed (a `--role`/`--provider` spawn, or any spawn in a project that has `.orchestrator/config.json` with a `providers`/`roles` block). A bare `roost spawn testnick` with no registry must not require jq.

- [ ] **Step 1: Write the failing test**

Create `test/registry_test.sh` with the standard scaffold (copy the header block from Task 1 Step 1, rename temp prefix to `roost-registry-test`), then:

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/registry_test.sh`
Expected: FAIL — no jq guard and no registry resolution yet, so the `--role` path does not produce either signal.

- [ ] **Step 3: Add the guard**

In `bin/roost`, add near the other `require_*` helpers:

```bash
require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "error: roost registry resolution (--role / --provider / .orchestrator providers) requires jq, which was not found on PATH." >&2
  echo "       Install jq (brew install jq) or spawn with explicit --harness/--model instead." >&2
  return 1
}
```

Call `require_jq || return 1` at the top of the registry-resolution branch you add in Task 5 (not unconditionally — bare spawns must not need jq).

- [ ] **Step 4: Run to verify it passes**

Run: `bash test/registry_test.sh` (both cases). The `--role` case will still not fully resolve until Task 5; for now assert only that the jq guard fires when jq is absent. Once Task 5 lands, re-run and confirm the resolution branch.
Expected: PASS for the "bare spawn does not require jq" case now; the `--role` case passes fully after Task 5.

- [ ] **Step 5: Commit**

```bash
git add bin/roost test/registry_test.sh
git commit -m "feat(roost): add jq preflight for registry resolution only"
```

---

## Task 5: Registry resolution — `--provider` and `--role`

**Files:**
- Create: `bin/roost-registry.sh`
- Modify: `bin/roost` (new locals `provider`, `role`; arg parse; resolution branch; sourcing)
- Test: `test/registry_test.sh` (extend)

**Interfaces:**
- Consumes: `.orchestrator/config.json` with optional `providers` and `roles` objects.
- Produces: `registry_resolve <role-or-provider-selector>` sets globals `RESOLVED_HARNESS`, `RESOLVED_MODEL`, `RESOLVED_BASE_URL_ENV`, `RESOLVED_AUTH_ENV`, `RESOLVED_ORG`, `RESOLVED_PROVIDER_NAME`. Returns non-zero with a clear message on unknown provider/role.
- Precedence in `bin/roost` (first match wins): explicit `--harness`/`--model` → `--provider` → `--role` → default `claude`/`opus`.

- [ ] **Step 1: Write the failing tests** (append to `test/registry_test.sh`)

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/registry_test.sh`
Expected: FAIL — no `--provider`/`--role` flags yet.

- [ ] **Step 3: Create `bin/roost-registry.sh` with `registry_resolve`**

```bash
#!/usr/bin/env bash
# Registry + policy module for roost spawn. Sourced by bin/roost.
# Reads .orchestrator/config.json (providers + roles) via jq. Spawn-time only.

# Path to the project config, relative to the spawn cwd.
_registry_config_path() { echo ".orchestrator/config.json"; }

# registry_provider_fields <provider-name>
# Sets RESOLVED_* from the provider entry. Returns 1 if the provider is absent.
registry_provider_fields() {
  local name="$1" cfg; cfg="$(_registry_config_path)"
  [ -f "$cfg" ] || { echo "error: no .orchestrator/config.json in $(pwd) — cannot resolve provider '${name}'" >&2; return 1; }
  local entry
  entry="$(jq -c --arg n "$name" '.providers[$n] // empty' "$cfg")"
  [ -n "$entry" ] || { echo "error: unknown provider '${name}' — not found in .orchestrator/config.json providers" >&2; return 1; }
  RESOLVED_PROVIDER_NAME="$name"
  RESOLVED_HARNESS="$(printf '%s' "$entry" | jq -r '.harness // "claude"')"
  RESOLVED_MODEL="$(printf '%s' "$entry" | jq -r '.model // empty')"
  RESOLVED_BASE_URL_ENV="$(printf '%s' "$entry" | jq -r '.base_url_env // empty')"
  RESOLVED_AUTH_ENV="$(printf '%s' "$entry" | jq -r '.auth_env // empty')"
  RESOLVED_ORG="$(printf '%s' "$entry" | jq -r '.org // empty')"  # may be empty; filled by vendor lineage in Task 6
  [ -n "$RESOLVED_MODEL" ] || { echo "error: provider '${name}' has no model in .orchestrator/config.json" >&2; return 1; }
  return 0
}

# registry_role_candidates <role> -> prints provider names, one per line, in preference order.
registry_role_candidates() {
  local role="$1" cfg; cfg="$(_registry_config_path)"
  [ -f "$cfg" ] || { echo "error: no .orchestrator/config.json in $(pwd) — cannot resolve role '${role}'" >&2; return 1; }
  local val
  val="$(jq -c --arg r "$role" '.roles[$r] // empty' "$cfg")"
  [ -n "$val" ] || { echo "error: unknown role '${role}' — not found in .orchestrator/config.json roles" >&2; return 1; }
  # Normalize string-or-array to a newline list.
  printf '%s' "$val" | jq -r 'if type=="array" then .[] else . end'
}

# registry_resolve_role <role>: resolve to the FIRST candidate (Task 8 replaces
# this with the policy gate for reviewer roles).
registry_resolve_role() {
  local role="$1" first
  first="$(registry_role_candidates "$role" | head -1)" || return 1
  [ -n "$first" ] || { echo "error: role '${role}' has an empty candidate set" >&2; return 1; }
  registry_provider_fields "$first"
}
```

- [ ] **Step 4: Wire resolution into `bin/roost`**

Add locals near `:664`: `local provider=""` and `local role=""`. Add arg-parse cases:

```bash
      --provider)       provider="$2"; shift 2 ;;
      --role)           role="$2"; shift 2 ;;
```

After harness validation (Task 1) and before the model default (`:722`), insert the resolution branch. It runs only when the registry selectors are used, so bare spawns skip jq entirely:

```bash
  if [ "${model_explicit}" -eq 0 ] && [ -z "${agent}" ] && { [ -n "${provider}" ] || [ -n "${role}" ]; }; then
    require_jq || return 1
    # shellcheck source=bin/roost-registry.sh
    source "$(dirname "${ROOST_BIN}")/bin/roost-registry.sh"
    if [ -n "${provider}" ]; then
      registry_provider_fields "${provider}" || return 1
    else
      registry_resolve_role "${role}" || return 1
    fi
    harness="${RESOLVED_HARNESS}"
    model="${RESOLVED_MODEL}"
    # base_url_env / auth_env consumed in Task 9.
  fi
```

Keep the existing `--model`/`--agent` mutual-exclusion check (`:718`). Add a symmetric guard: `--provider`/`--role` are mutually exclusive with each other and with explicit `--model` (explicit `--model` simply wins and skips the branch above, which is the desired precedence; add an explicit error only if both `--provider` and `--role` are set):

```bash
  if [ -n "${provider}" ] && [ -n "${role}" ]; then
    echo "error: --provider and --role are mutually exclusive" >&2; return 1
  fi
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash test/registry_test.sh`
Expected: PASS (all cases, including the Task 4 `--role` case now resolving).

- [ ] **Step 6: Confirm golden suite + lint**

Run: `bash test/spawn_test.sh && bun run lint`
Expected: spawn suite green, no shellcheck findings.

- [ ] **Step 7: Commit**

```bash
git add bin/roost bin/roost-registry.sh test/registry_test.sh
git commit -m "feat(roost): resolve --provider/--role from the registry"
```

---

## Task 6: Vendor-lineage org + unknown-model guard

**Files:**
- Modify: `bin/roost-registry.sh` (`registry_vendor_org`; call it inside `registry_provider_fields` when `org` is empty)
- Test: `test/registry_test.sh` (extend)

**Interfaces:**
- Produces: `registry_vendor_org <model>` echoes the org (`anthropic`/`openai`) or empty if unknown. `registry_provider_fields` sets `RESOLVED_ORG` from an explicit `org` if present, else from lineage, and errors if still empty.

- [ ] **Step 1: Write the failing tests** (append to `test/registry_test.sh`)

```bash
# -- Test: claude-* model without explicit org resolves org=anthropic (visible via a debug echo) --
# We expose resolution via ROOST_SPAWN_KEEP_DATA_DIR + a resolved-provider.txt side-car (added in this task).
setup
mkdir -p "$TDIR/.orchestrator"; printf '%s' "$CFG" > "$TDIR/.orchestrator/config.json"
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn testnick --provider claude-opus --cwd "$TDIR" 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
if [ -n "$data_dir" ] && grep -q '"org":"anthropic"' "$data_dir/resolved-provider.txt" 2>/dev/null; then
  ok "claude-* lineage → org anthropic"
else
  fail "claude-* lineage → org anthropic" "out=$out rp=$(cat "$data_dir/resolved-provider.txt" 2>/dev/null)"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown

# -- Test: unknown model without org errors --
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"weird":{"harness":"claude","model":"mystery-7b"}}}' > "$TDIR/.orchestrator/config.json"
err="$("${ROOST_BIN}" spawn testnick --provider weird --cwd "$TDIR" 2>&1)"; ec=$?
if [ "$ec" -ne 0 ] && echo "$err" | grep -q "cannot determine org for model 'mystery-7b'" && echo "$err" | grep -q '"org"'; then
  ok "unknown model without org errors, names the fix"
else
  fail "unknown model without org errors, names the fix" "ec=$ec err=$err"
fi
teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/registry_test.sh`
Expected: FAIL — no lineage computation, no `resolved-provider.txt`, unknown model does not error.

- [ ] **Step 3: Add lineage + guard to `bin/roost-registry.sh`**

```bash
# registry_vendor_org <model> -> echoes org by weight lineage, or empty if unknown.
registry_vendor_org() {
  local m="$1"
  case "$m" in
    claude-*|opus|sonnet|haiku|fable) echo "anthropic" ;;
    gpt-*|o1|o1-*|o3|o3-*|o4|o4-*|o[0-9]*) echo "openai" ;;
    *) echo "" ;;
  esac
}
```

In `registry_provider_fields`, after reading `RESOLVED_ORG`, add:

```bash
  if [ -z "$RESOLVED_ORG" ]; then
    RESOLVED_ORG="$(registry_vendor_org "$RESOLVED_MODEL")"
  fi
  if [ -z "$RESOLVED_ORG" ]; then
    echo "error: cannot determine org for model '${RESOLVED_MODEL}' by vendor lineage — set an explicit \"org\" on provider '${RESOLVED_PROVIDER_NAME}' in .orchestrator/config.json" >&2
    return 1
  fi
```

Note: the bare aliases `opus`/`sonnet`/`haiku`/`fable` are Claude models used by the default Claude path; include them so a provider entry using a bare alias still resolves to `anthropic`.

- [ ] **Step 4: Stage `resolved-provider.txt` for the test seam**

In `bin/roost`, inside the registry-resolution branch (Task 5 Step 4), after resolution succeeds, add:

```bash
    printf '{"provider":"%s","harness":"%s","model":"%s","org":"%s"}\n' \
      "${RESOLVED_PROVIDER_NAME}" "${RESOLVED_HARNESS}" "${RESOLVED_MODEL}" "${RESOLVED_ORG}" \
      > "${ROOST_DATA_DIR}/resolved-provider.txt"
```

(Placed after `ROOST_DATA_DIR` exists. If `ROOST_DATA_DIR` is created later in the flow, move this write to just after the data-dir is established, still inside the resolved branch guarded by a non-empty `${RESOLVED_PROVIDER_NAME}`.)

- [ ] **Step 5: Run to verify it passes**

Run: `bash test/registry_test.sh`
Expected: PASS (all cases).

- [ ] **Step 6: Commit**

```bash
git add bin/roost bin/roost-registry.sh test/registry_test.sh
git commit -m "feat(roost): compute org by vendor lineage, error on unknown model"
```

---

## Task 7: Record author-org at worker spawn

**Files:**
- Modify: `bin/roost` (new locals `role`/`issue`; derive issue key; record assignment when the resolved role is a worker)
- Modify: `bin/roost-registry.sh` (`assignment_record`, `assignment_lookup`, `_assignment_path`)
- Modify: `bin/roost` `_init_config_local_json` gitignore writer (add `provider-assignments.json`)
- Test: `test/cross-org_test.sh`

**Interfaces:**
- Consumes: the resolved provider/org (Task 6) and an issue key.
- Produces: `.orchestrator/provider-assignments.json` mapping `issue -> {provider, org, role, override?, reason?, ts?}`, written atomically. `assignment_lookup <issue>` echoes the recorded org (empty if none).
- Issue key: from `--issue N`, else parsed from the first `#<project>-issue-<N>` channel in `--channels`.

- [ ] **Step 1: Write the failing tests**

Create `test/cross-org_test.sh` (standard scaffold, prefix `roost-crossorg-test`):

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/cross-org_test.sh`
Expected: FAIL — no `--issue` flag, no assignment recording.

- [ ] **Step 3: Add assignment helpers to `bin/roost-registry.sh`**

```bash
_assignment_path() { echo ".orchestrator/provider-assignments.json"; }

# assignment_record <issue> <role> <provider> <org> [override] [reason]
assignment_record() {
  local issue="$1" role="$2" provider="$3" org="$4" override="${5:-false}" reason="${6:-}"
  local f; f="$(_assignment_path)"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] || printf '{}' > "$f"
  local tmp; tmp="$(mktemp "${f}.XXXXXX")"
  jq --arg i "$issue" --arg role "$role" --arg p "$provider" --arg o "$org" \
     --argjson ov "$override" --arg reason "$reason" \
     '.[$i] = {provider:$p, org:$o, role:$role, override:$ov, reason:$reason}' \
     "$f" > "$tmp" && mv "$tmp" "$f"
}

# assignment_lookup <issue> -> echoes recorded org, or empty.
assignment_lookup() {
  local issue="$1" f; f="$(_assignment_path)"
  [ -f "$f" ] || return 0
  jq -r --arg i "$issue" '.[$i].org // empty' "$f"
}
```

- [ ] **Step 4: Add `--issue`, issue-key derivation, and the worker-record call in `bin/roost`**

Add locals: `local issue=""`. Arg-parse case: `--issue) issue="$2"; shift 2 ;;`.

After registry resolution succeeds, derive the issue key and record if this is a worker role:

```bash
  if [ -n "${role}" ] || [ -n "${provider}" ]; then
    # Derive issue key: explicit --issue wins, else parse first #<proj>-issue-<N> channel.
    local issue_key="${issue}"
    if [ -z "${issue_key}" ]; then
      issue_key="$(printf '%s' "${channels}" | grep -oE '#[a-zA-Z0-9_-]+-issue-[0-9]+' | head -1 | grep -oE '[0-9]+$' || true)"
    fi
    if [ "${role}" = "worker" ] && [ -n "${issue_key}" ]; then
      assignment_record "${issue_key}" "worker" "${RESOLVED_PROVIDER_NAME}" "${RESOLVED_ORG}"
      echo "  recorded author-org '${RESOLVED_ORG}' for issue ${issue_key} (provider ${RESOLVED_PROVIDER_NAME})"
    fi
  fi
```

(`registry.sh` is already sourced inside the resolution branch; ensure `assignment_record` is available there. If the record call sits outside that branch, source the module unconditionally when `role`/`provider` is set.)

- [ ] **Step 5: Add `provider-assignments.json` to the gitignore writer**

In `bin/roost`'s `_init_config_local_json` gitignore printf (`:411`), append `provider-assignments.json\n` to the list so the local assignment state is not tracked.

- [ ] **Step 6: Run to verify it passes**

Run: `bash test/cross-org_test.sh`
Expected: PASS (both cases).

- [ ] **Step 7: Commit**

```bash
git add bin/roost bin/roost-registry.sh test/cross-org_test.sh
git commit -m "feat(roost): record author-org per issue at worker spawn"
```

---

## Task 8: Cross-org gate for reviewer resolution + `--allow-same-org`

**Files:**
- Modify: `bin/roost-registry.sh` (`policy_gate_reviewer`)
- Modify: `bin/roost` (reviewer resolution path; `--allow-same-org` flag; override recording + loud print)
- Test: `test/cross-org_test.sh` (extend)

**Interfaces:**
- Consumes: reviewer candidate set (Task 5), recorded author-org (Task 7).
- Produces: `policy_gate_reviewer <issue> <role>` walks the candidate set in preference order, picks the first whose lineage org differs from the recorded author-org, sets `RESOLVED_*` for it, and prints a note if a non-top candidate was chosen. Hard-fails if all candidates are same-org. `--allow-same-org "<reason>"` bypasses the fail, records the override, and prints a loud warning.

- [ ] **Step 1: Write the failing tests** (append to `test/cross-org_test.sh`)

```bash
# -- Test: reviewer auto-picks the cross-org candidate --
setup
mkdir -p "$TDIR/.orchestrator"; printf '%s' "$CFG" > "$TDIR/.orchestrator/config.json"
# Author is openai (worker=gpt). reviewer candidates [claude-opus (anthropic), gpt (openai)].
# Gate must pick claude-opus (anthropic ≠ openai) even though... it is already first here;
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/cross-org_test.sh`
Expected: FAIL — reviewer resolution still uses first-candidate (Task 5), no gate, no `--allow-same-org`.

- [ ] **Step 3: Add `policy_gate_reviewer` to `bin/roost-registry.sh`**

```bash
# policy_gate_reviewer <issue> <role> <allow_same_org:0|1> <reason>
# Walks the role's candidate set, picks the first provider whose lineage org
# differs from the recorded author-org. Sets RESOLVED_* on success.
# Return codes: 0 ok; 2 no recorded author; 3 all same-org (no override).
policy_gate_reviewer() {
  local issue="$1" role="$2" allow="$3" reason="$4"
  local author_org; author_org="$(assignment_lookup "$issue")"
  if [ -z "$author_org" ]; then
    echo "error: no recorded author for issue ${issue} — spawn the worker first" >&2
    return 2
  fi
  local candidates; candidates="$(registry_role_candidates "$role")" || return 1
  local top="" chosen=""
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    [ -z "$top" ] && top="$cand"
    registry_provider_fields "$cand" || return 1
    if [ "$RESOLVED_ORG" != "$author_org" ]; then
      chosen="$cand"; break
    fi
  done <<< "$candidates"
  if [ -n "$chosen" ]; then
    if [ "$chosen" != "$top" ]; then
      echo "  cross-org gate: chose '${chosen}' over top candidate '${top}' (author org '${author_org}')"
    fi
    # RESOLVED_* already set to the chosen provider by the loop's last fields call.
    registry_provider_fields "$chosen"
    return 0
  fi
  # No cross-org candidate.
  if [ "$allow" = "1" ]; then
    registry_provider_fields "$top" || return 1
    echo "  WARNING: cross-org gate OVERRIDDEN — reviewer '${top}' is same org ('${author_org}') as the author. Reason: ${reason}" >&2
    assignment_record "$issue" "reviewer-override" "$top" "$RESOLVED_ORG" true "$reason"
    return 0
  fi
  echo "error: cross-org review rule — every reviewer candidate for issue ${issue} is same org ('${author_org}') as the author. Pass --allow-same-org \"<reason>\" to override." >&2
  return 3
}
```

- [ ] **Step 4: Wire the gate into `bin/roost`**

Add local `local allow_same_org=0` and `local allow_same_org_reason=""`. Arg-parse:

```bash
      --allow-same-org) allow_same_org=1; allow_same_org_reason="$2"; shift 2 ;;
```

Replace the plain `registry_resolve_role "${role}"` call (Task 5) with a role-aware branch:

```bash
    if [ -n "${provider}" ]; then
      registry_provider_fields "${provider}" || return 1
    elif [ "${role}" = "reviewer" ]; then
      # issue_key derived below in Task 7 must be available here; derive it before this branch.
      policy_gate_reviewer "${issue_key}" "reviewer" "${allow_same_org}" "${allow_same_org_reason}"
      case $? in 0) ;; *) return 1 ;; esac
    else
      registry_resolve_role "${role}" || return 1
    fi
```

Note on ordering: move the `issue_key` derivation (Task 7 Step 4) to BEFORE this resolution branch so the reviewer gate can use it. The worker-record call stays after resolution.

- [ ] **Step 5: Run to verify it passes**

Run: `bash test/cross-org_test.sh`
Expected: PASS (all cases).

- [ ] **Step 6: Confirm golden suite + registry suite + lint**

Run: `bash test/spawn_test.sh && bash test/registry_test.sh && bun run lint`
Expected: all green, no shellcheck findings.

- [ ] **Step 7: Commit**

```bash
git add bin/roost bin/roost-registry.sh test/cross-org_test.sh
git commit -m "feat(roost): enforce cross-org review gate with --allow-same-org override"
```

---

## Task 9: Env-based backend swap (`base_url_env` / `auth_env`)

**Files:**
- Modify: `bin/roost` (pass resolved `base_url_env`/`auth_env` into the adapter request; the claude adapter forwards them as env)
- Modify: `bin/roost-harness-claude.sh` (append `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` to `RESP_TMUX_ENV` from the named env vars when set)
- Test: `test/registry_test.sh` (extend)

**Interfaces:**
- Consumes: `RESOLVED_BASE_URL_ENV`, `RESOLVED_AUTH_ENV` (names of env vars holding the actual values).
- Produces: when set and the named env vars are populated, the claude adapter adds `-e ANTHROPIC_BASE_URL=<val>` and `-e ANTHROPIC_AUTH_TOKEN=<val>` to the tmux env.

- [ ] **Step 1: Write the failing test** (append to `test/registry_test.sh`)

```bash
# -- Test: provider base_url_env/auth_env flow into the inner env (via inner-cmd.txt env check) --
# The adapter appends to RESP_TMUX_ENV, which bin/roost passes via `tmux -e`.
# We assert on a staged env-manifest side-car the adapter also writes.
setup
mkdir -p "$TDIR/.orchestrator"
printf '{"project":"p","providers":{"alt":{"harness":"claude","model":"opus","base_url_env":"ALT_URL","auth_env":"ALT_TOK"}}}' > "$TDIR/.orchestrator/config.json"
out="$(ALT_URL="https://alt.example/v1" ALT_TOK="sk-test" ROOST_SPAWN_KEEP_DATA_DIR=1 "${ROOST_BIN}" spawn testnick --provider alt --cwd "$TDIR" 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
if [ -n "$data_dir" ] \
    && grep -qF 'ANTHROPIC_BASE_URL=https://alt.example/v1' "$data_dir/tmux-env.txt" 2>/dev/null \
    && grep -qF 'ANTHROPIC_AUTH_TOKEN=sk-test' "$data_dir/tmux-env.txt" 2>/dev/null; then
  ok "provider base_url_env/auth_env flow into tmux env"
else
  fail "provider base_url_env/auth_env flow into tmux env" "out=$out env=$(cat "$data_dir/tmux-env.txt" 2>/dev/null)"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/registry_test.sh`
Expected: FAIL — no backend-env forwarding, no `tmux-env.txt` manifest.

- [ ] **Step 3: Pass the resolved env-var names into the adapter request**

In `bin/roost`, set the request globals (Task 2 Step 3 block) to include:

```bash
  REQ_BASE_URL_ENV="${RESOLVED_BASE_URL_ENV:-}" REQ_AUTH_ENV="${RESOLVED_AUTH_ENV:-}"
```

- [ ] **Step 4: Forward the env in the claude adapter**

In `bin/roost-harness-claude.sh` `harness_assemble`, before writing `inner-cmd.txt`, add:

```bash
  if [ -n "${REQ_BASE_URL_ENV}" ]; then
    local _url_val="${!REQ_BASE_URL_ENV:-}"
    [ -n "${_url_val}" ] && RESP_TMUX_ENV+=(-e "ANTHROPIC_BASE_URL=${_url_val}")
  fi
  if [ -n "${REQ_AUTH_ENV}" ]; then
    local _tok_val="${!REQ_AUTH_ENV:-}"
    [ -n "${_tok_val}" ] && RESP_TMUX_ENV+=(-e "ANTHROPIC_AUTH_TOKEN=${_tok_val}")
  fi
  # Test seam: stage the tmux env additions for spawn tests.
  printf '%s\n' "${RESP_TMUX_ENV[@]}" > "${REQ_DATA_DIR}/tmux-env.txt"
```

(`${!VAR}` is bash indirect expansion — the value of the env var whose name is in `REQ_BASE_URL_ENV`.)

- [ ] **Step 5: Run to verify it passes**

Run: `bash test/registry_test.sh`
Expected: PASS.

- [ ] **Step 6: Confirm golden suite (the `tmux-env.txt` write must not break existing spawns) + lint**

Run: `bash test/spawn_test.sh && bun run lint`
Expected: green. Note: `tmux-env.txt` is written unconditionally now; ensure the array is non-empty-safe (`printf '%s\n' "${arr[@]}"` on an empty array prints one blank line, which is harmless).

- [ ] **Step 7: Commit**

```bash
git add bin/roost bin/roost-harness-claude.sh test/registry_test.sh
git commit -m "feat(roost): forward provider base_url_env/auth_env as Anthropic env"
```

---

## Task 10: signet-eval layering, `.signet/` detection, banner, `--no-signet`

**Files:**
- Modify: `bin/roost` (`.signet/` detection; `--no-signet` flag; banner line; `REQ_SIGNET_ACTIVE`)
- Modify: `bin/roost-harness-claude.sh` (wire signet-eval into the PreToolUse/PermissionRequest hook JSON ahead of the existing relay entries)
- Test: `test/signet_test.sh`

**Interfaces:**
- Consumes: presence of a `.signet/` directory in the spawn cwd; `--no-signet`.
- Produces: when `.signet/` exists and `--no-signet` absent, the claude adapter prepends signet-eval hook entries to `PreToolUse` (`--pretooluse` adapter) and to `PermissionRequest` (`--permissionrequest` adapter), BEFORE the existing `irc-pretooluse-prompt` / `irc-permission-prompt` entries, so signet decides first. A banner line announces activation.

- [ ] **Step 1: Write the failing tests**

Create `test/signet_test.sh` (standard scaffold, prefix `roost-signet-test`):

```bash
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash test/signet_test.sh`
Expected: FAIL — no signet detection or wiring.

- [ ] **Step 3: Detect `.signet/`, add `--no-signet`, banner, request global**

In `bin/roost`, add `local no_signet=0`. Arg-parse: `--no-signet) no_signet=1; shift ;;`.

After arg parse, compute activation (relative to the spawn cwd, which the spawn already `cd`s into or references via `--cwd`):

```bash
  local signet_active=0
  if [ "${no_signet}" -eq 0 ] && [ -d "${cwd:-.}/.signet" ]; then
    signet_active=1
    echo "  signet-eval policy active (.signet/ found)"
  fi
```

Add `REQ_SIGNET_ACTIVE="${signet_active}"` to the request-globals block (Task 2 Step 3).

- [ ] **Step 4: Wire signet ahead of the relay in the claude adapter**

In `bin/roost-harness-claude.sh`, inside the moved hook-wiring block, BEFORE the existing Bash PreToolUse entry is pushed, prepend a signet entry when active. Locate the `pretooluse_entries` construction and change it so signet goes first:

```bash
  # signet-eval decides first (deterministic). ALLOW/DENY short-circuit; ASK or
  # no-matching-rule falls through to the existing classifyBash + IRC relay,
  # which is left exactly as-is.
  if [ "${REQ_SIGNET_ACTIVE}" -eq 1 ]; then
    pretooluse_entries+=("{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"signet-eval --pretooluse\"}]}")
  fi
```

Place this push BEFORE the existing `if [ "${REQ_PERM_IRC}" -eq 1 ] && [ "${_skip_bash_hook}" -eq 0 ]` block so signet's Bash entry precedes the relay's. Also add, when active, a signet `PermissionRequest` entry ahead of the existing `perm_hook_json`:

```bash
  local signet_perm_json=""
  if [ "${REQ_SIGNET_ACTIVE}" -eq 1 ]; then
    signet_perm_json="{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"signet-eval --permissionrequest\"}]}"
  fi
```

Then in the settings `printf`, compose `PermissionRequest` so signet leads. If `perm_hook_json` currently starts with `,"PermissionRequest":[{...}]`, change the construction so both entries live in the array with signet first, e.g. build a `permissionrequest_array` from the non-empty pieces joined by commas and emit `,"PermissionRequest":[${permissionrequest_array}]` only when at least one piece exists. Keep the exact same JSON shape otherwise so no-signet output is byte-identical to today.

- [ ] **Step 5: Run to verify it passes**

Run: `bash test/signet_test.sh`
Expected: PASS (all four cases).

- [ ] **Step 6: Golden suite must still be byte-identical when `.signet/` is absent**

Run: `bash test/spawn_test.sh && bun run lint`
Expected: green. This proves the signet composition did not perturb the no-signet path (all existing tests run in temp dirs with no `.signet/`).

- [ ] **Step 7: Commit**

```bash
git add bin/roost bin/roost-harness-claude.sh test/signet_test.sh
git commit -m "feat(roost): layer signet-eval ahead of the IRC permission relay"
```

---

## Task 11: Documentation sync + config scaffolding

**Files:**
- Modify: `skills/roost/SKILL.md` (new spawn surface: `--harness`, `--provider`, `--role`, `--issue`, `--allow-same-org`, `--no-signet`; the registry; the cross-org gate; signet auto-on)
- Modify: `README.md` (spawn flag list; a short "multi-provider" subsection)
- Modify: `bin/roost` `spawn --help` (document the new flags + an "Agent class guidance"-adjacent note)
- Modify: `bin/roost` `_init_config_json` (scaffold empty `"providers": {}` and `"roles": {}`)
- Modify: `agents/associate-pm.md`, `agents/project-manager.md` (the APM announces cross-org overrides in `#<project>-leads`; workers/reviewers may be non-Claude)
- Test: `test/init_test.sh` (extend to assert the scaffolded keys)

**Interfaces:**
- Produces: docs consistent with the shipped CLI. No behavior change beyond `init` scaffolding.

- [ ] **Step 1: Scaffold registry keys in `_init_config_json` — write the failing test first**

In `test/init_test.sh`, add an assertion that a single-repo `roost init` produces `providers` and `roles` keys:

```bash
# -- Test: init scaffolds empty providers + roles --
# (follow the existing init_test.sh pattern for running init in a temp repo)
if jq -e 'has("providers") and has("roles")' .orchestrator/config.json >/dev/null; then
  ok "init scaffolds providers + roles keys"
else
  fail "init scaffolds providers + roles keys"
fi
```

Run: `bash test/init_test.sh` → FAIL.

Then edit `_init_config_json` (`:393`) so the single-repo printf includes `"providers": {},\n  "roles": {},\n` (and the multi-repo printf at `:397` likewise). Re-run: PASS.

- [ ] **Step 2: Extend `spawn --help`**

In the `usage_spawn` heredoc (near `:157-227`), document each new flag with one IRC-voice line. Add a short "Provider selection" block explaining the resolution order and that no registry means today's behavior. Reference the cross-org rule and `--allow-same-org` in one sentence. State that signet-eval is auto-on when `.signet/` exists and `--no-signet` disables it.

- [ ] **Step 3: Update `skills/roost/SKILL.md`**

Add the new flags to the command surface. Add a short "Multi-provider" section: registry lives in `.orchestrator/config.json`; roles map to providers; reviewers are auto-selected cross-org; the APM announces any `--allow-same-org` override in `#<project>-leads`. Keep it timeless (no issue refs) and IRC-voiced.

- [ ] **Step 4: Update `README.md`**

Add the new flags to the spawn synopsis and a two-paragraph "Running non-Claude agents / alternate backends" note. Keep it generic (this ships into other projects).

- [ ] **Step 5: Update agent prompts**

In `agents/associate-pm.md`: add a line that when spawning a reviewer the cross-org gate may hard-fail, and that using `--allow-same-org "<reason>"` REQUIRES announcing the override in `#<project>-leads`. In `agents/project-manager.md`: note that worker/reviewer providers come from the registry and that cross-org review is enforced.

- [ ] **Step 6: Run the full suite + lint**

Run: `bash test/spawn_test.sh && bash test/harness_test.sh && bash test/registry_test.sh && bash test/cross-org_test.sh && bash test/signet_test.sh && bash test/init_test.sh && bun run lint && bun run typecheck`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add skills/roost/SKILL.md README.md bin/roost agents/associate-pm.md agents/project-manager.md test/init_test.sh
git commit -m "docs(roost): sync SKILL/README/agent prompts + scaffold registry config"
```

---

## Final verification

- [ ] Run every shell test and the bun suite:

```bash
for t in spawn harness registry cross-org signet init; do echo "== $t =="; bash "test/${t}_test.sh" || echo "FAILED: $t"; done
script/run-and-tail bun test
bun run lint && bun run typecheck
```

Expected: all shell suites report `0 failed`; `bun test` exits 0; lint and typecheck clean.

- [ ] Open the PR with `Closes #<issue>` and a body summarizing Phase 1 scope, the deferred Codex adapter + its two spikes, and the `jq`-in-shell decision flagged for reviewer attention.

## Notes for the reviewer (design decisions worth a second look)

1. **`jq` as a spawn-time dependency.** The spec said the resolver "reads state via jq." Grounding revealed the repo deliberately avoids a hard `jq` dependency in hook/runtime scripts. Phase 1 keeps resolution in shell (per the approved decision) but gates `jq` behind a preflight that fires ONLY on registry use. A bare `roost spawn` never needs `jq`. If the reviewer prefers zero new spawn-time deps, the alternative is a small Bun/TS resolver invoked via a launcher (bun is always present); that trades one-language-spawn for no-jq. Flagged, not decided.
2. **Assignment state file** (`.orchestrator/provider-assignments.json`) is deliberately separate from the dispatcher's `state.json` to avoid colliding with dispatcher-owned writes and the structured merge driver. It is gitignored local state.
3. **signet composition** is additive-only: the no-signet settings JSON is byte-identical to today's, guarded by the untouched `spawn_test.sh`.
