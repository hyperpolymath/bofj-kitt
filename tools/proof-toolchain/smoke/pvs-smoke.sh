#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Prove pvs_smoke.pvs in batch mode from a scratch directory (PVS writes
# pvsbin/ and .pvscontext beside the file). proveit's exit status is not
# documented to reflect unproved formulas, so require the summary line.
set -eu

smoke_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
cp "$smoke_dir/pvs_smoke.pvs" "$work/pvs_smoke.pvs"
cd "$work"
prover_exit=0
proveit --force pvs_smoke.pvs >transcript 2>&1 || prover_exit=$?
if [ "$prover_exit" -ne 0 ] ||
   ! grep -Eq 'Grand Totals: 1 proofs?, 1 attempted, 1 succeeded' transcript; then
  cat transcript >&2
  exit 1
fi
