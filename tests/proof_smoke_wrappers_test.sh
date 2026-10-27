#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Test the proof-toolchain smoke installer and the Mizar and PVS wrappers
# against stub prover binaries. This checks the wrappers' pass/fail logic and
# that they never write into the installed prefix; it does not run Mizar or PVS.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

prefix="$work/prefix"
stubs="$work/stubs"
mkdir -p "$stubs" "$prefix/share/mizar"
sh "$repo_root/tools/proof-toolchain/install-smoke.sh" "$prefix"
for fixture in hol-light-refl.sh hol4-smoke.sml acl2-smoke.lisp smoke.miz \
    mizar-smoke.sh pvs-smoke.sh pvs_smoke.pvs; do
    [ -f "$prefix/share/smoke/$fixture" ] || { echo "FAIL: $fixture not installed" >&2; exit 1; }
done
chmod -R a-w "$prefix/share/smoke"  # a wrapper that writes here now fails

expect() {  # expect pass|fail <description> <command...>
    local want="$1" what="$2"; shift 2
    if "$@" >/dev/null 2>&1; then got=pass; else got=fail; fi
    if [ "$got" != "$want" ]; then
        echo "FAIL: $what: expected $want, got $got" >&2
        exit 1
    fi
}

# Stub Mizar: makeenv checks MIZFILES and the article path; verifier writes
# the .err file the mode under test asks for.
cat > "$stubs/makeenv" <<'SH'
#!/bin/sh
[ "$MIZFILES" = "$EXPECT_MIZFILES" ] && [ "$1" = text/smoke ] && [ -f text/smoke.miz ]
SH
cat > "$stubs/verifier" <<'SH'
#!/bin/sh
case "$STUB_MODE" in
    ok)      : > text/smoke.err ;;
    errors)  echo '5 7 4' > text/smoke.err ;;
    no-err)  : ;;
    crash)   exit 3 ;;
esac
SH
chmod +x "$stubs/makeenv" "$stubs/verifier"
mizar() { STUB_MODE="$1" EXPECT_MIZFILES="$prefix/share/mizar" MIZFILES=/host/mml \
    PATH="$stubs:$PATH" sh "$prefix/share/smoke/mizar-smoke.sh" "$prefix"; }
expect pass "mizar clean article" mizar ok
expect fail "mizar article errors" mizar errors
expect fail "mizar no error file" mizar no-err
expect fail "mizar verifier crash" mizar crash
expect fail "mizar missing PREFIX" sh "$prefix/share/smoke/mizar-smoke.sh"
expect fail "mizar missing MML" env PATH="$stubs:$PATH" STUB_MODE=ok \
    sh "$prefix/share/smoke/mizar-smoke.sh" "$work/no-such-prefix"

# Stub PVS: proveit prints the summary the mode under test asks for.
cat > "$stubs/proveit" <<'SH'
#!/bin/sh
[ "$1" = --force ] && [ "$2" = pvs_smoke.pvs ] && [ -f pvs_smoke.pvs ] || exit 9
mkdir -p pvsbin
case "$STUB_MODE" in
    ok)       echo 'Grand Totals: 1 proofs, 1 attempted, 1 succeeded (0.01 s)' ;;
    unproved) echo 'Grand Totals: 1 proofs, 1 attempted, 0 succeeded (0.01 s)' ;;
    silent)   : ;;
    crash)    echo 'Grand Totals: 1 proofs, 1 attempted, 1 succeeded (0.01 s)'; exit 4 ;;
esac
SH
chmod +x "$stubs/proveit"
pvs() { STUB_MODE="$1" PATH="$stubs:$PATH" sh "$prefix/share/smoke/pvs-smoke.sh"; }
expect pass "pvs proved" pvs ok
expect fail "pvs unproved" pvs unproved
expect fail "pvs no summary" pvs silent
expect fail "pvs non-zero exit" pvs crash

[ -z "$(find "$prefix/share/smoke" -newer "$prefix/share/smoke/pvs_smoke.pvs" ! -path "$prefix/share/smoke")" ] ||
    { echo "FAIL: a wrapper wrote into the prefix" >&2; exit 1; }
chmod -R u+w "$prefix"
echo 'PASS: smoke installer and Mizar/PVS wrappers'
