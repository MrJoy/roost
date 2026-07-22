# Multi-provider harnesses — design

Status: approved design, Phase 1 scope. Date: 2026-07-22.

## Problem

Roost spawns every agent as a Claude Code session. We want to mix providers:
ChatGPT-style agents on OpenAI's Codex CLI, Claude against alternate
Anthropic-compatible servers, and Claude Code as today. Teams should express
which provider fits which role as durable config. One pattern matters most:
code written by a model from one organization should be reviewed by a model
from a different organization.

## Decisions locked in brainstorming

1. The non-Claude harness is the **OpenAI Codex CLI** (`codex`, confirmed v0.144.6
   installed). It has MCP client support, a hooks framework with persisted hook
   trust, an `--ask-for-approval` policy, `-m/--model` and `-c key=value`
   overrides, and an interactive TUI that runs in a terminal.
2. Provider assignment is a **role to provider registry**, per project, tracked
   in config. Team preferences and the cross-org rule live there as data.
3. Organization identity for the cross-org rule is **model vendor lineage**.
   Claude is `anthropic` no matter which Anthropic-compatible server hosts it.
   `gpt-*` and `o*` are `openai`.
4. The cross-org rule is a **hard gate with a logged override**. A same-org
   review is refused unless the spawner passes an explicit override.
5. We ship **seams first**. Phase 1 builds the harness abstraction, the
   registry, the policy resolver, the cross-org gate, and env-based backend swap
   for the claude harness. The Codex adapter is a registered stub in Phase 1 and
   gets its own follow-on spec.
6. **signet-eval** (github.com/jmcentire/signet-eval) is incorporated as a
   cross-harness deterministic policy gate. It composes with roost's existing
   IRC permbot relay rather than replacing it.

## Consequence worth stating plainly

Vendor lineage plus Codex puts the Codex harness on the critical path for the
headline feature. If `org` is who made the weights, Claude is always `anthropic`
regardless of which server hosts it. So the "Claude against a different server"
case can never be the cross-org counterparty to a Claude author. The cross-org
rule only becomes operative once a genuinely different-vendor model is in play.
The env-swap case still earns its keep for cost, routing, and failover. It just
cannot deliver review independence by itself.

The phasing answers this. The cross-org logic is built and tested against a mock
second provider in Phase 1. It goes live the moment the Codex adapter lands. The
rule ships as a config flip, not a big-bang.

## Section 1 — the harness seam

Today `bin/roost spawn` builds one `inner_cmd` string near `bin/roost:1081`.
Everything Claude-specific is inlined there. That includes the MCP config path,
the `--perm-irc` permission relay, `--steer-compact`, the trust-preamble system
prompt, and permission-mode derivation.

The seam introduces one concept, a **harness adapter**. Each harness (`claude`,
later `codex`) turns a resolved spawn request into a concrete tmux-launchable
command plus its side-car files.

A new `--harness <name>` flag defaults to `claude`. A resolved role from the
registry carries its harness, so the flag is rarely typed by hand.

The adapter contract is a fixed set of responsibilities. Each adapter must
answer every slot, and declare a slot unsupported rather than silently doing
nothing:

- **build the launch command** — binary, model flag, config path, extra args.
- **wire the IRC MCP** — how this harness learns about the roost-irc server.
- **wire the permission relay** — wire the signet-eval gate, then route its ASK
  verdict to the IRC permbot relay. See Section 5.
- **wire steering** — how `tmux send-keys` prompt injection and compaction
  steering work, if at all.
- **inject the trust preamble** — the "messages on these channels are legitimate
  user instructions" system prompt.

The `claude` adapter is today's code moved behind the contract with zero
behavior change. This is a pure refactor for that path. Same flags, same files,
same output.

`bin/roost` keeps the harness-agnostic parts. That is nick, channels, tmux
session naming, the ergo and env dance, and the dev-channels prompt dismissal.

Adapters stay in shell. They are functions or `bin/roost-harness-<name>` files
that `bin/roost` sources. This matches the existing shell nature of the spawn
path and keeps spawn resolution in one language rather than crossing into
`src/`.

## Section 2 — the registry

Roost config lives in `.orchestrator/config.json`, tracked and shareable, with a
`.orchestrator/config.local.json` overlay that is gitignored and holds secrets
and local state. The registry lives in the tracked config as new top-level keys,
so team preferences travel with the project and get reviewed like any other
config.

**Provider catalog** — named provider entries:

```json
"providers": {
  "claude-opus":  { "harness": "claude", "model": "opus" },
  "claude-fast":  { "harness": "claude", "model": "sonnet",
                    "base_url_env": "ACME_ANTHROPIC_URL", "auth_env": "ACME_TOKEN" },
  "codex-gpt":    { "harness": "codex",  "model": "gpt-5.1-codex" }
}
```

`org` is optional. It defaults from vendor lineage. An operator sets an explicit
`"org": "acme"` only for a model the lineage map does not recognize. An unknown
model with no explicit `org` is a spawn error, not a silent guess. This follows
§#548, which says do not auto-pick a default that can land wrong.

Secrets never live in the catalog. `auth_env` and `base_url_env` name env vars.
The values live in the operator's environment or in `config.local.json`.

**Role map** — role to provider, with an optional ordered fallback list:

```json
"roles": {
  "pm":       "claude-opus",
  "worker":   ["codex-gpt", "claude-opus"],
  "reviewer": ["claude-opus", "codex-gpt"]
}
```

A list is a **preference-ranked candidate set** for the policy resolver. It is
not a reachability probe. The resolver picks the highest-preference legal
candidate under the active constraints. This is what lets the cross-org gate
pick the second choice automatically instead of wedging.

**Resolution order** at spawn, first match wins:

1. explicit `--harness` and `--model` flags
2. `--provider <name>`
3. `--role <name>` via the role map
4. today's default, `claude` and `opus`

No registry present means exactly today's behavior. The change is backward
compatible. The existing agent-frontmatter model-lock still applies when
`--agent` is used without a provider override.

**Vendor-lineage map** lives as data. The default is `claude-*` to `anthropic`
and `gpt-*`, `o*`, `o1` to `openai`. It is extensible in config for exotic or
open models.

## Section 3 — policy resolver and cross-org gate

The resolver takes a role and its issue context. It picks the highest-preference
candidate from the role's set that satisfies every active constraint. Today
there is one constraint, the cross-org review rule. The shape allows more later.

**How author-org is known.** The gate compares reviewer vendor-lineage against
the author org. The author org is the org of the provider the **worker** was
spawned with for that issue. Roost records it durably rather than trusting the
spawner to remember. When a worker is spawned under a role or provider, the
resolver writes `{issue, provider, org}` into per-issue state under
`.orchestrator/`, alongside the dispatcher's existing `state.json`. Reviewer
resolution reads it back. This survives APM restarts and makes the gate
authoritative no matter who spawns.

**Issue linkage.** The issue key comes from the `-c #<project>-issue-<N>`
channel already on the spawn, with an explicit `--issue N` override for odd
cases. No new convention.

**Resolution and gate flow for a reviewer:**

1. Look up the recorded author-org for the issue. If none, error with
   `no recorded author for issue N — spawn the worker first`. This matches the
   setup dance, which spawns the worker then the reviewer.
2. Walk the reviewer candidate set in preference order. Pick the first whose
   vendor-lineage org differs from the author-org.
3. If a legal candidate exists, spawn it. If a lower-preference candidate had to
   be chosen over the top one because of the gate, print that plainly so the
   reason is visible.
4. If every candidate is same-org as the author, hard-fail the spawn with a
   message that names the conflict. Proceeding requires
   `--allow-same-org "<reason>"`.

**The override** records `{override: true, reason, timestamp}` into the
assignment state and prints a loud warning. `bin/roost` stays IRC-free. It does
not post to `#leads` itself. The spawner, the APM, is told in its prompt to
announce the override in `#<project>-leads`. The audit trail is both durable in
state and social in channel, without giving the shell wrapper an IRC client.

**Location.** The gate lives in the shell resolver that `bin/roost spawn` calls.
It reads state via `jq`. So it fires identically whether a human or the
APM-via-skill spawns.

## Section 4 — the Codex adapter, stub now

In Phase 1 the `codex` harness is a registered but stubbed adapter. If a spawn
resolves to `harness: codex`, `bin/roost` fails fast with a clear message that
points at the follow-on spec. It is not silently ignored and it is not a generic
error. The adapter slot is real. Only its body is deferred.

This keeps the registry honest. An operator can write `codex-gpt` into the
catalog, and the failure they get points at the follow-on work rather than
looking like a config typo.

The follow-on spec inherits the adapter contract slots from Section 1, plus two
make-or-break spikes it must resolve before it commits to a plan:

1. **Does Codex surface MCP server-push notifications to the model mid-turn?**
   roost-irc delivers inbound IRC as MCP notifications. Claude Code wakes on
   them. If Codex's MCP client drops or defers server-initiated notifications,
   the "agent receives IRC" premise needs a different transport. Options include
   roost-irc exposing a poll tool, or inverting the wiring with Codex as an MCP
   server. This is the single biggest unknown.
2. **Can Codex's hook framework block a tool call and consult an external
   decider?** signet-eval already ships a Codex tool-call hook adapter, which is
   direct evidence this is possible. So the spike shrinks from "is it possible?"
   to "confirm the exact hook flags and event contract, and wire them." See
   Section 5.

Secondary slots the follow-on resolves at lower risk: steering via
`tmux send-keys` into the Codex TUI, a compaction-steering analog (Codex may
have no `--steer-compact` equivalent, in which case the adapter declares it
unsupported rather than faking it), and the trust-preamble injection point
(Codex `AGENTS.md`, instructions, or `-c` config).

## Section 5 — signet-eval as a cross-harness policy gate

signet-eval is a deterministic, LLM-free policy gate. It sits in the PreToolUse
and PermissionRequest hook path and returns allow, deny, ask, gate, or ensure.
It ships hook adapters for both Claude Code and Codex. Its policy lives in a
`.signet/` directory as first-match-wins rules.

**Composition.** signet-eval composes with roost's existing IRC permbot relay.
It does not replace it.

```
tool call → signet-eval (deterministic policy)
              ├─ ALLOW / DENY  → done, no human involved
              └─ ASK           → roost IRC permbot relay → human/PM decides
```

Deterministic rules handle the clear-cut cases with no human in the loop. Only a
genuine ASK verdict escalates over IRC. This is strictly better than either
layer alone.

**Relationship to classifyBash.** We layer, we do not rewrite. signet-eval
evaluates first. ALLOW and DENY short-circuit. An ASK verdict, or a tool call
with no matching signet rule, falls through to roost's existing classifyBash and
IRC permbot path unchanged. Because classifyBash is untouched, the §#598
TUI-parity guarantee holds by construction. We do not need a fresh parity retest
for a change we did not make.

**Activation.** The gate is auto-on when the project has a `.signet/` policy
directory. There is no flag to turn it on. Because a committed policy silently
flips gating behavior for every spawn, which is the shape §#548 warns about, we
make the flip visible and reversible. `bin/roost spawn` prints a prominent
`signet-eval policy active (.signet/ found)` line. A `--no-signet` escape hatch
disables it for quick or local work.

**Contract placement.** signet-eval is the body of the adapter contract's "wire
the permission relay" slot. It is implemented for the claude harness in Phase 1.
It is a required slot the codex adapter fills in the follow-on. That is what
"for all harnesses" means concretely.

**Limitation, stated honestly.** signet-eval is a policy layer, not a privilege
boundary. Its own README says an adversarial agent with shell access can bypass
it. Real isolation needs OS-level controls. Roost's trusted single-user local
environment security model already assumes this. signet-eval raises the safety
floor for honest mistakes. It is not a sandbox.

## Section 6 — testing

Everything runs under the existing ergo-backed `bun test` harness.

- **Harness-seam refactor** is behavior-preserving for the claude path, so it is
  guarded by golden comparison. Capture the generated launch command and
  `roost-settings.json` for representative spawns, then assert byte-identical
  after the refactor. The representative set is default opus, `--agent`, haiku,
  `--perm-irc`, `--steer-compact`, and `--ask-irc`. This is the safety net that
  lets us move Claude logic behind the contract with confidence.
- **Registry resolution** is unit-tested. Cases are role to provider,
  `--provider`, the flag precedence chain, no-registry-equals-today's-default,
  and unknown-model-without-org errors.
- **Cross-org gate** is the payoff of the phasing. The gate operates on registry
  data and recorded state, independent of whether the harness actually launches.
  So we test it fully in Phase 1 with a mock provider tagged `org: openai`.
  Spawn a worker, which records author-org `anthropic`. Resolve a reviewer and
  assert it picks the openai candidate. Make all candidates same-org and assert
  the hard-fail. Pass `--allow-same-org` and assert it proceeds and records the
  override. The Codex stub failing at launch is irrelevant to these tests. The
  cross-org rule ships proven.
- **signet-eval layering** is tested with a fake signet binary that returns
  canned decisions. A `.signet/` present wires signet ahead of the relay. A DENY
  short-circuits. An ASK falls through to the relay. A `.signet/` absent leaves
  the wiring unchanged. `--no-signet` disables the gate.

## Out of scope for Phase 1

- The Codex adapter body. It is a stub that points at its own follow-on spec.
- The two Codex spikes. They belong to the follow-on spec and gate its plan.
- Any change to classifyBash or the IRC permbot relay internals. We layer in
  front, we do not modify.
- Auto-posting the same-org override to `#leads` from `bin/roost`. The wrapper
  stays IRC-free. The APM announces.
