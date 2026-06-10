// Variant 2: dispatcher-style intermediary.
//
// Adds a `cont` alias and a delivery function that wraps the stored
// thunk in `unsafe-total` before invoking — matches OneHR's
// `interp/dispatcher.kk:deliver-result`'s pattern of
//   `match take(pending, cid) { Just(k) -> unsafe-total { k(r) } }`.
//
// FINDING: this variant does NOT crash, but the resume SILENTLY
// NO-OPS — after `dispatcher: k returned`, body1's "op #1 = 42"
// is never printed. The `unsafe-total { rcontext.resume(v) }`
// wrap (which is type-system-FORCED because raw-ctl bodies must
// be total) is swallowing the resume's effects, so the
// continuation's re-entry into body1 doesn't actually happen.
//
// This matches OneHR's symptom:
//   - The brain handshakes, calls time.now-ms, file.append, prints
//     "journal append done". That's all from BEFORE the first park.
//   - After step-result delivers the Result for c-2 (file.append),
//     the parked continuation runs under `unsafe-total { k(r) }`.
//   - body1's post-append code (next val now0 = now-ms()) NEVER
//     executes — same silent-no-op pattern.
//   - When the silent no-op is followed by un-popped handler frames
//     on the C stack, the SIGSEGV manifests; when it isn't, the
//     brain exits cleanly with code 0.
//
// Fix paths:
//   1. Avoid the `raw ctl` / unsafe-total pattern entirely.
//      Use `ctl` and resume synchronously inside the handler.
//      But that requires the handler to block (read the wire
//      result) before returning, which means switching to a
//      single-threaded synchronous model.
//   2. Use a Koka version that doesn't have this issue (if any).
//   3. File upstream and wait.

module dispatcher_style

import std/core/list
import std/core/string
import std/core/console
import std/core/unsafe

pub effect syscall
  ctl op() : int

pub alias cont = (int) -> ()

// Storage shaped like OneHR's `pending : list<(string, cont)>`.
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
  println("=== variant 2: dispatcher-style intermediary ===")
  with-A fn() body1()
  println("--- after A ---")
  deliver-step()
  println("=== end ===")
