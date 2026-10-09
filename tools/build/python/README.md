# Hermetic Python

The package `komira//tools/build/python` holds the rules that give tests a
hermetic Python ([`defs.bzl`](defs.bzl)) and the two scripts their actions
run: [`pyrun.py`](pyrun.py), the runner of every `py_test`, and
[`wheel_install.py`](wheel_install.py), the installer of every
`python_wheel`, and [`oracle_run.py`](oracle_run.py), the runner of every
`python_oracle`. The interpreter and the wheels are pinned in
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
| `python_dist(name, archive, version, freethreaded, native_libs, preload)` | a CPython `install_only` archive (python-build-standalone) unpacked into one directory by busybox `tar`, with the packages of its `site-packages` (pip) removed. Fails unless `bin/python<major>.<minor>` (`bin/python<major>.<minor>t` with `freethreaded = True`) runs and prints `version`, followed by `t` exactly when the interpreter is a free-threaded build (`Py_GIL_DISABLED`) (`python_dist: the interpreter in <archive> is <got>, the pin says <version>[t]`): a free-threaded archive pinned without `freethreaded`, or the reverse, fails. `native_libs` is a directory of shared libraries, `preload` the paths in it a `py_test` loads before its script. |
| `python_wheel(name, distribution, version, wheel, python, deps)` | one wheel installed into a directory of its own by `wheel_install.py`, run with `python`: every member at its path, a `<name>-<version>.data/` directory's `purelib/` and `platlib/` merged in, its `scripts/`, `headers/` and `data/` left out. Fails unless the wheel holds exactly one `.dist-info` and that directory's name and its METADATA `Name` and `Version` are `distribution` and `version`. `deps` are the wheels it imports; a closure holding one distribution at two versions fails analysis. |
| `py_test(name, src, srcs, deps, args, expect_error, python, tzdata)` | runs `src` with the interpreter as a build action; its output (`<name>.pass`) exists only if the script passed, so building the target is running the test. `srcs` are staged next to `src` and importable from it, `deps` are `python_wheel` targets (each with its deps), `args` the script's arguments (`$(location ...)` expands). With `expect_error`, the script passes only if it raises an exception whose last traceback line (`Type: message`) is exactly that string. `python` defaults to `komira//third_party/python:cpython`; `tzdata` (default `komira//third_party/python:tzdata`) is the wheel whose `tzdata/zoneinfo` directory is the action's time-zone database ([Time zones](#time-zones)), and is in the closure whether or not `deps` names it. |
| `python_oracle(name, src, srcs, data, deps, args, outs, python, tzdata)` | runs `src` twice ([Oracles](#oracles)) and outputs the directory the first run wrote (`<name>/`), only if both runs wrote the same tree. Other targets take it as test data: the directory as `:<name>`, each `outs` path as the sub-target `:<name>[<path>]` (a Mojo library's `test_data`, a `py_test`'s `args` through `$(location ...)`). `data` is `{dest: source}` (or sources, each staged at its path from the cell root), staged in the data directory; `srcs` are staged next to `src`; `deps` are `python_wheel` targets; `args` are plain strings. Analysis fails if `src`, a `srcs` entry, a `data` source, a wheel of `deps` or the `python` dist was built by a target not under `third_party/`. `tzdata` is as in `py_test` (in the closure, so its wheel is checked too). |
| `python_proto(name, src)` | the module `<stem>_pb2.py` that the pinned protoc (`komira//tools/build/toolchains/proto:protoc`, 29.1) generates for one `.proto` with no imports, for a `py_test`'s `srcs` (staged next to its script, so `import <stem>_pb2`). protoc 29.1 writes Python gencode 5.29.1; the test `protobuf_gencode` holds the pinned protobuf runtime to it. |

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
  the C locale the interpreter runs in UTF-8 mode (PEP 540). `TZ=UTC0` (a
  `python_wheel` action has it too) is a POSIX rule: local time is UTC, and
  the C library reads no zone file for it, where an unset `TZ` would read the
  worker's `/etc/localtime`. `TZDIR` is the tzdata wheel's `zoneinfo`
  directory ([Time zones](#time-zones)).
- The verdict: exit 0 (or a `SystemExit` of 0 or `None`) passes; any other
  exit or exception fails, printing the traceback and
  `pyrun: <script> failed: <last line>`. With `--expect-error`, the script
  must raise and the last line must be equal; otherwise
  `pyrun: <script> was expected to fail with '<want>', it failed with '<got>'`
  or `... and it passed`.

## Oracles

A `python_oracle` computes, on the farm, an answer a komira test compares
against: DuckDB or pyarrow reading test data and writing files. Its action
runs

```
<dist>/bin/python3.13 -I -S oracle_run.py --out <name> --tmpdir <name>.tmp \
    --data <name>.data --preload ... --site <wheel dir> ... [--outs <path>]... \
    -- <script> <args>
```

- **The script's contract.** `sys.argv` is `[<script>, <output directory>,
  <data directory>, <args>...]`. The script writes files (and directories)
  under the output directory and reads its inputs from the data directory;
  its current directory and `tempfile`'s directory are a scratch directory
  of its own. `sys.path` is the script's directory, the standard library and
  the wheels' directories, as in a `py_test`.
- **Two runs.** `oracle_run.py` runs the script in two child interpreters,
  one after the other, the first writing into the output, the second into a
  directory under `<name>.tmp`. Each child is `python3.13 -s -S -P` with the
  environment `LC_ALL=C PYTHONHASHSEED=0 TZ=UTC0 TZDIR=<absolute>` and
  nothing else (`-I` would ignore `PYTHONHASHSEED`; the child refuses to run
  with a random hash seed), so the iteration order of a set of strings is the
  same in every run. Time zones come from the tzdata wheel as in a `py_test`
  ([Time zones](#time-zones)). The oracle
  passes only if the two trees hold the same paths, each a directory or a
  regular file, with the same bytes and executable bit; a symlink is
  refused. A clock, a random number, a process id or the output path
  written into a file makes the runs differ:
  `python_oracle: two runs of <script> differ at <path>: the bytes`. Two
  runs on one worker cannot see what is fixed on that worker: a listing in
  directory order (both runs list the same filesystem), the CPU count, the
  host name, a clock read at a coarse grain. Sort a listing before writing
  it. The test `oracle_twins` builds the same oracle as two targets, two
  actions, and compares their outputs.
- **outs.** With `outs`, the files written must be exactly those paths
  (`python_oracle: <script> wrote <path>, which outs does not declare`,
  `... did not write <path>`); without it, at least one file must be written
  (`... wrote nothing`). A failing script is `python_oracle: <script> failed:
  <last traceback line>`, also when it calls `sys.exit` with a status other
  than 0 or `None` (`SystemExit: 3`).
- **Inputs, and independence from komira.** An oracle reads only what it
  declares: `src`, `srcs`, `data`, the wheels of `deps` and the `python`
  dist (with its `native_libs`) are the action's inputs, and `args` are
  strings, so no `$(location ...)` adds one. Each of `src`, `srcs`, `data`,
  the wheels and the dist's directory, if an action built it (not a
  checked-in file), must be the output of a target under `third_party/` (a
  pinned download, a wheel, the interpreter); anything else fails analysis:
  `<oracle>: the oracle's data "<dest>" is built by <target>, which is not under third_party/; an oracle reads checked-in files and third_party/ outputs only, so that its answer cannot come from komira (tools/build/python/README.md, Oracles)`
  (likewise `srcs entry`, `src`, `wheel <name>` and `python`). Checked-in files are
  allowed anywhere, so a package's test data under `src/` is an input; a
  komira library, binary or generated file is not. Only direct inputs are
  checked: a `third_party/` target is trusted not to be built from komira,
  and the dist's `native_libs` come with the dist, so they are not checked
  apart from it.
  The interpreter can still open any absolute path on the worker; nothing
  stops a script that does.

### Test 51: Python oracles

Test 51 of [`tools/build/tests`](../tests/README.md) checks the
independence rule above: each target of
[`negative/python_oracle`](../tests/negative/python_oracle/BUCK) fails
analysis naming the input: a komira library's gated package as `data`, a
komira binary in `srcs` or as `src`, a wheel installed by a target outside
`third_party/` (as a dep or as the `tzdata` wheel) and an interpreter
unpacked outside it. The oracles that work, the runner's verdicts and a
welded Mojo test reading an oracle's output are in
[`src/tests/helpers/komira_test_python`](../../../src/tests/helpers/komira_test_python/README.md).

```sh
./buck2 build tests//negative/python_oracle:komira_data   # must fail: is built by komira//src/komira_encoding:komira_encoding, which is not under third_party/
```

## Host floor

What a Python action takes from the worker is the floor of every action
([toolchains/README.md](../toolchains/README.md#host-floor)): a Linux x86_64
kernel, an `x86-64-v3` CPU, and glibc (the interpreter needs 2.17, the
wheels at most 2.28). The test `isolation` checks it: once the native
module of every wheel that has one is mapped (it asserts each is, protobuf's
upb backend included), each file the process maps is under the action's
directory except glibc's own libraries. The time-zone database is not part
of the floor either ([Time zones](#time-zones)).

## Time zones

A `py_test` and each run of a `python_oracle` read every time zone from the
pinned tzdata wheel
([third_party/python](../../../third_party/python/README.md#the-closure)).
For a `py_test`:

- the rule sets `TZDIR` to the wheel's `tzdata/zoneinfo` directory, and
  `pyrun.py` makes it absolute in the environment, so the C library and ORC
  (pyarrow's ORC writer and reader take their writer's zone, `GMT`, from
  `TZDIR`) read it and no fixed path;
- `pyrun.py` makes that directory `zoneinfo`'s only search path
  (`zoneinfo.reset_tzpath`), replacing the interpreter's built-in one, which
  names `/usr/share/zoneinfo` and three other host directories. Python's
  `zoneinfo`, and so a zoned pyarrow array's `to_pylist()`, reads zones there.
  Run without `TZDIR`, `pyrun.py` sets the path empty, so `zoneinfo` reads
  only an importable `tzdata` package;
- `TZ=UTC0`: local time is UTC from a rule, not a file.

A `python_oracle` sets the same `TZDIR` and `TZ`; `oracle_run.py` passes them
to each child run (`TZDIR` made absolute, since the child changes directory)
and the child makes `TZDIR` `zoneinfo`'s only search path, or, without
`TZDIR`, an empty one. The test `oracle_cases` holds the runner's half; the
oracle `orc_timestamps` holds the rule's (it asserts the zone setup, then
writes an ORC timestamp column, which needs the `GMT` zone from `TZDIR`, and
its two runs must write the same bytes).

The test `timezones` holds all of it except the run without `TZDIR`, which
the test `runner_cases` holds (its scripts run with an empty environment).
One reader is outside it: Arrow C++'s
compute kernels that take a zone by name (`pyarrow.compute.assume_timezone`,
a cast of a zoned timestamp to a string, the field extractions of a zoned
timestamp) find the database through a path compiled into the pyarrow wheel
(`/usr/share/zoneinfo`) and read no variable. On a worker without that
directory they fail with
`ArrowInvalid: Cannot locate or parse timezone '<zone>': discover_tz_dir failed to find zoneinfo`;
on one with it they would read the worker's files. No test uses them; a
test that needs one converts in Python (`to_pylist()` and `zoneinfo`) or
with UTC offsets instead.

## Adding a wheel or a consumer

1. Pin the wheel in [`pins.bzl`](../../../third_party/python/pins.bzl): its
   name, version, URL, sha256 and size from PyPI's JSON API
   (`https://pypi.org/pypi/<name>/<version>/json`, the `urls` entry of the
   `cp313-cp313-manylinux_*_x86_64` or `py3-none-any` wheel), its SPDX
   licence, and its linux requirements as `deps`. A wheel of the CPython
   3.14 closures goes in `WHEELS_314`, once per ABI (`cp314-cp314` and
   `cp314-cp314t`), and in the 3.14 tests' tables instead.
2. Add it to `MODULES` in the smoke test and review its licence files; the
   tests `smoke` and `licenses` fail until both are done.
3. A package that uses the hermetic Python is one line of `_TEST_ONLY` in
   [`third_party/python/BUCK`](../../../third_party/python/BUCK).
