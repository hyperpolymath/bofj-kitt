# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# FORMAL VERIFICATION (PROOFS)
#
# Imported by ../../Justfile via `import? "build/just/proofs.just"`.
# The recipes call scripts/proof-check.sh, which follows the estate
# PROOF-POLICY (metadatastician/standards, 3-practice/PROOF-POLICY.adoc):
# Agda runs with the canonical `--safe --without-K --cubical-compatible`
# invocation (§2.1), and a missing checker is reported UNAVAILABLE and fails
# the run instead of passing (exit 3). Set AGDA_STDLIB to the standard
# library's source directory if it is not a registered Agda library.
#
# The proof files here are RSR template material, not obligations of this
# repository; docs/status/PROOF-STATUS.adoc records their status.

# Check every proof file and scan for escape hatches
proof-check-all:
    scripts/proof-check.sh all

# Check Idris2 proofs
proof-check-idris2:
    scripts/proof-check.sh idris2

# Check Lean 4 proofs
proof-check-lean4:
    scripts/proof-check.sh lean4

# Check Agda proofs (PROOF-POLICY §2.1 invocation)
proof-check-agda:
    scripts/proof-check.sh agda

# Check Coq (Rocq) proofs
proof-check-coq:
    scripts/proof-check.sh coq

# Scan proof code (comments and strings ignored) for escape hatches
proof-scan-dangerous:
    scripts/proof-check.sh scan

# Show the proof ledger summary
proof-status:
    @sed -n '/^== Ledger/,/^== /p' docs/status/PROOF-STATUS.adoc | sed '$d'
