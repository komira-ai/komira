# komira_runtime_paths

Where a running program finds its files, from its own executable path.

A shipped program (a bundle) and a test's staged tree share one layout:

```text
<root>/bin/<program>
<root>/share/<data files>
```

These functions find `<root>` through the executable's own path
(`/proc/self/exe` on Linux, `_NSGetExecutablePath` and `realpath` on macOS),
so they need no environment variable and no runfiles tree, and they give
the same answer whatever the current directory is.

| function | returns |
|---|---|
| `executable_path()` | the absolute, symlink-free path of the running executable |
| `install_root()` | `<root>`, the parent of the directory holding the executable |
| `share_dir()` | `<root>/share` |
| `data_path(rel)` | `<root>/share/<rel>`; the file is not opened |
| `read_data(rel)` | the contents of `<root>/share/<rel>`; raises if it is absent |
| `test_tmpdir()` | `$TEST_TMPDIR`, a directory private to the running test; raises when it is unset rather than falling back to a shared directory |

`rel` is where the build put the file under `share/`: its key in a `data`
dict, or its path from the cell root in a `data` list. It must be relative,
with no empty, `.` or `..` segment; anything else raises before the file
system is touched. A program that wants a clear error for an undeclared file
uses `komira_resources`, which is built on this package.

Every example below runs as a test when the package is built, so it cannot
go stale.

## The layout, from the executable

```mojo
from komira_runtime_paths import data_path, executable_path, install_root, share_dir
from std.testing import assert_equal, assert_true

var exe = executable_path()
assert_true(exe.startswith("/"))
var root = install_root()
assert_true(exe.startswith(root + "/"))  # <root>/<dir>/<program>
assert_equal(share_dir(), root + "/share")
assert_equal(data_path("config/settings.txt"), root + "/share/config/settings.txt")
```

## Paths that are refused

```mojo
from komira_runtime_paths import data_path
from std.testing import assert_equal

var refused_paths: List[String] = ["", "/etc/passwd", "../outside.txt", "a/./b.txt", "a//b.txt"]
for bad in refused_paths:
    var refused = False
    try:
        _ = data_path(bad)
    except e:
        refused = "data path must" in String(e)
    assert_equal(refused, True, "data_path accepted '" + bad + "'")
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_runtime_paths`, version 0.1.0
(`mopm.toml`). The library is `src/komira_runtime_paths/` (`paths.mojo` and the `__init__.mojo` that re-exports it),
its test is `tests/`. The package has no dependencies and no native archive. It calls three C functions, each by name
and with no platform constant: `readlink` on `/proc/self/exe` (Linux), `_NSGetExecutablePath` and `realpath` (macOS),
all in the C library or dyld that every Mojo program links; the buffer size is the package's own `_PATH_CAP`, not a
`PATH_MAX`. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, where the library and its tests are |
| `mopm.lock` | what `mopm lock` writes (with no registry reachable); the package has no dependencies, so it pins the toolchain only |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN`: the least line coverage `:coverage` may measure; `:coverage_floor` fails when it falls below, and above it passes and prints a hint to raise the figure. There is no `branches` line: the test runs in the installed layout, which has no branch records yet |
| `fixtures/` | the files the test declares under `test_data` (`greeting.txt`, `other.txt`) and one it does not (`undeclared.txt`) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above; `buildrules mojo check` fails when they are stale |

The test runs with `test_layout = "installed"`: the test binary is `<root>/bin/<exe>`, the declared files are under
`<root>/share` (each key relative to `share/`), the working directory is `<root>`, and `TMPDIR`, `TEST_TMPDIR` and
`HOME` are private to the run, which is the layout this library reads. `:lib` is the library file and exists only once
the test has passed. After any change to a source, a test, `mopm.toml`, `mopm.lock` or `mopm-toolchain.toml`, run
`buildrules mojo sync`, commit what it writes, and build `komira//src/komira_runtime_paths:lib` on the farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_runtime_paths-0.1.0-mojo1.0.0_0.conda`), which therefore exists only once the test has passed.
Publishing it (`mopm publish`) uploads, so it is a step of a CI job that takes that file, not a build action.

`:komira_runtime_paths` is `:lib` as komira's Mojo rules take it (`mojo_adopted_library`). It also compiles and runs
the README's examples above (`[tests][readme]`) against `:lib`; the test is not run again. The label
`komira//tools/build/mojo/runtime_paths:komira_runtime_paths` is an alias of it.
