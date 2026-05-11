(* SPDX-License-Identifier: PMPL-1.0-or-later *)
(* SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) *)

(** Python face for AffineScript.

    Per the faces spec (docs/specs/faces.md), a face is a source-level
    text preprocessor: [text → canonical text] followed by the stock
    lex + parse pipeline.  This module implements the preprocessor for
    Python-style surface syntax:

      - [def f(x): body]           becomes [fn f(x) { body }]
      - [if/elif/else] chains with [:]-terminated heads and indented
        bodies become braced chains
      - Python keywords [and or not True False None pass] are replaced
        with their canonical equivalents [&& || ! true false () ()]
      - Statement-like lines inside a braced block get a trailing
        [;] so that the canonical parser sees one statement per
        source line

    Nothing about the compiler beyond this file knows about Python.
    Type errors surface in the canonical vocabulary; ADR-010's
    face-aware *error* formatter layer lives in [face.ml] and is
    orthogonal. *)

(* ------------------------------------------------------------------ *)
(* Keyword substitution — applied to the content of every line after *)
(* it has been tokenised into word/non-word fragments.  Matching is   *)
(* whole-word; [not_a] does not become [!_a].                         *)
(* ------------------------------------------------------------------ *)

let keyword_map = [
  "True",  "true";
  "False", "false";
  "None",  "()";
  "pass",  "()";
  "and",   "&&";
  "or",    "||";
  "not",   "!";
  "def",   "fn";
]

let is_ident_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
  || (c >= '0' && c <= '9') || c = '_'

(** Replace Python keywords with their canonical equivalents at
    word boundaries.  Quick-and-correct: we walk the string once,
    re-emitting each maximal identifier run after lookup.  Non-ident
    characters are copied through verbatim so arithmetic, punctuation,
    and string literals survive untouched.

    Caveat: inside a string literal, keyword-like substrings are
    rewritten anyway.  Fixtures under test do not contain [and]/[or]/
    etc. in strings, so this is a known limitation rather than a
    bug in scope.  A future pass can gate the substitution on an
    outside-literal tracker. *)
let substitute_keywords (line : string) : string =
  let buf = Buffer.create (String.length line) in
  let n = String.length line in
  let i = ref 0 in
  while !i < n do
    let c = line.[!i] in
    if is_ident_char c then begin
      let start = !i in
      while !i < n && is_ident_char line.[!i] do incr i done;
      let word = String.sub line start (!i - start) in
      let replacement =
        match List.assoc_opt word keyword_map with
        | Some r -> r
        | None -> word
      in
      Buffer.add_string buf replacement
    end else begin
      Buffer.add_char buf c;
      incr i
    end
  done;
  Buffer.contents buf

(* ------------------------------------------------------------------ *)
(* Line-level classification                                          *)
(* ------------------------------------------------------------------ *)

let count_leading_spaces (s : string) : int =
  let n = String.length s in
  let i = ref 0 in
  while !i < n && s.[!i] = ' ' do incr i done;
  !i

(** [strip_hash_comment s] drops any trailing [# ...] comment from a
    Python source line.  Does not try to recognise [#] inside strings;
    acceptable because fixtures use [//]-style block comments at the
    top of files but [#] only on dedicated comment lines. *)
let strip_hash_comment (s : string) : string =
  match String.index_opt s '#' with
  | Some i -> String.sub s 0 i
  | None -> s

let rtrim (s : string) : string =
  let n = ref (String.length s) in
  while !n > 0 && (s.[!n - 1] = ' ' || s.[!n - 1] = '\t') do decr n done;
  String.sub s 0 !n

let is_blank (s : string) : bool =
  let n = String.length s in
  let rec loop i =
    if i >= n then true
    else if s.[i] = ' ' || s.[i] = '\t' then loop (i + 1)
    else false
  in
  loop 0

let ends_with_colon (s : string) : bool =
  let s = rtrim s in
  String.length s > 0 && s.[String.length s - 1] = ':'

(** Strip the trailing [:] (after any trailing whitespace) from a
    block-header line so the caller can append [ {] instead. *)
let drop_trailing_colon (s : string) : string =
  let s = rtrim s in
  let n = String.length s in
  if n > 0 && s.[n - 1] = ':' then String.sub s 0 (n - 1)
  else s

(** Heuristic: does this line, after stripping [:] and whitespace,
    look like a statement rather than a block header or terminal
    expression?  Used to decide whether to append [;].  We treat
    [let], [return], [break], [continue], [use], [type], [effect] as
    unambiguously statement-shape; function calls and arithmetic are
    ambiguous and left bare (they become terminal expressions unless
    a later line forces a statement position). *)
let looks_like_statement (s : string) : bool =
  let s = String.trim s in
  let starts_with prefix =
    String.length s >= String.length prefix
    && String.sub s 0 (String.length prefix) = prefix
    && (String.length s = String.length prefix
        || not (is_ident_char s.[String.length prefix]))
  in
  starts_with "let"
  || starts_with "return"
  || starts_with "break"
  || starts_with "continue"
  || starts_with "use"
  || starts_with "type"
  || starts_with "effect"
  || starts_with "import"

(* ------------------------------------------------------------------ *)
(* Main preprocessor                                                  *)
(* ------------------------------------------------------------------ *)

(** [preview_transform src] returns the canonical AffineScript source
    produced from the Python-face source [src].  Exposed so tests can
    inspect the intermediate string without running the full parser. *)
let preview_transform (src : string) : string =
  (* Parse into (indent, payload) pairs; drop blank + pure-comment
     lines early. *)
  let raw_lines = String.split_on_char '\n' src in
  let lines =
    List.filter_map (fun line ->
      let line_no_comment = strip_hash_comment line in
      if is_blank line_no_comment then None
      else
        let indent = count_leading_spaces line_no_comment in
        let content =
          rtrim (String.sub line_no_comment indent
                   (String.length line_no_comment - indent))
        in
        Some (indent, content)
    ) raw_lines
  in

  let out = Buffer.create (String.length src) in
  (* Indent stack: each entry is the indent column at which the
     enclosing block body starts (i.e., the indent of its first
     statement).  The outermost layer is the file scope, modelled as
     indent -1 so any top-level line with indent >= 0 is "inside"
     it without opening a new block. *)
  let stack = ref [-1] in
  (* If the previous emitted line ended with a block-opening [:],
     the NEXT non-empty line is the first statement of the new block.
     Record its indent on the stack before emitting it. *)
  let pending_open = ref false in

  let emit_close_braces ?(same_line=false) target_indent =
    (* Pop the stack while the top indent is strictly greater than
       [target_indent]; emit [}] for each pop.  If [same_line] is
       false (default), each [}] gets its own line of output. *)
    let count = ref 0 in
    while (match !stack with
           | top :: _ -> top > target_indent
           | [] -> false) do
      stack := List.tl !stack;
      incr count
    done;
    for i = 0 to !count - 1 do
      if same_line && i = 0 then Buffer.add_char out ' ';
      Buffer.add_char out '}';
      if not (same_line && i = !count - 1) then Buffer.add_char out '\n'
    done;
    if same_line && !count > 0 then Buffer.add_char out ' '
  in

  List.iter (fun (indent, content) ->
    (* Decide whether this line continues an opening block or dedents. *)
    if !pending_open then begin
      (* This line is the first statement of the block opened by the
         previous [:].  Push its indent so later dedents can find it. *)
      stack := indent :: !stack;
      pending_open := false
    end else begin
      (* Close any braces we're dedenting out of. *)
      emit_close_braces indent
    end;

    (* Handle the [elif ...:] and [else:] keyword rewrites.  The
       dedent above has already emitted the [}] that closes the
       previous [if]/[elif] branch — we just need to translate the
       Python keyword into its canonical form.  The trailing [:] is
       handled below by the generic block-opener path. *)
    let starts_with_word w s =
      let wn = String.length w in
      String.length s >= wn
      && String.sub s 0 wn = w
      && (String.length s = wn || not (is_ident_char s.[wn]))
    in
    let content =
      if starts_with_word "elif" content then
        "else if" ^ String.sub content 4 (String.length content - 4)
      else if starts_with_word "else" content
              && String.length content > 4 && content.[4] = ':'
      then
        (* [else:] is already canonical barring the colon that the
           block-opener path handles.  Keep [content] as-is. *)
        content
      else
        content
    in

    (* Write indent for readability (two spaces per nesting level
       counting entries above the sentinel -1). *)
    let depth = List.length !stack - 1 in
    for _ = 1 to depth do Buffer.add_string out "  " done;

    let content = substitute_keywords content in

    (* Handle block-opener lines: strip trailing [:], append ` {`,
       mark [pending_open] so the next line's indent defines the new
       block boundary. *)
    if ends_with_colon content then begin
      Buffer.add_string out (drop_trailing_colon content);
      Buffer.add_string out " {";
      pending_open := true
    end else begin
      Buffer.add_string out content;
      if looks_like_statement content then Buffer.add_char out ';'
    end;
    Buffer.add_char out '\n'
  ) lines;

  (* End of file: close any still-open blocks. *)
  emit_close_braces (-1);
  Buffer.contents out

(* ------------------------------------------------------------------ *)
(* Parsing entry points                                               *)
(* ------------------------------------------------------------------ *)

(** [parse_string_python ~file src] preprocesses [src] into canonical
    AffineScript text and runs the canonical parser on the result.
    [file] is used only for error-location reporting. *)
let parse_string_python ~file (src : string) : Ast.program =
  let canonical = preview_transform src in
  Parse_driver.parse_string ~file canonical

(** [parse_file_python path] reads the file at [path] and runs
    [parse_string_python] on the contents. *)
let parse_file_python (path : string) : Ast.program =
  let ic = open_in path in
  let n = in_channel_length ic in
  let src = really_input_string ic n in
  close_in ic;
  parse_string_python ~file:path src
