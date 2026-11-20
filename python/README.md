# python: the Python package `komira`

The Python package over `libkomira`, komira's one shared library with a flat C
ABI ([`src/so`](../src/so/README.md)). Its layout, names and first API are
decided in [docs/design/python_package.md](../docs/design/python_package.md).
What is built so far is the loader; the session, `sql`, the Arrow terminals,
the wheel and its release come in later changes, so nothing here is shipped
yet and no public name runs a query.

## What is here

| path | what it is |
|---|---|
| `komira/__init__.py` | the public names, exactly `__all__`: `KomiraError` and `LibraryLoadError` today |
| `komira/_errors.py` | `KomiraError` (with `status`, the failed call's status code or `None`) and its subclass `LibraryLoadError` |
| `komira/_native.py` | the ctypes loader: `load(lib_dir)` and the `Native` it returns |
| `komira/py.typed` | the PEP 561 marker: the package's annotations are its types |
| `BUCK` | `:komira`, the package's files as the site directory its tests import (`python_source_package`) |
| `tests/` | the tests (`python_binding_test`) and `fake_libkomira.c`, the stand-in library they refuse |

## The loader

`_native.load(lib_dir=None)` opens `<lib_dir>/libkomira.so` (`libkomira.dylib`
on macOS) with ctypes; with no directory it opens the package's own `_lib/`,
where a wheel will stage the library. Nothing else picks the library: no
environment variable, no search of the working directory.

- **The ABI major version.** `komira_abi_version()` is read before any other
  function is looked up. A version whose major (`version // 1000`) is not 1, or
  a negative one, raises `LibraryLoadError` with the version the library
  reported: `libkomira at <path> has ABI version 2.0; this package needs major 1`.
- **The functions.** `komira_ctx_new`, `komira_ctx_free`, `komira_last_error`
  and `komira_register_parquet` are bound with the types of
  [`abi/komira.tsv`](../src/so/abi/komira.tsv); a library without one is
  refused by name (`libkomira at <path> has no symbol <name>`). A file that
  cannot be opened is `cannot load libkomira from <path>: <the loader's message>`.
- **One library per process.** The first load that succeeds is kept: loading the
  same file again returns the same `Native`, and another file is refused
  (`libkomira is already loaded from ...`). A refused load leaves nothing
  loaded. The library is never closed (the Mojo runtime cannot be unloaded), and
  a refused one stays mapped.
- **Errors of a call.** A status other than 0 raises `KomiraError` with
  `status` set and the context's last error, unchanged, as the message. The text
  is read with the two-call protocol: a call with capacity 0 learns the length,
  the second gets a buffer of exactly that length. An empty last error gives
  `<function> failed with status N and no message`; a last error that cannot be
  read gives `<function> failed with status N; its last error could not be
  read: <why>`, and a length that changes between the two calls is never read
  as an answer. Bytes that are not UTF-8 read as U+FFFD.
- **Arguments.** A string argument that is not a `str` raises `TypeError`, and
  one holding a NUL byte `ValueError`, before the library is called; a path may
  be an `os.PathLike`.

## Tests

```sh
./buck2 build //python/tests:load_test //python/tests:two_call_test
```

- `load_test` loads, in one process: the package's own `_lib/` (absent, so
  refused), a directory with no library, stand-ins of ABI version 2.0, 0.999
  and -1, and one without `komira_register_parquet`, each refused with its exact
  message; then `//src/so:libkomira[runnable]`, which loads with version 1001,
  is the same library when loaded again by a `str` or a `pathlib.Path`, and makes
  another file's load refused. On it two contexts are distinct, a missing
  Parquet file is a `KomiraError` of status -3 whose message is the last error,
  that error is the first context's only, and registering a Parquet file clears
  it.
- `two_call_test` drives the stand-in `fake_modes`: the second call of the
  protocol gets the capacity the first reported, a call's own status is kept
  (-2 and -3), text that is not UTF-8, an empty last error, a length that grows
  or shrinks between the calls, a second call that fails, a `komira_last_error`
  that fails on its first call, the `TypeError` and `ValueError` of the
  arguments, and a `komira_ctx_new` that returns NULL.

Linux x86_64 only, like every `python_binding_test`
([tools/build/python](../tools/build/python/README.md#binding-tests)).
