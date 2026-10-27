#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Verify smoke.miz against the bundled MML from a scratch directory, so a
# doctor run never writes into the installed prefix.
# Usage: sh mizar-smoke.sh PREFIX
set -eu

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: sh mizar-smoke.sh PREFIX" >&2
  exit 2
fi

smoke_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# Closure rule: always the bundle's MML, never a host MIZFILES.
MIZFILES="$1/share/mizar"
export MIZFILES
if [ ! -d "$MIZFILES" ]; then
  echo "mizar smoke: MIZFILES $MIZFILES is not a directory" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$work/text"
cp "$smoke_dir/smoke.miz" "$work/text/smoke.miz"
cd "$work"
makeenv text/smoke
verifier text/smoke
# Mizar reports article errors in the .err file, not only in its exit status.
if [ ! -f text/smoke.err ] || [ -s text/smoke.err ]; then
  echo "mizar smoke: verifier left errors (or no error file)" >&2
  cat text/smoke.err >&2 2>/dev/null || true
  exit 1
fi
