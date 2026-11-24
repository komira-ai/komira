# `bump_arena`

An O(1)-reset bump allocator over a fixed-capacity byte region, built on
`byte_buffer` (`ByteView`).

- `bump_arena`: `BumpArena`. A request past capacity declines (the
  `ARENA_DECLINE` sentinel) instead of growing, so no page fault comes back
  inside a pull loop. Allocations are `ARENA_ALIGN`-aligned.
- The public API returns `ByteView` and typed scalars, never a raw pointer.

There are no root re-exports; import each name from its module.

Hand out two blocks, see a request past the capacity declined, and rewind:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from bump_arena.bump_arena import ARENA_ALIGN, ARENA_DECLINE, BumpArena

var arena = BumpArena(256)
assert_equal(arena.capacity(), 256)

var first = arena.alloc(10)
var second = arena.alloc(100)
assert_equal(first, 0)
assert_equal(second, ARENA_ALIGN)  # each request is rounded up to 64 bytes
assert_equal(arena.used(), 3 * ARENA_ALIGN)

assert_false(arena.would_fit(100))
assert_equal(arena.alloc(100), ARENA_DECLINE)  # never grows
assert_equal(arena.used(), 3 * ARENA_ALIGN)

arena.reset()
assert_equal(arena.used(), 0)
assert_true(arena.would_fit(256))
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `bump_arena`, version 0.1.0
(`mopm.toml`). The library is `src/bump_arena/`, its tests are `tests/`. It depends on one package, a sibling
directory (`[dependencies]` of `mopm.toml`): `byte_buffer`, as `{ path = "../byte_buffer", version = "0.1" }`. The
`.conda` of this package records `mojo-komira-ai.byte_buffer >=0.1,<0.2` as a dependency and holds none of its files:
installing `bump_arena` installs `byte_buffer` (and, through it, its own dependencies) with it. This package
owns no C. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependency and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, direct and transitive, as `mopm lock` writes them (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | the line and branch coverage the build holds at least |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of `byte_buffer`, and exists only once every test of `tests/` has
passed. After any change to a source, a test, a manifest of this package or of a sibling, run `buildrules mojo sync`
with this package and the packages of its closure staged, commit what it writes, and build
`komira//src/bump_arena:lib` on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira-ai.bump_arena-0.1.0-mojo1.1.0_0.conda`), packed with the manifests of the path dependencies beside its own
(`members`), which therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is
a step of a CI job that takes that file, not a build action.

`:bump_arena` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`): its `deps` are the adopted
target of each package in `[dependencies]`, and the rule refuses a list that is not the closure `:lib` was built
from. It also compiles and runs the README's examples (`[tests][readme]`) against `:lib`; the tests are not run again.
