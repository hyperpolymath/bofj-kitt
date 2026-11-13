#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Exercise the helper functions of the rendered agent-session setup script
# (tools/environments/rendered/agent-session/setup.sh) offline, with stub
# dpkg-query, apt-get and curl, and the report directory in scratch space.
# The script's install lines are not run. Checks: apt_pin reports PRESENT,
# INSTALLED (and links) and FAILED; asset installs a file whose SHA-256
# matches, reports PRESENT on a second run, and refuses a mismatched digest
# without installing; FAILED and UNAVAILABLE are printed loudly; no helper
# returns non-zero.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/tools/environments/rendered/agent-session/setup.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The helpers: from `rep()` up to, not including, the apt-get update line,
# with the report directory moved into scratch space.
sed -n '/^rep() {/,/^apt-get update/p' "$script" | sed '$d' > "$work/helpers.sh"
grep -q '^asset() {' "$work/helpers.sh" || fail "could not extract the helpers from $script"

mkdir -p "$work/bin" "$work/payload" "$work/out"
printf '#!/bin/sh\necho tool\n' > "$work/payload/tool"
chmod +x "$work/payload/tool"
tar -czf "$work/tool.tgz" -C "$work/payload" tool
good_sha="$(sha256sum "$work/tool.tgz" | cut -d' ' -f1)"
# A release-style archive with one top directory, for the tar.gz-tree format.
mkdir -p "$work/tree/pkg-1.0/bin"
cp "$work/payload/tool" "$work/tree/pkg-1.0/bin/tool"
tar -czf "$work/tree.tgz" -C "$work/tree" pkg-1.0
tree_sha="$(sha256sum "$work/tree.tgz" | cut -d' ' -f1)"

cat > "$work/bin/dpkg-query" <<'SH'
#!/bin/sh
for a in "$@"; do pkg="$a"; done
[ "$pkg" = have ] && printf '1.0' && exit 0
exit 1
SH
cat > "$work/bin/apt-get" <<'SH'
#!/bin/sh
case "$*" in *"ok=2.0"*) exit 0 ;; esac
exit 100
SH
cat > "$work/bin/curl" <<SH
#!/bin/sh
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
case "\$prev" in *tree*) cp "$work/tree.tgz" "\$out" ;; *) cp "$work/tool.tgz" "\$out" ;; esac
SH
chmod +x "$work/bin/"*

run() {  # run <helper call...>; stderr to $work/err
    PATH="$work/bin:$PATH" R="$work/report" bash -c '
        set -u; mkdir -p "$R"; : >> "$R/setup-report.tsv"
        . "$1"; shift; "$@"' _ "$work/helpers.sh" "$@" 2>>"$work/err"
}
report() { cat "$work/report/setup-report.tsv"; }

run apt_pin a have 1.0 || fail "apt_pin returned non-zero"
run apt_pin b ok 2.0 "$work/payload/tool" "$work/out/linked" || fail "apt_pin returned non-zero"
run apt_pin c bad 3.0 || fail "apt_pin returned non-zero on failure"
run asset t tar.gz "$work/out/tool" https://example.invalid/t.tgz "$good_sha" tool || fail "asset returned non-zero"
run asset t tar.gz "$work/out/tool" https://example.invalid/t.tgz "$good_sha" tool || fail "asset returned non-zero on rerun"
run asset w tar.gz "$work/out/wrong" https://example.invalid/t.tgz "$(printf '0%.0s' {1..64})" tool || fail "asset returned non-zero on mismatch"
run rep kyq UNAVAILABLE "no pinned release" || fail "rep returned non-zero"
run asset j tar.gz-tree "$work/out/pkg" https://example.invalid/tree.tgz "$tree_sha" || fail "asset returned non-zero on a tree"

r="$(report)"
grep -qP '^a\tPRESENT\thave=1.0$' <<<"$r" || fail "apt_pin did not report PRESENT: $r"
grep -qP '^b\tINSTALLED\tok=2.0$' <<<"$r" || fail "apt_pin did not report INSTALLED: $r"
[[ -L "$work/out/linked" ]] || fail "apt_pin did not create the link"
grep -qP '^c\tFAILED\tapt-get install bad=3.0$' <<<"$r" || fail "apt_pin did not report FAILED: $r"
grep -qP '^t\tINSTALLED\tsha256 '"$good_sha"'$' <<<"$r" || fail "asset did not report INSTALLED: $r"
[[ -x "$work/out/tool" ]] || fail "asset did not install an executable"
grep -qP '^t\tPRESENT\tsha256 '"$good_sha"'$' <<<"$r" || fail "asset rerun was not PRESENT: $r"
grep -qP '^w\tFAILED\tsha256 mismatch' <<<"$r" || fail "asset accepted a wrong digest: $r"
[[ ! -e "$work/out/wrong" ]] || fail "asset installed a file whose digest did not match"
grep -q '!!! bofj-kitt setup: c FAILED' "$work/err" || fail "FAILED was not loud"
grep -q '!!! bofj-kitt setup: kyq UNAVAILABLE' "$work/err" || fail "UNAVAILABLE was not loud"
grep -qP '^j\tINSTALLED\tsha256 '"$tree_sha"'$' <<<"$r" || fail "tar.gz-tree asset did not report INSTALLED: $r"
[[ -x "$work/out/pkg/bin/tool" ]] || fail "tar.gz-tree did not unpack the tree with its top directory stripped"

echo "PASS: setup helpers report PRESENT/INSTALLED/FAILED/UNAVAILABLE, verify SHA-256 before installing, and never fail the script"
