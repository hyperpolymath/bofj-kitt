#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Test tools/proof-toolchain/provers.sh in both directions, offline:
#   render --check passes on the committed files and fails when one is edited;
#   doctor reports a stub tool at the expected version PRESENT, a stub at the
#   wrong version DRIFT, and a missing tool UNAVAILABLE with a reason, and
#   exits 1 on drift and 3 when only something is unavailable;
#   doctor --json is JCS-canonical with one final newline (checked with jq);
#   install is refused. Needs cargo (to build the engine) and jq.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
provers="$repo_root/tools/proof-toolchain/provers.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is not on PATH; the test cannot run"

# Build once through the wrapper; later runs reuse the engine.
"$provers" render --check >/dev/null || fail "committed rendered files drifted from the manifests"

# An edited rendered file must be caught.
cp -R "$repo_root/tools/environments/rendered" "$work/rendered"
printf '# hand edit\n' >> "$work/rendered/agent-session/setup.sh"
rc=0; "$provers" render --check --out "$work/rendered" >/dev/null 2>"$work/err" || rc=$?
[[ "$rc" -eq 1 ]] || fail "render --check on an edited file exited $rc, expected 1"
grep -q "DRIFT .*setup.sh" "$work/err" || fail "render --check did not name the drifted file"

# A rendered file the manifests no longer declare must be caught, then removed.
rm -rf "$work/rendered" && cp -R "$repo_root/tools/environments/rendered" "$work/rendered"
printf 'stale.example.com\n' > "$work/rendered/agent-session/allowed-hosts-retired.txt"
rc=0; "$provers" render --check --out "$work/rendered" >/dev/null 2>"$work/err" || rc=$?
[[ "$rc" -eq 1 ]] || fail "render --check with a stale file exited $rc, expected 1"
grep -q "STALE .*allowed-hosts-retired.txt" "$work/err" || fail "render --check did not name the stale file"
"$provers" render --out "$work/rendered" >/dev/null || fail "render failed"
[[ ! -e "$work/rendered/agent-session/allowed-hosts-retired.txt" ]] || fail "render left the stale file in place"
"$provers" render --check --out "$work/rendered" >/dev/null || fail "render --check failed after render removed the stale file"

# A self-contained root with a three-entry toolchain and stub tools.
root="$work/root"
mkdir -p "$root/tools/proof-toolchain" "$root/tools/environments" "$work/bin"
cat > "$root/tools/proof-toolchain/toolchain.kyaml" <<'EOF'
{
  schema: 1,
  prefix: "/nonexistent-prefix",
  tools: [
    {id: "good", role: "backend", method: "stub", pin: "1.2.3", verify: "stubgood --version"},
    {id: "old", role: "backend", method: "stub", pin: "2.0.0", verify: "stubold --version"},
    {id: "gone", role: "backend", method: "stub", pin: "resolve", verify: "stub-not-installed --version"},
  ],
}
EOF
cat > "$root/tools/environments/environments.kyaml" <<'EOF'
{
  schema: 1,
  environments: [{id: "workstation", kind: "host", measured: {}}],
  render: {},
}
EOF
printf '#!/bin/sh\necho "stubgood 1.2.3"\n' > "$work/bin/stubgood"
printf '#!/bin/sh\necho "stubold 1.9.9"\n' > "$work/bin/stubold"
chmod +x "$work/bin/stubgood" "$work/bin/stubold"

engine="$repo_root/tools/proof-toolchain/provers/target/release/provers"
doctor() { PATH="$work/bin:$PATH" "$engine" --root "$root" doctor --env workstation --setup-report "$work/none" "$@"; }

rc=0; out="$(doctor)" || rc=$?
[[ "$rc" -eq 1 ]] || fail "doctor with a drifted tool exited $rc, expected 1"
grep -Eq '^PRESENT +good +stubgood 1.2.3$' <<<"$out" || fail "good is not PRESENT: $out"
grep -Eq '^DRIFT +old +expected 2.0.0' <<<"$out" || fail "old is not DRIFT: $out"
grep -Eq '^UNAVAILABLE +gone +verify: command or file not found' <<<"$out" || fail "gone is not UNAVAILABLE with a reason: $out"

rc=0; doctor --json > "$work/rec.json" || rc=$?
[[ "$rc" -eq 1 ]] || fail "doctor --json exited $rc, expected 1"
[[ "$(tail -c 1 "$work/rec.json" | od -An -c | tr -d ' ')" == '\n' ]] || fail "record lacks its final newline"
[[ "$(wc -l < "$work/rec.json")" -eq 1 ]] || fail "record is not one line"
# For these ASCII keys, jq's sorted compact form is the JCS form.
[[ "$(jq -cS . "$work/rec.json")" == "$(head -c -1 "$work/rec.json")" ]] || fail "record is not canonical"
[[ "$(jq -r '[.tools[].id] | join(",")' "$work/rec.json")" == "good,old,gone" ]] || fail "record is not total over the manifest, in order"
[[ "$(jq -r '.tools[2].status' "$work/rec.json")" == "UNAVAILABLE" ]] || fail "missing tool not UNAVAILABLE in the record"

# Without the drifting entry, a missing tool alone exits 3, never 0.
sed -i '/id: "old"/d' "$root/tools/proof-toolchain/toolchain.kyaml"
rc=0; doctor >/dev/null || rc=$?
[[ "$rc" -eq 3 ]] || fail "doctor with only an unavailable tool exited $rc, expected 3"

rc=0; "$provers" install 2>/dev/null || rc=$?
[[ "$rc" -eq 2 ]] || fail "install exited $rc, expected 2 (not built by decision)"

echo "PASS: render drift and stale files caught both ways; doctor PRESENT/DRIFT/UNAVAILABLE and exit codes; canonical record; install refused"
