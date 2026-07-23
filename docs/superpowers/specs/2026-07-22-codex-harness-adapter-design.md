# Codex harness adapter and cross-org automation enablement — design

## Goal

Two coupled deliverables that ship together:

**Part A — the Codex adapter.** Replace the fail-fast
`bin/roost-harness-codex.sh` stub with a working adapter that spawns an OpenAI
Codex CLI agent as a resident roost worker: joined to IRC, gated by the same
signet + permbot policy layer as Claude workers, and running as an OpenAI-org
provider under the cross-org review rules the registry enforces.

**Part B — cross-org enforcement on the automation path.** Wire roost's own
automation (the PM/APM spawn templates) onto the cross-org gate and
author-recording that already exist, so the security invariant is live for the
path automation actually uses, not just the explicit-flag paths an operator
types by hand.

The two are coupled because a Codex reviewer that automation cannot select
cross-org is a demo, not a feature. Part B is what makes a Codex reviewer
reachable; Part A is what a Codex reviewer runs on. They are independently
testable and can land in either order, but neither is complete without the
other.

## Background: what Phase 1 already gives us

The harness seam is in place. `bin/roost` resolves a provider (from
`--harness`/`--model`/`--provider`/`--role`), sets the `REQ_*` contract
globals, and sources `bin/roost-harness-<name>.sh`, whose `harness_assemble()`
reads those globals and writes back `RESP_INNER_CMD` plus `RESP_TMUX_ENV[]` and
any side-car files under `REQ_DATA_DIR`. The Claude adapter
(`bin/roost-harness-claude.sh`) is the reference implementation of that
contract.

The cross-org enforcement work that followed added a provider/role registry, a
reviewer gate keyed on role properties (`author`/`review`, with `worker` and
`reviewer` as built-in name defaults), author-recording into
`.orchestrator/provider-assignments.json`, and an append-safe `#bypass` audit
for explicit launch targets. The registry classifies OpenAI-family models as
org `openai`, so a Codex worker slots into the gate as a second org with no
change to the gate's core matching logic.

## Why Part B exists: the coverage gap in the enforcement as shipped

The gate and author-recording only fire on `--role`, `--provider`, and explicit
`--model`/`--harness`. roost's own automation does not use those paths by
default:

- The APM worker template spawns `--model <model>`. Explicit `--model`
  short-circuits the registry block, so no author org is recorded.
- The APM reviewer template spawns `--agent reviewer`. The `--agent` path skips
  the gate and is excluded from the `#bypass` audit.

So as shipped, automation running the default templates is neither gated nor
audited. The invariant is opt-in: it comes alive only if an operator both fills
the registry and rewrites the templates onto `--role`. A reviewer finding
flagged this against the repo's own rule that a fix narrower than the failure
mode is a blocker.

The reason this is acceptable to fold into the Codex work rather than patch
onto Phase 1: the gate only has teeth once a second org exists. In a single-org
(all-Anthropic) deployment there is nothing cross-org to enforce, so the gate is
a no-op there regardless of spawn path. The work that introduces a second org
is the Codex adapter. So the fix belongs where a cross-org pair first becomes
real and end-to-end testable.

## Empirical findings that anchor Part A

Two make-or-break unknowns were settled before designing, against Codex CLI
0.145.0 on the spawn host.

**Codex does not wake on MCP notifications (verified negative).** A standalone
stdio MCP server pushed three notification shapes into an idle, modal-free
Codex TUI: the standard `notifications/message`, roost-irc's exact custom
`notifications/claude/channel`, and an arbitrary custom method. The model
called a probe tool once at startup (so MCP connectivity and tool calls work),
then reacted to none of the notifications. So roost-irc's inbound-delivery
mechanism, which Claude Code wakes on, is a dead path for Codex. Inbound IRC
must reach a Codex agent another way.

**Codex hooks are a Claude-shape clone (verified favorable).** The binary
carries the same hook event names (`PreToolUse`, `PermissionRequest`,
`PostToolUse`, `PreCompact`, `PostCompact`, `SessionStart`, `SessionEnd`,
`SubagentStart`, `SubagentStop`, `Stop`), command-based handlers
(`HookHandlerConfig::Command`), and a `PreToolUsePermissionDecisionWire` with
`permissionDecision` / `permissionDecisionReason` / `hookSpecificOutput`. It
prints literal "Tool call blocked by PreToolUse hook" messages, so PreToolUse
genuinely blocks. Two deltas from Claude Code: hooks are declared in
`config.toml` rather than a `--settings` JSON file, and they sit behind a trust
hash that `--dangerously-bypass-hook-trust` unlocks for vetted automation.

**Alternate backends are a supported override.** Codex has
`[model_providers.<name>]` config with `base_url` and `env_key` (the name of
the env var holding the key), and it explicitly documents that a provider may
override `base_url`, `auth`, and `http_headers`. Setting `model_provider` to
that name selects it.

---

## Part A: the Codex harness adapter

A Codex worker is a resident `codex` TUI in a tmux pane, occupying the same
lifecycle slot as a Claude worker.

`bin/roost-harness-codex.sh` implements `harness_assemble()`:

1. Generates a per-session `config.toml` under `REQ_DATA_DIR` carrying the
   roost-irc MCP entry, the policy hook blocks, and the model/provider
   selection.
2. Sets `RESP_INNER_CMD` to a `codex` invocation that points at that config,
   bypasses hook trust, and passes the initial prompt.
3. Stages side-car files under `ROOST_SPAWN_KEEP_DATA_DIR` (the same gating the
   Claude adapter uses for `inner-cmd.txt`), so tests assert on generated
   artifacts without a live `codex` run.

Outbound IRC (the agent talking) uses the roost-irc MCP tools, which the spike
confirmed work. Inbound IRC (the agent listening) arrives as injected turns,
described below.

### Launch assembly

`RESP_INNER_CMD` takes the shape:

```
codex --no-alt-screen --dangerously-bypass-hook-trust \
  --ask-for-approval never \
  -c <config overrides pointing at the session config.toml> \
  "<initial prompt>"
```

The session `config.toml` (referenced via `CODEX_HOME` or `-c` overrides,
whichever proves cleaner in the plan spike) contains:

- `[mcp_servers.roost-irc]`: a stdio server entry whose `command`/`args` launch
  `roost-irc-server`, with `env` set to the same `ROOST_IRC_*` variables the
  Claude path exports. This is how the agent gets its outbound IRC tools and its
  identity (nick, channels).
- `[[hooks.PreToolUse]]` and `[[hooks.PermissionRequest]]`: the policy chain
  (see below).
- `model` and, when a non-default provider is resolved, `model_provider` plus a
  `[model_providers.<name>]` block.

Approval policy is `never`: the permbot and signet gate through the hooks, so
Codex's own approval prompt must not also fire. Sandbox choice is settled in the
plan spike, defaulting to the least-privilege mode that does not double-prompt.

### Inbound delivery: roost-irc gains a Codex mode

roost-irc keeps sole ownership of the IRC socket. A new `ROOST_DELIVERY` env var
selects how inbound traffic reaches the agent:

- `notification` (default): today's `notifications/claude/channel` MCP push.
  This is the Claude path and stays byte-identical.
- `tmux`: inject each inbound message as a user turn into the agent's pane via
  `tmux send-keys`, the same mechanism `bin/roost-compact-hook` already uses to
  steer a pane.

In `tmux` mode roost-irc needs the pane target, passed via env at spawn (the
adapter knows the pane because `bin/roost` spawns it). Injection is gated on the
session being idle and buffers while the model is mid-turn, so a message that
arrives during a turn is delivered when the turn ends rather than corrupting the
composer. The message is formatted as a readable user turn that names the
channel and sender.

Transport choice for v1 is `tmux send-keys`: proven in-tree, harness-agnostic,
no dependency on experimental Codex surfaces. Codex's experimental
app-server/remote-control protocol is a documented future upgrade for structured
turn injection, out of scope here.

The Claude delivery path is not modified. The existing `test/spawn_test.sh`,
which runs in `.signet`-free temp dirs and asserts the Claude launch, is the
guard that the default path is untouched.

### Permission and signet layering

Because Codex hooks mirror Claude Code's, the Phase 1 layering ports directly.
The adapter writes `[[hooks.PreToolUse]]` and `[[hooks.PermissionRequest]]`
command blocks that:

1. Run signet-eval first when `.signet/` is present in the spawn cwd (the same
   fail-closed-when-missing rule Phase 1 established), so signet decides before
   anything else.
2. Fall through to `bin/irc-permission-prompt` (the IRC permbot relay).

Both scripts already emit the `permissionDecision` / `permissionDecisionReason`
wire that Codex's `PreToolUsePermissionDecisionWire` consumes, so no hook-script
rewrite is expected; the adapter's work is the TOML wiring and the trust bypass.
`--dangerously-bypass-hook-trust` is passed because roost ships and vets its own
hooks.

Any change to the permission relay itself is held to the repo's parity rule:
empirical verification against Codex's native approval behavior before merge.

### Alternate backend and auth

A resolved provider's `base_url_env` / `auth_env` map to a generated
`[model_providers.<name>]` block: `base_url` set from the base-url value and
`env_key` set to the auth env var name, with top-level `model_provider =
"<name>"`. This is Codex's supported override surface, so a different
OpenAI-compatible endpoint slots in the same way the Claude adapter swaps
`ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`. When no non-default provider is
resolved, the adapter emits no `model_providers` block and Codex uses its own
default auth.

### IRC-trust injection

roost-irc's MCP handshake already carries the full IRC-usage instructions (the
`instructions` field in `src/irc-server.ts`). The preferred path is that Codex
surfaces MCP-server `instructions` to the model, which would require zero extra
work; this needs a one-message spike to confirm. The fallback, if Codex ignores
MCP-server instructions, is to prepend the trust text to the initial prompt. The
adapter will not clobber a project's `AGENTS.md`.

### Compact and steering

Codex has its own auto-compaction and a `PreCompact` hook event, so the
`--steer-compact` idea has a Codex analog. It is lower priority and out of scope
for v1. The adapter wires the permission and signet hooks; compact-steering is a
documented follow-on.

---

## Part B: cross-org enforcement on the automation path

The root cause of the coverage gap is that `bin/roost` treats `--agent`,
`--model`/`--harness`, and `--role`/`--provider` as mutually exclusive
short-circuits, when two of them are really on different axes. Closing the gap
is four changes plus a doc pass.

### B1. Compose the persona axis with the provider axis

Two orthogonal axes exist today but the dispatch forces a single winner:

- **Persona axis** — `--agent <name>` selects the agent file: its system
  prompt, its `permissionMode`, and its pinned model/effort. This is *who the
  agent is*.
- **Provider axis** — `--role`/`--provider`/`--model`/`--harness` select the
  model, harness, and backend, and `--role` additionally drives
  author-recording and the gate. This is *what the agent runs on*.

The dispatch must let them compose:

- **R1: `--role` composes with explicit `--model`/`--harness`/`--effort`.**
  `--role` drives author-recording and the gate and supplies the org; the
  explicit flags override the model/harness/effort for the run. An org-coherence
  check runs: if the override model's vendor org differs from the role's
  resolved org, the spawn errors, because picking a role from one org and a
  model from another is incoherent. In a single-org deployment the check never
  triggers, so a worker spawned `--role worker --model <model>` records
  authorship *and* keeps the PM's per-issue model choice.

- **R2: `--agent` composes with `--role`/`--provider`.** The agent supplies the
  persona and `permissionMode`; the role/provider supplies (and gates) the
  model/harness, overriding the agent frontmatter's model. Author-recording and
  the gate run per the role. `--agent` alone, with no provider-axis flag,
  keeps today's behavior exactly: persona plus frontmatter model, no gate, no
  registry read, no jq. That backward-compatible bare-`--agent` path is what the
  `spawn_test.sh` golden baseline pins.

The precedence rule stays as documented for *model selection* (explicit
`--model`/`--harness` beats `--provider` beats `--role` beats default). What
changes is that `--role`'s author-recording and gate now run even when an
explicit flag overrides the model, and `--agent`'s persona now coexists with a
provider-axis selection instead of suppressing it.

### B2. Single-org registries degrade the gate to a no-op

`policy_gate_reviewer` today errors when no candidate differs from the author
org, forcing `--allow-same-org` on every review. In a single-org registry that
is every review, which makes migrating the reviewer template to `--role
reviewer` unusable.

The gate gains one rule: **when the registry as a whole contains providers from
only one org, the reviewer gate allows** (there is no cross-org choice to make,
so nothing to enforce). It enforces exactly as today the moment a second org's
provider exists in the registry. The existing hard error is preserved for the
genuine misconfiguration: a registry that *does* contain a second org, but a
reviewer role whose candidates are all same-org as the author. That case still
errors and still takes `--allow-same-org "<reason>"` to override.

This is what turns finding 1's fix from opt-in into automatic: the default
reviewer role can carry `review: true` safely, the gate is silent in single-org
shops, and it engages on its own when an operator adds a Codex/OpenAI provider.

### B3. `roost init` seeds default roles so `--role` always resolves

`roost init` seeds `.orchestrator/config.json` with a default Claude provider
and `worker`/`reviewer` roles pointing at it, so a fresh orchestrated project
resolves `--role worker`/`--role reviewer` to exactly today's Claude default
behavior. Because the PM/APM flow already requires `.orchestrator/config.json`,
the migrated templates always resolve. Adding a Codex/OpenAI provider and a
reviewer candidate from it is the operator's one opt-in step to real cross-org
enforcement.

Bare `roost spawn <nick>` (no role, no provider) still needs no registry and no
jq. The seeded roles change what `--role` resolves to, not whether a
role-less spawn reads the registry. The bare-spawn-never-needs-jq invariant
holds.

### B4. Migrate the APM spawn templates onto `--role`

With B1 through B3 in place, the APM setup dance changes its default templates:

- **Worker:** `--role worker --model <model> -- --effort <effort>`. `--role
  worker` records authorship and the org; `--model`/`--effort` stay as the PM's
  per-issue call (R1).
- **Reviewer:** `--agent reviewer --role reviewer`. `--agent reviewer` keeps the
  reviewer persona and its `permissionMode`; `--role reviewer` runs the gate and
  selects the reviewer's provider (R2). The reviewer role's default provider
  matches `reviewer.md`'s pinned model, so single-org behavior is unchanged.

The APM prose stops framing `--role`/`--provider` as an alternative to the
Claude defaults. The `--role` templates *are* the defaults; a non-Claude
provider is just a different registry entry the same templates resolve.

### B5. Document the coverage plainly

`spawn --help`, `skills/roost/SKILL.md`, and the PM/APM prompts state where the
gate and audit fire and where they do not: live on `--role`/`--provider` and the
migrated automation templates, a no-op in single-org registries, and inert on a
hand-typed bare `--agent`/`--model` spawn. The canonical cross-org sentence
stays byte-identical across every surface per the repo's canonical-wording rule:
"a review role's provider org must differ from the recorded author org."

### B6. The `#bypass` record captures what was launched

`assignment_append` and `bypass_audit` gain `model` and `harness` fields so an
explicit-`--model`/`--harness` bypass record says *what* launched, not just
which org. `bin/roost` threads `${model}`/`${harness}` into `bypass_audit` at
both the `--provider` and explicit-flag call sites. This closes the audit-quality
finding on the explicit path: an auditor reading a `#bypass` entry back sees the
launched model and harness, matching the detail the `--provider` path already
records.

---

## Testing

### Part A

The primary gate is a golden shell test mirroring `test/spawn_test.sh`: spawn a
Codex worker with `ROOST_SPAWN_KEEP_DATA_DIR=1`, then assert the staged
side-cars are byte-correct. That means the generated `config.toml` (the
roost-irc MCP entry, the hook blocks, the model/provider selection), the
`RESP_INNER_CMD`, and `RESP_TMUX_ENV`. No live `codex` process runs in CI.

The signet-active and signet-absent branches get the same coverage the Claude
path has: a `.signet/`-present spawn wires the signet hook block ahead of the
permbot; a `.signet/`-absent spawn omits it.

A guard test asserts the Claude path stays byte-identical, which the existing
`spawn_test.sh` already provides.

Live behavior that a golden test cannot cover is verified by a small set of
explicitly quota-frugal manual spikes, named as the plan's first tasks. The
spawn host is under 10% of its weekly Codex limit, so the plan batches these into
one or two tiny sessions rather than burning runs: each spike does a single
startup turn and asserts on server-side logs, not model output.

### Part B

Shell tests extend `test/cross-org_test.sh` and `test/registry_test.sh`:

- R1: `--role worker --model <model>` records authorship with the role's org and
  runs on the override model; a cross-org override model errors.
- R2: `--agent reviewer --role reviewer` runs the gate and selects the role's
  provider while the agent persona is loaded; bare `--agent reviewer` stays
  ungated (the `spawn_test.sh` baseline covers the byte-identical bare case).
- B2: a single-org registry allows a same-org reviewer with no error and no
  `--allow-same-org`; a two-org registry with all-same-org candidates still
  errors.
- B3: `roost init` writes default provider + `worker`/`reviewer` roles; `--role
  worker`/`--role reviewer` resolve against the seeded config; a role-less bare
  spawn still reads no registry (jq-absent test stays green).
- B6: an explicit-`--model` `#bypass` record carries the launched model and
  harness, not just the org.

## Open items resolved as gated spikes in the plan

All Part A spikes are low-quota and settled before the adapter code they inform:

1. The exact `[[hooks.*]]` TOML nesting Codex expects (event key casing, field
   names like `command` / `timeout_sec` / `matcher`, list-vs-table form).
2. Whether Codex surfaces MCP-server `instructions` to the model (decides the
   IRC-trust injection path).
3. `tmux send-keys` injection behavior into the Codex TUI: that it wakes an idle
   session, and how it behaves mid-turn (informs the idle-gating and buffering).
4. Whether the session config is cleaner via `CODEX_HOME` or `-c` overrides, and
   the least-privilege sandbox mode that does not double-prompt.

## Non-goals

- No change to the Claude adapter or the default Claude launch assembly. The
  `spawn_test.sh` golden baseline stays byte-identical.
- No change to the gate's core org-matching logic. Part B adds the single-org
  degradation rule (B2) and threads model/harness into the bypass record (B6),
  but the candidate-walk and the same-org error path are unchanged.
- No app-server/remote-control transport for inbound (future upgrade).
- No compact-steering for Codex (documented follow-on).
- No new provider harnesses beyond Codex.
