// Variant 3: dispatcher-style intermediary, FIXED by a non-total stored type.
//
// This is `dispatcher_style.kk` with exactly ONE change: the stored
// continuation alias carries a `<div>` effect row instead of being total:
//
//     pub alias cont = (int) -> <div> ()       // was: (int) -> ()
//
// Everything else is identical to the failing variant 2 -- including the
// type-system-FORCED `unsafe-total { rcontext.resume(v) }` inside the raw
// ctl body, and the `unsafe-total { k(v) }` at the delivery site.
//
// HYPOTHESIS (from docs/.../unsafe-total-resume-dce journal, section 3):
// the DCE fires only when the *callee's declared type* at the delivery
// site is total. `unbox(k)` inherits `k`'s declared type; making that type
// `(int) -> <div> ()` means `hasTotalEffect` is False, so the simplifier
// keeps the `(unbox(k))(v)` call. The outer `unsafe-total { k(v) }` only
// erases the *thunk's* effect, not `k`'s, so it does not re-arm the DCE.
//
// EXPECTED (post-fix, stock Koka 3.2.3): prints
//     dispatcher: k returned
//     body1: op #1 = 42
//     body1: op #2 (suspect)
// i.e. the parked resume actually re-enters body1 -- the lines that the
// total-typed variant 2 silently dropped.
//
// This validates the OneHR brain fix WITHOUT a compiler patch: we ship on
// stock nixpkgs koka 3.2.3 and keep the effect row honest at storage time.

module dispatcher_style_div

import std/core/list
import std/core/string
import std/core/console
import std/core/unsafe

pub effect syscall
  ctl op() : int

// THE FIX: non-total stored type. Compare dispatcher_style.kk: `(int) -> ()`.
pub alias cont = (int) -> <div> ()

val pending : ref<global, maybe<cont>> =
  unsafe-total { ref(Nothing) }

fun park(k : cont) : ()
  unsafe-total { pending := Just(k) }

fun take-pending() : maybe<cont>
  unsafe-total
    val cur = !pending
    pending := Nothing
    cur

fun deliver(v : int) : <console,div> ()
  match take-pending()
    Just(k) ->
      println("dispatcher: invoking parked k(" ++ v.show ++ ")")
      unsafe-total { k(v) }
      println("dispatcher: k returned")
    Nothing ->
      println("dispatcher: nothing parked")

fun with-A(body : () -> <syscall,console,div|e> ()) : <console,div|e> ()
  println("A: install")
  with handler
    raw ctl op()
      println("A: parking via dispatcher (NO unsafe-total around resume)")
      park(fn(v) unsafe-total { rcontext.resume(v) })   // typecheck-forced
  body()
  println("A: body returned")

fun with-B(body : () -> <syscall,console,div|e> ()) : <console,div|e> ()
  println("B: install")
  with handler
    ctl op()
      println("B: resume immediately with 99")
      resume(99)
  body()

fun deliver-step() : <console,div> ()
  with-B fn()
    deliver(42)

fun body1() : <syscall,console,div> ()
  println("body1: op #1")
  val v = op()
  println("body1: op #1 = " ++ v.show)
  println("body1: op #2 (suspect)")
  val w = op()
  println("body1: op #2 = " ++ w.show)

pub fun main()
  println("=== variant 3: dispatcher-style, non-total stored type ===")
  with-A fn() body1()
  println("--- after A ---")
  deliver-step()
  println("=== end ===")
