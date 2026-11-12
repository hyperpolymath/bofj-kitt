#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# provers.sh: the kit's toolchain front door (DESIGN.adoc).
#
#   provers.sh doctor [--json] [--env ID] [--timeout SECS] [--setup-report FILE]
#       Run every toolchain.kyaml entry's own check, plus the checks the
#       environment class's setup declares, and report each as PRESENT,
#       DRIFT or UNAVAILABLE with a reason. --json prints the capability
#       record (JCS-canonical I-JSON, one final newline).
#       Exit 0 all PRESENT, 1 any DRIFT, 3 something UNAVAILABLE, 2 error.
#   provers.sh render [--check] [--out DIR]
#       Render each environment class's setup script, allowlist and
#       environment variable names into tools/environments/rendered/.
#       --check exits 1 when a committed file differs from the manifests.
#   provers.sh install
#       Not built. Owner decision 2026-11-12: always-needed tools are
#       preinstalled by the class's rendered setup script; nothing installs
#       from inside a session. Exits 2.
#
# The engine is the Rust crate beside this script, built on first use with
# `cargo build --release --locked`. PROVERS_BIN names a prebuilt engine.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
crate="$here/provers"

case "${1:-}" in
    doctor|render) ;;
    install)
        echo "provers.sh install: not built; see the owner decision of 2026-11-12 in this script's header" >&2
        exit 2 ;;
    *)
        sed -n '/^#   provers.sh doctor/,/^#       preinstalled/p' "$0" | sed 's/^# \{0,1\}//' >&2
        exit 2 ;;
esac

bin="${PROVERS_BIN:-$crate/target/release/provers}"
if [ -z "${PROVERS_BIN:-}" ]; then
    stale=0
    [ -x "$bin" ] || stale=1
    if [ "$stale" -eq 0 ] && [ -n "$(find "$crate/src" "$crate/Cargo.toml" "$crate/Cargo.lock" -newer "$bin" 2>/dev/null | head -n 1)" ]; then
        stale=1
    fi
    if [ "$stale" -eq 1 ]; then
        if ! command -v cargo >/dev/null 2>&1; then
            echo "provers.sh: cargo is not on PATH, so the engine cannot be built; set PROVERS_BIN to a built engine" >&2
            exit 2
        fi
        cargo build --release --locked --quiet --manifest-path "$crate/Cargo.toml" >&2 || {
            echo "provers.sh: building the engine failed" >&2
            exit 2
        }
    fi
fi
[ -x "$bin" ] || { echo "provers.sh: no engine at $bin" >&2; exit 2; }

exec "$bin" --root "$root" "$@"
