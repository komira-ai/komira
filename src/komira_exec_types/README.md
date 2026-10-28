# komira_exec_types

The result and error types that cross the operator / scheduler / caller boundary: EngineError, ExecResult, ProcessResult, QueryContext, the byte-budget parser, the PartitionBy output contract.

## Examples

A byte budget is a decimal count with an optional 1024-based `G`, `M` or `K` suffix. An empty or malformed budget
parses to 0, so an unset budget is ignored rather than read as a zero budget:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_exec_types.byte_size import parse_byte_size

assert_equal(parse_byte_size("8G"), 8 * 1024 * 1024 * 1024)
assert_equal(parse_byte_size("512M"), 512 * 1024 * 1024)
assert_equal(parse_byte_size("64k"), 64 * 1024)
assert_equal(parse_byte_size("4096"), 4096)
assert_equal(parse_byte_size(""), 0)
assert_equal(parse_byte_size("many"), 0)
```

An engine error is a code and a message, built by one factory per variant and told apart by predicates:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_exec_types.engine_error import ERR_IO, ERR_SCHEMA, io_error, schema_error

var failure = io_error("read failed")
assert_equal(failure.code, ERR_IO)
assert_equal(failure.message, "read failed")
assert_true(failure.is_io())
assert_false(failure.is_schema())
assert_equal(schema_error("no column").code, ERR_SCHEMA)
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_exec_types`, version 0.1.0
(`mopm.toml`). The library is `src/komira_exec_types/`, its tests are `tests/`. It depends on one package, a sibling
directory (`[dependencies]` of `mopm.toml`): `komira_arrow`, as `{ path = "../komira_arrow", version = "0.1" }`. The
`.conda` of this package records `mojo-komira_arrow >=0.1,<0.2` as a dependency and holds none of its files: installing
`komira_exec_types` installs `komira_arrow` with it. `komira_arrow`'s closure includes `komira_libc`, which links a C
shim of its own; a dependent's link takes it from the closure, and this package owns no C. The files that are not
sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependency and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, as `mopm lock` writes them (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of `komira_arrow`, and exists only once every test of `tests/` has
passed. After any change to a source, a test, a manifest of this package or of a sibling, run `buildrules mojo sync`
with the package and its siblings staged, commit what it writes, and build `komira//src/komira_exec_types:lib` on the
farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_exec_types-0.1.0-mojo1.0.0_0.conda`), packed with the manifests of the path dependencies beside its own
(`members`), which therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is
a step of a CI job that takes that file, not a build action.
