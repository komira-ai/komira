# komira_counters

Process-global census and falsifier counters plus the build-gated runtime introspection probe.

A counter is named, not constructed: `GlobalCounter["name"]` is a type whose
static methods add to, read and reset one 64-bit cell, and every use of the
same name, in any module of the process, reaches the same cell. The cell is
created, zeroed, the first time a name is used. Adds are relaxed atomic
operations, so threads may count at once; read a total after they have
joined. `GlobalCounterTable["name", n]` is the same with `n` slots.

The `try_` forms (`try_add`, `try_incr`) do not raise, for an instrument in a
function that cannot: a counter must never change the control flow of the
code it observes.

Every example below runs as a test when the package is built, so it cannot
go stale.

## A counter

```mojo
from komira_counters.global_counter import GlobalCounter
from std.testing import assert_equal

comptime Requests = GlobalCounter["readme_example_requests"]


def handle_request() raises:
    Requests.incr()


def requests_seen() raises -> Int:
    # The name spelled again: the same counter.
    comptime Seen = GlobalCounter["readme_example_requests"]
    return Seen.read()


Requests.reset()
handle_request()
handle_request()
Requests.add(5)
Requests.try_add(-1)
assert_equal(requests_seen(), 6)
Requests.reset()
assert_equal(requests_seen(), 0)
```

## A table of counters

A slot outside the table is refused rather than written.

```mojo
from komira_counters.global_counter import GlobalCounterTable
from std.testing import assert_equal, assert_raises

comptime ByWidth = GlobalCounterTable["readme_example_by_width", 4]

ByWidth.reset()
ByWidth.incr(1)
ByWidth.add(3, 40)
assert_equal(ByWidth.read(0), 0)
assert_equal(ByWidth.read(1), 1)
assert_equal(ByWidth.read(3), 40)
with assert_raises(contains="slot out of range"):
    ByWidth.incr(4)
```

## The counters in this package

`global_counter` is the one primitive under every counter here: a process-global, name-keyed table of relaxed atomic counters (`GlobalCounter`, `GlobalCounterTable`) whose API exposes no pointer. Each counter module declares its names and keeps only its own meaning.

A counter that has one owner lives in its owner's package and uses `global_counter` from here: `gather_width_counter`, `rxcensus` and `string_eq_arm_counter` in `komira_column_kernels`, `join_index_window_counter` in `komira_join_assembly`. The counters that are cross-cutting (`runtime_introspection`, `keyeq_census`) or whose owners are not packages yet (`strdrain_counter`, `planner_scale_counter`, `parquet_read_counter`) stay here.

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_counters`, version 0.1.0
(`mopm.toml`). The library is `src/komira_counters/`, its tests are `tests/`. It depends on one package,
`komira_atomic_alias`, a sibling directory (`[dependencies]` of `mopm.toml`: `{ path = "../komira_atomic_alias",
version = "0.1" }`), so the `.conda` of this package records `mojo-komira_atomic_alias >=0.1,<0.2` as a dependency and
holds none of that package's files: installing `komira_counters` installs `komira_atomic_alias` with it. Its tests
also use `komira_runtime_paths` (`[dev-dependencies]`), which reaches the tests only and is not in the `.conda`. The
files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependency, the dev-dependency and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, as `mopm lock` writes them (no registry is reached: both are siblings) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

The tests are built with the `KOMIRA_TRACE_ARC`, `KOMIRA_TRACE_TCMALLOC` and `KOMIRA_TRACE_TRAMPOLINE` defines on
(`test_defines` in `BUCK`), so `test_runtime_introspection` sees the lines those hooks emit; the library file `:lib`
is built without them. `:lib` exists only once the tests have passed. After any change to a source, a test, a manifest
of this package or of a sibling, run `buildrules mojo sync` with the packages staged, commit what it writes, and
build `komira//src/komira_counters:lib` on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_counters-0.1.0-mojo1.0.0_0.conda`), packed with the sibling's manifest beside its own (`members`),
which therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is a step of a
CI job that takes that file, not a build action.

`:komira_counters` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built
from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not
run again.
