# The Mojo SDK: a thin package over the shared library, and a surface for physical plans

Status: design, not built. **EXISTS** names code on `main`. **PROPOSED** is new. Statements the
author deduced rather than read are marked *(inferred)*. The choices only the owner can make are
collected under [Decisions for the owner](#decisions-for-the-owner).

## What problem does this solve?

A Python user runs `pip install komira` and gets SQL over their files. The TypeScript package offers
the same over the Node addon ([python_package.md](python_package.md),
[typescript_package.md](typescript_package.md)). Both reach the engine the same way: through the C
interface of the shared library `libkomira` (`src/so`,
[libkomira_run_abi.md](libkomira_run_abi.md)). A Mojo user has nothing equivalent. **EXISTS:**
- 66 Mojo libraries are packages on mopm, the registry the release publishes to (the `PACKAGES` of
  [release/readme_e2e/packages.bzl](../../release/readme_e2e/packages.bzl)). The other 197 are not
  (the rows of [release/UNPUBLISHED.md](../../release/UNPUBLISHED.md)).
- None of the 66 runs a query, and no mopm package carries `libkomira`.
- No Mojo library has a public `Session` type. `src/so/session.mojo` has an internal `Session`: the
  state behind libkomira's C handle, inside the shared library and exported by no package. The
  `komira.Session` of this design shares its name in a different package, so a user never sees both.

The owner has said what the Mojo SDKs are:
- **The untyped Mojo SDK is the package `komira`.** It calls the shared library through its C
  interface, as the Python and TypeScript packages do. The C interface has two ways in: SQL text
  and a logical plan. SQL is turned into a logical plan inside the library. Asked whether the
  untyped SDK calls the shared library and does not link the engine, the owner said: "yes we did
  this because compiling the engine was so expensive that it didn't make sense for the untyped
  path to do that".
- **Writing physical plans is a separate, Mojo-only surface.** It looks different from the untyped
  SDK, it has no counterpart in the C interface, and it is the one Mojo surface that links the
  engine's Mojo libraries.
- **A typed SDK**, where column types are checked when the user's program is compiled, may come
  later. It is not ruled on.

This document designs the first two, says what the third would rest on, and computes what must be
published for each. It adds no code and publishes nothing.

Fixed before this design, and not reopened here:
- **One C interface.** Every language's SDK uses the same calls
  ([libkomira_run_abi.md](libkomira_run_abi.md)). This design adds no call to it. What `komira`
  would want and the interface lacks is listed as a gap in the interface (§1), not built in Mojo
  around it.
- **Sources are values.** Every SDK is to bind a table name to a source value with
  `add_sql_binding`. Python does today; Node registers with `registerParquet` until it does.
  Mojo spells it `session.add_sql_binding(name, source)`, as Python does
  ([credentials_and_writes.md](credentials_and_writes.md), decision 12). The owner prefers one
  `files` source to a reader name per format.
- **The Mojo rules** of [AGENTS.md](../../AGENTS.md) and
  [mojo_safety_and_idioms.md](mojo_safety_and_idioms.md) hold for every new line.

## Words this document uses

- **the shared library**: `libkomira` (`libkomira.so` on Linux, `libkomira.dylib` on macOS), the
  engine built once as one library with a C interface. The Python wheel carries it today.
- **C interface**: the 26 functions the shared library exports (`src/so/abi/komira.tsv`, ABI 1.10).
- **form**: one way to write a program: a language and the part of komira it uses. This is the word
  of the task-examples design (komira-ai/komira#2495, `docs/design/task_examples_languages.md` on
  its branch), which gives each form its own tree of task examples and its own tab on a task page.
  Mojo has two forms in this design: **Mojo** (the untyped SDK, key `mojo`) and **Mojo physical
  plan** (key `mojo_plan`).
- **published**: a package on mopm. In the repository that means a member of `PACKAGES`.
- **closure**: every library a library needs, directly or through the libraries it needs.
- **wave**: a group of libraries that can be published together, because every library each of them
  needs is published already or in an earlier wave (§5).
- **FFI boundary**: the one module that holds foreign pointers (the library handle, C strings, the
  Arrow stream) and turns them into Mojo values. The repository's rule is that foreign code is
  called only from the module that owns the foreign resource, behind safe functions.
- **welded test**: a test the build runs before a library's package can exist, so a failing test
  fails the build.
- **install test**: the release's README end-to-end test (`//release/readme_e2e/verify:<name>`). It
  installs the packages into an empty project, the way a user does, and runs the README examples
  against them (§9).
- **logical plan**: the plan of what a query computes, before it is cut into pipelines
  (`komira.plan.v1`). SQL is turned into one inside the shared library.
- **Arrow C stream**: the standard C struct of the Arrow format (`ArrowArrayStream`) through which
  the library hands back a result in batches.
- **sink**: the step that ends a pipeline and gathers its rows (aggregate, sort, collect, ...).
- **physical plan**: the plan the executor runs: pipelines, the operators in each, and the step that
  ends each pipeline, as data (`physical_plan`). The engine's lowering makes it from a logical plan.
- **tree**: the directory of one form's task examples, with one directory per task.
- **tab**: the part of a task page that shows one form's program and output.
- **slice**: one step of the work, one or more pull requests, that ends with a test showing it works
  (§11).

## The Mojo SDKs

| | Mojo: the untyped SDK, `komira` | Mojo physical plan, `komira_physical` | A typed SDK, possibly later |
|---|---|---|---|
| what the user writes | files and SQL text, and later logical plans; reads rows back | the physical plan itself: pipelines, their operators and the step that ends each, run as written | a program whose schema is a compile-time value |
| when names and types are checked | at run time, when the library binds the plan | at run time, when the plan is submitted (§5) | when the user's program is compiled |
| what it rests on | the shared library's C interface (§1 to §3) | the engine's Mojo libraries, linked into the user's program (§5) | the typed operator tables (§6) |
| what installing it compiles | `komira` and the 19 libraries of its closure (§4); no engine | `komira_physical` and the 88 libraries of its closure (`sdk_exec`, its 86 and `komira_error`), the engine among them; of these, 58 packages are still to publish (§5) | not designed |
| built | first | second | not planned; the owner has not ruled on it |

The untyped SDK comes first because the examples gate needs it and because it needs only four
packages and one change to mopm (§4). The physical-plan surface needs the engine's closure
published. The order of the work is not a question for the owner.

## 1. The untyped SDK, `komira`: the page a stranger writes

**PROPOSED.** The whole program:

```mojo
from komira import Session, files

def main() raises:
    var session = Session()
    session.add_sql_binding("trips", files("trips.parquet"))
    var result = session.sql(
        "SELECT city, count(*) AS trips FROM trips GROUP BY city ORDER BY city"
    )
    print(result)
```

The setup around it, on Linux x86_64 or macOS on Apple silicon (macOS is built, but the install test
runs on Linux x86_64 only, so it is not yet proven there):

```sh
mopm init --name hello
# in the mopm.toml that init wrote, set: [toolchain] mojo = "1.1.0"
mopm add komira-ai/komira
mopm sync
mopm build main.mojo -o main --prefix .mopm/.pixi/envs/default
./main
```

The setup lines are sourced, not invented:
- `mopm init`, `[toolchain] mojo` and `mopm add komira-ai/<name>` are what the release's `prod-add`
  job does as a user ([docs/ci.md](../ci.md), "prod-add").
- `mopm sync` installs the compiler through pixi ([src/bench/README.md](../../src/bench/README.md)).
- The `mopm build ... --prefix .mopm/.pixi/envs/default` line is that README's own way to build an
  installed source.

*(inferred)* Building the user's own `main.mojo` the same way works too. The shared library comes
with the package (§2), so the user installs nothing else.

### Its names, and the C calls each one makes

The package is `komira-ai/komira`, imported as `komira`. It has four names, `Session`, `files`,
`Result` and `KomiraError`, and `Session` has two methods, `add_sql_binding` and `sql`. Each one is
a call the C interface already has. The Python package makes the same calls
(`python/komira/_native.py`, `_session.py`, `_sources.py`).

| name | what it is | the C calls (**EXISTS**, ABI version) |
|---|---|---|
| `Session(threads: Optional[Int] = None, memory_limit: Optional[Int] = None) raises` | one engine in the shared library; `Movable`, not `Copyable`; dropping it frees the context | `komira_ctx_new` (1.0), or `komira_ctx_new_with_options(threads, memory_limit)` (1.4) when either is given; `komira_ctx_free` (1.0) on drop |
| `files(location: String) raises -> Files` | a source value; it does no I/O | none: it holds the location |
| `session.add_sql_binding(name: String, source: Files) raises` | `name` reads `source` in later `sql` calls; binding a name again replaces it | `komira_add_sql_binding(ctx, name, source, len, KOMIRA_BIND_SESSION)` (1.10), with the source as `komira.plan.v1.WireBoundSource` bytes, encoded with the published `plan_proto` and `proto_codec` |
| `session.sql(query: String) raises -> Result` | runs one statement, raises on any refusal | `komira_sql_stream(ctx, sql, &stream)` (1.3), then the stream is read into Mojo values (§3) |
| `Result` | the answer: `num_rows()`, `num_columns()`, `column_names()`, `table()` (a `ref [self] Table`), and `Writable` for `print` | the stream's batches, read once and released (§3) |
| `KomiraError` (from `komira_error`) | what each call raises: `code`, `step`, `status` and the message | `komira_last_error` (1.0), `komira_last_error_code` and `komira_last_error_step` (1.7) |

The behaviour:
- **Options.** `threads` and `memory_limit` mean what they mean in Python's `Session(threads=...,
  memory_limit=...)`. Absent means the host's own value, and below 1 is refused before the call, as
  Python's `_option` refuses it. The library returns NULL when the engine does not start, and
  `Session()` then raises a fixed message, since there is no context to ask. Nothing reads an
  environment variable: configuration is passed in code, not in the environment.
- **`files`.**
  - An empty location is refused. A leading `~` is expanded and a relative path is made absolute
    against the working directory when `files` is called, as Python's `komira.files` does.
  - The location may be a Parquet file or a glob, which is what the `files` arm of `WireBoundSource`
    binds today (`src/so/bindings.mojo`).
  - A location is passed to the library as written. The library refuses a scheme it does not read
    (anything but `s3://`, `s3a://`, `az://`, `abfs://` and `abfss://`) with `STORAGE_URL_REFUSED`.
    It refuses a readable remote scheme with no sealed credential with `CREDENTIALS_NOT_FOUND`
    (`src/so/bindings.mojo`). `files` names no credential until slice 4.
- **CSV and JSON.** The session runs SQL text, so it reads a CSV or JSON file through SQL's own
  functions (`SELECT ... FROM read_csv('<file>')`), exactly as the SQL and TypeScript forms do.
  That needs no `files`.
- **Threads.** The C interface allows one thread at a time per context (`libkomira_run_abi.md`,
  §7). `sql` and `add_sql_binding` take `mut self`, so the compiler holds a session to one caller
  at a time. Two sessions share nothing.
- **Faults.** A fault the library treats as fatal ends the process. It does so for Python's and
  Node's callers too ([libkomira_run_abi.md](libkomira_run_abi.md), §8, the fail-fast list).
  Missing codec libraries are not such a fault: the library probes them before each run and
  refuses by name.

### Errors

- **Python and Node already raise a `KomiraError`.** It carries `code` (the named code, such as
  `SQL_SYNTAX_ERROR`), `step` (`parse`, `bind`, `optimize`, `lower` or `execute`), the C call's
  `status`, and the library's message `<step>: <reason>`.
- **Each has subclasses chosen by the code, then the step.**
  - Python has `ParseError`, `BindError`, `UnsupportedOperation`, `MemoryLimitError`,
    `CredentialsError`, `StorageError`, `LibraryLoadError` and `UnsupportedCpuError`
    (`python/komira/_errors.py`, `_CODE_CLASSES` and `_STEP_CLASSES`).
  - Node has `UnsupportedOperation`, `LibraryLoadError` and `UnsupportedCpuError`
    (`node/src/errors.ts`).
- **`komira` matches them.** Every call raises a `KomiraError` struct with `code: Optional[String]`,
  `step: Optional[String]`, `status: Optional[Int]` and the message. Its text is the message.
- **Where each field comes from.** After a status other than 0, `komira` reads the three last-error
  calls of the context before making any other call on it. The message comes from
  `komira_last_error`, the code from `komira_last_error_code`, and the step from
  `komira_last_error_step`. Its values 1 to 5 map to the step's name, and 0 means no step (`step`
  is `None`).
- **The same classes, as a value.** Mojo structs have no inheritance, so the class is a value, not a
  type. `KomiraError.error_class()` returns the name Python and Node use for the same refusal:
  `ParseError`, `BindError`, `UnsupportedOperation`, `MemoryLimitError`, `CredentialsError`,
  `StorageError`, `LibraryLoadError`, `UnsupportedCpuError`, or else `KomiraError`. The mapping is
  Python's: its code-then-step tables, `_CODE_CLASSES` and `_STEP_CLASSES`. TypeScript's is coarser.
  Node's `errorClass(status, code)` has no step table, has one subclass for refusals
  (`UnsupportedOperation`, else `KomiraError`), and maps fewer codes than Python
  (`COPY_TYPE_UNSUPPORTED`, `TABLE_TYPE_UNSUPPORTED` and `COPY_COMPRESSION_UNSUPPORTED` are
  Python's only). So a refusal TypeScript calls `KomiraError` can be a `ParseError` in Python and in
  Mojo. The two codes `komira` raises itself (below) map to `LibraryLoadError`
  (`LIBRARY_VERSION_UNSUPPORTED`) and `UnsupportedCpuError` (`CPU_UNSUPPORTED`).
- **Two codes are new.** `LIBRARY_VERSION_UNSUPPORTED` and `CPU_UNSUPPORTED` are **PROPOSED** for
  the Mojo packages alone: they come from checks `komira` makes before the library is called.
  Python's `LibraryLoadError` and `UnsupportedCpuError` carry no code.
- **Where it lives.** `KomiraError` and `error_class()` live in a small package of their own,
  `komira_error`, with no dependencies. `komira` and `komira_physical` both import it, so a
  physical-plan error has the same type as a session error, and `komira_physical` does not depend on
  `komira` or on the shared library.
- **Typed raises.** A `KomiraError` raised by type needs the pinned compiler's typed raises:
  `def sql(mut self, query: String) raises KomiraError -> Result`. No function under `src/`
  declares one yet, so slice 1 first proves them on the pinned Mojo with a standalone program that
  uses no komira code. The repository asks that a claim about the compiler be shown by such a
  small program.
- **The fallback.** If typed raises do not work there, every call raises a plain `Error` with the
  same text and the code at the start of the reason. A later move to `KomiraError` would change the
  signatures, a public interface change, so this is settled before the first release.

### `Result`, and `print(result)` when formatting fails

- **What it holds.** `Result` holds the `arrow.table.Table` read from the stream. `Table` is
  `Movable`, so `Result` lends it by `ref` and does not copy it.
- **How `print(result)` looks.** It writes the result as a table between `+---+` rules: column
  names, a row of short type names, one line per row (at most 20), then the row count (`N rows`,
  with `(showing 20, ... M more rows)` when rows were cut). A result with no columns prints `(empty:
  0 columns, N rows)`.
- **The printer.** It is `format_table`, which **EXISTS** in `sdk` (`src/sdk/table_display.mojo`)
  and imports only `arrow`.
  - It takes a `RecordBatch`, and a `Table` is chunked. So slice 1 moves it into `arrow` and gives
    it a `Table` overload, which reads the first 20 rows across the chunks without consuming the
    table.
  - Its tests move with it: `src/sdk/tests/test_table_display_direct.mojo`,
    `test_display_stats.mojo` and `test_display_width_non_ascii.mojo`, from `sdk`'s `test_srcs` to
    `arrow`'s.
  - `sdk`, its README and its other tests then import it from `arrow`. `komira` prints without
    depending on `sdk`.
- **When formatting fails.**
  - `format_table` is declared `raises`. A cell it cannot render raises, for example.
  - `Writable`'s `write_to` cannot raise at the pinned compiler. Every one of the 67 `write_to`
    methods under `src/` is declared without `raises` (`git grep -n "def write_to" --
    'src/*.mojo'`), for example `def write_to[W: Writer](self, mut writer: W)` in
    `src/arrow/schema.mojo`.
  - So `Result` does not format inside `write_to`. `sql` formats the first 20 rows once, when it
    builds the `Result`, and keeps the text.
  - A query that ran is never lost to a printing failure. If formatting fails, `sql` still returns
    the rows, and the `Result` keeps instead one fixed line naming the failure:
    `komira: the result could not be printed: <format_table's message>`. The rows stay readable
    through `table()`.
  - `print(result)` writes the kept text, the table or that line, and cannot fail, so the user never
    sees a half-printed table.
  - The cost is formatting at most 20 rows per query *(inferred: small next to running it)*.

### Logical plans

The C interface's other way in is a logical plan: `komira_plan_stream(ctx, plan, len, &stream)`
(1.8), with a `komira.plan.v1.WirePlanEnvelope`. Python's DataFrame terminals send one today.

A Mojo logical-plan API over it rests only on what is published:
- `plan_proto`'s `WirePlan` messages and `proto_codec`'s `encode_proto`;
- the scan bindings `komira_parquet_schema`, `komira_csv_binding` and `komira_json_binding` (1.1),
  which give each scan leaf its schema and fingerprint.

It is the untyped SDK's frame API, not the physical-plan builder of §5. Its names belong with
Python's two frame APIs ([dataframe_surface.md](dataframe_surface.md)), and it gets a design of its
own (slice 5). It adds no library to publish.

### What the C interface does not offer

These are gaps in the C interface, listed for its own design. `komira` does not build around them
in Mojo:
- **`files` over CSV or JSON.** `WireFileSource` has no format field, so a `files` source is
  Parquet. CSV and JSON register only one file at a time (`komira_register_csv`,
  `komira_register_json`). SQL's `read_csv` and `read_json` cover the session meanwhile.
- **A spill directory.** A context takes only a worker count and a memory budget
  (`src/so/README.md`, "Not done").
- **Cancel and progress for a plan run.** Only `komira_sql_stream_run` takes a run handle; there is
  no `komira_plan_stream_run`.
- **A way to report which Mojo runtime the library was built with.** Python compares the runtime
  libraries' build ids itself (`python/komira/_runtime.py`). A call returning the build's Mojo
  version would let every binding check it the same way (§2).
- **A printer of a result.** The library returns Arrow only. Each SDK prints in its own code. A
  shared printer is the task-examples design's question (komira-ai/komira#2495, section 3).

## 2. How the shared library reaches a Mojo user

**What the package carries, per platform.** The library already exists as the self-contained
directory `//src/so:libkomira[dist]`, which the wheel copies whole into `komira/_lib/`
(`python/BUCK`). `komira` carries the same files except the three Mojo runtime libraries, which the
user's own Mojo already has (below).

| platform | files | built today |
|---|---|---|
| Linux x86_64 | `libkomira.so`, and the 11 native libraries it needs (`libkomira_<owner>_native.so.1`). Sizes: 3,752,832 bytes for the library, about 4.9 MB for the 11 (`src/so/README.md`, its size table) | yes |
| macOS arm64 | `libkomira.dylib` alone: the native code is linked into it, with install name `@rpath/libkomira.dylib` | yes, on the farm's Macs |
| Linux arm64 | none | no |

Linux arm64, said for each package:
- **`komira`** has no linux-arm64 build because the shared library has none. That is listed with
  the gate's exceptions (the gate question of komira-ai/komira#2495).
- **`komira_physical`** does not use the shared library, and it is not built for linux-arm64 either.
  No mopm package is built for linux-arm64 today ([docs/releases.md](../releases.md)), and its
  closure links `awslc`, whose static archive has no linux-arm64 build (`src/awslc/README.md`:
  "Not built: ... the linux arm64 assembly set"). It is outside the gate, so this is no gate
  exception.

**mopm cannot carry it yet.** What a mopm package can declare today:
- `[native.<id>]`: a static archive only, linked into the user's program (`mopm pack` refuses
  anything else);
- `[native-dependencies]`: a library from conda-forge, opened at run time (`mode = "load"`), as
  `compression` opens libzstd.

Both facts come from mopm's `docs/configuration.md` in komira-ai/mopm. Neither route carries a
library komira builds itself as a shared library.

**PROPOSED: a third kind in mopm.**
- mopm's manifest already reads `[native.<id>] kind = "shared"`, but `mopm pack` and
  `mopm publish` refuse it. komira-ai/mopm learns to pack and publish one: prebuilt shared
  libraries that mopm installs into the environment's `lib/`, beside the conda-forge ones.
- Whether the 11 native libraries land flat beside `libkomira.so` or in a `lib/` below it, as in
  `[dist]`, is that design's choice. The run path `$ORIGIN/lib:$ORIGIN` finds either.
- That is mopm's own pull request and design, then a bump of the mopm pin here.
- mopm's limits allow it *(inferred)*. The Linux package file is about 9 MB, under its 100 MB
  limit per package file and 512 MiB unpacked. The 12 libraries are files inside one package file,
  so the limit of 20 package files per version does not count them.

**How `komira` opens it.**
- `komira` opens `libkomira.so` (`libkomira.dylib` on macOS) by name. That is the same way
  `compression` opens `libzstd.so.1` from the environment's `lib/` *(inferred: through the same
  search path mopm gives a `mode = "load"` library)*.
- The 11 native libraries are found through its run path `$ORIGIN/lib:$ORIGIN`.
- The host's C++ runtime (`libstdc++.so.6`, `libgcc_s.so.1`), which `[dist]` leaves out for the
  host to give, must be in the environment or on the host. Which one gives it in a mopm project is
  not verified yet *(inferred: the Mojo compiler's own environment has it)*, and slice 1's install
  test settles it.
- The user gives no path and sets no environment variable: configuration is passed in code, not
  in the environment.
- The library is opened once per process and never closed:
  - the library is linked `DF_1_NODELETE`, because the Mojo standard library's process-wide
    values must outlive it (`tools/build/mojo/shared_lib.bzl`);
  - the release callbacks of every stream it returns are its own code
    ([libkomira_run_abi.md](libkomira_run_abi.md)).

**One Mojo runtime in the process.**
- The library needs `libKGENCompilerRTShared` and the two runtime libraries it needs in turn. A Mojo
  program has them loaded already.
- The loader matches a needed library by name against the libraries already loaded. So the shared
  library binds to the user's own runtime, and a second copy is never mapped *(inferred)*.
- That is the first row of the measured table in
  [mojo_runtime_pypi_vs_conda.md](mojo_runtime_pypi_vs_conda.md), which was measured in a Python
  process with Modular's runtime loaded first. A Mojo program built by `mopm build` is not measured
  yet. Slice 1's install test is that measurement.
- That is safe only for the same build of the runtime:
  - `komira`'s `mopm.toml` says `mojo = ["1.1.0"]`, the pin the library is built with
    (`tools/build/platforms/table.bzl`, every row);
  - `mopm add` resolves a package only for the project's Mojo.
  - So a program on another Mojo does not get this build of `komira`.
- Python also compares the runtime's build ids before it loads the library (`_runtime.py`). The same
  check in Mojo waits on the C interface gap of §1: a call that reports the build's Mojo version.

**The CPU.**
- On Linux the library is built for x86-64-v3. `komira` reads the CPU's flags before it opens the
  library. On a CPU without them it raises a `KomiraError` with code `CPU_UNSUPPORTED` naming the
  missing flags, where Python raises `UnsupportedCpuError`.
- The variants directory of [isa_variants.md](isa_variants.md) (a `VARIANTS` manifest and an
  x86-64-v2 floor) needs the same selector in Mojo as in Python. That is slice 3.

**Licences.**
- `komira` carries no Modular runtime library, so no Modular licence file *(inferred)*.
- It carries the notices of the third-party code inside the library and its native libraries, as
  the wheel does ([wheel_licence_audit.md](wheel_licence_audit.md)).

## 3. The FFI boundary

The FFI boundary is one private module, `komira._lib`. It owns every foreign pointer, and its
`# FFI-BOUNDARY:` header says who owns and frees each one. Every `UnsafePointer` in it has an adjacent
`# SAFETY:` comment saying why it is sound. The wildcard origins (`MutUntrackedOrigin`), which the
repository allows only in a module's FFI internals, appear only there. So `komira._lib` takes a row
in `tests/pointer_lint_ffi.tsv`, the pointer lint's list of FFI modules, naming the foreign resource
it owns: "the libkomira shared library: its handle, the session's context, the C strings and buffers
of each call, and the ArrowArrayStream each query returns". The repository already has the pattern
in two places:
- `src/so/tests/gate/*.mojo` and `src/tests/helpers/komira_plan_harness/door.mojo` open libkomira
  from Mojo and call it;
- `compression/codec_libraries.mojo` has a process-wide handle slot and a raising opener.

| foreign thing | who owns it | who frees it, and when |
|---|---|---|
| the library handle (`OwnedDLHandle`) | `komira._lib`, in one process-wide slot, opened on the first `Session()` | never: the library stays open (§2) |
| the context (`void *` from `komira_ctx_new*`) | the `Session`, as a private `Int` word | `komira_ctx_free`, once, when the `Session` is dropped |
| C strings (name, path, SQL text) | `komira._lib`: a NUL-terminated copy of the Mojo `String`, built for the call; a `String` holding a NUL is refused first, as Python refuses one | the copy is dropped after the call. The library copies what it keeps |
| `WireBoundSource` bytes | `komira._lib`, a `List[UInt8]` from `encode_proto` | dropped after the call; the library copies them |
| error text and code (the two-call protocol) | `komira._lib`: it asks for the length, then allocates exactly that and asks again | dropped once copied into the `KomiraError` |
| the `ArrowArrayStream` struct | `komira._lib`, allocated on the heap and zeroed. `arrow_ipc/c_data_stream.mojo` records that a stack slot is unsound for its scratch schema and array structs, because the compiler may reuse the slot; the same holds for the stream struct *(inferred)* | the library fills it only on success. `arrow_ipc.c_stream_table.drain_record_batch_stream_table` copies every buffer into a `Table` and calls the stream's `release` once, on every path, unless the stream is already released. Then `komira._lib` frees the struct |

The steps on the first `Session()`:
1. Open the library.
2. Resolve `komira_abi_version` alone and call it. A major other than 1 is refused. So is a minor
   below 10, because `add_sql_binding` needs 1.10. The refusal is a `KomiraError` with code
   `LIBRARY_VERSION_UNSUPPORTED` that names both versions.
3. Resolve the other calls.

No public name takes or returns a pointer:
- `Session` holds an `Int`;
- `Files` holds a `String`;
- `Result` holds a `Table`;
- `KomiraError` holds strings and an `Int`.

`arrow_ipc`'s `CArrowArrayStream` is a public struct with pointer fields, so `komira` imports it
only inside `komira._lib` and never names it in its own API.

## 4. What `komira` needs published

`komira` imports `komira_error` (for `KomiraError`), `arrow` (for `Table` and `format_table`),
`arrow_ipc` (to read the stream) and `plan_proto` with `proto_codec` (for `WireBoundSource`).
`komira_error` is new and imports nothing. Their closures, from `./buck2 uquery
"deps(//src/<name>:<name>)" --output-attribute deps` with the `deps` attribute walked and test
dependencies left out:
- `arrow` (11 libraries, with itself): `arrow`, `atomic_alias`, `byte_buffer`, `compression`,
  `containers`, `counters`, `host_probe`, `libc`, `lz4`, `simd_ops` and `zlib`.
- `arrow_ipc`: `arrow`'s closure, plus `async_api` and itself.
- `plan_proto` (5 libraries, with itself): `encoding`, `json`, `plan_proto`, `proto_codec` and
  `protobuf`.

Of those 18, all are published except two:
- `arrow`: UNPUBLISHED.md's reason is "none". Its README has examples and every library it imports
  is published.
- `arrow_ipc`: its reason is "depends on an unpublished library", namely `arrow`.

So the untyped SDK publishes **four packages**, `komira_error`, `arrow`, `arrow_ipc` and `komira`,
plus the mopm change of §2. Notes on them:
- **Coverage.** By the census of 2026-10-10 (each library's `coverage_census.tsv`), `arrow` has
  67.8% line coverage of 7,042 lines and `arrow_ipc` 86.1% of 6,827. The repository holds every
  package a pull request touches to 99% line and branch coverage, so both need tests first. The pull
  request's check measures again.
- **Names.** `arrow` and `arrow_ipc` are claimed on the prod registry already
  (`release/prod_claimed_names.txt`). `komira` and `komira_error` are not.
- **Why a binding, not `komira_register_parquet`.** The first slice binds a file through
  `komira_add_sql_binding`, with the source encoded as protobuf, although `komira_register_parquet`
  (1.1) takes a bare path. Sources are values in every SDK (credentials_and_writes.md, decision 12),
  and the same `files` value later carries a credential for a remote file, which
  `komira_register_parquet` cannot. The encoding libraries are published already, and the logical
  plans of slice 5 need them anyway. Their cost is the five libraries of the `plan_proto` set,
  counted in the 19 below.

The engine is compiled once, by the release, into the shared library, as it is for the wheel. A
user's build of a program that imports `komira` compiles `komira` and the 19 libraries of its
closure: `komira_error`, the 13 of `arrow` and `arrow_ipc`, and the 5 of the `plan_proto` set. None
of them is an engine library *(inferred: a `.mojoc` holds no machine code, so the user's build
compiles every library it imports)*.

## 5. Mojo physical plan: `komira_physical`

**PROPOSED.** A separate package, `komira_physical`, imported as `komira_physical`. The user's code
writes the physical plan: the pipelines, the operators inside each one, and the step that ends each
pipeline. The plan goes to the executor as written. There is no binder, no optimizer and no
lowering, so nothing reorders, pushes down, fuses or chooses a sink for the user. Schemas are
run-time values: the plan reads them from the sources when it is submitted.

It looks different from the untyped SDK and has no counterpart in the C interface. It is the one
Mojo surface that links the engine's Mojo libraries, so its user pays the engine's compile time.
Its engine is an `Engine` value of its own, over `sdk_exec`'s `EngineContext`, in the user's
process. It does not use the shared library.

### What exists to build on

All of this is **EXISTS** and public:
- **The physical plan** (`src/physical_plan/physical_plan.mojo`, IR version 21). A plan is a list of
  `SegmentDescPod`, one per pipeline. Each holds a source (`SourceSpecPod`, for example
  `SourceSpecPod.parquet(path, projection, pushed_filter, spec_is_total, fs)`), a chain of
  `MorselOp` (`filter`, `project`, `limit`, `join_probe`), and a sink tag (`SINK_AGG`,
  `SINK_COLLECT`, `SINK_SORT`, `SINK_TOPN`, `SINK_HASH_BUILD`, ...). The sink also has a key type
  tag, an orientation, an order key and its dependencies with their edge tags.
- **The plan as lowering emits it.** `LoweredPlan(segments, params, result_seg_id)`
  (`src/lowering/lowered_plan.mojo`). Its `ParamTable` holds each sink's data by index. For example
  `AggSinkData(group_by_exprs, agg_exprs, output_schema, ...)` (`src/physical_plan/sink_data.mojo`).
- **Expressions.** `Expr` is an owned tree with factories (`Expr.col_ref(name)`, `Expr.col_idx(i)`,
  `Expr.literal(ScalarValue...)`, `Expr.binary(op, l, r)`). `AggExpr(func, child, alias)` holds an
  aggregate (`src/plan_expr`).
- **The executor's entry point.** `run_lowered_plan_with(ctx, lowered, opener) raises ->
  RecordBatch` (`src/sdk_exec/engine_execute.mojo`). It feeds the `ParamTable` to the segment
  builder in index order and runs the segments on the context's workers.
- **A precedent.** `src/pipeline_exec/tests/test_group_agg_plan.mojo` builds a scan, filter and
  grouped-aggregate plan by hand. `src/pipeline_exec/plan_harness.mojo` has its helpers, which are
  test support.

None of those public signatures takes or returns a pointer (§7).

### What the user writes, for one real pipeline

One local Parquet file, scanned, filtered, grouped and aggregated, then printed. In SQL this is
`SELECT city, count(*) AS trips, sum(fare) AS total FROM 'trips.parquet' WHERE fare > 10 GROUP BY
city`. *(PROPOSED; the spelling of list arguments follows whatever the pinned compiler accepts for
lists of the SDK's `Expr`.)*

```mojo
from komira_physical import Engine, PhysicalPlan, parquet, col, lit, count_rows, sum_of

def main() raises:
    var engine = Engine()
    var plan = PhysicalPlan()
    # One pipeline: a Parquet scan, a filter, and a hash aggregate, the sink that ends it.
    var trips = plan.pipeline(parquet("trips.parquet", columns=["city", "fare"]))
    plan.filter(trips, col("fare") > lit(10.0))
    plan.hash_aggregate(trips, keys=[col("city")],
                        aggregates=[count_rows("trips"), sum_of(col("fare"), "total")])
    plan.set_result(trips)
    var result = engine.run(plan^)           # check the plan, then run it as written
    print(result)
```

`engine.run` returns a `Result` of `komira_physical`'s own, over the result batch. It prints the
same `format_table` text as `komira`'s `Result`, by the same rule: the first 20 rows are formatted
when it is built, and a formatting failure keeps the rows and prints one fixed line (§1). So a Mojo
physical plan example prints the same way as a Mojo example. The pipeline's output schema, a
run-time value, is read with `engine.schema_of(plan, trips)` when a program wants it.

Each call maps to the IR, and the builder fills the fields the user does not choose:

| builder call | what it emits |
|---|---|
| `plan.pipeline(parquet(path, columns))` | a `SegmentDescPod` with `SOURCE_PARQUET` and `SourceSpecPod.parquet(path, columns, None, spec_is_total=True)`; its id is its position. The IR says the flag is derived and never declared, so the builder makes it true by what it accepts: one local file (a glob or a directory is listed into `SourceSpecPod.parquet_files` first) |
| `plan.filter(p, e)`, `plan.project(p, exprs, names)`, `plan.limit(p, n)` | `MorselOp.filter`, `MorselOp.project` and `MorselOp.limit` appended to that pipeline |
| `plan.hash_aggregate(p, keys, aggregates)` | sink `SINK_AGG`, with the key type tag taken from the key's type in the run-time schema (`KEY_DTYPE_STRING` here, `KEY_DTYPE_COMPOSITE` for several keys) and always `SINK_ORIENT_COLUMNAR`; lowering may pick `SINK_ORIENT_DICT_ENCODED` from footer facts, which the builder does not read. The `AggSinkData` is appended to `params.agg`, and its `output_schema` comes from the input schema and the aggregate list. `ORDER_ROW_RANGE` is set when a sum or mean is over a float, so the answer does not depend on the worker count |
| no sink named | `SINK_COLLECT` |
| `plan.pipeline(output_of(p))` | `SourceSpecPod.from_sink_output(p)`, with `p` in the new pipeline's `deps` and the waiting edge `EDGE_E3_PUBLISH_WAIT` |
| later: `sort`, `top_n`, `hash_join(build=p1, probe=p2, ...)` | `SINK_SORT`, `SINK_TOPN`, and `SINK_HASH_BUILD` on `p1` with `MorselOp.join_probe` on `p2` |
| `engine.run(plan)` returns a `Result` | reads each source's schema, checks the whole plan (below), builds the `LoweredPlan`, and calls `run_lowered_plan_with(ctx, lowered, LocalOnlyScanFs())` |

The user chooses the shape: how the plan is cut into pipelines, where a filter runs, which sink ends
each pipeline, and which side of a join is built. That is what this surface has and the untyped
SDK does not. The builder
chooses only what follows from those choices.

### What lowering guarantees today, and how the plan builder checks it instead

`lower` builds most invariants by construction. The executor checks part of the rest:
- `check_plan` (`src/pipeline_exec/plan_check.mojo`) runs before any pipeline does.
- `RealBuilder` checks each pipeline as it builds it, after earlier pipelines have already run.
- A few things nothing checks.

A hand-built plan could break any of them, so the plan builder's rule is a check at submit, before
any pipeline runs. A broken plan is refused by name and never crashes. The table shows what the
executor does today with a broken plan and what the plan builder does.

| invariant | today, for a plan `lower` did not build | the plan builder |
|---|---|---|
| IR version, ids equal positions, deps in range and acyclic, edge tags with a policy, the order key only on `SINK_AGG` | named, before any pipeline runs (`check_plan`) | by construction, and `check_plan` still runs |
| the Parquet spec is total | a named refusal at build | by construction (one file, or a listed set) |
| a sink's data index is in range for its sink kind | named, but late (at that pipeline's build) | by construction: the builder assigns the indices and feeds them in order |
| the sink's (kind, key type, orientation) is one the executor serves | named, late. The capability table (`lowering.sink_capability.admit_plan`) is checked only inside `lower`, and `pipeline_exec` does not import it | checked at submit: `PHYSICAL_PLAN_SINK_UNSERVED` |
| a join probe's build pipeline ends in `SINK_HASH_BUILD` | **not checked**: the probe takes whatever the build pipeline published | by construction (`hash_join` names both sides) |
| the result pipeline is published and is the plan's only root | partly: a missing result is named; a stray root is not checked | checked at submit: `PHYSICAL_PLAN_RESULT_NOT_ROOT` |
| a column named in an expression exists in the rows that reach it | named, but at the first morsel, inside a worker | checked at submit against the run-time schema: `PHYSICAL_PLAN_COLUMN_UNKNOWN` |
| a column given by position is in range | **unchecked in a release build**: `Slab.__getitem__` is a `debug_assert` only, so an out-of-range ordinal reads out of bounds | the builder's expressions name columns by name and never by position |
| expression types fit (a filter is boolean, a sum is over a number) | partly: aggregate output types at sink build (`check_declared_type`), the rest when a kernel meets the data | checked at submit: `PHYSICAL_PLAN_TYPE_MISMATCH` |
| a sink's `output_schema` agrees with what the sink produces (names, types, nullability) | partly: `check_declared_type`, and a NULL in a non-nullable column at run time | by construction: the builder derives it |
| no logical plan or correlated subquery inside an expression | checked only inside `lower` (the purity gate). The evaluator returns NULL for that tag, so the result would be wrong | by construction: the builder's expressions have no subquery |
| a float sum gives the same answer at any worker count | not checked; lowering sets `ORDER_ROW_RANGE` | by construction (the table above) |

Two changes make this hold, both **PROPOSED**:
- **In the executor.** The sink capability table moves from `lowering` to `physical_plan`, and
  `check_plan` runs it for every plan before any pipeline runs. `check_plan` and `run_plan` take
  only the segments, and the result segment's id lives in `LoweredPlan`, which `pipeline_exec`
  does not depend on. So the check that the result pipeline exists and is the plan's only root
  goes in `run_lowered_plan_with` in `sdk_exec`, before it calls `run_plan`. Today a missing
  result is named only after the whole run (`out.take(lowered.result_seg_id)`). A lowered plan
  passes both checks, and the table becomes the one list `lowering` and the executor share.
- **In `komira_physical`.** The checks that need schemas: column names, types and output schemas.
  The builder holds the flowing schema of each pipeline when the plan is submitted, so it can run
  them.

Each refusal is a `KomiraError` from `komira_error` (§1) whose code is the name above and whose
message names the pipeline, the operator and the column. `komira_physical` depends on `komira_error`
and on the engine's closure (below), and not on `komira` or the shared library.

### What is stable enough to expose, and what is not

The physical IR is not stable, and the design documents say so:
- [lowering_and_pipeline.md](lowering_and_pipeline.md) §2.2 calls it the interim IR and lists six
  changes still to come: `parquet_spec_is_total` goes, the `ParamTable` indices become inline sink
  parameters, `cancel_slot` and `error_slot` go, logical subtrees become pipeline references, a wire
  form replaces the version check, and each pipeline gets a memory budget. Every one of them breaks
  a plan written against today's fields.
- The version check is an exact match. A producer and the executor must be the same build.
- The IR changes about weekly. Commits since 2026-10-01 (`git log --since=2026-10-01 --oneline --
  <dir> | wc -l`): `physical_plan` 12, `lowering` 25, `pipeline_exec` 23.

So:
- **Exposed.** The builder's own vocabulary:
  - `PhysicalPlan` and `PipelineId` (an id, not an `Int`);
  - the sources: `parquet` now, and CSV and JSON later;
  - the operators `filter`, `project` and `limit`;
  - the sinks `hash_aggregate` and collect, then `sort`, `top_n` and `hash_join`;
  - the expressions: `col`, `lit`, comparisons, arithmetic, `and`, `or`, `not`, `is_null`;
  - the aggregates `count_rows`, `count`, `sum_of`, `min_of`, `max_of`, `mean_of`;
  - `Schema` and `RecordBatch` from `arrow`.

  These words name what the executor does: a pipeline ends at the sink that breaks it,
  lowering_and_pipeline.md §2.3. They outlast any one layout of the IR *(inferred)*.
- **Not exposed.** `SegmentDescPod`, `SourceSpecPod`, `MorselOp`, `ParamTable`, sink indices, edge
  tags, `ir_version`, key type and orientation tags, order keys, morsel sizes, the estimates and the
  slots. The builder writes them. When the IR changes, the change updates the builder and its welded
  tests in the same pull request, because `komira_physical` is built in this
  repository. A user's program
  does not change.

One design statement bears on the plan builder. lowering_and_pipeline.md (§2.2, "Exit condition")
says no consumer of the interim IR exists outside `pipeline_exec`, and nothing serializes a
`LoweredPlan`, until the self-contained IR lands. The plan builder adds a second producer, in the
same process and the same build, and nothing serializes its plans. This document reads that as
allowed. Read the other way, as also closing the IR to a second producer, it would make the plan
builder wait for the self-contained IR. That is a question of when, not of what exists at the end,
so this design settles it by the reading above ("What the design decides, and why").

### Which libraries it needs

`komira_physical` links the engine: `sdk_exec` for `EngineContext` and `run_lowered_plan_with`, and
`physical_plan`, `plan_expr`, `plan_ir`, `lowering`, `pipeline_exec` and `parquet_footers` for the
plan and its schemas. So it needs the engine's closure published, which the next section computes.

The executor alone is smaller, computed the same way:
- `pipeline_exec`'s closure is 69 libraries, 45 of them unpublished, with no `sql`, `optimizer` or
  `lowering`;
- `lowering`'s is 21.

The entry point the builder uses needs `EngineContext`, though. That holds the SQL catalog (`sql`)
and the footer cache (`parquet_footers`, whose closure has `sql` and `lowering`). A narrower package
would need an execution context outside `sdk_exec`. That is a later refactor, not this design.

### How the plan builder is tested

- **The README example.** The README of `komira_physical` holds the plan above. It writes its input
  file first, with `komira_physical`'s `write_parquet(batch, path)` over `sdk_exec`'s
  `write_parquet_result`, and asserts the rows. So the install test runs it against the installed
  packages.
- **Task pages.** This surface is the form "Mojo physical plan", key `mojo_plan`. Its tree is
  `src/komira_physical/docs/tasks/`, in its own package, as komira-ai/komira#2495 places a tree, and
  it has its own tab. This path replaces `src/komira/docs/mojo_plan_tasks/` of the text the two
  designs shared earlier, which assumed both forms were one package. A task is shown in that form
  only when the builder can write its plan. Until the builder lands, every task's `mojo_plan` record
  is `not-shown`, with that reason.
- **Welded tests.**
  - The same query through `komira` and through `komira_physical` gives the same rows.
  - Each submit refusal of the table above is asserted by its exact message: an unknown column, a
    filter that is not boolean, a sum over a string, an unserved sink, a result pipeline that is
    not the root, and a pipeline that reads the output of a pipeline that does not exist.
  - Under the executor change, a hand-made `LoweredPlan` with an unserved sink and one with a stray
    root are refused before any pipeline runs.

### The engine's closure

#### How it was computed

From the BUCK graph, not estimated:
- `./buck2 uquery "deps(//src/sdk_exec:sdk_exec)" --output-attribute deps --output-format json`
  (a query, not a build).
- Then the `deps` attribute was walked transitively from `//src/sdk_exec:sdk_exec`. Only Mojo
  library targets were kept (`mojo_library`, and `mojo_adopted_library` with the deps of its
  `:lib`).
- Test dependencies are left out, because `test_deps` never reach a package.
- For each library the result was matched to `PACKAGES` (published) and to the row of
  `release/UNPUBLISHED.md` (not published, with its reason).

The result:

| | libraries |
|---|---|
| `sdk_exec`'s closure, not counting `sdk_exec` | **93** |
| published (in `PACKAGES`) | 32 |
| not published | 61 |
| of the 61: depends on an unpublished library | 36 |
| of the 61: no README example | 17 |
| of the 61: native dependency pending | 6: `async_rt`, `fs`, `http_core`, `objectstore`, `parquet_codec`, `scan_source` |
| of the 61: none (ready now) | 2: `arrow`, `secret_store` |

Three facts about the graph:
- **The declared `deps` are incomplete.** `sdk_exec`'s own `deps` list 87 of the 93. The other 6
  (`decimal_literal`, `iceberg`, `op_agg_hash`, `op_fused_kernels`, `op_join_build`, `rowcell`) are
  reached only through its dependencies. A library's `deps` must list its full closure. Slice 6 adds
  the 4 of them that stay in the recommended closure (`iceberg` and `rowcell` leave it).
- **The ledger's import lists can be shorter.** For several libraries the "imports" in
  UNPUBLISHED.md (each library's own imports) name fewer libraries than its BUCK `deps` (which hold
  the full closure). Two examples:
  - `sdk`: the ledger names 8, and BUCK adds `agg`, `arrow_ipc`, `expr`, `kernels`, `op_agg_state`,
    `parquet_codec` and `plan_stats`;
  - `pipeline_exec`: BUCK adds 10.

  The order below follows BUCK, so it never publishes a library before something it builds with.
  Some libraries could go a wave earlier by their imports alone.
- **Iceberg brings in the whole HTTP stack.** One module of `sdk_exec`, `engine_iceberg.mojo`
  (`register_iceberg_table`), imports `iceberg_catalog`. That alone brings in `http_client`,
  `http_core` (with s2n-tls), `net` and `iceberg`. No other module of `sdk_exec` imports any of
  them. SQL's `iceberg_scan('<path>')` does not need them: `engine_lower.mojo` imports
  `iceberg_scan`, which stays.

#### The recommended closure: without `engine_iceberg`

**PROPOSED**: slice 6 moves `engine_iceberg.mojo` into a library of its own, `sdk_exec_iceberg`.
- No `.mojo` file outside `sdk_exec` imports it. `src/so/BUCK` lists `iceberg_catalog` and
  `iceberg_scan` among its deps, but no source under `src/so` names `engine_iceberg` or
  `register_iceberg_table`.
- Its one user, `sdk_exec/tests/test_run_sql_iceberg.mojo`, moves with it, with the test data its
  BUCK names.
- Its README section moves with it.
- It takes a row in UNPUBLISHED.md ("depends on an unpublished library": `iceberg_catalog`,
  `sdk_exec`).

The same walk over the imports of `sdk_exec`'s other modules then gives:

| | libraries |
|---|---|
| closure | **86**, plus `sdk_exec` |
| published | 30 (`rowcell` and `uuid` leave the closure) |
| to publish | **56**, then `sdk_exec`, then `komira_physical`: **58 packages** |
| of the 56: depends on an unpublished library | 33 |
| of the 56: no README example | 16 |
| of the 56: native dependency pending | 5: `async_rt`, `fs`, `objectstore`, `parquet_codec`, `scan_source` |
| of the 56: none | 2: `arrow`, `secret_store` |
| left out of the physical-plan surface's first package (Iceberg catalogs) | `http_client`, `http_core`, `iceberg`, `iceberg_catalog`, `net`, `sdk_exec_iceberg` |

The split matters most for `http_core`. It is the one native library with no path in a single pull
request: s2n-tls built on komira's renamed aws-lc (`komira_s2n_*` called by `external_call`) would
become a new `native_library`, and its renaming build runs on linux-x86_64 only today. Leaving it
out keeps the hardest native step off the road to the first physical plan. The untyped SDK reads
Iceberg tables through the shared library meanwhile, since the library links all of this already.

#### Published already (30 of the 86)

`async_api`, `atomic_alias`, `awslc`, `byte_buffer`, `clock`, `compression`, `containers`,
`counters`, `crypto`, `dynamic_filter`, `encoding`, `fork_join`, `hashing`, `host_probe`, `json`,
`libc`, `log`, `lz4`, `metrics`, `name_registry`, `parquet_api`, `plan_proto`, `proto_codec`,
`protobuf`, `scalar_arithmetic`, `simd_ops`, `spsc_ring`, `sync`, `trace`, `zlib`.

`sdk_exec`'s `deps` also name `runtime_paths` (published) through the alias
`//tools/build/mojo/runtime_paths`. No source of `sdk_exec` outside `tests/` imports it, so it is a
test dependency. The walk does not count it, and a package lists it under `[dev-dependencies]`, as
`log` does.

#### The 56, in publishing order

`arrow` and `arrow_ipc` (waves 1 and 2) are published by slice 1 for the untyped SDK (§4), so 54
are left when this surface starts.

The wave of a library is one more than the highest wave among its unpublished BUCK `deps`. Wave 1
needs only published libraries. Libraries in the same wave do not depend on each other, so they can
go in one pull request or in several. Earlier moves have put five to nine libraries in one pull
request (komira-ai/komira#2006 moved nine).

The columns:
- "reason today" is UNPUBLISHED.md's reason.
- "coverage" is the line coverage in the library's own `coverage_census.tsv`, measured by the census
  of 2026-10-10 (`csv`'s of 2026-10-27). "not measured" means the library has no census file. These
  numbers are old. The pull request's check measures again, and the repository holds every touched
  package to 99% line and 99% branch.
- "unpublished deps" counts the library's BUCK `deps` among the 56.
- "work before or in its pull request" lists the work. "claim the name" means a maintainer claims
  `komira-ai/<name>` on the prod registry first, a step outside the repository
  (`release/prod_claimed_names.txt`). The release refuses a member whose name is not claimed.

| wave | library | reason today | coverage | unpublished deps | work before or in its pull request |
|---|---|---|---|---|---|
| 1 | `arrow` | none | 67.8% | 0 | tests to reach 99% line and branch |
| 1 | `phase_timers` | no README example | not measured | 0 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 1 | `secret_store` | none | 100.0% | 0 |  |
| 2 | `arrow_ipc` | depends on an unpublished library | 86.1% | 1 | tests to reach 99% line and branch |
| 2 | `column_format` | depends on an unpublished library | 77.6% | 1 | tests to reach 99% line and branch |
| 2 | `exec_types` | no README example | 47.3% | 1 | write a README `mojo` example; tests to reach 99% line and branch; claim the name |
| 2 | `plan_expr` | depends on an unpublished library | 54.4% | 1 | tests to reach 99% line and branch |
| 2 | `secret_registry` | depends on an unpublished library | 98.5% | 1 | tests to reach 99% line and branch |
| 3 | `column_kernels` | depends on an unpublished library | 67.0% | 2 | tests to reach 99% line and branch |
| 3 | `decimal_literal` | no README example | not measured | 1 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 3 | `json_index` | no README example | 100.0% | 2 | write a README `mojo` example; claim the name |
| 3 | `parquet_codec` | native dependency pending | 96.0% | 2 | package the vendored Brotli decoder as a static archive with a `native_library`, as snappy is; tests to reach 99% line and branch; claim the name |
| 3 | `plan_stats` | depends on an unpublished library | 57.6% | 2 | tests to reach 99% line and branch |
| 3 | `udf` | no README example | 17.5% | 2 | write a README `mojo` example; tests to reach 99% line and branch; claim the name |
| 4 | `agg` | no README example | 92.4% | 2 | write a README `mojo` example; tests to reach 99% line and branch; claim the name |
| 4 | `kernels` | depends on an unpublished library | 52.7% | 4 | tests to reach 99% line and branch; claim the name |
| 4 | `parquet_writer` | depends on an unpublished library | not measured | 3 | measure coverage; reach 99% if short; claim the name |
| 4 | `scan_source` | native dependency pending | 63.2% | 4 | package its own C (`native/komira_scan_source_inmem_id.c`) as a static archive; tests to reach 99% line and branch; claim the name |
| 5 | `expr` | no README example | 100.0% | 4 | write a README `mojo` example; claim the name |
| 5 | `plan_ir` | depends on an unpublished library | 88.5% | 4 | tests to reach 99% line and branch; claim the name |
| 5 | `row_format` | depends on an unpublished library | 96.3% | 3 | tests to reach 99% line and branch; claim the name |
| 6 | `agg_api` | no README example | 28.7% | 4 | write a README `mojo` example; tests to reach 99% line and branch; claim the name |
| 6 | `batch_eval` | no README example | not measured | 6 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 6 | `join_assembly` | depends on an unpublished library | 64.7% | 4 | tests to reach 99% line and branch; claim the name |
| 6 | `physical_plan` | depends on an unpublished library | 97.2% | 5 | tests to reach 99% line and branch; claim the name |
| 6 | `plan_wire` | depends on an unpublished library | 99.7% | 5 | claim the name |
| 7 | `async_rt` | native dependency pending | 86.2% | 3 | package its own C (`reactor/_posix_shim.c` and the `_sched_labels.inc` it includes) as a static archive; tests to reach 99% line and branch; claim the name |
| 7 | `host_profile` | depends on an unpublished library | not measured | 2 | measure coverage; reach 99% if short; claim the name |
| 7 | `morsel` | depends on an unpublished library | 96.2% | 9 | tests to reach 99% line and branch; claim the name |
| 7 | `op_agg_state` | depends on an unpublished library | 99.9% | 7 | claim the name |
| 8 | `fs` | native dependency pending | 98.8% | 3 | package its own C (`_fs_shim.c`) as a static archive; tests to reach 99% line and branch; claim the name |
| 8 | `jsonl` | depends on an unpublished library | 99.6% | 6 | claim the name |
| 8 | `lowering` | no README example | not measured | 7 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 8 | `op_agg_hash` | no README example | not measured | 7 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 8 | `op_sources` | no README example | not measured | 7 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 8 | `operator_api` | no README example | not measured | 11 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 9 | `avro` | depends on an unpublished library | 99.3% | 4 | claim the name |
| 9 | `csv` | depends on an unpublished library | 83.2% | 6 | tests to reach 99% line and branch; claim the name |
| 9 | `objectstore` | native dependency pending | 83.6% | 2 | package its own C (`_objectstore_shim.c`) as a static archive; tests to reach 99% line and branch; claim the name |
| 9 | `parquet` | depends on an unpublished library | 99.9% | 7 | claim the name |
| 9 | `scan_planning` | depends on an unpublished library | 75.2% | 3 | tests to reach 99% line and branch; claim the name |
| 10 | `iceberg_scan` | depends on an unpublished library | not measured | 16 | measure coverage; reach 99% if short; claim the name |
| 10 | `optimizer` | no README example | 100.0% | 11 | write a README `mojo` example; claim the name |
| 10 | `sdk` | depends on an unpublished library | 99.0% | 15 | claim the name |
| 10 | `shuffle` | depends on an unpublished library | 85.8% | 1 | tests to reach 99% line and branch; claim the name |
| 10 | `sql` | depends on an unpublished library | 99.9% | 18 | claim the name |
| 11 | `engine_runtime` | no README example | not measured | 12 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 11 | `parquet_footers` | depends on an unpublished library | not measured | 23 | measure coverage; reach 99% if short; claim the name |
| 12 | `op_join_build` | depends on an unpublished library | not measured | 6 | measure coverage; reach 99% if short; claim the name |
| 12 | `op_sort` | depends on an unpublished library | not measured | 10 | measure coverage; reach 99% if short; claim the name |
| 12 | `parquet_scan` | depends on an unpublished library | not measured | 15 | measure coverage; reach 99% if short; claim the name |
| 13 | `op_fused_kernels` | depends on an unpublished library | not measured | 9 | measure coverage; reach 99% if short; claim the name |
| 13 | `op_spill_rows` | depends on an unpublished library | not measured | 19 | measure coverage; reach 99% if short; claim the name |
| 13 | `op_window` | no README example | not measured | 12 | write a README `mojo` example; measure coverage; reach 99% if short; claim the name |
| 14 | `op_join_probe` | depends on an unpublished library | not measured | 16 | measure coverage; reach 99% if short; claim the name |
| 15 | `pipeline_exec` | depends on an unpublished library | not measured | 37 | measure coverage; reach 99% if short; claim the name |
| 16 | `sdk_exec` | depends on an unpublished library | not measured | 56 | measure coverage; reach 99% if short; claim the name |
| 17 | `komira_physical` | new | new | 57 | the package of §5 with its README example; claim the name |

#### What each kind of row takes

- **One pull request each, nothing before it except its wave.** These need only their place in the
  order and a claimed name: `secret_store`, `plan_wire`, `op_agg_state`, `jsonl`, `avro`, `parquet`,
  `sdk`, `sql`. The rest of a "depends" row's work is the move itself. That move is what the
  `mopm_migrate` tool does: the layout `src/<name>/src/<name>/`, then `mopm.toml`,
  `mopm-toolchain.toml`, `mopm.lock`, `buildrules.mojo.bzl` and its lock, `coverage_floor.txt`, the
  `PACKAGES` and `mopm_native_ids.bzl` rows, the UNPUBLISHED.md row deleted with its count, and the
  dependents' rows rewritten
  ([tools/build/mopm_migrate/README.md](../../tools/build/mopm_migrate/README.md),
  [release/UNPUBLISHED.md](../../release/UNPUBLISHED.md)).
- **A README example to write (16).** The release refuses a package whose README holds no `mojo`
  example. Most of these are engine internals (`lowering`, `op_window`, `engine_runtime`, ...), so
  the example shows the library's own public call on a small input, as the published packages'
  READMEs do. It can be written in the same pull request as the move.
- **Coverage first (25 below 99% by the old census, 20 not measured, 11 at or above 99%).** The
  repository holds a touched package to 99%, and a move touches every file. *(inferred)* This is the
  largest part of the work: `arrow` (67.8% of 7,042 lines), `column_kernels` (67.0% of 7,061) and
  `udf` (17.5% of 674) are the biggest gaps. The real numbers come from each pull request's check.
- **Native code to package (5).** `mopm_migrate` refuses a library that owns C or links one, so
  each of the five is moved by hand, after the published precedents. Each one's C must also build
  for macOS, since the pull request check builds every package's library for darwin-arm64
  (AGENTS.md, "The macOS part of the pull request check").

  | library | wave | native code | route (precedent) | libraries of the 56 that wait for it |
  |---|---|---|---|---|
  | `parquet_codec` | 3 | none of its own; it links the vendored Brotli decoder (`//third_party/brotli:brotlidec`, symbols renamed `komira_brotli_*`) | the vendored library as a static archive with buildrules' `native_library`, as `compression` did for snappy (komira-ai/komira#2034). A static archive keeps the README's "neither library is needed at run time" | 8 |
  | `scan_source` | 4 | `native/komira_scan_source_inmem_id.c`, 16 lines, one counter | own C as a `[native.<id>] kind = "static"` archive (`libc`, `log`, `metrics`, `async_api`) | 37 |
  | `async_rt` | 7 | `reactor/_posix_shim.c`, 3,280 lines, which includes `reactor/_sched_labels.inc`; it already branches on `__APPLE__` and `__linux__` | the same, with the `.inc` file shipped beside the C *(inferred: no published static native has a header to carry yet)* | 24 |
  | `fs` | 8 | `_fs_shim.c`, 676 lines | the same | 20 |
  | `objectstore` | 9 | `_objectstore_shim.c`, 374 lines; it calls `fs`'s shim symbols | the same, with `fs` as a dependency | 10 |

  The last column counts the libraries whose BUCK closure holds the native library, and `sdk_exec`
  and `komira_physical` wait for all five. Each is one pull request *(inferred)*. `async_rt` is the
  largest C, and `scan_source` holds back the most libraries.
- **Names to claim (50 of the 58).** Already claimed: `arrow`, `arrow_ipc`, `column_format`,
  `column_kernels`, `plan_expr`, `plan_stats`, `secret_registry`, `secret_store`. The other 50,
  `komira_physical` among them, are claimed by the owner on the registry, each before its wave's
  pull request. Only the owner can do it, and it happens outside this repository (owner decision 2).

*(inferred)* The lower bound is 15 publishing pull requests (one per wave of the 56), then
`sdk_exec` and `komira_physical`. Five of them carry a native move. The coverage and README work
comes before or within them. Libraries of one wave that are ready can share a pull request, and a
library that needs tests first goes in a later one of the same wave.

## 6. A typed SDK, possibly later

A typed program has a schema that is a compile-time value: a column is named by type parameters, so
a missing column is a compile error, and the compiler specialises each operator for the program's
key and aggregate types ([lowering_and_pipeline.md](lowering_and_pipeline.md), §4.1). Its operator
tables **EXISTS** (`op_agg_stage`'s `HashAggTable[KB, *Aggs]`, `op_sort`'s `Stage_Sort`,
`op_window`'s top-n stages, `expr`'s `ExprX` traits, `plan_expr.typed_schema` and
`sdk.auto_schema`'s `derive_schema[T]()`), but its front end does not. The port left it out on
purpose ("Typed execution path not kept", [port_audit/sdk_group.md](port_audit/sdk_group.md)), and
no test runs a typed program end to end. Like the physical-plan surface it would link the engine,
and it would publish its own libraries beyond it (`eval`, `op_agg_stage` and `op_join_stage` among
them). Whether it exists at the end is owner decision 1, and this design gives it no slices.

## 7. The Mojo rules, and what a user's build needs

How the two packages obey the rules:
- **No pointer type in a public API.**
  - `komira`'s public names hold values: an `Int`, a `String`, a `Table`, strings (§3).
  - `komira_physical` exposes its own values (`Engine`, `PhysicalPlan`, `PipelineId`, its
    expressions and aggregates) and `arrow`'s `Schema` and `RecordBatch`.
  - The IR it emits is pointer-free in its public fields too (`physical_plan.mojo`'s header says it
    is inert data with no `UnsafePointer`). `Expr` keeps its `OwnedPointer` children in private
    fields.
- **Pointers, wildcard origins and foreign calls.** `komira`'s foreign pointers live in
  `komira._lib` alone, with `# SAFETY:` and `# FFI-BOUNDARY:` comments (§3). `komira_physical` has
  no FFI of its own: native code stays in the engine libraries that own it. `//:pointer_lint` runs
  over both, like every library under `src/`.
- **Packaging is `.mojoc`, and `deps` list the whole closure.**
  - Both are `mojo_package`s from their first commit, so each library is a `.mojoc` and each
    package a `.conda` with a `mopm.toml`.
  - Their BUCK `deps` are their whole closures: 19 libraries for `komira`, with `komira_error`
    (§4); `komira_error`, `sdk_exec` and its 86 for `komira_physical` (§5).
  - Each `mopm.toml` `[dependencies]` names only what the package imports. mopm resolves the rest
    from each package's own dependencies (`>=0.1,<0.2`, [docs/ci.md](../ci.md)).
- **Files, tests and examples.** Every file stays under 1,000 lines, every test file is in
  `test_srcs`, and every public name appears in a README example.

A user's build needs:

| | what | where it is fixed |
|---|---|---|
| Mojo | `1.1.0`, the one Mojo every package and the shared library are built for | `MOJO` in [packages.bzl](../../release/readme_e2e/packages.bzl), `mojo = ["1.1.0"]` in each `mopm.toml`, `tools/build/platforms/table.bzl` |
| mopm | a mopm with pixi on `PATH`. `komira` needs the first mopm with shared natives (§2); the repository builds with mopm 0.0.138 today | `MOPM` in packages.bzl, `mopm-toolchain.toml` |
| the project | `mopm init`, `[toolchain] mojo = "1.1.0"` (init writes mopm's own default, and `mopm add` resolves the newest build for the project's Mojo), `mopm add komira-ai/komira`, `mopm sync` | the `prod-add` job ([docs/ci.md](../ci.md)) |
| platform | Linux on x86_64 or macOS on arm64. Neither Mojo package is built for linux-arm64 (§2 says why for each) | [docs/releases.md](../releases.md) |
| host | what the Python wheel needs on Linux: glibc 2.35 or newer and an x86-64-v3 CPU, since the same shared library is inside it | [docs/install.md](../install.md) |
| system libraries | `compression` opens libzstd, libbz2 and liblzma, and `zlib` and `lz4` open libz and liblz4, at run time. Each package declares them as `[native-dependencies]`, so `mopm sync` installs them from conda-forge | those packages' `mopm.toml`, `tools/build/package/system_libs.bzl` |

## 8. The relation to the C interface

`komira` makes the same `komira_sql_stream` call as the Python and Node packages, and the same
`komira_add_sql_binding` call as Python (Node registers with `komira_register_parquet`). So every
language takes the same route from the C interface down:

```
Python  Session.sql ──┐
Node    Session.sql ──┼── komira_sql_stream ── libkomira: parse, bind, optimize, lower, execute ──
Arrow C stream
Mojo    Session.sql ──┘
```

What differs for a Mojo caller, beside Python:

| | Python | Mojo (`komira`) |
|---|---|---|
| opening the library | `ctypes.CDLL` on the copy in the wheel's `_lib/` | `OwnedDLHandle` by name, from the environment's `lib/` (§2) |
| the Mojo runtime | the wheel carries its own three runtime libraries, and checks build ids against any already loaded | the user's own Mojo runtime, at the same pin (§2) |
| the result | the Arrow C stream handed to pyarrow, read once | the stream read into an `arrow` `Table`, released at once (§3) |
| errors | `KomiraError` and its subclasses from code and step | `KomiraError` with the same code, step, status and message (§1) |
| threads | a lock per session | the compiler holds it (`mut self`) |

The physical-plan surface has no C counterpart, and it never crosses a process or a build. So the
physical IR needs no wire form for it.

## 9. How Mojo examples are tested

The two kinds of Mojo example follow the one documentation and test framework
([documentation_tests.md](documentation_tests.md)) the other languages use.

### README examples

Every README example of `komira` and of `komira_physical` runs twice in the pull request check.

1. **The welded README gate** (**EXISTS** for every library). Each `mojo` fence of the README is
   cut into a program, compiled against the library's `.mojoc` and its closure in the build, and
   run ([tools/build/mojo/README.md](../../tools/build/mojo/README.md)). For `komira` the run needs
   the shared library on the loader's path:
   - **PROPOSED**: `komira`'s tests are given `//src/so:libkomira[dist]`'s directory the way
     buildrules gives a package's conda-forge libraries to its tests, by a library directory
     (`--lib-dir`).
   - A test run is not a user's configuration, so this is not the configuration by environment
     variable that the repository forbids *(inferred)*.
2. **The install test** (**EXISTS**: `//release/readme_e2e/verify:<name>`). It is what a stranger
   does, run offline ([tools/build/readme_e2e/README.md](../../tools/build/readme_e2e/README.md)):
   - it makes an empty project (`mopm.toml` with a name and version, `[toolchain] mojo` and an empty
     `[dependencies]`);
   - it runs `mopm add komira-ai/<name>@=<version> --overlay <staged set>`, the same `.conda` files
     the release uploads, against a loopback registry that refuses everything else;
   - it checks each locked file against the staged one byte for byte;
   - it compiles each README example with the pinned Mojo against the installed prefix only, and
     runs it with an empty working directory.

   Today the tool links static archives only. For `komira`, **PROPOSED** in slice 1:
   - the tool installs the shared native into the prefix's `lib/`, and the program finds it there;
   - a scenario of the tool's own holds this, with a negative case: a package whose shared native is
     missing fails at `run`, naming the library.

A README example writes its own input first, with SQL's `COPY (SELECT ...) TO 'trips.parquet'`,
which runs through the shared library like any query. It asserts the rows it reads back, as
documentation_tests.md judges README examples by exit status. The release then adds `komira` to the
packages the `prod-add` job installs from the prod registry ([docs/ci.md](../ci.md)). That runs in
the release workflow, not in the pull request check, which runs only the build and unit tests.

### Task-page examples

The task pages ([docs/tasks/](../tasks/README.md)) follow komira-ai/komira#2495, which owns the
runner.
- **The runner.** komira-ai/komira#2495's `mojo_task_examples` builds each `example.mojo` in the
  pull request's check, runs it from an empty directory, and compares what it prints with
  `expected_output.txt`, byte for byte. It is given the shared library as the README gate is. After
  merge, the release runs the same examples against the installed packages, with
  komira-ai/komira#2495's exact compare added to the install test's phases (its slice 5).
- **The output.** It is `format_table`'s text in both Mojo forms, since `print(result)` writes it
  for `komira`'s `Result` and for `komira_physical`'s (§5).
- **The trees, one per form, each in its package:**
  - Mojo (key `mojo`): `src/komira/docs/tasks/<rank>-<slug>/`;
  - Mojo physical plan (key `mojo_plan`): `src/komira_physical/docs/tasks/<rank>-<slug>/`.

  Each holds `example.mojo`, `expected_output.txt` and `page.md`. A form draws its tab only once its
  package is published (komira-ai/komira#2495, section 1).
- **How many of the 80 tasks the Mojo form can show.** The same range as the SQL form, because it
  runs SQL text. The counts are komira-ai/komira#2495's ("What each form can show"), from the one
  text search it writes out:
  - "Cannot be shown in SQL today, for a reason other than work not yet done: 5. Ranks 31 and 93
    read cloud storage with a credential, which SQL text cannot name. Ranks 22, 89 and 90 store rows
    in a database with Python's `sqlite3`, and komira writes to no database."
  - "Rank 60 ... has no SQL in its Python example ... That is not shown to be impossible in SQL, so
    it is counted with the tasks whose SQL is written first."

  For Mojo, ranks 31 and 93 leave the 5 once `files` names a credential (slice 4), so its floor is
  then 3. This design does not count them again.

## 10. Tests of `komira` itself

The welded tests in `src/komira/tests/`, each in `test_srcs`, cover the following.

The happy path:
- one session, one binding, one query, over a Parquet file the test writes with `COPY`;
- a glob of two files;
- a CSV file read through `read_csv` in the SQL;
- binding a name again replaces it;
- two sessions in one process share nothing;
- `Result` over zero rows, and over more than 20 rows (the printer's "more rows" line).

Refusals, each asserted by its exact message and by the `code`, `step` and `status` of its
`KomiraError`:
- a parse error, with the line and column;
- an unknown table (`bind`);
- a missing file;
- a glob that matches nothing;
- `files("")`;
- `files("http://...")` (`STORAGE_URL_REFUSED`) and `files("s3://b/k.parquet")` with no credential
  (`CREDENTIALS_NOT_FOUND`);
- a NULL context from the library (the fixed message), and a library that cannot be opened
  (`LibraryLoadError` from `error_class()`);
- a CPU without the x86-64-v3 flags (`CPU_UNSUPPORTED`), given stand-in flags by the test;
- a cell `format_table` cannot render: `sql` returns the rows, `table()` reads them, and `print`
  writes the fixed line;
- `error_class()` for one code of each class and for a step with no code;
- a relative path and a `~` path made absolute by `files`;
- `Session(threads=0)` and `Session(memory_limit=0)`;
- a SQL text holding a NUL;
- a library whose ABI major is not 1, or whose minor is below 10 (`LIBRARY_VERSION_UNSUPPORTED`),
  given a stand-in library built for the test.

That list covers each branch of `komira`'s names and of `komira._lib`:
- each argument's refusal;
- each step at which a C call can fail;
- each way the library can be refused.

Everything below the C interface is libkomira's, already tested by its gate drivers.

## 11. Slices, in order

| slice | what lands | ends with |
|---|---|---|
| 1 | the first query through the shared library, in this order: komira-ai/mopm gains `[native.<id>] kind = "shared"` and the mopm pin is bumped here; the install test learns to install and find a shared native, with its scenario and negative case; `arrow` (with `format_table` moved into it) and `arrow_ipc` published, tests to 99% first; a sub-target of `//src/so:libkomira` that leaves out the Mojo runtime; the standalone proof that the pinned compiler's typed raises work; then `komira_error`; then `komira`: `komira._lib` with its CPU check and its row in `tests/pointer_lint_ffi.tsv`, `Session`, `files`, `add_sql_binding`, `sql`, `Result`, `KomiraError`, its tests (§10) and its README example | **the install test**: `//release/readme_e2e/verify:komira` installs `komira-ai/komira` into an empty project and runs one SQL query over one local Parquet file through the shared library. Then `prod-add` does `mopm add komira-ai/komira` from the prod registry on the next release |
| 2 | Mojo task examples in `src/komira/docs/tasks/`, form `mojo`, run by komira-ai/komira#2495's `mojo_task_examples` with its byte-for-byte compare (komira-ai/komira#2495 slice 5) | every task SQL can answer shown in Mojo; the rest `not-shown` with a reason (§9) |
| 3 | the CPU-level variants: the `VARIANTS` selector in `komira._lib`, as in [isa_variants.md](isa_variants.md) | `komira` runs on an x86-64-v2 CPU |
| 4 | cancel and progress (`komira_run_*`, `komira_sql_stream_run`), and credentials with remote files (`komira_credential_*`, `files("s3://...", credential=...)`) | a cancelled query refused by name; a query over a bucket through a fake object store |
| 5 | logical plans: a design for the Mojo frame API, then that API over `plan_proto` and `komira_plan_stream` | a plan run through the shared library gives the same rows as its SQL |
| 6 | the physical-plan surface's first step: `engine_iceberg.mojo` and its test `sdk_exec/tests/test_run_sql_iceberg.mojo` move to `sdk_exec_iceberg`, and `sdk_exec`'s `deps` drop `iceberg_catalog` and gain the 4 libraries of the 86 they lack (a library's `deps` list its full closure). No behaviour changes | `sdk_exec`'s closure is the 86 of §5 |
| 7 | the 54 libraries left of the engine's closure, in the waves of §5, then `sdk_exec` | `sdk_exec` published |
| 8 | the executor's own checks: the sink capability table moves to `physical_plan` and `check_plan` refuses an unserved sink; `run_lowered_plan_with` refuses a missing result or a stray root, before any pipeline runs (§5) | a hand-made `LoweredPlan` with either fault refused by name |
| 9 | `komira_physical`: `Engine`, `PhysicalPlan`, `parquet`, `filter`, `project`, `limit`, `hash_aggregate`, collect, the expressions and aggregates, the checks at submit, `run` and its README example. The `mojo_plan` tree and its first task examples land with komira-ai/komira#2495's slice 6, which owns the tree | the install test runs its README example; the same query through `komira` and `komira_physical` gives the same rows |
| 10 | `sort`, `top_n`, `output_of` and `hash_join` in `komira_physical` | a two-pipeline join plan run as written |

The order inside slice 1 is fixed by what each part needs. The slices after it go in any order the
dependencies allow, and no slice waits on an answer about order:
- 7 needs 6;
- 9 needs 7 and 8;
- 10 needs 9;
- 2 to 5 need only 1.

Slice 1 uses the name `komira` (owner decision 2); another name would change only the package's
name.

## Decisions for the owner

Two questions, each about what exists at the end; the third, about the gate, is asked once, in
komira-ai/komira#2495. The order of the work is not among them.

1. **Does a typed SDK exist at the end?** It would check column types when the user's program is
   compiled (§6).
   - *Yes, later.* It needs a front end that the port left out and a design of its own, and it
     links the engine like the physical-plan surface.
   - *No.* The Mojo SDKs are then `komira` and `komira_physical`. The typed operator tables stay
     engine internals.
   - **Recommended:** decide after `komira` and `komira_physical` exist. Nothing in this design
     depends on the answer.
2. **Is the untyped Mojo package called `komira`** (`from komira import Session, files`)? The
   owner's words were "I think the untyped sdk is komira?", and this design uses it as the working
   name.
   - Confirming it means claiming `komira`, and the small `komira_error` beside it, on the
     production registry before slice 1 publishes. These two are the only names that need a yes
     now. `arrow` and `arrow_ipc` are claimed already.
   - For information, not a question: the physical-plan surface needs 50 more names before its waves
     are published, listed in §5's table (every row marked "claim the name"). They are claimed as
     each wave comes, or all at once.
   - **Recommended:** `komira`, the name on PyPI and npm.
3. **The gate.** What it means for a task a language cannot show is asked once, in
   komira-ai/komira#2495's question for the owner, with its table of ranks per language and its
   recommendation. The gate counts four languages, SQL, Python, TypeScript and Mojo, where Mojo is
   the untyped SDK `komira`, and the Mojo physical plan tab is outside it. For `komira` the answer
   decides whether ranks 22, 89, 90 (and 31 and 93 until slice 4) and its missing linux-arm64 build
   are listed exceptions or must be done first.

## What the design decides, and why

These are engineering choices, not the owner's. Each says what the design does and why.

- **`komira` rests on the shared library, and adds no C call.** This is the owner's model. Each
  gap the Mojo session meets is listed as a gap in the C interface (§1).
- **The shared library reaches a Mojo user through a new mopm kind, a shared native, not through a
  download.** A download at install or run time is what the TypeScript design refused for the same
  reason: binaries somewhere no test of the package ran
  ([typescript_package.md](typescript_package.md), section 3).
- **The package carries no Mojo runtime.** The user's Mojo at the same pin already holds one, and a
  second copy would not be mapped anyway (§2).
- **Errors match Python's classes**, from a small `komira_error` package both Mojo packages share,
  with plain `Error` as the fallback if typed raises fail on the pinned compiler (§1).
- **`format_table` moves into `arrow`.** Then `komira` can print without depending on `sdk`.
- **What is copied from Python as it ships:**
  - `add_sql_binding(name, files(...))`;
  - `Session(threads, memory_limit)`;
  - `files` making a local path absolute;
  - the result printed as a table.

  Each is the behaviour of `python/komira/_session.py` and `_sources.py` on main, over the same C
  calls.
- **The physical-plan surface is its own package, `komira_physical`, with its own `Engine`.** It is
  the only surface that links the engine, and a user of `komira` must not compile the engine.
- **The physical-plan builder fills in the low-level plan fields.** The plan structures change
  about weekly: 12, 25 and 23 commits since 2026-10-01 in `physical_plan`, `lowering` and
  `pipeline_exec` (§5). So a user's program written against the builder's words does not break each
  time they change.
- **Iceberg catalogs leave the engine's first package (slice 6).** That takes `http_core` and its
  s2n-tls build off the road to the first physical plan. The untyped SDK reads Iceberg tables
  through the shared library meanwhile.
- **Brotli ships as a static archive in `parquet_codec`, as snappy does.** It keeps "neither library
  is needed at run time".
- **The plan builder reads lowering_and_pipeline.md's exit condition as allowing a second producer
  in the same build** (§5).

## What this design does not change

- No C call, no wire format, and no Python or TypeScript behaviour. The shared library gains only a
  build sub-target without the Mojo runtime.
- No published package changes. Publishing goes on as it does today: every push to main publishes
  each member of `PACKAGES` ([docs/releases.md](../releases.md)).
- Two documents disagree with the code they describe, and this design leaves them as they are:
  - [native_packaging.md](native_packaging.md) plans one shared library per native owner, while the
    published natives are static archives;
  - [mojo_runtime_pypi_vs_conda.md](mojo_runtime_pypi_vs_conda.md) says toolchain 1.0.0 where the
    pin is 1.1.0.

  Each is for its own document's owner to settle.
