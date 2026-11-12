#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
#
# session-start.sh: configure SSH commit signing at Claude Code session start.
#
# Reads CLAUDE_SIGNING_KEY (base64 of an ed25519 private key, one line),
# CLAUDE_SIGNING_NAME and CLAUDE_SIGNING_EMAIL from the cloud environment.
# Writes ~/.ssh/id_ed25519_signing (mode 600) and ~/.ssh/allowed_signers,
# then sets signing config in the global git config (~/.gitconfig).
#
# Idempotent. Never prints the key. On any problem it prints a loud warning
# and exits 0, so the session still starts (unsigned-commit risk is reported,
# not hidden).

set -eu

# Cloud sessions only: on a workstation this would overwrite a real key file.
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

warn() {
  printf '%s\n' "!!! WARNING: commit signing NOT configured: $1" \
    "!!! Commits from this session will not carry the CLAUDE_SIGNING_KEY signature."
  exit 0
}

missing=""
[ -n "${CLAUDE_SIGNING_KEY:-}" ] || missing="$missing CLAUDE_SIGNING_KEY"
[ -n "${CLAUDE_SIGNING_NAME:-}" ] || missing="$missing CLAUDE_SIGNING_NAME"
[ -n "${CLAUDE_SIGNING_EMAIL:-}" ] || missing="$missing CLAUDE_SIGNING_EMAIL"
[ -z "$missing" ] || warn "missing environment variable(s):$missing"

# git needs ssh-keygen to sign with gpg.format=ssh; the base image lacks it.
if ! command -v ssh-keygen >/dev/null 2>&1; then
  { apt-get install -y openssh-client || { apt-get update && apt-get install -y openssh-client; }; } \
    >/dev/null 2>&1 || warn "ssh-keygen is missing and apt-get could not install openssh-client"
fi

ssh_dir="$HOME/.ssh"
key="$ssh_dir/id_ed25519_signing"
signers="$ssh_dir/allowed_signers"

umask 077
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"

# Decode to a temp file, then move into place, so a bad value never leaves a
# half-written key. snip:prod: key material: no echo, no set -x, mode 600.
tmp="$key.tmp.$$"
trap 'rm -f "$tmp"' EXIT
printf '%s' "$CLAUDE_SIGNING_KEY" | base64 -d > "$tmp" 2>/dev/null \
  || warn "CLAUDE_SIGNING_KEY is not valid base64"
chmod 600 "$tmp"
pub=$(ssh-keygen -y -P '' -f "$tmp" 2>/dev/null) \
  || warn "CLAUDE_SIGNING_KEY is not an unencrypted OpenSSH private key"
case "$pub" in
  ssh-ed25519\ *) ;;
  *) warn "CLAUDE_SIGNING_KEY is not an ed25519 key" ;;
esac
mv -f "$tmp" "$key"
printf '%s\n' "$pub" > "$key.pub"
printf '%s namespaces="git" %s\n' "$CLAUDE_SIGNING_EMAIL" "$pub" > "$signers"
chmod 644 "$key.pub" "$signers"

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
