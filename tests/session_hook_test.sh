#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Test .claude/hooks/session-start.sh (proposal E4) without touching the real
# home directory or git config: HOME is a scratch directory throughout.
# Checks: the hook always exits 0; it writes .session/capability-record.json
# and names UNAVAILABLE legs; with CLAUDE_CODE_REMOTE=true and no signing
# variables it warns loudly, writes no key, and still writes the record; a
# broken or slow doctor is reported loudly, leaves no record, and does not
# block. Needs cargo (to build the engine) and jq.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is not on PATH; the test cannot run"

# A copy of the repository, so .session/ lands in scratch space.
proj="$work/proj"
mkdir -p "$proj"
(cd "$repo_root" && git ls-files -z | xargs -0 cp --parents -t "$proj")
cargo build --release --locked --quiet --manifest-path "$repo_root/tools/proof-toolchain/provers/Cargo.toml"
engine="$repo_root/tools/proof-toolchain/provers/target/release/provers"
mkdir -p "$work/home"

hook() {
    env -u CLAUDE_SIGNING_KEY -u CLAUDE_SIGNING_NAME -u CLAUDE_SIGNING_EMAIL \
        HOME="$work/home" CLAUDE_PROJECT_DIR="$proj" PROVERS_SETUP_REPORT="$work/none" "$@" \
        sh "$proj/.claude/hooks/session-start.sh"
}

# 1. Local session: no signing, record written, UNAVAILABLE legs named.
out="$(hook env CLAUDE_CODE_REMOTE=false PROVERS_BIN="$engine")" || fail "hook exited non-zero"
rec="$proj/.session/capability-record.json"
[[ -s "$rec" ]] || fail "no capability record written"
jq -e '.record_type.id == "5934cd83-73e5-80ab-abf5-f1c0bd3526fd"' "$rec" >/dev/null || fail "record has the wrong type id"
grep -q "Capability record written" <<<"$out" || fail "hook did not report the record: $out"
want="$(jq -r '[.tools[], .environment_tools[]] | map(select(.status == "UNAVAILABLE")) | .[0].id' "$rec")"
grep -q "UNAVAILABLE in this session.*$want" <<<"$out" || fail "hook did not name UNAVAILABLE leg $want: $out"
grep -q "commit signing" <<<"$out" && fail "hook touched signing outside a cloud session"

# 2. Cloud session without signing variables: loud warning, no key, record still written.
rm -f "$rec"
out="$(hook env CLAUDE_CODE_REMOTE=true PROVERS_BIN="$engine")" || fail "hook exited non-zero without signing variables"
grep -q "commit signing NOT configured: missing environment variable(s): CLAUDE_SIGNING_KEY" <<<"$out" || fail "no loud signing warning: $out"
[[ ! -e "$work/home/.ssh/id_ed25519_signing" ]] || fail "a key file was written without a key"
[[ -s "$rec" ]] || fail "signing failure stopped the capability record"

# 3. A failing doctor: loud, no record, exit 0.
rm -f "$rec"
out="$(hook env CLAUDE_CODE_REMOTE=false PROVERS_BIN=/bin/false)" || fail "hook exited non-zero when doctor failed"
grep -q "capability record NOT written: doctor exited" <<<"$out" || fail "failing doctor not reported: $out"
[[ ! -e "$rec" ]] || fail "a failing doctor left a record"

# 4. A doctor that overruns the budget: loud, no record, exit 0.
printf '#!/bin/sh\nsleep 30\n' > "$work/slow"; chmod +x "$work/slow"
out="$(hook env CLAUDE_CODE_REMOTE=false PROVERS_BIN="$work/slow" PROVERS_HOOK_BUDGET=1)" || fail "hook exited non-zero on timeout"
grep -q "did not finish within 1s" <<<"$out" || fail "timeout not reported: $out"
[[ ! -e "$rec" ]] || fail "a timed-out doctor left a record"

# 5. Every signing variable the hook reads is in the rendered env-var names.
for v in $(grep -o '\${CLAUDE_SIGNING_[A-Z_]*' "$repo_root/.claude/hooks/session-start.sh" | tr -d '${' | sort -u); do
    grep -q "^$v " "$repo_root/tools/environments/rendered/agent-session/env-vars.txt" || fail "hook reads $v, which env-vars.txt does not list"
done

echo "PASS: hook exits 0 always; writes and reports the record; signing and doctor failures are loud and do not block; its variables are rendered"
