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
