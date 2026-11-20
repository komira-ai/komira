# The Python package: layout, names and first API

Status: design, not built. The allowlist entry that admits the package (`python` in `PYTHON_SURFACE`,
[tests/python_closure_allowlist.bzl](../../tests/python_closure_allowlist.bzl)) lands with this document;
`python/` itself does not exist yet, so the entry matches nothing until the loader's pull request adds
the first files.

## What problem does this solve?

People should be able to `pip install komira-ai` and run SQL over their local files from Python. komira has
no Python package today: Python in this repository is test-only, and the one Python surface is the hello
test of `python_binding_test` ([tools/build/python/README.md](../../tools/build/python/README.md)). The
shared library `libkomira` ([src/so/README.md](../../src/so/README.md)) is what the package will load,
and the Node addon ([node/README.md](../../node/README.md)) is the precedent for a binding over it.

The work that builds the package is split over several pull requests (the loader, the session, error
mapping, the wheel rule, the release member). Each of them needs the same answers first: where the package
lives, what it and its modules are called, which names are public, which parts of the earlier,
never-published Python SDK are carried over, and what its metadata says. This document gives those
answers. It does not decide the C ABI (symbols and status codes), the wheel's platform tags and CPython
range, the Mojo runtime route, or the DataFrame surface; each has its own design, named under
[What is decided elsewhere](#what-is-decided-elsewhere).

Fixed before this design and not reopened here: the distribution (the name on PyPI, the name `pip install`
takes) is `komira-ai`, the name of the GitHub organisation; it is published by the top-level workflow
`.github/workflows/pypi.yml` through the GitHub environments `testpypi` and `pypi`, by trusted
publishing with no token, and nothing is uploaded before the first real release; the package lives in `python/` in this repository; it is published as a wheel first; the wheel
carries `libkomira` and never the Mojo runtime (if the library needs runtime libraries at load time, the
wheel depends on Modular's own published package for them); the release platforms are linux-x86_64,
linux-arm64 and macos-arm64; the first public release is SQL-first and the DataFrame surface follows;
Python UDFs run in zygote worker processes ([udf_runtime_interface.md](udf_runtime_interface.md)).

## The decisions

### 1. Where the package lives

```
python/
  BUCK              the package's sources as one target, its tests' targets, later the wheel target
  README.md         what the package is, how it is built and tested (the package doc, like node/README.md)
  pyproject.toml    the [project] metadata (decision 7)
  komira/           the import package
    __init__.py     the public names, and nothing else (decision 3)
    py.typed        the PEP 561 marker (decision 8)
    _native.py      the ctypes loader: finds and opens libkomira, checks the ABI major version
    _session.py     Session, Result, the default session
    _errors.py      KomiraError and its subclasses
    _arrow.py       the Arrow C stream import
    _lib/           not in the repository: the wheel rule stages libkomira here (decision 6)
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
- **The generated protobuf modules are not in the first release.** They come with the DataFrame plan
  encoder (decision 4). When they come, they live where their proto package puts them, `komira/plan/v1/`
  (`package komira.plan.v1;` in [src/plan_proto/plan.proto](../../src/plan_proto/plan.proto)): protoc
  writes `from komira.plan.v1 import ...` into the generated code, and the earlier SDK nested them there
  for that reason. `komira.plan` is then a package without public names: nothing in `__all__` comes from
  it, and its README line says so.

### 2. Module names

- The distribution is `komira-ai` and the import package is `komira`: users run `pip install komira-ai`
  and write `import komira` (the design docs write `import komira as km`;
  [storage_stack.md](storage_stack.md), [optimized_plan_sources.md](optimized_plan_sources.md) §15.9).
  The two names differ on purpose, as `scikit-learn` and `sklearn` do:
  - the import name is the product's name, the one every design doc and every other SDK (`km.` in Mojo
    and TypeScript) already uses;
  - the generated protobuf modules must import as `komira.plan.v1` (decision 1), so any other import
    name would put a second top-level package, `komira`, into the user's environment anyway;
  - the distribution name follows the organisation, and the wheel's file name (`komira_ai-<version>-...`)
    and `.dist-info` directory are spelt from it by the normalisation of PEP 427 and PEP 503.
  Messages that tell a user what to install name the distribution (`pip install komira-ai[pandas]`);
  messages about the code name the import package.
- Every module other than `komira/__init__.py` starts with an underscore and is private. A user imports
  public names from `komira` only; a private module may be split, merged or renamed in any release.
- No public submodule ships in the first release. The earlier SDK's polars-shaped submodule `komira.pl`
  is not carried in it; whether the DataFrame surface has one skin or two, and their module names, is the
  DataFrame surface's design. The names that design must keep are the ones the design docs already use
  at the top level: `read_parquet`, `read_table`, `col`, `catalog` (verb names are the same words in every
  language, [optimized_plan_sources.md](optimized_plan_sources.md) §15.9). This design reserves them by
  not using them for anything else.

### 3. The first release's public API

The whole public surface of the first release is these names in `komira.__all__`:

| name | what it is |
|---|---|
| `Session(*, threads=None, memory_limit=None)` | one engine context (`komira_ctx_new`) and its registered tables. `threads` is the worker count and `memory_limit` the engine's memory budget in bytes; `None` takes the engine's default. Options are arguments, never environment variables (rule S2). A context manager: `with komira.Session() as s:`; `close()` frees the context and is idempotent |
| `Session.register_parquet(name, path)` | registers a local Parquet file as the table `name` (`komira_register_parquet`). `path` is a `str` or `os.PathLike`; a relative path is resolved against the working directory when the call is made, `~` is expanded. Registering a name again replaces it |
| `Session.sql(query) -> Result` | runs one SQL statement over the session's tables. **This is the official door of the first release**, not an escape hatch |
| `Result` | the answer of one `sql` call: `to_arrow() -> pyarrow.Table`, `to_reader() -> pyarrow.RecordBatchReader`, `to_pandas()`, `to_polars()`, and `__arrow_c_stream__(requested_schema=None)` (the Arrow PyCapsule interface, so `pyarrow.table(r)`, `polars.from_arrow(r)` and DuckDB take the stream itself; no batch is converted in Python) |
| `sql(query) -> Result`, `register_parquet(name, path)` | the same two calls on the process's default session (decision 5) |
| `KomiraError` | the base class of every error the package raises on purpose (decision 9) |
| `UnsupportedOperation` | a `KomiraError`: komira refused a construct by name (an SQL feature the engine does not run yet, an option it does not take) |
| `LibraryLoadError` | a `KomiraError`: `libkomira` or a library it needs could not be loaded, or its ABI major version is not the one this package was written for |
| `__version__` | the installed distribution's version, read with `importlib.metadata.version("komira-ai")` (the distribution's name, not the import package's) |

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
  missing, the `ImportError` names the extra that installs it (`pip install komira-ai[pandas]`).
- **A closed session refuses every call** with `KomiraError`, and closing a session while a `Result` of
  it is unread never crashes the interpreter. Whether that unread result then still reads, or refuses, is
  the session pull request's choice, held by a test of each case it allows.
- **One session, any thread.** A `Session` may be used from several threads; it holds a lock around each
  call into the library, its `Result`s' batch reads included, so one context never runs two calls at
  once (a thread reading a large result holds up a `sql` call on the same session between batches, not
  for the whole read). Sessions are independent of one another. The lock goes when the ABI design states
  that a context is safe to share.
- **Fork.** A child process made by `os.fork` must not use a session of its parent: the package
  registers an `os.register_at_fork` hook that marks every session of the parent closed in the child, so
  a call there raises `KomiraError` instead of running on a copied context. The package never forks;
  UDF workers are the engine's, not this package's.
- **Ctrl-C during a query** is delivered when the query returns; the session stays usable. The first
  release has no cancel and its docs say so.

### 4. What is carried from the earlier SDK, and what is not

The earlier SDK (`komira` 0.0.1, never published) was a ctypes wrapper over one Mojo shared library with
a pandas-shaped and a polars-shaped DataFrame surface. What happens to each part:

| part | first release | later | not carried, and why |
|---|---|---|---|
| ctypes loader (`_native.py`): load by path, ABI version check, status codes and last error to exceptions | yes, as `_native.py`, against `libkomira`'s ABI | | its lookup by environment variable and the walk up the working directory to a build output: see decision 6 |
| `Session`: context manager, `close`, one context per session | yes | | the `plan_wire` argument (below) |
| `Session.sql` | yes, as the official door returning a `Result` | | its status as "escape hatch, goes away with the scaffolding": SQL is now the first release's whole query surface |
| default session and module-level calls | yes, for `sql` and `register_parquet` | the DataFrame readers | the public `session()` accessor: a second way to reach the same object |
| table registration | `register_parquet(name, path)`, with the name required | CSV and NDJSON registration, from the engine's own schema | automatic names (`t1`, `t2`, ...): SQL needs the name the user wrote |
| `KomiraError` with the engine's status and message | yes, with the fields of decision 9 | | the `PLAN_ENDPOINT_<NAME>(<code>):` message prefix and its generated code table: libkomira's status codes and error text replace them |
| `UnsupportedOperation` | yes, now a `KomiraError` (it was a `TypeError`) | | |
| pandas-shaped `DataFrame`, `Column`, `Expr`, `GroupBy`, `MaterializedFrame`; the shared builder `Query`; the protobuf plan encoder | | with the DataFrame surface, through the plan door (`komira_plan_stream`) | |
| polars-shaped `komira.pl` | | if the DataFrame surface keeps two skins | |
| **the SQL-text route** (`_sql.py`: DataFrame operations rendered to SQL text and re-parsed) | | | dropped. A DataFrame becomes a plan, never SQL text; `sql()` is SQL the user wrote, and is not that route |
| **the route switch**: `Session(plan_wire=...)` and the environment variable that chose the SQL-text route | | | dropped. There is one route per kind of input, so there is nothing to switch; and configuration is never an environment variable (rule S2) |
| `@komira.udf` and `Session.declare_sql_udf` | | Python UDFs in zygote worker processes | the in-process `ctypes` callback the engine called per batch: Python UDFs run in worker processes |
| Excel calls (`xl_*`), the second result door (`plan_bytes`), `sql_render` | | | not in the first release's ABI; a text rendering of a plan is a later, separate decision |
| warming pyarrow before opening the library | | | the Arrow import goes through the PyCapsule interface or pyarrow's public C stream import; the load-order case it worked around is a test of the Arrow terminals pull request |

### 5. The default session

`komira.sql` and `komira.register_parquet` use one `Session` per process, created with default options on
the first call. The package does not close it; the operating system reclaims it at exit, as it does the
library, which is never unloaded (decision 6). A user who wants options or a second set of tables
creates a `Session`. There is one default per process, not per thread: a table registered on it is
visible from every thread, as a module-level name would be.

### 6. Finding the library, with no environment variable

- An installed package loads `komira/_lib/libkomira.so` (`libkomira.dylib` on macOS), the library the
  wheel carries beside its own `lib/` directory of native owners, which is the library's run path
  (`$ORIGIN/lib:$ORIGIN`, [tools/build/mojo/README.md](../../tools/build/mojo/README.md)). It is the
  layout of `//src/so:libkomira[runnable]`, so the wheel rule copies that directory.
- The Mojo runtime libraries are not in the wheel. Where the loader finds them is the runtime route's
  decision; whatever it is, a missing or wrong runtime raises `LibraryLoadError` naming the library and
  the version it needed.
- Tests load the library their target staged: the private `_native.load(lib_dir)` takes the directory a
  `python_binding_test` passes as `--lib-dir`. It is an argument of a private function, not a user setting.
- There is no lookup by environment variable (`KOMIRA_NATIVE_LIB`, `KOMIRA_NATIVE_LIBDIR` and the
  `CONDA_PREFIX` scan of the earlier SDK) and no search of the working directory for a build output. A
  wheel that loaded a library from somewhere the user's environment pointed would answer with a library
  no test of that wheel ran.
- The library is opened once per process and never closed: the Mojo runtime does not support unloading
  ([node/README.md](../../node/README.md)).

### 7. Metadata

The `[project]` table of `python/pyproject.toml` is the one source of the wheel's `METADATA`. The wheel
is written by a Buck2 rule, not by a PEP 517 build backend: an sdist cannot build `libkomira`, so none is
published, and the file has no `[build-system]` table to imply otherwise. The table, with the values the
later designs fill marked:

```toml
[project]
name = "komira-ai"
dynamic = ["version"]   # stamped by the wheel rule
description = "SQL over local files, with libkomira, the komira query engine, in process"
readme = "README.md"
requires-python = ">=3.13"   # the oldest CPython the package's tests run; the wheel design may widen it
license = "Apache-2.0"
license-files = ["LICENSE", "NOTICE"]
authors = [{ name = "The komira authors" }]
keywords = ["sql", "arrow", "parquet", "query-engine"]
classifiers = [
  "Development Status :: 3 - Alpha",
  "Intended Audience :: Developers",
  "Intended Audience :: Science/Research",
  "Operating System :: MacOS",
  "Operating System :: POSIX :: Linux",
  "Programming Language :: Python :: 3 :: Only",
  "Programming Language :: Python :: 3.13",
  "Topic :: Database",
  "Typing :: Typed",
]
dependencies = [
  "pyarrow",   # range: the wheel design, from the range the Arrow terminals are tested at
  # the Mojo runtime package, if the runtime route needs one
]

[project.optional-dependencies]
pandas = ["pandas"]   # range: as for pyarrow
polars = ["polars"]

[project.urls]
Homepage = "https://github.com/komira-ai/komira"
Source = "https://github.com/komira-ai/komira"
Issues = "https://github.com/komira-ai/komira/issues"
```

- **PEP 639 licence metadata.** `license` is the SPDX expression of the repository's licence and
  `license-files` puts the licence text in the wheel's `.dist-info/licenses/`. There is no
  `License ::` classifier: PEP 639 deprecates them alongside an expression. `LICENSE` and `NOTICE` are the
  repository root's files (`//:LICENSE` is already an exported file); the wheel rule stages them, so
  `python/` holds no copy that could drift from the root. The wheel rule's read-back check refuses a
  wheel without both: an absent licence file must not build a wheel with no licence in it.
- **No internal names.** Authors are "The komira authors", not a person; the URLs name only this
  repository; no internal host, no private repository, no address. The public-boundary lint reads
  `python/` like every file of the cell.
- **Only what is true.** The `Operating System` classifiers name the release platforms, each of which
  gets its wheel only after that wheel's install test passes on that platform (in the release workflow
  for macOS, never in a pull request's check). The CPython classifiers name the interpreters the
  package's tests run: 3.13 today ([third_party/python](../../third_party/python/README.md)), and 3.14
  when a test of the package runs the pinned 3.14. `requires-python` starts at the oldest of them;
  claiming older versions waits for a test on them. `Typing :: Typed` because the package ships
  `py.typed` (decision 8).
- **The file is the wheel rule's data, not an installable project.** With no `[build-system]` table,
  `pip install ./python` would fall back to setuptools and fail (there is no library to build), and
  `license-files` names files the wheel rule stages from the repository root, which `python/` does not
  hold. Both are expected: the package is installed from its wheel, and the wheel rule refuses a key of
  `[project]` it does not read, so the file never says something the wheel does not carry.
- **protobuf is not a dependency of the first release.** Only the DataFrame plan encoder needs it; it is
  added, with its range, when that lands.
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
  Which status and code map to which subclass is the error-mapping pull request's table.
- The message is the engine's text, unchanged: a refusal names the construct (rule B21: unsupported
  features are refused by name), and the package does not rewrite it.

## What is decided elsewhere

| question | where |
|---|---|
| the SQL and plan doors of the C ABI, the Arrow C stream export, session options, status codes, abort containment | the ABI design for running a query (`src/so`) |
| wheel tags, the supported CPython range, `Requires-Dist` ranges, RUNPATH, sdist, release member, PyPI stages | the wheel and release design |
| where the Mojo runtime comes from | the runtime route decision |
| the DataFrame skins, their verbs and module names, the refusal policy for verbs | the DataFrame surface design |
| Python UDFs in worker processes | [udf_runtime_interface.md](udf_runtime_interface.md) and its Python design |

## What must always hold?

- No `.py` file and no Python target outside `python/` and the other surface entries: `//:python_closure`
  refuses one, and the package adds nothing to its ceiling.
- No public name of the package is configured by an environment variable.
- The public names are exactly `komira.__all__`; a private module's name is never in user documentation.
- The wheel carries `libkomira` and its native owners, its licence files and `py.typed`, and no file of
  Modular's runtime distribution.
- A query answers what DuckDB answers for the same SQL, or refuses by name.

## How is it tested?

This document lands with the surface entry only. Each later pull request tests what it builds, in
`python/tests/` as `python_binding_test` targets, and the wheel rule's read-back check holds the wheel's
contents. What the first ones must show, in this design's terms: the loader refuses a library of another
ABI major version and an absent library with `LibraryLoadError`; `SELECT 1 AS n` and a `GROUP BY` over a
checked-in Parquet fixture answer as DuckDB does; an unknown table, a syntax error and an unsupported
construct raise from `sql` with their step and code; a `Result` read twice refuses the second read;
closing a session with an unread result does not crash.

## What are the limits and open questions?

- **Question for the owner: distribution `komira-ai`, import package `komira`?** This design takes
  `komira` as the import name for the reasons in decision 2. The alternative, `import komira_ai`, would
  match the distribution and the import name, but the generated `komira.plan.v1` modules would still
  add a `komira` package beside it. The import name is the one name a user types in every program, so
  it is the owner's to confirm before the loader's pull request lands its first `.py` file.

- The interpreter list ([tools/build/lint/interpreter_allowlist.tsv](../../tools/build/lint/interpreter_allowlist.tsv))
  needs a row for each `.py` file today, and `third_party/python`'s `_TEST_ONLY` and `src/so`'s visibility
  each need a line for `python/`. The loader pull request adds them; whether the interpreter list should
  read `PYTHON_SURFACE` instead of a row per file is a question for that lint.
- Free-threaded CPython (3.14t): the package is not claimed for it in the first release. ctypes works
  there, but no test runs the package on it.
- `Result.to_polars` and `to_pandas` convert through Arrow; their dtype mapping is the Arrow terminals
  pull request's tests.

## Where is the code?

`python/` (not yet built), the allowlist [tests/python_closure_allowlist.bzl](../../tests/python_closure_allowlist.bzl),
the check [tools/build/selftest/graph/python_closure.zig](../../tools/build/selftest/graph/python_closure.zig).
