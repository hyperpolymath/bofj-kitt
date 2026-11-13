#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
#
# session-start.sh: Claude Code SessionStart hook. Two jobs, in order:
#
# 1. Commit signing (cloud sessions only; ported from rsr-template-repo).
#    Reads CLAUDE_SIGNING_KEY (base64 of an ed25519 private key, one line),
#    CLAUDE_SIGNING_NAME and CLAUDE_SIGNING_EMAIL from the cloud environment.
#    Writes ~/.ssh/id_ed25519_signing (mode 600) and ~/.ssh/allowed_signers,
#    then sets signing config in the global git config (~/.gitconfig).
#    If .claude/signing/mode says "cert", the hook instead makes a session
#    key in memory-backed storage and asks the owner for a short-lived SSH
#    certificate (.claude/signing/cert-signing.sh); CLAUDE_SIGNING_KEY is
#    not read. Until a certificate is installed, commits fail loudly.
#
# 2. Capability record (every session; proposal E4). Runs
#    `tools/proof-toolchain/provers.sh doctor --json` and writes the record to
#    .session/capability-record.json, then names every UNAVAILABLE leg. By
#    owner decision (2026-11-12) the hook never installs anything: what a
#    session always needs comes from the environment's rendered setup script.
#
# Idempotent. Never prints the key. On any problem it prints a loud warning
# and still exits 0, so the session always starts: a problem is reported,
# never hidden, and never blocks.

set -eu

warn() {
  printf '%s\n' "!!! WARNING: $1"
}

# --- 1. Commit signing -------------------------------------------------------

signing_warn() {
  reason="$1"
  warn "commit signing NOT configured: $reason"
  printf '%s\n' "!!! Commits from this session will not carry the CLAUDE_SIGNING_KEY signature."
}

configure_signing() {
  missing=""
  [ -n "${CLAUDE_SIGNING_KEY:-}" ] || missing="$missing CLAUDE_SIGNING_KEY"
  [ -n "${CLAUDE_SIGNING_NAME:-}" ] || missing="$missing CLAUDE_SIGNING_NAME"
  [ -n "${CLAUDE_SIGNING_EMAIL:-}" ] || missing="$missing CLAUDE_SIGNING_EMAIL"
  [ -z "$missing" ] || { signing_warn "missing environment variable(s):$missing"; return 0; }

  # git needs ssh-keygen to sign with gpg.format=ssh; the base image lacks it.
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    { apt-get install -y openssh-client || { apt-get update && apt-get install -y openssh-client; }; } \
      >/dev/null 2>&1 || { signing_warn "ssh-keygen is missing and apt-get could not install openssh-client"; return 0; }
  fi

  ssh_dir="$HOME/.ssh"
  key="$ssh_dir/id_ed25519_signing"
  signers="$ssh_dir/allowed_signers"

  old_umask=$(umask)
  umask 077
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"

  # Decode to a temp file, then move into place, so a bad value never leaves a
  # half-written key. snip:prod: key material: no echo, no set -x, mode 600.
  tmp="$key.tmp.$$"
  if ! printf '%s' "$CLAUDE_SIGNING_KEY" | base64 -d > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; umask "$old_umask"
    signing_warn "CLAUDE_SIGNING_KEY is not valid base64"; return 0
  fi
  chmod 600 "$tmp"
  if ! pub=$(ssh-keygen -y -P '' -f "$tmp" 2>/dev/null); then
    rm -f "$tmp"; umask "$old_umask"
    signing_warn "CLAUDE_SIGNING_KEY is not an unencrypted OpenSSH private key"; return 0
  fi
  case "$pub" in
    ssh-ed25519\ *) ;;
    *) rm -f "$tmp"; umask "$old_umask"; signing_warn "CLAUDE_SIGNING_KEY is not an ed25519 key"; return 0 ;;
  esac
  mv -f "$tmp" "$key"
  printf '%s\n' "$pub" > "$key.pub"
  printf '%s namespaces="git" %s\n' "$CLAUDE_SIGNING_EMAIL" "$pub" > "$signers"
  chmod 644 "$key.pub" "$signers"
  umask "$old_umask"

  # Global scope, so every repository in the session signs with this key. This
  # overwrites the harness signer settings in ~/.gitconfig. gpg.ssh.program is
  # reset to ssh-keygen because the harness points it at its own signer, which
  # would ignore our key.
  git config --global user.name "$CLAUDE_SIGNING_NAME"
  git config --global user.email "$CLAUDE_SIGNING_EMAIL"
  git config --global user.signingkey "$key"
  git config --global gpg.format ssh
  git config --global gpg.ssh.program ssh-keygen
  git config --global gpg.ssh.allowedSignersFile "$signers"
  git config --global commit.gpgsign true

  echo "Commit signing configured (ssh, key $key, principal from CLAUDE_SIGNING_EMAIL)."
}

configure_cert_signing() {
  script="$root/.claude/signing/cert-signing.sh"
  if ! sh "$script" request; then
    warn "commit signing NOT configured: certificate mode could not start (see above)"
    printf '%s\n' "!!! Commits from this session will fail until this is fixed."
  fi
}

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
signing_mode=key
[ ! -r "$root/.claude/signing/mode" ] || signing_mode=$(tr -d '[:space:]' < "$root/.claude/signing/mode")

# Cloud sessions only: on a workstation this would overwrite a real key file.
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
  case "$signing_mode" in
    cert) configure_cert_signing ;;
    key|"") configure_signing ;;
    *) warn "commit signing NOT configured: .claude/signing/mode is '$signing_mode', want 'key' or 'cert'" ;;
  esac
fi

# --- 2. Capability record ----------------------------------------------------

provers="$root/tools/proof-toolchain/provers.sh"
session_dir="$root/.session"
record="$session_dir/capability-record.json"
budget="${PROVERS_HOOK_BUDGET:-50}"

# Print the record's summary and name each UNAVAILABLE leg. In the JCS record
# a "reason" member follows "id" only on UNAVAILABLE entries.
report_record() {
  summary=$(grep -o '"summary":{[^}]*}' "$record" || echo '"summary":?')
  echo "Capability record written to .session/capability-record.json: $summary"
  ids=$(grep -o '"id":"[^"]*","reason"' "$record" | cut -d'"' -f4 | tr '\n' ' ' || true)
  [ -z "$ids" ] || warn "UNAVAILABLE in this session (see the record for each reason): $ids"
}

run_doctor() {
  if ! mkdir -p "$session_dir" 2>/dev/null; then
    warn "capability record NOT written: cannot create $session_dir"; return 0
  fi
  if [ ! -x "$provers" ]; then
    warn "capability record NOT written: $provers is missing or not executable"; return 0
  fi
  rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout "$budget" "$provers" doctor --json --timeout 10 > "$record.tmp" 2> "$session_dir/doctor.err" || rc=$?
  else
    "$provers" doctor --json --timeout 10 > "$record.tmp" 2> "$session_dir/doctor.err" || rc=$?
  fi
  # Exit 1 also means "crashed", so a record counts only if it is one.
  if [ "$rc" -ne 124 ] && ! grep -q '"record_type":{"id":"5934cd83-73e5-80ab-abf5-f1c0bd3526fd"' "$record.tmp" 2>/dev/null; then
    rc="not-a-record:$rc"
  fi
  case "$rc" in
    0|1|3)
      mv -f "$record.tmp" "$record"
      [ "$rc" -ne 1 ] || warn "a tool reports DRIFT: its version differs from what this environment expects"
      report_record ;;
    124)
      rm -f "$record.tmp"
      warn "capability record NOT written: doctor did not finish within ${budget}s (a first run builds the engine). Run tools/proof-toolchain/provers.sh doctor" ;;
    *)
      rm -f "$record.tmp"
      warn "capability record NOT written: doctor exited ${rc#not-a-record:} without printing a record; see .session/doctor.err" ;;
  esac
}

run_doctor
exit 0
