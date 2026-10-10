# komira_fork_join

Run one body on `n` real threads and wait for all of them.

`fork_join(body, n)` starts `n` threads; thread `tid` (`0` to `n - 1`, each
exactly once) calls `body.run(tid)`. It returns only after every thread has
exited. `n == 0` runs nothing; a negative `n` raises.

`body` is borrowed, not copied, and all `n` threads share it at once, so
`run` takes `self` immutably. State the threads change lives behind atomics,
or in per-thread cells, that the body points to.

Failure rules:

- every thread that started is joined before anything is raised;
- if bodies raise, `fork_join` raises the error of the lowest `tid` that
  failed, with `(<k> of <n> workers failed)` appended when more than one did;
- if a thread cannot be started after `k` have been, those `k` are joined and
  `fork_join` raises, naming how many of the `n` started.

The threads are POSIX threads; the bindings live in one private module,
`_pthread.mojo`. The first example uses `AtomicI64` from
`komira_atomic_alias`, which this package depends on.

Every example below runs as a test when the package is built, so it cannot
go stale.

## Summing across threads

The body holds a `Pointer` to an atomic the caller owns. The borrow checker
keeps the atomic alive for the whole call.

```mojo module
from komira_atomic_alias import AtomicI64
from komira_fork_join import ForkJoinBody, fork_join
from std.memory import Pointer
from std.testing import assert_equal


struct SumOfTids[o: MutOrigin](ForkJoinBody):
    var total: Pointer[AtomicI64, Self.o]

    def __init__(out self, total: Pointer[AtomicI64, Self.o]):
        self.total = total

    def run(self, tid: Int) raises:
        _ = self.total[].fetch_add(Int64(tid))


def main() raises:
    var total = AtomicI64(Int64(0))
    var body = SumOfTids(Pointer(to=total))
    fork_join(body, 8)
    assert_equal(total.load(), Int64(0 + 1 + 2 + 3 + 4 + 5 + 6 + 7))

    fork_join(body, 0)  # runs nothing
    assert_equal(total.load(), Int64(28))
```

## When bodies raise

Every thread still runs to the end; the lowest failing `tid` names the
error.

```mojo module
from komira_fork_join import ForkJoinBody, fork_join
from std.testing import assert_equal


struct FailFrom(ForkJoinBody):
    var first_failing_tid: Int

    def __init__(out self, first_failing_tid: Int):
        self.first_failing_tid = first_failing_tid

    def run(self, tid: Int) raises:
        if tid >= self.first_failing_tid:
            raise Error("tid " + String(tid) + " failed")


def main() raises:
    var two_fail = FailFrom(2)
    var message = String()
    try:
        fork_join(two_fail, 4)  # tids 2 and 3 raise
    except e:
        message = String(e)
    assert_equal(message, "tid 2 failed (2 of 4 workers failed)")

    var one_fails = FailFrom(3)
    try:
        fork_join(one_fails, 4)  # only tid 3 raises
    except e:
        message = String(e)
    assert_equal(message, "tid 3 failed")

    try:
        fork_join(one_fails, -1)
    except e:
        message = String(e)
    assert_equal(message, "fork_join: n must be >= 0, got -1")
```
