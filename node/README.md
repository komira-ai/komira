# node: the Node addon over libkomira

A Node-API addon in C ([`komira_addon.c`](komira_addon.c)) that gives Node the
calls of `libkomira`, komira's one shared library with a flat C ABI
([`src/komira_so`](../src/komira_so/README.md)). It is built by `node_addon`
([`tools/build/node`](../tools/build/node/README.md)) with the pinned zig against
the headers of the pinned Node, and it is tested with the pinned Node's own
runner (`node_binding_test`). Nothing here is shipped yet: Node.js is test-only
in this repository ([third_party/node](../third_party/node/README.md)).

## The calls

| call | does |
|---|---|
| `load(path)` | opens `libkomira` from `path` with `dlopen`, requires `komira_abi_version()` to have major 1, and resolves the functions below. A second `load` of the same path does nothing; of another path is an error |
| `abiVersion()` | `komira_abi_version()`: `major * 1000 + minor`, 1001 for ABI 1.1 |
| `newSession()` | `komira_ctx_new()`, as an N-API external (a handle that is not a number or an object) |
| `freeSession(session)` | `komira_ctx_free()`. Idempotent: the second call does nothing |
| `registerParquet(session, name, path)` | `komira_register_parquet` |
| `parquetSchema(session, path)` | `komira_parquet_schema`: a `Buffer` of the file's schema as `komira.plan.v1` `WireSchema` bytes (a protobuf message, not an Arrow IPC stream), through the two-call protocol inside the addon |
| `planRender(session, plan)` | `komira_plan_render`: the text of a serialized plan (a `Uint8Array`, a `Buffer` included), as a string. The plan is not run |
| `sessionStats()` | `{ created, freed }`: how many contexts the addon made and destroyed, for the tests of the session's lifetime |

Everything else in the C ABI (`komira_last_error` is used by the addon itself;
`komira_csv_binding` and `komira_json_binding` have no call yet) and every
call that would run a query is outside this addon.

## Why `dlopen` at `load`, not a NEEDED dependency

`libkomira` is a Mojo shared library: it needs the Mojo runtime and its native
owners beside it in `lib/` (its run path is `$ORIGIN/lib`). The build offers it
as a directory, `//src/komira_so:libkomira[runnable]` (the gated library with
`lib/` beside it), and Buck2 has no edge that links a C target against a
`mojo_shared_lib` yet. A NEEDED entry with an rpath would also fix the
library's place when the addon is built, and a wrong or missing library would
be a loader error before JavaScript runs. With `dlopen` the host gives the
path, the addon checks the ABI major version and names a missing symbol, and
every failure is a JavaScript `Error`. The library is never `dlclose`d: the
Mojo runtime does not support being unloaded, and a session finalizer may run
late.

## Errors

A call whose status is not zero throws an `Error` with `status` (the number),
`code` (`KOMIRA_ERR_ENGINE`, ...) and `lastError` (the session's last error text,
read with the two-call protocol); the message is
`<function> failed (status N): <lastError>`. Misuse of the addon itself throws
with a `code` and no `status`: a `TypeError` `KOMIRA_ARG` for an argument of the
wrong kind (a path with a NUL byte included), `KOMIRA_SESSION_FREED`,
`KOMIRA_NOT_LOADED`, and from `load` `KOMIRA_LOAD_FAILED` (the loader's
message), `KOMIRA_ABI_MISMATCH` (with the library's version),
`KOMIRA_MISSING_SYMBOL` (with the name) and `KOMIRA_LOADED`.

## The session

A session is an external over a heap box that holds the context handle. The
external is tagged, so a value another addon made is refused. Its finalizer
destroys the context if `freeSession` has not, so a context is destroyed once.

## Tests

| target | what it proves | the defect it catches |
|---|---|---|
| `:load_test` ([`load.test.mjs`](load.test.mjs), [`capacity.test.mjs`](capacity.test.mjs)) | the addon exposes exactly the eight calls; calls before `load` say not loaded; `load` refuses a non-string, a NUL byte, a missing file (with the loader's message), a library of ABI 2.0 and one of 0.999 (stand-ins built from [`tests/fake_libkomira.c`](tests/fake_libkomira.c)) and one without `komira_plan_render`, and each refusal leaves the addon unloaded; the real library loads, reports 1001, loads again as a no-op, and another path is then refused; with a stand-in that writes into each result the capacity it was given and the length it reported, `parquetSchema` and `planRender` pass exactly the reported length as the second call's capacity | an ABI check that is missing or accepts a higher major version, a missing symbol that is not named, a refused library that stays half-loaded, a second path ignored, a second call with more room than the reported length |
| `:session_test` ([`session.test.mjs`](session.test.mjs)) | the version; a missing file is an `Error` with status -3, code, `lastError` and the message ending in it; a good call on the same session after a refusal; `parquetSchema` of the fixture ([`src/komira_so`](../src/komira_so/tests/fixtures/two_columns.parquet)) is a `Buffer` equal to the bytes the C ABI returns (frozen as hex), twice; `planRender` of the scan plan the C gates render, from a `Buffer` and from a view with an offset; bytes that are not a plan (and an empty array) are status -3 with a last error; arguments of the wrong kind, another addon's external and a NUL byte are `TypeError`s without a status; `freeSession` twice calls `komira_ctx_free` once and a freed session is refused; five sessions never freed are each freed once by their finalizers, and five freed by `freeSession` are not freed again by theirs | an error without its status or last error; a truncated or empty result; an offset ignored; a double free; no finalizer; a finalizer that frees again; a foreign external read as a session |

The frozen schema bytes are what `libkomira` returned when the test was
written, checked by reading them: a protobuf message of two fields, `i64` and
`s`. The finalizer tests collect garbage with `gc()` (from
`v8.setFlagsFromString('--expose-gc')`) for a bounded number of rounds, and
count with `sessionStats()`, so they read no clock.
