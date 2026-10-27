#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Install core-backend smoke inputs before the bundle's verify phase.
set -eu

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "usage: sh install-smoke.sh PREFIX" >&2
  exit 2
fi

smoke_dir="$(CDPATH='' cd -- "$(dirname -- "$0")/smoke" && pwd)"
destination="$1/share/smoke"
install -d "$destination"
for fixture in hol-light-refl.sh hol4-smoke.sml acl2-smoke.lisp smoke.miz \
    mizar-smoke.sh pvs-smoke.sh pvs_smoke.pvs; do
  install -m 644 "$smoke_dir/$fixture" "$destination/$fixture"
done
