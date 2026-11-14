#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Ported from rsr-template-repo. validate-deed.sh is deliberately absent (see docs/status/ROADMAP.adoc, M1); pre-push skips it with a notice.
# Point this clone's git hooks at .github/hooks/ so the local Dogfood Gate runs
# on push. Idempotent; safe to re-run.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .github/hooks
chmod +x .github/hooks/pre-push .github/hooks/validate-k9.sh .github/hooks/scan-secrets.sh 2>/dev/null || true
echo "Installed: core.hooksPath -> .github/hooks (pre-push K9 + secret gate active)."
