# komira_test_run_id

A per-run id for naming the resources one test run creates (a bucket prefix,
a temporary directory, a namespace). `mint_run_id` builds it from a wall clock
and 64 random bits, and from nothing else, so two executions of the same
action (a retry and its twin) get different ids and disjoint resources. The id
reads `<epoch seconds>-<16 lowercase hex>`, for example
`1790000000-0123456789abcdef`, and is a valid validation-run id. The clock and
the random source are traits (`WallClock`, `Entropy`) with real conformers
(`SystemClock`, `UrandomEntropy`, which reads `/dev/urandom`) and fakes for
tests (`FixedWallClock`, `ScriptedEntropy`). `mint_run_id` raises when the
clock reads zero or less, or when the entropy source cannot produce a value.

## Examples

Mint from pinned sources, so the id is exact:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_test_run_id import FixedWallClock, ScriptedEntropy, mint_run_id

var clock = FixedWallClock(1790000000)
var entropy = ScriptedEntropy([UInt64(0x0123456789ABCDEF), UInt64(0xFF)])
var first = mint_run_id(clock, entropy)
assert_equal(first.value, "1790000000-0123456789abcdef")
assert_equal(first.created_unix, 1790000000)
clock.advance(5)
var second = mint_run_id(clock, entropy)
assert_equal(String(second), "1790000005-00000000000000ff")
```

Mint from the real clock and `/dev/urandom`; two ids differ:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_test_run_id import SystemClock, UrandomEntropy, mint_run_id

var clock = SystemClock()
var entropy = UrandomEntropy()
var a = mint_run_id(clock, entropy)
var b = mint_run_id(clock, entropy)
assert_true(a.value != b.value)
assert_equal(a.value.byte_length(), 27)
```

A source that runs out raises instead of repeating a value:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_test_run_id import FixedWallClock, ScriptedEntropy, mint_run_id

var clock = FixedWallClock(1790000000)
var empty = ScriptedEntropy(List[UInt64]())
var refused = False
try:
    _ = mint_run_id(clock, empty)
except:
    refused = True
assert_true(refused)
```

`hex16_lower` is the zero-padded format of the random half:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_test_run_id import hex16_lower

assert_equal(hex16_lower(UInt64(0xAB)), "00000000000000ab")
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_test_run_id`, version 0.1.0
(`mopm.toml`). The library is `src/komira_test_run_id/` (`run_id.mojo`, `seams.mojo` and the `__init__.mojo` that
re-exports them), its tests are `tests/`. It depends on two packages, `komira_clock` and `komira_validation_run`,
sibling directories (`[dependencies]` of `mopm.toml`: `{ path = "../komira_clock", version = "0.1" }` and
`{ path = "../komira_validation_run", version = "0.1" }`), so the `.conda` of this package records
`mojo-komira_clock >=0.1,<0.2` and `mojo-komira_validation_run >=0.1,<0.2` as dependencies and holds none of their
files: installing `komira_test_run_id` installs both with it. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, as `mopm lock` writes them (no registry is reached: both dependencies are siblings) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below, and above it passes and prints a hint to raise the figure |
| `coverage_held` | the metrics this package holds at the coverage target (`line`, `branch`), read by the pull request's coverage job |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of both siblings, and exists only once the tests of `tests/` have
passed. After any change to a source, a test, a manifest of this package or of a sibling, run `buildrules mojo sync`
with the three packages staged, commit what it writes, and build `komira//src/komira_test_run_id:lib` on the farm. A
test file that the sync has not listed is not run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_test_run_id-0.1.0-mojo1.0.0_0.conda`), packed with the siblings' manifests beside its own (`members`),
which therefore exists only once the tests have passed. `:conda_holds` reads it back: this package's own `.mojoc`
and exactly the two dependencies above. Publishing it (`mopm publish`) uploads, so it is a step of a CI job that
takes that file, not a build action.

`:komira_test_run_id` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built
from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not
run again.
