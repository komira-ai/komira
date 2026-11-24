# komira

komira is a SQL query engine that runs in your process. This package is its
Python binding: it carries `libkomira`, the engine as one shared library, and
calls it with `ctypes`.

**This is an early release.** It registers Parquet files as tables and runs
SQL over them, and it hands each answer to pyarrow. The DataFrame APIs come
later.

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
third-party notices beside komira's own. It requires one other distribution,
`pyarrow>=25.0.1`, which a result is read as; `pip install komira` installs it.
The runtime libraries add about 2 MB uncompressed.

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
print(komira.abi_version())   # the engine's C ABI version: 1005 is 1.5

with komira.Session() as s:
    s.register_parquet("readings", "readings.parquet")
    print(s.sql("SELECT 1 AS n").to_arrow().to_pylist())
    result = s.sql("SELECT count(*) AS n, sum(value) AS total FROM readings")
    print(result.to_arrow().to_pylist())   # a pyarrow Table, as Python rows
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
  - Registering a name again replaces the table.
- `Session.sql(query)` runs one SQL statement over the session's tables and
  returns a `komira.Result`. The engine turns the text into a plan before
  `sql` returns, so a syntax error, an unknown table or column, or a construct
  the engine does not run yet raises `KomiraError` from `sql`, with the
  engine's `<step>: <reason>` message.
- A `Result` is read once, by one of:
  - `to_arrow()`, the whole answer as a `pyarrow.Table`;
  - `to_reader()`, a `pyarrow.RecordBatchReader` that reads batches as they
    are asked for;
  - `__arrow_c_stream__()`, the Arrow PyCapsule interface, so
    `pyarrow.table(result)` and other Arrow libraries read it with no copy. A
    requested schema raises `KomiraError`.

  Reading it a second time raises `KomiraError`: run the query again. A
  result still reads after its session is closed, and one never read frees
  its answer when it is garbage collected.
- A session is a context manager. `close()` frees it and can be called again,
  and `closed` says whether it was. Any other call on a closed session raises
  `KomiraError`.
- A session may be used from several threads. Its calls run one at a time: a
  call made while another thread's call runs on the same session waits for it
  to return. `close()` waits too, so a session is never freed under a running
  call. Two sessions run their calls at once, so a session per thread is how
  to run queries in parallel. A call made from a signal handler or a finalizer
  while a call of the same thread is running on that session raises
  `KomiraError` instead of waiting for itself. A `Result` reads without the
  session, so reading one never waits for a call on its session; of two
  threads that read one `Result`, one reads it and the other gets the
  already-read `KomiraError`.
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

The engine is loaded on the first `Session()` or `abi_version()` call, and
pyarrow during the first `Session.sql` call the engine accepts, when the
answer's schema is read; neither on `import komira`.

## What does not work yet

- Results as pandas or polars frames (`to_pandas`, `to_polars`).
- The module-level `komira.sql` and `komira.register_parquet` on a default
  session.
- Cancelling a query. A query cannot be interrupted while it runs: Ctrl-C
  during `Session.sql` raises `KeyboardInterrupt` when the engine has finished
  the query. The answer is freed, and the session runs the next query.
- The DataFrame APIs: one shaped like pandas and one shaped like polars.
- Registering CSV and JSON files.
- Iceberg tables: reading one, and writing to one by its name in a catalog.

The two DataFrame APIs come in a later release of this same package.

## Working on the package

Most readers can skip this section.

The package's layout and API are designed in
[docs/design/python_package.md](https://github.com/komira-ai/komira/blob/main/docs/design/python_package.md).

| path | what it is |
|---|---|
| `komira/__init__.py` | the public names, exactly `__all__` |
| `komira/_capture/` | the capture of Python user functions (private; no query runs them yet): `udf`, the decorator that records a function's call shape (`scalar`, `map_batches_column`, `row`, `map_batches_frame`), its return type (`return_dtype=`, `schema=` or the type hints) and, for `row` and `map_batches_frame`, its read set (`columns=`, a `TypedDict` or dataclass annotation, or for `row` a scan of the function's bytecode, refused with `UDF_READ_SET_REQUIRED` when the reads are not bounded); `Udf.spec()`, the `UdfSpec` the plan encodes, with the function's code as a bundle named by its sha256 or as a reference into an installed distribution; and `write_code`, which writes each code object under its digest. Calling a decorated function calls the function, which is how the komira/python worker runs it. It imports no `ctypes` |
| `komira/_credentials.py` | the credential objects (private; nothing public takes one yet): `AwsKeys`, `AwsProfile`, `GcpServiceAccount`, `GcpToken`, `AzureKey`, `AzureSas`, `BearerToken` and `OAuth2ClientCredentials`, each a name and its fields, checked when built (the name's grammar and reserved names; each value a non-empty `str` of at most 4096 bytes of UTF-8), with every secret shown as `<set>` by `repr` and no pickle or copy; and the built-in `AMBIENT` and `ANONYMOUS` ([docs/design/credentials_and_writes.md](https://github.com/komira-ai/komira/blob/main/docs/design/credentials_and_writes.md), decision 1) |
| `komira/_iceberg.py` | the Iceberg sources (private; nothing public takes one yet): `iceberg(uri, *, warehouse=None, credential=AMBIENT, signing=None, access_delegation="vended-credentials")`, an `IcebergCatalog`; `catalog.table(name)`, an `IcebergTable`, with `name` as `"namespace.table"` or a tuple of namespace levels and the table; and `SigV4(region, service)`. Each is checked when built (an http or https URI with a host and no user, password, query or fragment; a credential that fits the catalog: `AMBIENT` or `AwsKeys` with SigV4, and `AMBIENT`, `ANONYMOUS`, `BearerToken` or `OAuth2ClientCredentials` without; `access_delegation` `vended-credentials` or `none`), does no I/O and loads no library; a catalog or a table shows its credential's secrets as `<set>` and refuses pickle and copy ([docs/design/iceberg_tables.md](https://github.com/komira-ai/komira/blob/main/docs/design/iceberg_tables.md), "What the user sees") |
| `komira/_arrow.py` | the Arrow C stream of a query: `ArrowArrayStream`, the C struct for `ctypes`, and `import_stream`, which hands a filled stream to pyarrow's public `RecordBatchReader.from_stream` through a PyCapsule with no destructor, and releases it itself if pyarrow did not take it |
| `komira/_errors.py` | `KomiraError`, `LibraryLoadError`, `UnsupportedCpuError`, and the private `UnsupportedOperation` and `CredentialsError` |
| `komira/_native.py` | the `ctypes` loader: `load(lib_dir=None)` and the `Native` it returns, with the calls of ABI 1.3 (`sql_stream` among them) |
| `komira/_plan/` | the plan encoder: `encode_plan`, a plan of `komira/_ops` as the `komira.plan.v1` `WirePlanEnvelope` the plan door takes, every node with the output schema the engine derives for it and every scan reading a source libkomira described (`parquet_source`, `binding_source`); calls of user functions (`UdfCall`, `MapBatches`) as `WireUdfApply` and `WireMapBatchesNode` over the envelope's `UdfRef` list, one per distinct function, each with the komira/python descriptor; `encode_expr`, an expression node as a `WireExpr`; and `expr_field`, the output field the engine derives for it. It writes no SQL text. It imports the generated plan modules, which the wheel does not ship yet, so `import komira` does not import it |
| `komira/_runtime.py` | `check_loaded_runtime`, called before libkomira is opened: it compares the Mojo runtime libraries already loaded in the process with komira's copies by build id, and the GNU build id reader it uses |
| `komira/_session.py` | `Session` with `sql`, `Result`, and the session's private `_seal_credential`, which defines a credential on the session through `komira_credential_add`, `_set` and `_seal` |
| `komira/py.typed` | the PEP 561 marker |
| `BUCK` | `:komira`, the package's files as the directory its tests import from; `:komira_with_plan_modules`, the same with the generated plan modules at `komira/plan/v1/`, for the plan encoder's tests; `:komira_wheel`, the wheel; `:komira_wheel_macos_arm64`, the macOS wheel; `:wheel_install_test` and `:wheel_install_test_macos_arm64`, each installed into an empty environment; and the `refuses_*` and `beside_*` targets |
| `install_test.bzl` | the rules of the wheel's files and of the install test, and `python_versions`, the supported Pythons as JSON for the workflows |
| `pythons.bzl` | the supported Pythons, the one list of them (Supported Pythons, below) |
| `tests/` | the tests (`python_binding_test`, and `py_test` for the plan encoder: `test_plan_expr.py`, `test_plan_expr_goldens.py`, `test_plan_rel.py`, `test_plan_rel_goldens.py`, `test_plan_udf.py`, `test_plan_udf_goldens.py` and `test_plan_no_sql.py`), `fake_libkomira.c` and `fake_runtime_lib.c`, the stand-in libraries they load, `test_installed.py` and `wheel_install_run.py`, the install test and its driver, `test_tpch_installed.py` and `tpch_compare.py`, TPC-H q1 to q22 at scale factor 1 through the installed wheel against DuckDB's recorded answers (`:tpch_via_wheel_test`; its answer check is held by `test_tpch_compare.py`), `test_analysis_job.py`, which runs `examples/analysis_job.py` from the installed wheel and compares its answers with DuckDB's (`:analysis_job_test`), and `test_beside_modular.py`, the tests of komira loaded beside Modular's runtime |

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
  versions as JSON lists, from which `pypi_smoke matrix` writes the job matrix
  of the wheel's user test and of the index smoke (in pypi.yml, and in
  pypi-macos-arm64.yml for the macOS wheel): one job per version. `//python/smoke:supported_pythons_lists` holds both
  lists to the versions it writes out.

Adding a minor is a line in `pythons.bzl` and its interpreter's pin in
`third_party/python/pins.bzl`. The one wheel, tagged `py3-none`, serves every
minor. On macOS, `actions/setup-python` has no build of the newer patch
releases of 3.11 and 3.12 (they are released as source alone), so the macOS
jobs install 3.11.9 and 3.12.10. The farm's macOS tests run CPython 3.13
alone.

How the loader behaves:

- **Where it looks.** `_native.load` opens `<lib_dir>/libkomira.so`
  (`libkomira.dylib` on macOS), or, when the directory holds a `VARIANTS`
  manifest, the CPU-level variant `_native._select_variant` picks (below).
  With no directory, it opens the package's own `_lib/` copy. No environment
  variable and no search of the working directory picks the library. It opens
  the file with `RTLD_LOCAL`. libkomira's run path (`$ORIGIN/lib:$ORIGIN` on Linux,
  `@loader_path/lib` on macOS) finds the native owner libraries (Linux only:
  on macOS they are linked into the dylib) in `_lib/lib/`, and the three Mojo
  runtime libraries there too. A file of the package that
  is missing is a `LibraryLoadError` with the loader's message, which names
  the file.
- **What runs before the library opens.** `load` first checks the CPU, with
  `_native._select_variant(<lib_dir>)` when the directory holds a `VARIANTS`
  manifest and `_native._check_cpu()` when it does not, then calls
  `_runtime.check_loaded_runtime(<lib_dir>/lib)`. An error raised by either
  stops the load.
  - From a directory with a manifest (docs/design/isa_variants.md, decision
    5), the loader opens the last line, the highest level, whose features the
    `flags` (x86_64) or `Features` (aarch64) lines of `/proc/cpuinfo` list on
    every processor. A CPU without the features of the first line, the floor,
    raises `UnsupportedCpuError` naming them. A manifest it cannot read or
    parse, an unreadable cpuinfo, or a missing chosen file raises
    `LibraryLoadError`; a lower level is never loaded in place of a missing
    one. The wheel carries no manifest yet.
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
    same Mojo build, such as the `mojo-compiler` wheel of the toolchain's
    version): accepted, and
    libkomira uses that copy.
  - Another build id, or none: `LibraryLoadError` naming the library, the
    directory it was loaded from and komira's copy.
  - Komira's copy cannot be read while another is loaded: `LibraryLoadError`.
  - On other platforms, macOS among them, it does nothing.
  - The runtime libraries are not opened with `RTLD_GLOBAL`: that would put
    komira's copy in the global scope, ahead of the definitions of other Mojo
    libraries. A process holds one Mojo runtime version, so Mojo code built
    with another version (for example `max` with `mojo-compiler` 1.2.0) does
    not work beside komira: loaded first, komira refuses it; loaded after, a
    newer runtime fails to load, and an older one (not yet run: inferred from
    its symbols) loads on komira's libraries.
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
  length. An engine refusal (-3) of a credential call, which the library
  answers only with `CREDENTIALS_INVALID`, raises `CredentialsError`, a
  `KomiraError`; the package never parses the message to choose the class.
- **Private calls.** `parquet_schema`, `csv_binding`, `json_binding`,
  `plan_render`, `credential_add`, `credential_set` and `credential_seal`
  exist only on `_native.Native`. They have no public API and no stability
  promise.

The tests below run on Linux x86_64 as build actions, with
`./buck2 build //python/tests:load_test` and the same for
`//python/tests:session_test`, `//python/tests:minor0_test`,
`//python/tests:minor3_test`, `//python/tests:two_call_test`,
`//python/tests:credentials_test`, `//python/tests:credentials_lib_test`,
`//python/tests:iceberg_test`, `//python/tests:sql_test`,
`//python/tests:sql_fake_test`, `//python/tests:sql_interrupt_test`,
`//python/tests:threads_test`,
`//python/tests:runtime_test` and `//python/tests:cpu_test`:

| test | what it covers |
|---|---|
| `load_test` | loading and refusal, then the real `libkomira[runnable]` and its nine calls |
| `session_test` | the public surface on the real library |
| `minor0_test`, `minor3_test` | stand-ins of ABI 1.0 and 1.3: a 1.0 library refuses `sql` by the ABI version it needs |
| `sql_test` | `Session.sql` on the real library: `SELECT 1 AS n`, a GROUP BY over a checked-in Parquet file, an aggregate, an answer of no rows, each terminal, the engine's refusals, and a result read after its session was closed or collected |
| `sql_fake_test` | `Session.sql` on a stand-in Arrow stream that counts releases: a result read once, each stream, schema and batch released exactly once whoever ends it, a requested schema refused, a schema error raised from `sql` and a batch error from the terminal, the argument checks, and results left unread at exit |
| `sql_interrupt_test` | Ctrl-C during `Session.sql`, on a stand-in whose `komira_sql_stream` raises SIGINT in the calling thread: `KeyboardInterrupt` once the call returns, the stream it filled released exactly once, the session answering the next query (also after a refusal SIGINT came during), a handler that does not raise running once while `sql` returns the answer, and an ignored SIGINT changing nothing |
| `threads_test` | a session used from several threads, on a stand-in that journals each call and holds one at a gate: a call waits for the call running on its session, each thread gets its own error message, `close` waits for the running call, two sessions run at once, a signal handler calling the session inside a call is refused, a `Result` reads while its session is busy, and of two threads reading one `Result` one reads it |
| `two_call_test` | the error path, the two-call protocol and the arguments of each call, on a stand-in |
| `credentials_test` | the credential objects, and what sealing each sends the library, on a stand-in's fake store that records every credential call |
| `iceberg_test` | the Iceberg catalog, table and SigV4 values, with no library: each argument's checks and refusals with their full messages, which credential fits a catalog with and without SigV4, how a table name splits, repr, and no pickle or copy |
| `credentials_lib_test` | sealing every kind of credential on the real library, and each of its refusals as a `CredentialsError` with its `CREDENTIALS_INVALID` message |
| `runtime_test` | the runtime check on stand-in runtime libraries: not loaded, same build id, another build id, no build id, komira's copy unreadable, and the build id reader |
| `cpu_test` | the CPU check on cpuinfo files written from `tests/fixtures/cpuinfo_x86_64_v3.txt`, and that a refused CPU never opens the library |

The Linux wheel is `./buck2 build //python:komira_wheel`: the package and, in
`komira/_lib/`, `libkomira[dist]` whole: `libkomira.so`, and in `lib/` its
native owner libraries and the three Mojo runtime libraries, taken from the
toolchain's Mojo package so that runtime and compiler are one build. It is
tagged `py3-none-manylinux_2_35_x86_64`, declares the one `Requires-Dist`
`pyarrow>=25.0.1` (`PYARROW_REQUIREMENT`, `dependencies.bzl`), and
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
built and tested only in its release workflow (`.github/workflows/pypi-macos-arm64.yml`),
never in a pull request, and a run publishes it only from main. After the upload, a GitHub-hosted macOS runner installs it from the
index and runs the smoke test.

`./buck2 build //python:wheel_install_test` (CPython 3.13; `:wheel_install_test_py311`,
`_py312` and `_py314` on the other supported Pythons) installs the wheel and the pinned pyarrow
25.0.1 wheel of that Python into an empty virtual environment, the
way a wheel is installed for the other tests (no pip, no network), and runs
`tests/test_installed.py` there in isolated mode, from an empty directory, with
no library path set. `//python:wheel_install_test_macos_arm64` runs the test on
the macOS wheel on the farm's macOS workers (CPython 3.13, the one macOS
interpreter pinned), from the release workflow only. That test holds:

| what | how |
|---|---|
| the installed package | `komira` imports from the environment, at the wheel's version |
| its metadata | the `Requires-Dist` `pyarrow>=25.0.1` and no other; `Requires-Python` `>=3.11` and exactly the classifiers `python/BUCK` writes out (`_PYTHON_METADATA`: the four supported minors); the `License-Expression` given; `.dist-info/licenses/` holding `LICENSE`, `NOTICE`, and Modular's `LICENSE` and `Third-Party-Notices`, each byte-equal to its source, and no other; the description starting with the first line of this README |
| nothing else | no `modular/` directory and no distribution in the environment but komira and pyarrow |
| the library | `abi_version()` is the version of `src/so/abi/komira.tsv`; a Parquet file registers, a missing one raises `KomiraError`; `SELECT 1 AS n` and an aggregate over `examples/readings.parquet` answer their rows through pyarrow; a serialized plan renders |
| where it loaded from | `/proc/self/maps` (on macOS, the images dyld has loaded) lists libkomira and its owners (none on macOS, where `lib/` holds exactly the three runtime `.dylib` files) from `komira/_lib`, and the three Mojo runtime libraries from `komira/_lib/lib` |

Each `//python:refuses_*` target runs the same install and test on one broken
case and passes only if it fails with the line it names: no `libkomira.so` in
the wheel (`refuses_missing_libkomira`), owner libraries off libkomira's run
path (`refuses_owners_off_run_path`), a Mojo runtime library missing from the
wheel (`refuses_missing_runtime_library`), a wheel tagged for another platform
(`refuses_wheel_of_another_platform`), another distribution installed with the
wheel (`refuses_other_distribution`), an unmet requirement
(`refuses_unmet_requirement`), the wheel without pyarrow
(`refuses_missing_requirement`), a pyarrow wheel of another CPython minor
(`refuses_requirement_of_another_minor`), a wheel whose `Requires-Dist` is
another range (`refuses_requires_dist_not_the_declared_range`), a wheel whose classifiers leave out 3.11
(`refuses_classifiers_not_the_supported_pythons`) or whose `Requires-Python`
starts at 3.12 (`refuses_requires_python_not_the_oldest_supported`), and
CPython 3.10, which the wheel's
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
| `beside_other_mojo_loaded_after` | komira loaded first, then another Mojo version: a newer one fails to load with the loader's `undefined symbol`, an older one loads as a second `libKGENCompilerRTShared` on komira's two other libraries (first run at a 1.1.0 or 1.2.0 toolchain; inferred from symbols until then), and komira keeps working |
| `refuses_modular_unlike_toolchain` | the `mojo-compiler` wheel handed to a same-version case is not the toolchain's version, and the test refuses it |
| `refuses_other_mojo_at_toolchain` | the `mojo-compiler` wheel handed to an other-version case is the toolchain's version, and the test refuses it |

The toolchain's Mojo picks the versions: the pair at its version and the
compiler wheel of the newest other version in
`third_party/modular/pins.bzl`.

`//tools/build/package/libkomira:libkomira_dist_load` loads a copy of the
`[dist]` directory from C, with no Python, no library path and nothing of
Modular's.
