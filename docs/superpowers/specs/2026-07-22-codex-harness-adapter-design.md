# Codex harness adapter — design

## Goal

Replace the fail-fast `bin/roost-harness-codex.sh` stub with a working adapter
that spawns an OpenAI Codex CLI agent as a resident roost worker: joined to
IRC, gated by the same signet + permbot policy layer as Claude workers, and
subject to the cross-org review rules the provider registry already enforces.

This is the follow-on to the multi-provider Phase 1 work, which shipped the
`REQ_*`/`RESP_*` harness contract, the provider/role registry, the cross-org
gate, and the signet layering, with Codex left as a stub.

## Background: what Phase 1 already gives us

The harness seam is in place. `bin/roost` resolves a provider (from
`--harness`/`--model`/`--provider`/`--role`), sets the `REQ_*` contract
globals, and sources `bin/roost-harness-<name>.sh`, whose `harness_assemble()`
reads those globals and writes back `RESP_INNER_CMD` plus `RESP_TMUX_ENV[]` and
any side-car files under `REQ_DATA_DIR`. The Claude adapter
(`bin/roost-harness-claude.sh`) is the reference implementation of that
contract. The registry already classifies OpenAI-family models as org
`openai`, so a Codex worker slots into the cross-org gate with no gate changes.

The Codex adapter's whole job is to satisfy the same contract for `codex`
instead of `claude`.

## Empirical findings that anchor this design

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

## Architecture

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

## Testing

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

## Open items resolved as gated spikes in the plan

All are low-quota and settled before the adapter code they inform:

1. The exact `[[hooks.*]]` TOML nesting Codex expects (event key casing, field
   names like `command` / `timeout_sec` / `matcher`, list-vs-table form).
2. Whether Codex surfaces MCP-server `instructions` to the model (decides the
   IRC-trust injection path).
3. `tmux send-keys` injection behavior into the Codex TUI: that it wakes an idle
   session, and how it behaves mid-turn (informs the idle-gating and buffering).
4. Whether the session config is cleaner via `CODEX_HOME` or `-c` overrides, and
   the least-privilege sandbox mode that does not double-prompt.

## Non-goals

- No change to the Claude adapter or the default spawn path.
- No change to the provider registry, cross-org gate, or signet detection logic
  from Phase 1; the adapter consumes `RESOLVED_*` and `REQ_SIGNET_ACTIVE` as-is.
- No app-server/remote-control transport for inbound (future upgrade).
- No compact-steering for Codex (documented follow-on).
