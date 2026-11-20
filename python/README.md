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

- **Linux on x86_64**, with glibc 2.34 or newer and a CPU with AVX2. Wheels for
  Linux on arm64 and macOS on Apple silicon come in later releases.
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
| `komira/_errors.py` | `KomiraError` and `LibraryLoadError` |
| `komira/_native.py` | the `ctypes` loader: `load(lib_dir=None, *, search_path=None)` and the `Native` it returns, with the nine calls of ABI 1.1 |
| `komira/_runtime.py` | `_preload_runtime_libraries(search_path)`, called before libkomira is opened; it loads nothing yet |
| `komira/_session.py` | `Session` |
| `komira/py.typed` | the PEP 561 marker |
| `BUCK` | `:komira`, the package's files as the directory its tests import from |
| `tests/` | the tests (`python_binding_test`) and `fake_libkomira.c`, the stand-in libraries they load |

How the loader behaves:

- **Where it looks.** `_native.load` opens `<lib_dir>/libkomira.so`. With no
  directory, it opens the package's own `_lib/libkomira.so`. No environment
  variable and no search of the working directory picks the library.
- **What runs before the library opens.** `load` first calls
  `_native._check_cpu()`, then `_runtime._preload_runtime_libraries(search_path)`.
  Both do nothing yet. An error raised by either stops the load.
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
`//python/tests:minor3_test` and `//python/tests:two_call_test`:

| test | what it covers |
|---|---|
| `load_test` | loading and refusal, then the real `libkomira[runnable]` and its nine calls |
| `session_test` | the public surface on the real library |
| `minor0_test`, `minor3_test` | stand-ins of ABI 1.0 and 1.3 |
| `two_call_test` | the error path, the two-call protocol and the arguments of each call, on a stand-in |
