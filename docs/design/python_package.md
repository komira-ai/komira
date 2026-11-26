# The Python package: layout, names and first API

Status: design, partly built. The allowlist entry that admits the package (`python` in `PYTHON_SURFACE`,
[tests/python_closure_allowlist.bzl](../../tests/python_closure_allowlist.bzl)) landed with this document.
Release 1's surface is built ([python/README.md](../../python/README.md)): the loader, `Session` with
`register_parquet` and `close`, `abi_version()`, `__version__`, `KomiraError`, `LibraryLoadError`
and `UnsupportedCpuError`, and their tests. The linux-x86_64 wheel is built and carries `libkomira`, its native
owners and the Mojo runtime libraries in one directory (decision 6), so `pip install komira` needs no package of
Modular's. `Session.sql` and `Result` are built, with `to_arrow`, `to_reader`, `to_pandas`, `to_polars` and
`__arrow_c_stream__` (a result still reads after its session is closed), and the wheel requires pyarrow;
the wheel declares no `pandas` or `polars` extra yet (its rule writes no `Provides-Extra`), so the
`ImportError` of a missing one names the distribution (`pip install pandas`) until it does.
`Session.register_csv(name, path, *, delimiter=",", header=True, all_varchar=False)` and
`Session.register_json(name, path)` are built (`komira_register_csv` and `komira_register_json`,
ABI 1.5): decision 4's CSV and NDJSON registration, from the engine's own schema. The default session,
the per-session lock and the fork hook are not built. The error table of decision 9 is built:
`KomiraError` carries `status`, `code` and `step` from `libkomira` ABI 1.7, and `ParseError`,
`BindError`, `UnsupportedOperation`, `CredentialsError` and `StorageError` are public;
the linux-arm64 and macos-arm64 wheels are not built.

## Release 1

The first release on PyPI is smaller than the first public API of [decision 3](#3-the-first-releases-public-api):
it installs, imports and loads `libkomira` at ABI 1.1, and nothing in it runs a query, because the
library's run call does not exist yet.

- Its public names are `__version__`, `abi_version()` (the library's `komira_abi_version()`, loading the
  library if needed), `KomiraError`, `LibraryLoadError`, `UnsupportedCpuError`
  and `Session`. `Session()` takes no argument and has `register_parquet(name, path)`, `close()`, `closed` and the context-manager methods. `Session.sql`, `Result`,
  the module-level `sql` and `register_parquet`, and `UnsupportedOperation` arrive with the run call.
- The per-session lock and the `os.register_at_fork` hook of decision 3's behaviour list are not built
  yet; they come with `Session.sql`, the first call that runs long enough to need them.
- It has no dependency on pyarrow: no call returns Arrow data until `Session.sql`. pyarrow becomes a
  dependency with the Arrow terminals, as decision 7 lists.
- It has no dependency on any other distribution: the Mojo runtime libraries are in the wheel (decision 6).
- The calls of ABI 1.1 that return protobuf bytes or plan text (`komira_parquet_schema`,
  `komira_csv_binding`, `komira_json_binding`, `komira_plan_render`) are bound only as private methods of
  `komira._native.Native`: they have no Python type yet and no public API.
- The loader accepts any minor of ABI major 1. A call added in a later minor than the library's is
  missing, and raises `KomiraError` when it is used, so one wheel loads on 1.1 and on later minors.
- There is no `python/pyproject.toml`: the wheel rule takes the metadata of decision 7 from its BUCK
  attributes.

## What problem does this solve?

People should be able to `pip install komira` and run SQL over their local files from Python. komira has
no Python package today: Python in this repository is test-only, and the one Python surface is the hello
test of `python_binding_test` ([tools/build/python/README.md](../../tools/build/python/README.md)). The
shared library `libkomira` ([src/so/README.md](../../src/so/README.md)) is what the package will load,
and the Node addon ([node/README.md](../../node/README.md)) is the precedent for a binding over it.

The work that builds the package is split over several pull requests (the loader, the session, error
mapping, the wheel rule, the release member). Each of them needs the same answers first: where the package
lives, what it and its modules are called, which names are public, which parts of the earlier,
never-published Python SDK are carried over, and what its metadata says. This document gives those
answers. It does not decide the C ABI (symbols and status codes), the wheel's platform tags and CPython
range, or the DataFrame surface; each has its own design, named under
[What is decided elsewhere](#what-is-decided-elsewhere).

Fixed before this design and not reopened here: the distribution (the name on PyPI, the name `pip install`
takes) is `komira`, the same as the import package (`komira-ai` is the organisation's name only: the GitHub
organisation, the PyPI organisation account and the mopm namespace; PyPI has one flat namespace); it is
published by the top-level workflow
`.github/workflows/pypi.yml` (the Linux wheel's jobs and the macOS arm64 wheel's jobs, two independent chains of
one file) through the GitHub environments `testpypi` and `pypi`, by trusted
publishing with no token, and nothing is uploaded or registered by hand. The owner has given the go to release `komira` from that workflow
before the DataFrame surfaces exist, so the name is registered on PyPI by the first release the workflow
makes, and no one registers or uploads it any other way; the package lives in `python/` in this repository; it is published as a wheel first; the wheel
carries `libkomira`, its native owners and the Mojo runtime libraries the library loads, and depends on no
package of Modular's (decision 6); the release platforms are linux-x86_64,
linux-arm64 and macos-arm64; the first public API is SQL-first and the DataFrame surfaces follow (the first
release on PyPI comes before it, with no query call and no pyarrow: [Release 1](#release-1)). The design of the SDK is settled
and is a port of the earlier one: two DataFrame surfaces, one shaped like pandas and one shaped like polars,
each only building a logical plan and submitting it through the plan entry of `libkomira`
(`komira_plan_stream`), never rendering it to SQL text; SQL text is a different entry
(`komira_sql_stream`), where the library converts it to a logical plan;
Python UDFs run in zygote worker processes ([udf_runtime_interface.md](udf_runtime_interface.md)).

## The decisions

### 1. Where the package lives

```
python/
  BUCK              the package's sources as one target, its tests' targets, later the wheel target
  README.md         what the package is, how it is built and tested (the package doc, like node/README.md)
  CHANGELOG.md      the releases it keeps, newest first (decision 7, The changelog)
  changelog.d/      one file `<slug>.md` of bullets for each change no kept release holds yet
  changelog/        the Zig tool that assembles them and the wheel's description
  komira/           the import package
    __init__.py     the public names, and nothing else (decision 3)
    py.typed        the PEP 561 marker (decision 8)
    _native.py      the ctypes loader: opens libkomira, checks the ABI major version
    _runtime.py     the check of a Mojo runtime already loaded in the process (decision 6)
    _session.py     Session, Result, the default session
    _errors.py      KomiraError and its subclasses
    _arrow.py       the Arrow C stream import
    _lib/           not in the repository: the wheel rule copies libkomira's directory here (decision 6)
  tests/
    BUCK            python_binding_test targets
    test_*.py
```

- **`python/` is one Buck2 package tree, top level, beside `node/`.** It is not a `src/<pkg>`:
  `src/` holds Mojo libraries, each checked by `src_layout` against
  [docs/architecture.md](../architecture.md), and a Python package is not one of them. `node/` is the
  precedent for a binding at the top level.
- **The surface entry is `python`.** The graph check `//:python_closure` allows a finding whose package
  or path is `python` or under `python/` (the `under` match of
  [python_closure.zig](../../tools/build/selftest/graph/python_closure.zig): equal, or a prefix ending at
  a `/`). So `python/komira/*.py`, `python/tests/*.py` and every target under `python/` are allowed, and
  nothing else is: `third_party/python` does not start with `python/`, and a package of another cell at
  the same path is not in the surface. The pull-request aggregate's guard
  ([tools/build/ci/ci_graph.bzl](../../tools/build/ci/ci_graph.bzl), `python_findings`) reads the same
  list, so the package's tests are in the pull request's set, as the binding tests are today.
- **Tests live in `python/tests/`**, run as `python_binding_test` targets against
  `//src/so:libkomira`, each script loading the library from the `--lib-dir` it is given. They are the
  only Python tests of the package (rule T11 allows Python tests for the Python SDK surface).
- **The generated protobuf modules were not in the first release.** They came with the DataFrame
  (decision 4), and live where their proto package puts them, `komira/plan/v1/`
  (`package komira.plan.v1;` in [src/plan_proto/plan.proto](../../src/plan_proto/plan.proto)): protoc
  writes `from komira.plan.v1 import ...` into the generated code, and the earlier SDK nested them there
  for that reason. `komira.plan` is then a package without public names: nothing in `__all__` comes from
  it, and its README line says so.

### 2. Module names

- The distribution and the import package are both `komira`: users run `pip install komira` and write
  `import komira` (the design docs write `import komira as km`;
  [storage_stack.md](storage_stack.md), [optimized_plan_sources.md](optimized_plan_sources.md) §15.9).
  - The name is the product's name, the one every design doc and every other SDK (`km.` in Mojo and
    TypeScript) already uses;
  - the generated protobuf modules must import as `komira.plan.v1` (decision 1), so the import name has to
    be `komira`;
  - the wheel's file name (`komira-<version>-...`) and `.dist-info` directory are spelt from the
    distribution name by the normalisation of PEP 427 and PEP 503.
  Messages that tell a user what to install name the distribution (`pip install komira[pandas]`);
  `__version__` and these hints read the distribution's name, which equals the import package's.
- Every module other than `komira/__init__.py` starts with an underscore and is private. A user imports
  public names from `komira` only; a private module may be split, merged or renamed in any release.
- No public submodule ships in the first release. The DataFrame surfaces are two, as in the earlier SDK:
  the pandas-shaped one at the top level of `komira`, and the polars-shaped one as the submodule
  `komira.pl`, which is the one public submodule the package will have. Both arrive with the DataFrame
  surface (decision 4), not in the first release. Their verbs and refusal policy are the DataFrame
  surface's design. The names that design must keep are the ones the design docs already use
  at the top level: `read_parquet`, `read_table`, `col` (verb names are the same words in every
  language, [optimized_plan_sources.md](optimized_plan_sources.md) §15.9). This design reserves them by
  not using them for anything else.

### 3. The first release's public API

The whole public surface of the first release is these names in `komira.__all__`:

| name | what it is |
|---|---|
| `Session(*, threads=None, memory_limit=None)` | one engine context (`komira_ctx_new`) and its registered tables. `threads` is the worker count and `memory_limit` the engine's memory budget in bytes; `None` takes the engine's default. Options are arguments, never environment variables (rule S2). A later keyword, `ca_file=None`, adds trusted roots for `https://` reads ([credentials_and_writes.md](credentials_and_writes.md) decision 9). A context manager: `with komira.Session() as s:`; `close()` frees the context and is idempotent |
| `Session.register_parquet(name, path)` | registers a local Parquet file as the table `name` (`komira_register_parquet`). `path` is a `str` or `os.PathLike`; a relative path is resolved against the working directory when the call is made, `~` is expanded. Registering a name again replaces it |
| `Session.sql(query) -> Result` | runs one SQL statement over the session's tables through the SQL entry of the library (`komira_sql_stream`), which parses and binds the text to a logical plan. **This is the official door of the first release**, not an escape hatch |
| `Result` | the answer of one `sql` call: `to_arrow() -> pyarrow.Table`, `to_reader() -> pyarrow.RecordBatchReader`, `to_pandas()`, `to_polars()`, and `__arrow_c_stream__(requested_schema=None)` (the Arrow PyCapsule interface, so `pyarrow.table(r)`, `polars.from_arrow(r)` and DuckDB take the stream itself; no batch is converted in Python) |
| `sql(query) -> Result`, `register_parquet(name, path)` | the same two calls on the process's default session (decision 5). `add_sql_binding(name, source)` joins them with the sources and credentials of [credentials_and_writes.md](credentials_and_writes.md), which also gives `sql` its later forms `sql(query, /, **sources)` and `sql(source, query, /, **sources)`; the first release takes the query alone |
| `KomiraError` | the base class of every error the package raises on purpose (decision 9) |
| `UnsupportedOperation` | a `KomiraError`: komira refused a construct by name (an SQL feature the engine does not run yet, an option it does not take) |
| `ParseError` | a `KomiraError`: the SQL text does not parse (`SQL_SYNTAX_ERROR`) |
| `BindError` | a `KomiraError`: a name in the statement does not resolve, or the statement binds wrongly (`SQL_BIND_ERROR`, `BIND_*`) |
| `CredentialsError` | a `KomiraError`: a credential is unbound, in conflict, of the wrong kind, not found or invalid (`CREDENTIAL_*`, `CREDENTIALS_*`) |
| `StorageError` | a `KomiraError`: an object store or a local write failed (`STORAGE_NOT_FOUND`, `STORAGE_ACCESS_DENIED`, `STORAGE_IO` and their kin) |
| `LibraryLoadError` | a `KomiraError`: `libkomira` or a library it needs could not be loaded, or its ABI major version is not the one this package was written for. That includes a file missing from the package (the message is the loader's and names the file) and a Mojo runtime of another build already loaded in the process (decision 6) |
| `UnsupportedCpuError` | a `LibraryLoadError`: on Linux x86_64 the CPU lacks a flag of x86-64-v3, the level `libkomira` is compiled for there (or, from a directory of CPU-level variants, a flag of its lowest variant, [isa_variants.md](isa_variants.md)), so the library is not opened; the message names the missing flags |
| `__version__` | the installed distribution's version, read with `importlib.metadata.version("komira")` (the distribution's name) |

Behaviour each later pull request implements, fixed here so they agree:

- **`sql` fails early.** `sql` opens the result stream before it returns, so a syntax error, an unknown
  table or column, and a refusal at binding, optimizing or lowering raise from `sql` itself. An error
  while batches are produced raises from the terminal that reads them.
- **A `Result` is read once.** Its stream is consumed by the first terminal (`to_arrow`, `to_reader`,
  `to_pandas`, `to_polars`, `__arrow_c_stream__`); a second one raises `KomiraError` saying the result was
  already read. Running `sql` again is how to read it again. Hiding a second read behind a cached table
  would make a large result's memory use depend on which terminal was called first. Calling
  `__arrow_c_stream__` counts as reading: the capsule is made on the call and owns the stream from then
  on, whether or not its consumer reads it. A `requested_schema` other than `None` raises
  `UnsupportedOperation`; casting on request is a later, additive decision.
- **pandas and polars are optional.** `to_pandas` and `to_polars` import them when called; when one is
  missing, the `ImportError` names the extra that installs it (`pip install komira[pandas]`). Until the
  wheel declares the extras, it names the distribution (`pip install pandas`).
- **A closed session refuses every call** with `KomiraError`, and closing a session while a `Result` of
  it is unread never crashes the interpreter. Whether that unread result then still reads, or refuses, is
  the session pull request's choice, held by a test of each case it allows.
- **One session, any thread.** A `Session` may be used from several threads; it holds a lock around each
  call into the library, the read of a failed call's last error included, so one context never runs two
  calls at once. A `Result`'s batch reads take no lock: the stream needs neither the session nor its
  context ([src/so/README.md](../../src/so/README.md), Running SQL), so a thread reading a result never
  holds up a call on its session. A call made on the thread that holds the lock (from a signal handler or
  a finalizer) raises `KomiraError` rather than waiting for itself. With call bindings
  ([credentials_and_writes.md](credentials_and_writes.md) decision 8), the lock is held from the first
  staged call binding through the `komira_sql_stream` that consumes it. Sessions are independent of one another. The lock goes when the ABI design states
  that a context is safe to share.
- **Fork.** A child process made by `os.fork` must not use a session of its parent: the package
  registers an `os.register_at_fork` hook that marks every session of the parent closed in the child, so
  a call there raises `KomiraError` instead of running on a copied context. The package never forks;
  UDF workers are the engine's, not this package's.
- **Ctrl-C during a query** cancels it. A ctypes call keeps its thread in the library, and Python runs a
  signal's handler only on the main thread between bytecodes, so `Session.sql` makes
  `komira_sql_stream_run` on a helper thread under a run handle of its own (src/so/README.md, "Cancel
  and progress") and the calling thread waits for it, waking every 50 ms. Whatever is raised on the
  calling thread while it waits (the `KeyboardInterrupt`, or the exception of a `progress` callback)
  cancels the handle; the thread then waits for the call to return, drops a stream the call made,
  frees the handle and raises the exception again, with the session's lock held throughout, so the
  context never has two calls at once and the next call finds it free. A second Ctrl-C while the run
  stops is dropped. On a library older than ABI 1.6 the query runs on the calling thread and Ctrl-C is
  delivered when it returns, the answer freed.
- **Progress** is polled, never called back from the library: the waiting thread reads the run handle's
  segment counts and calls the `progress` callback, on the calling thread, when they change.
- **Logging** goes to the standard logger `"komira"`, with a `NullHandler`; no query text.

### 4. What is carried from the earlier SDK, and what is not

The earlier SDK (`komira` 0.0.1, never published) was a ctypes wrapper over one Mojo shared library with
a pandas-shaped and a polars-shaped DataFrame surface. What happens to each part:

| part | first release | later | not carried, and why |
|---|---|---|---|
| ctypes loader (`_native.py`): load by path, ABI version check, status codes and last error to exceptions | yes, as `_native.py`, against `libkomira`'s ABI | | its lookup by environment variable and the walk up the working directory to a build output: see decision 6 |
| `Session`: context manager, `close`, one context per session | yes | | the `plan_wire` argument (below) |
| `Session.sql` | yes, as the official door returning a `Result` | | its status as "escape hatch, goes away with the scaffolding": SQL is now the first release's whole query surface |
| default session and module-level calls | yes, for `sql` and `register_parquet` (and `add_sql_binding` when it lands) | the DataFrame readers | the public `session()` accessor: a second way to reach the same object |
| table registration | `register_parquet(name, path)`, with the name required; CSV and NDJSON registration, from the engine's own schema (`register_csv(name, path, *, delimiter, header, all_varchar)`, `register_json(name, path)`) | | automatic names (`t1`, `t2`, ...): SQL needs the name the user wrote |
| `KomiraError` with the engine's status and message | yes, with the fields of decision 9 | | the `PLAN_ENDPOINT_<NAME>(<code>):` message prefix and its generated code table: libkomira's status codes and error text replace them |
| `UnsupportedOperation` | yes, now a `KomiraError` (it was a `TypeError`) | | |
| pandas-shaped `DataFrame`, `Column`, `Expr`, `GroupBy`, `MaterializedFrame`; the shared plan builder `Query`; the protobuf plan encoder | | with the DataFrame surface, through the plan door (`komira_plan_stream`) | |
| polars-shaped `komira.pl` (`col`, `lit`, lazy frames over the same plan builder) | | with the DataFrame surface, on the same plan builder and door as the pandas-shaped one | |
| **the SQL-text route** (`_sql.py`: DataFrame operations rendered to SQL text and re-parsed) | | | dropped. A DataFrame becomes a plan, never SQL text; `sql()` is SQL the user wrote, and is not that route |
| **the route switch**: `Session(plan_wire=...)` and the environment variable that chose the SQL-text route | | | dropped. There is one route per kind of input, so there is nothing to switch; and configuration is never an environment variable (rule S2) |
| `@komira.udf` and `Session.declare_sql_udf` | | Python UDFs in zygote worker processes | the in-process `ctypes` callback the engine called per batch: Python UDFs run in worker processes |
| Excel calls (`xl_*`), the second result door (`plan_bytes`), `sql_render` | | | not in the first release's ABI; a text rendering of a plan is a later, separate decision |
| warming pyarrow before opening the library | | | the Arrow import goes through the PyCapsule interface or pyarrow's public C stream import; the load-order case it worked around is a test of the Arrow terminals pull request |

#### The DataFrame surfaces, and where the port differs

The DataFrame surfaces are carried, not redesigned. Each frame holds a logical plan that a shared plan
builder grows one verb at a time; a terminal encodes the plan as `komira.plan.v1` protobuf bytes and
submits them to `komira_plan_stream`, which answers an Arrow stream, so a `Result` (decision 3) is what a
terminal returns. The pandas-shaped and the polars-shaped surface differ in spelling only; neither has
a path of its own to the engine. `Session.sql` is the separate entry for SQL the user wrote. The port
differs from the earlier SDK in these points, each for the reason given:

- **No SQL-text route and no switch between routes.** The earlier SDK could render a frame to SQL and
  re-parse it, chosen by `plan_wire` and an environment variable. Here the plan door is the only route
  for a frame, so a frame's answer never depends on SQL rendering, and rule S2 holds.
- **The plan builder targets the current plan format.** It is written against
  [src/plan_proto/plan.proto](../../src/plan_proto/plan.proto) and its generated `komira.plan.v1` modules,
  not the earlier tree's encoder, so a plan from the Python package is one every engine accepts (rule
  B21), and the protobuf dependency enters with this surface (decision 7).
- **Libraries' status codes, not `PLAN_ENDPOINT_*` prefixes.** A refusal of the plan door raises the
  `KomiraError` of decision 9, with the library's `status`, `code` and `step`.
- **Tables are registered by name.** A frame's plan scans tables the session has under a name the user
  gave (`register_parquet`); the earlier automatic `t1`, `t2` names are dropped (decision 4's table).
- **Errors and reads follow the first release's rules.** `UnsupportedOperation` is a `KomiraError`;
  a terminal reads once, as a `Result` does; a frame is bound to its session's lock and fork rules
  (decision 3).
- **No in-process UDF callback and no Excel calls.** Python UDFs run in worker processes
  ([udf_runtime_interface.md](udf_runtime_interface.md)); a frame that names one refuses by name until
  that lands.

### 5. The default session

`komira.sql` and `komira.register_parquet` (and later `komira.add_sql_binding`) use one `Session` per process, created with default options on
the first call. The package does not close it; the operating system reclaims it at exit, as it does the
library, which is never unloaded (decision 6). A user who wants options or a second set of tables
creates a `Session`. There is one default per process, not per thread: a table registered on it is
visible from every thread, as a module-level name would be.

### 6. Finding the library, with no environment variable

The macOS arm64 wheel (`//python:komira_wheel_macos_arm64`, macOS 11 or later on Apple silicon, tagged
`py3-none-macosx_11_0_arm64`) is built from its own `[dist]` directory and its own pinned compiler. It is built
and tested only by the macOS jobs of pypi.yml, never in a pull request (`//python:wheel_install_test_macos_arm64`, on
the farm's macOS workers), and a run publishes it only from main.

- An installed package loads `komira/_lib/libkomira.so`. The wheel carries
  `//src/so:libkomira[dist]` whole at `komira/_lib/`: `libkomira.so`, and in `_lib/lib/` the native owners
  and the three Mojo runtime libraries. The runtime libraries are the ones of the toolchain's pinned
  `mojo-compiler` package that compiled libkomira, so runtime and compiler match by construction. `[dist]`
  is `[runnable]` without the C++ runtime (`libstdc++.so.6`, `libgcc_s.so.1`); `[runnable]` keeps it,
  because build workers have none. On macOS arm64 `[dist]` is `libkomira.dylib` and, in `lib/`, the three
  runtime `.dylib` files, with no owners (the C archives are linked into the dylib) and no C++ runtime; its
  run path is `@loader_path/lib`.
- The library's run path (`$ORIGIN/lib:$ORIGIN`,
  [tools/build/mojo/README.md](../../tools/build/mojo/README.md)) resolves the owners and the runtime in
  `_lib/lib/`, so the loader sets no search path and preloads nothing. It opens `<dir>/libkomira.so` with
  `RTLD_LOCAL`. A file missing from the package raises `LibraryLoadError` with the loader's own message,
  which names the file.
- **The runtime check.** Before the open, `komira._runtime.check_loaded_runtime` looks, for each of the
  three runtime names, for a copy already loaded in the process (`dlopen(name, RTLD_NOLOAD)`, its
  directory from `dlinfo`). A copy from the package's own file is fine. A copy from another file is
  accepted when its GNU build id equals the package's (the same build, for example Modular's PyPI
  `mojo-compiler` at the toolchain's version beside the package); a different or absent build id raises `LibraryLoadError`
  saying the library is already loaded from that directory as another build and that a process holds one
  Mojo runtime. The check runs on Linux and does nothing elsewhere.
- **Two Mojo runtimes in one process** (read from the pinned files and glibc's loader, and run by the
  `//python:beside_*` targets). The three libraries have `DT_SONAME` equal to the file name, default
  visibility for every defined symbol and no symbol versioning. glibc matches a `NEEDED` name against the
  name and SONAME of every loaded object before it searches any path, whatever the `RTLD_LOCAL` or
  `RTLD_GLOBAL` of the earlier open; opening a different file by absolute path maps a second copy.
  - Modular's runtime imported first, same version: libkomira binds to Modular's copy and the package's
    copy is never mapped. The build ids are equal, so the check accepts it.
  - The package's library first, then Modular's `libKGENCompilerRTShared.so` by path, same version: a
    second KGEN is mapped, and its `NEEDED` runtime libraries bind to the package's copies. Both work.
  - Another Mojo version imported first (`mojo-compiler` 1.2.0, which `max` 26.7.0 requires, beside a
    package built with 1.0.0): without the check, libkomira would bind silently to that runtime. The
    check refuses by name instead, whichever version is the newer.
  - Another Mojo version imported after libkomira: a newer Modular KGEN fails to load with the loader's
    `undefined symbol` (1.2.0's needs `AsyncRT` and `Globals` symbols the 1.0.0 libraries lack), and
    libkomira keeps working. An older one (1.0.0 or 1.1.0 beside a package built with 1.2.0) finds every
    `M::` symbol it needs in the package's newer libraries, so it loads as a second KGEN bound to them,
    and libkomira keeps working (INFERRED from the symbols, not yet run: no target is at a 1.2.0
    toolchain; [mojo_runtime_pypi_vs_conda.md](mojo_runtime_pypi_vs_conda.md)). Neither
    can be made safe: one process holds one Mojo runtime version, so `import max` beside komira works
    only while both were built with the same Mojo version.
  - Why not `RTLD_GLOBAL` for the package's runtime: it would put the package's KGEN in the global scope,
    where its default-visibility definitions interpose the ones other Mojo libraries bring. Why not
    renaming the sonames: it means modifying Modular's binaries, and two copies of the Globals libraries
    would mean two allocators, two CPU-device tables and two fault handlers, the state those libraries
    exist to prevent.
- **Upgrading, and moving the Mojo pin.** `pip install --upgrade komira` uninstalls the old release's files
  (its `RECORD`) and installs the new one, so a file the new release no longer carries (a runtime library a
  new Mojo renamed, for example) is gone and `_lib/` is whole again. `//python:upgrade_test` installs two releases of the wheel one after the other into
  one environment the way pip does and holds the
  result to everything `//python:wheel_install_test` holds of a fresh install, plus that every file
  only the older release had is gone. A libkomira beside another build's runtime is not made by an upgrade:
  the wheel carries the runtime that built its libkomira, both out of one `[dist]` directory. The mixed case is in a
  process: another Mojo build's runtime already loaded when libkomira opens is refused by name
  (`//python:beside_other_mojo_loaded_first`, the runtime check above). To move the Mojo pin: change
  `mojo_compiler` in `tools/build/platforms/table.bzl` for every platform row. The wheel carries the
  runtime of the new pin with no other edit, the conda packages' `mojo-compiler ==<v>` follows
  `MOJO_COMPILER_VERSION` (`tools/build/package/conda.bzl`), and the `beside_*` tests take Modular's
  wheels of the pin's version and of the newest other version from `third_party/modular/pins.bzl`, which
  must hold a row for the new version (`python/BUCK` does not load without one). The wheel rule refuses a
  wheel whose runtime needs more glibc or C++ runtime than the limits in `_NATIVE_NEEDS` (`python/BUCK`).
- Tests load the library their target staged: the private `_native.load(lib_dir)` takes the directory a
  `python_binding_test` passes as `--lib-dir`. It is an argument of a private function, not a user setting.
- There is no lookup by environment variable (`KOMIRA_NATIVE_LIB`, `KOMIRA_NATIVE_LIBDIR` and the
  `CONDA_PREFIX` scan of the earlier SDK) and no search of the working directory for a build output. A
  wheel that loaded a library from somewhere the user's environment pointed would answer with a library
  no test of that wheel ran.
- The library is opened once per process and never closed: the Mojo runtime does not support unloading
  ([node/README.md](../../node/README.md)).

### 7. Metadata

The `[project]` table below is the one source of the wheel's `METADATA`; it is written as TOML here, and the wheel rule takes it as BUCK
attributes, with no `python/pyproject.toml` ([Release 1](#release-1)). The wheel is written by a Buck2
rule, not by a PEP 517 build backend: an sdist cannot build `libkomira`, so none is published. The table, with the values the
later designs fill marked:

```toml
[project]
name = "komira"
dynamic = ["version"]   # stamped by the wheel rule
description = "SQL over local files, with libkomira, the komira query engine, in process"
readme = "README.md"   # the wheel's description is this file followed by the assembled changelog (below)
requires-python = ">=3.11"   # the oldest CPython the package's tests run (python/pythons.bzl)
license = "Apache-2.0 AND LicenseRef-Modular-Proprietary"
license-files = ["LICENSE", "NOTICE", "MODULAR_LICENSE", "MODULAR_THIRD_PARTY_NOTICES"]
authors = [{ name = "The komira authors" }]
keywords = ["sql", "arrow", "parquet", "query-engine"]
classifiers = [
  "Development Status :: 3 - Alpha",
  "Intended Audience :: Developers",
  "Intended Audience :: Science/Research",
  "Operating System :: MacOS",
  "Operating System :: POSIX :: Linux",
  "Programming Language :: Python :: 3 :: Only",
  "Programming Language :: Python :: 3.11",
  "Programming Language :: Python :: 3.12",
  "Programming Language :: Python :: 3.13",
  "Programming Language :: Python :: 3.14",
  "Topic :: Database",
  "Typing :: Typed",
]
dependencies = [
  # none for the Mojo runtime (decision 6)
  "pyarrow>=25.0.1",   # with Session.sql's Result; the lower bound is the pyarrow the tests run on
  "protobuf>=5.29.1,<8",   # with the DataFrame: loads the generated plan modules (python/dependencies.bzl)
]

[project.optional-dependencies]
pandas = ["pandas"]   # range: as for pyarrow
polars = ["polars"]

[project.urls]
Source = "https://github.com/komira-ai/komira"
Issues = "https://github.com/komira-ai/komira/issues"
Documentation = "https://github.com/komira-ai/komira/blob/main/docs/install.md"
Changelog = "https://github.com/komira-ai/komira/blob/main/python/CHANGELOG.md"
```

- **The changelog.** Every change to the package adds a file, `python/changelog.d/<slug>.md`, and never a
  line of `python/CHANGELOG.md`: ten pull requests that each add a bullet at the head of one file conflict
  with each other in the merge queue, and ten that each add a file do not. A file holds Markdown bullets
  (`- **Title.** text`, a continuation indented two spaces, no heading). A release's version is `0.1.<N>`
  from the stamp, which a pull request cannot know, so the release writes its section: the changelog tool
  (`python/changelog`, Zig, with its own cases; the rule is `changelog_file`, target `//python:changelog`)
  puts `## 0.1.<N>` before the first release heading of `CHANGELOG.md`, holding the bullets of every file in
  file-name order, so a release lists every change merged since the newest section `CHANGELOG.md` keeps
  (a section is kept by moving its files' bullets under their own heading in one change). The wheel's
  description, `METADATA`'s body, is `README.md` followed by that changelog with each heading one level
  down, so the page of version 0.1.`<N>` on PyPI shows its own section; both wheels read the one target,
  so their `METADATA` is the same. The tool refuses, naming the file and the line, a file that is not a
  slug and `.md`, an empty file, a line that is neither a bullet nor an indented continuation, a heading,
  a `## Unreleased` heading in `CHANGELOG.md` and a `CHANGELOG.md` with no release heading; the wheel
  depends on the target, so a pull request that builds the wheel builds the check. Nothing else fails when
  an entry is missing, so `python/tests/test_changelog_names.py` holds every public name of `komira` and
  `komira.pl` (each module's `__all__`, and the public attributes of each public class) to an entry: the
  name is an identifier inside a backticked code span of `CHANGELOG.md` or of a file of `changelog.d/`.
  It holds the names, not the change: a name whose last part is already in a span passes, and a change of
  behaviour that adds no name needs a fragment by review.
  A change that touches only `changelog.d/` is documentation-only to the release workflow (`**.md`), so it
  starts no release; its entry reaches the page of the next release that changes code.
- **PEP 639 licence metadata.** `license` is an SPDX expression with two terms: `Apache-2.0` for the
  repository's code and `LicenseRef-Modular-Proprietary` for the three Mojo runtime libraries the wheel
  carries. The pinned `mojo-compiler` conda package states `LicenseRef-Modular-Proprietary` in its
  metadata and ships the Modular Community License Terms as `info/licenses/LICENSE` and a list of its
  third-party components as `info/licenses/Third-Party-Notices`; it has no Apache text and no per-file
  statement for the three libraries. So `license-files` puts four files in the wheel's
  `.dist-info/licenses/`: `LICENSE` and `NOTICE` (the repository root's) and `MODULAR_LICENSE` and
  `MODULAR_THIRD_PARTY_NOTICES` (those two files of the conda package, extracted unmodified at build
  time). There is no `License ::` classifier: PEP 639 deprecates them alongside an expression. The wheel
  rule stages the files, so `python/` holds no copy that could drift. The wheel rule's read-back check
  refuses a wheel without them: an absent licence file must not build a wheel with no licence in it.
- **Two `Requires-Dist` lines, `pyarrow>=25.0.1` and `protobuf>=5.29.1,<8`.** Release 1 listed none;
  the release with `Session.sql` requires pyarrow, which a `Result` is read as, and the release with
  the DataFrame requires protobuf, which loads the generated plan modules a frame's plan is encoded
  with (python/dependencies.bzl says why each range is what it is). None is on `mojo-compiler`: the
  runtime libraries are in the wheel (decision 6).
- **The tag is `py3-none-manylinux_2_35_x86_64`.** `libAsyncRTRuntimeGlobals.so` needs
  `GLIBC_2.35`, so a `manylinux_2_34` tag would promise a glibc the library does not run on; the highest
  C++ runtime versions the three need are `GLIBCXX_3.4.30` and `CXXABI_1.3.11`
  (`libKGENCompilerRTShared.so`), which manylinux_2_35's limits admit. The wheel rule
  takes the floor as an attribute, set per platform in `python/BUCK` with those two symbol-version
  limits, and its read-back check holds the wheel's native files to them.
- **No internal names.** Authors are "The komira authors", not a person; the URLs name only this
  repository; no internal host, no private repository, no address. The public-boundary lint reads
  `python/` like every file of the cell.
- **Only what is true.** The `Operating System` classifiers name the release platforms, each of which
  gets its wheel only after that wheel's install test passes on that platform (in the macOS jobs of pypi.yml
  for macOS, never in a pull request's check). The CPython classifiers name the interpreters the
  package's tests run: 3.11, 3.12, 3.13 and 3.14, each pinned in
  [third_party/python](../../third_party/python/README.md) and listed once in
  [python/pythons.bzl](../../python/pythons.bzl), which the wheel's metadata, the tests and the release
  workflow's smoke jobs all read. `requires-python` starts at the oldest of them; claiming an older
  version waits for a test on it. 3.10, which reached its end of life in October 2026, is outside, and
  an install test holds that it is refused. `Typing :: Typed` because the package ships
  `py.typed` (decision 8).
- **`python/` is not an installable project.** It has no `pyproject.toml` and no `[build-system]`
  table, so `pip install ./python` fails, as expected: the package is installed from its wheel. The
  wheel rule's attributes are the metadata, and `license-files` names files the rule stages from the
  repository root, which `python/` does not hold.
- **protobuf was not a dependency of the first release.** Only the DataFrame's plan encoder needs it;
  it was added, with its range, with the DataFrame. `import komira` does not import it: the first
  reader that makes a frame does.
- **The version** is stamped by the wheel rule. Its scheme is in
  [packaging/conda/README.md](../../packaging/conda/README.md) ("Wheels: versioning") and is the wheel
  design's to confirm.

### 8. Typed from the first release

`komira/py.typed` ships in the first release and every public name is annotated, so a type checker reads
the package's own annotations (PEP 561) and the `Typing :: Typed` classifier is true. The annotations of
private modules are the author's choice. No type checker is pinned in this repository yet, so nothing
checks the annotations; the wheel rule's read-back check holds that `py.typed` is in the wheel.

### 9. Errors

- Every error from the library or from a session's state (closed, already read) is a `KomiraError` (a
  subclass of `Exception`), so `except komira.KomiraError` catches komira's errors and nothing else.
  Arguments are Python's: a wrong type raises `TypeError` and a wrong value of the right type (a
  `threads` of 0, a negative `memory_limit`, an empty table name) `ValueError`, before the library is
  called; a missing optional dependency raises `ImportError` (decision 3).
- `UnsupportedOperation` was a `TypeError` in the earlier SDK and is a `KomiraError` here. That SDK was
  never published, so no user's `except TypeError` depends on it.
- A `KomiraError` from the library carries `status` (the ABI's status number), `code` (the engine's
  named code, `ENGINE_OPTIONS_INVALID` for example, or `None`), `step` (the step that refused it:
  `parse`, `bind`, `optimize`, `lower`, `execute`, or `None`) and the library's message as `str(e)`.
  `code` and `step` come from the library's `komira_last_error_code` and `komira_last_error_step`
  (ABI 1.7), never from parsing the message. An empty code from the library is `None`. Against a
  library older than 1.7, `code` and `step` are `None`.
- **The table is built** (`python/komira/_errors.py`). A status other than -3 (the engine refused the
  call) raises `KomiraError`. For -3 the subclass is chosen by `code` first, then by `step`, then by
  the call's own default, then `KomiraError`:
  - `ParseError`: `SQL_SYNTAX_ERROR`; step `parse`.
  - `BindError`: `SQL_BIND_ERROR` and the `BIND_*` codes; step `bind`.
  - `UnsupportedOperation`: `SQL_NOT_SUPPORTED`, `STATEMENT_NOT_A_QUERY`,
    `OPTIMIZE_UNRESOLVED_SCALAR`, `LOWERING_UNCUTTABLE_NODE`, `LOWERING_SCAN_NOT_TOTAL`,
    `LOWERING_SINK_UNSERVED`, `LOWERING_JOIN_UNSERVED`,
    `LOWERING_WINDOW_UNSERVED`, `LOWERING_UDF_UNSERVED`, `SQL_STATEMENT_UNSUPPORTED`,
    `COPY_OPTION_UNSUPPORTED`, `COPY_FORMAT_NOT_INFERRED`, `STORAGE_URL_REFUSED`,
    `STORAGE_RANGE_NOT_SUPPORTED`, `STORAGE_WRITE_UNSUPPORTED`, `PLAN_URL_QUERY_REFUSED`.
  - `MemoryLimitError`: `MEMORY_BUDGET_EXCEEDED`, the engine's refusal at step `execute` when the
    memory budget (`Session(memory_limit=)`) denies an operator the bytes its state needs. The
    code is the first word of the engine's message, set by `pipeline_exec` at every site that
    reports a denied draw (the aggregation, grouped aggregation, window and sort sinks and
    COUNT(DISTINCT)). A query the engine runs in less memory, as a fixed-width GROUP BY that
    spills, does not raise it; the class and the code stay the same when a spill directory
    becomes reachable through the ABI, and an operator that does not spill still raises it.
  - `CredentialsError`: `CREDENTIAL_UNBOUND`, `CREDENTIAL_NAME_CONFLICT`,
    `CREDENTIAL_KIND_MISMATCH`, `CREDENTIALS_NOT_FOUND`, `CREDENTIALS_INVALID`; also the default of
    the credential calls.
  - `StorageError`: `STORAGE_REGION_UNKNOWN`, `STORAGE_NOT_FOUND`, `STORAGE_ACCESS_DENIED`,
    `STORAGE_THROTTLED`, `STORAGE_TRANSPORT`, `STORAGE_MALFORMED`, `STORAGE_OBJECT_CHANGED`,
    `STORAGE_IO`.
  - The code rule, in the library (`error_code` in `src/so/session.mojo`): the prose prefixes
    `SQL syntax error`, `SQL bind error` and `SQL not supported` give `SQL_SYNTAX_ERROR`,
    `SQL_BIND_ERROR` and `SQL_NOT_SUPPORTED`; otherwise a leading `CODE: ` (upper-case words joined
    by underscores) is the code; otherwise there is none. The rows for credentials, storage and
    writes are in [credentials_and_writes.md](credentials_and_writes.md#11-error-shapes).
- The message is the engine's text, unchanged: a refusal names the construct (rule B21: unsupported
  features are refused by name), and the package does not rewrite it.

## What is decided elsewhere

| question | where |
|---|---|
| the SQL and plan doors of the C ABI, the Arrow C stream export, session options, status codes, abort containment | the ABI design for running a query (`src/so`) |
| the wheel tags of linux-arm64 and macos-arm64, the supported CPython range, `Requires-Dist` ranges, sdist, release member, PyPI stages | the wheel and release design |
| the verbs of the two DataFrame surfaces, the refusal policy for verbs | the DataFrame surface design |
| Python UDFs in worker processes | [udf_runtime_interface.md](udf_runtime_interface.md) and its Python design |
| sources, credentials and binding them (`Session.add_sql_binding`, and `sql(query, **sources)` for one statement), `https://` reads, `COPY ... TO` and its result | [credentials_and_writes.md](credentials_and_writes.md) |

## What must always hold?

- No `.py` file and no Python target outside `python/` and the other surface entries: `//:python_closure`
  refuses one, and the package adds nothing to its ceiling.
- No public name of the package is configured by an environment variable. The package reads none;
  the variables read are the AWS and Google credential chains', inside the library, when a URL
  needs them, and libcrypto's default trust-store variables ([credentials_and_writes.md](credentials_and_writes.md#7-the-ambient-credential-and-the-only-environment-komira-reads)).
- The public names are exactly `komira.__all__`; a private module's name is never in user documentation.
- The wheel carries `libkomira`, its native owners, the three Mojo runtime libraries of the
  toolchain's pinned `mojo-compiler`, the licence files of both and `py.typed`, and requires no other
  distribution.
- A query answers what DuckDB answers for the same SQL, or refuses by name.

## How is it tested?

Each pull request tests what it builds, in
`python/tests/` as `python_binding_test` targets, and the wheel rule's read-back check holds the wheel's
contents. What the first ones must show, in this design's terms: the loader refuses a library of another
ABI major version and an absent library with `LibraryLoadError`; `SELECT 1 AS n` and a `GROUP BY` over a
checked-in Parquet fixture answer as DuckDB does; an unknown table, a syntax error and an unsupported
construct raise from `sql` with their step and code; a `Result` read twice refuses the second read;
closing a session with an unread result does not crash.

The wheel is installed into an empty environment and run there (`//python:wheel_install_test` on CPython 3.13,
and `_py311`, `_py312` and `_py314` on the other supported minors), alone: the environment holds komira and no other distribution, and the runtime is mapped from
`<site-packages>/komira/_lib/lib`. `//python/tests:runtime_test` holds the runtime check on stand-in libraries.

## What are the limits and open questions?

- The interpreter list ([tools/build/lint/interpreter_allowlist.tsv](../../tools/build/lint/interpreter_allowlist.tsv))
  holds two glob rows for the package, `python/komira/**/*.py` and `python/tests/**/*.py`, so a new `.py` file
  there needs no row; a file of another kind under `python/` (a shell script, or a file with only a `#!` line)
  still needs its own. `third_party/python`'s `_TEST_ONLY` and `src/so`'s visibility each need a line for
  `python/`; the loader added them.
- Free-threaded CPython (3.14t): the package is not claimed for it in the first release. ctypes works
  there, but no test runs the package on it.
- An abort inside libkomira ends the interpreter. A raise is a status and becomes a Python exception,
  but an `abort()`, a fault, stack exhaustion or an out-of-memory kill cannot be caught in the process
  ([libkomira_run_abi.md](libkomira_run_abi.md) §8 lists the inputs refused before they reach one, and
  the ones that still do). The package README says so, under "What does not work yet".
- `Result.to_polars` and `to_pandas` convert through Arrow, with pyarrow's `Table.to_pandas()` and
  `polars.from_arrow` and no options of their own; `python/tests/test_result_frames.py` holds the dtype
  each Arrow type the engine answers becomes.

## Where is the code?

`python/` (release 1, [python/README.md](../../python/README.md)), the allowlist [tests/python_closure_allowlist.bzl](../../tests/python_closure_allowlist.bzl),
the check [tools/build/selftest/graph/python_closure.zig](../../tools/build/selftest/graph/python_closure.zig).
