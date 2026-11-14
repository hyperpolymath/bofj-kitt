#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Test .claude/signing/cert-signing.sh and the hook's certificate mode with
# throwaway software CAs (the real CA lives in the owner's TPM and is never
# touched here). HOME, the session key directory and the trust-anchor file
# are all scratch, so the real git config and keys are never read or written.
# Checks: no CA -> loud refusal, and a refused request still leaves commits
# failing (no CA, no identity); before a certificate, commits fail; install
# refuses wrong key, wrong principal, extra principal, untrusted CA, expired,
# not-yet-valid, never-expiring, over-long and extension-bearing
# certificates; a good certificate gives %G? = G with the right committer;
# the recovery CA works alongside; an expired certificate stops commits; the
# hook in cert mode never reads CLAUDE_SIGNING_KEY and still exits 0.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/.claude/signing/cert-signing.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v ssh-keygen >/dev/null || fail "ssh-keygen is not on PATH"

export HOME="$work/home" GIT_CONFIG_NOSYSTEM=1
export SESSION_SIGNING_DIR="$work/shm" SESSION_SIGNING_CAS="$work/cas.pub"
export CLAUDE_SIGNING_NAME="Test Signer" CLAUDE_SIGNING_EMAIL="signer@example.invalid"
unset CLAUDE_SIGNING_KEY || true
mkdir -p "$HOME"

ca() { ssh-keygen -q -t ecdsa -b 256 -N '' -C "$1" -f "$work/$1"; }
ca tpm-ca; ca recovery-ca; ca rogue-ca
issue() { # issue NAME CA PRINCIPALS VALIDITY [extra ssh-keygen args...]
    local name="$1" caname="$2" princ="$3" validity="$4"; shift 4
    cp "$SESSION_SIGNING_DIR/id_session.pub" "$work/$name.pub"
    ssh-keygen -q -s "$work/$caname" -I "$name" -n "$princ" -V "$validity" "$@" "$work/$name.pub"
    echo "$work/$name-cert.pub"
}
refused() { # refused CERT EXPECTED-TEXT
    local out
    if out="$(sh "$script" install "$1" 2>&1)"; then fail "accepted $1"; fi
    grep -q -- "$2" <<<"$out" || fail "refusal for $1 lacked '$2': $out"
}

# 1. No CA listed: loud refusal.
printf '# none yet\n' > "$SESSION_SIGNING_CAS"
out="$(sh "$script" request 2>&1)" && fail "request succeeded with no CA"
grep -q "lists no CA key" <<<"$out" || fail "no-CA refusal unclear: $out"

# 1b. A refused request must still leave git failing closed: a commit made
# afterwards has to fail, loudly, not go through unsigned. Each case runs in a
# fresh HOME and session directory so no earlier configuration can hide a gap.
# The commit identity comes from the environment, so a missing identity cannot
# be what stops the commit.
commit_must_fail() { # commit_must_fail LABEL (run in the calling shell's HOME)
    local label="$1"
    local repo="$work/repo-$label" err="$work/err-$label"
    git init -q "$repo"
    (
        cd "$repo"
        echo a > a; git add a
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
        export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
        git commit -q -m "should fail" 2>"$err" && exit 3
        grep -q "no session certificate installed" "$err" || exit 4
    ) || fail "after a refused request ($label) a commit did not fail loudly (status $?): $(cat "$err" 2>/dev/null)"
}
for case_name in no-ca no-identity; do
    (
        export HOME="$work/home-$case_name" SESSION_SIGNING_DIR="$work/shm-$case_name"
        mkdir -p "$HOME"
        case "$case_name" in
            no-ca) printf '# none yet\n' > "$work/cas-$case_name.pub" ;;
            no-identity) cat "$work/tpm-ca.pub" > "$work/cas-$case_name.pub"; unset CLAUDE_SIGNING_EMAIL ;;
            *) echo "FAIL: unknown refused-request case $case_name" >&2; exit 6 ;;
        esac
        export SESSION_SIGNING_CAS="$work/cas-$case_name.pub"
        sh "$script" request >"$work/req-$case_name" 2>&1 && exit 5
        commit_must_fail "$case_name"
    ) || fail "refused-request case $case_name failed (status $?)"
done

# 2. With the TPM and recovery CAs: key made, request printed, commits fail.
cat "$work/tpm-ca.pub" "$work/recovery-ca.pub" > "$SESSION_SIGNING_CAS"
out="$(sh "$script" request 2>&1)" || fail "request failed: $out"
grep -q "WAITING FOR A CERTIFICATE" <<<"$out" || fail "no waiting notice: $out"
[[ -s "$SESSION_SIGNING_DIR/id_session" ]] || fail "no session key"
[[ "$(stat -c %a "$SESSION_SIGNING_DIR")" = 700 ]] || fail "key dir is not mode 700"
fp1="$(ssh-keygen -lf "$SESSION_SIGNING_DIR/id_session.pub")"
sh "$script" request >/dev/null 2>&1
[[ "$(ssh-keygen -lf "$SESSION_SIGNING_DIR/id_session.pub")" = "$fp1" ]] || fail "request is not idempotent: key changed"
git init -q "$work/repo"
cd "$work/repo"
echo a > a; git add a
git commit -q -m "should fail" 2>"$work/err" && fail "commit succeeded without a certificate"
grep -q "no session certificate installed" "$work/err" || fail "commit failure not loud: $(cat "$work/err")"

# 3. Refusals.
other="$work/otherkey"; ssh-keygen -q -t ed25519 -N '' -f "$other"
ssh-keygen -q -s "$work/tpm-ca" -I other -n "$CLAUDE_SIGNING_EMAIL" -O clear -V -5m:+1h "$other.pub"
refused "$other-cert.pub" "not this session's key"
refused "$(issue wrongp tpm-ca someone@example.invalid -5m:+1h -O clear)" "want exactly"
refused "$(issue twop tpm-ca "$CLAUDE_SIGNING_EMAIL,x@example.invalid" -5m:+1h -O clear)" "want exactly"
refused "$(issue rogue rogue-ca "$CLAUDE_SIGNING_EMAIL" -5m:+1h -O clear)" "not in"
refused "$(issue expired tpm-ca "$CLAUDE_SIGNING_EMAIL" -2h:-1h -O clear)" "expired at"
refused "$(issue future tpm-ca "$CLAUDE_SIGNING_EMAIL" +1h:+2h -O clear)" "not valid until"
refused "$(issue forever tpm-ca "$CLAUDE_SIGNING_EMAIL" always:forever -O clear)" "never expires"
refused "$(issue long tpm-ca "$CLAUDE_SIGNING_EMAIL" -5m:+30h -O clear)" "ceiling"
refused "$(issue exts tpm-ca "$CLAUDE_SIGNING_EMAIL" -5m:+1h)" "extensions"
echo junk > "$work/junk"; refused "$work/junk" "not an SSH certificate"
[[ ! -e "$SESSION_SIGNING_DIR/id_session-cert.pub" ]] || fail "a refused certificate was left installed"

# 4. A good certificate, read from stdin: commit verifies as G.
good="$(issue good tpm-ca "$CLAUDE_SIGNING_EMAIL" -5m:+8h -O clear)"
out="$(sh "$script" install - < "$good" 2>&1)" || fail "good certificate refused: $out"
git commit -q -m "signed" || fail "commit failed with a good certificate"
st="$(git log -1 --format='%G? %ce')"
[[ "$st" = "G $CLAUDE_SIGNING_EMAIL" ]] || fail "commit status '$st', want 'G $CLAUDE_SIGNING_EMAIL'"
sh "$script" status >/dev/null || fail "status not ok with a valid certificate"

# 5. The recovery CA signs alongside.
rec="$(issue recovered recovery-ca "$CLAUDE_SIGNING_EMAIL" -5m:+1h -O clear)"
sh "$script" install "$rec" >/dev/null 2>&1 || fail "recovery-CA certificate refused"
echo b > b; git add b; git commit -q -m "recovery-signed"
[[ "$(git log -1 --format=%G?)" = G ]] || fail "recovery-CA commit is not G"

# 6. Expiry mid-session: the guard refuses to sign, and status says so.
cp "$(issue lapsed tpm-ca "$CLAUDE_SIGNING_EMAIL" -2h:-1m -O clear)" "$SESSION_SIGNING_DIR/id_session-cert.pub"
echo c > c; git add c
git commit -q -m "after expiry" 2>"$work/err" && fail "commit succeeded with an expired certificate"
grep -q "expired at" "$work/err" || fail "expiry refusal not loud: $(cat "$work/err")"
sh "$script" status >/dev/null 2>&1 && fail "status ok with an expired certificate"

# 7. Removing a CA from the trust file revokes its past signatures locally.
grep -v -F "$(cat "$work/recovery-ca.pub")" "$SESSION_SIGNING_CAS" > "$work/cas2"; mv "$work/cas2" "$SESSION_SIGNING_CAS"
sh "$script" request >/dev/null 2>&1 || true
[[ "$(git log -1 --format=%G? HEAD)" != G ]] || fail "recovery-CA commit still G after the CA was removed"
[[ "$(git log -1 --format=%G? HEAD~1)" = G ]] || fail "TPM-CA commit lost G when only the recovery CA was removed"
cd "$work"

# 8. The hook in cert mode: never reads CLAUDE_SIGNING_KEY, exits 0, asks for a certificate.
proj="$work/proj"
mkdir -p "$proj/.claude/hooks" "$proj/.claude/signing"
cp "$repo_root/.claude/hooks/session-start.sh" "$proj/.claude/hooks/"
cp "$script" "$proj/.claude/signing/"
echo cert > "$proj/.claude/signing/mode"
rm -rf "$SESSION_SIGNING_DIR"
out="$(CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$proj" CLAUDE_SIGNING_KEY=not-base64-at-all \
      sh "$proj/.claude/hooks/session-start.sh" 2>&1)" || fail "hook exited non-zero in cert mode"
grep -q "WAITING FOR A CERTIFICATE" <<<"$out" || fail "hook did not request a certificate: $out"
grep -q "CLAUDE_SIGNING_KEY is not valid base64" <<<"$out" && fail "hook read CLAUDE_SIGNING_KEY in cert mode"
echo bogus > "$proj/.claude/signing/mode"
out="$(CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$proj" sh "$proj/.claude/hooks/session-start.sh" 2>&1)" || fail "hook exited non-zero on a bad mode"
grep -q "mode is 'bogus'" <<<"$out" || fail "bad mode not reported: $out"

echo "PASS: certificate signing refuses bad certificates and missing/expired ones loudly, signs G with TPM or recovery CA, and the hook's cert mode never reads CLAUDE_SIGNING_KEY"
