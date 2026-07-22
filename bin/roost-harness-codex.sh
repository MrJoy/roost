#!/usr/bin/env bash
# Codex harness adapter. STUB. The adapter contract slot is real; the body is
# deferred to its own follow-on spec (see docs/superpowers/specs/ for the Codex
# adapter design and its two feasibility spikes). This is intentionally a hard,
# specific failure so a codex-* provider in the registry points at real work
# rather than looking like a config typo.

harness_assemble() {
  echo "error: codex harness not yet implemented. see docs/superpowers/specs/ for the Codex adapter follow-on spec" >&2
  return 1
}
