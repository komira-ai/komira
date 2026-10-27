# komira_spsc_ring

`SpscRing[T]`, one bounded single-producer / single-consumer ring of plain
data. Exactly one thread calls `try_push` and exactly one calls `try_pop` (they
may be the same thread); each cursor has one writer, published with a release
store and read with an acquire load (the full ordering argument is in the
header of `spsc_ring.mojo`). The capacity is rounded up to a power of two.

What a push onto a full ring does is chosen at construction: under
`OVERFLOW_BLOCK` (the default) it spins until the consumer frees a slot, so
`try_push` never returns `False`; under `OVERFLOW_DROP` it returns `False`
and counts the drop. Both are counted (`overflow_dropped_count`,
`overflow_blocked_count`). By default the ring is lazy: no slot memory exists
until the first push. `T` must be trivially copyable and trivially
destructible (checked at compile time): the ring holds no `String` or `List`.
It does not grow, does not support more than one producer or consumer, and
offers no blocking pop: `try_pop` on an empty ring returns `None`.

The ring lives in the `komira_spsc_ring.spsc_ring` module.

## Examples

Records come out in push order; the capacity is a power of two:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_spsc_ring.spsc_ring import SpscRing

var ring = SpscRing[Int64](capacity=6)
assert_equal(ring.capacity(), 8)
assert_false(ring.slots_allocated())  # lazy: nothing allocated yet
assert_true(ring.try_pop() is None)

for i in range(3):
    _ = ring.try_push(Int64(i * 10))
assert_true(ring.slots_allocated())
assert_equal(ring.approximate_size(), 3)
assert_equal(ring.try_pop().value(), 0)
assert_equal(ring.try_pop().value(), 10)
assert_equal(ring.try_pop().value(), 20)
assert_true(ring.is_empty())
```

Under `OVERFLOW_DROP`, a push onto a full ring is refused and counted, and the
stored records are untouched:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_spsc_ring.spsc_ring import OVERFLOW_DROP, SpscRing

var ring = SpscRing[Int64](capacity=2, overflow_policy=OVERFLOW_DROP)
assert_true(ring.try_push(1))
assert_true(ring.try_push(2))
assert_false(ring.try_push(3))  # full
assert_equal(ring.overflow_dropped_count(), 1)
assert_equal(ring.try_pop().value(), 1)
assert_true(ring.try_push(4))   # a slot is free again
assert_equal(ring.try_pop().value(), 2)
assert_equal(ring.try_pop().value(), 4)
```

A capacity of zero or less is refused:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_spsc_ring.spsc_ring import SpscRing

var message = String()
try:
    _ = SpscRing[Int64](capacity=0)
except e:
    message = String(e)
assert_equal(message, "SpscRing: capacity must be > 0")
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_spsc_ring`, version 0.1.0
(`mopm.toml`). The library is `src/komira_spsc_ring/` (`spsc_ring.mojo`, `_test_threads.mojo`, a test helper, and the
`__init__.mojo`), its tests are `tests/`; `tests/bench_spsc_ring.mojo` is the microbenchmark, declared under
`[targets] bins` of `mopm.toml` (`:bin_spsc_ring_bench`) and not run as a test. It depends on two packages,
`komira_atomic_alias` and `komira_collections`, sibling directories (`[dependencies]` of `mopm.toml`: `{ path =
"../komira_atomic_alias", version = "0.1" }` and `{ path = "../komira_collections", version = "0.1" }`).
`komira_collections` depends on `komira_atomic_alias` in turn, so the lock holds both and the `.conda` of this package
records `mojo-komira_atomic_alias >=0.1,<0.2` and `mojo-komira_collections >=0.1,<0.2` as dependencies and holds none
of their files: installing `komira_spsc_ring` installs both with it. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library, its tests and the benchmark are |
| `mopm.lock` | the toolchain pins and the path dependencies, as `mopm lock` writes them (no registry is reached: both dependencies are siblings; `komira_collections` lists its own dependency) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of `komira_collections` (which is built from that of
`komira_atomic_alias`), and exists only once the tests of `tests/` have passed. After any change to a source, a test,
a manifest of this package or of a sibling, run `buildrules mojo sync` with the three packages staged, commit what it
writes, and build `komira//src/komira_spsc_ring:lib` on the farm. A test file that the sync has not listed is not
run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_spsc_ring-0.1.0-mojo1.0.0_0.conda`), packed with the siblings' manifests beside its own (`members`),
which therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is a step of a
CI job that takes that file, not a build action.

`:komira_spsc_ring` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built
from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not
run again.
