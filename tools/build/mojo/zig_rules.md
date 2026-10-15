# Zig rules, for a repository that uses komira

The Zig rules ([`toolchain.bzl`](toolchain.bzl)) build and test Zig programs
as build actions with the pinned zig and busybox. A repository that names
komira as its `komira` cell
([Using komira from another repository](../README.md#using-komira-from-another-repository))
loads them as `@komira//tools/build/mojo:toolchain.bzl`. The examples are
[`tests/functional/zig_rules`](../tests/functional/zig_rules/BUCK); the
defects that must go red are
[`tests/negative/zig_rules`](../tests/negative/zig_rules/BUCK).

A test is welded: it is a build action, so a target that names it in
`unit_tests` is not built unless it passed, and a cached result is a pass on
identical inputs. `buck2 test` runs nothing for these rules.

## zig_module

`zig_module(name, src, imports, deps, unit_tests)` is a Zig file other targets
import by name: `@import("<name>")` in a `zig_exe`, `zig_test` or
`zig_test_binary` that lists the target in `deps`. The import name is the
target's name (`root`, `std` and `builtin` are zig's own and refused).

- `imports`: the files `src` imports by a relative name, beside it.
- `deps`: `zig_module` targets the module itself imports by name. The closure is
  transitive and each module is given the imports of its own `deps` only, as
  `zig build`'s `addImport` does: an importer sees the modules it lists, not
  the ones those import. Two different targets of one import name anywhere in
  a closure fail analysis (`two different modules are imported as "<name>"`).
- `unit_tests`: `zig_test` targets of the module. Nothing
  imports the module, or a module that depends on it, unless they passed.

## zig_exe, zig_test, zig_test_binary

| attribute | rules | default | meaning |
|---|---|---|---|
| `optimize` | `zig_exe`, `zig_test` | `ReleaseSafe`, `Debug` | zig's `-O`: `Debug`, `ReleaseSafe`, `ReleaseFast` or `ReleaseSmall`. `Debug` is zig's own default, so `zig_test` passes no flag for it |
| `strip` | `zig_exe` | `True` | `-fstrip`; `False` passes `-fno-strip`, so the executable keeps its debug information |
| `target` | `zig_exe`, `zig_test`, `zig_test_binary` | `x86_64-linux-musl` (required for `zig_test_binary`) | zig's `-target`. A `zig_test` runs its tests inside the action: the target must run on the execution platform (`x86_64-linux-gnu` does) |

With the defaults the commands, and so the action keys, of every existing
target are what they were before these attributes existed.

## Driver tests: exec_tools and data

A `zig_test` that drives built programs, an integration test written in Zig,
is given:

- `exec_tools = {NAME: target}`: each tool's **absolute** path in the
  environment variable `NAME` (`env_tools` gives a path relative to the
  action's directory). An executable's path is the file; a directory, such as
  the pinned zig (`komira//tools/build/toolchains:zig`), is the directory.
  A test with `exec_tools` or `env_tools` is also a validation, and cannot be
  an input of a tool it runs.
- `data`: a list of sources (files or directories, each at its path from the
  cell root) or `{destination: source}`, copied into a writable directory whose
  path is `KOMIRA_TEST_WORK`; executable bits are kept.
- `HOME`, `TMPDIR`, `XDG_CACHE_HOME`, `ZIG_GLOBAL_CACHE_DIR` and
  `ZIG_LOCAL_CACHE_DIR` are directories inside the action's scratch space
  (`XDG_CACHE_HOME` and `KOMIRA_TEST_WORK` only with `exec_tools` or `data`,
  so that the command of a test without them is unchanged).
- Loopback networking: a server on `127.0.0.1` port 0 and a client in the same
  test work. There is no other network.

The test runs in the action's directory, with the busybox applets as its
`PATH`; it spawns programs with `std.process.Child`. No shell is needed in the
test, and no script is run.
