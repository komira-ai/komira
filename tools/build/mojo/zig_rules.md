# Zig rules and script_test, for a repository that uses komira

The Zig rules ([`toolchain.bzl`](toolchain.bzl)) build and test Zig programs
as build actions with the pinned zig and busybox; `script_test`
([`script_test.bzl`](script_test.bzl)) runs a command, a script or a built
tool, as a build action. A repository that names komira as its `komira` cell
([Using komira from another repository](../README.md#using-komira-from-another-repository))
loads them as `@komira//tools/build/mojo:toolchain.bzl` and
`@komira//tools/build/mojo:script_test.bzl`. The examples are
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
- `unit_tests`: `zig_test` or `script_test` targets of the module. Nothing
  imports the module, or a module that depends on it, unless they passed.

## zig_exe, zig_test, zig_test_binary

| attribute | rules | default | meaning |
|---|---|---|---|
| `optimize` | `zig_exe`, `zig_test` | `ReleaseSafe`, `Debug` | zig's `-O`: `Debug`, `ReleaseSafe`, `ReleaseFast` or `ReleaseSmall`. `Debug` is zig's own default, so `zig_test` passes no flag for it |
| `strip` | `zig_exe` | `True` | `-fstrip`; `False` passes `-fno-strip`, so the executable keeps its debug information |
| `target` | `zig_exe`, `zig_test`, `zig_test_binary` | `x86_64-linux-musl` (required for `zig_test_binary`) | zig's `-target`. A `zig_test` runs its tests inside the action: the target must run on the execution platform (`x86_64-linux-gnu` does) |

With the defaults the commands, and so the action keys, of every existing
target are what they were before these attributes existed.

## script_test

```python
load("@komira//tools/build/mojo:script_test.bzl", "script_test")

script_test(
    name = "golden",
    cmd = "sh",
    args = ["tests/run_golden.sh", "$(location :tool)"],
    srcs = glob(["tests/**"]),
    tools = {"tool": ":tool"},
    env = {"TOOL": "$(location :tool)"},
)
```

The action runs on linux-x86_64 (`exec_compatible_with` defaults to it; the
shell and the file utilities are the pinned busybox) and its output,
`<name>.passed`, is written only if the command exited 0. A target that names
it in `unit_tests` is therefore built after it, as after a `zig_test`; a
`script_test` that runs a built tool cannot be an input of that tool.

- **Working directory.** A scratch directory in the action holding a copy of
  `srcs`: a list of sources (files or directories), each at its path from the
  cell root, or `{destination: source}`. The copy is writable and keeps
  executable bits; the command may write anywhere under it. A source listed as
  a file and as a directory of another is refused.
- **Environment.** `HOME`, `TMPDIR`, `XDG_CACHE_HOME`, `ZIG_GLOBAL_CACHE_DIR`
  and `ZIG_LOCAL_CACHE_DIR` are directories inside the action's scratch space.
  `PATH` is the declared tools, then the busybox applets; nothing of the worker
  is on it. `env` adds variables (not these, nor `PATH`); a value may hold
  `$(location ...)` and `$(exe ...)`.
- **Tools.** `tools` maps a name to a target. An executable file is on `PATH`
  under its name. A directory, such as the pinned zig or an unpacked
  interpreter distribution, puts its `bin/` (or itself, when it has none) on
  `PATH`.
- **Command.** `cmd` is a path of `srcs` (from the working directory) or a name
  on `PATH`; `args` are strings in which `$(location ...)` and `$(exe ...)`
  expand to absolute paths. A script runs by its `#!` line only if the worker
  image has that interpreter: name the interpreter in `cmd` (`sh`, or a tool such
  as `python3`) and the script in `args`. The macro syntax owns `$(`: shell
  command substitution belongs in a source script.
- **Failure.** `script_test: <cmd> exited with status N; the last 200 lines of
  its output:` and the command's merged standard output and error.

There is no network; a test that needs a server starts one on the loopback
interface.

## An interpreter as a tool

`python_dist` ([`python/defs.bzl`](../python/defs.bzl)) unpacks a pinned
python-build-standalone archive (`install_only`, stripped) with busybox `tar`
into a directory holding `bin/python3`; as a `script_test` tool its `bin/` is on
`PATH`. komira does not declare one for consumers (it has no Python surface:
`//:python_closure`), so the repository that needs one pins the archive itself
(`pinned_file`) and declares the dist. On macOS execution platforms, give it
`busybox = "komira//tools/build/mojo/darwin:busybox.sh"` and `system_tar = True`
(that busybox has no `tar` applet).
