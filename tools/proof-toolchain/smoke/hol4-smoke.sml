(* SPDX-License-Identifier: MPL-2.0 *)
(* Check a kernel theorem and propagate proof failures to the caller. *)
val _ =
  ((if aconv (concl (REFL ``T``)) ``T = T`` then
      OS.Process.exit OS.Process.success
    else
      OS.Process.exit OS.Process.failure)
   handle _ => OS.Process.exit OS.Process.failure);
