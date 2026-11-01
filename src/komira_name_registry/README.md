# komira_name_registry

Interned names: a compile-time id for a string literal, and a fixed-size
table that turns an id back into its name.

- `name_id[name]()` is the FNV-1a 32-bit hash of a `StringLiteral`, computed
  at compile time, so the id is a constant at the call site.
  `name_id_of(s)` computes the same id at run time from a `String`.
- `NameRegistry` records each registered name under its id, so code that
  carries only ids (a counter, a trace span) can print names later.
  It holds at most `MAX_REGISTERED_NAMES` (256) names of at most
  `MAX_NAME_BYTES` (64) bytes each; a longer name is stored cut at the last
  whole UTF-8 character that fits. Registration fails (returns `False`) when
  the table is full. Id 0 marks an empty slot, so a name whose id is 0 cannot
  be registered.

Concurrency: register from one thread at a time (or under your own lock).
Once registration is done, any number of threads may call `lookup`,
`contains` and `count`. The full contract is in the header of
`registry.mojo`.

The package depends only on `komira_hash`.

Every example below runs as a test when the package is built, so it cannot
go stale.

## Ids

```mojo
from komira_name_registry import name_id, name_id_of
from std.testing import assert_equal, assert_true

assert_equal(name_id["a"](), UInt32(0xE40C292C))  # the FNV-1a 32-bit test vector
assert_equal(name_id["foobar"](), UInt32(0xBF9CF968))
assert_equal(name_id["scan.rows"](), name_id_of(String("scan.rows")))
assert_true(name_id["scan.rows"]() != name_id["scan.bytes"]())
```

## Registering and looking up

`try_register` returns `True` the first time a name is registered and
`False` after that, so registering a name twice is harmless. `lookup`
returns the name for an id, or `None` for an id nobody registered;
`contains` answers the same question without allocating a `String`.

```mojo
from komira_name_registry import NameRegistry, name_id, name_id_of
from std.testing import assert_equal, assert_false, assert_true

var reg = NameRegistry()
assert_true(reg.try_register["scan.rows"]())
assert_false(reg.try_register["scan.rows"]())  # already there: a no-op
assert_true(reg.try_register["scan.bytes"]())
assert_equal(reg.count(), 2)

assert_equal(reg.lookup(name_id["scan.rows"]()).value(), "scan.rows")
assert_true(reg.contains(name_id_of(String("scan.bytes"))))
assert_false(reg.contains(name_id["never.registered"]()))
assert_false(Bool(reg.lookup(name_id["never.registered"]())))
assert_false(Bool(reg.lookup(UInt32(0))))  # 0 is the empty-slot marker
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_name_registry`, version 0.1.0
(`mopm.toml`). The library is `src/komira_name_registry/`, its tests are `tests/`. It depends on one package,
`komira_hash`, a sibling directory (`[dependencies]` of `mopm.toml`: `{ path = "../komira_hash", version = "0.1" }`),
so the `.conda` of this package records `mojo-komira_hash >=0.1,<0.2` as a dependency and holds none of that
package's files. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependency and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependency (no registry is reached: the only dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifest of the sibling; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of `komira_hash`, and exists only once the tests have passed.
After any change to a source, a test, or a manifest of this package or of the sibling, run `buildrules mojo sync`
with both packages staged, commit what it writes, and build `komira//src/komira_name_registry:lib` on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_name_registry-0.1.0-mojo1.0.0_0.conda`), packed with the sibling's manifest beside its own
(`members`). Publishing it (`mopm publish`) uploads, so it is a step of a CI job, not a build action.

`:komira_name_registry` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built
from. It also compiles and runs the README's examples above (`[tests][readme]`) against `:lib`; the tests are not
run again.
