// Regression test for the cross-depth erased-fork SIGSEGV (the "fork-eff" pattern):
// a thunk whose real effect row is <tick,console,div> is erased to `() -> <div> ()`
// via a no-op effect cast, stored in a global ref queue from a context WITHOUT a
// tick handler (create shallow), and invoked later under a freshly installed tick
// handler (run deep) via `unsafe-reopen` (std/core/unsafe).
//
// Previously: the invocation compiled to an `open-none` wrapper that cleared the
// evidence vector, the erased thunk's dynamic `evv-index` lookup returned a garbage
// insertion-point index, and `evv-at` read out of bounds -> SIGSEGV before the
// thunk body ran. Now: `unsafe-reopen` keeps the evidence vector so the thunk
// resolves the live handler dynamically, and a missing handler is a clean
// "no handler found for effect" fatal error instead of memory corruption.

import std/core/unsafe

effect tick
  ctl tick(tag : string) : int

// the no-op effect-row cast (as used by fork-style APIs)
inline extern cast-thunk-total<e>(t : () -> e ()) : (() -> <div> ())
  inline "#1"

val ready : ref<global, list<() -> <div> ()>> = unsafe-total { ref([]) }

fun fork-eff(thunk : () -> e ()) : ()
  unsafe-total { ready := Cons(cast-thunk-total(thunk), !ready) }

fun ready-pop() : maybe<() -> <div> ()>
  unsafe-total
    match !ready
      Nil           -> Nothing
      Cons(t, rest) -> { ready := rest; Just(t) }

fun fiber() : <tick,console,div> ()
  println("fiber: enter")
  val r = tick("op")
  println("fiber: got " ++ r.show)

fun with-tick(body : () -> <tick,console,div|e> ()) : <console,div|e> ()
  with handler
    raw ctl tick(tag)
      println("handler: " ++ tag)
      rcontext.resume(42)
  body()

fun drain() : <tick,console,div> ()
  match ready-pop()
    Just(t) -> { unsafe-reopen(t); drain() }
    Nothing -> ()

fun main()
  // create the erased thunk in a SHALLOW context (no tick handler installed)
  fork-eff(fn() fiber())
  // run it in a DEEP context (under a freshly installed tick handler)
  with-tick
    drain()
  println("done")
