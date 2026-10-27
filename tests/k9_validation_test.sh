#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Regression checks for K9-SVC validation alongside legacy session bindings.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/session" "$fixture_root/.github/hooks"
cp "$repo_root/.github/hooks/validate-k9.sh" "$fixture_root/.github/hooks/"
cp "$repo_root/coordination.k9" "$fixture_root/coordination.k9"
cp "$repo_root/session/custom-checks.k9" "$fixture_root/session/custom-checks.k9"
cp "$repo_root/.machine_readable/svc/k9/template-kennel.k9.ncl" "$fixture_root/component.k9"

validate() {
    INPUT_PATH="$fixture_root/" INPUT_STRICT=true \
        bash "$fixture_root/.github/hooks/validate-k9.sh" > "$fixture_root/result.log"
}

expect_failure() {
    if validate; then
        echo "FAIL: $1 unexpectedly passed" >&2
        exit 1
    fi
    grep -qF "$2" "$fixture_root/result.log"
}

# The integration files coexist with SVC components, without changing YAML.
validate
grep -qF 'Files scanned: 1' "$fixture_root/result.log"

# Unknown .k9 files cannot claim the legacy session exception.
cp "$fixture_root/coordination.k9" "$fixture_root/unrecognised.k9"
expect_failure 'unknown YAML file' 'Missing K9! magic number'
rm "$fixture_root/unrecognised.k9"

# A recognised name alone cannot exempt an incomplete binding.
cp "$fixture_root/coordination.k9" "$fixture_root/original.txt"
sed '/^signals:/d' "$fixture_root/original.txt" > "$fixture_root/coordination.k9"
expect_failure 'incomplete session binding' 'Missing K9! magic number'
mv "$fixture_root/original.txt" "$fixture_root/coordination.k9"

# A SVC component at a session path must still be checked as SVC.
cp "$fixture_root/coordination.k9" "$fixture_root/original.txt"
{
    printf 'K9!\n'
    cat "$fixture_root/original.txt"
} > "$fixture_root/coordination.k9"
expect_failure 'SVC without pedigree at session path' 'Missing pedigree block'
mv "$fixture_root/original.txt" "$fixture_root/coordination.k9"

# Existing SVC guarantees remain enforced.
cp "$fixture_root/component.k9" "$fixture_root/original.txt"
sed '1d' "$fixture_root/original.txt" > "$fixture_root/component.k9"
expect_failure 'missing SVC header' 'Missing K9! magic number'
cp "$fixture_root/original.txt" "$fixture_root/component.k9"
sed '/name =/d' "$fixture_root/original.txt" > "$fixture_root/component.k9"
expect_failure 'missing pedigree identity' "Pedigree block missing 'name' field"
sed "s/leash = 'Kennel/leash = 'Invalid/" "$fixture_root/original.txt" > "$fixture_root/component.k9"
expect_failure 'invalid security level' 'Invalid security level'
sed "s/leash = 'Kennel/leash = 'Hunt/" "$fixture_root/original.txt" > "$fixture_root/component.k9"
expect_failure 'unsigned Hunt component' "Hunt-level K9 file must include a 'signature'"

# The repository's real Nickel components also pass strict metadata checks.
INPUT_PATH="$repo_root" INPUT_STRICT=true \
    bash "$repo_root/.github/hooks/validate-k9.sh" > "$fixture_root/result.log"
echo 'PASS: K9 schema dispatch and security regressions'
