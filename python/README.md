# komira

komira is a SQL query engine that runs in your process. This package is its
Python binding: it carries `libkomira`, the engine as one shared library, and
calls it with `ctypes`.

**This is an early release.** It installs, imports and loads the engine, and
it registers Parquet files as tables. It does not run queries yet.

## Install

```sh
pip install komira
```

What it needs:

- **Linux on x86_64**, with glibc 2.34 or newer and an x86-64-v3 CPU (AVX2,
  BMI2, FMA: Intel Haswell, AMD Excavator or newer). Wheels for Linux on arm64
  and macOS on Apple silicon come in later releases.
- **Python 3.13 or newer.**
- **The system C++ runtime, `libstdc++`.** Most systems have it. A minimal
  container image may need the `libstdc++6` package (Debian, Ubuntu) or
  `libstdc++` (Fedora, RHEL).
- **Modular's `mojo-compiler` package**, which pip installs as a dependency.
  libkomira needs the Mojo runtime libraries at load time, and this package
  does not carry them. `mojo-compiler` is about 80 MB and is pinned to the
  version komira was built with.

## What works

```python
import komira

print(komira.__version__)     # the installed version
print(komira.abi_version())   # the engine's C ABI version: 1001 is 1.1

with komira.Session() as s:
    s.register_parquet("trips", "trips.parquet")
```

- `komira.__version__` is the installed distribution's version.
- `komira.abi_version()` loads the engine and returns its C ABI version as
  `major * 1000 + minor`.
- `komira.Session()` is one engine context. `register_parquet(name, path)`
  reads the Parquet file's footer and registers the file as the table `name`.
  - `path` may be a `str` or a `pathlib.Path`.
  - A relative path is resolved against the working directory, and `~` is
    expanded.
  - A missing or unreadable file raises `komira.KomiraError` with the engine's
    message.
  - Nothing can query the table yet.
- A session is a context manager. `close()` frees it and can be called again,
  and `closed` says whether it was. Any other call on a closed session raises
  `KomiraError`.
- `komira.KomiraError` is the base class of every error komira raises on
  purpose. Its `status` attribute is the engine's status code, or `None`.
- `komira.LibraryLoadError` is raised when the engine cannot be loaded. Its
  message names the library and the reason. For example, a library built for
  a different ABI major version is refused.
- `komira.RuntimeNotFoundError`, a `LibraryLoadError`, is raised when the Mojo
  runtime libraries are not installed, or are another version than the one
  komira was built with. Its message names the missing libraries (or both
  versions), the directories searched, and the fix:
  `pip install mojo-compiler==1.0.0`.
- `komira.UnsupportedCpuError`, a `LibraryLoadError`, is raised on Linux
  x86_64 when the CPU lacks a flag of x86-64-v3, before the engine is loaded.
  Its message lists the missing flags as `/proc/cpuinfo` spells them.

The engine is loaded on the first `Session()` or `abi_version()` call, not on
`import komira`.

## What does not work yet

- Running SQL. `Session.sql` arrives with the engine's query call.
- Results of any kind, such as Arrow tables or pandas and polars frames.
- The DataFrame APIs: one shaped like pandas and one shaped like polars.
- Registering CSV and JSON files.

SQL comes first in a later release of this same package, followed by the two
DataFrame APIs.

## Working on the package

Most readers can skip this section.

The package's layout and API are designed in
[docs/design/python_package.md](https://github.com/komira-ai/komira/blob/main/docs/design/python_package.md).

| path | what it is |
|---|---|
| `komira/__init__.py` | the public names, exactly `__all__` |
| `komira/_errors.py` | `KomiraError`, `LibraryLoadError`, `RuntimeNotFoundError` and `UnsupportedCpuError` |
| `komira/_native.py` | the `ctypes` loader: `load(lib_dir=None, *, search_path=None)` and the `Native` it returns, with the nine calls of ABI 1.1 |
| `komira/_runtime.py` | `_preload_runtime_libraries(*, search_path=None)`, called before libkomira is opened: it opens the three Mojo runtime libraries of `mojo-compiler` |
| `komira/_session.py` | `Session` |
| `komira/py.typed` | the PEP 561 marker |
| `BUCK` | `:komira`, the package's files as the directory its tests import from; `:komira_wheel`, the wheel; and `:wheel_install_test`, the wheel installed into an empty environment |
| `install_test.bzl` | the rules of the wheel's files and of the install test |
| `tests/` | the tests (`python_binding_test`, and the `py_test` of the runtime preload), `fake_libkomira.c` and `fake_mojo_runtime.c`, the stand-in libraries they load, `runtime_site.py`, the runtime laid out as `mojo-compiler` installs it, and `test_installed.py` and `wheel_install_run.py`, the install test and its driver |

How the loader behaves:

- **Where it looks.** `_native.load` opens `<lib_dir>/libkomira.so`. With no
  directory, it opens the package's own `_lib/libkomira.so`. No environment
  variable and no search of the working directory picks the library.
- **What runs before the library opens.** `load` first calls
  `_native._check_cpu()`, then
  `_runtime._preload_runtime_libraries(search_path=search_path)`. An error
  raised by either stops the load.
  - On Linux x86_64, `_check_cpu` reads the `flags` lines of `/proc/cpuinfo`
    and requires every flag of x86-64-v3, the level the library is compiled
    for there, on every processor: `pni` (SSE3), `ssse3`, `cx16`, `sse4_1`,
    `sse4_2`, `popcnt`, `lahf_lm`, `avx`, `avx2`, `bmi1`, `bmi2`, `f16c`,
    `fma`, `abm` (LZCNT) and `movbe`. A missing one raises
    `UnsupportedCpuError` naming it, instead of an illegal instruction inside
    the library; a file it cannot read raises `LibraryLoadError`. On other
    platforms it reads nothing.
- **The Mojo runtime.** `mojo-compiler` installs the three runtime libraries
  in `<site-packages>/modular/lib/`, which libkomira's run path does not reach.
  The preload looks in `modular/lib/` of each absolute directory of
  `search_path` (`sys.path` when it is None), in order, and takes the first
  that holds all three. It opens them by absolute path with `RTLD_GLOBAL`, in
  dependency order: `libMSupportGlobals`, `libAsyncRTRuntimeGlobals`,
  `libKGENCompilerRTShared` (`.so` on Linux, `.dylib` on macOS). libkomira's
  NEEDED names then resolve to the libraries already loaded.
  - No directory holds all three: `RuntimeNotFoundError`.
  - The `mojo-compiler` installed there is not `_MOJO_RUNTIME_VERSION`
    (1.0.0): `RuntimeNotFoundError`. With no `mojo-compiler` metadata there,
    the version is not checked.
  - A library that cannot be opened: `LibraryLoadError` with the reason.
  - A relative entry of the search path is skipped, and no environment
    variable or flag picks the directory. Once the runtime is loaded, another
    directory is refused.
- **The version check.** `komira_abi_version()` is read before any other
  symbol is looked up.
  - A major version other than 1 is refused with `LibraryLoadError`.
  - Any minor version is accepted.
  - A call added in a minor up to the library's own is required, and its
    absence is refused by name.
  - A call added in a later minor may be missing. It raises `KomiraError` only
    when it is used.
- **Call errors.** A failed call raises `KomiraError` with its status. The
  message is the context's last error, read with the two-call protocol: the
  first call learns the length, and the second passes a buffer of exactly that
  length.
- **Private calls.** `parquet_schema`, `csv_binding`, `json_binding` and
  `plan_render` exist only on `_native.Native`. They have no public API and no
  stability promise.

The tests run on Linux x86_64 as build actions, with
`./buck2 build //python/tests:load_test` and the same for
`//python/tests:session_test`, `//python/tests:minor0_test`,
`//python/tests:minor3_test`, `//python/tests:two_call_test`,
`//python/tests:runtime_test` and `//python/tests:cpu_test`:

| test | what it covers |
|---|---|
| `load_test` | loading and refusal, then the real `libkomira[runnable]` and its nine calls |
| `session_test` | the public surface on the real library |
| `minor0_test`, `minor3_test` | stand-ins of ABI 1.0 and 1.3 |
| `two_call_test` | the error path, the two-call protocol and the arguments of each call, on a stand-in |
| `runtime_test` | the runtime preload on stand-in directories: missing, wrong version, not loadable, present |
| `cpu_test` | the CPU check on cpuinfo files written from `tests/fixtures/cpuinfo_x86_64_v3.txt`, and that a refused CPU never opens the library |

The wheel is `./buck2 build //python:komira_wheel`: the package, libkomira at
`komira/_lib/libkomira.so` and its native owner libraries at
`komira/_lib/lib/`, requiring `mojo-compiler==1.0.0` and nothing else.
`./buck2 build //python:wheel_install_test` (and `:wheel_install_test_py314`
on CPython 3.14) installs it with Modular's two wheels into an empty virtual
environment, the way a wheel is installed for the other tests (no pip, no
network), and runs `tests/test_installed.py` there in isolated mode, from an
empty directory, with no library path set. That test holds:

| what | how |
|---|---|
| the installed package | `komira` imports from the environment, at the wheel's version, with `LICENSE` and `NOTICE` in `.dist-info/licenses/` |
| the runtime pin | the one `Requires-Dist`, `komira._runtime`, the toolchain's Mojo and the installed `mojo-compiler` are one version |
| the library | `abi_version()` is the version of `src/so/abi/komira.tsv`; a Parquet file registers, a missing one raises `KomiraError`; a serialized plan renders |
| where it loaded from | `/proc/self/maps` lists the three Mojo runtime libraries from `<site-packages>/modular/lib`, libkomira and its owners from `komira/_lib` |

Each `//python:refuses_*` target runs the same install and test on one broken
case and passes only if it fails with the line it names: no `libkomira.so` in
the wheel, owner libraries off libkomira's run path, no `mojo-compiler`
installed, a wheel tagged for another platform, an unmet requirement, a
`Requires-Python` the interpreter is outside of, and a toolchain Mojo other
than the pin.
