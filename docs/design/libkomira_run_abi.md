# Design: the libkomira calls that run a query (C ABI 1.2 and after)

Status: design, not built. **EXISTS** names code on `main`; **PROPOSED** is new.
Statements the author deduced rather than read are marked *(inferred)*.

`libkomira` is komira's one shared library and its flat C ABI
([src/so](../../src/so/README.md)). ABI 1.1 registers and describes sources and
renders a plan. None of its calls runs a query. This doc decides the calls that
do: run SQL text, run a serialized plan, hand the result out as an Arrow C
stream, set session options, and, later, cancel, progress and credentials. It
also decides what happens at the boundary when the engine fails or aborts. The
Python package (`pip install komira`) and the Node addon are the first two
callers. Both are thin bindings over these calls.

## 1. Decision summary

| item | decision |
|---|---|
| run SQL | `komira_sql_stream(ctx, sql, out)`, ABI 1.2 |
| run a plan | `komira_plan_stream(ctx, plan, plan_len, out)`, ABI 1.2. The bytes are an authored `WirePlanEnvelope`, the same input `komira_plan_render` takes. libkomira optimizes it in-process |
| result | an Arrow C stream, `struct ArrowArrayStream`, that the caller allocates and libkomira fills. The caller owns it after `KOMIRA_OK`. It does not depend on the context, which may be freed first |
| status codes | 1.2 adds none. Every engine refusal stays `KOMIRA_ERR_ENGINE` (-3), with the reason in the last error. The cancel minor adds `KOMIRA_ERR_CANCELLED` (-6) |
| session options | typed setters, accepted until the session's engine is built: `komira_set_worker_count`, `komira_set_memory_budget`. Target 1.3. No options struct crosses the ABI, and nothing is read from the environment |
| cancel, progress | `komira_cancel(ctx)` and `komira_progress(ctx, ...)`. These two calls are the exception to the one-thread rule: another thread may call them while a run is in flight. Target 1.4 |
| credentials | settled by their own design. The constraints are in §7. No row is reserved |
| aborts | every raise becomes a status, and nothing raises across the boundary. Known abort sites on the run path are turned into raises, or refused before the run. Anything left is fail-fast: it ends the process. No signal handler is installed and no `longjmp` is used. An out-of-process engine stays possible behind the same calls |
| not carried | Python UDF registration by code pointer, the Excel (`xl_*`) calls, IPC-bytes output, SQL render, and the prototype's text error codes (§9) |

The minor versions above are targets. A row's `since` is the version of the first
change that lands it on `main`, because releases come from `main` automatically. If
the 1.2 change lands only `komira_sql_stream`, then `komira_plan_stream` takes the
next minor. The golden (`src/so/abi/komira.tsv`) holds whichever version is true.

**Who calls which entry.** The Python package ports the settled shape of the
earlier SDK. It has two DataFrame surfaces: one shaped like a pandas
`DataFrame` and one shaped like the polars module. It also has a plan builder
over the plan protobuf, and a SQL call.

- **The DataFrame surfaces.** Both build a logical plan, serialize it as a
  `WirePlanEnvelope`, and submit it through `komira_plan_stream`. A frame is
  never rendered to SQL text.
- **SQL text.** It goes through its own entry, `komira_sql_stream`, where
  libkomira parses and binds it into a logical plan.
- **The shared route.** From the optimizer down, both entries run the same
  route in `sdk_exec` (§3).

The port differs from the earlier SDK in these places, each for the reason
given:

- **No switch that sends frames as SQL.** The earlier SDK had one, both as an
  environment variable and as a session argument. Neither is carried. A frame
  always travels as a plan, and configuration is never read from the
  environment (rule S2).
- **Python UDFs.** The earlier SDK reached them only through SQL text, as
  in-process callbacks. Rule B21 requires Python UDFs to run in zygote-forked
  workers, so neither entry carries them until that design lands. The plan door
  refuses an envelope with UDFs by name (§3).
- **One engine per session.** The earlier SDK built a fresh engine context for
  every call. Here the session keeps one `EngineContext` (§5).
- **The SQL entry is not scaffolding.** It is an entry of its own, beside the
  plan door, for users who write SQL (§9).

## 2. What exists today

- **EXISTS** ABI 1.1: nine exports, six status codes and `KOMIRA_MAX_INPUT_BYTES`
  (64 MiB) in [komira.tsv](../../src/so/abi/komira.tsv). There is the two-call
  output protocol and a last error per context. Each call that works on the
  context (register, schema, binding, render) clears the last error when it
  starts. `komira_last_error` does not clear it. An export catches a raise and returns `KOMIRA_ERR_ENGINE`
  (`src/so/_c_abi.mojo`). The `Session` behind a handle holds the last error and
  a `SqlCatalog`. It has no engine.
- **EXISTS** The engine's SQL door is
  `sdk_exec.run_sql(mut ctx: EngineContext, text: String) -> SqlOutcome`
  (`src/sdk_exec/engine_sql.mojo`). It parses, binds, optimizes
  (`optimizer.optimize`), lowers and runs, and it returns the batches or a
  `SqlRefusal{step, reason}`. Its steps are parse, bind, optimize, lower and
  execute. It does not raise. The result is materialized: one segment, as
  `List[RecordBatch]`.
- **EXISTS** `EngineContext(options: EngineOptions)` with
  `worker_count: Optional[Int]` and `memory_budget_bytes: Optional[Int]`
  (`src/sdk_exec/engine_options.mojo`). A field left absent takes the host
  profile's value: the physical cores, and 70% of available memory. A value below
  1 is refused (`ENGINE_OPTIONS_INVALID`). The options are read once, when the
  context is built, and building it starts the worker runtime.
- **EXISTS** `plan_wire.plan_from_bytes` decodes an authored envelope into a
  `LogicalPlan`. The decoder refuses input above `PLAN_WIRE_MAX_BYTES` (16 MiB).
  `OptimizedPlan` is a schema in `src/plan_proto/optimized_plan.proto` with no
  codec. Its design ([optimized_plan.md](optimized_plan.md)) is not built.
- **EXISTS** The Arrow C stream exporter
  `arrow_ipc.build_record_batch_stream(batches, schema, out_stream)`
  (`src/arrow_ipc/c_data_stream.mojo`). It fills a caller-allocated
  `CArrowArrayStream` and takes ownership of the batches. The exported arrays
  share column buffers by reference count, so the arrays outlive the stream. Its
  release callbacks null `release`, and they are idempotent.
- **EXISTS** `async_api.CancellationToken`. `run_lowered_plan` passes a fresh
  token to the pipeline, but the token is local to the call, so nothing outside
  can cancel it (`src/sdk_exec/README.md`). The engine has no progress counter.
- **EXISTS** The plan conformance harness speaks its own door ABI
  (`src/tests/helpers/komira_plan_harness/door.mojo`): a `const char *`
  `komira_last_error`, a `komira_plan_stream` like the one below, and
  `komira_plan_bytes`, which returns IPC bytes.
- **EXISTS** No containment: an abort, a failed `debug_assert`, a fault, or an
  out-of-memory kill inside libkomira ends the host process.

## 3. The 1.2 rows

These are the golden rows (`symbol<TAB>return<TAB>arguments<TAB>since`) that the
change adding the calls writes. The rows of 1.1 stay byte for byte. Only rows are
added, and no type or constant changes.

```text
version	1.2
komira_sql_stream	Int32	Handle,CStr,ArrowStream	1.2
komira_plan_stream	Int32	Handle,ConstBytes,UInt64,ArrowStream	1.2
```

The C prototypes in `komira.h`:

```c
int32_t komira_sql_stream(komira_handle ctx, const char *sql,
                          struct ArrowArrayStream *out);
int32_t komira_plan_stream(komira_handle ctx, const uint8_t *plan,
                           uint64_t plan_len, struct ArrowArrayStream *out);
```

**PROPOSED, golden tool.** `ArrowStream` is a new named type in the golden's type
map. It is declared in `_c_abi.mojo` as
`comptime ArrowStream = UnsafePointer[CArrowArrayStream, ...]` and spelt
`struct ArrowArrayStream *` in the header, the way `CStr` and `ConstBytes` are
handled today. The header defines `ArrowSchema`, `ArrowArray` and
`ArrowArrayStream` exactly as the Arrow C Data and C Stream interfaces do. Each
definition sits inside the spec's own `ARROW_C_DATA_INTERFACE` and
`ARROW_C_STREAM_INTERFACE` guards, so the header can be included next to Arrow's
own. `OpaquePointer` (`void *`) was rejected for this argument because it would
lose the type in the header that every binding reads.

### Arguments and order of checks

Both calls follow the order of the 1.1 calls:

1. A NULL `ctx` returns -1, and nothing else happens.
2. The last error is cleared.
3. A NULL `sql`, `plan` or `out` returns -2, and the refusal is stored as the
   last error.
4. Length checks:
   - `plan_len` above `KOMIRA_MAX_INPUT_BYTES` returns -5 before anything is
     read.
   - For `sql`, the NUL is searched for in at most `KOMIRA_MAX_INPUT_BYTES + 1`
     bytes. A string with no NUL inside the bound returns -5.
   - The SQL text must be valid UTF-8, or the call returns -3.
5. The engine runs. A refusal returns -3, with the message as the last error.

`*out` is written only on `KOMIRA_OK`. On every other status it is left exactly as
the caller wrote it, so a binding can pre-zero it and release nothing. On
`KOMIRA_OK` every slot is written and `release` is non-NULL.

A plan between 16 MiB and 64 MiB passes the ABI bound and is refused by the
decoder (-3). The two bounds stay separate. The ABI bound protects the copy-in,
and the wire bound belongs to the plan format.

### What `komira_sql_stream` runs

It runs one SQL statement against the tables registered on the context with
`komira_register_parquet` (and the later source calls). A registration is
visible to every later run on the context. The route is
`sdk_exec.run_sql` with the session's `EngineContext`. A statement that is not
a query is refused by `run_sql` (`STATEMENT_NOT_A_QUERY`) until writes have their
own design. **PROPOSED:** the last error text is `<step>: <reason>`, with the
step that refused (parse, bind, optimize, lower or execute). That text is for people.
Bindings do not parse it (§6).

### What `komira_plan_stream` runs: the plan door

The input is an authored `komira.plan.v1.WirePlanEnvelope`. It is the same bytes
`komira_plan_render` renders, and the format the SDK's plan builders write.
`plan_from_bytes` refuses an envelope that carries a write target
(`PLAN_WIRE_WRITE_TARGET_DROPPED`) or a UDF list (`PLAN_WIRE_UDFS_DROPPED`). The
door keeps those refusals (-3) until writes and UDFs have their own design.
`plan_envelope_from_bytes` already decodes both, for the door that carries
them later. The
route is `plan_from_bytes`, then `optimize`, `lower_for_context` and
`run_lowered_plan`. This is the tail of `run_sql` after bind. **PROPOSED:**
`sdk_exec` gets one `run_plan(mut ctx, var plan: LogicalPlan) -> SqlOutcome`,
and `run_sql` calls it after binding, so SQL and plans share one route from the
optimizer down. A scan leaf carries its own binding (path, schema and
fingerprint, from `komira_parquet_schema` or the binding calls), so a plan
needs no registered table.

**The client optimizes.** libkomira is the client in an in-process session. It
optimizes once, in-process, and then lowers and runs on the same host. This is
the "program that links the engine" role of [optimized_plan.md](optimized_plan.md)
§2. A job manager is not involved, and nothing is serialized after the optimizer.
An `OptimizedPlan` is the form a client *submits* to a job manager, and it is not
an input of this door. A bare `OptimizedPlan` passed here fails the envelope
decoder by name (-3). Producing an `OptimizedPlan` for a job manager is out of
scope until its codec exists. It will be its own call, and no row is reserved
for it here.

## 4. The result: an Arrow C stream

- **Who allocates.** The caller allocates `struct ArrowArrayStream`, which is
  five pointer-sized slots, and passes its address. Every Arrow consumer expects
  this: pyarrow `RecordBatchReader._import_from_c` and the `__arrow_c_stream__`
  capsule, Arrow C++ `ImportRecordBatchReader`, and arrow-rs
  `FFI_ArrowArrayStream`. If libkomira allocated the stream, it would need a
  matching free call and a second ownership rule.
- **Who owns.** After `KOMIRA_OK` the caller owns the stream. It must call
  `release` exactly once, as the Arrow spec requires. It may move the struct by
  copying it, after which the old copy counts as released. Arrays taken from the
  stream are independent of it. Each array has its own `release`, which stays
  callable after the stream is released (the spec, and **EXISTS** in
  `build_record_batch_stream`).
- **Lifetime against the context.** The stream holds no reference to the
  `Session` or the handle. It owns its batches, and their buffers are shared
  columns. `komira_ctx_free` may run before the stream is released. Python and
  Node garbage collectors release late, so this rule spares every binding from
  ordering its finalizers. It is a requirement on the export change, not yet a
  checked fact: if any buffer a result holds is accounted to, or allocated
  from, state that `komira_ctx_free` tears down (the memory budget, the worker
  runtime), the stream holds an `ArcPointer` on that state. A C driver case frees
  the context, then reads the stream, releases it, and releases its arrays. A
  later streaming producer keeps the engine state it reads alive in the same
  way, never through the handle.
- **The library stays loaded.** The release callbacks are code in libkomira, so
  a binding never unloads the library while a stream from it may be live. Both
  bindings never `dlclose` it: the Node addon already does not, because the Mojo
  runtime does not support being unloaded.
- **Materialized first.** In 1.2 the run completes before the call returns.
  `get_next` then hands out the batches that were already computed. The memory
  budget bounds the operators but not the size of the result *(inferred from
  `run_sql` returning `List[RecordBatch]`)*. Later, `get_next` can drive the
  engine incrementally, and the calls do not change.
- **Types.** The stream carries only types the exporter supports. A result
  column outside that set is refused by the run call (-3, naming the column and
  its type) before `*out` is written. It is never left to fail inside
  `get_schema` or `get_next`. That also covers an empty result: its schema must
  export, so a type the exporter cannot export without data is refused at the
  run as well. The export task lists the supported set in
  `src/arrow_ipc/README.md`.
- **Callback errors.** The callbacks never raise. `get_schema` and `get_next`
  return 0 or an errno value: `EINVAL` on a released stream or a NULL argument,
  `EIO` on a failure, and `ECANCELED` after a cancel (§7). `get_last_error`
  returns text owned by the stream, which stays valid until the next callback
  or `release`. Errno values differ by platform, so the Mojo side takes them from
  a C shim, not from literals (rule M8).
- **Threads.** A stream is used by one consumer at a time, which is the Arrow
  rule. It can be read on a thread other than the one that ran the query.

## 5. Session options

**PROPOSED, target 1.3:**

```text
komira_set_worker_count	Int32	Handle,Int64	1.3
komira_set_memory_budget	Int32	Handle,Int64	1.3
```

- **Typed setters, one per option.** They write `EngineOptions.worker_count` and
  `memory_budget_bytes`. A context whose setter was not called keeps the host
  profile's value. A new option later is a new setter row, which is additive
  (rule B8).
- **Rejected alternatives.**
  - A C options struct: its layout would become part of the ABI, and growing it
    would need a size or version field.
  - `komira_set_option(ctx, key, value)` with strings: a stringly typed surface.
  - A constructor with arguments, `komira_ctx_new_with(...)`: it needs a new
    symbol for every new option.
  - Environment variables: rule S2.
- **The session and its engine.** These rules apply from 1.2, when the session
  gains an engine:
  - A session holds one catalog, the `EngineContext`'s. The `SqlCatalog` that the
    1.1 `Session` keeps itself goes away, so a registered table is never in two
    places.
  - The `EngineContext` is built lazily, by the first call that needs it: a
    registration (`komira_register_parquet`, later source calls) or a run.
    Building it fixes its options and starts its workers.
  - The describe calls (`komira_parquet_schema`, `komira_csv_binding`,
    `komira_json_binding`, `komira_plan_render`) do not build it.
  - If the build fails, the call returns -3 with the engine's message. The
    session stays without an engine, so a later call tries again.
- **Setters are accepted until the engine is built.** A setter may be called more
  than once, and the last value counts. After the engine is built, a setter is
  refused (-3, "options are set before the first registration or query") and
  changes nothing. A value below 1 is -3 with the engine's
  `ENGINE_OPTIONS_INVALID` message, and it changes nothing either. There is no
  upper bound, which matches `EngineOptions`.
- **Python** passes the options as keyword arguments to its session constructor.
  The constructor calls the setters right after `komira_ctx_new`, so the rule is
  met by construction.

## 6. Status codes

1.2 adds no code. The six codes of 1.1 cover the two run calls. The setter
calls (§5) use the same codes.

| code | when |
|---|---|
| 0 `KOMIRA_OK` | `*out` holds a stream |
| -1 `KOMIRA_ERR_NULL_CTX` | NULL `ctx` |
| -2 `KOMIRA_ERR_NULL_ARG` | NULL `sql`, `plan` or `out` |
| -3 `KOMIRA_ERR_ENGINE` | invalid UTF-8; a parse, bind, optimize, lower or execute refusal; an unsupported feature refused by name (rule B21); a result type the stream cannot carry; a plan the decoder refuses, including an envelope with a write target or UDFs; an engine that fails to build |
| -4 `KOMIRA_ERR_BUFFER_TOO_SMALL` | not returned by the run calls (no byte output) |
| -5 `KOMIRA_ERR_TOO_LARGE` | `plan_len`, or SQL text, above 64 MiB |

Engine refusals were not split into more codes. For a first, SQL-first release a
binding needs one exception class for "the query was refused", carrying the
text. The prototype's lesson is to avoid a code space carried inside message
text and checked by a regex (§9). If a binding needs to tell refusals apart, the
split is added then, as new negative codes. **PROPOSED:** for that to be
additive, the 1.2 change writes into the README and the header that a binding
treats any negative code it does not know as a failure. Today the README says
only that every failure is negative.

**PROPOSED, with cancel:** `KOMIRA_ERR_CANCELLED` (-6). The run returned because
`komira_cancel` was called. `*out` is untouched, and the last error says
"cancelled".

## 7. Cancel, progress, credentials

**PROPOSED, target 1.4:**

```text
komira_cancel	Int32	Handle	1.4
komira_progress	Int32	Handle,UnsafePointer[UInt64],UnsafePointer[UInt64]	1.4
```

- **Threads.**
  - A handle is not tied to a thread. Any thread may use it, but only one thread
    at a time. Python runs a query on a helper thread and takes a lock per
    session.
  - Two calls on one context at the same time are the caller's error, as in 1.1.
    The exception is these two calls: while one thread is inside
    `komira_sql_stream` or `komira_plan_stream`, another thread may call
    `komira_cancel` and `komira_progress` on the same context.
  - Streams from earlier runs are independent of the context (§4). They may be
    read while a new run starts.
  - Nobody may call anything on a context while `komira_ctx_free` runs on it.
    That is the caller's rule, as for `free(3)`.
- **The run control block.**
  - `komira_ctx_new` allocates one control block. It holds an in-flight flag, a
    cancel flag and the two progress counters, all atomic. It is never replaced.
  - The run calls, `komira_cancel` and `komira_progress` reach it only through
    atomics.
  - `komira_cancel` and `komira_progress` do not clear or write the last error,
    and they touch nothing else in the session. Only the thread that owns the
    handle reads `komira_last_error`.
  - A NULL `ctx` is -1. A NULL `done` or `total` is -2, and no last error is
    written.
- **Cancel.**
  - A run sets the in-flight flag and clears the cancel flag on entry, before its
    first check. It clears the in-flight flag on return.
  - `komira_cancel(ctx)` sets the cancel flag only if a run is in flight. It
    returns `KOMIRA_OK` either way. A cancel that arrives before a run starts, or
    between queries, does nothing, so it never cancels the next query.
  - The run passes the cancel flag to the engine as its `CancellationToken`. Today
    `run_lowered_plan` makes its own token, so it takes one instead.
  - The run checks the flag one last time just before it writes `*out`. If the
    flag is set, the run returns -6 and leaves `*out` untouched. Otherwise it
    returns `KOMIRA_OK`. Once the run has returned, cancel is a no-op.
  - If a stream is read incrementally (after 1.2), the stream keeps the run in
    flight until its `release`, so a cancel stays live while it is read. Its
    `get_next` then returns `ECANCELED`. A 1.2 stream is materialized and never
    returns `ECANCELED`.
  - Python maps `KeyboardInterrupt` to it: the query runs on a helper thread
    while the main thread waits interruptibly.
- **Progress.**
  - `komira_progress(ctx, done, total)` stores two monotonic counters for the run
    in flight: the input bytes the scans have read, and the total the plan will
    read, which is known from the footers after lowering.
  - With no run in flight it stores 0 and 0. Before lowering has finished,
    `total` is 0.
  - `UnsafePointer[UInt64]` out arguments are already in the golden's type map,
    as in `komira_last_error`.
  - A binding polls it. libkomira never calls back into the host. A callback would
    run host code (Python, JavaScript) on engine worker threads.
  - The unit is settled by the progress change. Bytes are proposed because a
    Parquet footer gives them before the run.
- **Credentials.** These are the one item deferred to their own design, with no
  row reserved here. The constraints that design starts from:
  - Explicit per-session setter calls, typed as above, under the same rule as
    the option setters. They feed the engine's existing secret model:
    `SecretCapability` and the `secret_registry` bindings in
    `src/sdk_exec/secret_capability.mojo`, held by the session.
  - The provider-standard environment (`AWS_*`, `GOOGLE_*`) is allowed, as the one
    exception rule S2 makes.
  - No endpoint is written into the code (S1).
  - Secret material never appears in `komira_last_error` text, and a test checks
    a refusal's full text by equality (rule T13).

## 8. Aborts at the boundary

A Mojo `raise` is a value, and every export catches it. An `abort()`, a failed
`debug_assert` (at the assert levels that keep them), an out-of-bounds fault,
stack exhaustion and an out-of-memory kill are not values. Mojo has no unwinding,
and nothing in the library can turn them into a status. The design contains what
can be contained, refuses what can be recognized, and states the rest.

1. **Nothing raises across the boundary.** Every export, and every stream
   callback, catches every raise and returns a status or an errno, as the 1.1
   exports do. A context stays usable after any refusal. The rule that makes
   this hold: the session's state (catalog, options, engine) changes only when a
   call succeeds, and each run starts its per-query state afresh (today
   `EngineContext.begin_query` drops the previous query's footer cache). The
   run-SQL change tests a good query on the same handle after each kind of
   refusal.
2. **Refuse before running.**
   - Input bounds, NULLs and UTF-8 are checked before anything is read.
   - The plan decoder's admission limits apply (`plan_wire_admit`: size,
     version, depth, node count).
   - Lowering refuses unsupported shapes by name (rule B21), so a query never
     reaches an operator default that aborts on a shape it was never routed. The
     aggregate defaults in `src/agg/aggregator.mojo` are an example.
   - A result type the stream cannot carry is refused at the run (§4).
3. **Turn known abort sites on the run path into raises.** The abort containment
   change enumerates every `abort(` reachable from the two run calls and either
   makes it a raise, refused at the boundary, or argues why input cannot reach
   it. Examples are the catch-and-abort patterns in `src/op_sort` and the
   variable-length payload aborts in its payload stage. It also adds a C driver
   case per reachable site, which asserts a status rather than a crash.
   - The codec libraries are among those sites. `compression`
     (`_open_or_abort`) and `zlib` open their system libraries in `_Global`
     initializers, which cannot raise. Those run lazily, at the first use of a
     codec, so a missing library aborts in the middle of a query, for example at
     the first compressed Parquet page.
   - **PROPOSED:** the session opens them through a raising probe when it builds
     its engine, so a missing library is -3 at the first registration or run.
4. **Fail-fast for the rest, and say so.** Whatever still aborts ends the host
   process. The `src/so` README and the Python package docs state this, along
   with the assert level the published library is built at.
5. **Rejected: a signal handler with `longjmp`.** Catching `SIGABRT` or `SIGSEGV`
   and jumping back to the export is unsound:
   - other engine threads are left holding locks with half-written state;
   - Mojo destructors are skipped, so memory leaks or is freed twice;
   - a library handler overrides the host's own handlers (Python's
     `faulthandler`, Node's).
   libkomira installs no signal handler at all. The async runtime's SIGTERM
   handler (`async_rt` `install_sigterm_handler`) is for servers at boot, and
   libkomira never calls it.
6. **Deferred: an out-of-process engine** (§12). Nothing in these calls rules it
   out.

## 9. What replaces the prototype's doors, and what is not carried

An earlier prototype of this library sat behind a Python package that was
never published. Its run path was a plan endpoint and a result-IPC egress. The
table names its calls only to say what each becomes.

| prototype | in libkomira |
|---|---|
| plan endpoint: one call that admitted, decoded, validated and executed a plan | `komira_plan_stream`: `plan_wire` admission and decode, then the shared `sdk_exec` route (§3). There is no separate endpoint package. It built a fresh engine context per call, and here the session's `EngineContext` is reused |
| `komira_plan_stream`, `komira_sql_stream` (Arrow C stream out) | the same names and shapes, with the 1.1 conventions (two-call `komira_last_error`, -5 bound, `*out` untouched on refusal). The SQL door is an entry of its own beside the plan door, not scaffolding. The DataFrame surfaces never use it |
| result IPC egress: Arrow IPC stream bytes, through `komira_plan_bytes` and a CLI | **not carried.** The result is the Arrow C stream, and IPC bytes are a binding's own business. The Node addon is the one caller without a C stream importer. It drains the stream in C, and how it hands batches to JavaScript is decided when it gains a run call. That may add a two-call IPC export then |
| `PLAN_ENDPOINT_<NAME>(<code>): ` prefix on the error text, parsed by a regex against a frozen code table | **not carried.** The status code is the machine-readable part, and the text is for people (§6) |
| `komira_last_error(ctx) -> const char *` | the 1.1 two-call form stays. The plan harness's door (`door.mojo`) still describes the `const char *` form. It is moved to the 1.1 form when the harness is pointed at libkomira |
| `komira_sql_render` | not in 1.2. An `EXPLAIN` surface can add it later as a two-call row |
| `komira_register_python_udf`, `komira_declare_sql_udf` | **not carried.** They took a host code pointer and ran Python on engine threads, which conflicts with rule B21: Python UDFs run in zygote-forked workers. UDF registration is designed with those workers, and it will describe a worker, not hand over a code pointer |
| `komira_register_builtin_mojo_udf` | not carried. It selected from a closed set compiled into the library |
| `komira_xl_bind`, `xl_bind_value`, `xl_bind_cell`, `xl_render`, `xl_eval`, `xl_functions`, `xl_stream` (Excel formulas) | **not carried, recommended.** The Excel libraries are not ported, and a SQL-first release does not need them. This is a scope call for the product owner. If it is reversed, the calls come back as new rows in a later minor |
| knobs read from environment variables (feature gates, library paths, the plan-wire-or-SQL switch for frames) | none. Options are setter calls (§5), and a binding finds the library from its own install location |

## 10. Versioning and bindings

- Adding a row raises the minor, and a change or removal raises the major. That
  is the 1.1 rule, unchanged. 1.2 only adds rows.
- **A binding checks the major when it loads the library, and each symbol when
  it first uses that call.** A library too old for a call fails that call with a
  named error ("libkomira 1.1 has no komira_sql_stream"). Every other call still
  works. The prototype raised its version on every symbol and refused older
  libraries outright. That is a version floor, which is the thing rule B8 rules
  out for data, so it is avoided here.
  - The Node addon already checks the major only, and it ignores symbols it does
    not bind.
  - **PROPOSED:** the Python loader (not written yet) follows the same rule, so it
    works against 1.1 and only its query calls need 1.2.
- The C driver (`src/so/tests/c/abi_driver.c`) binds every row through the
  generated header. Old and new libraries are crossed in the same way as
  `node/tests/fake_libkomira.c` does: a stand-in of the previous minor, and the
  current library under a binding that knows only the previous minor's calls.

## 11. Where the work lands

Each part below is its own change, and each adds its rows and its tests together:

1. The stream export from run results (`arrow_ipc`, the supported type set).
2. libkomira links `sdk_exec`. The session gets a lazy `EngineContext` and one
   catalog (§5).
3. `komira_sql_stream` and `komira_plan_stream` with the `ArrowStream` golden
   type, gate drivers, the C driver, and the 1.2 rows (§3).
4. Session setters (§5).
5. Abort containment (§8, items 3 and 4).
6. Cancel and progress (§7).
7. Credentials, by their own design.

## 12. Options considered

- **Run calls that return IPC bytes through the two-call protocol** (the
  prototype's second door): this runs the query twice, or parks the result on
  the session between the probe and the fill. It also copies every buffer. It
  was rejected as the primary result. The C stream is zero-copy and every
  consumer takes it.
- **A result handle with its own calls** (`komira_result_next`, ...): this would
  duplicate the Arrow C stream with a komira-only interface. Rejected.
- **One `komira_run(ctx, kind, bytes, len, out)` for SQL and plans:** this puts a
  second way to choose behaviour inside an integer argument. Two named calls are
  clearer and are typed in the header. Rejected.
- **`OptimizedPlan` bytes as the plan door's input:** this would move the
  optimizer out of the run and require the not-yet-built codec. It also mixes
  the job-manager path into the in-process session. Rejected for 1.2 (§3).
- **An out-of-process engine** (deferred, not rejected). A child process
  running the same calls would turn a crash into a status naming the signal.
  The cost is a copy of the result across the process boundary (Arrow IPC) and
  replaying the session's registrations in the child. It needs no new run call:
  it would be a session option behind the same calls. The UDF runtimes already
  contain crashes this way (`CONTAINS_CRASHES`,
  [udf_runtime_conformance.md](udf_runtime_conformance.md)). It is not in this
  plan until a crash in the engine is seen in use.
