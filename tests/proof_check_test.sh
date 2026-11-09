#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Test scripts/proof-check.sh against stub checkers and planted escape hatches.
# It checks the invocations, the exit codes and the comment-aware scan; it does
# not run Agda, Coq, Lean or Idris2 (run `just proof-check-all` for that).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check="$repo_root/scripts/proof-check.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Only the utilities the script needs, so provers installed on this machine
# cannot answer for the stubs.
mkdir -p "$work/sysbin" "$work/stubs"
for tool in bash sed awk grep find sort cp mktemp rm head tail cat; do
    ln -s "$(command -v "$tool")" "$work/sysbin/$tool"
done

# Each stub logs its arguments; STUB_FAIL names a checker that should fail.
for tool in agda coqc lean idris2; do
    cat > "$work/stubs/$tool" <<SH
#!/bin/sh
[ "\$1" = --version ] && { echo "$tool stub 0"; exit 0; }
echo "\$*" >> "$work/$tool.args"
[ "\${STUB_FAIL:-}" = "$tool" ] && exit 1
: > built-artefact
exit 0
SH
    chmod +x "$work/stubs/$tool"
done

run() {  # run <expected-exit> <PATH> <args...>; output goes to $work/out
    local want="$1" path="$2"; shift 2
    local got=0
    PATH="$path" bash "$check" "$@" > "$work/out" 2>&1 || got=$?
    [ "$got" -eq "$want" ] || { cat "$work/out" >&2; fail "proof-check $* exited $got, expected $want"; }
}

proofs="$repo_root/verification/proofs"
before="$(cd "$proofs" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)"  # names and contents

# All checkers present and passing: canonical Agda flags, Idris2 source dir.
run 0 "$work/stubs:$work/sysbin" --proofs-dir "$proofs" all
grep -q -- '--safe --without-K --cubical-compatible Properties.agda' "$work/agda.args" ||
    fail "agda not run with the PROOF-POLICY 2.1 invocation: $(cat "$work/agda.args")"
grep -q -- '--source-dir . --check ABI/Compliance.idr' "$work/idris2.args" ||
    fail "idris2 not run with a source directory: $(cat "$work/idris2.args")"
grep -q '^scan    PASS' "$work/out" || fail "template comments tripped the scan"

# AGDA_STDLIB switches to explicit include paths with library files ignored.
: > "$work/agda.args"
AGDA_STDLIB=/opt/stdlib run 0 "$work/stubs:$work/sysbin" --proofs-dir "$proofs" agda
grep -q -- '--no-libraries -i . -i /opt/stdlib Properties.agda' "$work/agda.args" ||
    fail "AGDA_STDLIB not passed as an include path: $(cat "$work/agda.args")"

# A relative AGDA_STDLIB is resolved against the caller's directory, not the
# copy the checker runs in.
: > "$work/agda.args"
(cd "$work" && AGDA_STDLIB=lib/stdlib run 0 "$work/stubs:$work/sysbin" --proofs-dir "$proofs" agda)
grep -q -- "-i $work/lib/stdlib Properties.agda" "$work/agda.args" ||
    fail "relative AGDA_STDLIB not made absolute: $(cat "$work/agda.args")"

# A missing checker is UNAVAILABLE with exit 3, never a pass.
rm "$work/stubs/lean"
run 3 "$work/stubs:$work/sysbin" --proofs-dir "$proofs" all
grep -q '^lean4   UNAVAILABLE' "$work/out" || fail "missing lean not reported UNAVAILABLE"

# A failing checker fails the run, even with another one unavailable.
STUB_FAIL=coqc run 1 "$work/stubs:$work/sysbin" --proofs-dir "$proofs" all
grep -q '^coq     FAIL' "$work/out" || fail "failing coqc not reported"

# The checkers ran on a copy: nothing was written into the tree.
after="$(cd "$proofs" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)"
[ "$before" = "$after" ] || fail "a checker wrote into verification/proofs"

# Scan: planted escape hatches in code fail; the same words in comments,
# nested comments and strings do not.
plant() {  # plant <relative-file> <content>; scan a tree holding only that file
    rm -rf "$work/tree"; mkdir -p "$work/tree/$(dirname "$1")"
    printf '%s\n' "$2" > "$work/tree/$1"
}
scan_expect() {  # scan_expect <exit> <relative-file> <content>
    plant "$2" "$3"
    run "$1" "$work/sysbin" --proofs-dir "$work/tree" scan
}
scan_expect 1 agda/A.agda 'postulate p : Set'
scan_expect 1 agda/A.agda '{-# TERMINATING #-}'
scan_expect 0 agda/A.agda '-- no postulate here'
scan_expect 0 agda/A.agda '{- outer {- postulate -} still comment -} x = 1'
scan_expect 1 agda/A.agda '{- comment -} postulate q : Set'
scan_expect 1 idris2/B.idr 'f = believe_me x'
scan_expect 0 idris2/B.idr '||| Docs mention assert_total
-- and believe_me'
scan_expect 1 coq/C.v 'Lemma l : True. Admitted.'
scan_expect 0 coq/C.v '(* NO Admitted allowed (* nested *) *) Lemma l : True. exact I. Qed.'
scan_expect 1 lean4/D.lean 'theorem t : True := by sorry'
scan_expect 0 lean4/D.lean '/- sorry -/ def s := "sorry"'
grep -q '^scan    PASS' "$work/out" || fail "comment and string not ignored"
# A character literal holding a quote does not open a string that hides code.
scan_expect 1 lean4/D.lean "example : False := by { let c : Char := '\"'; sorry }"
scan_expect 1 lean4/D.lean "def c := '\\\\'  theorem t : True := by sorry"
# In Agda, `--` inside an identifier does not start a comment.
scan_expect 1 agda/A.agda 'f--g = x ; postulate p : Set'
# Escape hatches are per language: `admit` is an ordinary Agda identifier.
scan_expect 0 agda/A.agda 'admit : Set'
scan_expect 1 coq/C.v 'Lemma l : True. admit. Qed.'

# A proof directory that is a symbolic link is copied as its contents.
rm -rf "$work/linked" "$work/real"; mkdir -p "$work/linked" "$work/real"
printf '%s\n' 'Lemma l : True. Admitted.' > "$work/real/C.v"
ln -s ../real "$work/linked/coq"
run 1 "$work/sysbin" --proofs-dir "$work/linked" scan
grep -q 'escape hatch in coq/C.v' "$work/out" || fail "linked proof directory not scanned"

# Usage errors.
run 2 "$work/sysbin" bogus-leg
run 2 "$work/sysbin" --proofs-dir "$work/missing" scan

echo 'PASS: proof-check invocations, exit codes and comment-aware scan'
