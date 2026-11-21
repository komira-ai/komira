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
  BMI2, FMA: Intel Haswell, AMD Excavator or newer), or **macOS 11 or newer
  on Apple silicon** (arm64). A wheel for Linux on arm64 comes in a later
  release.
- **CPython 3.11, 3.12, 3.13 or 3.14.** One wheel serves all four, and each
  is tested (Supported Pythons, below).
- **On Linux, the system C++ runtime, `libstdc++`.** Most systems have it. A
  minimal container image may need the `libstdc++6` package (Debian, Ubuntu)
  or `libstdc++` (Fedora, RHEL). macOS has its own C++ runtime.

### What is in the wheel

libkomira needs three Mojo runtime libraries, which are Modular's and come
under Modular's licence. The wheel carries libkomira, its native owner
libraries (Linux only: on macOS they are linked into the dylib) and those
three Mojo runtime libraries in `komira/_lib/`, with Modular's licence and
third-party notices beside komira's own. Nothing else is installed with it: it
declares no dependencies. The runtime libraries add about 2 MB uncompressed.

The Linux wheel and the macOS wheel (macOS 11 or later, Apple silicon) are one
distribution, `komira`, with one version and the same Python API.

The install page,
[docs/install.md](https://github.com/komira-ai/komira/blob/main/docs/install.md),
says what each requirement means and what to do when the install or the first
load fails. What each release changed is in the
[changelog](https://github.com/komira-ai/komira/blob/main/python/CHANGELOG.md).

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
- `komira.UnsupportedCpuError`, a `LibraryLoadError`, is raised on Linux
  x86_64 only (the CPU guard does nothing on macOS) when the CPU lacks a flag of x86-64-v3, before the engine is loaded.
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
| `komira/_runtime.py` | `check_loaded_runtime`, called before libkomira is opened: it compares the Mojo runtime libraries already loaded in the process with komira's copies by build id, and the GNU build id reader it uses |
| `komira/_session.py` | `Session` |
| `komira/py.typed` | the PEP 561 marker |
| `BUCK` | `:komira`, the package's files as the directory its tests import from; `:komira_wheel`, the wheel; `:komira_wheel_macos_arm64`, the macOS wheel; `:wheel_install_test` and `:wheel_install_test_macos_arm64`, each installed into an empty environment; and the `refuses_*` and `beside_*` targets |
| `install_test.bzl` | the rules of the wheel's files and of the install test, and `python_versions`, the supported Pythons as JSON for the workflows |
| `pythons.bzl` | the supported Pythons, the one list of them (Supported Pythons, below) |
| `tests/` | the tests (`python_binding_test`), `fake_libkomira.c` and `fake_runtime_lib.c`, the stand-in libraries they load, `test_installed.py` and `wheel_install_run.py`, the install test and its driver, and `test_beside_modular.py`, the tests of komira loaded beside Modular's runtime |

### Supported Pythons

`pythons.bzl` lists the CPython minors the package supports, oldest first:
3.11, 3.12, 3.13 and 3.14. Each entry names the interpreter pinned for the
farm's tests (`third_party/python`) and the exact version a GitHub-hosted
runner installs with `actions/setup-python` on Linux x86_64 (the pinned
version) and on macOS arm64. Everything else is read from it:

- the wheel's `Requires-Python` (`>=` the oldest minor) and its
  `Programming Language :: Python` classifiers;
- the package's tests (`tests/BUCK`) and the wheel's install and upgrade tests
  (`BUCK`), one target per minor: `<name>` on CPython 3.13, `<name>_py311`,
  `<name>_py312` and `<name>_py314` on the others;
- `//python:supported_pythons[linux-x86_64]` and `[macos-arm64]`, the exact
  versions as JSON lists, which the release workflow's smoke jobs read to run
  one job per version.

Adding a minor is a line in `pythons.bzl` and its interpreter's pin in
`third_party/python/pins.bzl`. The one wheel, tagged `py3-none`, serves every
minor. On macOS, `actions/setup-python` has no build of the newer patch
releases of 3.11 and 3.12 (they are released as source alone), so the macOS
jobs install 3.11.9 and 3.12.10. The farm's macOS tests run CPython 3.13
alone.

How the loader behaves:

- **Where it looks.** `_native.load` opens `<lib_dir>/libkomira.so`
  (`libkomira.dylib` on macOS). With no directory, it opens the package's own
  `_lib/` copy. No environment
  variable and no search of the working directory picks the library. It opens
  the file with `RTLD_LOCAL`. libkomira's run path (`$ORIGIN/lib:$ORIGIN` on Linux,
  `@loader_path/lib` on macOS) finds the native owner libraries (Linux only:
  on macOS they are linked into the dylib) in `_lib/lib/`, and the three Mojo
  runtime libraries there too. A file of the package that
  is missing is a `LibraryLoadError` with the loader's message, which names
  the file.
- **What runs before the library opens.** `load` first calls
  `_native._check_cpu()`, then `_runtime.check_loaded_runtime(<lib_dir>/lib)`. An error raised
  by either stops the load.
  - On Linux x86_64, `_check_cpu` reads the `flags` lines of `/proc/cpuinfo`
    and requires every flag of x86-64-v3, the level the library is compiled
    for there, on every processor: `pni` (SSE3), `ssse3`, `cx16`, `sse4_1`,
    `sse4_2`, `popcnt`, `lahf_lm`, `avx`, `avx2`, `bmi1`, `bmi2`, `f16c`,
    `fma`, `abm` (LZCNT) and `movbe`. A missing one raises
    `UnsupportedCpuError` naming it, instead of an illegal instruction inside
    the library; a file it cannot read raises `LibraryLoadError`. On other
    platforms, macOS among them, it reads nothing.
- **The runtime check.** libkomira's NEEDED names for the Mojo runtime
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
  - On other platforms, macOS among them, it does nothing.
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

The tests below run on Linux x86_64 as build actions, with
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
| `runtime_test` | the runtime check on stand-in runtime libraries: not loaded, same build id, another build id, no build id, komira's copy unreadable, and the build id reader |
| `cpu_test` | the CPU check on cpuinfo files written from `tests/fixtures/cpuinfo_x86_64_v3.txt`, and that a refused CPU never opens the library |

The Linux wheel is `./buck2 build //python:komira_wheel`: the package and, in
`komira/_lib/`, `libkomira[dist]` whole: `libkomira.so`, and in `lib/` its
native owner libraries and the three Mojo runtime libraries, taken from the
toolchain's Mojo package so that runtime and compiler are one build. It is
tagged `py3-none-manylinux_2_35_x86_64`, declares no `Requires-Dist`, and
carries Modular's licence and third-party notices beside komira's own
(`Apache-2.0 AND LicenseRef-Modular-Proprietary`).

The macOS wheel is `//python:komira_wheel_macos_arm64`, built with
`--target-platforms komira//tools/build/platforms:darwin-arm64`. It has
the same package and metadata as `:komira_wheel` (including the licence
expression and the licence files, which are those of the pinned Linux package, the runtime libraries
being under the same Modular licence), and `libkomira[dist]` for macOS arm64,
which is `libkomira.dylib` and, in `lib/`, the three Mojo runtime libraries
(`libAsyncRTRuntimeGlobals.dylib`, `libKGENCompilerRTShared.dylib`,
`libMSupportGlobals.dylib`) and no native owner libraries. It is tagged
`py3-none-macosx_11_0_arm64`. It is
built and tested only in the release workflow (`.github/workflows/pypi.yml`),
never in a pull request, and a run publishes it only from main. After the upload, a GitHub-hosted macOS runner installs it from the
index and runs the smoke test.

`./buck2 build //python:wheel_install_test` (CPython 3.13; `:wheel_install_test_py311`,
`_py312` and `_py314` on the other supported Pythons) installs the wheel alone into an empty virtual environment, the
way a wheel is installed for the other tests (no pip, no network), and runs
`tests/test_installed.py` there in isolated mode, from an empty directory, with
no library path set. `//python:wheel_install_test_macos_arm64` runs the test on
the macOS wheel on the farm's macOS workers (CPython 3.13, the one macOS
interpreter pinned), from the release workflow only. That test holds:

| what | how |
|---|---|
| the installed package | `komira` imports from the environment, at the wheel's version |
| its metadata | no `Requires-Dist`; the `License-Expression` given; `.dist-info/licenses/` holding `LICENSE`, `NOTICE`, and Modular's `LICENSE` and `Third-Party-Notices`, each byte-equal to its source, and no other; the description starting with the first line of this README |
| nothing else | no `modular/` directory and no other distribution in the environment |
| the library | `abi_version()` is the version of `src/so/abi/komira.tsv`; a Parquet file registers, a missing one raises `KomiraError`; a serialized plan renders |
| where it loaded from | `/proc/self/maps` (on macOS, the images dyld has loaded) lists libkomira and its owners (none on macOS, where `lib/` holds exactly the three runtime `.dylib` files) from `komira/_lib`, and the three Mojo runtime libraries from `komira/_lib/lib` |

Each `//python:refuses_*` target runs the same install and test on one broken
case and passes only if it fails with the line it names: no `libkomira.so` in
the wheel (`refuses_missing_libkomira`), owner libraries off libkomira's run
path (`refuses_owners_off_run_path`), a Mojo runtime library missing from the
wheel (`refuses_missing_runtime_library`), a wheel tagged for another platform
(`refuses_wheel_of_another_platform`), another distribution installed with the
wheel (`refuses_other_distribution`), an unmet requirement
(`refuses_unmet_requirement`), and CPython 3.10, which the wheel's
`Requires-Python` (`>=3.11`) leaves out
(`refuses_python_outside_requires_python`).

`//python:upgrade_test` (and `_py311`, `_py312` and `_py314`) installs two releases of
the wheel one after the other into one environment, the way pip does, and
holds the result to what the install test holds of a fresh install, plus that
every file only the older release had is gone. Its refusals are a downgrade
(`refuses_downgrade`), an upgrade from nothing (`refuses_upgrade_from_nothing`)
and a second release installed without the upgrade
(`refuses_second_release_without_uninstall`). `//python:wheel_libs` reads the
finished wheel and walks its libraries as the loader would.

The `//python:beside_*` targets load komira in a process that also holds
Modular's runtime from the `mojo-compiler` wheel, run by
`tests/test_beside_modular.py`:

| target | what it holds |
|---|---|
| `beside_modular_loaded_first` | the same Mojo version loaded first: libkomira binds to Modular's copy and works |
| `beside_modular_loaded_after` | komira loaded first, then Modular's `libKGENCompilerRTShared` of the same version: both work |
| `beside_other_mojo_loaded_first` | another Mojo version loaded first: the load is refused, naming the library |
| `beside_other_mojo_loaded_after` | komira loaded first, then another Mojo version: Modular's library fails to load with the loader's `undefined symbol`, and komira keeps working |
| `refuses_modular_unlike_toolchain` | the `mojo-compiler` wheel handed to the test is not the toolchain's version, and the test refuses it |

`//tools/build/package/libkomira:libkomira_dist_load` loads a copy of the
`[dist]` directory from C, with no Python, no library path and nothing of
Modular's.
