# Hermetic Python

The package `komira//tools/build/python` holds the rules that give tests a
hermetic Python ([`defs.bzl`](defs.bzl)) and the two scripts their actions
run: [`pyrun.py`](pyrun.py), the runner of every `py_test`, and
[`wheel_install.py`](wheel_install.py), the installer of every
`python_wheel`. The interpreter and the wheels are pinned in
[`third_party/python`](../../../third_party/python/README.md); the tests
of all of it are
[`src/tests/helpers/komira_test_python`](../../../src/tests/helpers/komira_test_python/README.md).

Python here is test-only: live oracles (pyarrow and DuckDB computing the
answer a Mojo test compares against) and drivers of komira's Python-facing
surfaces. Nothing built with these rules is shipped
([third_party/python](../../../third_party/python/README.md#never-shipped)).

## Rules

| rule | what it builds |
|---|---|
| `python_dist(name, archive, version, native_libs, preload)` | a CPython `install_only` archive (python-build-standalone) unpacked into one directory by busybox `tar`, with the packages of its `site-packages` (pip) removed. Fails unless `bin/python<major>.<minor>` runs and prints `version` (`python_dist: the interpreter in <archive> is <got>, the pin says <version>`). `native_libs` is a directory of shared libraries, `preload` the paths in it a `py_test` loads before its script. |
| `python_wheel(name, distribution, version, wheel, python, deps)` | one wheel installed into a directory of its own by `wheel_install.py`, run with `python`: every member at its path, a `<name>-<version>.data/` directory's `purelib/` and `platlib/` merged in, its `scripts/`, `headers/` and `data/` left out. Fails unless the wheel holds exactly one `.dist-info` and that directory's name and its METADATA `Name` and `Version` are `distribution` and `version`. `deps` are the wheels it imports; a closure holding one distribution at two versions fails analysis. |
| `py_test(name, src, srcs, deps, args, expect_error, python)` | runs `src` with the interpreter as a build action; its output (`<name>.pass`) exists only if the script passed, so building the target is running the test. `srcs` are staged next to `src` and importable from it, `deps` are `python_wheel` targets (each with its deps), `args` the script's arguments (`$(location ...)` expands). With `expect_error`, the script passes only if it raises an exception whose last traceback line (`Type: message`) is exactly that string. `python` defaults to `komira//third_party/python:cpython`. |

The macros set `exec_compatible_with` to the linux x86_64 execution
platform: every action runs the linux interpreter.

## What an action runs

```
<dist>/bin/python3.13 -I -S pyrun.py --out <name>.pass --tmpdir <name>.tmp \
    --preload <native_libs>/lib/libgcc_s.so.1 --preload ... \
    --site <wheel dir> ... [--expect-error <line>] -- <script> <args>
```

- `-I` (isolated mode): no `PYTHON*` environment variable, no user site
  directory, and the runner's own directory is not put on `sys.path`. `-S`:
  the `site` module is not imported, so no `site-packages` directory and no
  `.pth` file is read. A wheel that needs its `.pth` processed does not work
  here.
- `pyrun.py` loads each `--preload` library by path (`RTLD_GLOBAL`), in
  order. The loader resolves a library an extension module needs to the
  object already loaded under that soname, so `libstdc++.so.6`,
  `libgcc_s.so.1` and `libz.so.1` come from the pinned conda-forge packages,
  not from the worker.
- `sys.path` is the script's directory, then the archive's standard
  library, then each `--site` directory. `tempfile` writes under `--tmpdir`,
  which is emptied when the script passes.
- The environment is `LC_ALL=C`, so the interpreter does not coerce the C
  locale to C.UTF-8 (PEP 538), which would map the worker's locale files; in
  the C locale the interpreter runs in UTF-8 mode (PEP 540).
- The verdict: exit 0 (or a `SystemExit` of 0 or `None`) passes; any other
  exit or exception fails, printing the traceback and
  `pyrun: <script> failed: <last line>`. With `--expect-error`, the script
  must raise and the last line must be equal; otherwise
  `pyrun: <script> was expected to fail with '<want>', it failed with '<got>'`
  or `... and it passed`.

## Host floor

What a Python action takes from the worker is the floor of every action
([toolchains/README.md](../toolchains/README.md#host-floor)): a Linux x86_64
kernel, an `x86-64-v3` CPU, and glibc (the interpreter needs 2.17, the
wheels at most 2.28). The test `isolation` checks it: once the native
module of every wheel that has one is mapped (it asserts each is, protobuf's
upb backend included), each file the process maps is under the action's
directory except glibc's own libraries. The time-zone database is not part
of it: a script that asks `zoneinfo` for a zone reads the worker's
`/usr/share/zoneinfo` (no test does).

## Adding a wheel or a consumer

1. Pin the wheel in [`pins.bzl`](../../../third_party/python/pins.bzl): its
   name, version, URL, sha256 and size from PyPI's JSON API
   (`https://pypi.org/pypi/<name>/<version>/json`, the `urls` entry of the
   `cp313-cp313-manylinux_*_x86_64` or `py3-none-any` wheel), its SPDX
   licence, and its linux requirements as `deps`.
2. Add it to `MODULES` in the smoke test and review its licence files; the
   tests `smoke` and `licenses` fail until both are done.
3. A package that uses the hermetic Python is one line of `_TEST_ONLY` in
   [`third_party/python/BUCK`](../../../third_party/python/BUCK).
