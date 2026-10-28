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

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_sync`, version 0.1.0
(`mopm.toml`). The library is `src/komira_sync/` (`spin_mutex.mojo` and the `__init__.mojo` that re-exports
`SpinMutex`), its test is `tests/`. The package depends on `komira_atomic_alias`, a sibling package named under
`[dependencies]` of `mopm.toml`, and has no native archive and no C shim. Its test forks real threads with
`komira_fork_join`, a sibling named under `[dev-dependencies]`: it is locked and built for the test, and is not part of
the packed package. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependency, the dev-dependency and where the library and its test are |
| `mopm.lock` | the toolchain pins and the path packages of the closure (`komira_atomic_alias`, and `komira_fork_join` with its own dependency), as `mopm lock` writes them (no registry is reached: they are siblings) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once the test has passed. After any change to a source, the test, a manifest
of this package or of a sibling, run `buildrules mojo sync` with the packages staged, commit what it writes, and build
`komira//src/komira_sync:lib` on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_sync-0.1.0-mojo1.0.0_0.conda`), which records one dependency beyond the compiler,
`mojo-komira_atomic_alias >=0.1,<0.2` (`:conda_holds` reads that back, so a dev-dependency that leaked into the package
turns it red). Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build
action.

`:komira_sync` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`), with `deps` naming
`komira_atomic_alias`. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the
test is not run again.
