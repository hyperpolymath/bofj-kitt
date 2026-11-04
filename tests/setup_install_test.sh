#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Test installer fallback paths without networking or installing dependencies.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

# Source the actual functions without running setup's main routine.
sed '/^main "\$@"$/d' "$repo_root/build/setup.sh" > "$fixture_root/functions.sh"

# Cargo fallback, with stub executables and a real PATH lookup. Cargo's
# install root is deliberately NOT on PATH, as with a distro Cargo: setup must
# install into a known root and put its bin directory on PATH itself.
mkdir -p "$fixture_root/bin"
cat > "$fixture_root/bin/cargo" <<'SH'
#!/bin/sh
expected="install just --version 1.56.0 --locked --root $CARGO_HOME"
if [ "$*" != "$expected" ]; then
    echo "Unexpected Cargo arguments: $*" >&2
    exit 98
fi
mkdir -p "$CARGO_HOME/bin"
printf '#!/bin/sh\necho "just 1.56.0"\n' > "$CARGO_HOME/bin/just"
chmod +x "$CARGO_HOME/bin/just"
SH
printf '#!/bin/sh\nexit 1\n' > "$fixture_root/bin/sudo"  # an apt repository without just
chmod +x "$fixture_root/bin/cargo" "$fixture_root/bin/sudo"

for manager in apt unknown; do
    rm -rf "$fixture_root/cargo-home"
    FIXTURE_ROOT="$fixture_root" MANAGER="$manager" CARGO_HOME="$fixture_root/cargo-home" \
        PATH="$fixture_root/bin:/usr/bin:/bin" sh -eu <<'SH'
. "$FIXTURE_ROOT/functions.sh"
PKG_MGR="$MANAGER"
curl() { echo 'Unexpected download' >&2; exit 99; }
install_just
case ":$PATH:" in
    *":$CARGO_HOME/bin:"*) ;;
    *) echo "FAIL: $CARGO_HOME/bin was not added to PATH" >&2; exit 1 ;;
esac
[ "$(just --version)" = 'just 1.56.0' ]
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
just() { printf 'just 1.56.0\n'; }
cargo() { echo 'Unexpected install' >&2; exit 99; }
sudo() { echo 'Unexpected install' >&2; exit 99; }
install_just
SH
echo 'PASS: setup uses verified package installation paths'
