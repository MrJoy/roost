#!/usr/bin/env bash
# Tests for signet-eval layering: `.signet/` auto-detection wires a
# deterministic policy-gate hook ahead of the IRC permission relay on both
# PreToolUse and PermissionRequest; `--no-signet` opts out. Plain bash, no bats.
# Run: bash test/signet_test.sh
set -uo pipefail

ROOST_BIN="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )/bin/roost"
PASS=0
FAIL=0
TDIR=""

ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1 ${2:+- $2}"; FAIL=$((FAIL+1)); }

setup() {
  TDIR="$(mktemp -d /tmp/roost-signet-test-XXXXXXXX)"
  trap 'rm -rf "$TDIR"' EXIT
}

teardown() {
  rm -rf "$TDIR"
  tmux kill-session -t "roost-testnick" 2>/dev/null || true
  trap - EXIT
  TDIR=""
}

# signet-eval is not expected to be installed in the test/CI environment (that's
# the whole point of the fail-closed guard), but the activation cases below
# need it on PATH to exercise the wired-hook path. Stub it: an executable that
# just exits 0 is sufficient since these tests only check hook JSON wiring and
# the banner, never actually invoking signet-eval.
STUBS=""
stub_signet_eval() {
  STUBS="${TDIR}/.stubs"
  mkdir -p "$STUBS"
  cat > "${STUBS}/signet-eval" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${STUBS}/signet-eval"
}

# -- Test: .signet/ present → banner announces activation + hook wired ahead of relay --
setup
mkdir -p "$TDIR/.signet"
stub_signet_eval
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 PATH="${STUBS}:${PATH}" "${ROOST_BIN}" spawn testnick --perm-irc --perm-target op --permission-mode acceptEdits --cwd "$TDIR" 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
if echo "$out" | grep -qF "signet-eval policy active (.signet/ found)" \
    && grep -qF 'signet-eval' "$data_dir/roost-settings.json" 2>/dev/null; then
  ok ".signet present: banner + signet hook wired"
else
  fail ".signet present: banner + signet hook wired" "out=$out settings=$(cat "$data_dir/roost-settings.json" 2>/dev/null)"
fi
[ -n "$data_dir" ] && rm -rf "$data_dir"; teardown

# -- Test: signet decides first on BOTH PreToolUse and PermissionRequest --
# roost's job is to wire signet-eval as a separate hook entry ordered ahead of
# the IRC relay on each surface. The runtime ALLOW/DENY-short-circuit vs
# ASK-falls-through composition is Claude Code's multi-hook merge across those
# two independent entries, plus signet-eval's own hook-decision output
# contract. Neither is roost code, so that behavior is verified live against
# the native TUI per the permission-relay parity rule, not in these claude-free
# wiring tests. Here we pin what roost owns: both surfaces carry signet, ordered
# before the relay. The prior version checked only PreToolUse, and via a raw
# byte offset that could not tell the two surfaces apart.
setup
mkdir -p "$TDIR/.signet"
stub_signet_eval
out="$(ROOST_SPAWN_KEEP_DATA_DIR=1 PATH="${STUBS}:${PATH}" "${ROOST_BIN}" spawn testnick --perm-irc --perm-target op --permission-mode acceptEdits --cwd "$TDIR" 2>&1 || true)"
data_dir="$(echo "$out" | sed -n 's/.*data dir (preflight): //p' | head -1)"
settings_file="$data_dir/roost-settings.json"
# order(arr;a;b): true iff, within hook array `arr`, the first entry whose
# command matches `a` comes before the first whose command matches `b`.
if jq -e '
    def order(arr; a; b):
      (arr | map(.hooks[0].command)) as $c
      | ([range(0; ($c|length)) | select($c[.] | test(a))][0]) as $ia
      | ([range(0; ($c|length)) | select($c[.] | test(b))][0]) as $ib
      | ($ia != null and $ib != null and $ia < $ib);
    order(.hooks.PreToolUse; "signet-eval"; "irc-pretooluse-prompt")
    and order(.hooks.PermissionRequest; "signet-eval"; "irc-permission-prompt")
  ' "$settings_file" >/dev/null 2>&1; then
  ok "signet precedes irc relay on both PreToolUse and PermissionRequest"
else
  fail "signet precedes irc relay on both PreToolUse and PermissionRequest" "settings=$(cat "$settings_file" 2>/dev/null)"
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

# -- Test: .signet/ present + signet-eval NOT on PATH → fail closed and loud --
setup
mkdir -p "$TDIR/.signet"
# Neutralize PATH so signet-eval is absent even if the ambient environment
# happens to have it installed: strip out any PATH entry that resolves
# signet-eval, but keep everything else so bash and core utilities still work.
neutralized_path=""
IFS=':' read -ra _path_dirs <<< "$PATH"
for _dir in "${_path_dirs[@]}"; do
  [ -x "${_dir}/signet-eval" ] && continue
  neutralized_path="${neutralized_path:+${neutralized_path}:}${_dir}"
done
err_out="$(PATH="${neutralized_path}" "${ROOST_BIN}" spawn testnick --cwd "$TDIR" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && echo "$err_out" | grep -qF "signet-eval is not on PATH"; then
  ok ".signet present + signet-eval missing: fails closed with clear error"
else
  fail ".signet present + signet-eval missing: fails closed with clear error" "rc=$rc out=$err_out"
fi
teardown

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
