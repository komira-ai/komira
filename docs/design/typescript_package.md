# The TypeScript package: surface, packaging and release

Status: design, not built. **EXISTS** names code on `main`. **PROPOSED** is new. Statements the
author deduced rather than read are marked *(inferred)*. The choices only the owner can make are
collected under [Decisions for the owner](#decisions-for-the-owner). D2, where the Mojo runtime
comes from, is ruled. D1, D3 and D4 are open, so until the owner answers them, the npm names below
are the recommended ones, not settled ones.

## What problem does this solve?

People should be able to `npm install` komira and run SQL over their local files from Node, with
Arrow data back. komira has a Node addon over `libkomira` ([node/README.md](../../node/README.md)),
and a private package over it that runs SQL (`Session.sql`) and answers Arrow (`Result`), but both
are test-only and nothing of them is published.

The Python package ([python_package.md](python_package.md)) is the sibling. Both bind the same
library through the same C calls ([libkomira_run_abi.md](libkomira_run_abi.md)). This document
covers the parts that are Node's own:
- the first release's surface and how an Arrow C stream reaches JavaScript;
- the npm packages, the self-contained native directory they carry, and how they load it;
- how they plug into the release machine;
- the tests that run from the installed package;
- where the Excel SDK and the later surfaces sit.

Fixed before this design, and not reopened here:
- **One C ABI.** The run calls are `komira_sql_stream` and `komira_plan_stream`, with an Arrow C
  stream as the result ([libkomira_run_abi.md](libkomira_run_abi.md)). This design adds no
  libkomira call.
- **The package is self-contained.** The owner ruled that every language package carries one
  self-contained native directory: `libkomira`, its native owners and the three Mojo runtime
  libraries (`libKGENCompilerRTShared`, `libAsyncRTRuntimeGlobals`, `libMSupportGlobals`), which
  loads from any location with nothing installed beyond the host's system C and C++ libraries.
  The owner also ruled that komira may redistribute those libraries. Their licence files and
  notice are the wheel's (§3).
  - The directory is one build output, the self-contained directory of the libkomira target
    (`//src/so:libkomira[dist]`). The wheel is its first user: `//python:komira_wheel` copies it whole
    to `komira/_lib/`, with `libkomira.so` at the top and the native owners and the three Mojo runtime
    libraries in `lib/`, and requires no distribution of Modular's ([python/BUCK](../../python/BUCK),
    komira-ai/komira#2139, komira-ai/komira#2151).
  - The npm platform packages copy the same directory (§3).
- **Release platforms.** linux-x86_64, linux-arm64 and macos-arm64 (rule B11).
- **One UDF mode per language.** UDFs written in TypeScript run in Node worker processes (rule B21,
  [udf_runtime_interface.md](udf_runtime_interface.md)).
- **Excel is a separate TypeScript SDK.** It turns Excel formulas into logical plans and submits
  them through `komira_plan_stream`. libkomira has no Excel call ([libkomira_run_abi.md](libkomira_run_abi.md) §4).

## 1. What exists

### The addon

- **EXISTS** [node/komira_addon.c](../../node/komira_addon.c) (1059 lines) is a Node-API addon in C, with
  its Arrow import in [node/arrow_import.c](../../node/arrow_import.c).
  - It defines `NAPI_VERSION 8` and uses `NAPI_MODULE_INIT`, so it is context-aware. Its function
    table is process-wide, and a worker thread shares it (the comment at the table). `:thread_test`
    loads it in worker threads.
  - It exports thirteen functions: `load`, `abiVersion`, `newSession`, `freeSession`,
    `registerParquet`, `parquetSchema`, `planRender`, `sql`, `sessionStats`, and the Arrow import's
    `importArrowStream`, `arrowSchema`, `arrowNextBatch` and `arrowClose` (below).
- **How it binds libkomira.** `load(path)` opens the library with `dlopen(RTLD_NOW | RTLD_LOCAL)`
  and requires `komira_abi_version()` major 1. It then resolves seven symbols by name, and a
  missing one is named in a `KOMIRA_MISSING_SYMBOL` error. It also resolves
  `komira_sql_stream` (1.3), `komira_ctx_new_with_options` (1.4), `komira_last_error_code` and `komira_last_error_step`
  (1.7): each is required when the library's minor includes it and may be missing from an older
  library, where `sql` and options are refused naming both versions and a refusal has no code or step.
  - The library is never `dlclose`d, because the Mojo runtime cannot be unloaded.
  - There is one library per process: loading the same path again does nothing, and loading
    another path is refused.
  - [node/README.md](../../node/README.md) says why it is `dlopen` rather than a NEEDED
    dependency. Buck2 has no edge from a C target to a `mojo_shared_lib`. With `dlopen`, a wrong
    library also becomes a JavaScript `Error` instead of a loader failure before any JavaScript
    runs.
- **Sessions.** A session is an N-API external over a heap box holding the `komira_handle`. Its
  type tag makes the addon refuse another addon's externals. The finalizer frees the context if
  `freeSession` did not, so a context is freed once.
  - Each session owns one native thread, started by its first call, which runs the session's
    calls in call order. `registerParquet`, `parquetSchema`, `planRender` and `freeSession`
    return Promises, settled through a thread-safe function that is referenced only while a call
    is pending.
  - `freeSession` refuses new calls at once and frees the context after the calls made before it.
    A pending call holds its session, so the finalizer never runs under a call, and it joins the
    thread before it frees the context.
- **Errors.** A non-zero status rejects with an `Error` that carries `status`, `code` (the
  `KOMIRA_ERR_*` name), `lastError` (read with the two-call protocol), `lastErrorCode` and
  `lastErrorStep` (the last error's named code and `KOMIRA_STEP_*` number). `node/src/native.ts`
  turns it into a `KomiraError` whose `code` and `step` are the engine's, with the class the error
  table gives the code. Misuse of the addon
  throws an error with a `code` and no `status`: `KOMIRA_ARG`, `KOMIRA_NOT_LOADED`,
  `KOMIRA_SESSION_FREED`, `KOMIRA_LOAD_FAILED`, `KOMIRA_ABI_MISMATCH`, `KOMIRA_MISSING_SYMBOL`,
  `KOMIRA_LOADED`, and from `newSession` `KOMIRA_ABI_TOO_OLD` and `KOMIRA_CTX_REFUSED`, and from `sql`
  `KOMIRA_ABI_TOO_OLD`.
- **`sql`.** `sql(session, text)` runs `komira_sql_stream` on the session thread into a zeroed
  stream and drains it there (step 1 of [Arrow: from the C stream to
  JavaScript](#arrow-from-the-c-stream-to-javascript)). Its Promise resolves with the drained result
  the Arrow import's calls read, which needs no context, so it reads after `freeSession`.
- **Calls it does not bind.** `komira_csv_binding` and `komira_json_binding` have no function in
  the addon, nor do `komira_sql_stream_run`'s run handle and `komira_plan_stream`.
- **EXISTS** The Arrow import of [Arrow: from the C stream to
  JavaScript](#arrow-from-the-c-stream-to-javascript), steps 1 to 3, over the stream
  `komira_sql_stream` fills (drained on the session thread) and over a stream handed to
  `importArrowStream` as a capsule (an N-API external tagged as an Arrow C stream,
  [node/arrow_c.h](../../node/arrow_c.h)), which it drains on the JavaScript thread. The private
  module is [node/src/arrow_import.ts](../../node/src/arrow_import.ts) (`tableOf`, `openBatches`,
  and `readArrowStream` for the tests), with
  `KomiraError` and `UnsupportedOperation` in [node/src/errors.ts](../../node/src/errors.ts), the package's one errors module.
  [node/package.json](../../node/package.json) is private and declares the `apache-arrow` peer
  dependency at `^21.2.0` (part 3 completes it).

### Tests and CI

- **EXISTS** [node/BUCK](../../node/BUCK) has five `node_binding_test` targets.
  - `:load_test` runs [load.test.mjs](../../node/load.test.mjs) and
    [capacity.test.mjs](../../node/capacity.test.mjs). They cover the load refusals, using
    stand-ins built from [tests/fake_libkomira.c](../../node/tests/fake_libkomira.c): ABI 2.0,
    ABI 0.999, a missing `komira_plan_render`, ABI 1.3 without `komira_sql_stream`, ABI 1.7
    without `komira_last_error_code`, and a library that records the capacity it was given.
  - `:session_test` runs [session.test.mjs](../../node/session.test.mjs). It covers errors with
    their last error, the frozen schema bytes of `two_columns.parquet`, plan text, wrong-kind
    arguments, a foreign external, double free, and finalizers counted with `gc()` with no clock.
  - `:thread_test` runs [thread.test.mjs](../../node/thread.test.mjs) against a stand-in
    ([tests/fake_latch.c](../../node/tests/fake_latch.c)) that journals each call's context and
    thread and holds a call at a gate. It covers call order on one thread per session, two
    sessions at once, `freeSession` while a call is held, the finalizer of a session with a
    pending call, and sessions in worker threads.
  - `:arrow_test` runs [arrow_stream.test.mts](../../node/arrow_stream.test.mts) and
    [arrow_import.test.mts](../../node/arrow_import.test.mts) over streams of a stand-in producer
    ([tests/arrow_stand_in.c](../../node/tests/arrow_stand_in.c)) that counts each release: the
    round trip of every type of the exporter's set, with nulls, offsets and a dictionary, an empty
    stream, failing callbacks, a misaligned buffer, malformed arrays and unmapped formats. It
    measures `node/src/arrow_import.ts`: at least 99% of its lines and branches covered.
  - `:package_test` runs the package's tests, `sql` and `Result` among them, over the real
    library (a Parquet file of three rows the engine writes, a syntax error and an unknown table
    with their codes and steps) and over a stand-in of ABI 1.9
    ([tests/fake_sql.c](../../node/tests/fake_sql.c)) whose `komira_sql_stream` answers fixed
    queries.
- **EXISTS** The tests are in the pull request's check set (`ci/targets/shard_7.bzl`).
  - `node_binding_test` runs `node --test` as a build action, under `env -i`, with no network.
  - It passes only if TAP reports tests, all passed, and none skipped
    ([tools/build/node/README.md](../../tools/build/node/README.md)).
- **EXISTS** The TypeScript sources of `node/src/` are measured by their own test targets:
  `//node:package_test` names them, the Arrow import aside, as `covered_srcs`, and `:arrow_test`
  names the Arrow import; `node_binding_test` fails unless every one is loaded and their lines and
  branches are each at least 99% covered (rule T1). The addon's C is
  not measured. `.github/workflows/coverage.yml` and the covcheck README never name `node/`
  *(inferred from a search of both)*; covcheck does read lcov tracefiles
  ([tools/build/coverage/README.md](../../tools/build/coverage/README.md)).

### Toolchain

- **EXISTS** One Node pin: 24.21.0, linux-x64 only (`third_party/node/pins.bzl`).
  - The addon is compiled by `c_shared_lib` with
    `zig cc -target x86_64-linux-gnu.2.34 -shared -Wl,-z,undefs`, so the `napi_*` symbols resolve
    against `node` at load.
  - `node_dist` keeps only `bin/node`, `include/node` and `LICENSE` from the archive. npm, npx and
    corepack are left out, so the repository has no npm CLI.
  - The "Limits" section of [tools/build/node/README.md](../../tools/build/node/README.md) lists
    what macOS needs: a `darwin-arm64` pin, the macOS execution platform, and
    `-undefined dynamic_lookup`. None of it exists yet. linux-arm64 has neither a
    Node pin nor a registered build platform (`tools/build/platforms/table.bzl`,
    `komira-limit:linux-arm64-unregistered`).
- **EXISTS** The Node rules also hold `npm_modules` (an offline `npm ci --ignore-scripts` from a
  pinned lockfile), `tsc_check`, `tsc_build` and `jest_test` (`tools/build/node/modules.bzl`).
  - `npm_modules` is a Zig program and runs no npm. It reads a `package-lock.json` and the pins
    that `kpin lock` writes.
  - These rules are used by `src/tests/helpers` and their negative fixtures under
    `tools/build/tests/negative`, and by `//node:typecheck` and `//node:dist` over the package's
    own pinned compiler (`node/devtools`).
- **EXISTS** Pinned npm tarballs include `apache-arrow` 21.2.0. It is used by a test of an Arrow
  IPC round trip in `komira_test_node`.
- **EXISTS** "Never shipped" ([third_party/node/README.md](../../third_party/node/README.md)): the
  `node` runtime and every npm package are visible only to `src/tests/*` and `//node`, and a
  conda package cannot hold JavaScript.

### Release state

- **Nothing is released.** **EXISTS** The package of parts 3 and 4 (below, "Where the work lands"):
  `node/package.json` (`"private": true`, named by D1's option A as a placeholder), the TypeScript
  sources in `node/src/`, `Session.sql` and `Result` among them, and the `.js` and `.d.ts` files
  `//node:dist` compiles from them. The private Arrow import of part 2
  (`node/src/arrow_import.ts`) is one of those sources, read by `Result`. No platform package is
  built and nothing is published. No workflow mentions npm
  publishing. The only use of npm in a workflow is the pin check in `kpin-update.yml`.

### The library under it

- **EXISTS** `libkomira` is at ABI 1.9, with twenty-five exports
  ([src/so/abi/komira.tsv](../../src/so/abi/komira.tsv)).
  - `komira_sql_stream` (1.3) runs SQL text and answers an Arrow C stream.
    `komira_sql_stream_run` (1.6) runs it under a run handle that another thread cancels
    (`komira_run_cancel`, status -6) and reads the progress of (`komira_run_progress`).
  - `komira_plan_stream` (1.8) runs a serialized logical plan and answers the same way.
  - `komira_ctx_new_with_options` (1.4) creates a context with the engine's worker count and
    memory budget as arguments (0 is the host's own value).
  - `komira_register_csv` and `komira_register_json` (1.5) bind a CSV or newline-delimited JSON
    file to the session as a table that SQL reads by name.
  - `komira_last_error_code` and `komira_last_error_step` (1.7) answer the last error's named code and
    the step that refused it. The addon binds them, and `KomiraError` carries them.
  - `komira_register_arrow_stream` (1.9) drains a host's Arrow C stream into a table held in
    memory and registers it by name, replacing a table of that name; it releases the stream.
  - On linux-x86_64 it is 3.8 MB, with run path `$ORIGIN/lib:$ORIGIN`, and its eleven native owners
    sit in `lib/` beside it ([src/so/README.md](../../src/so/README.md)).
  - It needs the three Mojo runtime libraries at load time: `libKGENCompilerRTShared`,
    `libAsyncRTRuntimeGlobals` and `libMSupportGlobals`
    ([mojo_runtime_pypi_vs_conda.md](mojo_runtime_pypi_vs_conda.md)). The self-contained directory
    (`//src/so:libkomira[dist]`) puts them in its `lib/`, which the library's run path finds, and the
    wheel ships that directory.
- **No TypeScript or Node SDK existed in the earlier code base.** Its one engine binding was the
  Python ctypes SDK ([python_package.md](python_package.md) decision 4).

## 2. The first release's surface

The first release matches the Python package's SQL-first release ([python_package.md](python_package.md)
decision 3). The names are the same words in camelCase
([optimized_plan_sources.md](optimized_plan_sources.md) §15.9 fixes that for every SDK), and the
behaviour is the same except where Node's idiom differs, as noted in each item.

```ts
import * as km from "@komira-ai/komira";          // the name is decision D1

await using s = new km.Session({ threads: 8 });
await s.registerParquet("trips", "data/trips.parquet");
const result = await s.sql("SELECT vendor, count(*) AS n FROM trips GROUP BY vendor");
const table = await result.toArrow();               // an apache-arrow Table
console.log(table.toArray());
```

### Public names

The package exports these names and nothing else. The test `exports_test` holds the list.

| name | what it is |
|---|---|
| `new Session(options?)` | one engine context (`komira_ctx_new`) and its tables. The options are `{ threads?: number, memoryLimit?: number }`, passed to `komira_ctx_new_with_options` (ABI 1.4), which takes them as arguments; with neither, the session is `komira_ctx_new`'s. A later option, `caFile?: string`, adds trusted roots for `https://` reads, as Python's `ca_file=` ([credentials_and_writes.md](credentials_and_writes.md) decision 9). `memoryLimit` is in bytes, and an omitted option takes the engine's default. Options are arguments, never environment variables (rule S2) |
| `session.registerParquet(name, path): Promise<void>` | `komira_register_parquet`. `path` is a `string` or a `file:` `URL`. A relative path resolves against the working directory when the call is made, as Node's `fs` does, and `~` is not expanded. Registering a name again replaces it |
| `session.registerCsv(name, path, options?)`, `session.registerNdjson(name, path)` | CSV and newline-delimited JSON. They arrive with libkomira calls that register those formats by name. No design has those calls yet: [libkomira_run_abi.md](libkomira_run_abi.md) §7 says only "the later source calls", and today's `komira_csv_binding` and `komira_json_binding` return bindings, not registrations. The CSV options are the ones `komira_csv_binding` takes: `{ delimiter?: string, header?: boolean, allVarchar?: boolean }` |
| `session.sql(query): Promise<Result>` | runs one SQL statement through `komira_sql_stream`. **The official door of the first release**. A later second argument, `sql(query, bindings?)`, binds sources for one statement ([credentials_and_writes.md](credentials_and_writes.md) decision 12) |
| `session.close()`, `session.closed`, `session[Symbol.dispose]()`, `session[Symbol.asyncDispose]()` | closing is idempotent, and `using` / `await using` close the session |
| `Result` | the answer of one `sql` call: `toArrow(): Promise<Table>`, and `[Symbol.asyncIterator]()`, which yields `apache-arrow` `RecordBatch`es |
| `sql(query)`, `registerParquet(name, path)` | the same calls on a default session (below) |
| `abiVersion(): number` | `komira_abi_version()`, `major * 1000 + minor` |
| `version: string` | the package's version |
| `KomiraError`, `LibraryLoadError`, `UnsupportedCpuError`, `UnsupportedOperation` | the errors (below) |

The package has no `bin` and no command: `npm install` is the only step (decision D2).

### Behaviour

Behaviour the pull requests implement, fixed here so they agree:

- **Every call into the library is asynchronous.** `registerParquet` and `sql` return promises,
  and the event loop never waits on the engine.
  - Each session owns one native thread, started by its first call. The thread runs the session's
    library calls in the order they were made, and settles each promise through a thread-safe
    function.
  - So a context is used by one thread at a time, which is the ABI's rule
    ([libkomira_run_abi.md](libkomira_run_abi.md) §7), with no lock in JavaScript.
  - A long query never occupies the libuv thread pool, which `fs` and `dns` share.
  - Sessions are independent, so two sessions run at once.
  - Python is synchronous here because its idiom is. Node's idiom is a promise.
- **`sql` fails early.** Its promise rejects on a syntax error, an unknown table or column, or a
  refusal at bind, optimize or lower. In the first release the result is materialized, so it also
  rejects on an execute error. The contract leaves room for an error later, from `toArrow()` or
  from iteration, when the stream becomes incremental. That change is additive.
- **A `Result` is read once.** The first `toArrow()` or iteration takes the batches. A second read
  rejects with `KomiraError("the result was already read")`, as in Python.
- **Closing.** `close()` is synchronous. It refuses new calls on the session, and it frees the
  context when the call already in flight finishes. It never frees the context under a running
  query.
  - A `Result` that is not yet read still reads after its session closes, because the stream does
    not depend on the context ([libkomira_run_abi.md](libkomira_run_abi.md) §5). This settles,
    for Node, the case the Python design left to its session pull request.
  - A session that is never closed is closed by its finalizer, as `freeSession` is today.
- **The default session.** `km.sql` and `km.registerParquet` use one `Session` per JavaScript
  environment, made with default options at the first call and never closed. A worker thread has
  its own default session.
  - It is per environment rather than per process, as Python's is, because an N-API external
    cannot cross from one environment to another.
- **The process.** An unfinished call keeps the process alive, as a pending `fs` call does. An idle
  session does not, because the thread-safe function is unreferenced while nothing is in flight.
- **Aborts.** An abort inside libkomira ends the process
  ([libkomira_run_abi.md](libkomira_run_abi.md) §8). The README says so. The addon installs no
  signal handler.

### Arrow: from the C stream to JavaScript

`apache-arrow` has no importer for the Arrow C Data Interface. It reads IPC bytes and builds data
from typed arrays. The addon therefore reads the C stream itself
([libkomira_run_abi.md](libkomira_run_abi.md) §9 leaves this choice to the Node binding), and hands
JavaScript the buffers without copying them.

1. **On the session thread**, the addon calls `komira_sql_stream` into a zeroed
   `struct ArrowArrayStream`, then calls `get_schema` and `get_next` until the end of the stream.
   - The stream is materialized today, so this only moves pointers.
   - A non-zero callback status rejects the promise with `get_last_error`'s text.
   - The addon then calls the stream's `release`. The `ArrowArray`s it took stay valid, because
     each has its own `release` (the Arrow spec).
2. **On the JavaScript thread**, when a batch is read, the addon describes the batch to
   JavaScript.
   - The schema becomes `{ format, name, flags, metadata, children, dictionary }`.
   - The array becomes `{ length, nullCount, offset, buffers, children, dictionary }`, where each
     buffer is an external `ArrayBuffer` over the array's memory.
   - The `ArrowArray` is released when the last of its buffers is collected (a count per array).
   - A buffer that is not 8-byte aligned is copied into an aligned one, because a typed array
     needs alignment. The Arrow spec recommends aligned buffers, and the exporter's are expected to
     be aligned *(inferred; the export change states it)*, so the copy is for a producer that does
     not align. A test holds it.
3. **A private TypeScript module** maps each format string to an `apache-arrow` `DataType` and
   builds the batch with `makeData`. The batches are wrapped into `RecordBatch` and `Table`.
   - The set of types is the exporter's supported set, which the export change lists in
     `src/arrow_ipc/README.md`.
   - libkomira refuses a result type outside that set before the stream is written
     ([libkomira_run_abi.md](libkomira_run_abi.md) §5).
   - A format the module does not map raises `UnsupportedOperation`, naming the column and the
     format string, and is never read as some other type.

Rejected: writing Arrow IPC bytes in the addon and reading them with `tableFromIPC`. It copies
every buffer, and it would put an IPC writer in C beside the engine's own.

**`apache-arrow` is a peer dependency, and a required one.**
- The package declares `"peerDependencies": { "apache-arrow": "^21.2.0" }`, the range its tests
  run.
- npm 7 and later installs a peer dependency that is missing, so `npm install` alone works.
- A peer dependency rather than a direct one, so `result.toArrow()` returns a `Table` of the
  user's own copy of `apache-arrow`. `instanceof` checks and `tableToIPC` then work in user code.
  A second, private copy would break both.
- It is not optional: Arrow is the only form a result has in the first release.

### Errors a user can act on

- `KomiraError extends Error` is the base of every error the package raises on purpose. It has the
  fields of the Python error ([python_package.md](python_package.md) decision 9):
  - `status`: the ABI's status number, or `null`;
  - `code`: the engine's named code, or `null`;
  - `step`: `parse`, `bind`, `optimize`, `lower`, `execute`, or `null`;
  - `message`: the engine's text, unchanged.
- Which status and code map to which subclass is one table, shared with the Python error-mapping
  change, with a test per row in each language. An unknown negative status is a `KomiraError`,
  never a success ([libkomira_run_abi.md](libkomira_run_abi.md) §6).
- The subclasses:
  - `UnsupportedOperation`: komira refused a construct by name (rule B21).
  - `LibraryLoadError`: the platform package is missing (for example after
    `npm install --omit=optional`, or on a platform with no package), the library cannot be opened
    (with the loader's message), its ABI major is not 1, or a symbol its minor promises is
    missing. A call that a newer minor added fails when it is used, with a message naming both
    versions.
    - The Mojo runtime libraries are files of the platform package, so a missing one is a damaged
      install. It is the loader's failure to open `libkomira`, reported as this error with the
      loader's message. There is no error of its own for the runtime, and no message that points
      at something to install.
  - `UnsupportedCpuError extends LibraryLoadError`: on linux-x64 the CPU lacks a flag of
    x86-64-v3. The package reads `/proc/cpuinfo` before it loads the addon, so the process never
    dies on an illegal instruction. The flags and the message are the Python check's
    (komira-ai/komira#2121).
- Arguments are JavaScript's own. A wrong type is a `TypeError`, and a wrong value of the right
  type is a `RangeError` (`threads: 0`, an empty table name, a NUL byte in a path). Both are raised
  before the library is called.
- The addon's own error codes (`KOMIRA_ARG`, ...) stay inside the private layer. The public errors
  are the classes above.

### Cancellation

The first release has no cancel, and its README says so. libkomira has one since ABI 1.6: a run
handle passed to `komira_sql_stream_run`, cancelled by `komira_run_cancel` from any thread, and a
cancelled run returns `KOMIRA_ERR_CANCELLED` (-6) ([libkomira_run_abi.md](libkomira_run_abi.md)
§10). The addon does not bind it yet.

An `AbortSignal` that only rejected the promise would leave the engine running and holding the
session's thread, so it is not offered.
- When the addon binds the run handle, `sql(query, { signal })` is added: an additive option.
- An aborted query then rejects with a `KomiraError` whose `status` is the cancelled code.
- After it, the session stays usable.

### Explicitly later

- **A DataFrame-style builder.** The matrix already names its surface: `ts_polars`, polars-shaped
  (`tests/surface_capability_matrix.bzl`). It builds a `WirePlanEnvelope` and submits it through
  `komira_plan_stream`, as the Python surfaces do. It needs a TypeScript encoder of
  `komira.plan.v1`, shared with the Excel SDK.
- **The Excel SDK** (§6).
- **UDFs written in TypeScript.** They run in Node worker processes, the `komira/node` runtime of
  [udf_runtime_interface.md](udf_runtime_interface.md), never in the engine's process or in an
  isolate. The plan door refuses an envelope with UDFs by name until then.
- **Remote jobs.** These submit an `OptimizedPlan` to a job manager, after its codec exists
  ([optimized_plan.md](optimized_plan.md)).
- **Also later:** object stores and credentials, bound as in every SDK
  (`s.addSqlBinding(name, source)`, and `s.sql(query, { orders_table })` for one statement,
  [credentials_and_writes.md](credentials_and_writes.md) decision 12); writes; progress; `explain()`
  through `komira_plan_render`.

## 3. Packaging

### The packages

The npm packages follow the shape esbuild and rollup use: a main package of JavaScript, and one
package per platform holding the native files, named in the main package's
`optionalDependencies`. npm installs only the platform package whose `os`, `cpu` and `libc` match
the host.

| package (decision D1) | holds | `os` / `cpu` / `libc` |
|---|---|---|
| `@komira-ai/komira` | the compiled JavaScript, `.d.ts` types, `README.md`, `LICENSE`, `NOTICE` | none |
| `@komira-ai/komira-linux-x64-gnu` | `komira_addon.node` and the self-contained native directory: `libkomira.so`, the eleven native owners and the three Mojo runtime libraries, laid out as the directory lays them out; the licence files | `linux` / `x64` / `glibc` |
| `@komira-ai/komira-linux-arm64-gnu` | the same, for aarch64 | `linux` / `arm64` / `glibc` |
| `@komira-ai/komira-darwin-arm64` | `komira_addon.node` and the directory, with `libkomira.dylib`; the licence files | `darwin` / `arm64` |

- **One step.** `npm install @komira-ai/komira` is all a user runs. It installs the main package and
  the one platform package that matches the host, and that platform package holds every native file
  a query loads. Nothing is fetched after install and nothing is fetched at run time, so an install
  from a registry mirror or an offline cache works with no network. The package needs no Python, no
  `pip` or conda, and no `mojo-compiler`.

- **Versions.** Every package has one version, `0.1.<N>`, the wheel's scheme. `N` is the same
  stamp the wheel and the conda packages take (`komira.package_stamp`,
  `tools/build/package/wheel.bzl`); the conda packages spell their version differently. The main
  package names its platform packages at that exact version.
- **Rejected: one tarball with every platform's files in it.** Every install would download three
  platforms' libraries.
- **Rejected: an install script that downloads the binaries.** pnpm and Bun do not run dependency
  install scripts by default, `--ignore-scripts` skips them, and the files would come from
  somewhere no test of the package ran.
- **Size.** A platform package is about 6 MB unpacked on linux-x64: the library is 3.5 MB, the
  owners 0.5 MB and the three runtime libraries about 2 MB *(inferred: the first two from the
  linux-x86_64 table of [src/so/README.md](../../src/so/README.md), the third from the sizes in
  [mojo_runtime_pypi_vs_conda.md](mojo_runtime_pypi_vs_conda.md); nothing has been packed)*.

### Node versions and N-API

- **Node versions.** `"engines": { "node": ">=22.12" }`. Node's release schedule
  (`github.com/nodejs/Release`, `schedule.json`, read 2026-11-20) gives these lines:
  - 22 and 24 are in maintenance;
  - 26 became the active LTS on 2026-10-28;
  - 20 is past its end of life.

  `third_party/node` still calls 24 the active line and 26 not an LTS line. Its README is updated
  when the 26 pin lands.
  - 22.12 is the first 22 that loads an ES module through `require`, so CommonJS users need no
    second build.
  - The package is ESM only, with an `exports` map and `types`.
  - The compiled JavaScript uses no syntax newer than Node 22's: `using` is spelt as `try` and
    `finally` there. The example above needs Node 24 or later for `await using`.
- **N-API.** The addon stays at `NAPI_VERSION 8`, which every Node from 16 on provides.
  - It needs nothing newer: externals with type tags (8), thread-safe functions (4), async work
    and external `ArrayBuffer`s (1).
  - N-API is ABI-stable, so one `.node` per platform serves every Node major.
- **Only what is true.** The install test runs on pins of Node 22, 24 and 26 (§5). Until it does,
  the README claims only the majors it runs. Today there is one pin, 24.21.0. Electron, Deno and
  Bun are not claimed.

### Types

- The sources are TypeScript under `node/src/`. `tsc_build` compiles them to `dist/` with
  `declaration: true`. The package ships the `.js` and `.d.ts` files, never `.ts` files, because
  Node does not strip types inside `node_modules`.
- `strict` is on, every public name is annotated, and `tsc_check` runs over the tests too.
- The batch types are `apache-arrow`'s own `Table` and `RecordBatch`, so a user's type checker
  sees one `apache-arrow`.

### How the package finds libkomira

- The main package resolves its platform package with `require.resolve` of
  `@komira-ai/komira-<platform>/package.json`, where `<platform>` is spelt from `process.platform`
  and `process.arch`. Then:
  1. on linux-x64, it runs the CPU check;
  2. it loads `komira_addon.node` from that directory;
  3. it calls the addon's `load` with the path of `libkomira` in the copied directory.
- The directory loads from any location with nothing else installed: the library's run path
  (`$ORIGIN/lib:$ORIGIN`, `@loader_path/lib` on macOS) finds its owners and the three runtime
  libraries inside it. That is the directory's own property, and its own test in the change that
  builds it holds it. The npm package adds no preload, no search for a runtime, and no second
  directory.
  - The package rule copies the directory as it is, file for file. It does not pick members out of
    it and adds none.
  - The directory is the wheel change's output. The npm rule takes no other target in its place,
    `//src/so:libkomira[runnable]` included.
- There is no environment variable, no search of the working directory, and no global install
  path. That is Python's decision 6, for the same reason: a package must load the library its own
  tests ran.
- Tests call the private `load(dir)` with the directory their target staged, as the addon tests
  do now.

### The Mojo runtime (decision D2, ruled)

The platform packages carry the Mojo runtime: the three libraries are members of the self-contained
native directory, and each platform package copies that directory (above). The comparison of routes
is under [D2](#d2-where-the-mojo-runtime-comes-from). What follows from the ruling:
- **No second step.** There is no `install-runtime` command, no `bin`, no install script, and no
  download of a runtime, at install time or at run time. `npm install` is the only step, and it
  works offline.
- **No runtime pins in the npm packages.** The runtime's bytes are the directory's, chosen by the
  change that builds the directory. The npm build adds no pin of its own for the runtime, and no
  URL or hash of a Modular package.
- **No runtime check at load.** The addon opens `libkomira` and nothing else, and the loader finds
  the runtime libraries through the run path. A platform package whose runtime library is missing
  fails as any unloadable library does (§2, `LibraryLoadError`). The fix is to reinstall the
  package, never to install a Mojo runtime.
- **The bytes a test ran.** Each platform package's runtime libraries are the bytes its install test
  loaded (§5), because the package is the test's input. The directory's runtime libraries
  are taken from the pinned toolchain's Mojo package, the build that compiled `libkomira`
  ([mojo_runtime_pypi_vs_conda.md](mojo_runtime_pypi_vs_conda.md), [NOTICE](../../NOTICE)). The npm
  packages fetch no runtime, so the npm install test loads those same bytes.
- **What the host provides.** On Linux the host provides `libstdc++.so.6` and `libgcc_s.so.1`,
  which the runtime needs, as for the wheel today
  ([mojo_runtime_pypi_vs_conda.md](mojo_runtime_pypi_vs_conda.md),
  [wheel_licence_audit.md](wheel_licence_audit.md), [python/README.md](../../python/README.md)). If
  the self-contained directory changes that set, the npm package follows the directory. The npm
  README states the set the directory needs.

### Licence files

- The main package holds only komira's own JavaScript and types. It carries the repository's
  `LICENSE` and `NOTICE` as they stand when it is built (`"license": "Apache-2.0"`).
- The platform packages carry the same native files as the wheel, the Mojo runtime libraries among
  them, so they carry the same licence files and the same notice as the wheel, and their
  `"license"` field follows the wheel's licence metadata. This design does not write that text. The
  wheel carries the three runtime libraries with Modular's licence file and third-party notices,
  and its License-Expression is `Apache-2.0 AND LicenseRef-Modular-Proprietary`
  ([python/README.md](../../python/README.md)). The npm package rule copies the wheel's licence files
  rather than keeping a second set.
- `NOTICE` reproduces the notices of snappy, Brotli and libc++, which are inside the native owners
  ([wheel_licence_audit.md](wheel_licence_audit.md)), and its last section is on the Mojo runtime
  libraries the wheel carries. Whatever `NOTICE` holds, the npm packages copy. No npm change edits
  `NOTICE`.

### macOS

- `libkomira.dylib` and the addon are ad-hoc signed by the linker, and nothing else signs them
  ([tools/build/mojo/README.md](../../tools/build/mojo/README.md)).
- npm writes files without the quarantine attribute, and Node's macOS binary allows libraries that
  are not signed by its own team. So `dlopen` of an ad-hoc-signed library works
  *(inferred; the macOS install test checks it)*.
- No notarization is planned.

## 4. Release

The release machine today publishes mopm packages from `release.yml` on every push to `main`:
stage, test, commit, smoke ([docs/ci.md](../ci.md), [docs/releases.md](../releases.md)). The conda
release set (`//release:release_set`) is built but not uploaded. The Linux wheel is published by the
top-level `pypi.yml` and the macOS arm64 wheel by `pypi-macos-arm64.yml`, each through the environments
`testpypi` and `pypi` ([python_package.md](python_package.md)). The npm packages follow the wheel's shape.

### The build

- **A package rule.** `npm_tarball`, in `tools/build/package/`, is a Starlark rule with a Zig tool,
  the sibling of `wheel_file` (rule B7; no shell and no Python, rules B4 and B5).
  - It writes the tarball `npm pack` would write: gzip over a tar of `package/...`, members sorted,
    one fixed mtime, modes 0644 and 0755. A `[twin]` action writes it again from inputs staged
    elsewhere, and the check refuses it unless the bytes are equal.
  - It stamps `version` from `komira.package_stamp` and writes `package.json` from the rule's
    attributes. **EXISTS** since part 3: `node/package.json`, the manifest the package's tests read
    (`"private": true`, version `0.0.0`). The rule's change decides whether the rule stamps that file
    or writes its own, and in the second case adds the check that the two agree.
  - Its native input is the self-contained directory of the libkomira target, the one the wheel
    copies. The rule takes the directory as one input and copies it
    whole; it never assembles the library, owners and runtime from separate targets.
  - It reads the tarball back. The ELF policy of `wheel_file` for that directory
    (`_NATIVE_NEEDS` in [python/BUCK](../../python/BUCK)) applies to the platform packages: the glibc floor; every run path at
    `$ORIGIN` or under it; every NEEDED a member or a system library, so the three runtime
    libraries are members; no other file of Modular's distribution; a size cap.
  - The rule refuses a package whose `repository.url` is not `https://github.com/komira-ai/komira`,
    because trusted publishing requires that it match.
  - The policy code is a module both tools import: **EXISTS** as the zig_module
    `//tools/build/package:native_policy` (`tools/build/package/native_policy/`), moved out of the
    wheel tool in a refactor of its own before the npm rule (rule P7).
  - Its sub-targets are `[check]`, `[release]` and `[release_check]`, as for the wheel. The
    `[release]` target refuses an unstamped package.
- **The targets.** `//node:package` (the main package) and
  `//node:package_<platform>` for each platform row of `table.bzl`.
- **A release set of their own.** `//release:npm_packages` is one directory holding the tarballs
  and `npm_set.json`, which records each package's name, version, file, SHA-256 and the sha512
  `integrity` npm reports.
  - It is not a member of the conda `release_set` and not an entry of `artifacts.textproto`. Both
    hold only `_conda` targets, and `release_json names` checks that.
  - The package names are listed in `release/npm_names.txt`, and a Zig case holds the set equal to
    the list, as `prod_claimed_names.txt` does for mopm.
- **The platforms.** linux-x86_64 is built on the farm's Linux workers. macos-arm64 is built by the
  macOS leg (`release-macos.yml`'s farm macOS workers), never in a pull request (rule B9).
  linux-arm64 waits for that platform to be registered.
  - The main package lists only the platform packages that are published.
  - A platform added later is a new optional dependency in a later version. That is additive, and
    a user of an older version is not affected.

### The workflow

A top-level `.github/workflows/npm.yml`. Trusted publishing names a workflow file, so publishing
has a file of its own, as PyPI does. It runs on push to `main` and has `permissions: {}` at the
top. Its jobs:

1. **build** (environment `build`, farm): `//release:npm_packages`, stamped with the run's `N`.
2. **test** (environment `build`, no npm identity): the install test of §5, on each pinned Node.
   - The job's only identity is the farm join, the one `prod-test` already uses
     ([docs/ci.md](../ci.md)).
   - It tests the tarballs that the build job uploaded as a workflow artifact, after checking each
     against `npm_set.json`.
3. **publish** (environment `npm`, `contents: read` and `id-token: write`, no token). Each
   platform tarball first, then the main package, with `npm publish <file> --access public`.
   - Trusted publishing exchanges the job's OIDC token, so no `NPM_TOKEN` exists anywhere.
   - Provenance is generated automatically for a public repository and a public package.
   - The CLI must be npm 11.5.1 or later, under Node 22.14 or later (npm's trusted-publishing page,
     read 2026-11-20).
   - The repository has no npm today, so the CLI is a new pin, by URL and SHA-256 (rule B10). It is
     the npm tarball from the registry, run by the pinned Node, and visible only to this job's
     target.
4. **smoke** (no identity): one named Zig tool, `//release/ci:npm_smoke`, run as one step (rule
   B4).
   - It installs the exact version from the registry into an empty directory, compares each
     package's `integrity` with `npm_set.json`, and runs `SELECT 1`. There is no step between the
     install and the query.
   - This job is the one place a test reaches the network, and it reaches only the npm registry.

How it holds the rules:
- Hosted runners only, every action pinned by SHA, no `pull_request_target`, actionlint clean
  (rule B10).
- No `pull_request` trigger and no pull-request job (rule B9).
- It runs automatically from `main`, with no tag (rule B12).
- A Zig case file like `release_workflow_test.zig` holds the jobs' permissions and environments,
  with a negative case for each (rule T15).

**Failure.** npm creates a (name, version) once, like the mopm registry.
- A run that fails before the main package is published leaves only platform packages that
  nothing names. The next run publishes `N+1`.
- A run whose smoke fails turns the run red, and `npm deprecate` of that version is the owner's
  call.
- npm's trusted-publisher page (read 2026-11-20) lists `npm stage publish` among a publisher's
  actions. If staged publishing is available when the job is written, publish mirrors mopm's
  stage, test and commit.

**Owner steps outside the repository**, before the first publish:
- confirm that the `komira-ai` scope on npm is the company's;
- create the four packages and their trusted publishers (workflow `npm.yml`, environment `npm`);
- create the `npm` environment on GitHub, deployable from `main` only.

The npm documentation does not say whether a trusted publisher can be configured before its
package exists. The owner settles that, and how the first version of each package is created. No
one publishes by hand otherwise.

## 5. Tests

All tests are hermetic: no network, no clock, no fixed port (rule T12). The behaviour tests are
written in TypeScript (rule T11) and run with the pinned Node, which strips types itself, so they
need no build step. `node_binding_test` takes `.mjs`, `.js`, `.ts` and `.mts` files (**EXISTS**).
`tsc_check` checks the package's tests' types (`//node:typecheck`).

### The package's own tests

These are `node_binding_test` targets under `node/tests/`, in the pull request's set, on
linux-x86_64.
- **The addon.**
  - Each session's calls run in order on its own thread.
  - Two sessions run at once. A stand-in library blocks inside a call until the test releases it,
    which is an explicit event, not a sleep.
  - An `fs` call completes while four sessions are blocked, which shows the libuv pool is free.
  - `close` during a call frees the context once, after that call.
  - Finalizers are counted, as today.
- **The Arrow import.** A stand-in library exports fixed streams:
  - every type of the exporter's set, with nulls, offsets and a dictionary;
  - an empty result;
  - a stream whose `get_next` fails;
  - a misaligned buffer;
  - a format the mapping does not know.
  Release counts show that every `ArrowArray` is released exactly once, and only after its buffers
  are collected.
- **The surface.**
  - `exports_test` holds the exact public names.
  - The loader's refusals: a missing platform package, ABI 2.0 and 0.999, a symbol missing for the
    library's minor, a call of a newer minor, and a CPU without x86-64-v3, from a cpuinfo fixture.
  - A staged directory with one of the three runtime libraries removed rejects with
    `LibraryLoadError` and no other class, with a message that names the missing library's file.
    The loader's text varies by platform, so this test checks the class and the file name. The
    other refusals assert the full message by equality (rule T13). This test needs the directory,
    so it lands with the package rule (item 6 of the plan) or after it.
  - `SELECT 1 AS n` and a `GROUP BY` over the checked-in Parquet fixture answer as DuckDB does.
  - An unknown table, a syntax error and an unsupported construct reject from `sql` with their
    class, `step` and `code`.
  - A second read of a `Result` rejects.
  - An unread `Result` of a closed session reads.
  - Arguments of the wrong type or value throw before the library is called.
- **Coverage.** Node's test runner writes lcov (`--experimental-test-coverage` with the lcov
  reporter), so `node/` is measured at line and branch level against 99% (rule T1).
  - **EXISTS** for the TypeScript: `node_binding_test`'s `covered_srcs` are measured in the test's own
    action, which fails under 99% or when a listed source was never loaded (node leaves an unloaded
    file out of its totals). Showing the same numbers in the coverage job's table, through
    covcheck, is a later step.
  - The addon's C has no measurement yet. covcheck reads lcov, so the addon can be compiled with
    coverage instrumentation and its counts written as lcov. Which instrumentation `zig cc` uses
    for this is that change's to show.

### From the installed package, on each platform

`//node:install_test` installs the built tarballs into an empty project with the pinned npm of §4
(`npm ci --ignore-scripts --offline`, from `file:` tarballs and the pinned `apache-arrow`). It is
the one build action that runs npm.
- It uses npm rather than the Zig `npm_modules`, because the test is that npm itself installs the
  package: the `optionalDependencies` and `os`/`cpu`/`libc` selection, and the peer dependency.
- `--ignore-scripts` holds that the package needs no install script.
- It then runs behaviour tests that import `@komira-ai/komira` by its name, never by a path into
  the repository:
  - the version;
  - the public names;
  - the load of `libkomira` from the installed platform package alone, with no Mojo toolchain, no
    `mojo-compiler` and no library path in the test's environment, which is what a user's machine
    has;
  - `SELECT 1`;
  - a `GROUP BY` over Parquet, CSV and NDJSON fixtures, once those registrations exist;
  - an `apache-arrow` `instanceof` check on the result;
  - a `require()` of the package from CommonJS.
- It runs once per pinned Node: 22, 24 and 26 on linux-x64.
- The test stages no runtime of its own: the runtime is whatever the platform tarball holds, so the
  test runs the bytes that are published.
- On macos-arm64 and linux-arm64 the same target runs in the release workflows only, never in a
  pull request (rule B9). The published package names a platform only after that platform's
  install test passed.

### SQL conformance, reused

The SQL cases are data already: `src/tests/conformance/komira_sql_conformance/cases/<corpus>/`
holds `tables.sql`, `<case>.sql` and the committed DuckDB answer `<case>.tsv`
([README](../../src/tests/conformance/komira_sql_conformance/README.md)). The Node runner,
`//node:sql_conformance_test` ([node/tests/conformance](../../node/tests/conformance/README.md)), runs
every case through `Session.sql`. A Python end-to-end runner over them is planned but not built. The Mojo package
`src/tests/e2e/sql_e2e` holds komira's SQL to DuckDB through `so.sql_result` over a corpus of its
own, on `komira_test_oracle`'s datasets and its own regression tables; no matrix cell names one
of its targets yet. The Node runner reads **the same files through Buck2 targets**,
and copies none of them.
- **Tables.** Both runners register the same Parquet export of each corpus's `tables.sql`, built
  once by DuckDB as a target beside the corpus. Neither runner executes `CREATE TABLE`.
- **Answers.** Both runners render each Arrow cell by the rules of the committed TSV (NULL as an
  empty cell, `""`, shortest round-trip floats, `nan`/`inf`, decimals at their scale), sort when
  the case says `order: rows`, and compare text with the header.
- **Refusals.** The cases komira refuses by name sit in one list both runners read, with the
  refusal each expects, so the two languages cannot disagree on what is supported. The cases komira
  answers otherwise than DuckDB sit in a second list beside it, `differences.tsv`, each with how its
  answer differs, so every case is held to exactly one outcome and a fix shows as a removed line.
- **Negatives.** A fixture corpus with one wrong committed answer must fail the Node runner, the
  negative case of rule T15.
- **The matrix.** The `sql` cells of `tests/surface_capability_matrix.bzl` are to be filled by the
  Python runner's targets. The Node runner checks the binding, not a new surface: SQL is one surface,
  however it is reached. The `ts_polars` and `excel` cells are filled by those SDKs.

## 6. The Excel SDK

The owner settled the shape: Excel is a separate TypeScript SDK. It turns Excel formulas into
logical plans and submits them through `komira_plan_stream`, as the pandas-shaped and polars-shaped
Python SDKs do. libkomira has no Excel call ([libkomira_run_abi.md](libkomira_run_abi.md) §4).

The SDK is a package of its own (`@komira-ai/excel`, decision D1). It depends on the main package
for the session and the plan door, and it adds no native file.

What the earlier code base had. The first two items are recorded in
[libkomira_run_abi.md](libkomira_run_abi.md) §4. The rest was read in the earlier code base's
sources, which are not in this repository *(read there, not checkable here)*:
- A formula parser and a plan builder, in Mojo inside the shared library.
- Seven `xl_*` calls that bound names, values and cells, listed functions, evaluated, rendered and
  streamed formulas, and a scalar evaluator that ran a formula with no plan.
- A second, relational evaluator beside the scalar one.
- Excel error values (`#DIV/0!`, `#N/A`, `#VALUE!`, `#REF!`, `#NAME?`, `#NUM!`, `#NULL!`,
  `#SPILL!`, `#CALC!`), carried in a columnar error sidecar ([port_audit](port_audit.md)).
- An expectation corpus written by hand from published function documentation, each row with its
  source and a quote, checked by a checker that imported no implementation.

Where the port differs, and why:

1. **The parser and the plan builder are TypeScript, in the SDK.** The library only ever sees plan
   bytes. The seven calls are not carried.
2. **One door, and no scalar evaluator.** Every formula becomes a plan, `=1+1` included, as a
   projection over a one-row input. Two evaluators of one function were a standing source of
   disagreement in the earlier code base.
3. **Inputs are named tables or literals.** A range is a table the host registers, and a cell value
   is a literal in the plan. The earlier in-memory bindings to batches had no wire form, and the
   wire already carries named scan bindings.
4. **The SDK needs a TypeScript encoder of `komira.plan.v1`.** It is generated from
   `src/plan_proto/plan.proto` with its goldens (rule T19), and it is shared with the `ts_polars`
   builder. New expression arms on the wire are additive (rule B8).
5. **Excel semantics are engine work.** Some answers differ from SQL's. Excel `UPPER` folds `ß` to
   `SS`, where DuckDB's maps one code point to one. These functions are plan expressions with Excel
   behaviour, never a reused SQL kernel. How a result column carries an error value is decided with
   those expressions, as data in the Arrow stream, never as a status of the run call.
6. **Division and other operators** lower to Excel's behaviour explicitly (a guard that yields
   `#DIV/0!`), never to the engine's SQL operator, because DuckDB's division by zero is not
   Excel's.
7. **The function census becomes named refusals.** A function with no plan form is refused by name
   (rule B21) with the new door's errors. The earlier message prefixes are not carried.
8. **The expectation corpus is kept, and its checker is TypeScript.** It stays hand-written from
   published sources, each row with its source and a quote, and its divergences are recorded and
   never rewritten. There is no Python generator and no Python checker (rules T11 and B5).

## Decisions for the owner

### D1. The npm name

This is one question: the install line.

Registry check, read-only, 2026-11-20: `registry.npmjs.org` answers 404 for `komira`,
`komira-ai`, `@komira-ai/komira`, `@komira-ai/sdk`, `@komira-ai/node`, `@komira-ai/excel` and
`@komira-ai/komira-linux-x64-gnu`. The scope endpoint `/-/org/komira-ai/package` answers 200 with
no packages, where a scope that does not exist answers 404. So the `komira-ai` organisation exists
on npm and has no public package. Who owns it cannot be read from outside.

| option | install line | platform packages | Excel |
|---|---|---|---|
| **A (recommended)** | `npm install @komira-ai/komira` | `@komira-ai/komira-<platform>` | `@komira-ai/excel` |
| B | `npm install komira-ai` | `@komira-ai/komira-ai-<platform>`, or unscoped names | `komira-ai-excel` or `@komira-ai/excel` |
| C | `npm install @komira-ai/sdk` | `@komira-ai/sdk-<platform>` | `@komira-ai/excel` |

Recommendation: **A**.
- The platform packages need a namespace no one else can publish into, and the organisation's scope
  is one. With A, every name lives in one namespace the company holds, so nothing has to be claimed
  early to protect it.
- B adds a second, flat name that has to be held beside the scope.
- `komira` is the product's name, and the Python import name. `@komira-ai/komira` reads as "komira,
  from komira-ai", which matches the GitHub repository `komira-ai/komira`.
- C names a kind of thing rather than the product.

### D2. Where the Mojo runtime comes from

**Ruled: D.** The owner ruled that the native library is self-contained, and that komira may
redistribute the Mojo runtime libraries. One self-contained directory is the unit every language
package copies, which also makes the library easier to ship to languages beyond Python and Node.
This section records the routes that were compared and why they lost.

| option | what the user runs | for | against |
|---|---|---|---|
| A an explicit command fetches Modular's PyPI wheel | `npm install @komira-ai/komira`, then `npx @komira-ai/komira install-runtime` once | no install script; pinned by version and SHA-256; no network at query time | **a second step for the user**, and a download that needs network after install; downloads Modular's whole compiler wheel (71 to 79 MB) for about 2 MB of libraries; it writes into `node_modules`, which under pnpm is a store shared by projects; it adds a command, its pins and a runtime-not-found error to the public surface; and it would load libraries other than the ones the package's tests ran |
| B the same fetch, in a `postinstall` script | `npm install` | one step where scripts run | **a download at install time**, which pnpm and Bun skip by default and `--ignore-scripts` skips everywhere, so A's command is needed anyway; install scripts are also a supply-chain warning sign |
| C the user installs the runtime with pip or conda, and the package finds it | `pip install mojo-compiler==<pin>`, then `npm install` | no download code of ours | **a second step, in another language's installer**; Node has no `sys.path`, so finding the runtime needs a search or a setting, and a setting would be an environment variable (rule S2) or an option on every session |
| **D (ruled)** the platform packages carry the three libraries, as members of the self-contained directory | `npm install` | one step; works offline; no download code, no command, no runtime pins of the package's own, no runtime error path; the installed bytes are the tested bytes; the same directory serves every language package | the platform package is about 2 MB larger; a fix to the runtime reaches users only in a new komira release; the package carries Modular's files, so its licence files and notice follow the wheel's, whose text is not decided here (§3) |

What a user learns: `npm install @komira-ai/komira`, and nothing else.

### D3. The public API of the first release

The names and behaviour of §2:
- asynchronous calls, with a native thread per session;
- the default session per environment;
- `apache-arrow` as a required peer dependency at `^21.2.0`;
- ESM only, on Node 22.12 and later;
- paths resolved as Node's `fs` resolves them, with no `~`;
- `registerCsv` and `registerNdjson` as the names for CSV and NDJSON;
- no cancel until the addon binds libkomira's run handle.

Recommendation: approve as written. The CSV and NDJSON names should be the Python package's too
(`register_csv`, `register_ndjson`), which its registration change has not named yet.

### D4. When npm publishing starts

The owner gave the go for PyPI releases from the workflow. npm has no go yet.
- Option A: publish from `npm.yml` on every push to `main`, from the first version in which `sql`
  works.
- Option B: publish before then, as Python's release 1 does, with no query call.

Recommendation: **A**. With the scope held there is no name to protect early, and an npm package
that runs no query would be a release with nothing in it.

## What must always hold?

- The packages carry the self-contained native directory (`libkomira`, its native owners and the
  three Mojo runtime libraries), the addon, the licence files and the compiled JavaScript, and no
  other file of Modular's distribution.
- `npm install` is the only step. Nothing is downloaded after it, at install time or at run time.
- No public behaviour is configured by an environment variable.
- The public names are exactly the list `exports_test` holds.
- Each platform package's native files are the bytes its install test ran.
- A query answers what DuckDB answers for the same SQL, or is refused by name.
- The package adds no libkomira call. Node reaches the engine only through the calls Python uses.

## What are the limits and open questions?

- The npm platform packages wait for `npm_tarball` and the npm release set. The self-contained
  directory they copy, and the licence files and notice the wheel carries with it, are on `main`.
- Tests in `.ts` run with type stripping on the pinned 24, and on a Node 22 pin only from 22.18,
  so the Node 22 pin is 22.18 or later.
- linux-arm64 waits for its build platform. macos-arm64 waits for the macOS build of the addon;
  `libkomira` itself builds and loads on macOS, and the macOS arm64 wheel carries
  `libkomira.dylib` and the three runtime libraries. Both platforms also need a Node pin of their
  own (the one pin is linux-x64, [third_party/node/pins.bzl](../../third_party/node/pins.bzl)).
- Whether ad-hoc signing is enough on macOS is inferred, not tested.
- Whether a trusted publisher can be configured before its package exists is not stated by npm's
  documentation.
- Electron, Deno and Bun are not claimed. Electron refuses external `ArrayBuffer`s.

## Where the work lands

Each part is its own change, with its tests:
1. the addon's session thread and asynchronous calls;
2. the Arrow import, against a stand-in stream;
3. the TypeScript package with its loader and public names;
4. `sql` and `Result`, once `komira_sql_stream` exists;
5. errors, session options, and CSV and NDJSON registration, each after its library change;
6. the package rule and the release set, consuming the self-contained directory of the libkomira
   target (`//src/so:libkomira[dist]`, which the wheel already uses);
7. the macOS and linux-arm64 builds;
8. the install tests;
9. `npm.yml`;
10. the SQL conformance runner.

The change that first ships the addon also updates
[third_party/node/README.md](../../third_party/node/README.md) ("Never shipped") and its
visibility lists. The headers become a build input of a published package, while the `node`
runtime itself stays test-only.

The Excel SDK and the `ts_polars` builder follow, on a shared plan encoder.

## Where is the code?

Today: [node/](../../node/README.md), [tools/build/node](../../tools/build/node/README.md),
[third_party/node](../../third_party/node/README.md), [src/so](../../src/so/README.md), and `node/src/`
for the TypeScript. Later: `tools/build/package/` for `npm_tarball`, `release/` for the npm set, and
`.github/workflows/npm.yml`.
