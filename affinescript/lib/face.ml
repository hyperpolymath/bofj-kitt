(* SPDX-License-Identifier: PMPL-1.0-or-later *)
(* SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) *)

(** face.ml — face selection, detection, and error-vocabulary

    Per ADR-010 / docs/specs/faces.md, a *face* is an alternative
    surface presentation of AffineScript.  There are two face-aware
    layers in the compiler and this module is the second:

      1. Source preprocessor (e.g. lib/python_face.ml — text →
         canonical text), invoked by the CLI and LSP before lex+parse.
      2. Error formatter (this module) — maps canonical structured
         errors to face-specific display strings.

    The compiler proper is face-agnostic.  No face should ever touch
    the AST or the type-checker. *)

(** Available faces for the compiler's user-facing surface.

    [Canonical] is the default AffineScript surface syntax; the other
    faces are sugar layers over it.  JS and Pseudocode are listed for
    the CLI's [--face] enum but their preprocessors have not shipped
    — only the error vocabulary is face-aware. *)
type face =
  | Python
  | Pseudocode
  | JavaScript
  | Canonical

(** [face_error_vocab face] returns [(display_name, short_tag)] for
    the given face.  [display_name] appears in user-facing error
    prose ("Python syntax error"); [short_tag] appears in error codes
    and log prefixes ("[rattle]"). *)
let face_error_vocab (face : face) : string * string =
  match face with
  | Python     -> ("Python", "rattle")
  | Pseudocode -> ("Pseudocode", "pseudo")
  | JavaScript -> ("JavaScript", "jaffa")
  | Canonical  -> ("AffineScript", "affinescript")

(** [detect_face filename] guesses the face from a filename's
    extension.  Mapping matches the [--face] flag aliases documented
    in docs/specs/faces.md. *)
let detect_face (filename : string) : face =
  if Filename.check_suffix filename ".rattle"
     || Filename.check_suffix filename ".pyaff"
  then Python
  else if Filename.check_suffix filename ".pseudo"
          || Filename.check_suffix filename ".pseudoaff"
  then Pseudocode
  else if Filename.check_suffix filename ".jaffa"
          || Filename.check_suffix filename ".jsaff"
  then JavaScript
  else Canonical
