(* SPDX-License-Identifier: PMPL-1.0-or-later *)
(* SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) *)

(** face.mli — face selection, detection, and error-vocabulary.

    See face.ml for the ADR-010 / docs/specs/faces.md context.  The
    compiler is face-agnostic; the two face-aware layers are the
    source preprocessors (e.g. [Python_face.parse_string_python]) and
    this module's error vocabulary. *)

type face =
  | Python
  | Pseudocode
  | JavaScript
  | Canonical

(** [face_error_vocab face] returns [(display_name, short_tag)] for
    the given face.  Example: [Python -> ("Python", "rattle")]. *)
val face_error_vocab : face -> string * string

(** [detect_face filename] guesses the face from the filename's
    extension: [.pyaff]/[.rattle] -> Python, [.pseudo]/[.pseudoaff]
    -> Pseudocode, [.jaffa]/[.jsaff] -> JavaScript, anything else ->
    Canonical. *)
val detect_face : string -> face
