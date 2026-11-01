# komira_collections

Generic containers with no dependency beyond `komira_atomic_alias`.
`Slab[T]` (`komira_collections.slab`) is a growable array for any movable
type, including one that cannot be copied: values are moved in with `append`,
borrowed in place with `get`, and moved out with `pop`, `take_at` (order kept)
or `swap_remove` (O(1), the last value fills the hole). `VariadicPack`
(`komira_collections.variadic_pack`) stores a compile-time list of values of
different types that share the `VariadicElement` trait, and a `comptime for`
over it calls each one's trait method directly, with no dynamic dispatch.
`DynValue` (`komira_collections.dyn_value`) holds one value of any type up to a
fixed size inline, without a heap allocation. `HyperLogLog`
(`komira_collections.hyperloglog`) estimates how many distinct values it has
seen in a fixed 4 KiB sketch, and two sketches merge into the sketch of their
union.

## Examples

A slab of values that cannot be copied:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo module
from komira_collections.slab import Slab


struct Job(Deinitable, Movable):
    var name: String
    var steps: List[Int]

    def __init__(out self, var name: String, var steps: List[Int]):
        self.name = name^
        self.steps = steps^


def main() raises:
    var jobs = Slab[Job]()
    jobs.append(Job("build", [1, 2, 3]))
    jobs.append(Job("test", [4]))
    jobs.append(Job("ship", [5, 6]))
    assert_equal(len(jobs), 3)
    assert_equal(len(jobs.get(0).steps), 3)

    var first = jobs.swap_remove(0)  # "ship" moves into slot 0
    assert_equal(first.name, "build")
    assert_equal(jobs.get(0).name, "ship")
    var second = jobs.take_at(1)
    assert_equal(second.name, "test")
    assert_equal(len(jobs), 1)
    assert_true(Bool(jobs.pop()))
    assert_true(not jobs.pop())
```

A pack of values of different types, visited at compile time:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo module
from komira_collections.variadic_pack import VariadicElement, VariadicPack


@fieldwise_init
struct Width(VariadicElement):
    var px: Int

    def variadic_tag(self) -> Int:
        return self.px


@fieldwise_init
struct Margin(VariadicElement):
    var px: Int

    def variadic_tag(self) -> Int:
        return 2 * self.px


def total[*Ts: VariadicElement](pack: VariadicPack[*Ts]) -> Int:
    var sum = 0
    comptime for k in range(VariadicPack[*Ts].arity()):
        sum += pack.get[k]().variadic_tag()  # a direct call per element
    return sum


def main() raises:
    var pack = VariadicPack[Width, Margin, Width](Width(100), Margin(8), Width(20))
    assert_equal(total(pack), 136)
    assert_equal(pack.get[1]().px, 8)
```

Counting distinct values, and merging two sketches:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_collections.hyperloglog import HyperLogLog

var evens = HyperLogLog()
var odds = HyperLogLog()
for i in range(10_000):
    if i % 2 == 0:
        evens.add_int64(Int64(i))
    else:
        odds.add_int64(Int64(i))
    evens.add_int64(Int64(0))  # repeats do not count again

var seen = evens.estimate()
assert_true(seen > 4_750 and seen < 5_250)  # about 1.6% standard error
evens.merge(odds)
var both = evens.estimate()
assert_true(both > 9_500 and both < 10_500)
```

One value of any type, stored inline, and read back only as that type. `DynValue[MAX_SIZE]` holds one value of any `Movable` type of at most
`MAX_SIZE` bytes, with no heap allocation, and destroys it when dropped.
`get[T]()` returns a reference to the value, mutable when the `DynValue` is.
It is checked: it raises when the `DynValue` is empty or holds another type.
The identity compared is the symbol name of a per-type instantiation, which
is unique per type (a type's printed name is not: every function type prints
the same). `holds[T]()` asks the same question without raising. `create[T]`
refuses, at compile time, a type larger than `MAX_SIZE`, more aligned than 8
bytes, or with a move constructor that is not trivial.

```mojo module
from komira_collections.dyn_value import DynValue
from std.testing import assert_equal, assert_false, assert_raises, assert_true


@fieldwise_init
struct Point(Movable):
    var x: Int
    var y: Int


def main() raises:
    var dv = DynValue[32].create[Point](Point(3, 4))
    assert_true(dv.holds[Point]())
    assert_equal(dv.get[Point]().x, 3)

    dv.get[Point]().y = 10
    assert_equal(dv.get[Point]().y, 10)

    assert_false(dv.holds[Int]())
    with assert_raises(contains="asked for"):
        _ = dv.get[Int]()
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_collections`, version 0.1.0
(`mopm.toml`). The library is `src/komira_collections/` (`slab.mojo`, `dyn_value.mojo`, `variadic_pack.mojo`,
`hyperloglog.mojo` and the `__init__.mojo` that ties them together), its tests are `tests/`. It depends on one
package, `komira_atomic_alias`, a sibling directory (`[dependencies]` of `mopm.toml`: `{ path =
"../komira_atomic_alias", version = "0.1" }`), so the `.conda` of this package records
`mojo-komira_atomic_alias >=0.1,<0.2` as a dependency and holds none of that package's files: installing
`komira_collections` installs `komira_atomic_alias` with it. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependency and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependency, as `mopm lock` writes them (no registry is reached: the only dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifest of the sibling; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of `komira_atomic_alias`, and exists only once the tests of
`tests/` have passed. After any change to a source, a test, a manifest of this package or of the sibling, run
`buildrules mojo sync` with both packages staged, commit what it writes, and build
`komira//src/komira_collections:lib` on the farm. A test file that the sync has not listed is not run: run the sync
after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_collections-0.1.0-mojo1.0.0_0.conda`), packed with the sibling's manifest beside its own (`members`),
which therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is a step of a
CI job that takes that file, not a build action.

`:komira_collections` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built
from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not
run again.
