#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Test installer fallback paths without networking or installing dependencies.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

# Source the actual functions without running setup's main routine.
sed '/^main "\$@"$/d' "$repo_root/build/setup.sh" > "$fixture_root/functions.sh"

for manager in apt unknown; do
    FIXTURE_ROOT="$fixture_root" MANAGER="$manager" sh -eu <<'SH'
. "$FIXTURE_ROOT/functions.sh"
PKG_MGR="$MANAGER"
installed=false
command() {
    case "$2" in
        just) [ "$installed" = true ] ;;
        cargo) return 0 ;;
        *) return 1 ;;
    esac
}
sudo() { return 1; }  # Simulate an apt repository without just.
curl() { echo 'Unexpected download' >&2; exit 99; }
cargo() {
    if [ "$*" != 'install just --version 1.40.0 --locked' ]; then
        echo "Unexpected Cargo arguments: $*" >&2
        exit 98
    fi
    installed=true
}
just() { printf 'just 1.40.0\n'; }
install_just
[ "$installed" = true ]
SH
done

# No Cargo: return a failure without attempting remote shell execution.
FIXTURE_ROOT="$fixture_root" sh -eu <<'SH'
. "$FIXTURE_ROOT/functions.sh"
PKG_MGR=unknown
command() { return 1; }
curl() { echo 'Unexpected download' >&2; exit 99; }
if install_just; then
    echo 'FAIL: installation without Cargo unexpectedly succeeded' >&2
    exit 1
fi
SH

# An already installed just must not trigger an installation.
FIXTURE_ROOT="$fixture_root" sh -eu <<'SH'
. "$FIXTURE_ROOT/functions.sh"
command() { [ "$2" = just ]; }
just() { printf 'just 1.40.0\n'; }
cargo() { echo 'Unexpected install' >&2; exit 99; }
sudo() { echo 'Unexpected install' >&2; exit 99; }
install_just
SH
echo 'PASS: setup uses verified package installation paths'
