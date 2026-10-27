#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Regression tests for K9-SVC validation and session-binding compatibility.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Exercise the real hook in an isolated repository, including its two
# repository-relative session bindings. No Nickel evaluation is needed.
mkdir -p "$TEST_ROOT/repo/.github/hooks" "$TEST_ROOT/repo/session" "$TEST_ROOT/scan"
cp "$REPO_ROOT/.github/hooks/validate-k9.sh" "$TEST_ROOT/repo/.github/hooks/"
cp "$REPO_ROOT/coordination.k9" "$TEST_ROOT/repo/"
cp "$REPO_ROOT/session/custom-checks.k9" "$TEST_ROOT/repo/session/"
VALIDATOR="$TEST_ROOT/repo/.github/hooks/validate-k9.sh"
export INPUT_PATHS_IGNORE="" INPUT_STRICT=false
export GITHUB_OUTPUT="$TEST_ROOT/output"

expect_status() {
    local label="$1" expected="$2" actual=0
    shift 2
    "$@" > "$TEST_ROOT/log" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        cat "$TEST_ROOT/log" >&2
        echo "FAIL: $label (expected exit $expected, got $actual)" >&2
        exit 1
    fi
    echo "PASS: $label"
}

expect_log() {
    if ! grep -Fq "$1" "$TEST_ROOT/log"; then
        cat "$TEST_ROOT/log" >&2
        echo "FAIL: expected diagnostic: $1" >&2
        exit 1
    fi
}

cat > "$TEST_ROOT/valid.k9" <<'EOF'
K9!
# SPDX-License-Identifier: MPL-2.0
{
  pedigree = {
    schema_version = "1.0.0",
    security = {
      leash = 'Kennel,
    },
    metadata = {
      name = "test-component",
      version = "1.0.0",
    },
  },
}
EOF

# Resolve exemptions against the hook's repository, regardless of cwd or
# whether INPUT_PATH is relative, absolute, a subdirectory, or a single file.
cd "$TEST_ROOT/repo"
expect_status "session YAML bindings retain their format" 0 bash "$VALIDATOR"
expect_log "Excluded 2 session-management binding(s)"
expect_log "No K9 files found"
cd "$TEST_ROOT"
expect_status "absolute scan from another directory" 0 env INPUT_PATH="$TEST_ROOT/repo" INPUT_STRICT=true bash "$VALIDATOR"
expect_log "Excluded 2 session-management binding(s)"
expect_status "session subdirectory scan" 0 env INPUT_PATH=repo/session bash "$VALIDATOR"
expect_log "Excluded 1 session-management binding(s)"
expect_status "single binding scan" 0 env INPUT_PATH=repo/coordination.k9 bash "$VALIDATOR"
expect_log "Excluded 1 session-management binding(s)"

# Only the two actual session files are exempt. Namesakes elsewhere remain
# subject to normal K9-SVC checks, including when scanned outside the repo.
cp "$TEST_ROOT/repo/coordination.k9" "$TEST_ROOT/scan/coordination.k9"
expect_status "unrelated coordination.k9 is validated" 1 env INPUT_PATH=scan bash "$VALIDATOR"
expect_log "Missing K9! magic number"
mv "$TEST_ROOT/scan/coordination.k9" "$TEST_ROOT/scan/custom-checks.k9"
expect_status "unrelated custom-checks.k9 is validated" 1 env INPUT_PATH=scan bash "$VALIDATOR"
expect_log "Missing pedigree block"
rm "$TEST_ROOT/scan/custom-checks.k9"

cp "$TEST_ROOT/valid.k9" "$TEST_ROOT/scan/component.k9"
expect_status "nested metadata is accepted in strict mode" 0 env INPUT_PATH=scan INPUT_STRICT=true bash "$VALIDATOR"
expect_log "Files scanned: 1"

tail -n +2 "$TEST_ROOT/valid.k9" > "$TEST_ROOT/scan/component.k9"
expect_status "missing component marker still fails" 1 env INPUT_PATH=scan bash "$VALIDATOR"
expect_log "Missing K9! magic number"

printf 'K9!\n# SPDX-License-Identifier: MPL-2.0\n{}\n' > "$TEST_ROOT/scan/component.k9"
expect_status "missing component pedigree still fails" 1 env INPUT_PATH=scan bash "$VALIDATOR"
expect_log "Missing pedigree block"

sed '/name =/d' "$TEST_ROOT/valid.k9" > "$TEST_ROOT/scan/component.k9"
expect_status "missing pedigree name still fails" 1 env INPUT_PATH=scan bash "$VALIDATOR"
expect_log "Pedigree block missing 'name'"

sed "s/'Kennel/'Invalid/" "$TEST_ROOT/valid.k9" > "$TEST_ROOT/scan/component.k9"
expect_status "invalid security level still fails" 1 env INPUT_PATH=scan bash "$VALIDATOR"
expect_log "Invalid security level"

sed "s/'Kennel/'Hunt/" "$TEST_ROOT/valid.k9" > "$TEST_ROOT/scan/component.k9"
expect_status "Hunt without signature declaration still fails" 1 env INPUT_PATH=scan bash "$VALIDATOR"
expect_log "Hunt-level K9 file must include"
sed -i '/leash =/a\      signature_required = true,' "$TEST_ROOT/scan/component.k9"
expect_status "Hunt with signature requirement is accepted" 0 env INPUT_PATH=scan INPUT_STRICT=true bash "$VALIDATOR"

sed '/SPDX-License-Identifier/d' "$TEST_ROOT/valid.k9" > "$TEST_ROOT/scan/component.k9"
expect_status "non-strict warning remains advisory" 0 env INPUT_PATH=scan bash "$VALIDATOR"
expect_log "Missing SPDX-License-Identifier"
expect_status "strict mode still promotes warnings" 1 env INPUT_PATH=scan INPUT_STRICT=true bash "$VALIDATOR"

expect_status "explicit paths-ignore remains supported" 0 env INPUT_PATH=scan INPUT_STRICT=true INPUT_PATHS_IGNORE=component.k9 bash "$VALIDATOR"
expect_log "Skipped 1 file(s) matching paths-ignore"

echo "K9 validation regression tests passed."
