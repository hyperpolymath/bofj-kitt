#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# proof-check.sh — check the proof files under verification/proofs/ and scan
# them for escape hatches, following the estate PROOF-POLICY
# (metadatastician/standards, 3-practice/PROOF-POLICY.adoc).
#
#   proof-check.sh [--proofs-dir DIR] LEG...
#   LEG: agda | coq | lean4 | idris2 | scan | all
#
# Each leg reports one of PASS, FAIL or UNAVAILABLE. A missing checker is
# UNAVAILABLE and makes the run fail: PROOF-POLICY §2.1 treats a missing tool
# as an open obligation, so it is never reported as a pass or skipped silently.
#
# Agda runs with the canonical invocation of PROOF-POLICY §2.1:
#   agda --safe --without-K --cubical-compatible <module.agda>
# The standard library comes from AGDA_STDLIB (a directory holding its source)
# when set; otherwise Agda resolves `depend: standard-library` in
# verification/proofs/agda/*.agda-lib through its registered libraries.
#
# Checkers run on a temporary copy of the proofs directory, so their build
# artefacts (.agdai, .vo, .glob, build/) never land in the working tree.
#
# Exit codes:
#   0 — every requested leg passed
#   1 — a leg failed (a proof did not check, or the scan found an escape hatch)
#   2 — usage error
#   3 — no leg failed, but at least one checker was unavailable

set -euo pipefail

# Print the invocation syntax to stderr and terminate the script with exit 2.
usage() {
    sed -n '/^#   proof-check.sh/,/^#   LEG:/p' "$0" | sed 's/^# \{0,3\}//' >&2
    exit 2
}

proofs_dir="verification/proofs"
legs=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --proofs-dir) [ "$#" -ge 2 ] || usage; proofs_dir="$2"; shift 2 ;;
        agda|coq|lean4|idris2|scan) legs+=("$1"); shift ;;
        all) legs+=(agda coq lean4 idris2 scan); shift ;;
        *) usage ;;
    esac
done
[ "${#legs[@]}" -gt 0 ] || usage
[ -d "$proofs_dir" ] || { echo "proof-check: no proofs directory at $proofs_dir" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -RL "$proofs_dir/." "$work/"  # -L: a linked proof directory is copied, not left dangling

failed=0
unavailable=0
# Print a leg result to stdout and set the global failed or unavailable flag
# for FAIL or UNAVAILABLE respectively; PASS leaves both flags unchanged.
report() {  # report <leg> <PASS|FAIL|UNAVAILABLE> <detail>
    printf '%-7s %-11s %s\n' "$1" "$2" "$3"
    case "$2" in
        FAIL) failed=1 ;;
        UNAVAILABLE) unavailable=1 ;;
    esac
}

# run_files <leg> <tool> <subdir> <extension> <command-prefix...>
# Check matching files recursively in the temporary copy of <subdir>, using
# paths relative to that directory as the final command argument. <tool> is
# checked on PATH; <extension> excludes the dot. Missing tools are reported as
# UNAVAILABLE; missing directories, no matching files and checker failures are
# reported as FAIL. Checker failures are collected so remaining files run;
# these outcomes update global flags through report rather than returning an error.
run_files() {
    local leg="$1" tool="$2" sub="$3" ext="$4"; shift 4
    if ! command -v "$tool" >/dev/null 2>&1; then
        report "$leg" UNAVAILABLE "$tool is not on PATH; the check did not run"
        return
    fi
    local dir="$work/$sub" n=0 bad=0 f
    if [ ! -d "$dir" ]; then
        report "$leg" FAIL "no $sub/ directory under $proofs_dir"
        return
    fi
    echo "== $leg: $("$tool" --version 2>&1 | head -n 1)"
    while IFS= read -r f; do
        n=$((n + 1))
        if (cd "$dir" && "$@" "${f#./}") >"$work/.log" 2>&1; then
            echo "   ok   $sub/${f#./}"
        else
            bad=$((bad + 1))
            echo "   FAIL $sub/${f#./}"
            sed 's/^/        /' "$work/.log" | tail -n 20
        fi
    done < <(cd "$dir" && find . -name "*.$ext" -type f | LC_ALL=C sort)
    if [ "$n" -eq 0 ]; then
        report "$leg" FAIL "no .$ext files under $sub/"
    elif [ "$bad" -gt 0 ]; then
        report "$leg" FAIL "$bad of $n file(s) did not check"
    else
        report "$leg" PASS "$n file(s) checked"
    fi
}

# Remove comments, keeping line numbers and Agda pragmas ({-# ... #-}), so the
# scan sees only code. Nested block comments, string literals and character
# literals ('"', '\'') are honoured. A quote after an identifier character is a
# prime (`f'`), not a literal, and Coq has no character literals at all. In
# Agda, `--` opens a comment only at the start of a token, since an identifier
# such as `a--b` may contain it.
strip_comments() {  # strip_comments <file>
    local file="$1" line_tok open close doc='' agda=0 charlit=1
    case "$file" in
        *.idr) doc='|||' ;;  # Idris2 documentation comment, also a line comment
        *.agda) agda=1 ;;
    esac
    case "$file" in
        *.agda|*.idr) line_tok='--'; open='{-'; close='-}' ;;
        *.lean)       line_tok='--'; open='/-'; close='-/' ;;
        *.v)          line_tok='';   open='(*'; close='*)'; charlit=0 ;;
        *) cat "$file"; return ;;
    esac
    LC_ALL=C awk -v lt="$line_tok" -v op="$open" -v cl="$close" -v doc="$doc" -v agda="$agda" -v charlit="$charlit" -v q="'" '
        BEGIN { depth = 0 }
        {
            out = ""; i = 1; n = length($0); instr = 0
            while (i <= n) {
                two = substr($0, i, 2); c = substr($0, i, 1)
                if (depth > 0) {
                    if (two == op) { depth++; i += 2; continue }
                    if (two == cl) { depth--; i += 2; continue }
                    i++; continue
                }
                if (instr) {  # string contents are dropped: a word there is not code
                    if (c == "\\") { i += 2; continue }
                    if (c == "\"") { instr = 0; out = out c }
                    i++; continue
                }
                pc = (i == 1) ? " " : substr($0, i - 1, 1)
                # A quote after an identifier character (a byte >= 0x80 counts, for
                # Unicode names) is a prime; otherwise it opens a character literal,
                # dropped so a quote inside it is not taken for a string.
                if (c == q && charlit && pc != q && pc !~ /[A-Za-z0-9_!?\200-\377]/) {
                    if (substr($0, i + 1, 1) == "\\") {
                        j = index(substr($0, i + 2), q)
                        if (j > 0 && j <= 8) { i += j + 2; continue }
                    } else if (substr($0, i + 2, 1) == q) { i += 3; continue }
                }
                if (c == "\"") { instr = 1; out = out c; i++; continue }
                if (two == op && substr($0, i, 3) != "{-#") { depth = 1; i += 2; continue }
                if (lt != "" && two == lt) {
                    p = (i == 1) ? " " : substr($0, i - 1, 1)
                    if (!agda || p ~ /[ \t(){};@".]/) break  # `.`: `...--` is a comment
                }
                if (doc != "" && substr($0, i, 3) == doc) break
                out = out c; i++
            }
            print out
        }' "$file"
}

# Escape hatches per language. A word that is an escape hatch in one language
# can be an ordinary identifier in another (`admit` in Agda, say).
hatch_pattern() {  # hatch_pattern <file>
    case "$1" in
        *.agda) echo 'postulate|TERMINATING|NON_TERMINATING|NO_TERMINATION_CHECK|unsafeCoerce' ;;
        *.idr)  echo 'believe_me|assert_total|postulate|idris_crash' ;;
        *.lean) echo 'sorry|admit' ;;
        *.v)    echo 'Admitted|admit|Obj\.magic' ;;
        *)      echo 'believe_me|assert_total|postulate|sorry|admit|Admitted|unsafeCoerce|Obj\.magic' ;;
    esac
}

# Scan Agda, Idris2, Lean and Coq files in the temporary proof tree for each
# language's escape-hatch patterns, ignoring comments and literals. Print
# matches with source line numbers and report FAIL if any file has a match,
# setting the global failed flag; an empty tree reports PASS.
scan() {
    local hits=0 f m
    while IFS= read -r f; do
        m="$(strip_comments "$work/$f" | grep -nwE "$(hatch_pattern "$f")" || true)"
        if [ -n "$m" ]; then
            hits=$((hits + 1))
            echo "   escape hatch in ${f#./}:"
            printf '%s\n' "$m" | sed 's/^/        /'
        fi
    done < <(cd "$work" && find . -type f \( -name '*.agda' -o -name '*.idr' -o -name '*.lean' -o -name '*.v' \) | LC_ALL=C sort)
    if [ "$hits" -gt 0 ]; then
        report scan FAIL "$hits file(s) contain an escape hatch in code"
    else
        report scan PASS "no escape hatch in code (comments ignored)"
    fi
}

# Checkers run from inside the copy, so a relative library path is made
# absolute against the caller's directory first.
if [ -n "${AGDA_STDLIB:-}" ] && [ "${AGDA_STDLIB#/}" = "$AGDA_STDLIB" ]; then
    AGDA_STDLIB="$PWD/$AGDA_STDLIB"
fi

for leg in "${legs[@]}"; do
    case "$leg" in
        agda)
            if [ -n "${AGDA_STDLIB:-}" ]; then
                run_files agda agda agda agda agda --safe --without-K --cubical-compatible \
                    --no-libraries -i . -i "$AGDA_STDLIB"
            else
                run_files agda agda agda agda agda --safe --without-K --cubical-compatible
            fi ;;
        coq)    run_files coq coqc coq v coqc ;;
        lean4)  run_files lean4 lean lean4 lean lean ;;
        idris2) run_files idris2 idris2 idris2 idr idris2 --source-dir . --check ;;
        scan)   scan ;;
    esac
done

if [ "$failed" -ne 0 ]; then exit 1; fi
if [ "$unavailable" -ne 0 ]; then exit 3; fi
exit 0
