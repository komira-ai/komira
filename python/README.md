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

- **Linux on x86_64**, with glibc 2.35 or newer and an x86-64-v3 CPU (AVX2,
  BMI2, FMA: Intel Haswell, AMD Excavator or newer). Wheels for Linux on arm64
  and macOS on Apple silicon come in later releases.
- **Python 3.13 or newer.**
- **The system C++ runtime, `libstdc++`.** Most systems have it. A minimal
  container image may need the `libstdc++6` package (Debian, Ubuntu) or
  `libstdc++` (Fedora, RHEL).

### The two flavours

libkomira needs three Mojo runtime libraries, which are Modular's and come
under Modular's licence. The wheel is built in two flavours that differ only
in where those come from; a release publishes one of them, and the first
paragraph of this description says which one you have.

- **bundled**: the wheel carries libkomira, its native owner libraries and the
  three Mojo runtime libraries in `komira/_lib/`, with Modular's licence and
  third-party notices beside komira's own. Nothing else is installed with it:
  it declares no dependencies. The runtime libraries add about 2 MB
  uncompressed.
- **external**: the wheel carries libkomira and its native owner libraries and
  no file of Modular's. It requires Modular's `mojo-compiler` package at the
  Mojo version komira was built with (`mojo-compiler==1.0.0`), which `pip`
  installs with it from PyPI (about 79 MB) and which puts the runtime in
  `site-packages/modular/lib/`. komira loads it from there. If it is missing
  (for example after `pip install --no-deps`) or is another version,
  `komira.LibraryLoadError` says so and gives the `pip install` line that
  fixes it.

Both flavours have the same name, version scheme, tag and Python API.
`pip show komira` tells them apart: only the external one lists
`Requires: mojo-compiler`.

## What works

```python
import komira

print(komira.__version__)     # the installed version
print(komira.abi_version())   # the engine's C ABI version: 1001 is 1.1

with komira.Session() as s:
    s.register_parquet("readings", "readings.parquet")
    print("registered readings")
print(s.closed)               # True: the session is freed
```

This block is the file `python/examples/quickstart.py` of the source tree
(next to the `readings.parquet` it registers), which the release checks run
against the published package.

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
  A file of the package that is missing is reported the same way, with the
  loader's message naming the file.
- A process holds one Mojo runtime. `komira.LibraryLoadError` is also raised
  when a Mojo runtime library of another build is already loaded in the
  process, for example by Mojo code built with another Mojo version. Its
  message names the library and the directory it was loaded from.
- In the external flavour, `komira.LibraryLoadError` is also raised when
  Modular's `mojo-compiler` is not installed, or is another version than the
  one komira was built with. Its message names the missing or mismatched
  library, where it looked, and the `pip install` line that provides the
  right one.
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
| `komira/_errors.py` | `KomiraError`, `LibraryLoadError` and `UnsupportedCpuError` |
| `komira/_native.py` | the `ctypes` loader: `load(lib_dir=None)` and the `Native` it returns, with the nine calls of ABI 1.1 |
| `komira/_runtime.py` | `prepare(lib_dir)`, called before libkomira is opened: with the runtime inside the package, `check_loaded_runtime`, which compares the Mojo runtime libraries already loaded in the process with komira's copies by build id; without it, `load_installed_runtime`, which finds Modular's installed runtime, holds it to the record of `read_record` and opens it; and the GNU build id reader they use |
| `komira/_session.py` | `Session` |
| `komira/py.typed` | the PEP 561 marker |
| `BUCK` | `:komira`, the package's files as the directory its tests import from; `:komira_wheel_bundled` and `:komira_wheel_external`, the wheel's two flavours; `:mojo_runtime_record`, the external wheel's record of the runtime; `:wheel_install_test_<flavour>`, each installed into an empty environment; and the `refuses_*` and `beside_*` targets |
| `flavour.bzl` | `komira_wheel`, the wheel of one flavour, what each flavour holds, and `runtime_record` |
| `install_test.bzl` | the rules of the wheel's files and of the install test |
| `tests/` | the tests (`python_binding_test`), `fake_libkomira.c` and `fake_runtime_lib.c`, the stand-in libraries they load, `test_installed.py` and `wheel_install_run.py`, the install test and its driver, and `test_beside_modular.py`, the tests of komira loaded beside Modular's runtime |

How the loader behaves:

- **Where it looks.** `_native.load` opens `<lib_dir>/libkomira.so`. With no
  directory, it opens the package's own `_lib/libkomira.so`. No environment
  variable and no search of the working directory picks the library. It opens
  the file with `RTLD_LOCAL`. libkomira's run path, `$ORIGIN/lib:$ORIGIN`,
  finds the native owner libraries in `_lib/lib/`, and in the bundled wheel
  the three Mojo runtime libraries there too. A file of the package that is
  missing is a `LibraryLoadError` with the loader's message, which names the
  file.
- **What runs before the library opens.** `load` first calls
  `_native._check_cpu()`, then `_runtime.prepare(<lib_dir>)`. An error raised
  by either stops the load.
  - On Linux x86_64, `_check_cpu` reads the `flags` lines of `/proc/cpuinfo`
    and requires every flag of x86-64-v3, the level the library is compiled
    for there, on every processor: `pni` (SSE3), `ssse3`, `cx16`, `sse4_1`,
    `sse4_2`, `popcnt`, `lahf_lm`, `avx`, `avx2`, `bmi1`, `bmi2`, `f16c`,
    `fma`, `abm` (LZCNT) and `movbe`. A missing one raises
    `UnsupportedCpuError` naming it, instead of an illegal instruction inside
    the library; a file it cannot read raises `LibraryLoadError`. On other
    platforms it reads nothing.
- **Which runtime.** `prepare` uses the runtime inside the package when any
  of the three libraries is in `<lib_dir>/lib/`, or when there is no
  `<lib_dir>/mojo_runtime.tsv`: the runtime check below. Otherwise (the
  external wheel) it reads that record (the `mojo-compiler` requirement and
  each library's GNU build id, as the compiler that built libkomira ships
  them) and loads Modular's installed runtime:
  - A library already loaded must be the record's build, or it is a
    `LibraryLoadError`; one that is, is not opened again.
  - The others are found in `<dir>/modular/lib/` of the first absolute
    directory of `sys.path` that holds all three. None does: a
    `LibraryLoadError` naming the missing libraries, every directory searched
    and `pip install mojo-compiler==1.0.0`.
  - Each must have the record's build id, or it is a `LibraryLoadError`
    naming it, the directory and the same install line.
  - They are opened by path with `RTLD_LOCAL`, the library the others need
    first, so libkomira's NEEDED names then resolve to them.
  - On other platforms it does nothing.
- **The runtime check** (bundled). libkomira's NEEDED names for the Mojo runtime
  (`libMSupportGlobals`, `libAsyncRTRuntimeGlobals`, `libKGENCompilerRTShared`;
  `.so` on Linux) resolve to a library already loaded under the same name
  before any path is searched. So when other Mojo code is in the process,
  libkomira would bind to that code's runtime without a message. The check
  looks at each of the three names with `dlopen(name, RTLD_NOLOAD)` and reads
  the directory it came from with `dlinfo`.
  - Not loaded, or loaded from komira's own file: nothing to do.
  - Loaded from another file with the same GNU build id as komira's copy (the
    same Mojo build, such as the `mojo-compiler` 1.0.0 wheel): accepted, and
    libkomira uses that copy.
  - Another build id, or none: `LibraryLoadError` naming the library, the
    directory it was loaded from and komira's copy.
  - Komira's copy cannot be read while another is loaded: `LibraryLoadError`.
  - On other platforms it does nothing.
  - The runtime libraries are not opened with `RTLD_GLOBAL`: that would put
    komira's copy in the global scope, ahead of the definitions of other Mojo
    libraries. A process holds one Mojo runtime version, so Mojo code built
    with another version (for example `max` with `mojo-compiler` 1.2.0) cannot
    be loaded beside komira in either order.
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
| `runtime_test` | the runtime hook on stand-in runtime libraries: the bundled check (not loaded, same build id, another build id, no build id, komira's copy unreadable) and the build id reader; the external flavour's record and its refusals, Modular's runtime not installed, of another build, of the record's build (opened in order), unopenable or already loaded; and which of the two `prepare` runs |
| `cpu_test` | the CPU check on cpuinfo files written from `tests/fixtures/cpuinfo_x86_64_v3.txt`, and that a refused CPU never opens the library |

The wheel is `./buck2 build //python:komira_wheel_<flavour>`, `bundled` or
`external` (`flavour.bzl`; the release workflow builds the one its `flavour`
input names, `external` unless it is given another). Both are tagged
`py3-none-manylinux_2_35_x86_64` and start their description with a paragraph
naming the flavour.

- `:komira_wheel_bundled`: the package and, in `komira/_lib/`,
  `libkomira[dist]` whole: `libkomira.so`, and in `lib/` its native owner
  libraries and the three Mojo runtime libraries, taken from the toolchain's
  Mojo package so that runtime and compiler are one build. It declares no
  `Requires-Dist`, and carries Modular's licence and third-party notices
  beside komira's own (`Apache-2.0 AND LicenseRef-Modular-Proprietary`).
- `:komira_wheel_external`: the package, `libkomira.so` and its native owner
  libraries picked from the same directory, and `komira/_lib/mojo_runtime.tsv`,
  the record of the runtime's build ids written by `:mojo_runtime_record`
  from the same three libraries. It declares
  `Requires-Dist: mojo-compiler==1.0.0` (the toolchain's Mojo), carries
  komira's `LICENSE` and `NOTICE` only (`Apache-2.0`) and no file of Modular's.

`./buck2 build //python:wheel_install_test_<flavour>` (and
`:wheel_install_test_<flavour>_py314` on CPython 3.14) installs the wheel into
an empty virtual environment, the external one with Modular's `mojo-compiler`
wheels of third_party/modular, the way a wheel is installed for the other
tests (no pip, no network), and runs `tests/test_installed.py --flavour
<flavour>` there in isolated mode, from an empty directory, with no library
path set. That test holds:

| what | how |
|---|---|
| the installed package | `komira` imports from the environment, at the wheel's version |
| its flavour's metadata, none of the other's | `Requires-Dist` none (bundled) or `mojo-compiler==<the toolchain's Mojo>` (external); the `License-Expression` given; `.dist-info/licenses/` holding `LICENSE` and `NOTICE`, and for bundled Modular's `LICENSE` and `Third-Party-Notices`, each byte-equal to its source, and no other; the description's preface; the runtime record present (external) or absent (bundled) |
| nothing else | bundled: no `modular/` directory and no other distribution in the environment; external: no distribution but Modular's two, and no file under `komira/` named as a runtime library or byte-equal to a file of Modular's |
| the library | `abi_version()` is the version of `src/so/abi/komira.tsv`; a Parquet file registers, a missing one raises `KomiraError`; a serialized plan renders |
| where it loaded from | `/proc/self/maps` lists libkomira and its owners from `komira/_lib`, and the three Mojo runtime libraries from `komira/_lib/lib` (bundled) or `modular/lib` (external) |

Each `//python:refuses_*` target runs the same install and test on one broken
case and passes only if it fails with the line it names: no `libkomira.so` in
the wheel (`refuses_missing_libkomira`), owner libraries off libkomira's run
path (`refuses_owners_off_run_path`), a Mojo runtime library missing from the
wheel (`refuses_missing_runtime_library`), a wheel tagged for another platform
(`refuses_wheel_of_another_platform`), another distribution installed with the
bundled wheel (`refuses_other_distribution`), an unmet requirement
(`refuses_unmet_requirement`), a `Requires-Python` the interpreter is
outside of (`refuses_python_outside_requires_python`), the external wheel
without its requirement (`refuses_external_without_requirement`, the
installer's refusal; `refuses_external_without_modular`, installed with
`--no-deps`: the loader's error and install line), the external wheel beside
`mojo-compiler` 1.2.0 (`refuses_external_beside_other_mojo`: the build-id
refusal), and each flavour's wheel held to the other flavour
(`refuses_bundled_as_external`, `refuses_external_as_bundled`).

The `//python:beside_*` targets (and the two `external_beside_*` ones) load komira in a process that also holds
Modular's runtime from the `mojo-compiler` wheel, run by
`tests/test_beside_modular.py`:

| target | what it holds |
|---|---|
| `beside_modular_loaded_first` | the same Mojo version loaded first: libkomira binds to Modular's copy and works |
| `beside_modular_loaded_after` | komira loaded first, then Modular's `libKGENCompilerRTShared` of the same version: both work |
| `beside_other_mojo_loaded_first` | another Mojo version loaded first: the load is refused, naming the library |
| `beside_other_mojo_loaded_after` | komira loaded first, then another Mojo version: Modular's library fails to load with the loader's `undefined symbol`, and komira keeps working |
| `external_beside_modular_loaded_first` | the external wheel, the same Mojo version loaded first: the loader accepts it by the record's build ids, opens nothing more, and works |
| `external_beside_other_mojo_loaded_first` | the external wheel, another Mojo version loaded first: refused, naming the library and the build the record names |
| `refuses_modular_unlike_toolchain` | the `mojo-compiler` wheel handed to the test is not the toolchain's version, and the test refuses it |

`//tools/build/package/libkomira:libkomira_dist_load` loads a copy of the
`[dist]` directory from C, with no Python, no library path and nothing of
Modular's.
