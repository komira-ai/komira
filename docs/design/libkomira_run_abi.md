# Port: the libkomira calls that run a query (C ABI 1.3)

Status: port document. `komira_sql_stream` is built (ABI 1.3, with the `ArrowStream`
golden type and the header's Arrow structs), and so is the abort containment
of §8 for the paths it lists as refused; `komira_plan_stream` is not. **EXISTS** names code on `main`; **PROPOSED** is new. Statements the author deduced rather than read are marked *(inferred)*.

`libkomira` is komira's one shared library and its flat C ABI
([src/so](../../src/so/README.md)). ABI 1.1 registers and describes sources and
renders a plan. None of its calls runs a query.

This document ports the run calls of the earlier SDK's C ABI to libkomira:
`komira_sql_stream`, `komira_plan_stream` and their result, an Arrow C stream.
They keep the earlier SDK's names, arguments and result, and take on ABI 1.1's
conventions and status codes. It also covers what happens at the boundary when
the engine fails or aborts.

The earlier SDK's ABI golden (23 rows) is the source. This port adds no symbol
that has no row there. The items that do appear in no earlier row are listed apart
in §10, "New relative to the earlier ABI": session options, cancel, progress and
credentials. They are not decided here.

The callers are thin bindings over these calls: the Python package
(`pip install komira`), the Node addon, and the TypeScript Excel SDK.

## 1. Summary

| item | port |
|---|---|
| run SQL | `komira_sql_stream(ctx, sql, out)`, from the earlier golden. ABI 1.3 |
| run a plan | `komira_plan_stream(ctx, plan, plan_len, out)`, from the earlier golden. ABI 1.3. The bytes are an authored `WirePlanEnvelope`, the same input `komira_plan_render` takes. libkomira optimizes it in-process |
| result | an Arrow C stream (`struct ArrowArrayStream`), as in the earlier golden. The caller allocates it and libkomira fills it. The caller owns it after `KOMIRA_OK`. It does not depend on the context, which may be freed first |
| status codes | the six of ABI 1.1. The port adds none. Every engine refusal is `KOMIRA_ERR_ENGINE` (-3), with the reason in the last error |
| conventions | ABI 1.1's: the two-call `komira_last_error`, the 64 MiB input bound (-5), and `*out` untouched on any refusal |
| aborts | every raise becomes a status, and nothing raises across the boundary. Known abort sites on the run path are turned into raises, or refused before the run. Anything left is fail-fast: it ends the process. No signal handler is installed and no `longjmp` is used |
| not carried | `komira_register_python_udf`, `komira_declare_sql_udf`, `komira_register_builtin_mojo_udf`, the seven `xl_*` calls, `komira_plan_bytes` and `komira_sql_render` (§9) |
| new relative to the earlier ABI | session options, cancel, progress, a cancelled status code and credentials. Not decided here (§10) |

The rows' `since` is 1.3 when they land together: 1.2 is the credential calls
(`komira_credential_add`, `_set`, `_seal`; [credentials_and_writes.md](credentials_and_writes.md)
decision 8), which landed first. Releases come from `main` automatically, so a row's `since` is
the version of the first change that lands it on `main`. If `komira_sql_stream` lands alone,
`komira_plan_stream` takes the next minor. The golden (`src/so/abi/komira.tsv`) holds whichever
version is true.

## 2. What exists today

- **EXISTS** ABI 1.1: nine exports, six status codes and `KOMIRA_MAX_INPUT_BYTES`
  (64 MiB) in [komira.tsv](../../src/so/abi/komira.tsv).
- **EXISTS** ABI 1.2: the three credential calls and their `constant` rows (kinds, fields and
  `KOMIRA_BIND_SESSION`), twelve exports in all.
  - The 1.1 conventions: the two-call output protocol and a last error per
    context.
  - Each call that works on the context (register, schema, binding, render)
    clears the last error when it starts. `komira_last_error` does not clear it.
  - An export catches a raise and returns `KOMIRA_ERR_ENGINE`
    (`src/so/_c_abi.mojo`).
  - The `Session` behind a handle holds the last error, the credentials and an
    engine (`sdk_exec`'s `EngineContext`, whose catalog holds the registered
    tables); no call runs it yet.
- **EXISTS** The engine's SQL door is
  `sdk_exec.run_sql(mut ctx: EngineContext, text: String) -> SqlOutcome`
  (`src/sdk_exec/engine_sql.mojo`).
  - It parses, binds, optimizes (`optimizer.optimize`), lowers and runs.
  - It returns the batches, or a `SqlRefusal{step, reason}`. Its steps are parse,
    bind, optimize, lower and execute. It does not raise.
  - The result is materialized: one segment, as `List[RecordBatch]`.
- **EXISTS** `EngineContext(options: EngineOptions)`
  (`src/sdk_exec/engine_options.mojo`). Its options are read once, when it is
  built, and building it starts the worker runtime.
- **EXISTS** `plan_wire.plan_from_bytes` decodes an authored envelope into a
  `LogicalPlan`. The decoder refuses input above `PLAN_WIRE_MAX_BYTES` (16 MiB).
  `OptimizedPlan` is a schema in `src/plan_proto/optimized_plan.proto` with no
  codec. Its design ([optimized_plan.md](optimized_plan.md)) is not built.
- **EXISTS** The Arrow C stream exporter
  `arrow_ipc.build_record_batch_stream(batches, schema, out_stream)`
  (`src/arrow_ipc/c_data_stream.mojo`).
  - It fills a caller-allocated `CArrowArrayStream` and takes ownership of the
    batches.
  - The exported arrays share column buffers by reference count, so the arrays
    outlive the stream.
  - Its release callbacks null `release`, and they are idempotent.
- **EXISTS** The plan conformance harness speaks the earlier SDK's door ABI
  (`src/tests/helpers/komira_plan_harness/door.mojo`): a `const char *`
  `komira_last_error`, a `komira_plan_stream` like the one below, and
  `komira_plan_bytes`, which returns IPC bytes.
- **EXISTS** An abort, a failed `debug_assert`, a fault, stack exhaustion or an
  out-of-memory kill inside libkomira ends the host process. The inputs known
  to reach one are refused before they do (§8, "The abort sites and the
  inputs, by status").

## 3. The two run calls

The earlier golden's rows, in its ctypes spelling:

```text
komira_sql_stream	c_int32	c_void_p,c_char_p,POINTER(ArrowArrayStream)
komira_plan_stream	c_int32	c_void_p,POINTER(c_ubyte),c_uint64,POINTER(ArrowArrayStream)
```

The same calls as libkomira golden rows (`symbol<TAB>return<TAB>arguments<TAB>since`).
The rows of 1.1 and 1.2 stay byte for byte. Only these two rows are added, and no type or
constant changes:

```text
version	1.3
komira_sql_stream	Int32	Handle,CStr,ArrowStream	1.3
komira_plan_stream	Int32	Handle,ConstBytes,UInt64,ArrowStream	1.3
```

The C prototypes in `komira.h`:

```c
int32_t komira_sql_stream(komira_handle ctx, const char *sql,
                          struct ArrowArrayStream *out);
int32_t komira_plan_stream(komira_handle ctx, const uint8_t *plan,
                           uint64_t plan_len, struct ArrowArrayStream *out);
```

**PROPOSED, golden tool.** `ArrowStream` is a new named type in the golden's type
map.
- It is declared in `_c_abi.mojo` as
  `comptime ArrowStream = UnsafePointer[CArrowArrayStream, ...]`, and spelt
  `struct ArrowArrayStream *` in the header. This is the way `CStr` and
  `ConstBytes` are handled today.
- The header defines `ArrowSchema`, `ArrowArray` and `ArrowArrayStream` exactly as
  the Arrow C Data and C Stream interfaces do. Each definition sits inside the
  spec's own `ARROW_C_DATA_INTERFACE` and `ARROW_C_STREAM_INTERFACE` guards, so the
  header can be included next to Arrow's own.
- `OpaquePointer` (`void *`) was rejected for this argument. It would lose the type
  in the header that every binding reads.

### Arguments and order of checks

Both calls follow the order of the 1.1 calls:

1. A NULL `ctx` returns -1, and nothing else happens.
2. The last error is cleared.
3. A NULL `sql`, `plan` or `out` returns -2, and the refusal is stored as the
   last error.
4. The length checks:
   - `plan_len` above `KOMIRA_MAX_INPUT_BYTES` returns -5 before anything is read.
   - For `sql`, the NUL is searched for in at most `KOMIRA_MAX_INPUT_BYTES + 1`
     bytes. A string with no NUL inside the bound returns -5.
   - The SQL text must be valid UTF-8, or the call returns -3.
5. The engine runs. A refusal returns -3, with the message as the last error.

`*out` is written only on `KOMIRA_OK`. On every other status it is left exactly as
the caller wrote it, so a binding can pre-zero it and release nothing. On
`KOMIRA_OK` every slot is written and `release` is non-NULL.

A plan between 16 MiB and 64 MiB passes the ABI bound, and the decoder refuses it
(-3). The two bounds stay separate: the ABI bound protects the copy-in, and the
wire bound belongs to the plan format.

### What `komira_sql_stream` runs

It runs one SQL statement against the tables registered on the context with
`komira_register_parquet` and `komira_add_sql_binding` ([credentials_and_writes.md](credentials_and_writes.md)
decision 8): it runs over the context's whole binding table, and over the call-scope bindings staged
just before it, which apply to that run only and are dropped when it returns. A registration is visible
to every later run on the context.
- **The route.** It is `sdk_exec.run_sql` with the session's `EngineContext`. The
  library converts the SQL text to a logical plan by parsing and binding it.
- **Statements that are not queries.** `run_sql` runs `COPY ... TO` a local
  Parquet, CSV or newline-delimited JSON file and answers one row, the BIGINT `Count`
  ([src/sdk_exec/README.md](../../src/sdk_exec/README.md)). It refuses
  `CREATE TABLE ... AS` and the other statements that are not queries
  (`STATEMENT_NOT_A_QUERY` today; the write design renames it `SQL_STATEMENT_UNSUPPORTED`). The write
  design also lifts the refusal, into a bound catalog, for `CREATE TABLE ... AS` and `INSERT`, which
  answer what DuckDB returns: a one-row `Count` stream, or no rows for `CREATE TABLE` with a column
  list ([credentials_and_writes.md](credentials_and_writes.md#10-writes)).
- **The error text.** **PROPOSED:** the last error text is `<step>: <reason>`,
  where the step is the one that refused (parse, bind, optimize, lower or
  execute). That text is for people, and bindings do not parse it (§6).

### What `komira_plan_stream` runs: the plan door

The input is an authored `komira.plan.v1.WirePlanEnvelope`. These are the same
bytes `komira_plan_render` renders, and the format the SDKs' plan builders write.
- **Envelopes it refuses.** `plan_from_bytes` refuses an envelope that carries a
  write target (`PLAN_WIRE_WRITE_TARGET_DROPPED`) or a UDF list
  (`PLAN_WIRE_UDFS_DROPPED`). The door keeps those refusals (-3) until each lands.
  The write target is lifted by the write design
  ([credentials_and_writes.md](credentials_and_writes.md#10-writes)), the UDF list
  by the UDFs' own. `plan_envelope_from_bytes` already decodes both, for the door
  that carries them later.
- **The route.** It is `plan_from_bytes`, then `optimize`, `lower_for_context` and
  `run_lowered_plan`: the tail of `run_sql` after bind. **PROPOSED:** `sdk_exec`
  gets one `run_plan(mut ctx, var plan: LogicalPlan) -> SqlOutcome`, and `run_sql`
  calls it after binding. SQL and plans then share one route from the optimizer
  down.
- **Tables.** A scan leaf carries its own binding (path, schema and fingerprint,
  from `komira_parquet_schema` or the binding calls), so a plan needs no
  registered table.

**The client optimizes.** In an in-process session libkomira is the client. It
optimizes once, in-process, and then lowers and runs on the same host. This is
the "program that links the engine" role of [optimized_plan.md](optimized_plan.md)
§2.
- No job manager is involved, and nothing is serialized after the optimizer.
- An `OptimizedPlan` is the form a client *submits* to a job manager. It is not an
  input of this door, and a bare `OptimizedPlan` passed here fails the envelope
  decoder by name (-3).
- Producing an `OptimizedPlan` for a job manager is out of scope until its codec
  exists.

## 4. Who calls which entry

The SDKs port the settled shape of the earlier SDK.

- **Python.** The Python package has two DataFrame surfaces: one shaped like a
  pandas `DataFrame`, and one shaped like the polars module. Both build a logical
  plan, serialize it as a `WirePlanEnvelope` and submit it through
  `komira_plan_stream`. A frame is never rendered to SQL text. The package also
  has a plan builder over the plan protobuf.
- **SQL text** goes through its own entry, `komira_sql_stream`. It is not
  scaffolding: it is the entry for users who write SQL.
- **Excel** is a separate TypeScript SDK. It takes Excel formulas, builds a
  logical plan and submits it through `komira_plan_stream`, exactly as the Python
  frames do. libkomira has no Excel-specific call.
- From the optimizer down, both entries run the same route in `sdk_exec` (§3).

The Python port differs from the earlier SDK in three places, each for the reason
given:

- **No switch that sends frames as SQL.** The earlier SDK had one, both as an
  environment variable and as a session argument. Neither is carried. A frame
  always travels as a plan, and configuration is never read from the environment
  (rule S2).
- **No Python UDFs in either entry yet.** The earlier SDK reached them only
  through SQL text, as in-process callbacks. Rule B21 requires Python UDFs to run
  in zygote-forked workers, so neither entry carries them until that design lands.
  The plan door refuses an envelope with UDFs by name (§3).
- **One engine per session.** The earlier SDK built a fresh engine context for
  every call. Here the session keeps one `EngineContext` (§7).

The Excel port differs from the earlier code in four places, each for the reason
given:

- **The plan is built in the SDK, and only submitted to the library.** The
  earlier formula parser and plan builder were Mojo inside the library. Seven
  `xl_*` calls bound names, rendered, evaluated and streamed formulas, and a
  scalar evaluator ran formulas with no plan at all. Here the TypeScript SDK holds
  the parser and the plan builder, and the library only ever sees plan bytes.
- **Every formula becomes a plan.** That includes scalar formulas such as `=1+1`,
  which the earlier builder refused and evaluated directly. A formula's cell values
  and named ranges ride in the plan as literals, or as tables the host registers.
  They never go through bind calls.
- **Excel semantics are engine work, not C ABI surface.** Some functions' correct
  answers differ from SQL's. Excel `UPPER` does full case folding, where DuckDB
  maps one code point to one. Excel also has error values such as `#DIV/0!`.
  These functions become plan expressions with Excel behaviour, never a reused SQL
  kernel, because the two surfaces have different oracles.
  - New expression arms on the plan wire are additive (rule B8).
  - How a result column carries an Excel error value is decided with those
    expressions. It is data inside the Arrow stream, never a status code of the
    run call, so it changes nothing here.
- **The Node binding carries it.** The TypeScript SDK reaches libkomira through
  the Node addon. When the addon gains its run call, it drains the stream in C
  (§9).

## 5. The result: an Arrow C stream

- **Who allocates.** The caller allocates `struct ArrowArrayStream` (five
  pointer-sized slots) and passes its address, as in the earlier golden. Every
  Arrow consumer expects this:
  - pyarrow `RecordBatchReader._import_from_c`, and the `__arrow_c_stream__`
    capsule;
  - Arrow C++ `ImportRecordBatchReader`;
  - arrow-rs `FFI_ArrowArrayStream`.
- **Who owns.** After `KOMIRA_OK` the caller owns the stream and calls `release`
  exactly once, as the Arrow spec requires.
  - The caller may move the struct by copying it. The old copy then counts as
    released.
  - Arrays taken from the stream are independent of it. Each array has its own
    `release`, which stays callable after the stream is released (the spec, and
    **EXISTS** in `build_record_batch_stream`).
- **Lifetime against the context.** The stream holds no reference to the
  `Session` or the handle. It owns its batches, and their buffers are shared
  columns, so `komira_ctx_free` may run before the stream is released.
  - Python and Node garbage collectors release late. This rule spares every
    binding from ordering its finalizers.
  - The earlier SDK built an engine context per call, so its streams never
    depended on the session either *(inferred)*.
  - This is a requirement on the export change, not yet a checked fact. If any
    buffer a result holds is accounted to, or allocated from, state that
    `komira_ctx_free` tears down (the memory budget, the worker runtime), the
    stream holds an `ArcPointer` on that state. A C driver case frees the context,
    then reads the stream, releases it, and releases its arrays.
- **The library stays loaded.** The release callbacks are code in libkomira, so a
  binding never unloads the library while a stream from it may be live. Neither
  binding ever `dlclose`s it. The Node addon already does not, because the Mojo
  runtime does not support being unloaded.
- **Materialized first.** The run completes before the call returns, and
  `get_next` hands out batches that were already computed. The memory budget
  bounds the operators but not the size of the result *(inferred from `run_sql`
  returning `List[RecordBatch]`)*. Later, `get_next` can drive the engine
  incrementally, and the calls do not change.
- **Types.** The stream carries only types the exporter supports.
  - A result column outside that set is refused by the run call (-3, naming the
    column and its type) before `*out` is written. It is never left to fail
    inside `get_schema` or `get_next`.
  - The same holds for an empty result: its schema must export, so a type the
    exporter cannot export without data is refused at the run as well.
  - The export change lists the supported set in `src/arrow_ipc/README.md`.
- **Callback errors.** The callbacks never raise.
  - `get_schema` and `get_next` return 0 or an errno value: `EINVAL` on a released
    stream or a NULL argument, `EIO` on a failure.
  - `get_last_error` returns text the stream owns, valid until the next callback
    or `release`.
  - Errno values differ by platform, so the Mojo side takes them from a C shim,
    not from literals (rule M8).
- **Threads.** A stream is used by one consumer at a time, which is the Arrow
  rule. It can be read on a thread other than the one that ran the query.

## 6. Status codes

The port adds no code. The six codes of ABI 1.1 cover the two run calls:

| code | when |
|---|---|
| 0 `KOMIRA_OK` | `*out` holds a stream |
| -1 `KOMIRA_ERR_NULL_CTX` | NULL `ctx` |
| -2 `KOMIRA_ERR_NULL_ARG` | NULL `sql`, `plan` or `out` |
| -3 `KOMIRA_ERR_ENGINE` | invalid UTF-8; a parse, bind, optimize, lower or execute refusal; an unsupported feature refused by name (rule B21); a result type the stream cannot carry; a plan the decoder refuses, including an envelope with a write target or UDFs; an engine that fails to build |
| -4 `KOMIRA_ERR_BUFFER_TOO_SMALL` | not returned by the run calls (no byte output) |
| -5 `KOMIRA_ERR_TOO_LARGE` | `plan_len`, or SQL text, above 64 MiB |

The earlier SDK carried a second code space inside the message text: a
`PLAN_ENDPOINT_<NAME>(<code>): ` prefix, parsed by a regex against a frozen table.
It is not carried. The status code is the machine-readable part, and the text is
for people.

**PROPOSED:** the 1.3 change writes into the README and the header that a binding
treats any negative code it does not know as a failure. That keeps a later code
additive. Today the README says only that every failure is negative.

## 7. The session behind the run calls

- **One catalog.** A session holds one catalog, the `EngineContext`'s. The
  `SqlCatalog` that the 1.1 `Session` keeps itself goes away, so a registered table
  is never in two places.
- **One engine, built lazily.** The `EngineContext` is built by the first call
  that needs it: a registration (`komira_register_parquet`, `komira_add_sql_binding`) or
  a run.
  - The describe calls (`komira_parquet_schema`, `komira_csv_binding`,
    `komira_json_binding`, `komira_plan_render`) do not build it.
  - If the build fails, the call returns -3 with the engine's message. The session
    stays without an engine, so a later call tries again.
  - The earlier SDK built an engine context per call, so it had no such rule.
- **Threads.** As in 1.1, a handle is used by one thread at a time.
  - A handle is not tied to a thread. Python runs a query on a helper thread and
    holds a lock per session ([python_package.md](python_package.md)).
  - Streams from earlier runs are independent of the context (§5), so they may be
    read while a new run starts.
- **State after a refusal.** A context stays usable after any refusal. The
  session's state (catalog, engine) changes only when a call succeeds, and each
  run starts its per-query state afresh. Today `EngineContext.begin_query` drops
  the previous query's footer cache.

## 8. Aborts at the boundary

A Mojo `raise` is a value, and every export catches it. These are not values:
- an `abort()`;
- a failed `debug_assert`, at the assert levels that keep them;
- an out-of-bounds fault;
- stack exhaustion;
- an out-of-memory kill.

Mojo has no unwinding, and nothing in the library can turn these into a status.
The earlier SDK had no containment either. Its answer was to validate first, and
otherwise fail fast. The port keeps that answer and makes it explicit:

1. **Nothing raises across the boundary.** Every export, and every stream
   callback, catches every raise and returns a status or an errno, as the 1.1
   exports do. The run change tests a good query on the same handle after each
   kind of refusal (§7).
2. **Refuse before running.**
   - Input bounds, NULLs and UTF-8 are checked before anything is read.
   - The plan decoder's admission limits apply (`plan_wire_admit`: size, version,
     depth, node count).
   - Lowering refuses unsupported shapes by name (rule B21). A query therefore
     never reaches an operator default that aborts on a shape it was never routed,
     such as the aggregate defaults in `src/agg/aggregator.mojo`.
   - A result type the stream cannot carry is refused at the run (§5).
3. **Turn known abort sites on the run path into raises.**
   - The abort containment change lists every `abort(` reachable from the two run
     calls. For each one it either makes it a raise, refuses its input at the
     boundary, or argues why input cannot reach it.
   - Examples are the catch-and-abort patterns in `src/op_sort`, and the
     variable-length payload aborts in its payload stage.
   - It adds a C driver case per reachable site, which asserts a status rather than
     a crash.
   - The codec libraries are among those sites. `compression` (`_open_or_abort`)
     and `zlib` open their system libraries in `_Global` initializers, which cannot
     raise. Those run lazily, at the first use of a codec, so a missing library
     aborts in the middle of a query (for example at the first compressed Parquet
     page).
   - **EXISTS:** every call that can reach a codec (the three register calls,
     the three describe calls, `komira_sql_stream` and `komira_sql_stream_run`) first opens libzstd, libz and liblz4 through a raising
     probe (`compression.probe_codec_libraries`), so a missing library is -3 at
     that call. Today the engine is built by `komira_ctx_new`, and the probe runs
     per call instead of there: a context on a host
     without one of them still describes plans and defines credentials.
4. **Fail-fast for the rest, and say so.** Whatever still aborts ends the host
   process. The `src/so` README and the Python package docs state this, along with
   the assert level the published library is built at.
5. **Rejected: a signal handler with `longjmp`.** Catching `SIGABRT` or `SIGSEGV`
   and jumping back to the export is unsound:
   - other engine threads are left holding locks over half-written state;
   - Mojo destructors are skipped, so memory leaks or is freed twice;
   - a library's handler overrides the host's own (Python's `faulthandler`,
     Node's).

   libkomira installs no signal handler at all. The async runtime's SIGTERM
   handler (`async_rt` `install_sigterm_handler`) is for servers at boot, and
   libkomira never calls it.

### The abort sites and the inputs, by status

Every `abort(` in the closure of `src/so` (its `deps`), every input class the
readers of the run path found that ends the process without one, and what
happens to it. Read from the code, by grep of the closure and by following the
call paths from the exports; nothing here was measured unless it says so.

**Refused, with a C driver case** (`src/so/tests/c/abort_driver.c`, target
`//src/so:abort_check`):

| input | where it ended the process | now |
|---|---|---|
| a statement nested more than 100 levels (parentheses, prefix `NOT`, prefix minus, scalar subqueries, derived tables) | the parser recursed once per level on the caller's stack (`sql/sql_parser.mojo`), about 25 KB per parenthesis and 35 KB per subquery (measured on linux-x86_64 from the stack's high-water mark), so about 300 levels filled an 8 MiB stack in the parser alone | `parse: SQL syntax error: the statement nests deeper than 100 levels`; exactly 100 levels runs. DuckDB allows 1000; smaller parser frames would let the limit rise |
| `lpad` / `rpad` with a count such as 2^63 - 1 | `_pad_bytes` (`batch_eval/string_bytes.mojo`) appended the pad with no ceiling | refused over the 64 MiB per-row ceiling `repeat` already had (`STRING_FN_N_REPEAT_MAX_BYTES`) |
| `repeat` with a count such as 2^31 - 1 | not an abort: refused before the change too; kept as a case | the same refusal |

**Refused, without a C driver case:** libzstd, libz or liblz4 missing on the
host. `compression/codec_libraries.mojo` (`_open_or_abort`),
`zlib/zlib_ffi.mojo` and `lz4/codec.mojo` open them in `_Global` initializers,
which cannot raise, at the first zstd, gzip or lz4 page or file, at a Parquet
page CRC (libz's `crc32`), or at a `COPY ... TO` with that compression. The
probe above makes it -3 first. A C driver cannot hide a host library without
an environment variable or a container, so the probe's refusal is a welded test
of `compression` over a soname that does not exist.

**Not reachable from an export** (each site stays as it is):

| site | why no input reaches it |
|---|---|
| `op_sort/sort_stage_string_key.mojo`, `op_sort/sort_stage_payloads.mojo` (25 `abort(`) | the typed sort stage (`SortBuffer`, `SortKeyColumn_String`, `PayloadCol_String`) has no caller outside `op_sort`'s and `op_window`'s tests; SQL sorts run in `pipeline_exec/sink_sort.mojo` through `op_sort.sort_multi` and `sort_topn_sink`, which hold no `abort(` |
| `agg/aggregator.mojo` (2), `op_agg_state/dyn_accumulator.mojo` (2) | no file of `sdk_exec`, `pipeline_exec`, `lowering` or `so` imports `agg` or `op_agg_state`; SQL aggregates run in `pipeline_exec/sink_agg.mojo`, which raises on a type or tag it does not serve |
| `compression/codec_libraries.mojo` for libbz2 and liblzma | only the Avro block codecs open them, and no export reads Avro |
| `aws_core/aws_retry.mojo` (1) | the token bucket is built from two positive constants it never refuses |

The other matches of `abort` in the closure are comments, an unused import
(`op_sort`), and a method named `abort` (`morsel/streaming_sink.mojo`). A raise
on an engine worker thread is not one of these: the segment task, the
dispatcher and `fork_join` catch it, and `run_sql` returns it as a refusal.
The Arrow stream callbacks hold no `abort(` and return an errno for a NULL
argument or a released stream.

**Still ending the process** (fail-fast, item 4; each is its own change):

- **Flat chains.** `x IN (1, 2, ..., N)` is parsed into a left-deep `OR` chain
  of N levels, and `1 + 1 + ...`, `a AND b AND ...` and `UNION` chains are
  left-deep too. Later walkers recurse over that depth *(inferred: no depth at
  which one fails was measured)*. A nesting limit would refuse long `IN` lists,
  which DuckDB runs, so the fix is a flat `IN` list and n-ary `AND`/`OR`, then
  a bound on the rest.
- **Parquet footers that amplify.** A footer of millions of one-byte empty
  schema elements or row groups is bounded only by its byte length, about
  150-250 bytes of heap per byte of footer *(inferred)*; the fix is a column
  and row-group count ceiling beside the reader's list-size check.
- **Compressed CSV and JSON read whole.** `csv_binding` and `json_binding`
  decompress a `.gz`, `.zst` or `.lz4` file whole before inferring from a
  256 KiB prefix, so a decompression bomb can exhaust memory; the fix is an
  output cap on that read.
- **Corrupt Parquet data pages.** The data-page decoders were not audited here
  for a length read from the page and used unchecked; that audit is its own
  change.
- **Plan decode stack.** `plan_wire` bounds the nesting to 64 messages, not
  the stack they take; a host thread with a small stack is not covered.
- **A file truncated while it is mapped.** Binding reads the prefix through a
  mapping, so another process truncating the file at that moment raises
  `SIGBUS`. It cannot be tested deterministically.
- **Anything else** that aborts, faults or runs out of memory. The library is
  built at the compiler's default assert level, `safe`: the `debug_assert`s
  declared `assert_mode="safe"` are kept, and abort when they fail.

## 9. What replaces the earlier doors, and what is not carried

The earlier SDK's run path was a plan endpoint and a result-IPC egress:

- **The plan endpoint** was one call that admitted, decoded, validated and
  executed a plan. It is replaced by `komira_plan_stream`: `plan_wire` admission
  and decode, then the shared `sdk_exec` route (§3). There is no separate endpoint
  package.
- **The result-IPC egress** wrote Arrow IPC stream bytes, through
  `komira_plan_bytes` and a CLI. It is replaced by the Arrow C stream, and IPC
  bytes are a binding's own business.
  - The Node addon is the one caller without a C stream importer. It drains the
    stream in C. How it hands batches to JavaScript is decided when it gains a run
    call.
  - The plan harness's door (`door.mojo`) still describes the earlier `const char *`
    `komira_last_error`. It moves to the 1.1 form when the harness is pointed at
    libkomira.

The earlier golden's 23 rows, and where each one goes:

- **Already in ABI 1.1:** `komira_abi_version`, `komira_ctx_new`,
  `komira_ctx_free`, `komira_register_parquet`, `komira_parquet_schema`,
  `komira_csv_binding` and `komira_json_binding`.
  - `komira_last_error` and `komira_plan_render` are also in 1.1, in its two-call
    form instead of the earlier `const char *` return.
- **Ported here:** `komira_sql_stream` and `komira_plan_stream`.
- **Not carried:**
  - `komira_register_python_udf`
  - `komira_declare_sql_udf`
  - `komira_register_builtin_mojo_udf`
  - `komira_xl_bind`, `komira_xl_bind_value`, `komira_xl_bind_cell`,
    `komira_xl_render`, `komira_xl_eval`, `komira_xl_functions`,
    `komira_xl_stream`
  - `komira_plan_bytes`
  - `komira_sql_render`

## 10. New relative to the earlier ABI

The earlier golden has no row for any of the items below. **None of them is
decided here.** Each is settled by its own change:
- session options (now built, below), cancel and progress by their feature
  pull requests;
- credentials, and the structured error calls `komira_last_error_code` and
  `komira_last_error_step`, by [credentials_and_writes.md](credentials_and_writes.md).

What earlier drafts of this document proposed is kept as input for those
changes:

- **Session options** (worker count, memory budget). **EXISTS**, ABI 1.4:
  `komira_ctx_new_with_options(int64_t worker_count, int64_t memory_budget_bytes)`,
  a constructor with arguments ([src/so/README.md](../../src/so/README.md),
  "Session options"). 0 is the host's own value, a negative value is the NULL
  handle, and the options are fixed for the life of the context. An earlier
  draft proposed typed setters accepted until the session's engine is built
  (§7); the engine is now built in `komira_ctx_new` itself, so there is no
  window in which a setter could still change it, and the constructor is what
  remains. Still rejected: an options struct (its layout would become ABI),
  string key and value pairs, and environment variables (rule S2).
- **Cancel and progress** (decided and built in ABI 1.6; [src/so/README.md](../../src/so/README.md),
  "Cancel and progress"). The earlier proposal here was `komira_cancel(ctx)` and
  `komira_progress(ctx, ...)` on one control block per context, where a cancel with no
  run in flight did nothing. What was built is a run handle the caller creates and
  passes to the run instead:
  - `komira_run_new`, `komira_run_free`, `komira_run_cancel(run)`,
    `komira_run_progress(run, uint64_t *done, uint64_t *total)` and
    `komira_sql_stream_run(ctx, sql, run, out)`. Cancel and progress are callable
    from another thread while the run is in flight, and touch no context and no
    last error.
  - Why a handle and not the context: a cancel belongs to the run the caller chose.
    A Ctrl-C that lands just as one query returns cancels that query's handle, which
    no later run is given, so it cannot reach the next query. And a cancel that comes
    before the call reaches the run, so a test cancels without racing the engine.
  - A cancelled run returns `KOMIRA_ERR_CANCELLED` (-6), leaves `*out` untouched, and
    sets the last error `QUERY_CANCELLED: execute: <reason>`. A cancel is observed
    only while the plan runs (before each segment and at each morsel boundary); a
    statement refused earlier keeps its own refusal.
  - Progress counts the plan's segments: the total when the plan is checked, and the
    done count as each segment finishes. It is polled, never called back into the
    host.
  - An incrementally read stream, when one exists, would return `ECANCELED`.
- **Credentials** (decided in [credentials_and_writes.md](credentials_and_writes.md)).
  Constraints from the repository rules that design starts from:
  - Configuration comes as explicit calls. The provider-standard environment
    (`AWS_*`, `GOOGLE_*`) is the one allowed exception (rule S2).
  - No endpoint is written into the code (rule S1).
  - Secret material never appears in `komira_last_error` text.
  - The engine's secret model (`SecretCapability` and the `secret_registry`
    bindings in `src/sdk_exec/secret_capability.mojo`) is what credentials feed.
- **An out-of-process engine** (deferred). A child process running the same
  calls would turn a crash into a status naming the signal. The cost is a copy of
  the result across the process boundary (Arrow IPC) and replaying the session's
  registrations in the child. The UDF runtimes already contain crashes this way
  (`CONTAINS_CRASHES`, [udf_runtime_conformance.md](udf_runtime_conformance.md)).

## 11. Versioning and bindings

- **The version rule.** Adding a row raises the minor, and a change or removal
  raises the major. That is the 1.1 rule, unchanged, and the port only adds rows.
- **Checks in a binding.** A binding checks the major when it loads the library,
  and each symbol when it first uses that call.
  - A library too old for a call fails that call with a named error, for example
    "libkomira 1.1 has no komira_sql_stream". Every other call still works.
  - The earlier SDK raised its version on every symbol and refused older libraries
    outright. That is a version floor, the thing rule B8 rules out for data, so it
    is not carried.
  - The Node addon already checks the major only, and it ignores symbols it does
    not bind.
- **The C driver.** The C driver (`src/so/tests/c/abi_driver.c`) binds every row
  through the generated header.
- **Crossing versions.** Old and new libraries are crossed the way
  `node/tests/fake_libkomira.c` does it: a stand-in library of the previous minor,
  and the current library under a binding that knows only the previous minor's
  calls.

## 12. Where the work lands

Each part below is its own change, and each adds its rows and its tests together:

1. The stream export from run results (`arrow_ipc`, the supported type set).
2. libkomira links `sdk_exec`. The session gets one catalog and a lazy
   `EngineContext` (§7).
3. `komira_sql_stream` and `komira_plan_stream`, with the `ArrowStream` golden
   type, the gate drivers, the C driver and the 1.3 rows (§3).
4. Abort containment (§8, items 3 and 4): built for the paths §8 lists as
   refused; the paths it lists as still ending the process follow.

The items of §10 follow in their own changes.

## 13. Options considered

- **Run calls that return IPC bytes through the two-call protocol** (the earlier
  SDK's second door). Rejected as the primary result:
  - it runs the query twice, or parks the result on the session between the probe
    and the fill;
  - it copies every buffer;
  - the C stream is zero-copy, and every consumer takes it.
- **A result handle with its own calls** (`komira_result_next`, ...). Rejected: it
  would duplicate the Arrow C stream with a komira-only interface.
- **One `komira_run(ctx, kind, bytes, len, out)` for SQL and plans.** Rejected: it
  puts a second way to choose behaviour inside an integer argument. Two named calls
  are clearer and are typed in the header, and they are the earlier golden's
  shape.
- **`OptimizedPlan` bytes as the plan door's input.** Rejected for 1.3 (§3):
  - it would move the optimizer out of the run;
  - it would need a codec that is not built yet;
  - it mixes the job-manager path into the in-process session.
