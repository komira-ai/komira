# Streamed results: the engine hands out batches as it makes them

Status: design, not built. **EXISTS** names code on `main`; **PROPOSED** is new. Statements the author
deduced rather than read are marked *(inferred)*.

Today a query's answer leaves libkomira as an Arrow C stream (`komira_sql_stream`, `komira_plan_stream`),
but the stream is a cursor over an answer that was computed whole before the call returned. The first
row reaches the caller only after the last row was computed, and the whole answer is in memory at once.
This document designs real streaming: a reader that asks for the next batch gets it while the rest of
the query is still to run, the engine runs ahead of the reader by a bounded amount, and a reader that
stops early stops the query.

It answers, in order: what the earlier engine built (§2), where komira materialises the answer today
(§3), what the reference libraries promise (§4), the execution model (§5), the C interface (§6), the
SDKs (§7), writes (§8), the tests (§9), the slices (§10), and the decisions that are the owner's (§11).
"Streaming" here means streaming the result of a bounded query. Plans over unbounded input, run in
epochs, are a different subject ([plan_models.md](plan_models.md) §4.3), and nothing here changes them.

## 1. Summary

| item | design |
|---|---|
| the model | **bounded waves, pulled by the reader** (§5). The breakers below the root run as today. The root pipeline runs in waves: a wave is one ordinary fork-join dispatch in which each worker takes a new claim (a row group) only while a credit gate admits one, so a wave stops by itself when the delivery queue is full. A reader's `get_next` runs the next wave when the queue is empty. No engine thread ever waits on a reader |
| the bound | at most `N` claims and `B` bytes held for the reader, plus one claim in flight per worker, all by construction (§5.3); a root pipeline with a keyed join probe, whose output one claim does not bound, is refused by name until the probe splits its output. Proposed defaults: `N` = 2 × workers, `B` = 64 MiB, charged to the context's memory budget |
| order | a streamed result comes out in the order the materialised result has today: source position order (file order) for a scan, the sort's order for `ORDER BY`. A `LIMIT` without `ORDER BY` is cut at delivery, so it returns the first `n` rows in that order (§5.4, §5.5) |
| what cannot stream | a sort, an aggregate, a window, a distinct and a join's build side finish before their output exists. The first `get_next` waits for them; progress and cancel work meanwhile (§5.6) |
| a late error | an error in the morsel that would have produced batch `N` is returned by the `N`th `get_next` (`EIO`, the error text in `get_last_error`), after every batch before it (§5.7) |
| cancel | `komira_run_cancel(run)` from any thread, as today; a waiting `get_next` returns `ECANCELED`. Releasing the stream before its end ends the run and frees everything it holds (§5.8) |
| the C interface | the Arrow C stream stays the one result shape. Two calls are added, `komira_sql_open` and `komira_plan_open`, which return the stream before the run, with the run handle that cancels it; `get_schema` answers from the plan before any batch exists (§6) |
| the existing calls | `komira_sql_stream`, `komira_sql_stream_run` and `komira_plan_stream` keep their contract: the answer computed before the call returns, every engine error a status. Later they are rebuilt as open-then-drain, so there is one mechanism (§6.5) |
| ABI version | 1.11 for `komira_sql_open`, then the next minor for `komira_plan_open` (§6.6) |
| SDKs | Python `Result.to_reader()` streams; `sql()` still raises for an error before the first batch. `read_csv(chunksize=n)` and `iterator=True` need a CSV source that streams first. Node's async iterator reads batch by batch. The Mojo SDK gets a stream form beside its `Result` (§7) |
| writes | `COPY ... TO` and the SDK sinks do not stream today: they compute the answer, encode the whole file in memory, then write it. They move onto the same streamed run, with a writer appending to a temporary file renamed at the end (§8) |
| first slice | one SQL query over Parquet, streamed end to end through `komira_sql_open`, proven by the C driver and the engine tests (§10) |

## 2. What the earlier engine did

This work was asked for as a revival of the earlier engine's streaming, so the earlier engine's
history was read in full for this design: its Rust engine, its first Mojo engine and its later Mojo
engine, its C interface, its Python SDK and its design records. **It never streamed a query's result
to its caller.** Every result path ran the query to completion first. What it did build, and what of
that this design keeps, is below.

### 2.1 How a result left the engine

- **The Rust engine.** `collect()` returned a `Vec<RecordBatch>` after the morsel scheduler had run every
  segment. Its bounded channels (`sync_channel` with a capacity of twice the reader threads) carried
  decoded row groups from reader threads to a Parquet writer thread, file to file, with a reorder buffer
  keyed by row-group index on the writer's side. They were never between the engine and a caller, and
  they were deleted with that executor.
- **The first Mojo SDK.** A "streaming materialize" result type ran the whole query, then sliced the
  one result batch into pages of `rows_per_batch` rows and handed the pages out one by one. Its own
  header called this "eager-materialize-then-chunk", and named the real primitive (a worker pool that
  pauses and resumes) as a later follow-up. The type was later renamed to a "paginated" result, because
  the name claimed streaming that the code did not do and could never return on an unbounded input.
- **The later Mojo engine.** Its result sink said in its header: the Arrow C stream is a pull interface,
  a sink is push, so the sink buffers every batch and exports them after the run; "true incremental
  streaming-export ... is the ... streaming follow-up". Its C entry points (`komira_plan_stream`,
  `komira_sql_stream`) ran the plan to one batch or one chunked table, then built the stream over it.
  Its Python `Session` documented that `komira_sql_stream` "executes the query — it does not merely open
  a stream".
- **Its "streaming" work was elsewhere.** A ratified streaming record designed micro-batch,
  exactly-once jobs over unbounded sources (a broker, a write-ahead log, shuffle as a broker, a
  streaming sink with `pre_commit`, `commit` and `abort` per step). A second record designed
  overlap between pipeline segments inside one query. Neither delivers a result to a caller, and the
  first said in so many words that its jobs must not be confused with the paginated result.

### 2.2 Back-pressure, cancel, errors, memory and tests

- **Back-pressure.** None on the result path. Its channels (an SPSC and an MPSC ring, bounded in
  slots, a power of two) returned `FULL` to a producer and never parked it; the wake word they reserved
  for parking was never wired. A morsel driver had a "maximum in flight" of 64 parked I/O morsels that
  sized a slab and was never compared against anything.
- **Cancel.** A `CancellationToken` (a chain of atomic flags, cancelled downward to children, never
  up) was polled between morsels and between dispatched tasks, and dropping a join handle cancelled its
  task. Neither was tied to a result: releasing a result stream only freed the buffered batches, since
  nothing was running by then. Cancel latency was bounded by the work between two checks, and the
  engine's own notes record a query that decoded a whole 81-million-row column before it could be
  refused.
- **Late errors.** Impossible by construction: every execution error came back as the status of the run
  call. `get_next` could fail only while building an Arrow array from a stored batch (`EIO`, with the text
  in `get_last_error`).
- **Memory.** The whole result was resident until the stream was released. A per-segment memory
  accountant existed, wired into two aggregate sinks.
- **Order.** The collect sink kept "collected order". A sink capability meant to make the planner
  disable parallel scheduling for sinks that need source order was declared and never read.
- **Tests.** Lifetime tests only, and they were good ones: every buffer of every array read through the
  raw C struct after the stream was released, in all three release orders; a chunk outliving its stream;
  a stream read after its engine context was destroyed; ten thousand export cycles without a leak; a
  chunkless table keeping its schema. No test measured anything read at the first batch, a peak memory,
  a cancel through the stream or a late error, because none of those could happen.

### 2.3 What this design carries from it

- **The Arrow C stream as the result shape**, and its lifetime rules: each exported array owns its share
  of the buffers and outlives the stream, release is idempotent and leaves stubs behind, the stream
  holds no reference to the session. komira already carries all of this
  (`src/arrow_ipc/c_data_stream.mojo`).
- **Drop means cancel**, from its join handles, applied to a result stream (§5.8).
- **The lifetime tests**, rerun against a stream that is still producing (§9).
- **One lesson:** cancel latency is the work between two checks, so a check point sits at every morsel
  and the morsel size is bounded (§5.3).
- **Not carried:** the 2PC sink contract (a result has no durable step to commit), the never-enforced
  in-flight cap, rings that spin or return `FULL`, and pagination of a materialised answer.

## 3. Where komira materialises the answer today

**EXISTS.** The call chain of `komira_sql_stream`, every step done before the call returns and before
`*out` is written:

| step | where | what it does |
|---|---|---|
| 1 | `src/so/_c_abi.mojo:674` | `_sql_stream` calls `sql_result(session[], text, control)` |
| 2 | `src/sdk_exec/engine_sql.mojo:127`, `:149` | `run_sql_with` calls `ctx.begin_query()` (which replaces the context's footer cache), parses and binds, then `run_plan_batch` |
| 3 | `src/sdk_exec/engine_execute.mojo:162`, `:171` | `run_plan(...)` runs every segment, then `out.take(lowered.result_seg_id)` takes the root's output: **one `RecordBatch`** |
| 4 | `src/pipeline_exec/run_plan.mojo:66-85` | a serial ready-set loop: one segment at a time, a cancel check before each, `finish_segment` after each |
| 5 | `src/pipeline_exec/run_segment.mojo:115`, `:153-155` | one `run_with_state` dispatch per segment; the calling thread waits in the dispatch barrier until every worker has finished, then `combine`, `finalize`, `take_output` |
| 6 | `src/pipeline_exec/sink_collect.mojo:104`, `:118`, `:144` | **the sink that materialises**: `consume` appends each morsel's batch to the worker's slot; `combine` orders all chunks by source position (`position_order`); `take_output` concatenates them into one batch (`concat_record_batches_nway`) |
| 7 | `src/sdk_exec/engine_sql.mojo:157` | `outcome.batches.append(batch^)`: the list of the answer, which holds exactly one batch |
| 8 | `src/sdk_exec/arrow_result.mojo:69-75` | the one batch moves into a `Slab`, and `check_record_batch_stream` refuses a type the exporter cannot export |
| 9 | `src/so/_c_abi.mojo:677` | `build_record_batch_stream(result.take_batches(), result.take_schema(), out_stream)` fills the caller's struct |
| 10 | `src/arrow_ipc/c_data_stream.mojo:2925-2944` | `get_next` builds an Arrow array over the next stored batch (no copy, shared buffers) and ends at the end of the `Slab` |

So the answer is materialised by `CollectSink.take_output` at the end of the root segment, called from
`run_segment` after the dispatch barrier, and the reason is structural, not incidental:

- **The dispatch returns only when every worker has finished.** `run_with_state` holds the caller in its
  barrier until every shard is done, and only one dispatch can be live per dispatcher
  ([async_runtime.md](async_runtime.md), "What must always hold?"). Nothing can leave a segment before its
  dispatch returns.
- **The sink learns that every morsel has arrived only at `combine`**, so it can order by position only
  then. The order the result has today (file order, whatever the schedule) is bought by holding
  everything.
- **The run call is synchronous and its errors are statuses.** "The answer is computed before the call
  returns" is the documented contract of `komira_sql_stream` (`_c_abi.mojo:695`), which
`komira_sql_stream_run` and `komira_plan_stream` take over by reference, and the rule "a query
  is never answered from a part of its input" ([lowering_and_pipeline.md](lowering_and_pipeline.md),
  failure table) holds because nothing is handed out before the end.

The memory cost: the collect sink holds every chunk until `take_output`, and the concatenation copies
them, "so a segment's peak memory is about twice its output" (`src/pipeline_exec/README.md`, Known
limits). The collect sink's chunks are not charged to the memory budget.

Above the C interface the same holds. Python's `Result.to_reader()` is a pyarrow reader over that
stream (`python/komira/_session.py:623`), lazy only over batches that already exist. Node's addon drains
the stream on the session's thread before `sql` resolves (`node/src/result.ts:5-7`). pandas'
`read_csv(chunksize=n)` was left unbuilt for this reason: chunks taken from the engine would read the
whole file before the first chunk.

Sources matter as much as the sink. The Parquet source claims row groups lazily, per worker. The CSV
and Iceberg sources decode their whole input before the first morsel (`source_csv.mojo:21-22`,
`source_iceberg.mojo:15-16`), and the JSONL source builds every batch up front. A streamed result over
those sources would still read the whole input before its first batch.

## 4. What the reference libraries promise

**The Arrow C stream interface.** `get_schema`, `get_next`, `get_last_error`, `release`. `get_next`
returns 0 and an array, or an errno-like code; a released (NULL `release`) array is the end of the
stream. `get_last_error` may be called only after a failed call and is valid until the next callback.
The source "is not assumed to be thread-safe": a consumer serialises its calls. The spec says nothing about
releasing before the end, and nothing about any call from a second thread, so a cancel from another thread
needs its own entry point outside the stream. An async device stream with a thread-safe `cancel` and
`request(n)` back-pressure exists but is marked experimental. pyarrow's reader calls `get_next` with the
GIL released (`read_next_batch` and `read_all` are `with nogil` in `ipc.pxi`), releases the stream when
the reader is closed or collected, and turns a non-zero `get_next` into an exception whose message is
exactly `get_last_error`'s text (`EINVAL` becomes `ArrowInvalid`, `ENOMEM` `ArrowMemoryError`,
anything else `OSError`).

**ADBC**, the database API over that stream, fills both gaps. "Releasing the returned ArrowArrayStream
without consuming it fully is equivalent to calling AdbcStatementCancel." `AdbcStatementCancel` "must
always be thread-safe (other operations are not)", may be called "while consuming an ArrowArrayStream",
and makes the stream's methods return `ECANCELED`; it is best effort, since "the result set may be
buffered in memory already".

**DuckDB.** `con.sql(q).to_arrow_reader()` (also `fetch_record_batch(rows_per_batch)`) streams: the
result collector is a buffered collector whose sink returns `BLOCKED` when its buffer is full and is
rescheduled as the reader drains it, and the query's tasks run on the fetching thread until the buffer is
no longer empty. The buffer is a byte bound (`streaming_buffer_size`, about 1 MB in 1.5, a 10 MiB
`max_streaming_buffer_size` on its main branch), admitting one unit even when it would overshoot.
`rows_per_batch` sizes the Arrow chunks only. A late error makes the `N`th `get_next` return -1 with the
message, so pyarrow raises it there, after the earlier batches. Destroying a streaming result whose
statement has not completed aborts the statement, and another query on the same connection ends an
open stream. Order: with `preserve_insertion_order` (the default) a plan without `ORDER BY` keeps
insertion order, through a batch-indexed collector or a single-threaded one; with it off, the
collector is parallel and the order is not defined. Its newer Python binding releases the stream
without the GIL, because releasing "ends the query and joins its tasks, one of which may be inside a
Python UDF waiting for the GIL".

**polars.** `collect(engine="streaming")` runs the batch-at-a-time engine but returns one whole
`DataFrame`. `LazyFrame.collect_batches(chunk_size, maintain_order=True, lazy=False)` (unstable) yields
`DataFrame` chunks from a channel of capacity 1: the engine waits on the channel, an error is sent down
it and raised by the `next()` that reaches it, and dropping the iterator closes the channel, which stops
the sink. `sink_parquet`, `sink_csv`, `sink_ndjson`, `sink_ipc` run the query in the streaming engine and
write the file, larger than memory, and return once it is written. Inside the engine, ordered output from
many workers goes through a linearizer over bounded per-worker channels (4 by default), keyed by morsel
sequence numbers.

**pandas.** `read_csv(path, chunksize=n)` or `iterator=True` returns a `TextFileReader`: iterable, with
`get_chunk(size)`, `close()`, and a context manager. Each chunk is a `DataFrame` of up to `n` rows whose
`RangeIndex` continues from the previous chunk. Parsing is lazy: the C parser tokenises only the rows the
chunk needs, so a malformed line raises `ParserError` while its chunk is read, after the earlier chunks
were returned, and the reader then closes itself. `engine="pyarrow"` refuses both options.

**Spark.** `toLocalIterator(prefetchPartitions=False)` yields `Row`s one partition at a time: one job per
partition, run when the partition is asked for (or one ahead with prefetch), "as much memory as the
largest partition", two with prefetch. An error in a later partition's job is raised when that partition
is reached. An iterator dropped early first drains the rest of its current partition, then tells the JVM
to stop.

**Arrow Flight.** `do_get` returns a `FlightStreamReader`, "a reader that can also be canceled"
(`cancel()`), whose server-side errors arrive on the read that reaches them.

What they agree on, and this design takes: the stream is pulled; the producer runs ahead by a bounded
buffer, in bytes; a late error arrives at the read that reaches it, after the rows before it; releasing
early ends the query; a cancel from another thread is a separate, thread-safe call; ordered output from
parallel workers is bought with sequence numbers and a bounded reorder window.

## 5. The model: bounded waves, pulled by the reader

### 5.1 The options

1. **Pull, one batch per `get_next`.** `get_next` runs the pipeline until one batch comes out. With a
   morsel-driven parallel executor this means a dispatch per batch, or one worker per stream. Either the
   parallelism or the dispatch cost is lost.
2. **Push into a bounded queue that blocks the producer.** A driver thread runs the plan as today, and the
   root sink's `consume` waits while the queue is full. This is DuckDB's shape. In komira it holds the
   context's one dispatch for as long as the reader takes, so a reader that pauses stops every other query on
   the context. A worker waiting inside `consume` also waits on something outside the engine. If that
   reader is itself the engine (`komira_register_arrow_stream` fed a komira stream, a Python `register`
   of a `Result` of the same session), the engine waits on itself. The runtime forbids exactly this for its
   own primitives ("a worker thread must not block on its own runtime").
3. **Bounded waves, pulled by the reader** (proposed). The root pipeline runs as a series of ordinary
   dispatches. In each, a worker takes a new claim only while a credit gate admits one, so the wave stops by
   itself once the queue plus the work in flight reach the bound. The reader's `get_next` hands out a queued
   batch, and runs the next wave when the queue is empty. Between waves no worker is busy and the
   dispatcher is free.

**Proposed: 3.** It keeps everything the executor guarantees today: `run_with_state` still returns only
after every shard, a worker never blocks, the order is still bought by sorting positions, and it is
parallel. It bounds memory by construction, because the gate is what admits work, so nothing has to
watch the memory and react. It is pull in the Arrow sense: nothing runs unless a reader asks. Between
waves the stream holds memory but no thread. The earlier engine had none of these: its result path was
eager, and its morsel driver's in-flight cap was never enforced.

The cost of 3 is that the engine is idle while the reader processes the batches of a wave. A read-ahead
driver that starts the next wave when the queue falls below half closes that gap, at the cost of one
thread per open stream and a release that must wait for the wave in flight. It is a later slice (S6) and a
decision for the owner (§11, D2).

### 5.2 How a streamed run works

**PROPOSED.** The engine-level object is a `StreamedRun` in `sdk_exec`, built by
`open_sql(ctx, text, control)` and `open_plan(ctx, plan, control)` beside today's `run_sql_with` and
`run_plan_with`.

1. **Open (the caller's thread).** Parse, bind, optimise and lower, exactly as today. Every refusal of
   those steps is still a status, and `*out` is untouched. The result schema is known from the lowered
   plan, and the export check (`check_record_batch_stream`'s type rules) runs on the schema. The run takes
   what it reads from the context into itself: the lowered plan, the opener and credentials it resolved,
   and its own footer cache (today `begin_query` replaces the context's cache at every query;
   `engine_context.mojo:126-128`). After open, the run reads no mutable context state. Nothing is
   claimed from any source yet.
2. **The breakers (the first `get_next`).** Every segment below the root runs as today, one dispatch
   each, in `run_plan`'s order. Their outputs are published as today.
3. **The root pipeline (each `get_next` that finds the queue empty).** The root segment is built once,
   with its source, its operators and a **delivery sink**, and then run in waves. A wave is one
   `run_with_state` over the same `SegmentRun`. The **claim gate** sits in the source, at the point where
   it takes a new claim from its cursor (for Parquet, `_claim` in
   `src/parquet_scan/parquet_source.mojo:551-572`, before `rg_cursor.fetch_add`). A claim is the unit the
   gate admits: one row group, or one row range of a split row group. A worker first drains the
   sub-morsels of the claim it already holds (the source parks them on the worker's pending slab and hands
   them out on the next calls), and only asks for a new claim when it holds none. So a gated worker never
   holds part of a claim. When the gate refuses a claim, `next_morsel` returns `None` as at the end of the
   input, and the source records which of the two it was (`is_exhausted()`). Today `None` means "never ask
   this worker again" (`src/pipeline_exec/README.md`); a source built with a gate may be asked again in a
   later wave. The wave ends when every worker has returned.
4. **Delivery.** The delivery sink is `CollectSink` without its concatenation: at the end of a wave it
   orders the wave's chunks by position (`position_order`, as `combine` does today), materialises a
   selection mask if there is one, drops empty chunks, and appends the batches to the delivery queue.
   `get_next` pops the queue's head and exports it as `get_next` does today: an array over the batch's
   shared buffers, with no copy.
5. **The end.** When a wave ends with the source exhausted, the run pushes the operator tails (the unmatched
   rows of a RIGHT or FULL join, `run_segment`'s `_push_tails`), then `finalize` runs and the run checks its
   pool is returned (`EXECUTE_POOL_NOT_RELEASED`, as today). The stream ends when the queue is empty after
   that. A wave that ended at the gate pushes no tails.

Nothing in the run waits on a reader, and the reader waits only on engine work: on a breaker segment, or on
one wave. That one property is what lets a reader pause, read from another thread, or feed the stream back
into the same engine.

### 5.3 The bound

The gate counts claims, not batches, because the source decides at the claim and a claim may yield several
batches. It admits a claim while

```text
held_claims + in_flight_claims < N   and   held_bytes + in_flight_estimate < B
```

- `held` is everything the delivery side holds: the chunks already pushed into the delivery sink during the
  wave, and the batches in the queue. A chunk is charged when the sink takes it, so the gate sees a wave's
  output as it grows, and the charge is returned when the reader pops the batch.
- A claim's estimate is the source's own size for it, read before the claim is taken: for Parquet, the
  next row group's (or row range's) uncompressed size from the footer. It is replaced by the claim's real
  output as that output reaches the sink.
- When nothing is held, the gate always admits one claim, so a claim larger than `B` still makes progress,
  as DuckDB's buffer admits one unit when empty.

So at any moment the root pipeline holds at most

```text
B + W × C     bytes, where W = workers and C = the largest output of one claim
```

plus what the breakers below hold, which the memory budget already bounds. `C` is what one claim
becomes after the operators:

- **A scan with filters and projections:** at most the claim's decoded size. The Parquet source decodes
  a whole row group before it cuts it into morsels (`parquet_source.mojo` header), so `C` is the largest
  decoded row group (or row range), which can exceed its uncompressed size in the footer for dictionary
  or run-length encoded columns; the estimate is corrected as the output arrives.
- **A keyed join probe** emits one batch as large as the fan-out of its morsel: only a CROSS join splits
  its output (`HAVE_MORE_OUTPUT`), and the keyed probes do not (`src/pipeline_exec/README.md`, Known
  limits). A keyed probe's `C` is therefore not bounded by the claim. Until the keyed probes split their
  output, **a root pipeline with a probe is refused by name in a streamed run** (§10, S1 and S8); the
  materialised calls still run it.
- **The tails of a RIGHT or FULL join** are pushed after the last claim, chunk by chunk, on the reader's
  thread. The tail push goes through the same gate: it stops when the queue is full and goes on at the next
  `get_next`.

Each run has its own segment pool today, sized by the context's memory budget
(`real_builder.mojo`, `set_memory_budget`), and a streamed run keeps one: the held bytes are charged to
it, so a stream counts against the same budget as its operators, and the end-of-run check
(`EXECUTE_POOL_NOT_RELEASED`) stays per run. A charge the pool refuses closes the gate (the queue drains
first) rather than failing the query, except when nothing is held, where the one admitted claim is charged
and a refusal fails with `MEMORY_BUDGET_EXCEEDED`, as an operator's refusal does today. Two open streams on
one context each have the whole budget, as two runs would; the bound is per stream.

**Proposed defaults:** `N` = 2 × workers, `B` = 64 MiB or a quarter of the memory budget, whichever is
smaller. Whether a caller may set them is decision D3 (§11).

No queue in this design is unbounded, and nothing watches memory at run time: the gate is the bound.

### 5.4 Order

**The rule.** A streamed result comes out in the order the same query's materialised result has today:

- **A scan, filter, project or probe pipeline** comes out in source position order, the order
  `CollectSink.combine` sorts by. For Parquet that is file order, then row group order, then the order
  within a row group, which is the order DuckDB gives with `preserve_insertion_order` on (its default),
  so B21's "same result as DuckDB" holds for the order too.
- **`ORDER BY`** comes out in the sort's order. The sort is a breaker (§5.6), so its output is complete
  before the first batch is handed out, and it is handed out in slices.
- **A grouped aggregate** has no specified group order today (`sink_group_agg.mojo`), and keeps none.

**How waves keep it.** Within a wave, the delivery sink sorts by position, as `combine` does. Across
waves, order holds if two things are true:

1. **Claims are monotone in position.** Every claim a later wave takes has a higher position than every
   claim of an earlier wave. That holds when each claim takes the next unit, in file order, from one atomic
   cursor.
2. **No wave ends with a claim half done.** The gate stops a worker only between claims, after the worker
   has drained the sub-morsels of the claim it holds (§5.2).

The Parquet source has several modes that break the first condition, and a streamed run builds it with
each one off:

- the cursor stride, which hands each worker a range of several claims at once
  (`src/parquet_scan/parquet_source.mojo:551-572`): a streamed run uses stride 1, one claim per
  atomic add;
- the claim order (`claim_order`, a permutation of the row groups, heaviest first): off, so claims go in
  file order;
- sharing parked sub-morsels between workers (`share_parked`): off, so a claim's sub-morsels stay with the
  worker that claimed it;
- top-N row-group pruning (`topn_prune`) and the cursor-grain route: off. Both reorder or regroup what a
  claim covers.

The row-range split of a large row group stays on. Its units are claimed in position order, one unit
per claim.

A root source that cannot claim this way (today every source but Parquet and a breaker's published
output) is refused by name in a streamed run (`STREAM_SOURCE_UNSUPPORTED: <source kind>`) until it can.
The ordered delivery then needs no reorder window beyond the wave. The cost is one atomic add per claim
instead of one per stride, and the scheduling those modes bought.

**An unordered stream** (deliver each morsel as it finishes, in any order) is not offered. It would be
faster only by the wait for the slowest morsel of a wave, and it would make a streamed result differ
from the materialised one. Decision D4 (§11) keeps it open.

### 5.5 LIMIT

Today a `LIMIT` without `ORDER BY` is exact in count but not in which rows survive. With several workers,
whichever worker reached the shared budget first keeps its rows (`op_limit.mojo`), and the other workers'
scans keep running after the budget is spent (`src/pipeline_exec/README.md`, Known limits). A limit that
is not over a sort is lowered into the pipeline as an `OP_LIMIT` (`cut_limit.mojo`).

In a streamed run, **a limit that is the last operator of the root pipeline** is taken out of the pipeline
by the lowering and given to the delivery sink instead. Delivery counts the rows it hands out in position
order, slices the batch that crosses `n`, and then ends the stream: no further wave runs, and the run is
released as on an early release (§5.8). So that `LIMIT` returns the first `n` rows in file order, which
DuckDB returns too, and reads no more than one wave past them.

A limit with an operator above it in the same pipeline stays an operator. It keeps today's behaviour:
exact in count, and the rows that survive depend on the schedule. A `LIMIT` over a sort is the top-N
breaker, as today. The lowering change is part of S1; the lowering library is the second package that
slice touches.

### 5.6 What does not stream by nature

A breaker finishes before its output exists: a sort, a top-N, a grouped or ungrouped aggregate, a
`DISTINCT`, a window, and a join's build side. When the root segment's input comes from one of them, the
stream waits for it:

- **The first `get_next` returns only after the breakers below the root have finished.** For
  `SELECT region, sum(x) FROM t GROUP BY region` the whole scan and aggregation happen inside the first
  `get_next`. The answer is then handed out batch by batch over the aggregate's published output.
- **Meanwhile** `komira_run_progress(run, &done, &total)` counts segments as today, and
  `komira_run_cancel(run)` stops the run at its next check. That is the next morsel inside a breaker's
  pipeline. A breaker's `combine`, sort or merge does not check the token today, so a cancel that lands
  there waits for it to finish.
- **Memory** for these queries is what the breakers hold, as today. Streaming saves only the collect
  sink's copy of the root output, about half the peak today (§3).
- **A root segment that is itself a breaker** (a final `ORDER BY` or aggregate with no pipeline above it)
  publishes one batch at `take_output`. The stream hands it out in slices of the morsel size, each a view
  of the same buffers.

The Python and Node bindings pull the first batch inside `sql()` (§7.1), so for these queries `sql()` waits
for the breakers as it waits today.

### 5.7 Errors after the first batch

**The rule.** An error while producing the claim at position `p` is handed out after every batch from a
claim below `p`, and before any batch from `p` or above. Where each claim yields one batch, the error
raised while producing batch `N` is returned by the `N`th `get_next`, and not before. Where a claim yields
several batches, `N` counts claims, not batches.

**How.** Today a worker's error cancels the segment: `SegmentRun.fail` records the first error in time
(`set_error_cas`) and calls `pipeline.cancel()`, which `should_stop()` reads, so the other workers drop
their morsels mid-way (`segment_task.mojo:74-82`). A streamed run changes that:

- A worker's error records `(p, error)` in a slot that keeps the **lowest position**, not the first in
  time, and closes the gate. It does not cancel the pipeline: `should_stop()` stays true only for the
  run's token.
- The other workers finish the claims they hold, sub-morsels included, and take no more.
- An error in `next_morsel` itself (a decode error) is recorded at the claim the source was producing.
- Every claim below `p` was taken before `p`, because claims are monotone (§5.4), so when the wave ends
  every claim below `p` has finished. The delivery sink queues those batches, then the error. It discards
  every chunk from `p` (including any the failing claim pushed before it failed) and above.
- When two workers fail in one wave, the error at the lower position wins. That is deterministic, where
  today's first error in time is not. The error costs at most one claim per worker of extra work.
- An error in the tails or in `finalize` comes after every claim.

A cancel is not an error at a position. It stops every worker at its next check, and the stream hands out
nothing more (§5.8).

**What the reader sees.** `get_next` returns `EIO` and `get_last_error` returns
`<CODE>: execute: <reason>`, the text today's run calls put in the context's last error
(`MEMORY_BUDGET_EXCEEDED: execute: ...`). Every later `get_next` returns the same code and text: a failed
stream stays failed. The reader must still call `release`.

This replaces, for streamed runs only, the rule "no partial result" with a narrower one: **a stream never
hands out a batch after an error, and never ends normally after an error.** A reader that reads to the end
without an error has the whole answer. A reader that wants all or nothing reads everything before using any
of it, which is what `to_arrow()` does (§7.1).

### 5.8 Cancel and release

- **`komira_run_cancel(run)`** from any thread, at any time, as today. A `get_next` that is running a
  wave or a breaker returns `ECANCELED` once the workers reach their next check (the next morsel, or the
  next chunk of an emitting operator). `get_last_error` then returns
  `QUERY_CANCELLED: execute: pipeline_exec: the query was cancelled: the caller cancelled the run`,
  today's cancel text (`src/so/tests/c/abi_driver.c`). A `get_next` after the
  cancel returns the same, without running anything. A cancel after the stream ended does nothing.
- **`release` before the end** ends the run. Release is called by the reader, never concurrently with
  `get_next` (the Arrow rule). With waves pulled by the reader, no wave is running when release is called,
  so release has nothing to wait for. It cancels the run's token (so a breaker's spill files and the like
  see a cancel), and frees, before it returns:
  - the queued batches and their pool charge;
  - the root segment's state: the delivery sink's slots, each operator's state, the source with its claim
    cursor, its open files and mappings, and its prefetch buffers;
  - the published outputs of the breakers below that the root has not consumed;
  - the run's footer cache, opener, credentials and lowered plan;
  - its share of the run handle's control, and its share of the engine core (§5.10).
  After release the source is read no more: zero bytes, by construction, since no wave can start. The
  Parquet source gives the operating system an advisory read-ahead hint for the next row group at the end
  of each claim (`_prefetch_next`). In a streamed run the hint is given only for a claim the gate has
  admitted, so a wave that stops at the gate leaves no hint for unread data.
- **Arrays already handed out** stay valid after release, as today: each owns its share of the buffers.
- **The run handle** may be freed while the stream is open, because the stream holds its own share of
  the handle's control. `komira_run_free`'s rule "only once no call given it is running" is unchanged:
  `komira_sql_open` has returned.

With the read-ahead driver (S6), release cancels and waits for the wave in flight, which ends after at
most one claim per worker: so at most `W` more claims are read after release begins.

### 5.9 Many runs on one context

Today Python holds its session lock for the run call only, and reading a `Result` takes no lock
([python_package.md](python_package.md), "a `Result`'s batch reads take no lock"). So
`r1 = s.sql(a); r2 = s.sql(b); r1.to_arrow()` works, and so does reading `r1` on one thread while
`s.sql(b)` runs on another. Streamed results keep both:

- **The dispatcher is lent per wave (PROPOSED: a dispatch lock).** One dispatch at a time per dispatcher
  stays the runtime's rule, and today nothing in libkomira needs a lock for it, because Python's session
  lock and Node's session thread serialise every run. With streams, two readers on two threads may each
  want a wave. A **dispatch lock** in the engine core serialises them. A run takes it for one wave or one
  breaker segment and gives it back between them. It is taken only by reader threads, never by a worker
  (a worker blocking on its own runtime is the hazard [async_runtime.md](async_runtime.md) rules out). The
  wait for it watches the run's token, so a `get_next` waiting for the lock still returns `ECANCELED` on a
  cancel. A run that wants the dispatcher waits for the wave or segment in progress. That is engine work,
  never a reader.
- **Two open streams on one context** interleave by waves. A third query runs between their waves.
- **A run reads no mutable context state after open** (§5.2), so registering a table, adding a binding or
  starting another query while a stream is open does not change what the open stream reads. It reads the
  catalog as it was when it opened.
- **A stream fed back into the engine** (`komira_register_arrow_stream` given a komira stream, Python's
  `register(name, result)`) is drained whole by the registering call into the registered table, as any
  registered stream is (`src/so/sources.mojo`). Its `get_next` calls run waves on the same dispatcher,
  taking the dispatch lock per wave. The registering call holds the session (Python takes its session
  lock) but not the dispatch lock while it reads, so the two do not wait on each other. The table it
  registers is materialised, as every registered stream is.

The cost: a long breaker in one run holds back every other run on the context for its duration. That is
already the case today, since runs on one context are serialised.

### 5.10 What the stream owns

The stream must outlive the context (`komira_ctx_free` may come first today, and §5 of
[libkomira_run_abi.md](libkomira_run_abi.md) requires the stream to hold an `ArcPointer` on any state it
needs that `komira_ctx_free` tears down). A streamed run needs the worker runtime with its dispatcher, and
the dispatch lock; its segment pool is its own. These move into an engine core held by `ArcPointer`: the
context holds one share and each open stream holds one. `komira_ctx_free` drops the context's share. The
core, and with it the worker threads, stops when the last share is dropped: by the context, or by the
release of the last stream.

The thread that drops the last share joins the worker threads, which are idle between waves, so the join
waits on nothing else. That thread is never a worker. It may be a garbage collector's: pyarrow releases an
imported stream when the reader is collected, with the GIL held. No worker ever needs the GIL, because
Python UDFs run in worker processes ([udf_python_worker.md](udf_python_worker.md)), so that join cannot
wait on the GIL. The Node addon's finalizer hands the release to the session's native thread rather than
running it on the event loop.

## 6. The C interface

### 6.1 One shape, two new calls

The result stays an Arrow C stream (`struct ArrowArrayStream`), allocated by the caller and filled by
libkomira. That is the one shape every Arrow consumer imports: pyarrow, Arrow C++, arrow-rs, DuckDB,
polars, ADBC. Only when it is produced changes. Two new calls return it before the run:

```text
version	1.12
komira_sql_open	Int32	Handle,CStr,Handle,ArrowStream	1.11
komira_plan_open	Int32	Handle,ConstBytes,UInt64,Handle,ArrowStream	1.12
```

(After S1 alone the version line reads `1.11` and only the first row is there.)

```c
int32_t komira_sql_open(komira_handle ctx, const char *sql, komira_handle run,
                        struct ArrowArrayStream *out);
int32_t komira_plan_open(komira_handle ctx, const uint8_t *plan, uint64_t plan_len,
                         komira_handle run, struct ArrowArrayStream *out);
```

The rows are in the golden's form (`symbol<TAB>return<TAB>arguments<TAB>since`, `src/so/abi/komira.tsv`).
No existing row changes, and no constant or status code is added. The errno values the stream returns
come from a C shim, as today (rule M8).

**Why new calls, and not new behaviour behind the old ones.** Three reasons. Each would break a binding that
is already shipped:

1. **The status contract.** A binding of `komira_sql_stream` today learns of an execution error from the
   call's status, with the code and step in `komira_last_error_code` and `komira_last_error_step`. A
   stream that returns `KOMIRA_OK` and fails later would turn every such error into an `EIO` from
   `get_next`, which the shipped Python and Node packages do not expect: Python would raise a pyarrow
   `OSError` from a read instead of a `KomiraError` from `sql()`, and both would lose the code and step.
   That is a silent re-meaning of a shipped call, which rule B8 rules out.
2. **The plan door has no run handle.** `komira_plan_stream` cannot be cancelled today, and a stream that
   runs after the call returns needs a cancel that does not depend on reading it.
3. **Lifetime.** A materialised stream holds batches and nothing else. A streamed one holds an engine core
   and a share of a run. A caller that relied on the old calls finishing their work before they returned
   (for example, timing a query by the call) keeps that.

Not chosen: **a handle of our own** with `next`, `cancel` and `progress` calls. The run handle already is
the cancel and progress half, and the Arrow stream already is the `next` half. A third type would be a
second way to read a result, and no consumer could import it.

### 6.2 What `komira_*_open` does

The order of checks is `komira_sql_stream_run`'s:

1. A NULL `ctx` returns -1.
2. The last error is cleared.
3. A NULL `sql`, `plan` or `out` returns -2. A NULL `run` is allowed: the stream then has no out-of-band
   cancel, and release is still a cancel.
4. The length checks of today's calls (-5).
5. Parse, bind, optimise, lower, and the export check of the result schema. A refusal returns -3 (or -6
   if `run` was already cancelled), with the code, step and text in the context's last error, exactly as
   today. `*out` is untouched.
6. `*out` is filled, and the call returns `KOMIRA_OK`. **No source has been read.**

`COPY ... TO` through `komira_sql_open` is refused by name (`STREAM_COPY_UNSUPPORTED`) until the
streamed writer of §8 lands, because its answer is one `Count` row whose meaning is "the file is written",
which an open call cannot promise.

### 6.3 The stream's callbacks

| callback | before the first batch | while reading | after the end, an error or a cancel |
|---|---|---|---|
| `get_schema` | returns the result schema from the plan, without running anything | the same schema | the same schema |
| `get_next` | runs the breakers and the first wave, then returns batch 1 | returns the next queued batch, or runs a wave when the queue is empty | at the end: 0 and a released array, every time. After an error: `EIO`, every time. After a cancel: `ECANCELED`, every time |
| `get_last_error` | NULL | NULL | the text of the error or cancel, valid until the next callback or `release` |
| `release` | ends the run, frees everything (§5.8) | the same | frees what is left; idempotent |

- **`get_schema` before any batch** needs a schema built from types alone. Today a nested column (LIST,
  STRUCT, MAP, UNION) needs a sample batch, because its child types come from the column
  (`c_data_stream.mojo:2880-2903`). The streamed export builds nested child formats from the plan's own
  result types. Until it does, `komira_*_open` refuses a result with a nested column by name
  (`STREAM_NESTED_RESULT_UNSUPPORTED: ...`), and the old calls keep serving it.
- **`EINVAL`** for a NULL argument or a call on a released stream, as today.
- **A batch with no rows** is never handed out: an empty answer is its schema, then the end.
- **A batch's size** is one morsel's output, at most one row group or `M` rows. Batches are not coalesced in
  the first slices.

### 6.4 Threads

- **One reader at a time.** `get_schema`, `get_next` and `release` are serialised by the reader (the
  Arrow rule). They may be called from any thread, one after another.
- **`komira_run_cancel` and `komira_run_progress`** may be called from any thread, at any time, also while
  a `get_next` is running. That was already true of the run call.
- **`get_next` blocks** for a wave or a breaker. It holds no lock of the context while it waits for the
  dispatch lock, and no lock at all while the wave runs except the dispatcher's own.
- **The context.** `komira_ctx_free` may run before the stream is read or released (§5.10).
- **The library stays loaded** while a stream is live, as today: the callbacks are its code.

### 6.5 The existing calls

`komira_sql_stream`, `komira_sql_stream_run` and `komira_plan_stream` keep their contract: the answer is
computed before the call returns, every execution error is a status, and `*out` is written only on
`KOMIRA_OK`. In slice S7 they are rebuilt inside libkomira as open-then-drain on the calling thread, so
there is one run mechanism. The drain keeps the batches in a list and builds today's stream over it, so
for these calls the change is invisible except that:

- the answer arrives as one batch per morsel instead of one concatenated batch, which saves the
  concatenation's copy and half of the peak (§3);
- a `LIMIT` that is the last operator of the root pipeline returns the first `n` rows in file order
  (§5.5), which matches DuckDB where today's result may not.

### 6.6 Versions and bindings

- `komira_sql_open` lands as 1.11 and `komira_plan_open` as the next minor (1.12 if nothing else lands
  between). A row's `since` is the version of the change that lands it on `main`, so the numbers move if
  other rows land first. Each change raises `ABI_MINOR`, the `gate_version` pin and the export list
  (`gate_no_extra_exports.mojo`), adds the `abi_driver.c` cases, and regenerates `komira.h`.
- **Older library, newer binding.** A binding that finds no `komira_sql_open` falls back to
  `komira_sql_stream_run`, so the user gets the answer, materialised, as before. The binding checks each
  symbol at its first use ([libkomira_run_abi.md](libkomira_run_abi.md) §11).
- **Newer library, older binding.** An older binding never calls the new symbols, and the old calls keep
  their contract (§6.5).
- **The cross-version tests** are the existing stand-in library of the previous minor
  (`node/tests/fake_libkomira.c`) and its Python counterpart, run with a binding of each version (§9,
  `binding_falls_back_when_the_library_has_no_open_call`).

## 7. The SDKs

### 7.1 Python

- **`Session.sql(query)`** calls `komira_sql_open` when the library has it, and then **pulls the first
  batch before it returns**. So an error before the first batch (every parse, bind, optimise and lower
  refusal, and every execution error of a breaker below the root) still raises `KomiraError` with its code
  and step from `sql()`, as today. A query that finds nothing returns at once. Only an error after the first
  batch is raised later, by whichever read reaches it. The batch pulled is kept and handed out first. The
  pull runs on the helper thread that runs `komira_sql_stream_run` today (`python/komira/_run.py`), so
  Ctrl-C still cancels through the run handle. Decision D5 (§11) weighs the alternatives.
- **The run handle lives as long as the `Result`.** Today `_Call.finish` frees it before the `Result` exists
  (`_run.py:110-120`). In a streamed `Result` the handle is kept, so a Ctrl-C during a later read cancels the
  run.
- **`Result.to_reader()`** returns a `pyarrow.RecordBatchReader` that streams. To keep komira's error
  type, it wraps the imported reader: `pa.RecordBatchReader.from_batches(schema, gen)`, whose generator
  calls `read_next_batch()` and turns pyarrow's `OSError`/`ArrowInvalid` into `KomiraError`. The code and
  step are read from the text's `<CODE>: <step>: ` prefix, and `ECANCELED` becomes the cancelled status.
  The generator reads the next batch on the helper thread too, so a Ctrl-C during a long wave raises
  `KeyboardInterrupt` and cancels the run, as it does in `sql()`.
- **`to_arrow()`, `to_pandas()`, `to_polars()`** read everything and are all or nothing. A late error
  raises and returns nothing, as today.
- **`__arrow_c_stream__`** hands the raw stream to DuckDB, polars or pyarrow, which read it lazily. Errors
  are then theirs to raise.
- **`_repr_html_`** reads only the first rows it shows (`_read_head`), so for a streamed result it reads
  one or two waves, not the whole answer.
- **The pandas DataFrame path** (`DataFrame.materialize()`) and `komira.pl`'s `collect()` go through the
  plan door, so they stream only once `komira_plan_open` lands (S3).
- **GIL.** pyarrow calls `get_next` with the GIL released. Python UDFs run in worker processes, not
  in-process ([udf_python_worker.md](udf_python_worker.md)), so a wave never waits on the reader's
  interpreter, and release needs no GIL care.

**`read_csv(path, chunksize=n)` and `iterator=True`.** pandas returns a `TextFileReader`. It iterates over
chunks of `n` rows, has `get_chunk(size)` and `close()`, is a context manager, and each chunk is a pandas
`DataFrame` with a `RangeIndex` that continues across chunks. komira's form:

- `read_csv(path, chunksize=n)` or `iterator=True` returns `komira.TextFileReader`, with `__iter__`,
  `get_chunk(size=None)`, `close()` and `with`. It opens one streamed run of the file's scan, with the
  column types the engine infers today. It cuts the stream's batches into chunks of exactly `n` rows by
  slicing, and joins slices only across a batch boundary. A malformed line in chunk `N` raises when chunk
  `N` is read, and the reader then closes, as pandas' does. `chunksize < 1` raises pandas' `ValueError`.
- **What a chunk is.** pandas' chunk is a pandas `DataFrame`. The task examples run with only pyarrow and
  protobuf installed (`python/docs/tasks/BUCK`), so komira cannot return a pandas frame there. The options
  are a `pyarrow.Table`, a komira `DataFrame` over the chunk's rows, or a pandas `DataFrame` that needs
  pandas. Decision D6 (§11). Proposed: a komira `DataFrame`, the type `read_csv` returns without
  `chunksize`, so the same verbs run on a chunk. That needs a frame over rows in memory, which the plan
  wire does not have yet ([dataframe_surface_verbs.md](dataframe_surface_verbs.md), `scan_in_memory` not
  built). komira frames have no index ([dataframe_surface.md](dataframe_surface.md)), so pandas'
  continuing `RangeIndex` has no counterpart.
- **Prerequisite:** a CSV source that streams (S4). Today the CSV source decodes the whole file before the
  first morsel, so a chunked read would read the whole file before its first chunk.

**polars (`komira.pl`).**

- `LazyFrame.collect(engine=...)` takes `"auto"`, `"streaming"` and `"in-memory"`, which all run the same
  engine, and refuses `"gpu"` by name. It still returns a `Result`.
- `LazyFrame.collect_batches(chunk_size=None, maintain_order=True)` returns an iterator over the
  streamed run, with chunks of the type D6 picks. `maintain_order=False` is refused by name until an
  unordered stream exists (D4). It lands with D6.
- `sink_parquet`, `sink_csv` and `sink_ndjson` already write through the engine, with no row returned to
  Python. They stream their writes when §8 lands, with no change to their signatures.

### 7.2 Node

`Result` keeps its two reads (`node/src/result.ts`). The addon's `sql` calls `komira_sql_open` and pulls
the first batch on the session's native thread before the promise settles, for the reason given for Python.
It then keeps the stream instead of draining it.

- **`for await (const batch of result)`** runs each `get_next` on the session's native thread and settles one
  promise per batch.
- **`return()`** (a `break` out of the loop) releases the stream, which ends the run.
- **`toArrow()`** reads everything.
- **`sql(query, { signal })`**, the cancel the TypeScript design already plans
  ([typescript_package.md](typescript_package.md), "Cancellation"), binds the run handle. An abort while
  reading rejects the pending `next()` with the cancelled `KomiraError`.

### 7.3 Mojo

The Mojo SDK's design is pull request komira-ai/komira#2496. Its `Result` lends one
materialised batch (`batch()`, a `ref [self] RecordBatch`) over `run_sql`. The streamed form is a second
type beside it, not a change to `Result`:

```mojo
struct ResultStream(Movable):
    def schema(self) -> Schema
    def next(mut self) raises -> Optional[RecordBatch]   # None at the end; raises KomiraError late
    def cancel(self)                                     # any thread, through a shared RunControl
    # dropping it before the end ends the run, as release does
```

`Session.sql_stream(query: String) raises -> ResultStream` wraps `sdk_exec.open_sql` directly, in
process, with no C call. It lands after S1, in the Mojo SDK's own slice, with a README example (rule T18).

## 8. Writes

**EXISTS.** `COPY ... TO` and the SDK writers (`to_csv`, `to_parquet`, `sink_*`) do not stream today.
They run the query to one batch, encode the whole file in memory (Parquet with `parquet_writer`, CSV and
JSON with `engine_write_text`, and gzip or zstd compressed whole), and write it with `write_file_atomic`:
a temporary file in the destination's directory, synced and renamed (`src/sdk_exec/engine_write.mojo:5-12`).
A failure leaves the destination as it was.

**PROPOSED (S5).** A write is a streamed run whose reader is a writer inside the engine. It is the same
`StreamedRun`, the same waves and the same bound, without the C stream. The writer opens the temporary file
first. It then appends each batch as it arrives: Parquet row groups of `DEFAULT_MAX_ROWS_PER_RG` rows,
CSV or NDJSON lines through a streaming gzip or zstd encoder. At the end it writes the footer, syncs and
renames, then answers its one `Count` row. On an error or a cancel it deletes the temporary file, and the
destination stays as it was. The guarantee "all or nothing" is unchanged, and the memory is the stream's
bound plus one row group, instead of the answer plus its encoded file. The writers' order is the stream's
order (§5.4).

So writes share the mechanism (the streamed run) and not the interface (the C stream). The write's
reader is in the engine, so the wave loop runs on the run call's thread, and the call returns when the file
is renamed.

## 9. Tests

Every test is hermetic (T12) and asserts no time (T10). "First", "before" and "after" are counted:
bytes, claims, batches, events. The engine tests run under `src/pipeline_exec/tests` and
`src/sdk_exec/tests`. The C tests run in the C driver (`src/so/tests/c/abi_driver.c`), and the binding
tests in `python/tests` and `node/tests`. Two test-only parts make the counts possible:

- **A generated source.** A `pipeline_exec` source that makes each morsel from its index (a counter
  column, `R` rows of 8 bytes) and stores nothing. It counts its claims and the bytes it has made, can
  fail at a chosen index, and can wait at a chosen index on an event the test sets. "A 10 GB scan" is
  10 GiB / 1 MiB = 10,240 morsels of 1 MiB from it, generated and never held.
- **A counting opener.** The run already takes an opener (`run_sql_with`). A test opener over the
  scratch directory counts every byte read and every file opened and closed.

### 9.1 The four tests that prove the promise

- `first_batch_arrives_before_the_scan_ends`. A streamed run over the 10 GiB generated source with `W`
  workers. At the moment `get_next` returns batch 1, the source has made at most `B + W × 1 MiB` bytes and at
  most `N + W` claims, and fewer than 10,240. The same over a Parquet file of 64 row groups written to scratch
  by the test: at the first batch the counting opener has read the footer and at most `N + W` row groups.
- `peak_memory_is_the_queue_bound_not_the_input_size`. The same 10 GiB source read to its end, one batch per
  `get_next`. After every `get_next`, the run's accounted peak (a high-water mark the segment pool gains,
  plus the queue's bytes) is at most `B + W × 1 MiB`. A second run over a 1 GiB source has the same peak:
  the bound depends on `N`, `B` and `W`, not on the input.
- `early_release_stops_reading_the_source`. Read 3 batches, record the claims and the bytes read, then
  release. Afterwards: no further claim, no further byte read, every file the opener opened is closed, the
  pool's granted bytes are 0, and an array taken before the release still reads its values.
- `an_error_in_batch_n_arrives_on_the_nth_get_next`. The generated source (one batch per claim, claims
  numbered from 1, `W` = 4, the real dispatcher) fails at claim 37. Calls 1 to 36 return batches whose
  first values are `0, R, 2R, ..., 35R` in order. Call 37 returns `EIO` with `get_last_error` exactly
  `GENERATED_SOURCE_FAILED: execute: claim 37`. Call 38 returns the same code and text. The error is not
  seen before call 37.

### 9.2 The rest of the contract

- `schema_is_known_before_any_claim_is_taken`: after open, `get_schema` returns the plan's schema, and
  the source has 0 claims.
- `a_lower_position_error_wins`: the source fails at claims 40 and 38 in one wave, the failure at 40
  first, with workers run in an order a fake dispatcher chooses (`fake_dispatch.mojo`). The stream hands out
  37 batches, then claim 38's error.
- `an_error_discards_the_failing_claims_own_chunks`: a claim that yields three batches fails after its
  second. Neither of its batches is handed out; the error follows the batches of the claims below it.
- `cancel_from_another_thread_ends_a_waiting_get_next`: the source signals an event when a worker reaches
  claim 5, then waits there on a second event. Thread A's `get_next` is running the wave. Thread B waits for
  the first event, calls `komira_run_cancel`, then sets the second. A's `get_next` returns `ECANCELED` with
  exactly `QUERY_CANCELLED: execute: pipeline_exec: the query was cancelled: the caller cancelled the run`,
  and the next call returns the same.
- `a_get_next_waiting_for_the_dispatch_lock_is_cancellable`: stream 1's wave is held at an event, stream 2's
  `get_next` waits for the lock, a cancel of stream 2's run makes it return `ECANCELED`, and stream 1 then
  reads to its end.
- `batches_come_out_in_position_order_whatever_the_schedule`: workers finish in reverse order (fake
  dispatcher). Every batch's positions increase across waves.
- `a_row_group_larger_than_a_morsel_keeps_its_order`: a Parquet file whose row groups are four morsels each,
  with `N` small enough that the gate closes in the middle of the file. The rows come out in file order, and
  no wave ends with a worker holding a parked sub-morsel.
- `the_scheduling_modes_are_off_in_a_streamed_run`: a streamed Parquet scan builds its source with stride 1,
  file claim order, no parked-morsel sharing, no top-N pruning and no cursor-grain route.
- `a_root_source_that_cannot_claim_in_order_is_refused_by_name` (a CSV file in S1:
  `STREAM_SOURCE_UNSUPPORTED: csv`), and `a_root_probe_is_refused_by_name` until the keyed probes split
  their output.
- `a_streamed_limit_returns_the_first_rows_and_stops_claiming`: `LIMIT 1000` over the generated source
  returns its first 1000 rows and ends, with at most `N + W` claims. With a projection above the limit, the
  limit stays an operator and only the row count is asserted.
- `an_order_by_hands_out_its_sorted_output_in_slices`: the first `get_next` returns after the sort segment
  (progress shows it done), and the concatenated batches equal the materialised answer.
- `a_cancel_during_a_breaker_returns_ecanceled_on_the_first_get_next`: the same cancel test with the
  source waiting below an aggregate.
- `the_stream_outlives_its_context`: `komira_ctx_free` after open and after batch 1, then the stream is read
  to its end and released, and its arrays are read after that.
- `two_streams_and_a_query_share_one_context`: two open streams read alternately, and a third query runs
  between their waves. Each answer equals its materialised answer.
- `a_komira_stream_registered_into_its_own_context`: `komira_register_arrow_stream` given a stream from
  the same context completes, and the registered table equals the answer.
- `releasing_the_last_share_from_a_finalizer_joins_cleanly`: a Python test drops the context, then lets the
  garbage collector release the last open stream's reader. The worker threads are joined, and the
  process's thread count returns to what it was before the session.
- `an_empty_answer_is_its_schema_then_the_end`, `a_nested_result_is_refused_by_name_at_open`,
  `copy_through_open_is_refused_by_name`.
- The lifetime cases carried from the earlier engine (§2.3), run against a stream that is still
  producing: every buffer read after release in the three release orders, and a thousand open, read and
  release cycles with the pool back at 0.
- **C interface:** the golden rows, the `gate_version` pin, the export list, the `abi_driver.c` cases for
  each status of §6.2, and `binding_falls_back_when_the_library_has_no_open_call` (the binding of this
  version against the stand-in library of the previous minor).
- **Python:** `sql_raises_for_an_error_before_the_first_batch`,
  `to_reader_raises_komira_error_for_a_late_error` (the exact message),
  `ctrl_c_during_a_read_cancels_the_run`, `repr_reads_only_the_rows_it_shows` (by the run's claim
  count, read through a test hook), and later the `read_csv` chunk cases: exact chunk sizes across batch
  boundaries, `get_chunk(size)`, a malformed line in chunk 3 raising at chunk 3, and `with` closing the run.
- **Node:** `breaking_out_of_the_iterator_ends_the_run`, `abort_while_reading_rejects_next`, and
  `a_collected_result_is_released_on_the_session_thread`.

### 9.3 Why this list is complete

Each promise of §5 and §6 has a test that fails when the promise breaks. The bound (first batch, peak)
has two. Early stop has release, `LIMIT` and `break`. Late errors have the `N`th call, the lower
position, the failing claim's own chunks and stickiness. Cancel has four: from another thread, while
waiting for the dispatch lock, during a breaker, and through Ctrl-C. Order has the schedule test and the
split row group, and the source modes that would break it have their own. There are also tests for the
schema before running, what cannot stream, the refused sources and probes, lifetime against the context,
against release and against a finalizer, concurrency on one context, feeding a stream back into the
engine, the empty and refused cases, both directions of version skew, and each binding's own mapping.
The boundaries are an empty answer, one batch, a claim larger than `B` (the always-admit rule, checked
inside the peak test with `B` set below one claim), an error in the first claim, a cancel before the
first wave, and a release before the first `get_next`.

## 10. Slices

- **S1, one streamed query end to end.** `StreamedRun` and `open_sql` in `sdk_exec`. The root-segment
  waves, the position-keyed error slot and the delivery sink in `pipeline_exec`. The claim gate and the
  streamed build of the Parquet source (§5.4's modes off) in `parquet_scan`. The trailing limit handed to
  delivery, in `lowering`. The run's own footer cache, the engine core and its dispatch lock.
  `komira_sql_open` (ABI 1.11) and the stream callbacks over a `StreamedRun`. Scope: SQL whose root
  segment reads Parquet or a breaker's output through filters, projections and a limit. Any other root
  source, a probe in the root pipeline, a nested result and `COPY` are refused by name. Tests: §9.1, and
  from §9.2 every engine and C-interface case. Defaults `N` and `B` fixed in code. Python and Node do not
  call it yet, and the C driver is the reader.
- **S2, Python and Node read streams.** `sql()` through `komira_sql_open` with the first-batch pull, the
  run handle kept by the `Result`, `to_reader()`'s wrapper, Ctrl-C, Node's iterator and its `signal`.
  The docs that say `to_reader()` reads only what is asked change with it.
- **S3, the plan door.** `komira_plan_open` (ABI 1.12) and `open_plan`. `DataFrame.materialize()`,
  `komira.pl`'s `collect()` and `collect(engine=...)` stream.
- **S4, a CSV source that streams.** Claims byte ranges cut at line ends, decodes one range per morsel,
  and keeps types inferred at open. Then `read_csv(chunksize=n)` and `iterator=True` once D6 is decided,
  with `collect_batches` beside them.
- **S5, streamed writes.** `COPY ... TO` and the SDK writers as a streamed run with an in-engine writer
  (§8). `COPY` through `komira_sql_open` stops being refused.
- **S6, read-ahead.** A driver that starts the next wave when the queue falls below half (D2), with a
  benchmark that shows what it buys.
- **S7, one mechanism.** The old run calls rebuilt as open-then-drain (§6.5). `CollectSink`'s
  concatenation stays only where a breaker's input needs one batch.
- **S8 and after.** The keyed join probes split their output into chunks, as CROSS does, and probes stop
  being refused in a streamed root. The JSONL and Iceberg sources stream. A nested result schema is built
  from the plan. A cancel check inside a sort, merge and combine. The Mojo SDK's `ResultStream` (§7.3).

S1 is one subject, the engine with the call that exposes it. It touches five packages (`pipeline_exec`,
`parquet_scan`, `lowering`, `sdk_exec`, `so`); this document is its design (rule B22). Each later
slice lands alone in that order. S4's CSV source and S5's writer do not depend on each other.

## 11. Decisions for the owner

**D1. Which model.**
- (a) Bounded waves pulled by the reader (§5.1, option 3). Fits the fork-join executor unchanged, and no
  thread waits on a reader. Release frees everything at once. The cost: the engine idles while the reader
  works.
- (b) Push into a blocking bounded queue, with a driver thread. The engine overlaps with the reader. The
  cost: one thread per stream, and a paused reader holds the context's dispatcher. A stream read back into
  its own context can deadlock, and release must wait for workers.
- (c) Pull one batch per `get_next`. Simple. The cost: no parallelism, or a dispatch per batch.
- **Recommended: (a)**, with (b)'s overlap recovered by D2 if a benchmark asks for it.

**D2. Read-ahead.**
- (a) None: waves run inside `get_next` only.
- (b) A driver thread per open stream runs the next wave while the reader works. The cost: a thread per
  stream, and release waits for at most one claim per worker.
- **Recommended: (a) in S1, and (b) as S6 only if a benchmark of a slow reader shows the idle time
  matters.**

**D3. Who sets the bound.**
- (a) Fixed by the engine (`N` = 2 × workers, `B` = min(64 MiB, budget / 4)).
- (b) A context option, added to `komira_ctx_new_with_options` as a new constructor. The cost: a new
  row, and a knob users must understand.
- (c) Per run, on the run handle. The cost: a setter call, the most flexible.
- **Recommended: (a)**, and (b) only when a user shows a case the default serves badly. B20 asks for no
  speculative knob.

**D4. An unordered stream.**
- (a) Never: a stream's order is the materialised order.
- (b) An opt-in, such as polars' `maintain_order=False`, that hands out each morsel as it finishes. The
  cost: a second delivery path and a result that differs from DuckDB's with the default settings.
- **Recommended: (a) until a measurement shows the wave's slowest morsel costs enough to matter.**

**D5. When Python's and Node's `sql()` returns.**
- (a) At open: every execution error moves to the reads. The cost: today's code that catches errors
  around `sql()` misses them, and the error type changes unless every read wraps it.
- (b) After the first batch (proposed): errors before the first batch stay at `sql()`, with the code and
  step. The cost: `sql()` does one wave, or the breakers, even if nothing is read, and the error of a
  later batch is raised by a read.
- (c) Materialised by default, with streaming opt-in (`sql(q, stream=True)` or `Session.stream(q)`).
  The cost: two ways to run a query, and most users never stream.
- **Recommended: (b).** It matches what DuckDB users see for an immediate error, keeps the existing tests'
  contract for every error a query meets before it produces rows, and streams by default.

**D6. What a `read_csv(chunksize=n)` chunk is.**
- (a) A `pyarrow.Table`. Works in the examples environment today. The cost: pandas code over a chunk
  (`chunk[chunk.x > 0]`) does not run, and changing the type later breaks users.
- (b) A komira `DataFrame` over the chunk's rows. The same verbs as the frame `read_csv` returns without
  `chunksize`, and `.to_pandas()` when pandas is there. The cost: a frame over in-memory rows, which the
  plan wire lacks (`scan_in_memory`).
- (c) A pandas `DataFrame`, which requires pandas. Exactly pandas' type. The cost: unusable in the
  examples environment, and komira gains a hard pandas path.
- **Recommended: (b)**, with `read_csv(chunksize=n)` refused by name until it lands.

**D7. The plan door's cancel.** `komira_plan_stream` has no run handle today, so a DataFrame query cannot
be cancelled.
- (a) `komira_plan_open` (S3) is the plan door's cancel.
- (b) Also add `komira_plan_stream_run` now. The cost: a row that S7 makes redundant.
- **Recommended: (a).**

## 12. Decisions taken in this document

Cases no earlier document decides, decided here so the slices can start:

- **A failed stream stays failed.** Every `get_next` after an error or a cancel returns the same code and
  text. A reader that retries learns nothing new, and Arrow does not define a stream that resumes.
- **An error's position decides, not its time** (§5.7). It makes the `N`th-call test deterministic, at
  the cost of letting the claims in flight finish after an error.
- **`EIO` for every engine error, `ECANCELED` for a cancel.** The code is in the text's prefix.
  `ENOMEM` is not used for `MEMORY_BUDGET_EXCEEDED`: pyarrow would turn it into a different exception
  type, and the text already names it.
- **No empty batch is handed out, and batches are not coalesced** in the first slices. A morsel's output is
  the unit.
- **A NULL run handle is allowed** in `komira_*_open`. Release still cancels.
- **`COPY` through `komira_sql_open` is refused until S5**, since its one row means the file is written.
- **The first slice refuses any root source but Parquet and a breaker's output**, rather than streaming
  a source that decodes the whole input first and calling that streaming.
- **The gate sits at the source's claim, not at the worker loop** (§5.2). A claim is the unit that is
  either wholly in a wave or wholly in a later one, which is what keeps order across waves without a
  reorder window.
- **The bound counts claims and the bytes held for the reader, including chunks inside a wave** (§5.3),
  since a claim can yield several batches and a wave's output is held before the wave ends.
- **A root probe is refused in a streamed run until keyed probes split their output** (§5.3), rather than
  promising a bound one claim's fan-out breaks.
- **A streamed Parquet scan turns off the scheduling modes that reorder claims** (§5.4), and pays their
  cost, rather than adding a reorder window.
- **Only a trailing root limit moves to delivery** (§5.5). A limit with an operator above it keeps
  today's behaviour.
- **Each streamed run keeps its own segment pool** with the context's budget, as runs do today (§5.3). The
  bound is per stream.
- **The dispatch lock is taken only by reader threads, and its wait is cancellable** (§5.9).
- **The old run calls are unchanged until S7**, and then change only in batch count and `LIMIT` row choice
  (§6.5).

## 13. Docs this design finds stale

Rule P10. These are fixed by the slice that changes the behaviour, not here:

- `Result.to_reader()`'s docstring says it "reads its batches as they are asked for". That is true of
  the reader and not of the engine, which has computed them all. It is fixed in S2.
- [libkomira_run_abi.md](libkomira_run_abi.md) §5 ("Materialized first") and §10 (`ECANCELED` "when one
  exists") point forward to this document once S1 lands.
- The `read_csv` task page (rank 28, "process a CSV larger than memory") says `to_reader()` reads batches
  as they are asked for. It is fixed with S2 and S4.
