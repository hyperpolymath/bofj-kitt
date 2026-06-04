// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
// Playground runtime shim for js_of_ocaml.
//
// Provides a browser-safe stub for `caml_unix_putenv` so the js_of_ocaml
// link step does not emit a "missing primitive" warning and does not
// generate a stub that raises at runtime on first touch.  The Unix
// module is pulled in transitively via `affinescript/lib/interp.ml`
// (filesystem / env builtins); of its calls, only `Unix.putenv` lacks
// a js_of_ocaml runtime implementation in the default `+unix.js`.
//
// Browsers have no process environment, so the closest sensible
// behaviour is a no-op: the call returns unit without raising.  The
// playground driver (js/playground.ml) never calls `Unix.putenv`, so
// this shim is defensive — it keeps linking quiet and guarantees that
// if any future playground path reaches `Unix.putenv` it degrades to
// a silent no-op instead of surfacing the jsoo stub's `Failure`.

//Provides: caml_unix_putenv
function caml_unix_putenv(_name, _value) {
  return 0;
}
