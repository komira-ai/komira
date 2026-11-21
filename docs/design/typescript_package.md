# The TypeScript package: surface, packaging and release

Status: design, not built. **EXISTS** names code on `main`. **PROPOSED** is new. Statements the
author deduced rather than read are marked *(inferred)*. The choices only the owner can make are
collected under [Decisions for the owner](#decisions-for-the-owner). Until the owner answers them,
the npm names below are the recommended ones, not settled ones.

## What problem does this solve?

People should be able to `npm install` komira and run SQL over their local files from Node, with
Arrow data back. komira has a Node addon over `libkomira` ([node/README.md](../../node/README.md)),
but it is test-only. It runs no query, returns no Arrow, and nothing of it is published.

The Python package ([python_package.md](python_package.md)) is the sibling. Both bind the same
library through the same C calls ([libkomira_run_abi.md](libkomira_run_abi.md)). This document
covers the parts that are Node's own:
- the first release's surface and how an Arrow C stream reaches JavaScript;
- the npm packages and how they find `libkomira`, while carrying no Mojo runtime;
- how they plug into the release machine;
- the tests that run from the installed package;
- where the Excel SDK and the later surfaces sit.

Fixed before this design, and not reopened here:
- **One C ABI.** The run calls are `komira_sql_stream` and `komira_plan_stream`, with an Arrow C
  stream as the result ([libkomira_run_abi.md](libkomira_run_abi.md)). This design adds no
  libkomira call.
- **No Mojo runtime in the package.** The package carries `libkomira` and never the Mojo runtime,
  the same rule as the wheel.
- **Release platforms.** linux-x86_64, linux-arm64 and macos-arm64 (rule B11).
- **One UDF mode per language.** UDFs written in TypeScript run in Node worker processes (rule B21,
  [udf_runtime_interface.md](udf_runtime_interface.md)).
- **Excel is a separate TypeScript SDK.** It turns Excel formulas into logical plans and submits
  them through `komira_plan_stream`. libkomira has no Excel call ([libkomira_run_abi.md](libkomira_run_abi.md) §4).

## 1. What exists

### The addon

- **EXISTS** [node/komira_addon.c](../../node/komira_addon.c) (511 lines) is a Node-API addon in C.
  - It defines `NAPI_VERSION 8` and uses `NAPI_MODULE_INIT`, so it is context-aware. Its function
    table is process-wide, and a worker thread shares it (the comment at the table). No test loads
    this addon in a worker. `src/tests/helpers/komira_test_node` shows the pattern with its own
    test addon, loaded in a main thread and two workers.
  - It exports eight functions: `load`, `abiVersion`, `newSession`, `freeSession`,
    `registerParquet`, `parquetSchema`, `planRender` and `sessionStats`.
- **How it binds libkomira.** `load(path)` opens the library with `dlopen(RTLD_NOW | RTLD_LOCAL)`
  and requires `komira_abi_version()` major 1. It then resolves seven symbols by name, and a
  missing one is named in a `KOMIRA_MISSING_SYMBOL` error.
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
- **Errors.** A non-zero status throws an `Error` that carries `status`, `code` (the
  `KOMIRA_ERR_*` name) and `lastError` (read with the two-call protocol). Misuse of the addon
  throws an error with a `code` and no `status`: `KOMIRA_ARG`, `KOMIRA_NOT_LOADED`,
  `KOMIRA_SESSION_FREED`, `KOMIRA_LOAD_FAILED`, `KOMIRA_ABI_MISMATCH`, `KOMIRA_MISSING_SYMBOL` and
  `KOMIRA_LOADED`.
- **Calls it does not bind.** `komira_csv_binding` and `komira_json_binding` have no function in
  the addon. Nothing in it runs a query.

### Tests and CI

- **EXISTS** [node/BUCK](../../node/BUCK) has two `node_binding_test` targets.
  - `:load_test` runs [load.test.mjs](../../node/load.test.mjs) and
    [capacity.test.mjs](../../node/capacity.test.mjs). They cover the load refusals, using
    stand-ins built from [tests/fake_libkomira.c](../../node/tests/fake_libkomira.c): ABI 2.0,
    ABI 0.999, a missing `komira_plan_render`, and a library that records the capacity it was
    given.
  - `:session_test` runs [session.test.mjs](../../node/session.test.mjs). It covers errors with
    their last error, the frozen schema bytes of `two_columns.parquet`, plan text, wrong-kind
    arguments, a foreign external, double free, and finalizers counted with `gc()` with no clock.
- **EXISTS** Both tests are in the pull request's check set (`ci/targets/shard_7.bzl`).
  - `node_binding_test` runs `node --test` as a build action, under `env -i`, with no network.
  - It passes only if TAP reports tests, all passed, and none skipped
    ([tools/build/node/README.md](../../tools/build/node/README.md)).
- **EXISTS** Nothing measures the coverage of `node/`. `.github/workflows/coverage.yml` and the
  covcheck README never name it *(inferred from a search of both)*. covcheck does read lcov
  tracefiles ([tools/build/coverage/README.md](../../tools/build/coverage/README.md)).

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
  - These rules are used only by `src/tests/helpers` and their negative fixtures under
    `tools/build/tests/negative`.
- **EXISTS** Pinned npm tarballs include `apache-arrow` 21.2.0. It is used by a test of an Arrow
  IPC round trip in `komira_test_node`.
- **EXISTS** "Never shipped" ([third_party/node/README.md](../../third_party/node/README.md)): the
  `node` runtime and every npm package are visible only to `src/tests/*` and `//node`, and a
  conda package cannot hold JavaScript.

### Release state

- **Nothing is released.** The SDK has no `package.json`, no TypeScript source, no `.d.ts`, and no
  npm name. The only `.ts` files in the repository are test fixtures under `src/tests/helpers` and
  `tools/build/tests/negative`. No workflow mentions npm publishing. The only use of npm in a workflow is the
  pin check in `kpin-update.yml`.

### The library under it

- **EXISTS** `libkomira` is at ABI 1.1, with nine exports
  ([src/so/abi/komira.tsv](../../src/so/abi/komira.tsv)).
  - It runs no query. The 1.2 run calls are designed but not built.
  - On linux-x86_64 it is 3.5 MB, with run path `$ORIGIN/lib:$ORIGIN`, and its eight native owners
    sit in `lib/` beside it ([src/so/README.md](../../src/so/README.md)).
  - It needs the three Mojo runtime libraries at load time: `libKGENCompilerRTShared`,
    `libAsyncRTRuntimeGlobals` and `libMSupportGlobals`
    ([mojo_runtime_pypi_vs_conda.md](mojo_runtime_pypi_vs_conda.md)).
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
| `new Session(options?)` | one engine context (`komira_ctx_new`) and its tables. The options are `{ threads?: number, memoryLimit?: number }`, both settable once the session-options calls of the ABI land. `memoryLimit` is in bytes, and an omitted option takes the engine's default. Options are arguments, never environment variables (rule S2) |
| `session.registerParquet(name, path): Promise<void>` | `komira_register_parquet`. `path` is a `string` or a `file:` `URL`. A relative path resolves against the working directory when the call is made, as Node's `fs` does, and `~` is not expanded. Registering a name again replaces it |
| `session.registerCsv(name, path, options?)`, `session.registerNdjson(name, path)` | CSV and newline-delimited JSON. They arrive with libkomira calls that register those formats by name. No design has those calls yet: [libkomira_run_abi.md](libkomira_run_abi.md) §7 says only "the later source calls", and today's `komira_csv_binding` and `komira_json_binding` return bindings, not registrations. The CSV options are the ones `komira_csv_binding` takes: `{ delimiter?: string, header?: boolean, allVarchar?: boolean }` |
| `session.sql(query): Promise<Result>` | runs one SQL statement through `komira_sql_stream`. **The official door of the first release** |
| `session.close()`, `session.closed`, `session[Symbol.dispose]()`, `session[Symbol.asyncDispose]()` | closing is idempotent, and `using` / `await using` close the session |
| `Result` | the answer of one `sql` call: `toArrow(): Promise<Table>`, and `[Symbol.asyncIterator]()`, which yields `apache-arrow` `RecordBatch`es |
| `sql(query)`, `registerParquet(name, path)` | the same calls on a default session (below) |
| `abiVersion(): number` | `komira_abi_version()`, `major * 1000 + minor` |
| `version: string` | the package's version |
| `KomiraError`, `LibraryLoadError`, `UnsupportedCpuError`, `RuntimeNotFoundError`, `UnsupportedOperation` | the errors (below) |
| the command `komira install-runtime` (the package's `bin`, run as `npx @komira-ai/komira install-runtime`) | fetches the Mojo runtime, under the route of decision D2. It is public surface like the names above, and it goes if D2 picks a route without it |

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
  - `UnsupportedCpuError extends LibraryLoadError`: on linux-x64 the CPU lacks a flag of
    x86-64-v3. The package reads `/proc/cpuinfo` before it loads the addon, so the process never
    dies on an illegal instruction. The flags and the message are the Python check's
    (komira-ai/komira#2121).
  - `RuntimeNotFoundError extends LibraryLoadError`: the Mojo runtime is missing or of the wrong
    version, with the fix in the message. This is the Python package's name for the same error
    (komira-ai/komira#2122). Its route is decision D2.
- Arguments are JavaScript's own. A wrong type is a `TypeError`, and a wrong value of the right
  type is a `RangeError` (`threads: 0`, an empty table name, a NUL byte in a path). Both are raised
  before the library is called.
- The addon's own error codes (`KOMIRA_ARG`, ...) stay inside the private layer. The public errors
  are the classes above.

### Cancellation

The first release has no cancel, and its README says so. libkomira has no cancel call yet: it is
proposed as `komira_cancel` with status -6 in [libkomira_run_abi.md](libkomira_run_abi.md) §10,
and is not decided.

An `AbortSignal` that only rejected the promise would leave the engine running and holding the
session's thread, so it is not offered.
- When the cancel call lands, `sql(query, { signal })` is added: an additive option.
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
- **Also later:** object stores and credentials; writes; progress; `explain()` through
  `komira_plan_render`.

## 3. Packaging

### The packages

The npm packages follow the shape esbuild and rollup use: a main package of JavaScript, and one
package per platform holding the native files, named in the main package's
`optionalDependencies`. npm installs only the platform package whose `os`, `cpu` and `libc` match
the host.

| package (decision D1) | holds | `os` / `cpu` / `libc` |
|---|---|---|
| `@komira-ai/komira` | the compiled JavaScript, `.d.ts` types, `README.md`, `LICENSE`, `NOTICE` | none |
| `@komira-ai/komira-linux-x64-gnu` | `komira_addon.node`, `libkomira.so`, `lib/` (the eight native owners), `LICENSE`, `NOTICE` | `linux` / `x64` / `glibc` |
| `@komira-ai/komira-linux-arm64-gnu` | the same, for aarch64 | `linux` / `arm64` / `glibc` |
| `@komira-ai/komira-darwin-arm64` | `komira_addon.node`, `libkomira.dylib`, `lib/` | `darwin` / `arm64` |

- **Versions.** Every package has one version, `0.1.<N>`, the wheel's scheme. `N` is the same
  stamp the wheel and the conda packages take (`komira.package_stamp`,
  `tools/build/package/wheel.bzl`); the conda packages spell their version differently. The main
  package names its platform packages at that exact version.
- **Rejected: one tarball with every platform's files in it.** Every install would download three
  platforms' libraries.
- **Rejected: an install script that downloads the binaries.** pnpm and Bun do not run dependency
  install scripts by default, `--ignore-scripts` skips them, and the files would come from
  somewhere no test of the package ran.
- **Size.** A platform package is about 4 MB on linux-x64: the library is 3.5 MB and the owners
  0.5 MB *(inferred from the linux-x86_64 table of [src/so/README.md](../../src/so/README.md))*.

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
  3. it calls the addon's `load` with the path of `libkomira` in the same directory.
- The library's run path (`$ORIGIN/lib:$ORIGIN`, `@loader_path/lib` on macOS) finds the owners in
  `lib/`.
  - That is the layout of `//src/so:libkomira[runnable]`. But `[runnable]`'s `lib/` also holds the
    Mojo runtime libraries ([tools/build/mojo/README.md](../../tools/build/mojo/README.md)), so the
    package rule copies the library and its owners out of it, never the runtime libraries.
  - The policy check refuses a runtime member.
- There is no environment variable, no search of the working directory, and no global install
  path. That is Python's decision 6, for the same reason: a package must load the library its own
  tests ran.
- Tests call the private `load(dir)` with the directory their target staged, as the addon tests
  do now.

### The Mojo runtime (decision D2)

The wheel gets the runtime from Modular's own published package: it declares `mojo-compiler` as a
dependency, and its loader preloads the three libraries from `<site>/modular/lib`
(`python/komira/_runtime.py`, komira-ai/komira#2122). npm has no such package. Modular publishes the runtime on PyPI and conda,
not on npm *(inferred: no Modular runtime package was found on npm; the repository names none)*.
Under the rule that the package carries `libkomira` and never the runtime, the package must reach a
runtime Modular publishes. The routes are compared in [D2](#d2-where-the-mojo-runtime-comes-from).

The recommended route is one explicit command and no install script:
- `npx @komira-ai/komira install-runtime` downloads Modular's `mojo-compiler` wheel for the host
  platform from PyPI.
  - The wheel's version, URL and SHA-256, and each of the three libraries' SHA-256, are new pins,
    one set per platform.
    - The repository pins the conda runtime, not the PyPI wheels: `mojo_compiler` in
      `tools/build/platforms/table.bzl` is a `.conda` package.
    - The PyPI hashes are measured in [mojo_runtime_pypi_vs_conda.md](mojo_runtime_pypi_vs_conda.md),
      and two of the three libraries differ from the conda pins in their bytes.
  - It checks the hash and extracts only the three runtime libraries from `modular/lib/`.
  - It writes them into a `runtime/` directory of the platform package.
- At load, the addon opens the three by absolute path with `RTLD_GLOBAL`, in Python's order
  (`libMSupportGlobals`, `libAsyncRTRuntimeGlobals`, `libKGENCompilerRTShared`), and then opens
  `libkomira`.
  - A missing or wrong library is a `RuntimeNotFoundError` whose message is the command.
  - The libraries' SHA-256 values are checked against the pins, so the version is checked by
    bytes, not by metadata.
- Network is used by that command and by nothing else. A query never fetches anything.
- **What the route depends on.** It holds only if `libkomira`, built against the conda runtime,
  loads against the PyPI runtime's libraries. That check is marked NOT RUN in
  [mojo_runtime_pypi_vs_conda.md](mojo_runtime_pypi_vs_conda.md). The wheel route depends on it
  too, and the wheel's install test runs it.
- **What the host provides.** The host provides `libstdc++.so.6` and `libgcc_s.so.1`, which the
  runtime needs, as for the wheel ([mojo_runtime_pypi_vs_conda.md](mojo_runtime_pypi_vs_conda.md),
  [wheel_licence_audit.md](wheel_licence_audit.md), [python/README.md](../../python/README.md)).
  The npm README says so.

### Licence files

- Each tarball carries the repository's `LICENSE` and `NOTICE` (`"license": "Apache-2.0"`).
- `NOTICE` already reproduces the notices of snappy, Brotli and libc++, which are inside the native
  owners. Each platform package carries those same files
  ([wheel_licence_audit.md](wheel_licence_audit.md)).
- `NOTICE`'s section on the Mojo runtime ("a dependency, not distributed") gains the npm route's
  sentence in the change that implements D2.

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
release set (`//release:release_set`) is built but not uploaded. The wheel is to be published by a
top-level `pypi.yml` through the environments `testpypi` and `pypi`
([python_package.md](python_package.md)). The npm packages follow the wheel's shape.

### The build

- **A package rule.** `npm_tarball`, in `tools/build/package/`, is a Starlark rule with a Zig tool,
  the sibling of `wheel_file` (rule B7; no shell and no Python, rules B4 and B5).
  - It writes the tarball `npm pack` would write: gzip over a tar of `package/...`, members sorted,
    one fixed mtime, modes 0644 and 0755. A `[twin]` action writes it again from inputs staged
    elsewhere, and the check refuses it unless the bytes are equal.
  - It stamps `version` from `komira.package_stamp` and writes `package.json` from the rule's
    attributes. There is no `package.json` in the repository that could drift.
  - It reads the tarball back. The ELF policy of `wheel_file` applies to the platform packages: the
    glibc floor; every run path at `$ORIGIN` or under it; every NEEDED a member or a system
    library; the Mojo runtime named as external and never a member; a size cap.
  - The rule refuses a package whose `repository.url` is not `https://github.com/komira-ai/komira`,
    because trusted publishing requires that it match.
  - The policy code moves into a module both tools import, in a refactor of its own before the npm
    rule (rule P7).
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
     package's `integrity` with `npm_set.json`, runs `install-runtime`, and runs `SELECT 1`.
   - This job is the one place a test reaches the network: the registry and Modular's runtime.

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
need no build step. `node_binding_test` takes `.mjs` and `.js` today, and it gains `.ts`.
`tsc_check` checks the tests' types.

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
  - The runtime's refusals. Each asserts the full message by equality (rule T13).
  - `SELECT 1 AS n` and a `GROUP BY` over the checked-in Parquet fixture answer as DuckDB does.
  - An unknown table, a syntax error and an unsupported construct reject from `sql` with their
    class, `step` and `code`.
  - A second read of a `Result` rejects.
  - An unread `Result` of a closed session reads.
  - Arguments of the wrong type or value throw before the library is called.
- **Coverage.** Node's test runner writes lcov (`--experimental-test-coverage` with the lcov
  reporter), and covcheck reads it, so `node/` is measured at line and branch level against 99%
  (rule T1).
  - The addon's C has no measurement yet. covcheck reads lcov, so the addon can be compiled with
    coverage instrumentation and its counts written as lcov. Which instrumentation `zig cc` uses
    for this is that change's to show.
  - The first change that touches `node/` wires both. Until it does, `node/` is a touched package
    with no number.

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
  - the runtime refusal without the runtime, and the load with it;
  - `SELECT 1`;
  - a `GROUP BY` over Parquet, CSV and NDJSON fixtures, once those registrations exist;
  - an `apache-arrow` `instanceof` check on the result;
  - a `require()` of the package from CommonJS.
- It runs once per pinned Node: 22, 24 and 26 on linux-x64.
- The runtime comes from the toolchain's pinned runtime, staged where `install-runtime` would put
  it. The command's own download is tested on a local archive passed to a private parameter, never
  over the network.
- On macos-arm64 and linux-arm64 the same target runs in the release workflows only, never in a
  pull request (rule B9). The published package names a platform only after that platform's
  install test passed.

### SQL conformance, reused

The SQL cases are data already: `src/tests/conformance/komira_sql_conformance/cases/<corpus>/`
holds `tables.sql`, `<case>.sql` and the committed DuckDB answer `<case>.tsv`
([README](../../src/tests/conformance/komira_sql_conformance/README.md)). Nothing runs komira on
them yet. A Python end-to-end runner over them is planned but not built (the matrix's `sql` cells
read "no sql_e2e package yet"). The Node runner reads **the same files through Buck2 targets**,
and copies none of them.
- **Tables.** Both runners register the same Parquet export of each corpus's `tables.sql`, built
  once by DuckDB as a target beside the corpus. Neither runner executes `CREATE TABLE`.
- **Answers.** Both runners render each Arrow cell by the rules of the committed TSV (NULL as an
  empty cell, `""`, shortest round-trip floats, `nan`/`inf`, decimals at their scale), sort when
  the case says `order: rows`, and compare text with the header.
- **Refusals.** The cases komira refuses by name sit in one list both runners read, with the
  refusal each expects, so the two languages cannot disagree on what is supported.
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

| option | what the user runs | for | against |
|---|---|---|---|
| **A (recommended)** an explicit command fetches Modular's PyPI wheel | `npm install @komira-ai/komira`, then `npx @komira-ai/komira install-runtime` once | keeps the rule (the package carries no runtime file); pinned by version and SHA-256; no install script; no network at query time | two steps; downloads Modular's whole compiler wheel (71 to 79 MB) for about 2 MB of libraries; it writes into `node_modules`, which under pnpm is a store shared by projects, so the runtime lands in the store's copy; it depends on the load check that has not run yet |
| B the same fetch, in a `postinstall` script | `npm install` | one step where scripts run | pnpm and Bun skip it by default, and `--ignore-scripts` skips it everywhere. So a second path, A's command, is needed anyway. Install scripts are also a supply-chain warning sign |
| C the user installs the runtime with pip or conda, and the package finds it | `pip install mojo-compiler==<pin>`, then `npm install` | no download code of ours | Node has no `sys.path`. Finding the runtime needs either a search or a setting, and a setting would be an environment variable (rule S2) or an option on every session |
| D the platform packages carry the three libraries | `npm install` | one step, and it works offline | breaks the ruling that no package carries the runtime. `NOTICE` records the libraries as Modular's and outside this repository's Apache grant. Their licence is `LicenseRef-MAX-Platform-Software-License`, and whether komira may carry them is unruled ([mojo_runtime_pypi_vs_conda.md](mojo_runtime_pypi_vs_conda.md)) |

Recommendation: **A**, and D if the owner rules that komira may carry the libraries. A's command and its
error message are the only things a user learns.

### D3. The public API of the first release

The names and behaviour of §2:
- asynchronous calls, with a native thread per session;
- the default session per environment;
- `apache-arrow` as a required peer dependency at `^21.2.0`;
- ESM only, on Node 22.12 and later;
- paths resolved as Node's `fs` resolves them, with no `~`;
- `registerCsv` and `registerNdjson` as the names for CSV and NDJSON;
- no cancel until libkomira has one.

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

- The packages carry `libkomira`, its native owners, the addon, the licence files and the compiled
  JavaScript, and no file of Modular's runtime distribution. Under D2 option D they carry the three
  libraries only.
- No public behaviour is configured by an environment variable.
- The public names are exactly the list `exports_test` holds.
- Each platform package's native files are the bytes its install test ran.
- A query answers what DuckDB answers for the same SQL, or is refused by name.
- The package adds no libkomira call. Node reaches the engine only through the calls Python uses.

## What are the limits and open questions?

- The runtime route (D2) is open. Its download is the one network use of the package. Whether
  `libkomira` loads against the PyPI runtime's libraries has not been run (both routes need it).
- Tests in `.ts` run with type stripping on the pinned 24, and on a Node 22 pin only from 22.18,
  so the Node 22 pin is 22.18 or later.
- linux-arm64 waits for its build platform, and macos-arm64 for `libkomira`'s macOS build and
  load. The Mach-O checks of komira-ai/komira#2116 are a step toward the macOS build. Both platforms
  also need a Node pin of their own.
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
6. the package rule and the release set;
7. the runtime route;
8. the macOS and linux-arm64 builds;
9. the install tests;
10. `npm.yml`;
11. the SQL conformance runner.

The change that first ships the addon also updates
[third_party/node/README.md](../../third_party/node/README.md) ("Never shipped") and its
visibility lists. The headers become a build input of a published package, while the `node`
runtime itself stays test-only.

The Excel SDK and the `ts_polars` builder follow, on a shared plan encoder.

## Where is the code?

Today: [node/](../../node/README.md), [tools/build/node](../../tools/build/node/README.md),
[third_party/node](../../third_party/node/README.md), [src/so](../../src/so/README.md). Later: `node/src/`
for the TypeScript, `tools/build/package/` for `npm_tarball`, `release/` for the npm set, and
`.github/workflows/npm.yml`.
