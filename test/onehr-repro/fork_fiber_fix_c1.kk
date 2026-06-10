// Minimal repro: per-connection FORK fiber crashes when invoked at a handler
// depth different from where its (cast-thunk-total) closure was created.
//
// Mirrors the brain's TLS-accept path (docs/koka-repros/TLS_ACCEPT_SIGSEGV.md):
//   * `dispatcher` is a named effect installed OUTERMOST (with-dispatcher).
//   * `syscall` (`op`) is a raw-ctl handler installed PER-STEP (with-sys),
//     INSIDE the dispatcher -- exactly like the real with-syscall.
//   * `deliver-stream` (a dispatcher op) fires a `sink` that FORKS a fiber
//     thunk (cast-thunk-total, stored in a global ready queue). The sink runs
//     in the dispatcher-op context = SHALLOW (above with-sys).
//   * `drain` runs the forked thunk under with-sys = DEEP. The thunk does an
//     `op` (= a syscall, like tls.terminate).
//
// Hypothesis: invoking the cast closure in the DEEP frame corrupts the call
// (evidence-vector mismatch) -> crash, BEFORE "[fiber] entered" prints.
// Expected good output (if no bug / once fixed):
//   [fiber] entered; about to op
//   [handler] op(terminate) park
//   [step-result] resuming fiber
//   [fiber] op returned 42
//   main: DONE

module fork_fiber_fix_c1

import std/core/list
import std/core/string
import std/core/console
import std/core/unsafe

extern eprn(s : string) : ndet ()
  c inline "do { fputs(kk_string_cbuf_borrow(#1,NULL,kk_context()), stderr); fputc('\\n', stderr); kk_string_drop(#1, kk_context()); } while(0)"

pub effect syscall
  ctl op(tag : string) : int

pub named effect dispatcher
  fun deliver-stream(v : int) : ()
  fun has-ready()             : bool

pub alias cont = (int) -> <div> ()

// ── global state (like the real dispatcher's refs) ─────────────────────────
val ready   : ref<global, list<int>> = unsafe-total { ref([]) }
val pending : ref<global, maybe<cont>>           = unsafe-total { ref(Nothing) }

fun ready-push(t : int) : ()
  unsafe-total { ready := Cons(t, !ready) }

fun ready-pop() : maybe<int>
  unsafe-total
    match !ready
      Nil           -> Nothing
      Cons(t, rest) -> { ready := rest; Just(t) }

fun park(k : cont) : ()
  unsafe-total { pending := Just(k) }

fun take-pending() : maybe<cont>
  unsafe-total
    val c = !pending
    pending := Nothing
    c

// the no-op effect-row cast the brain uses for fork thunks.
inline extern cast-thunk-total<e>(t : () -> e ()) : (() -> <div> ())
  inline "#1"

fun fork-conn(connv : int) : ()
  ready-push(connv)

// ── the per-connection fiber body: does a syscall (like tls.terminate) ─────
fun fiber-body() : <syscall,console,div,ndet> ()
  eprn("  [fiber] entered; about to op")
  val r = op("terminate")
  eprn("  [fiber] op returned " ++ r.show)

// the sink: fired by deliver-stream; forks the fiber. Runs in the dispatcher
// op context (SHALLOW), like server_default's accept-stream sink.
fun sink(v : int) : <div,ndet> ()
  fork-conn(v)

// ── dispatcher handler (OUTERMOST) ─────────────────────────────────────────
fun with-dispatcher(action : (ev<dispatcher>) -> <div|e> a) : <div|e> a
  with d <- named handler
    fun deliver-stream(v)
      unsafe-total { sink(v) }          // sink runs HERE = shallow
    fun has-ready()
      unsafe-total { (!ready).is-cons }
  action(d)

// ── with-sys: raw-ctl syscall handler, installed PER-STEP (like with-syscall)
fun with-sys(body : () -> <syscall,console,div,ndet|e> ()) : <console,div,ndet|e> ()
  with handler
    raw ctl op(tag)
      eprn("  [handler] op(" ++ tag ++ ") park")
      park(fn(r) unsafe-total { rcontext.resume(r) })
  body()

// ── steps (mirror app/main.kk) ─────────────────────────────────────────────
fun drain-ready() : <syscall,console,div,ndet> ()
  match ready-pop()
    Just(_c) -> { eprn("  [drain] calling fiber-body() directly under with-sys"); fiber-body(); drain-ready() }
    Nothing -> ()

fun drain(d : ev<dispatcher>) : <console,div,exn,ndet> ()
  with-sys fn() drain-ready()

fun step-stream(d : ev<dispatcher>, v : int) : <console,div,exn,ndet> ()
  with-sys fn() d.deliver-stream(v)

fun step-result(d : ev<dispatcher>, v : int) : <console,div,exn,ndet> ()
  with-sys fn()
    match take-pending()
      Just(k) -> { eprn("  [step-result] resuming fiber"); unsafe-total { k(v) } }
      Nothing -> eprn("  [step-result] no pending")

pub fun main() : <console,div,exn,ndet> ()
  with-dispatcher fn(d)
    eprn("main: step-stream (delivers conn -> sink forks fiber)")
    step-stream(d, 1)
    eprn("main: drain (runs forked fiber under with-sys) -- watch for crash")
    drain(d)
    eprn("main: step-result (resume the parked fiber)")
    step-result(d, 42)
    eprn("main: DONE (no crash)")
