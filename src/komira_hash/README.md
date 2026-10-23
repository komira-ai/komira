# komira_hash

FNV-1a, 32 and 64 bit, with no dependencies: `fnv1a_32` and `fnv1a_64` hash a
byte span with the published FNV parameters (the four constants are exported
too), so the same bytes hash to the same value in every program and on every
machine. It is a cheap, stable hash for identifiers, table keys and sharding
over names you trust. It is not a cryptographic hash and does not resist
collisions an adversary chooses.

## Examples

The published test vectors:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_hash import FNV1A_32_OFFSET_BASIS, fnv1a_32, fnv1a_64

assert_equal(fnv1a_32("foobar".as_bytes()), 0xBF9CF968)
assert_equal(fnv1a_64("foobar".as_bytes()), 0x85944171F73967E8)
assert_equal(fnv1a_32("".as_bytes()), FNV1A_32_OFFSET_BASIS)  # nothing hashed
```

Any byte span works, a `List[UInt8]` as well as a string's bytes. Here a key
picks one of 8 shards; the hash is stable, so it is the same shard in every
program:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_hash import fnv1a_32

var raw: List[UInt8] = [0x61]  # the byte of "a"
assert_equal(fnv1a_32(Span(raw)), fnv1a_32("a".as_bytes()))
assert_equal(fnv1a_32("user:42".as_bytes()), 0x2F6B7B82)
assert_equal(fnv1a_32("user:42".as_bytes()) % 8, 2)
```

## Files

| file | what it holds |
|---|---|
| `fnv1a.mojo` | `fnv1a_32`, `fnv1a_64` and the four FNV constants |

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_hash`, version 0.1.0
(`mopm.toml`). The library is `src/komira_hash/` (the files of the table above), its tests are `tests/`. The
package has no native archive and calls no foreign function: it is Mojo over `Span` and integers. The files
that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); the package has no dependencies, so it pins the toolchain only |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source,
a test, `mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run `buildrules mojo sync`, commit what it
writes, and build `komira//src/komira_hash:lib` on the farm. (The sync writes the toolchain pins,
`mojo_pins.bzl` and `mopm_pins.bzl`, to the directory the `[cells] toolchains` line of `.buckconfig` names:
`tools/build/cells/toolchains/` here.) A test file that `buildrules mojo sync` has not listed is not
run: run the sync after adding one.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_hash-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the tests have passed.
Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:komira_hash` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). It also compiles and runs the
README's examples above (`[tests][readme]`) against `:lib`, which `:lib` does not do; the tests are not run again.
