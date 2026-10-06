# SPDX-License-Identifier: MPL-2.0
# shellcheck shell=bash
# Estate developer toolchains — sourced from ~/.profile.
# Toolchain binaries live under ~/developer/tools/opt (gitignored); language and
# prover/solver front-end bins are grouped under languages/ and provers-solvers/.
export DEV_TOOLS="$HOME/developer/tools"
export RUSTUP_HOME="$DEV_TOOLS/opt/rustup"
export CARGO_HOME="$DEV_TOOLS/opt/cargo"
export MISE_DATA_DIR="$DEV_TOOLS/opt/mise"
export PACK_DIR="$DEV_TOOLS/opt/pack"
export IDRIS2_PREFIX="$PACK_DIR"
export ALIRE_HOME="$DEV_TOOLS/opt/alire"
# Moved from $HOME 2026-10-01 (symlinks remain at the old paths for running shells).
export ELAN_HOME="$DEV_TOOLS/opt/elan"
export JULIA_DEPOT_PATH="$DEV_TOOLS/opt/julia-depot:"
export OPAMROOT="$DEV_TOOLS/opt/opam"
export BUN_INSTALL="$DEV_TOOLS/opt/bun"
export PATH="$CARGO_HOME/bin:$ELAN_HOME/bin:$MISE_DATA_DIR/shims:$PACK_DIR/bin:$DEV_TOOLS/languages/bin:$DEV_TOOLS/provers-solvers/bin:$DEV_TOOLS/opt/gh/bin:$DEV_TOOLS/bin:$HOME/.local/bin:$PATH"
if command -v mise >/dev/null 2>&1; then eval "$(mise activate bash 2>/dev/null || true)"; fi
