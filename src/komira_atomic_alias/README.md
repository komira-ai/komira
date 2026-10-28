# komira_atomic_alias

Fixed-width names for the standard library's `Atomic`: `AtomicI8`, `AtomicI32`,
`AtomicI64`, `AtomicU8`, `AtomicU32` and `AtomicU64`, with no other
dependencies. Each name is exactly `std.atomic.Atomic` at that width (the same
type, not a wrapper), so it has the same size, alignment and operations. The
point is the spelling: `Atomic`'s type parameter is changing in a coming Mojo
release, from a `DType` to a scalar type, and code that imports these names is
untouched by that change; only this package is edited.

## Examples

A counter:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_atomic_alias import AtomicI64

var hits = AtomicI64(0)
_ = hits.fetch_add(5)
var before = hits.fetch_sub(2)  # returns the value before the subtraction
assert_equal(Int(before), 5)
assert_equal(Int(hits.load()), 3)
```

Each name holds exactly its width and signedness:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from std.sys import size_of
from komira_atomic_alias import AtomicI8, AtomicU8, AtomicU32

assert_equal(size_of[AtomicU32](), 4)
var signed = AtomicI8(-1)
var unsigned = AtomicU8(255)
assert_equal(Int(signed.load()), -1)
assert_equal(Int(unsigned.load()), 255)
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_atomic_alias`, version 0.1.0
(`mopm.toml`). The library is `src/komira_atomic_alias/` (`atypes.mojo`, which holds the six `comptime` names, and the
`__init__.mojo` that re-exports them), its test is `tests/`. The package has no dependencies, no native archive and
calls no foreign function. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); the package has no dependencies, so it pins the toolchain only |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once the test of `tests/` has passed. After any change to a source,
a test, `mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run `buildrules mojo sync`, commit what it
writes, and build `komira//src/komira_atomic_alias:lib` on the farm. (The sync writes the toolchain pins,
`mojo_pins.bzl` and `mopm_pins.bzl`, to the directory the `[cells] toolchains` line of `.buckconfig` names:
`tools/build/cells/toolchains/` here.) A test file that `buildrules mojo sync` has not listed is not
run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_atomic_alias-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the test has passed.
Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:komira_atomic_alias` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). It also compiles and runs
the README's examples above (`[tests][readme]`) against `:lib`, which `:lib` does not do; the test is not run again.

Coverage: `atypes.mojo` holds only `comptime` declarations, so the coverage report lists it with 0 of 0 lines and the
package has no `coverage_floor.txt`: a floor on nothing measurable is refused.
