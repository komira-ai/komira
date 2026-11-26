# node: the Node.js package and its addon over libkomira

Two layers, the package over the addon:

- **The TypeScript package** `@komira-ai/komira` ([below](#the-typescript-package)): the public names a
  user imports, the loader that finds libkomira in the platform package npm installs beside it, and
  the errors. It is part 3 of [docs/design/typescript_package.md](../docs/design/typescript_package.md).
- **The addon**: a Node-API addon in C ([`komira_addon.c`](komira_addon.c)) that gives Node the calls of
  `libkomira`, komira's one shared library with a flat C ABI ([`src/so`](../src/so/README.md)). It is
  built by `node_addon` ([`tools/build/node`](../tools/build/node/README.md)) with the pinned zig
  against the headers of the pinned Node. The package's modules are the only callers it is written
  for; its error codes stay inside them.

Both are tested with the pinned Node's own runner (`node_binding_test`). Nothing here is published:
the package is `"private": true`, and Node.js is test-only in this repository
([third_party/node](../third_party/node/README.md)).

## The TypeScript package

ESM only, for Node 22.12 and later (which loads an ES module through `require`, so CommonJS users
need no second build), with `apache-arrow ^21.2.0` as its peer dependency. The name
`@komira-ai/komira` is a placeholder until the npm name is decided (the design's D1 and D4).

| file | holds |
|---|---|
| [`package.json`](package.json) | the manifest npm reads: `exports` and `types` point at `dist/`, `engines`, the peer dependency, and the platform packages as optional dependencies at the package's own version. No `bin`, no scripts, no dependency of its own. Its `version` is a placeholder the package rule will stamp |
| [`src/index.ts`](src/index.ts) | the one entry, and the public names: `Session`, `registerParquet`, `abiVersion`, `version`, `KomiraError`, `LibraryLoadError`, `UnsupportedCpuError`, `UnsupportedOperation`, and the types `SessionOptions`, `CsvOptions`, `FilePath`, `KomiraErrorFields`, `Step` |
| [`src/session.ts`](src/session.ts) | `Session`: `registerParquet(name, path)` (a path or a `file:` URL, a relative one resolved against the working directory when called), `registerCsv` and `registerNdjson` (their arguments checked, then refused with `UnsupportedOperation`: this package does not yet bind the call that registers those formats by name), `close()`, `closed`, `Symbol.dispose` and `Symbol.asyncDispose`; the options `threads` and `memoryLimit`, checked and refused by name until this package binds the call that sets them. The default session of the module-level `registerParquet`, one per JavaScript environment |
| [`src/errors.ts`](src/errors.ts) | `KomiraError` (`status`, `code`, `step`, each `null` unless the engine gave one) and its subclasses |
| [`src/platform.ts`](src/platform.ts) | the platform package's name for the host, and its directory, found with `require.resolve` |
| [`src/cpu.ts`](src/cpu.ts) | which libkomira file of the native directory this CPU opens: the `VARIANTS` selector, or the x86-64-v3 check of a single library |
| [`src/native.ts`](src/native.ts) | the load, once per JavaScript environment, and the conversion of the addon's errors |
| [`src/version.ts`](src/version.ts) | `version`, read from the package's own `package.json` |
| [`tsconfig.json`](tsconfig.json), [`tsconfig.build.json`](tsconfig.build.json) | `strict` over the sources and tests (`:typecheck`); the build of `dist/`, a `.js` and a `.d.ts` per source (`:dist`) |
| [`devtools/`](devtools/README.md) | the pinned TypeScript compiler and Node.js types the two targets run |

Every call that takes a table returns a promise, and every error, an argument's included, is its
rejection. The addon runs each session's library calls in order on a native thread of the
session's own ([below](#the-session-thread)), so the event loop never waits on the engine. `close()`
is synchronous: it refuses later calls at once, and the context is freed after the calls already
made have run; `await using` (`Symbol.asyncDispose`) settles once it is freed. A wrong argument type
is a `TypeError` and a wrong value a `RangeError`, both before the library is called.

### How it finds libkomira

Importing the package loads nothing. The first `Session`, `registerParquet` or `abiVersion` of a
JavaScript environment:

1. names the platform package from `process.platform`, `process.arch` and whether Node runs on glibc
   (`@komira-ai/komira-linux-x64-gnu`, `-linux-arm64-gnu`, `-darwin-arm64`), and finds it with
   `require.resolve('<name>/package.json')` from the package itself. A host with no package, a
   package that is not installed (npm's `--omit=optional`) and one that cannot be resolved are each a
   `LibraryLoadError` that says which and what to do;
2. picks the libkomira file of the package's `native/` directory, the self-contained directory of
   `//src/so:libkomira[dist]`, before opening anything: with a `VARIANTS` manifest, the highest CPU
   level whose features every processor of `/proc/cpuinfo` lists
   ([docs/design/isa_variants.md](../docs/design/isa_variants.md), decision 5); without one, its
   single `libkomira.so` (`libkomira.dylib` on macOS) after the x86-64-v3 check on Linux x64. The
   rules, messages aside, are the Python loader's, held to the same fixtures;
3. opens the package's `komira_addon.node`, and with it that file, which checks the ABI major version
   and the functions the addon resolves.

Every refusal is a `LibraryLoadError` (an `UnsupportedCpuError` for the CPU) naming the file, and
leaves nothing loaded. No environment variable, no search of the working directory and no global
path is read. A worker thread loads the same library again through the process-wide addon, and has
its own default session.

## The calls

| call | does |
|---|---|
| `load(path)` | opens `libkomira` from `path` with `dlopen`, requires `komira_abi_version()` to have major 1, and resolves the functions below. A second `load` of the same path does nothing; of another path is an error |
| `abiVersion()` | `komira_abi_version()`: `major * 1000 + minor`, 1009 for ABI 1.9 |
| `newSession()` | `komira_ctx_new()`, as an N-API external (a handle that is not a number or an object) |
| `freeSession(session)` | `komira_ctx_free()`, after the calls made before it (below). A Promise of `undefined`. Idempotent: a later call settles with the first |
| `registerParquet(session, name, path)` | `komira_register_parquet`. A Promise of `undefined` |
| `parquetSchema(session, path)` | `komira_parquet_schema`: a Promise of a `Buffer` of the file's schema as `komira.plan.v1` `WireSchema` bytes (a protobuf message, not an Arrow IPC stream), through the two-call protocol inside the addon |
| `planRender(session, plan)` | `komira_plan_render`: a Promise of the text of a serialized plan (a `Uint8Array`, a `Buffer` included; its bytes are copied when the call is made), as a string. The plan is not run |
| `sessionStats()` | `{ created, freed }`: how many contexts the addon made and destroyed, for the tests of the session's lifetime |
| `importArrowStream(capsule)` | a promise of a result: the Arrow C stream in `capsule` drained (below). It needs no library loaded |
| `arrowSchema(result)` | the stream's schema, described |
| `arrowNextBatch(result)` | the next batch, described, or `null` after the last |
| `arrowClose(result)` | releases the schema and the batches not read yet. Idempotent |

Everything else in the C ABI (`komira_last_error` is used by the addon itself;
`komira_csv_binding` and `komira_json_binding` have no call yet) and every
call that would run a query is outside this addon.

## The Arrow import

`apache-arrow` has no importer for the Arrow C Data Interface, so the addon
reads an Arrow C stream itself ([`arrow_import.c`](arrow_import.c)) and a
private TypeScript module ([`src/arrow_import.mts`](src/arrow_import.mts)) builds
`apache-arrow` data over the stream's own memory
([design](../docs/design/typescript_package.md#arrow-from-the-c-stream-to-javascript)).

- **The stream** arrives as a capsule: an N-API external tagged as an Arrow C
  stream ([`arrow_c.h`](arrow_c.h)), the Node form of Python's
  `arrow_array_stream` PyCapsule. `importArrowStream` moves the stream out of
  it, calls `get_schema` once and `get_next` until the end, keeps every
  `ArrowArray`, and calls the stream's `release`. A non-zero callback status
  rejects with `get_last_error`'s text, after everything taken so far is
  released. The run call that will hand the addon a stream of a query
  (`komira_sql_stream`) is not bound yet; the tests make streams with a
  stand-in producer.
- **The descriptions.** A schema is `{ format, name, flags, metadata, children,
  dictionary }`, the metadata as `[key, value]` pairs or `null`. A batch is
  `{ length, nullCount, offset, buffers, children, dictionary }`. Each buffer is
  an `ArrayBuffer` of the length its format and the array give (the C structs
  carry no lengths), `null` for an absent validity bitmap. At an 8-byte aligned
  address it is an external `ArrayBuffer` over the array's memory; at another
  address it is a copy, since a typed array needs its element alignment.
- **Ownership.** A batch `arrowNextBatch` hands out is released when the last
  external `ArrayBuffer` over it is collected (a count per batch), or at once
  when it has none. The schema and the batches never read are released by
  `arrowClose`, or by the result's finalizer if it is never called. Each struct
  is released once.
- **The types** are the exporter's set ([`src/arrow_ipc`](../src/arrow_ipc/README.md)):
  every integer and float width, bool, date32 and date64, timestamps of every
  unit, decimal128 and decimal256, time, duration and interval, utf8, binary and
  their large forms, dictionaries with an integer index of up to 32 bits (64-bit
  indices are refused: apache-arrow 21.2.0 cannot read them), list, struct, map, and
  sparse and dense unions. `readArrowStream(addon, capsule)` returns an
  `apache-arrow` `Table`, and refuses any other format from the schema, before
  it reads a batch, with `UnsupportedOperation`
  (`column "<name>": Arrow format "<format>" is not supported`, a nested column
  named by its path, `outer.inner`).

[`package.json`](package.json) is private and names `apache-arrow` as a peer
dependency at `^21.2.0`, the range the tests run: they use the pinned 21.2.0
([third_party/node](../third_party/node/README.md)). The Arrow import's files are
`.mts` with only erasable syntax, so the pinned node runs them by stripping
their types; `:typecheck` does not cover them yet, since they import
`apache-arrow`, which `devtools/` does not hold.

## Why `dlopen` at `load`, not a NEEDED dependency

`libkomira` is a Mojo shared library: it needs the Mojo runtime and its native
owners beside it in `lib/` (its run path is `$ORIGIN/lib`). The build offers it
as a directory, `//src/so:libkomira[runnable]` (the gated library with
`lib/` beside it), and Buck2 has no edge that links a C target against a
`mojo_shared_lib` yet. A NEEDED entry with an rpath would also fix the
library's place when the addon is built, and a wrong or missing library would
be a loader error before JavaScript runs. With `dlopen` the host gives the
path, the addon checks the ABI major version and names a missing symbol, and
every failure is a JavaScript `Error`. The library is never `dlclose`d: the
Mojo runtime does not support being unloaded, and a session finalizer may run
late.

## The session thread

Each session owns one native thread, started by its first call. A call on a
session checks its arguments, queues itself and returns a Promise; the thread
runs the session's calls one at a time in the order they were made, and a
thread-safe function settles each Promise on the JavaScript thread. So a
context is used by one thread at a time (the ABI's rule), the event loop
never waits on the library, and two sessions run at once. The thread-safe
function is referenced only while a call is pending: a pending call keeps the
process (or the worker) alive, an idle session does not. There is no cancel:
libkomira has no cancel call.

`freeSession` refuses new calls on the session at once (`KOMIRA_SESSION_FREED`)
and queues the destruction of the context behind the calls already made, so a
context is never destroyed under a running call; the calls made before it
still run and settle, then its Promise settles. A session that made no call is
destroyed before `freeSession` returns.

## Errors

A call whose status is not zero rejects with an `Error` with `status` (the number),
`code` (`KOMIRA_ERR_ENGINE`, ...) and `lastError` (the session's last error text,
read with the two-call protocol); the message is
`<function> failed (status N): <lastError>`. Misuse of the addon itself throws,
synchronously and before anything is queued, with a `code` and no `status`: a `TypeError` `KOMIRA_ARG` for an argument of the
wrong kind (a path with a NUL byte included), `KOMIRA_SESSION_FREED`,
`KOMIRA_NOT_LOADED`, and from `load` `KOMIRA_LOAD_FAILED` (the loader's
message), `KOMIRA_ABI_MISMATCH` (with the library's version),
`KOMIRA_MISSING_SYMBOL` (with the name) and `KOMIRA_LOADED`.

The Arrow import rejects a failed stream callback with `code`
`KOMIRA_ARROW_STREAM`, `status` (the callback's status, an errno value),
`lastError` (`get_last_error`'s text, empty when there is none) and the message
`get_schema failed (status N): <lastError>` (or `get_next`). A stream or an
array that breaks the C Data Interface is `KOMIRA_ARROW_INVALID`, naming the
column (`column "a.b": buffer 1 is NULL`, `the batch: ...` for the batch itself).
A closed result is `KOMIRA_ARROW_CLOSED`. A value that is not a capsule or a
result, and a capsule imported before, are `TypeError`s `KOMIRA_ARG`.

## The session

A session is an external over a heap box that holds the context handle and its
thread's queue. The external is tagged, so a value another addon made is
refused. Each pending call holds a reference to the external, so a session is
finalized only when no call is pending. Its finalizer stops and joins the
session's thread and destroys the context if `freeSession` has not, so a
context is destroyed once. When an environment is torn down (a worker that is
terminated, the process at exit) while a call runs, the teardown waits for the
call to return, then destroys the context.

## Tests

`:package_test` runs the package's behaviour tests, [`tests/*.test.ts`](tests/), with node stripping
their types; each file is its own process. Its covered sources are `src/*.ts`: every one must be
loaded and their lines and branches together must each be at least 99% covered, or the target fails.
It stages the platform package as npm lays it out (`node_modules/@komira-ai/komira-linux-x64-gnu/`
with the addon and `//src/so:libkomira[dist]` as `native/`), the compiled `dist/`, the stand-ins below,
and the CPU-level fixtures and table of choices of the Python selector
([python/tests/fixtures/isa_variants](../python/tests/fixtures/isa_variants/README.md)). Every test
that loads plants its host, so no real `/proc/cpuinfo` is read.

| file | what it proves |
|---|---|
| [`exports.test.ts`](tests/exports.test.ts) | the public names exactly, in the sources, in `dist/`, by the package's name through its `exports` map, and from CommonJS's `require`; importing opens no addon; `dist/` holds a `.js` and a `.d.ts` per source and imports `.js` siblings; `version` is the manifest's; the manifest's type, engines, peer, exports, files, optional platform packages at the package's version, and no bin, scripts or dependency |
| [`errors.test.ts`](tests/errors.test.ts) | the class tree and names; `status`, `code` and `step` default to null; a failed C call keeps its status and code and takes the engine's text as its message (the addon's when there is none); an unknown status has no code; the addon refusing its own use, and a thrown non-Error, have no status |
| [`platform.test.ts`](tests/platform.test.ts) | the package name of each release platform; a host with none (no glibc, riscv64, darwin x64, win32) refused by name; an installed package found, the staged one by default; one not installed, and one whose `exports` hides its `package.json`, refused with their messages; the default host |
| [`cpu.test.ts`](tests/cpu.test.ts) | features are a whole word on the key's own lines that every processor lists; the x86-64-v3 check passes v3 and v4, refuses westmere and core2 and a second processor without `movbe` naming the missing flags in order, refuses an unreadable cpuinfo, and reads nothing off Linux x64; a directory without a manifest is its single library |
| [`variants.test.ts`](tests/variants.test.ts) | the selector on the Python selector's table of choices, the fallbacks of one missing feature, one processor, `vmx flags` and a partial word, arm64's `Features`, the manifest read as written, a relative directory, no cpuinfo read for a manifest without features, and each refusal (unreadable cpuinfo, a host without a feature key, a missing, non-UTF-8, empty or malformed manifest, a path outside the directory, a missing or directory variant file with no lower level loaded, a `VARIANTS` that is a directory or a broken link) |
| [`load.test.ts`](tests/load.test.ts) | a host with no package and a CPU below x86-64-v3 refused before any addon is opened; a missing addon, one that is not ELF, a directory without libkomira and a library of ABI 2.0 each refused with the loader's or the addon's words; the v3 file of a variants directory loaded rather than its floor (an ABI 2.0 stand-in); the same directory again is the same library with no CPU read, and another is refused |
| [`session.test.ts`](tests/session.test.ts) | against a stand-in whose `komira_register_parquet` fails: the engine's status, code and text; every wrong argument and option a `TypeError` or `RangeError` before the library is called; the two options and the CSV and NDJSON registrations refused by name; close frees once and a closed session refuses each call; a call made before `close` still runs and settles while later calls are refused at once, and `await using` settles after its session's call and free; `using`, `await using` and both dispose symbols close |
| [`register_args.test.ts`](tests/register_args.test.ts) | against a stand-in whose refusal is the name and path `komira_register_parquet` received: each call passes its own table name unchanged; a string path as given, a `file:` URL as its decoded path, a relative path resolved against the working directory at the call (two directories, `..`, and `~` not expanded); the module-level call through the default session |
| [`unknown_status.test.ts`](tests/unknown_status.test.ts) | a status libkomira does not define rejects with that number, no code and the addon's message |
| [`package.test.ts`](tests/package.test.ts) | the real library loads from the staged platform package's `native/` with the planted host; the real engine opens the Parquet file by path, URL and relative path against the working directory at the call, and again under one name; a missing file is status -3 `KOMIRA_ERR_ENGINE` with the engine's text, and the session still works; the module-level call makes one default session and never closes it |
| [`default_session.test.ts`](tests/default_session.test.ts) | a worker thread makes a default session of its own, once for two calls, and the main thread's is untouched |

The addon's own tests:

| target | what it proves | the defect it catches |
|---|---|---|
| `:load_test` ([`load.test.mjs`](load.test.mjs), [`capacity.test.mjs`](capacity.test.mjs)) | the addon exposes exactly the twelve calls; calls before `load` say not loaded; `load` refuses a non-string, a NUL byte, a missing file (with the loader's message), a library of ABI 2.0 and one of 0.999 (stand-ins built from [`tests/fake_libkomira.c`](tests/fake_libkomira.c)) and one without `komira_plan_render`, and each refusal leaves the addon unloaded; the real library loads, reports 1009, loads again as a no-op, and another path is then refused; with a stand-in that writes into each result the capacity it was given and the length it reported, `parquetSchema` and `planRender` pass exactly the reported length as the second call's capacity | an ABI check that is missing or accepts a higher major version, a missing symbol that is not named, a refused library that stays half-loaded, a second path ignored, a second call with more room than the reported length |
| `:session_test` ([`session.test.mjs`](session.test.mjs)) | the version; a missing file rejects with an `Error` with status -3, code, `lastError` and the message ending in it; a good call on the same session after a refusal; `parquetSchema` of the fixture ([`src/so`](../src/so/tests/fixtures/two_columns.parquet)) is a `Buffer` equal to the bytes the C ABI returns (frozen as hex), twice; `planRender` of the scan plan the C gates render, from a `Buffer` and from a view with an offset; bytes that are not a plan (and an empty array) are status -3 with a last error; arguments of the wrong kind, another addon's external and a NUL byte are `TypeError`s without a status; `freeSession` twice calls `komira_ctx_free` once and a freed session is refused; five sessions never freed are each freed once by their finalizers, and five freed by `freeSession` are not freed again by theirs; a session whose calls ran on its thread and that is never freed is freed once by its finalizer | an error without its status or last error; a truncated or empty result; an offset ignored; a double free; no finalizer; a finalizer that frees again; a foreign external read as a session; a finalizer that never frees a session that made calls, or frees it twice |
| `:thread_test` ([`thread.test.mjs`](thread.test.mjs)) | over a stand-in ([`tests/fake_latch.c`](tests/fake_latch.c)) that journals each call with its context and thread, holds a call at a gate until the test opens it (through the test addon [`tests/fake_control.c`](tests/fake_control.c)), and refuses a call on the JavaScript thread, two at once on one context and one from a second thread: four calls on one session run one at a time, in call order, on one thread that is not the JavaScript thread, and settle in that order, a failure among them included; a call after a failed one succeeds; a call on a second session settles while the first session's call is held, on another thread; `freeSession` while a call is held refuses later calls at once, frees nothing until the held call and the call queued behind it have run, settles after them (a second `freeSession` with it, a third at once) and frees once; `freeSession` of a session that made no call frees it on the JavaScript thread before it returns; a plan changed after its call was queued, and an empty plan, are rendered as they were when the call was made; a session dropped while its call is held is not finalized through 50 collections, and after the call settles is freed once, on the JavaScript thread; in a worker thread, a session runs on a thread of its own, its held call keeps the worker alive until its result is posted, and the worker then exits by itself with the session freed once; a worker terminated while its call is held exits and frees the context once | calls run on the JavaScript thread; two calls at once on one context; calls out of order; sessions that share a thread; a context freed under a running call or before a queued one; a second `freeSession` that settles before the free; a plan read after the caller changed it; a session finalized while its call is pending; a pending call that does not keep a worker alive; a session that keeps an idle worker alive or is not freed at the worker's exit |
| `:arrow_test` ([`arrow_stream.test.mts`](arrow_stream.test.mts), [`arrow_import.test.mts`](arrow_import.test.mts)) | over streams of a stand-in producer ([`tests/arrow_stand_in.c`](tests/arrow_stand_in.c), an addon that builds a stream from a description and counts the releases of each stream's structs): the import releases the stream at once and holds the schema and batches; the schema and each batch are described exactly, every buffer at its exact length; a batch is released once, and not while its buffers are alive; a misaligned buffer is copied, and a batch of copies only is released when it is read; `get_schema` and `get_next` failures reject with the status and the last error (or the status alone), with everything released once; a released schema, a schema that is not a struct, eleven malformed arrays, a value that is not a capsule or a result, a capsule imported twice and a closed result are refused by name; a result never closed is released by its finalizer. Through `readArrowStream`: every integer and float width, bool, dates, times, timestamps, durations, intervals, decimal128 and decimal256, utf8 and binary and their large forms, a dictionary whose memory two batches share, list, struct, map and both unions round-trip equal, with nulls; offsets in every kind of column and in the batch; names, nullability and metadata; an empty stream and a batch of NULL buffers; eleven formats the mapping does not know are refused with `UnsupportedOperation` by their full message, everything released; the pinned `apache-arrow` satisfies the peer range | a buffer of the wrong length or slot; an offset ignored, or not carried into a struct's children; a batch released early, twice or never; a misaligned typed array; a callback error lost or without its text; a column read as another type; a dictionary id or union type id mixed up |

The frozen schema bytes are what `libkomira` returned when the test was
written, checked by reading them: a protobuf message of two fields, `i64` and
`s`. The finalizer tests collect garbage with `gc()` (from
`v8.setFlagsFromString('--expose-gc')`) for a bounded number of rounds, and
count with `sessionStats()`, so they read no clock.
