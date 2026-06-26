// Verify the kk_bytes_join_with element-leak fix (2026-06-26).
// Joins a list of FRESHLY-ALLOCATED strings (refcount 1) in a tight loop.
// Before the fix each element string leaked (+2 refcount/elem, never reaching 0):
//   RSS climbed ~76 B/iter -> ~152 MiB at 2,000,000 iters (journal row K).
// After the fix the elements are borrowed and freed by kk_vector_drop(v),
// so RSS stays flat regardless of iteration count.
import std/core/list
import std/core/string

pub fun main() : <console,div> ()
  // correctness: literals (stuck refcount) and fresh strings must both join right
  println(["a","bb","ccc"].join("-"))                              // expect: a-bb-ccc
  println(Cons(1.show, Cons(2.show, Cons(3.show, Nil))).join(",")) // expect: 1,2,3
  // leak probe: 2,000,000 joins of fresh strings, result consumed and dropped
  var i := 0
  var acc := 0
  while { i < 2000000 }
    val xs = Cons(1.show, Cons(2.show, Cons(3.show, Cons(4.show, Cons(5.show, Nil)))))
    val s  = xs.join(",")
    acc := acc + s.count
    i := i + 1
  println("done acc=" ++ acc.show)
