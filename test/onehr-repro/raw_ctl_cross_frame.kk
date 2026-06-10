// Minimal Koka 3.2.3 repro for the OneHR brain SIGSEGV investigation.
//
// What it does:
//   1. Install handler A with `raw ctl op` that parks its continuation
//      in a global var instead of resuming.
//   2. Call op from inside A — A parks; A's body returns.
//   3. Install fresh handler B with `ctl op` that resumes with 99.
//   4. From inside B, take the parked continuation and invoke it.
//   5. The resumed continuation calls op a SECOND time.
//
// Expected if the OneHR "dead-frame handler search" hypothesis were
// general: the 2nd op call dereferences A's dead handler frame and
// crashes / mis-routes.
//
// Actual result (Koka 3.2.3 on aarch64-darwin):
//   The 2nd op call routes back to handler A (the old handler), not
//   to B. A's raw ctl fires and parks a 2nd time. Then control
//   unwinds back to the deliver function. No crash.
//
// What this tells us:
//   - Koka's handler closures persist after the lexical scope ends,
//     at least in the simple raw-ctl + cross-frame case.
//   - The OneHR brain SIGSEGV is NOT the simple cross-frame resume
//     pattern. It must be triggered by something specific to the
//     OneHR handler stack — likely the `unsafe-total` wrap inside
//     `with-time-syscall`'s raw ctl combined with how step-result
//     installs its own copy of the syscall handlers.
//
// Build:  koka --target=c -o repro raw_ctl_cross_frame.kk
// Run:    ./repro

module raw_ctl_cross_frame

import std/core/list
import std/core/string
import std/core/console
import std/core/unsafe

pub effect syscall
  ctl op() : int

val parked-state : ref<global, maybe<() -> ()>> =
  unsafe-total { ref(Nothing) }

fun put-parked(t : () -> ()) : ()
  unsafe-total { parked-state := Just(t) }

fun take-parked() : maybe<() -> ()>
  unsafe-total
    val v = !parked-state
    parked-state := Nothing
    v

fun with-A(body : () -> <syscall,console,div|e> ()) : <console,div|e> ()
  println("A: install")
  with handler
    raw ctl op()
      println("A: parked")
      put-parked(fn() unsafe-total { rcontext.resume(42) })
  body()
  println("A: body returned")

fun with-B(body : () -> <syscall,console,div|e> ()) : <console,div|e> ()
  println("B: install")
  with handler
    ctl op()
      println("B: resume with 99")
      resume(99)
  body()

fun deliver() : <console,div> ()
  with-B fn()
    match take-parked()
      Just(t) ->
        println("deliver: invoking parked")
        unsafe-total { t() }
        println("deliver: invoking returned")
      Nothing ->
        println("deliver: nothing parked")

fun body1() : <syscall,console,div> ()
  println("body1: op #1")
  val v = op()
  println("body1: op #1 = " ++ v.show)
  println("body1: op #2 (suspect)")
  val w = op()
  println("body1: op #2 = " ++ w.show)

pub fun main()
  println("=== repro: raw-ctl + cross-frame resume ===")
  with-A fn() body1()
  println("--- after A ---")
  deliver()
  println("=== end ===")
