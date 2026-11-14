#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# cert-signing.sh: short-lived SSH-certificate commit signing for cloud
# sessions (docs/proposals/short-lived-signing-certificates.adoc, option (a):
# the CA key stays in the owner's workstation TPM; the session never holds
# anything that can mint a certificate).
#
#   cert-signing.sh request          make this session's key (once) and print the
#                                    certificate request for the owner
#   cert-signing.sh install [FILE]   check a certificate (FILE, or stdin) and
#                                    switch git signing to it
#   cert-signing.sh status           print the key, the certificate and its expiry
#
# Reads CLAUDE_SIGNING_NAME and CLAUDE_SIGNING_EMAIL. Never reads or writes
# CLAUDE_SIGNING_KEY. Trust anchors come from trusted-cas.pub beside this
# script (committed by the owner after the key ceremony).
#
# The session key lives in memory-backed storage (/dev/shm) and dies with the
# container. Until a valid certificate is installed, git is pointed at a
# certificate file that does not exist, so `git commit` FAILS rather than
# producing an unsigned or wrongly signed commit.
#
# git is pointed at a copy of this script as gpg.ssh.program (guard mode,
# first argument -Y): it refuses to sign with a missing or expired
# certificate and otherwise runs ssh-keygen unchanged.
#
# Exit codes: 0 ok; 1 refused (with a reason on stderr); 2 usage.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
cas="${SESSION_SIGNING_CAS:-$here/trusted-cas.pub}"
dir="${SESSION_SIGNING_DIR:-/dev/shm/claude-signing-$(id -u)}"
key="$dir/id_session"
cert="$dir/id_session-cert.pub"
signers="$dir/allowed_signers"
# Longest certificate validity accepted, in seconds (default 24 hours).
max_validity="${SESSION_SIGNING_MAX_SECONDS:-86400}"

die() { printf '%s\n' "!!! cert-signing: $1" >&2; exit 1; }

need_identity() {
  [ -n "${CLAUDE_SIGNING_NAME:-}" ] || die "CLAUDE_SIGNING_NAME is not set"
  [ -n "${CLAUDE_SIGNING_EMAIL:-}" ] || die "CLAUDE_SIGNING_EMAIL is not set"
  command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is not on PATH"
}

# The CA public keys, one per line, comments and blanks dropped.
ca_keys() {
  [ -r "$cas" ] || die "trust anchor file $cas is missing"
  grep -Ev '^[[:space:]]*(#|$)' "$cas" || true
}

write_signers() {
  keys=$(ca_keys)
  [ -n "$keys" ] || die "$cas lists no CA key; the owner adds them after the key ceremony (docs/practice/session-signing-certificates.adoc)"
  tmp="$signers.tmp.$$"
  printf '%s\n' "$keys" | while IFS= read -r line; do
    case "$line" in
      ssh-*\ *|ecdsa-*\ *|sk-*\ *) printf '%s cert-authority,namespaces="git" %s\n' "$CLAUDE_SIGNING_EMAIL" "$line" ;;
      *) echo "BAD" ;;
    esac
  done > "$tmp"
  if grep -qx BAD "$tmp"; then rm -f "$tmp"; die "$cas has a line that is not an SSH public key"; fi
  mv -f "$tmp" "$signers"
  chmod 644 "$signers"
}

# Make git refuse to commit until a valid certificate is installed: sign every
# commit, with the (possibly not yet existing) certificate, through the guard.
# It needs no identity, trust anchor or key, so `request` runs it first, before
# any check that can exit: a refused request must still leave git failing
# closed, never committing unsigned. Global scope, as the key-based hook does;
# gpg.ssh.program is reset because the harness points it at its own signer.
lock_git() {
  ( umask 077; mkdir -p "$dir" ) && chmod 700 "$dir" || die "could not create $dir"
  git config --global user.signingkey "$cert"
  git config --global gpg.format ssh
  # git calls this script (copied beside the key) instead of ssh-keygen; in
  # guard mode it refuses to sign with an expired certificate, which
  # ssh-keygen itself would do silently (measured in the proposal).
  cp "$0" "$dir/guard.sh.tmp" && chmod 755 "$dir/guard.sh.tmp" && mv -f "$dir/guard.sh.tmp" "$dir/guard.sh"
  git config --global gpg.ssh.program "$dir/guard.sh"
  git config --global commit.gpgsign true
}

# The rest of the git configuration, which does need the identity and the
# allowed-signers file, so it follows their checks.
configure_git() {
  lock_git
  git config --global user.name "$CLAUDE_SIGNING_NAME"
  git config --global user.email "$CLAUDE_SIGNING_EMAIL"
  git config --global gpg.ssh.allowedSignersFile "$signers"
}

fingerprint() { ssh-keygen -l -f "$1" | awk '{print $2}'; }

cmd_request() {
  lock_git
  need_identity
  old_umask=$(umask); umask 077
  mkdir -p "$dir"; chmod 700 "$dir"
  if [ ! -s "$key" ]; then
    rm -f "$key" "$key.pub" "$cert"
    ssh-keygen -q -t ed25519 -N '' -C "claude-session-$(hostname 2>/dev/null || echo unknown)-$(date -u +%Y%m%dT%H%M%SZ)" -f "$key" \
      || { umask "$old_umask"; die "could not generate the session key in $dir"; }
  fi
  umask "$old_umask"
  write_signers
  configure_git
  if [ -s "$cert" ] && cert_still_valid; then
    echo "Session signing certificate installed and valid until $(cert_field_to)."
    return 0
  fi
  rm -f "$cert"
  cat <<EOF
!!! Commit signing is WAITING FOR A CERTIFICATE: git commit will fail until one is installed.
!!! Session key: $(fingerprint "$key.pub")
!!! Owner, on the workstation (TPM CA; see docs/practice/session-signing-certificates.adoc):
!!!   1. save this one line as session.pub:
$(cat "$key.pub")
!!!   2. issue:  ssh-keygen -s <tpm-ca.pub> -U -I <session-id> -n '$CLAUDE_SIGNING_EMAIL' -O clear -V -5m:+8h session.pub
!!!   3. paste the contents of session-cert.pub back to the session.
!!! Session installs it with: .claude/signing/cert-signing.sh install <file>
EOF
}

# ssh-keygen -L field readers (on $1, default the installed cert).
cert_info() { ssh-keygen -L -f "${1:-$cert}" 2>/dev/null; }
cert_field_to() { cert_info "${1:-}" | sed -n 's/^[[:space:]]*Valid: from .* to \(.*\)$/\1/p'; }

cert_still_valid() {
  to=$(cert_field_to) || return 1
  [ -n "$to" ] && [ "$to" != forever ] || return 1
  to_s=$(date -d "$to" +%s 2>/dev/null) || return 1
  [ "$to_s" -gt "$(date +%s)" ]
}

cmd_install() {
  need_identity
  [ -s "$key" ] || die "no session key in $dir; run 'cert-signing.sh request' first"
  write_signers
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  if [ $# -ge 1 ] && [ "$1" != - ]; then
    [ -r "$1" ] || die "cannot read $1"
    cp "$1" "$work/c-cert.pub"
  else
    cat > "$work/c-cert.pub"
  fi
  info=$(cert_info "$work/c-cert.pub") || die "input is not an SSH certificate"
  [ -n "$info" ] || die "input is not an SSH certificate"

  printf '%s\n' "$info" | grep -q 'Type: ssh-ed25519-cert-v01@openssh.com user certificate' \
    || die "not an ed25519 user certificate"

  # 1. It certifies this session's key, not some other key.
  got=$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*Public key: [A-Z0-9-]* \(SHA256:[^ ]*\).*/\1/p')
  [ "$got" = "$(fingerprint "$key.pub")" ] || die "certificate is for key $got, not this session's key $(fingerprint "$key.pub")"

  # 2. Exactly one principal, the signing identity.
  principals=$(printf '%s\n' "$info" | awk '/^[[:space:]]*Principals:/{p=1;next} /^[[:space:]]*Critical Options:/{p=0} p{gsub(/^[[:space:]]+/,""); print}')
  [ "$principals" = "$CLAUDE_SIGNING_EMAIL" ] || die "certificate principals are [$(printf '%s' "$principals" | tr '\n' ' ')], want exactly [$CLAUDE_SIGNING_EMAIL]"

  # 3. No critical options and no extensions (issued with -O clear).
  printf '%s\n' "$info" | grep -q '^[[:space:]]*Critical Options: (none)' || die "certificate carries critical options; issue it with -O clear"
  printf '%s\n' "$info" | grep -q '^[[:space:]]*Extensions: (none)' || die "certificate carries extensions; issue it with -O clear"

  # 4. Signed by a trusted CA.
  ca_fp=$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*Signing CA: [A-Z0-9-]* \(SHA256:[^ ]*\).*/\1/p')
  trusted=no
  ca_keys > "$work/cas"
  while IFS= read -r line; do
    printf '%s\n' "$line" > "$work/one.pub"
    [ "$(fingerprint "$work/one.pub")" = "$ca_fp" ] && trusted=yes
  done < "$work/cas"
  [ "$trusted" = yes ] || die "certificate is signed by CA $ca_fp, which is not in $cas"

  # 5. A bounded window that is open now.
  valid=$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*Valid: //p')
  case "$valid" in
    forever|*" to forever") die "certificate never expires; issue it with -V" ;;
    "from "*" to "*) ;;
    *) die "cannot read the certificate validity: $valid" ;;
  esac
  from=$(printf '%s' "$valid" | sed 's/^from \(.*\) to .*$/\1/')
  to=$(printf '%s' "$valid" | sed 's/^from .* to \(.*\)$/\1/')
  from_s=$(date -d "$from" +%s) || die "cannot parse $from"
  to_s=$(date -d "$to" +%s) || die "cannot parse $to"
  now=$(date +%s)
  [ "$from_s" -le "$now" ] || die "certificate is not valid until $from"
  [ "$to_s" -gt "$now" ] || die "certificate expired at $to"
  [ $((to_s - from_s)) -le "$max_validity" ] || die "certificate validity is $((to_s - from_s))s, more than the ${max_validity}s ceiling"

  # 6. End to end: sign and verify a blob exactly as git will.
  cp "$work/c-cert.pub" "$cert.new"
  chmod 644 "$cert.new"
  mv -f "$cert.new" "$cert"
  echo probe > "$work/blob"
  if ! ssh-keygen -q -Y sign -n git -f "$cert" "$work/blob" >/dev/null 2>"$work/err" \
     || ! ssh-keygen -q -Y verify -n git -f "$signers" -I "$CLAUDE_SIGNING_EMAIL" -s "$work/blob.sig" < "$work/blob" >/dev/null 2>>"$work/err"; then
    rm -f "$cert"
    die "test signature did not verify against $signers: $(tr '\n' ' ' < "$work/err")"
  fi

  configure_git
  echo "Session signing certificate installed: CA $ca_fp, valid until $to."
}

cmd_status() {
  need_identity
  [ -s "$key" ] || { echo "No session key (run 'cert-signing.sh request')."; exit 1; }
  echo "Session key: $(fingerprint "$key.pub")"
  if [ ! -s "$cert" ]; then echo "!!! No certificate installed: commits will fail."; exit 1; fi
  if cert_still_valid; then
    echo "Certificate valid until $(cert_field_to)."
  else
    echo "!!! Certificate EXPIRED at $(cert_field_to): new commits would sign but verify as U. Request a new one."
    exit 1
  fi
}

# Guard mode: git invokes us as its ssh-keygen. Pass everything through,
# except refuse `-Y sign` with a certificate that is missing or expired.
guard() {
  op=""; f=""; prev=""
  for a in "$@"; do
    [ "$prev" = -Y ] && op="$a"
    [ "$prev" = -f ] && f="$a"
    prev="$a"
  done
  if [ "$op" = sign ]; then
    case "$f" in
      *-cert.pub)
        [ -s "$f" ] || die "no session certificate installed ($f); commit refused. Run .claude/signing/cert-signing.sh request"
        to=$(cert_field_to "$f")
        to_s=$(date -d "$to" +%s 2>/dev/null) || die "cannot read the expiry of $f; commit refused"
        [ "$to_s" -gt "$(date +%s)" ] || die "session certificate expired at $to; commit refused. Run .claude/signing/cert-signing.sh request"
        ;;
    esac
  fi
  exec ssh-keygen "$@"
}

case "${1:-}" in
  -Y) guard "$@" ;;
  request) shift; cmd_request "$@" ;;
  install) shift; cmd_install "$@" ;;
  status) shift; cmd_status "$@" ;;
  *) echo "usage: cert-signing.sh request | install [FILE|-] | status" >&2; exit 2 ;;
esac
