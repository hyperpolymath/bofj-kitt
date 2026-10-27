#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# A toplevel can exit zero after a proof error: require a checked theorem.
set -eu

transcript="$(mktemp)"
trap 'rm -f "$transcript"' EXIT
trap 'exit 1' HUP INT TERM
prover_exit=0
hol_light >"$transcript" 2>&1 <<'EOF' || prover_exit=$?
let smoke = REFL `T`;;
if concl smoke = `T = T` then
  print_endline "\nBOFJ_HOL_LIGHT_SMOKE_OK"
else failwith "reflexivity smoke failed";;
EOF
if [ "$prover_exit" -ne 0 ] || ! grep -qx 'BOFJ_HOL_LIGHT_SMOKE_OK' "$transcript"; then
  cat "$transcript" >&2
  exit 1
fi
