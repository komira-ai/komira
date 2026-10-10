# komira_sync

`SpinMutex`, a mutual-exclusion lock for plain (non-async) code, over one
atomic word: `try_lock` takes it if it is free, `lock` waits until this call
takes it, `unlock` releases it. A waiter retries with a `sched_yield` between
attempts, then sleeps in short `usleep` steps, so a holder that blocks for a
while (a network refresh) does not cost a busy core per waiter. To share it
between threads, put it behind one shared handle (an `ArcPointer`).

The lock is not reentrant (a thread that locks twice deadlocks itself), not
fair (a waiter has no place in a queue), and does not poison: a holder that
raises must unlock on every path. It guards nothing by itself; the caller
keeps the data it protects next to it.

## Examples

A held lock is not taken again until it is released:

<!-- mojo-hidden from std.testing import assert_true, assert_false -->
```mojo
from komira_sync import SpinMutex

var m = SpinMutex()
assert_true(m.try_lock())   # free: this call takes it
assert_false(m.try_lock())  # held: refused, without waiting
m.unlock()
assert_true(m.try_lock())   # free again
m.unlock()
```

A critical section that may raise unlocks on every path:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_sync import SpinMutex

def bump(mut m: SpinMutex, mut counter: Int, fail: Bool) raises:
    m.lock()
    try:
        counter += 1
        if fail:
            raise Error("refresh failed")
    finally:
        m.unlock()

var m = SpinMutex()
var counter = 0
bump(m, counter, False)
try:
    bump(m, counter, True)
except e:
    assert_equal(String(e), "refresh failed")
assert_equal(counter, 2)
assert_true(m.try_lock())  # the raising call did not leave it held
m.unlock()
```
