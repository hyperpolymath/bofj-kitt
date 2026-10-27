; SPDX-License-Identifier: MPL-2.0
(in-package "ACL2")

; LD returns a proof error instead of continuing to a successful exit.
(mv-let (erp val state)
  (ld '((defthm bofj-smoke-reflexivity (equal x x) :rule-classes nil))
      :ld-error-action :return)
  (mv (good-bye (if (and (not erp) (eq val :eof)) 0 1)) state))
