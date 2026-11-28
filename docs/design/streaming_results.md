# Streamed results: the engine hands out batches as it makes them

Status: design, not built. **EXISTS** names code on `main`; **PROPOSED** is new. Statements the author
deduced rather than read are marked *(inferred)*.

Today a query's answer leaves libkomira as an Arrow C stream (`komira_sql_stream`, `komira_plan_stream`),
but the stream is a cursor over an answer that was computed whole before the call returned. The first
row reaches the caller only after the last row was computed, and the whole answer is in memory at once.
This document designs real streaming: a reader that asks for the next batch gets it while the rest of
the query is still to run, the engine reads ahead of the reader by a bounded amount, and a reader that
stops early stops the query.

It answers, in order: what the earlier engine built (§2), where komira materialises the answer today
(§3), what the reference libraries promise (§4), the execution model (§5), the C interface (§6), the
SDKs (§7), writes (§8), the tests (§9), the slices (§10), the one open decision (§11) and the decisions
taken (§12). "Streaming" here means streaming the result of a bounded query. Plans over unbounded input,
run in epochs, are a different subject ([plan_models.md](plan_models.md) §4.3), and nothing here changes
them.

These words are used throughout:

- **A claim** is the unit of input a worker takes from a source at a time: for Parquet, one row group or
  one row range of a split row group; for a table in memory, one morsel.
- **A round** is one ordinary parallel run of the last pipeline: every worker takes claims and runs
  them through the pipeline's operators until the source is exhausted or no further claim is allowed.
- **The read-ahead limit** decides whether a worker may take one more claim. It is the bound on how far
  the engine runs ahead of the reader.
- **The last stage** is the last pipeline of the plan, built once for the whole stream: its source, its
  operators and its result sink.
- **The result sink** collects a round's output in position order and hands it to the stream's queue
  through **the hand-out step**, the one place every batch passes before a reader can take it (§5.12).

The slices are named by what they change: the engine-core slice (one pool and one lock per context), the
rounds slice (rounds in the executor), the source limits slice (the read-ahead limit in the sources), the
streamed-run slice (the run a driver thread holds), the open-call slice (the new C calls), the bindings
slice, the plan-door slice, the CSV slice, the writes slice, the read-ahead slice and the old calls slice
(§10).

## 1. Summary

| item | design |
|---|---|
| the model | **rounds pulled by the reader** (§5). The breakers below the last pipeline run as today. The last pipeline is built once and runs in rounds, each one ordinary parallel dispatch in which workers take claims while the read-ahead limit allows. A round therefore stops by itself, and the reader's `get_next` asks for the next round when nothing is left to hand out. Each open stream has a driver thread whose frame holds the run, and which runs a round only when asked. No worker and no lock ever waits on a reader |
| the bound | what is held for the reader: no more claims than the claim limit, taken and not yet handed out, counting the claims still being worked on. That is one claim per worker for the first round and two per worker after, so a Parquet stream holds up to twice the workers' decoded row groups, within a byte limit of at most half the memory budget (35% of available memory by default). Besides that, a stream holds what its source holds today (a table in memory is copied and cut into morsels; a breaker's output is held whole). §5.3 gives the peak for each kind of source. A stream's held batches are not charged to the context's pool, as today's answer is not, so an unread `Result` never makes another query fail. When the run is over, the stream holds only its queue (§5.2) |
| what streams | the last pipeline over a Parquet file set, a table in memory, a breaker's output, a `UNION ALL` or a whole-decoded CSV, JSONL or Iceberg file, through filters, projections and limits. A join probe in the last pipeline, and a Parquet file set whose files disagree on a column, run as today inside the first `get_next`, their limits kept, and are handed out from memory; they work the same and only do not stream yet. A statement with effects (`COPY ... TO`, a write) runs to completion inside the open call, so it never depends on the stream being read (§5.11) |
| order | a streamed result comes out in the order the materialised result has today: file order for a scan, the sort's order for `ORDER BY`. A final `LIMIT` without `ORDER BY` is applied as rows are handed out, so it returns the first rows in that order (§5.4, §5.5) |
| what cannot stream | a sort, an aggregate, a window, a distinct and a join's build side finish before their output exists. The first `get_next` waits for them; progress and cancel work meanwhile (§5.6) |
| a late error | an error while producing a claim is returned by the `get_next` that would have returned that claim's batch, after every batch before it, when each claim yields one batch. The code and step are read from the run handle, not from the text (§5.7, §6.3) |
| cancel | `komira_run_cancel(run)` from any thread, as today; a waiting `get_next` returns `ECANCELED`. Releasing the stream before its end ends the run and frees everything it holds (§5.8) |
| the C interface | the Arrow C stream stays the one result shape. `komira_sql_open` and `komira_plan_open` return it before the run, with the run handle that cancels it; `komira_run_error_code` and `komira_run_error_step` give a late error's code and step. The stream's schema is the first batch's, as today, with every field nullable (§6) |
| the existing calls | `komira_sql_stream`, `komira_sql_stream_run` and `komira_plan_stream` keep their contract: the answer computed before the call returns, every engine error a status (§6.5) |
| ABI version | the next minor for each call, as it lands (§6.6) |
| SDKs | Python's `sql()` pulls the first batch, so an error before it still raises there; every terminal reads on the helper thread, so Ctrl-C cancels. `read_csv(chunksize=n)` needs a CSV source that streams first. Node's async iterator reads batch by batch. The Mojo SDK gets a stream form beside its `Result` (§7) |
| writes | `COPY ... TO` and the SDK writers do not stream today. They move onto the same streamed run, with a writer appending to a temporary file renamed at the end (§8) |
| first slice | five pull requests that together stream one SQL query over Parquet end to end through `komira_sql_open`, proven by the engine tests and the C driver; only C callers can stream until the bindings slice (§10) |

## 2. What the earlier engine did

This design started from the earlier engine's streaming, and it draws on the whole of that engine's
history: its Rust engine, its first Mojo engine and its later Mojo engine, its C interface, its Python
SDK and its design records.

**It never handed a query's result to its caller batch by batch.** Every result path ran the query to
completion first. It did stream in other places: inside the engine, into files, and between brokers.
Each is described below, with what this design takes from it.

### 2.1 What streamed, and where

- **The Rust Parquet scan.** Two decode threads claimed row groups from an atomic counter, cut each
  decoded row group into morsel-sized batches and sent them down a bounded channel of eight batches to
  the compute workers. A send blocked while the channel was full, which is real back-pressure. When the
  receiver was dropped, the next send failed and the decode thread stopped, which is real stop-on-drop.
  The channel was between the scan and the operators, inside the engine, and it lasted until the Rust
  engine was deleted.
- **An earlier Rust executor's writer path.** Reader threads sent decoded row groups to one Parquet writer
  thread through a channel bounded at twice the reader count, with a reorder buffer on the writer's side
  keyed by row-group index. That was file to file, and it was removed with that executor, before the
  scan above.
- **The Mojo streaming scan.** The later Mojo engine made a streaming pull-decode the default scan for
  integer-typed `SELECT`, filter and project queries over Parquet. Each worker claimed row groups, decoded
  them in cache-sized chunks into a fixed per-worker buffer, and freed each chunk once the operators had
  folded it. A later change split the three grains of that path apart: the row group is claimed, the page
  decompressed, the grain decoded. Each chunk was stamped with its row group and chunk index, and the
  drain sorted the chunks stably into file order, the same position order komira's collect sink keeps.
  The scan streamed inside the engine; the result was still concatenated once at the API boundary.
  komira's Parquet source claims and decodes the same way today, and this design builds on it.
- **The Mojo streaming Parquet writer.** A writer that keeps the file open and writes each row group to
  disk as it is encoded, so its peak memory is one row group's working set and not the table's. It
  coalesces incoming batches up to a row-group size, so that one morsel does not become one tiny row group.
  It writes the footer at the end, and removes the partial file on an error if it created the file. The
  engine's other Parquet writers buffered the whole table and wrote it at close.
- **Micro-batch jobs between brokers.** A design and its code for exactly-once jobs over
  unbounded input: a broker, a write-ahead log, shuffle through a broker, and a streaming sink with
  `pre_commit`, `commit` and `abort` per step. It had no C or Python surface for a query's result.

### 2.2 How a result left the engine

- **The Rust engine.** `collect()` returned a `Vec<RecordBatch>` after the morsel scheduler had run every
  segment.
- **The first Mojo SDK.** A "streaming materialize" result type ran the whole query, then sliced the one
  result batch into pages of `rows_per_batch` rows and handed the pages out one by one. Its own header
  called this "eager-materialize-then-chunk", and named the real primitive, a worker pool that pauses and
  resumes, as a later follow-up. The type was later renamed to a "paginated" result, because the name
  claimed streaming that the code did not do, and could never return on an unbounded input.
- **The later Mojo engine.** Its result sink said in its header: the Arrow C stream is a pull interface,
  a sink is push, so the sink buffers every batch and exports them after the run; "true incremental
  streaming-export ... is the ... streaming follow-up". Its C entry points (`komira_plan_stream`,
  `komira_sql_stream`) ran the plan to one batch or one chunked table, then built the stream over it. Its
  Python `Session` documented that `komira_sql_stream` "executes the query — it does not merely open a
  stream". Its `to_reader()` docstring said "a real stream: nothing is materialised". That was true of the
  pyarrow reader and not of the engine.

### 2.3 Cancel, errors, memory and tests on the result path

- **Cancel.** A cancellation token (a chain of atomic flags, cancelled downward to children, never up)
  was polled between morsels and between dispatched tasks, and dropping a join handle cancelled its task.
  Neither was tied to a result: releasing a result stream only freed the buffered batches, since nothing
  was running by then.
- **Late errors.** Impossible by construction: every execution error came back as the status of the run
  call. `get_next` could fail only while building an Arrow array from a stored batch (`EIO`, with the text
  in `get_last_error`).
- **Memory.** The whole result was resident until the stream was released.
- **Order.** The collect sink kept "collected order". A sink capability meant to make the planner disable
  parallel scheduling for sinks that need source order was declared and never read.
- **Tests.** Lifetime tests only, and they were good ones: every buffer of every array read through the
  raw C struct after the stream was released, in all three release orders; a chunk outliving its stream; a
  stream read after its engine context was destroyed; ten thousand export cycles without a leak; a
  chunkless table keeping its schema. No test measured anything read at the first batch, a peak memory, a
  cancel through the stream or a late error, because none of those could happen.

### 2.4 What this design carries from it

- **The Arrow C stream as the result shape**, and its lifetime rules: each exported array owns its share
  of the buffers and outlives the stream, release is idempotent and leaves stubs behind, and the stream
  holds no reference to the session. komira already carries all of this
  (`src/arrow_ipc/c_data_stream.mojo`).
- **The scan channel's two properties**, a bounded read-ahead and a stop when the reader goes away, now
  as a property of the last pipeline rather than of one source (§5.3, §5.8).
- **Drop means cancel**, from its join handles, applied to a result stream (§5.8).
- **The streaming writer's shape** for §8: row groups written as they are encoded, small batches
  coalesced, the footer at the end, nothing left behind on an error.
- **The lifetime tests**, rerun against a stream that is still producing (§9).
- **Not carried:** the two-phase commit of the micro-batch sink (a result has no durable step to
  commit), threads that block inside the engine on a full channel (§5.1 says why), and pagination of a
  materialised answer.

## 3. Where komira materialises the answer today

**EXISTS.** The call chain of `komira_sql_stream`. Every step is done before the call returns and before
`*out` is written:

| step | where | what it does |
|---|---|---|
| 1 | `src/so/_c_abi.mojo:674` | `_sql_stream` calls `sql_result(session[], text, control)` |
| 2 | `src/sdk_exec/engine_sql.mojo:127`, `:149` | `run_sql_with` calls `ctx.begin_query()` (which replaces the context's footer cache), parses and binds, then `run_plan_batch` |
| 3 | `src/sdk_exec/engine_execute.mojo:159-171` | `ctx.runtime.dispatcher()`, then `run_plan(...)` runs every segment, then `out.take(lowered.result_seg_id)` takes the root's output: **one `RecordBatch`** |
| 4 | `src/pipeline_exec/run_plan.mojo:66-85` | a serial ready-set loop: one segment at a time, a cancel check before each, `finish_segment` after each |
| 5 | `src/pipeline_exec/run_segment.mojo:115`, `:153-155` | one `run_with_state` dispatch per segment; the calling thread waits in the dispatch barrier until every worker has finished, then `combine`, `finalize`, `take_output` |
| 6 | `src/pipeline_exec/sink_collect.mojo`: `consume` at `:90` (append at `:104`), `combine` at `:106` (`position_order` at `:118`), `take_output` at `:129` (concatenation at `:144`) | **the sink that materialises**: `consume` appends each morsel's batch to the worker's slot; `combine` orders all chunks by source position (`position_order`); `take_output` concatenates them into one batch (`concat_record_batches_nway`) |
| 7 | `src/sdk_exec/engine_sql.mojo:157` | `outcome.batches.append(batch^)`: the list of the answer, which holds exactly one batch |
| 8 | `src/sdk_exec/arrow_result.mojo:69-75` | the one batch moves into a `Slab`, with its selection mask materialised, and `check_record_batch_stream` refuses a type the exporter cannot export |
| 9 | `src/so/_c_abi.mojo:677` | `build_record_batch_stream(result.take_batches(), result.take_schema(), out_stream)` fills the caller's struct |
| 10 | `src/arrow_ipc/c_data_stream.mojo:2925-2944` | `get_next` builds an Arrow array over the next stored batch (no copy, shared buffers) and ends at the end of the `Slab` |

So the answer is materialised by `CollectSink.take_output` at the end of the root segment, called from
`run_segment` after the dispatch barrier. The reason is structural, not incidental:

- **The dispatch returns only when every worker has finished.** `run_with_state` holds the caller in its
  barrier until every shard is done, and only one dispatch can be live per dispatcher
  ([async_runtime.md](async_runtime.md), "What must always hold?"). Nothing can leave a segment before its
  dispatch returns.
- **The sink learns that every morsel has arrived only at `combine`**, so it can order by position only
  then. The order the result has today (file order, whatever the schedule) is bought by holding
  everything.
- **The run call is synchronous and its errors are statuses.** "The answer is computed before the call
  returns" is the documented contract of `komira_sql_stream` (`_c_abi.mojo:695`), which
  `komira_sql_stream_run` and `komira_plan_stream` take over by reference. The rule "a query is never
  answered from a part of its input" ([lowering_and_pipeline.md](lowering_and_pipeline.md), failure table)
  holds because nothing is handed out before the end.

The memory cost: the collect sink holds every chunk until `take_output`, and the concatenation copies
them, "so a segment's peak memory is about twice its output" (`src/pipeline_exec/README.md`, Known
limits). The collect sink's chunks are not charged to the memory budget, and neither are a segment's
published outputs.

Above the C interface the same holds. Python's `Result.to_reader()` is a pyarrow reader over that stream
(`python/komira/_session.py:623`), lazy only over batches that already exist. Node's addon drains the
stream on the session's thread before `sql` resolves (`node/src/result.ts:5-7`). pandas'
`read_csv(chunksize=n)` was left unbuilt for this reason: chunks taken from the engine would read the
whole file before the first chunk.

Sources matter as much as the sink. The Parquet source claims row groups lazily, per worker. Tables in
memory (a registered table, a breaker's published output, the branches of a `UNION ALL`) are served by
the in-memory batch source, which cuts morsels from a resident batch. The CSV and Iceberg sources decode
their whole input before the first morsel (`source_csv.mojo:21-22`, `source_iceberg.mojo:15-16`), and the
JSONL source builds every batch up front. A streamed result over those sources would still read the
whole input before its first batch.

## 4. What the reference libraries promise

**The Arrow C stream interface.** It has four callbacks: `get_schema`, `get_next`, `get_last_error` and
`release`.

- `get_next` returns 0 and an array, or an errno-like code. A released (NULL `release`) array is the end of
  the stream.
- `get_last_error` may be called only after a failed call, and is valid until the next callback.
- The source "is not assumed to be thread-safe": a consumer serialises its calls.
- The spec says nothing about releasing before the end, and nothing about any call from a second thread.
  So a cancel from another thread needs its own entry point outside the stream.
- An async device stream with a thread-safe `cancel` and `request(n)` back-pressure exists, but is marked
  experimental.

pyarrow's reader calls `get_next` with the GIL released (`read_next_batch` and `read_all` are `with nogil`
in `ipc.pxi`), and releases the stream when the reader is closed or collected. It turns a non-zero
`get_next` into an exception whose message is exactly `get_last_error`'s text: `EINVAL` becomes
`ArrowInvalid`, `ENOMEM` becomes `ArrowMemoryError`, and anything else becomes `OSError`.

**ADBC**, the database API over that stream, fills both gaps.

- "Releasing the returned ArrowArrayStream without consuming it fully is equivalent to calling
  AdbcStatementCancel."
- `AdbcStatementCancel` "must always be thread-safe (other operations are not)", and may be called "while
  consuming an ArrowArrayStream".
- It makes the stream's methods return `ECANCELED`.
- It is best effort, since "the result set may be buffered in memory already".

**DuckDB.** `con.sql(q).to_arrow_reader()` (also `fetch_record_batch(rows_per_batch)`) streams.

- The result collector is a buffered collector. Its sink returns `BLOCKED` when its buffer is full, and is
  rescheduled as the reader drains it.
- The query's tasks run on the fetching thread until the buffer is no longer empty.
- The buffer is a byte bound: `streaming_buffer_size`, about 1 MB in 1.5, and a 10 MiB
  `max_streaming_buffer_size` on its main branch. It admits one unit even when that would overshoot.
- `rows_per_batch` sizes the Arrow chunks only.
- A late error makes the `get_next` that reaches it return -1 with the message, so pyarrow raises it there, after
  the earlier batches.
- Destroying a streaming result whose statement has not completed aborts the statement, and another query
  on the same connection ends an open stream.
- Order: with `preserve_insertion_order` (the default), a plan without `ORDER BY` keeps insertion order,
  through a batch-indexed collector or a single-threaded one. With it off, the collector is parallel and
  the order is not defined.
- Its newer Python binding releases the stream without the GIL, because releasing "ends the query and
  joins its tasks, one of which may be inside a Python UDF waiting for the GIL".

**polars.**

- `collect(engine="streaming")` runs the batch-at-a-time engine, but returns one whole `DataFrame`.
- `LazyFrame.collect_batches(chunk_size, maintain_order=True, lazy=False)` (unstable) yields `DataFrame`
  chunks from a channel of capacity 1. The engine waits on the channel. An error is sent down it and
  raised by the `next()` that reaches it. Dropping the iterator closes the channel, which stops the sink.
- `sink_parquet`, `sink_csv`, `sink_ndjson` and `sink_ipc` run the query in the streaming engine, write
  the file (larger than memory), and return once it is written.
- Inside the engine, ordered output from many workers goes through a linearizer over bounded per-worker
  channels (4 by default), keyed by morsel sequence numbers.

**pandas.** `read_csv(path, chunksize=n)` or `iterator=True` returns a `TextFileReader`.

- It is iterable, has `get_chunk(size)` and `close()`, and is a context manager.
- Each chunk is a `DataFrame` of up to `n` rows, whose `RangeIndex` continues from the previous chunk.
- Parsing is lazy: the C parser tokenises only the rows the chunk needs. A malformed line raises
  `ParserError` while its chunk is read, after the earlier chunks were returned, and the reader then closes
  itself.
- `engine="pyarrow"` refuses both options.

**Spark.** `toLocalIterator(prefetchPartitions=False)` yields `Row`s one partition at a time.

- There is one job per partition, run when the partition is asked for (or one ahead with prefetch).
- It uses "as much memory as the largest partition", or two partitions with prefetch.
- An error in a later partition's job is raised when that partition is reached.
- An iterator dropped early first drains the rest of its current partition, then tells the JVM to stop.

**Arrow Flight.** `do_get` returns a `FlightStreamReader`, "a reader that can also be canceled"
(`cancel()`). Its server-side errors arrive on the read that reaches them.

What they agree on, and what this design takes:

- The stream is pulled.
- The producer runs ahead by a bounded buffer, counted in bytes.
- A late error arrives at the read that reaches it, after the rows before it.
- Releasing early ends the query.
- A cancel from another thread is a separate, thread-safe call.
- Ordered output from parallel workers is bought with sequence numbers and a bounded window.

## 5. The model: rounds pulled by the reader

### 5.1 The options

1. **Pull, one batch per `get_next`.** `get_next` runs the pipeline until one batch comes out. With a
   morsel-driven parallel executor this means either a dispatch per batch or one worker per stream, so
   either the dispatch cost or the parallelism is lost.
2. **Push into a bounded queue that blocks the producer.** A driver thread runs the plan as today, and the
   last sink's `consume` waits while the queue is full. This is DuckDB's shape, and the Rust scan's. In
   komira it holds the context's one dispatch for as long as the reader takes, so a reader that pauses
   stops every other query on the context. A worker waiting inside `consume` waits on something outside
   the engine. If that reader is itself the engine, the engine waits on itself. That happens when
   `komira_register_arrow_stream` is fed a komira stream, or Python's `register` is given a `Result` of
   the same session. The runtime forbids exactly this for its own primitives ("a worker thread must not
   block on its own runtime").
3. **Rounds pulled by the reader** (chosen).
   - The last pipeline is built once and runs as a series of ordinary dispatches, called rounds.
   - In each round, a worker takes a new claim only while the read-ahead limit allows, so the round stops
     by itself once the claims outstanding reach the bound.
   - The reader's `get_next` hands out a held batch, and asks for the next round when nothing is held.
   - The rounds run on a driver thread that belongs to the stream (§5.10), and only when the reader asks.
   - Between rounds no worker is busy, the dispatcher is free, and the driver thread waits for the next
     request, holding no lock.

**Chosen: 3**, and the reasons are in §12 (decision 1). It keeps every guarantee the executor gives
today:

- `run_with_state` still returns only after every shard.
- A worker never blocks.
- Order is still bought by sorting positions.
- It is parallel.

It bounds what the last pipeline holds for the reader by construction: the limit is what lets work in,
so nothing has to watch memory and react. What the bound does not cover is listed in §5.3. It is pull in
the Arrow sense: nothing runs unless a reader asks.

Its cost is that the engine is idle while the reader works through the batches of a round. The driver
thread could start the next round by itself when half the bound is free, which would close that gap.
The cost of that read-ahead is a round that may be running when release comes, so release would wait
for it. It is left until a measurement shows the idle time matters (§5.3, §12, decision 2).

### 5.2 How a streamed run works

**PROPOSED.** The engine-level object is a `StreamedRun` in `sdk_exec`. It is built by
`open_sql(ctx, text, control)` and `open_plan(ctx, plan, control)`, beside today's `run_sql_with` and
`run_plan_with`.

1. **Open (the caller's thread).**
   - Parse, bind, optimise and lower, exactly as today. Every refusal of those steps is still a status,
     and `*out` is untouched.
   - A statement with effects runs to completion here, and the call ends with its one-row stream
     (§5.11).
   - For any other statement, the run decides here, from the lowered plan alone, whether it can stream
     (§5.11). Every reason to run materialised that the plan shows is decided now, before anything runs.
     The lowered plan is never changed or copied: its parts (`MorselOp`, `SegmentDescPod`, `LoweredPlan`)
     can be moved but not copied (`physical_plan.mojo:284`, `:772`; `lowered_plan.mojo`). A run decided
     to stream that ends in a trailing limit instead records two numbers beside the plan: the number of
     the root segment's operators to build, one less than the plan's, and the limit's count, which the
     result sink takes (§5.5). A run that falls back later builds the plan's full operator list (§5.11).
   - The run takes a **child** of the control's cancel token (`CancellationToken.child()`,
     `src/async_api/src/async_api/token.mojo:195`). A cancel of the run handle reaches the child, and an
     early release cancels the child only. So the caller's handle, and every other run given it, stay
     usable (§5.8). A limit's end cancels nothing: it finishes the run (§5.5).
   - The run starts the stream's driver thread (§5.10). It hands the thread, by value, everything
     `run_lowered_plan_with` reads from the context or the plan today (`engine_execute.mojo:119-158`):
     - the lowered plan with its parameters (the resident batches and the aggregate, sort, top-N and window
       sink data);
     - the opener and the credentials it resolved;
     - the worker count (`ctx.host_profile.thread_count`), the memory budget and the spill directory.

     After open, the run reads no mutable context state.
   - Nothing is claimed from any source yet, and no file is opened.
   - The C stream it fills is backed by a new exporter state in `arrow_ipc`, whose `get_next` asks the
     driver for batches instead of walking a finished list (today's state ends at `len(state.batches)`,
     `src/arrow_ipc/c_data_stream.mojo:2925-2948`). It carries the request to the driver and the error and
     cancel returns below.
2. **The driver thread's frame.** The driver makes, in its own frame, what `run_lowered_plan_with` makes
   in its frame today (`src/sdk_exec/engine_execute.mojo:116-121`): a fresh Parquet metadata cache for the
   run, an expression pool, and a `RealBuilder` that borrows both. It then waits for a request.
3. **The breakers (at the first request).** Every segment below the root runs as today, through
   `run_segment`, one dispatch each, in `run_plan`'s order. Their outputs are published as today. Today
   `run_plan` runs every segment, the root included, in one loop with its own plan check, ready set and
   progress (`src/pipeline_exec/run_plan.mojo:49-86`). The rounds slice splits it so the driver can run
   everything below the root with the same check, order and progress, and then hold the root.
4. **The last stage, built once.** The driver builds the root segment once, through the same builder
   calls a segment run makes today:
   - `build_source`, which builds the source over a Parquet file set, a resident table, a breaker's
     published output, or the branches of a `UNION ALL`;
   - the operators' shared parts, so a limit's row budget is made once;
   - the **result sink**: `CollectSink` without its concatenation (§5.12).

   Today `run_segment` builds, runs and drops
   a segment in one call. The operators are built per worker and the sink sized once, before the dispatch
   (`run_segment.mojo:85-99`), and nothing is consumed by `run_with_state`, so the same `SegmentRun` can be
   dispatched again. The rounds slice splits `run_segment` into three calls, which keep today's order:
   building the segment, running one round over it, and finishing it. That needs four changes in
   `pipeline_exec`:
   - `CollectSink.combine` runs exactly once today, and leaves emptied chunks in the worker slots. The
     result sink gets a separate per-round drain;
   - `PipelineSink`, a fixed variant of four sinks (`real_builder.mojo`, `comptime Sink`), gets a forwarder
     for that drain;
   - the source trait `MorselSourceImpl` gets `is_exhausted()`, with its forwarders in `SourceVariant`,
     `BatchSource` and `SinkOutputSource`;
   - `SegmentRun.fail` and `SegmentTask.execute` get the streamed variant of §5.7, which records the lowest
     position and does not cancel the pipeline. For that, a failure must know its claim's position: the
     worker keeps the position of the morsel it hands to `_push` (`segment_task.mojo:144-150`, where the
     morsel is moved), and a source exposes the position of the claim each worker is decoding, for an
     error raised inside `next_morsel`.
5. **One round at a time.** Each request that needs batches makes the driver run one round:
   - one `run_with_state` over the segment built in step 4;
   - a worker first drains the sub-morsels of the claim it holds (the source parks them on the worker's
     pending slab and hands them out on its next calls), and asks for a new claim only when it holds none;
   - a new claim is taken only if the read-ahead limit allows it (§5.3);
   - when the limit refuses a claim, `next_morsel` returns `None`. The source records whether it was
     refused or is exhausted, and is asked again in the next round. Today `None` means "never ask this
     worker again" (`src/pipeline_exec/README.md`), so each source the source limits slice gates changes
     that contract (§5.4);
   - the round ends when every worker has returned, and at that point no worker holds part of a claim;
   - the result sink then hands the round's batches to the queue through the hand-out step (§5.12).
6. **The end.** When a round ends with the source exhausted, the driver pushes the operator tails (the
   unmatched rows of a RIGHT or FULL join, `run_segment`'s `_push_tails`). Then `finalize` runs, and the
   run checks that its share of the pool is returned (`EXECUTE_POOL_NOT_RELEASED`, as today). A round that
   ended at the limit pushes no tails.
7. **When the run is over, the frame goes.** The run is over when the source is exhausted and the end is
   queued, when a limit is reached, when it fails, when it is cancelled, or when a run materialised
   inside the stream has queued its whole answer. At that moment the driver returns from its frame and its
   thread ends. That frees:
   - the builder and the operators' shared parts, a join's build rows and index included
     (`HashProbeShared` in the builder's parts, `real_builder.mojo:438-441`);
   - the source with its copies and morsels, its open files and mappings, and its prefetch buffers;
   - the published outputs, the footer cache and the expression pool;
   - the lowered plan.

   What is left is the queue of batches not yet handed out, and the error or the end. None of those
   batches refers to a mapping (§5.12, step 5). They do keep alive the buffers they are views of: a
   decoded row group's columns, or the source's copy of a resident table. That is at most the stream's own
   bound (§5.3), which the retained-bytes function measures. So a finished stream left unread, such as a
   Python `Result` kept in a notebook, holds the batches of its answer the reader has not taken and the
   buffers they keep alive, within that bound: no run state, no thread and no file. Today's `Result` holds
   its whole answer. Release then frees the queue.

**`get_next`**, on the reader's thread, written out:

```text
loop:
    if the end has been returned once:     return 0 and a released array (the end, every time)
    if an error has been returned once:    return its errno (every time)
    if the stream's token is cancelled:    mark the run cancelled; if the driver is parked, tell it to stop
                                           and join it (it is parked, so this does not wait); return
                                           ECANCELED (every time)
    if the queue holds a batch:            pop it, return 0 and the batch
    if the run has failed:                 return its errno, and remember that it was returned
    if the run is finished:                return 0 and a released array, and remember that the end was
                                           returned
    ask the driver for more, and wait for its answer
```

- **The end stays the end, and an error stays the error.** Once either has been returned, it is returned
  every time, even if a cancel arrives afterwards.
- **A cancel hands out nothing more.** A cancel that arrives before the reader has seen the end returns
  `ECANCELED`, even with batches still queued, as §5.7 says. That includes a cancel after the last batch
  was queued.
- **An error comes after the batches before it.** They were queued before it, so they are popped first.
- **The wait.** The wait for the driver's answer does not return early on a cancel. The driver sees the
  cancel at its next check (the next morsel inside a round or a breaker), stops, and answers `ECANCELED`.
  A cancel that lands in a sort's or an aggregate's `combine`, which checks no token today, waits for it
  to finish, as a cancel of a materialised run does today. So when `get_next` returns, the driver is
  parked again, and a release that follows never waits for running work.

**The driver**, on its own thread:

```text
wait for a request
if the run is marked materialised:     run the plan's own lowered plan, its limits included, as
                                       run_lowered_plan_with does today; pass its batches through the
                                       hand-out step; mark finished
else:
    if a breaker has not run:          run the breakers, build the last stage (steps 3 and 4)
    if the stage is a fall-back case:  drop the stage, and run the root segment whole with the plan's full
                                       operator list, through the same builder (§5.11)
    run one round (and, when the source is exhausted, a trailing limit's count is reached, or a
    non-trailing limit's budget is spent: the tails and finalize, then mark finished)
answer the request
if the run is over (the end queued, a limit reached, failed, cancelled, or a materialised answer queued):
    return from the frame, freeing it, and end the thread (step 7)
else:
    wait for the next request, or for release
```

So one `get_next` may cause several rounds: a round whose filter rejects every row it read yields no
batch, and the loop asks again. A cancel is seen between rounds and, inside a round, at every claim and
morsel the workers check (§5.8).

**What the first batch costs.** The first `get_next` costs the breakers below, if any, then the build of
the last stage, then one whole round. A round cannot hand out a batch before it ends, because the result
sink orders the round's chunks only then.
- **The first round takes one claim per worker.** The claim limit is the worker count for the first round
  and twice it after (§5.3). Today a `LIMIT` query's workers each stop at about their first claim, when
  their limit operator reports `FINISHED` (`op_limit.mojo:97-118`, `segment_task.mojo:124-125`), and
  Python's `sql()` pulls the first batch (§7.1). A first round of two claims per worker would make every
  `sql()` decode and hold about twice the row groups today's `LIMIT` does before its first batch. With one
  claim per worker it costs what today's run costs up to its first morsel.
- So the first-batch bound of §9.1 holds for a scan that yields output per claim. A filter that rejects a
  whole round makes the first `get_next` run another round.

No worker and no lock ever waits on a reader. The reader waits only on engine work (a breaker segment, the
build of the last stage, or one round), and the driver thread waits for the reader holding nothing that
another run needs. That property is what lets a reader pause, read from another thread, or feed the stream
back into the same engine.

### 5.3 The read-ahead limit and the bound

**The two limits.** The read-ahead limit has two parts, both fixed by the engine (§12, decision 3):

- **the claim limit**, a number of claims: the number of workers for the first round, and twice the
  number of workers after it (§5.2, "What the first batch costs");
- **the byte limit**, a number of bytes: the larger of 64 MiB and twice the number of workers times the
  scan's largest claim estimate, and at most half the context's memory budget. Every context has a
  budget: when none is given it is 70% of the available memory (`detect_host_profile`,
  `host_profile/host_detect.mojo:36-41`; `default_memory_budget`, `host_profile/hardware.mojo:259-261`),
  and every run is given it (`engine_execute.mojo:122`). So by default the byte limit is at most 35% of
  the available memory. The second term keeps every worker busy when row groups are large. The budget cap
  keeps one stream from holding more than half the budget.

**The rule, stated once.** A claim is *outstanding* from the moment a worker takes it until every batch
it produced has been handed out to the reader, or discarded. That covers claims being worked on, claims
whose chunks sit in the result sink during the round, and claims whose batches sit in the queue. A worker
may take one more claim only if, with that claim counted,

```text
outstanding claims ≤ the claim limit   and   outstanding bytes ≤ the byte limit
```

When nothing is outstanding, one claim is always allowed, so a claim larger than the byte limit still
makes progress, as DuckDB's buffer admits one unit when empty.

**What a claim counts.** The outstanding counts are the stream's own: one 64-bit atomic word per stream
(claims in the low 16 bits, bytes in KiB above them), which the limit reads. It is not the context's
memory pool (below). A claim's bytes in that word are:

- before its output exists, its estimate: the source's own size for it, known before it is taken.
  - For Parquet it is the sum of `total_uncompressed_size` over the column chunks the scan projects, in
    that row group, from the footer. A row group's `total_byte_size`
    (`parquet_api/src/parquet_api/metadata.mojo:439`) counts every column, so a narrow projection over a
    wide file would be counted many times its real size. The reader has no accessor for the per-chunk
    sizes of a projection today, so the source limits slice adds one.
  - For a source over a table in memory it is the morsel's size, from a per-slot size array the source
    fills when it cuts the table. A slot's morsel cannot be read at the claim, because the winning worker
    swaps it out at the same time.
- once its output reaches the result sink, the bytes of every buffer that output keeps alive, which
  replace the estimate in the word. For a Parquet claim that includes the whole decoded row group, because
  a morsel's columns are views of the decoded row group's buffers: non-nullable fixed-width columns by a
  zero-copy slice, and strings by a window on their payload (`src/morsel/morsel.mojo:838-863`). So one
  held morsel keeps the whole buffer alive. It also includes any buffer the operators made, such as a cast
  of an integer column to text or a computed column, which can be larger than the column it came from.
  For a source over a table in memory, a morsel's buffers belong to the source (below), so a claim counts
  only what the operators and the hand-out step made.
- measured by a new function, which the rounds slice adds to `arrow`: the bytes a set of batches keeps
  alive, with every shared buffer counted once. Today a column holds its buffers as `SharedAlignedBuffer`s,
  and nothing sums what a column keeps alive or tells two views of one buffer apart (`src/arrow/column.mojo`).
  The function counts each underlying buffer once by its identity: the whole region behind a
  `SharedAlignedBuffer`, not the view's length, identified by the region's shared pointer. So the many
  morsels of one decoded row group are counted once, at the first that reaches the sink. A column whose
  buffers borrow a file mapping counts its window (its rows, not the whole column chunk the buffer covers),
  which is what the hand-out step's copy of it will hold (§5.12, step 5). The copies of the hand-out step (§5.12, §6.3) are buffers like any other, so they are
  counted the same way.
- released when the claim's last batch is handed out. A claim that yields nothing (a row group pruned,
  skipped or filtered empty) releases its reservation when its worker moves on.

The sink learns which claim a chunk belongs to from the chunk's position. For Parquet a position is the
claimed row group times `SUB_SLOT_STRIDE` plus the sub-slot (`parquet_source_options.mojo`,
`parquet_source_grain.mojo` header), so the claim is the position divided by the stride. For the in-memory
source the position is the claimed slot itself (`batch_morsel_source.mojo:782`, `partition_id = c`). Each
source states that mapping (`claim_of(position)`) in the rounds slice's source trait change, and the
generated source follows the Parquet encoding, so the rounds slice's tests exercise the real one.

**Taking a claim is one step.** The claim index is known only once the cursor has moved, so the check
and the cursor's move are done together, in a compare-and-swap loop:

```text
loop:
    next_claim = cursor.load();  if next_claim >= end: return EXHAUSTED
    claim_bytes = estimate(next_claim)
    if not limit.try_reserve(1 claim, claim_bytes): return REFUSED   # the stream's one atomic word
    if cursor.compare_exchange(next_claim, next_claim + 1): return next_claim
    limit.release(1 claim, claim_bytes)              # another worker took that claim; try again
```

**What that bounds.** Unless the budget cap is lower, the byte limit is never smaller than twice the
workers times the largest claim estimate. So on estimates alone every claim the claim limit allows also
fits under the byte limit, and the claim limit is the bound that binds. Where the cap is lower, as in a
small container whose budget is 70% of little memory, the byte limit binds instead and fewer claims run
at once; one claim is still always allowed when nothing is outstanding. A Parquet stream holds at most:

- **the claim limit's number of decoded row groups:** the workers for the first round, twice the workers
  after. For example, 16 workers over 128 MiB row groups hold up to 2 GiB for the first round, and up to
  4 GiB after it;
- **within the byte limit, which the outstanding bytes reach only through excess:** what the claims
  being worked on hold beyond their estimates. Only a claim a worker is working on can exceed its estimate,
  so that excess is at most one claim's excess per worker. A claim's excess has two sources: a decoded row
  group larger than the footer's uncompressed sizes (dictionary or run-length encoded columns), and
  operators whose output is larger than their input (a cast to text, a computed column). Nothing caps a
  morsel's output today (`op_project`, `sink_collect`), so the excess is bounded per claim, not by a
  constant. Once the excess has pushed the outstanding bytes over the byte limit, no claim is taken until
  the reader drains them below it.

**What the engine really holds, by the kind of source the last stage reads.** The limit bounds what is
held for the reader. Each kind of last stage also holds what its source and the breakers below hold. None
of that is new with streaming, and most of it is not charged to the pool today:

| last stage reads | what it holds besides the outstanding claims | charged to the pool today |
|---|---|---|
| a Parquet file set | per worker, the claim it is decoding, which is inside the bound above | no |
| a resident table (`SOURCE_BATCH`) | two copies of the table and a cut. `run_lowered_plan_with` first concatenates the plan's batches into the builder's resident batch, which copies even a single batch (`_resident_batch`, `engine_execute.mojo:66-72`, `:125-127`; `concat_record_batches_nway_ref`, `arrow/concat.mojo:1301`). The builder keeps that for the whole run. `build_source` then copies it again (`real_builder.mojo:520`, `copy_batch` "copies all column data"), and the source cuts the copy at once into morsels (`batch_morsel_source.mojo:440`, `split_record_batch`). The cut shares the non-nullable fixed-width columns and the string payloads, rebuilds string offsets and validity, and copies nullable fixed-width and boolean columns (`morsel.mojo:838-870`, `:975`). It refuses list, map, struct, union, large string and large binary columns (they fall to `check_fixed_width_dispatch`, `arrow/varlen_width_guard.mojo:377-398`, which raises), so a table with such a column fails in a materialised run today, and the same in a stream. So the table's size twice, plus up to the table's size again for nullable columns | no |
| a breaker's published output (`SOURCE_SINK_OUTPUT`) | the output, moved into the source when this is its last reader (`published.take`, `real_builder.mojo:541`; earlier readers get a copy, `published_outputs.mojo:89-100`), and its cut into morsels, as above | no |
| a `UNION ALL` (`SOURCE_CONCAT`) | one concatenation of every branch's output (`real_builder.mojo:561`), and its cut into morsels; the branches' own outputs are freed once concatenated | no |
| a CSV, JSONL or Iceberg file | the whole decoded input (§3), and its cut into morsels | no |

Batches a reader has taken from a source over a table in memory are views of the source's buffers.
After release they keep those buffers alive for as long as the reader holds them, as today's arrays keep
today's answer alive. When the run is over the frame goes (§5.2, step 7), so the copies a reader does not
hold are freed then, not at release.

The source limits slice removes one of the two copies of a resident table: a resident batch read by
exactly one segment is moved into its source instead of copied. The builder does not see the plan when
the resident batches are added today (`add_resident` runs before `run_plan` builds its published outputs,
`engine_execute.mojo:125-128`, `run_plan.mojo:65`), so the slice adds a call the driver makes before any
segment runs, which counts each handle's readers over the plan's segments, as `PublishedOutputs` counts
its readers. The copy exists today because a plan may read a resident batch twice (`source_batch.mojo`
header). The change applies to materialised runs too.

Below the last stage, a breaker holds its own state while it runs: a sort holds its input chunks, their
concatenation, the sorted copy and scratch, all charged to the pool until `take_output`
(`sink_sort.mojo` header, "Memory"). A join's build rows and index are not charged
(`src/pipeline_exec/README.md`, Known limits).

So the peak of a streamed query is:

- **over a Parquet scan:** the bound above;
- **over a table in memory, a breaker's output, a `UNION ALL` or a whole-decoded file:** what the table
  above holds (the copy, or the moved output, and its cut), plus the bound;
- **with breakers below:** the largest of each breaker's own peak while it runs, and the above once it has
  finished.

Streaming lowers today's peak by the collect sink's copies (its chunks and their concatenation, "about
twice its output", §3). It does not lower what the sources and breakers hold. The tests that check these
peaks measure the process's anonymous resident memory, so they see what no counter does (§9.2).

**The context's pool, and what it does not hold.**

- **Operators draw from one pool per context.** Today each run builds its own segment pool
  (`set_memory_budget` "replaces the pool", `real_builder.mojo:351-355`), sized by the context's budget.
  With one run at a time per context, that was one budget per context. With open streams, two runs can be
  open at once, so the engine core (§5.10) holds one pool for the context, and every run's builder draws
  its operators' reservations from it.
- **Each run keeps its own tally.** A pool's handles share one counter today (`SegmentPool.share()`,
  `segment_pool.mojo:52-58`), so the end-of-run check that the run returned what it took
  (`EXECUTE_POOL_NOT_RELEASED`, which reads `builder.pool_granted()`, `engine_execute.mojo:172-178`) would
  see the other runs' grants. The engine-core slice adds a per-run tally layered over the shared counter:
  every grant and return of a run's handles updates both, and the end-of-run check reads the run's tally.
- **Operators of two runs never hold the pool at once in a way today's engine could not.** Every segment
  and every round runs under the context's dispatch lock (§5.9), so the operators of two runs are never
  running together. A breaker returns its reservations when it finishes, and its published output is not
  charged, as today. So a sort that runs under the budget today still runs, whatever streams are open.
- **What a stream holds for its reader is not charged to the pool,** and neither is its own state, as
  today's answer and today's `Result` are not (the collect sink's chunks and concatenation are not
  charged, §3). So an unread `Result`, or several, can never make another query's sort or window fail with
  `MEMORY_BUDGET_EXCEEDED`. A stream's held bytes are bounded by its own two limits instead, and when its
  run is over it holds only its queue (§5.2, step 7).
- **What that means for a caller holding several streams.** Each open stream that is still running holds
  at most its own bound, plus what its source holds (the table above). A finished stream holds the batches
  the reader has not taken, no more than today's `Result` holds. As today, the number of open results is
  not bounded, and each holds memory outside the pool. Unlike today, an unfinished stream holds a part of
  its answer and not all of it.

An open stream whose run is not over holds its outstanding bytes, what its last stage holds (the table
above), its open files and mappings, and its parked driver thread. Building a last stage over a Parquet
file set opens every file of the set and reads its footer (`parquet_source.mojo:245-267`). Each file
stays open and mapped until the run is over (§5.2, step 7).

**The kernel's read-ahead.** A mapping asks the kernel, by default, to read the whole file ahead
(`madvise(MADV_WILLNEED)` over the whole mapping, `byte_buffer/src/byte_buffer/mmap_region.mojo:235`,
`:341`). The Parquet scan already maps its files without that hint (`advise_whole_file=False`,
`parquet/file_reader.mojo:386`, and `parquet/runtime_footer_cache.mojo:328` for the pinned mapping). So
what remains outside the limits is the scan's own per-claim range hint (§5.8). It is page cache, not the
process's memory, but it counts in a container's memory limit, and release does not undo it.

**The throughput check.** The open-call slice measures a streamed full scan against the materialised run
of the same Parquet file, at 1 and at 16 workers, and reports both in its pull request. It is a
measurement, not a test (tests never assert time), and no build fails on it. It is the reviewer's gate
for that slice: the streamed scan must reach at least 90% of the materialised run's rows per second at
each worker count.
- If it does not, the byte limit's default is doubled and the measurement repeated, up to the budget cap.
- If it still does not reach 90%, the slice does not land until the cause is fixed within it: the
  stride-1 claims, or the idle time between rounds. If the cause is the idle time, the read-ahead of §5.1
  is built inside the open-call slice, and the read-ahead slice is folded into it.

The same measurement is made over a 64-file glob, and over a resident table, so that the build of the last
stage and the in-memory source are measured as well. It is also made for `SELECT * FROM big LIMIT 5`
against today's run of it, counting the row groups decoded and the peak anonymous memory: with one claim
per worker in the first round, both should be today's.

For the shapes that stream, no queue in this design is unbounded, and nothing watches memory at run time:
the limit is the bound. A run materialised inside the stream (§5.11) queues its whole answer, a root
breaker hands out its whole output, and one morsel's operator output is uncapped; each is bounded only as
today's run is.

### 5.4 Order, and what each source must change

**The rule.** A streamed result comes out in the order the same query's materialised result has today:

- **A scan, filter or project pipeline** comes out in source position order, the order
  `CollectSink.combine` sorts by. For Parquet that is file order, then row group order, then the order
  within a row group. That is the order DuckDB gives with `preserve_insertion_order` on (its default), so
  the rule that results equal DuckDB's holds for the order too.
- **`ORDER BY`** comes out in the sort's order. The sort is a breaker (§5.6), so its output is complete
  before the first batch is handed out.
- **A grouped aggregate** has no specified group order today (`sink_group_agg.mojo`), and keeps none.

**How rounds keep it.** Within a round, the result sink sorts by position, as `combine` does. Across
rounds, order holds if two things are true:

1. **Claims are monotone in position.** Every claim a later round takes has a higher position than every
   claim of an earlier round. That holds when each claim is the next unit, in position order, from one
   atomic cursor.
2. **No round ends with a claim half done.** A worker is stopped only between claims, after it has
   drained the sub-morsels of the claim it holds (§5.2).

**Each kind of source the real builder serves** (`real_builder.mojo`, `build_source`), and what the
source limits slice changes in it. The last stage is built once (§5.2), so no source is rebuilt or reseeded
between rounds: each keeps its own cursor, as it does within one run today.

- **Parquet, local or remote** (`ParquetSource`). It can run in rounds.
  - Its cursor is `rg_cursor`, advanced in `_claim` (`src/parquet_scan/parquet_source.mojo:551-572`,
    the `fetch_add` at `:565`). The limit goes there, as the compare-and-swap loop of §5.3.
  - The cursor-grain route hands out grains of a claim this cursor took (`_plain_claim` opens it after
    `_claim`), so it needs no limit of its own.
  - The row-range split of a large row group has its own counter
    (`src/parquet_scan/parquet_source_subrg.mojo:297`), which `_next_morsel_claim` reaches before
    `_claim`. It is off by default (`subrg_mode = 0`, `parquet_source_options.mojo`), and a streamed run
    keeps it off until a later slice puts the limit on that counter.
  - A streamed run builds the source with stride 1 (`forced_cursor_stride`, one claim per cursor move).
    When that option is set the claim order is ignored and the per-worker range cache stays empty
    (`parquet_source.mojo:423-425`). The real builder passes the source no options today, so the slice
    adds a parameter to both `build_parquet_source` (local) and `build_parquet_source_on` for it. The claim order (`claim_order`) and parked-morsel
    sharing (`share_parked`) are not used by the real builder today.
  - `next_morsel` returns `None` on a refusal without ending the worker, and the source answers
    `is_exhausted()`.
- **A table in memory, a breaker's output, a `UNION ALL`, and the whole-decoded CSV, JSONL and Iceberg
  files.** All of these are served by `BatchMorselSource` (through `BatchSource` and `SinkOutputSource`),
  which cuts its batch into morsels when it is built. They can run in rounds.
  - Its cursor is the atomic slot index of its morsel array, with a per-worker range cache over it and an
    optional stealing mode (`batch_morsel_source.mojo:678-720`). The limit goes at the slot claim.
  - A streamed run uses stride 1, through a new option on `BatchMorselOptions` (the stride is the
    constant `_CURSOR_STRIDE` of 32, shrunk near the end). Its stealing mode is not used by the real
    builder.
  - Its contract today is single-pass: after `None` "the scheduler must not call again". A streamed run
    changes that: `None` on a refusal means "ask again next round", and `is_exhausted()` tells the two
    apart.
  - Its morsels are swapped out of the array as they are claimed, so a morsel handed out once is never
    handed out again. That is what the rounds need, and it is why the source must live for the whole
    stream (§5.10): a published output is taken from `PublishedOutputs` once (`published_outputs.mojo:89-100`,
    a second take raises "was taken"), and a resident table is copied at each build.
- **A source whose cut refuses a column type.** The in-memory cut refuses list, map, struct, union, large
  string and large binary columns (§5.3). A last stage that would cut such a column fails today in a
  materialised run too. A root breaker's output is not cut today, because it is the answer, and so a
  stream hands it out uncut (§5.6).

The ordered hand-out then needs no window beyond the round. The cost is one cursor move per claim instead
of the adaptive stride of up to 32 claims per move (`parquet_source_options.mojo`, `adaptive_stride`).
The throughput check (§5.3) measures that cost.

**An unordered stream**, handing out each claim as it finishes, is not offered (§12, decision 4).

### 5.5 LIMIT

Today a `LIMIT` without `ORDER BY` is exact in count, but not in which rows survive. With several workers,
whichever worker reached the shared budget first keeps its rows (`op_limit.mojo`), and the other
workers' scans keep running after the budget is spent (`src/pipeline_exec/README.md`, Known limits). A
limit that is not over a sort is lowered into the pipeline as an `OP_LIMIT` (`cut_limit.mojo`). Its row
budget is a `LimitBudget` made in `LimitShared` when the operator's shared parts are made, and
`build_source` drops the parts of an earlier run of the segment, so that "a plan run twice on one builder
spends a fresh limit each time" (`real_builder.mojo` header).

In a streamed run:

- **A limit that is the last operator of the root pipeline, in a run decided to stream,** is left out
  of the root segment's operators when the last stage is built: `open_sql` records an operator count one
  less than the plan's, and the limit's count, which the result sink takes (§5.2). The lowered plan itself
  is not changed. The lowering, the lowered plan's rendering and its goldens, and the plan wire
  do not change.
  - The result sink counts the rows it hands out in position order, and cuts the batch that crosses the
    count with the same function the limit operator cuts with today (`_slice_batch_first_n`,
    `src/column_kernels/batch_slice.mojo:28`, called at `op_limit.mojo:115`). That function copies the
    first rows of string, binary, large string, large binary, dictionary, boolean and fixed-width columns,
    and writes each at offset 0. It raises for list, struct, map, union and fixed-size binary columns
    (its last arm calls `element_size`, `compiler_helpers.mojo:3242-3265`). Today's limit operator meets
    the same raise whenever a limit crosses a morsel of such a column, so a stream fails exactly where
    today's run does.
  - It then finishes the run: no further round runs, and the driver runs `finalize`, returns from its
    frame and ends (§5.2, step 7). It cancels no token, so the batches already queued stay readable, and
    the reader then gets the end. So that `LIMIT` returns the first rows in file order, which DuckDB
    returns too, and reads no more than one round past them.
  - `LIMIT 0` builds the last stage, takes the empty answer's schema (§6.3), takes no claim, and ends.
- **A run that runs materialised keeps every limit of the plan.** It runs the plan's own lowered plan,
  whose limits are operators as today (§5.2). So `SELECT ... FROM a JOIN b ... LIMIT 10`, which runs
  materialised because its last pipeline has a probe, stops its workers early as it does today: the limit
  reports `FINISHED` and each worker stops claiming (`op_limit.mojo:97-118`,
  `segment_task.mojo:124-125`).
- **A limit with an operator above it in the same pipeline** stays an operator. The last stage is built
  once (§5.2), so its row budget is made once and is shared by every round: the limit counts the rows of
  every round, and stays exact in count, as today. The rows that survive depend on the schedule, as
  today. Today a worker that sees the limit report `FINISHED` stops claiming (`segment_task.mojo`,
  `_push` and `_work`), but in rounds every round starts every worker again. Each would take a claim, see
  the spent limit and return, until the source was exhausted, decoding the rest of the file for nothing.
  So after each round the driver asks each limit's shared budget whether it is spent
  (`LimitBudget.taken() >= limit`, `op_limit.mojo`). Once one is, the driver runs no further round: it
  pushes the tails of the operators above, runs `finalize` and ends the stream. That check is part of the
  rounds slice.
- **A `LIMIT` over a sort** is the top-N breaker, as today.

The lowering cuts no limit offset outside a sort (`cut_limit.mojo`), so the result sink carries a count
only.

### 5.6 What does not stream by nature

A breaker finishes before its output exists: a sort, a top-N, a grouped or ungrouped aggregate, a
`DISTINCT`, a window, and a join's build side. When the last pipeline's input comes from one of them,
the stream waits for it:

- **The first `get_next` returns only after the breakers below have finished.** For
  `SELECT region, sum(x) FROM t GROUP BY region`, the whole scan and aggregation happen inside the first
  `get_next`. The aggregate is the root, so its output is handed out as the one batch it is (below).
  With a filter or projection above it, as in `SELECT * FROM (... GROUP BY region) WHERE ...`, the
  pipeline above reads the published output through the in-memory source and hands it out in rounds.
- **Meanwhile** `komira_run_progress(run, &done, &total)` counts segments as today, and
  `komira_run_cancel(run)` stops the run at its next check, which is the next morsel inside a breaker's
  pipeline. A breaker's `combine`, sort or merge does not check the token today, so a cancel that lands
  there waits for it to finish.
- **Memory** for these queries is what §5.3's table lists for a breaker's output: the breaker's own peak
  while it runs, then its output and the output's cut into morsels, plus the bound for the batches handed
  out. The breaker's output stays uncharged, as today.
- **A root segment that is itself a breaker** (a final `ORDER BY` or aggregate, with no pipeline above it)
  has its output as the result today: "the root of the plan is a `SINK_COLLECT` unless its top node is
  itself a breaker whose output is the result" ([lowering_and_pipeline.md](lowering_and_pipeline.md)). In a
  streamed run the driver runs it as today, and passes its output, one batch, through the hand-out step
  (§5.12) uncut. It is not put through the in-memory source, whose cut refuses some column types the
  breaker's output can hold (§5.4), and it is already in memory whole. The lowering does not change.

The Python and Node bindings pull the first batch inside `sql()` (§7.1), so for these queries `sql()`
waits for the breakers, as it waits today.

### 5.7 Errors after the first batch

**The rule.** An error while producing a claim is handed out after every batch from the claims before
it in position order, and before any batch from that claim or a later one. Where each claim yields one
batch, the error raised while producing, say, the 37th batch is returned by the 37th `get_next`, and not
before. Where a claim yields several batches, the count is of claims, not batches.

**How.** Today a worker's error cancels the segment. `SegmentRun.fail` records the first error in time
(`set_error_cas`) and calls `pipeline.cancel()`, which `should_stop()` reads, so the other workers drop
their morsels mid-way (`segment_task.mojo:74-82`). A streamed round changes that:

- A worker's error records the failing claim's position and the error in a slot that keeps the **lowest
  position**, not the first in time, and refuses every further claim. It does not cancel the pipeline: `should_stop()` stays true only
  for the stream's token.
- The other workers finish the claims they hold, sub-morsels included, and take no more.
- An error in `next_morsel` itself (a decode error) is recorded at the claim the source was producing.
- Every claim before the failing one in position order was taken before it, because claims are monotone
  (§5.4). So when the round ends, every one of them has finished. The result sink queues their batches,
  then the error. It discards every chunk from the failing claim and later ones, including any the
  failing claim pushed before it failed.
- When two workers fail in one round, the error at the lower position wins. That is deterministic, where
  today's first error in time is not. The error costs at most one claim per worker of extra work.
- An error in the tails or in `finalize` comes after every claim.

A cancel is not an error at a position. It stops every worker at its next check, and the stream hands out
nothing more (§5.8).

**What the reader sees.**

- `get_next` returns an errno: `ENOMEM` for `MEMORY_BUDGET_EXCEEDED`, and `EIO` for every other engine
  error.
- `get_last_error` returns the text today's run calls put in the context's last error,
  `<CODE>: execute: <reason>`.
- The code and step are on the run handle (`komira_run_error_code`, `komira_run_error_step`, §6.3), so no
  binding parses the text.
- Every later `get_next` returns the same errno and text: a failed stream stays failed. The reader must
  still call `release`.

This replaces, for streamed runs only, the rule "no partial result" with a narrower one: **a stream never
hands out a batch after an error, and never ends normally after an error.** A reader that reads to the
end without an error has the whole answer. A reader that wants all or nothing reads everything before
using any of it, which is what `to_arrow()` does (§7.1).

### 5.8 Cancel and release

- **`komira_run_cancel(run)`** works from any thread, at any time, as today.
  - A `get_next` that is waiting for a round or a breaker returns `ECANCELED` once the workers reach their
    next check (the next morsel, or the next chunk of an emitting operator).
  - `get_last_error` then returns
    `QUERY_CANCELLED: execute: pipeline_exec: the query was cancelled: the caller cancelled the run`,
    today's cancel text (`src/so/tests/c/abi_driver.c`).
  - A `get_next` after the cancel returns the same, without running anything.
  - A cancel after the end has been returned does nothing (§5.2).
- **`release` before the end** ends the run. Release is called by the reader, never concurrently with
  `get_next` (the Arrow rule). Rounds run only while a `get_next` waits for them, so when release is
  called the driver thread is parked between requests, and release never waits for a round. (With the
  read-ahead of §5.1 a round could be running, and release would then wait for the slowest claim in
  flight.) Release:
  - cancels the stream's child token (§5.2), so a breaker's spill files and the like see a cancel. It
    never cancels the run handle's own token: a cancel of the control is one-way and reaches "every run
    given this control, now or later" (`src/sdk_exec/run_control.mojo:11-12`, `:54-62`). So an early
    release, or a limit's end, leaves the caller's handle, every other stream opened with it, and every
    later call given it, as they were;
  - if the run is not yet over, tells the driver to stop. The driver returns from its frame, which frees
    what the frame holds (§5.2, step 7): the last stage (the source with its cursor, its copies and morsels,
    its open files and mappings, its prefetch buffers, and the operators' shared parts), the published
    outputs not yet consumed, the builder, the footer cache, the expression pool and the lowered plan.
    Release joins the driver thread, so when it returns the thread has ended and every one of those is
    freed. If the run is already over, the frame went and the thread ended then, and there is nothing to
    stop;
  - frees the queue of batches the reader did not take, and the error or the end;
  - drops the stream's share of the run handle's control and of the engine core (§5.10).
- **After release the source is read no more.** No round can start, and the driver has ended. The Parquet
  source gives the operating system an advisory read-ahead hint for the next row group at the end of each
  claim (`_prefetch_next`, `parquet_source.mojo:749-763`, `:800`). The hint is for the row group after
  the one just claimed, so the last allowed claim of each worker hints one row group beyond the limit. A
  hint asks the page cache to read ahead; the engine itself reads no byte of it.
- **Arrays already handed out** stay valid after release, as today: each owns its share of the buffers.
- **The run handle** may be freed while the stream is open, because the stream holds its own share of the
  handle's control. `komira_run_free`'s rule "only once no call given it is running" is unchanged:
  `komira_sql_open` has returned.

### 5.9 Many runs on one context

Today Python holds its session lock for the run call only, and reading a `Result` takes no lock
([python_package.md](python_package.md), "a `Result`'s batch reads take no lock"). So
`r1 = s.sql(a); r2 = s.sql(b); r1.to_arrow()` works, and so does reading `r1` on one thread while
`s.sql(b)` runs on another. Streamed results keep both.

**PROPOSED: a dispatch lock in the engine core.** One dispatch at a time per dispatcher stays the
runtime's rule. Today nothing in libkomira needs a lock for it, because Python's session lock and Node's
session thread serialise every run. With streams, the driver threads of two streams, and a caller running
a materialised query, may each want the dispatcher, so a lock serialises them.

- **Where it is taken.** Every dispatch on a context's dispatcher comes from one place: `run_segment`'s
  `run_with_state` (`src/pipeline_exec/run_segment.mojo:115`), reached through
  `run_lowered_plan_with`'s `ctx.runtime.dispatcher()` (`src/sdk_exec/engine_execute.mojo:159`). No
  other code in `sdk_exec` or `so` takes the dispatcher. No sink is given a dispatcher: `combine` takes
  none (`morsel/morsel_sink.mojo`), and the sort sorts on the calling thread. The CSV reader and the
  column kernels take an optional dispatcher the real builder never passes. So the lock is taken in
  exactly three places, and any later code that dispatches inside a segment runs under the same lock:
  - around each `run_segment` call of a materialised run, covering its dispatch, tails, `combine`,
    `finalize` and `take_output`;
  - around each breaker segment and the build of the last stage of a streamed run, on its driver thread;
  - around each round of a streamed run, and around its tails and `finalize`, on its driver thread.
- **Who takes it.** Only driver threads and callers' threads take it, never a worker. A worker blocking on
  its own runtime is the hazard [async_runtime.md](async_runtime.md) rules out.
- **Waiting for it.** Today's locks block on a futex word and no cancel wakes them (`async_rt/sync`,
  `async_mutex.mojo`: "`lock()` blocks the calling thread on `wait_on_address`"), and a cancellation
  token is an atomic flag with no waker (`token.mojo:134-170`). So the dispatch lock is waited on with
  `wait_on_address`'s timeout (`async_rt/runtime/wake_primitives.mojo:170-173`, `timeout_ns`) in 1 ms
  slices, re-reading the stream's token between slices. That is how the dispatch barrier already waits
  (1 ms waits, [async_runtime.md](async_runtime.md)). A run waiting for the lock ends with `ECANCELED`
  within one slice of a cancel. The wait watches a cancel flag, not memory, so it is no watchdog.
- **The runtime goes inside the lock.** `dispatcher()` takes `mut self`
  (`async_rt/runtime/runtime.mojo:887`), so the worker runtime moves into the engine core behind the
  dispatch lock, and a run reaches the dispatcher only by taking the lock. Its one call site in the engine,
  `run_lowered_plan_with`'s `ctx.runtime.dispatcher()` (`engine_execute.mojo:159`), changes to take the
  lock. So do the tests that reach `EngineContext.runtime` directly; the engine-core slice's pull request
  lists each one it changes.
- **What a waiter waits for.** A run that wants the dispatcher waits for the round or segment in progress.
  That is engine work, never a reader.

Consequences:

- **Two open streams on one context** interleave by rounds. A third query, materialised, runs between
  their rounds.
- **A run reads no mutable context state after open** (§5.2). So registering a table, adding a binding or
  starting another query while a stream is open does not change what the open stream reads. It reads the
  catalog as it was when it opened.
- **A file changed while a stream is open.** Today a run reads its files while it runs, and its answer
  is a concatenated copy that no longer refers to them. A stream reads its files across many rounds, while
  the caller reads, so the window in which a file can change under it is the run's whole life. What a
  reader would see without a rule:
  - **A local file truncated or rewritten in place.** Local scans read a private, read-only mapping of
    the file (`parquet/file_reader.mojo:375-392`, `:525-545`; `borrow_mmap_erased` hands out buffers that
    borrow it). Reading a page of a mapping past the file's new end raises `SIGBUS`, which ends the
    process: not an error, a crash. pandas' and pyarrow's `to_parquet` rewrite a file in place.
  - **A local file replaced by a rename,** as writers that write a temporary file and rename it do. The
    source still reads the old file through the mapping it holds, so the stream answers from the old file.
    That is safe and consistent, and today's run of the same query would finish too.
  - **A remote object replaced.** Later row groups are read at the offsets of the old footer from the new
    object: wrong rows, or a decode error.

  The rule makes each case safe, in three parts:
  - **Handed-out batches never refer to a mapping.** The hand-out step copies the window of any column
    whose buffers still borrow a file mapping into heap memory before the batch is queued (§5.12, step 5).
    A buffer can tell whether it borrows a mapping (`SharedAlignedBuffer.is_mmap_backed()`,
    `byte_buffer/src/byte_buffer/shared_aligned_buffer.mojo:1029`). So once a batch is in the reader's
    hands, nothing the file does can reach it, as today's concatenated answer is unreachable.
  - **Each claim checks its local file first, by inode.** When the last stage is built, the source records
    each local file's device, inode, size and modification time. That needs a `stat` the local file
    system does not offer today: it has only `file_size` (`fs/local_fs.mojo:1019`), and the mapping closes
    its descriptor once mapped (`mmap_region.mojo:327-331`). So the source limits slice adds a stat call to
    the file system's C shim. Before it decodes a claim, the source stats the path:
    - the same inode with a different size or modification time means the file was rewritten in place,
      and the stream fails by name, as an error at that claim's position
      (`STREAM_SOURCE_CHANGED: <path>`);
    - a different inode, or no file at the path, means the file was replaced or removed. The old inode is
      intact under the held mapping, so the stream keeps reading it, as above.

    The check is made only in a streamed run. A materialised run does not make it, so nothing changes for
    the old calls.
  - **Each claim reads a remote object only if it is still the object whose footer was read.** Today the
    file system's reads return only the bytes (`fs/file_system.mojo:386`, `:423`), and no store's file
    system carries an entity tag. So the source limits slice adds, as a defaulted method on the
    `FileSystem` trait, a conditional ranged read: S3's and Azure's `If-Match` on the entity tag from the
    footer's read, and GCS's generation match. Each of the S3, Azure and GCS file systems implements it.
    A read whose condition fails fails the stream by name at that claim (`STREAM_SOURCE_CHANGED: <url>`).
  - **What is left.** A truncation in place that lands after a claim's check, before the round's batches
    are copied at hand-out, can still fault, exactly as it can today while a materialised run reads the
    file. The mapping-backed buffers are read by the operators and held in the result sink until the round
    ends, so that window is one round. Today it is the whole run, and without the rule it would be the
    stream's whole life.

  Today the scan already reads footers again after lowering (komira-ai/komira#2024). A stream reads them
  once, when the last stage is built, and the check above compares each claim with what that read saw.
- **A stream fed back into the engine** (`komira_register_arrow_stream` given a komira stream, or Python's
  `register(name, result)`) is drained whole by the registering call into the registered table, as any
  registered stream is (`src/so/sources.mojo`). Its `get_next` calls ask its driver for rounds, and the
  driver takes the dispatch lock per round. The registering call holds the session (Python takes its
  session lock), but not the dispatch lock while it reads, so the two do not wait on each other.

The cost: a long breaker in one run holds back every other run on the context for its duration. That is
already the case today, since runs on one context are serialised.

### 5.10 What the stream owns, and why it has a thread

**The engine core.** The stream must outlive the context. `komira_ctx_free` may come first today, and §5
of [libkomira_run_abi.md](libkomira_run_abi.md) requires the stream to hold an `ArcPointer` on any state it
needs that `komira_ctx_free` tears down. A streamed run needs the worker runtime with its dispatcher, the
dispatch lock and the context's pool. These move into an engine core held by `ArcPointer`:

- The context holds one share, and each stream whose run is still going holds one. The driver drops the
  stream's share when the run is over (§5.2, step 7), because a finished stream's queue needs no engine.
- `komira_ctx_free` drops the context's share.
- The core, and with it the worker threads, stops when the last share is dropped: by the context, by the
  end of the last running stream's run, or by its release. So closing a session (`komira_ctx_free`,
  Python's `Session.close`) no longer stops the worker threads at once while a stream's run is still
  going: they stop when that run is over or released. A finished `Result` keeps no worker alive.
- The thread that drops the last share joins the worker threads, which are idle between rounds. That
  thread is never a worker. It may be a garbage collector's: pyarrow releases an imported stream when the
  reader is collected, with the GIL held. No worker and no driver thread ever needs the GIL, so that join
  cannot wait on it:
  - SQL does not call Python functions;
  - the plan door refuses a plan that carries a Python function today (`PLAN_WIRE_UDFS_DROPPED`, at
    decode, `src/so/sources.mojo:465`);
  - the UDF designs in this repository run a plan's Python functions in separate worker processes
    ([udf_python_worker.md](udf_python_worker.md)), so that stays true when plans carry them.
- The Node addon's finalizer hands the release to the session's native thread, rather than running it on
  the event loop.
- **Credentials.** A stream reads a remote store with the credentials resolved at open, for as long as its
  run lasts. Whether the opener refreshes an expiring credential cannot be told from the code
  *(inferred: it does not)*. If it does not, a stream whose credentials expire mid-read fails at the claim
  that meets the expiry, with the store's error, at that claim's position. A materialised run of the same
  length would fail the same way.

**The driver thread.** The last stage must live for the whole stream, for two reasons the code gives:

- **Some sources cannot be built twice.** A breaker's published output and a `UNION ALL`'s branches are
  taken from `PublishedOutputs` once (`real_builder.mojo:541`, `:552-566`; a second take raises). A
  resident table is deep-copied and cut into morsels at every build (`real_builder.mojo:520`), and a
  Parquet file set reads every file's schema when the source is built. A limit's row budget is made when
  the parts are made, and `build_source` drops the parts of an earlier run (`real_builder.mojo:451-452`),
  so a rebuild would give each round a fresh budget.
- **The builder borrows.** `RealBuilder` holds the Parquet metadata cache and the expression pool as
  pointers with the origins of the frame that made them (`Pointer[ParquetMetadataCache, cache_o]`,
  `real_builder.mojo`, field `_cache`; made in `run_lowered_plan_with`'s frame,
  `engine_execute.mojo:116-121`). The Parquet source borrows them the same way (`build_parquet_source_on`
  takes `ref [cache_o] cache` and `ref [pool_o] pool`, `src/pipeline_exec/source_parquet.mojo`).

So the stream keeps one frame alive for its run's life: the frame of its driver thread. That frame holds
the cache, the pool, the builder, the published outputs and the last stage, exactly as
`run_lowered_plan_with`'s frame holds them for one call today. Nothing is rebuilt, nothing refers to
itself, and no pointer type appears in any public signature.

- **How it is made.** The driver thread is a plain operating-system thread, outside the worker runtime,
  started through `async_rt`'s own thread boundary, the one that starts its worker threads
  (`async_rt/runtime/pthread_worker.mojo`), with a second entry for a thread that is not a worker. Two
  other `pthread_create` boundaries exist (`async_api/spawn_drop.mojo`, and `fork_join/_pthread.mojo`,
  which is private to `fork_join`). `fork_join`'s header warns that two bindings of the call with
  different argument types can fail to compile, so the driver reuses `async_rt`'s binding shape rather
  than adding a fourth. The entry carries the boundary comment that says who owns and frees each
  pointer.
- **What it does between rounds.** It parks on a wake word, holding no lock and no dispatch. A request
  from `get_next` or `get_schema`, or a stop from release, wakes it.
- **When it ends.** When the run is over (the end queued, a limit reached, an error, a cancel, or a run
  materialised inside the stream done), it returns from its frame and ends, without waiting for release
  (§5.2, step 7). So only a stream whose run is still going has a thread.
- **What it costs.** One parked thread per stream whose run is still going, and its stack. It is not
  charged to the pool (§5.3).
- **What it is not.** It is not a read-ahead driver: it runs a round only when a reader asks (§5.1).

Not chosen: owning the built last stage in the `StreamedRun` value itself, rebuilt or not. A struct that
owned the cache and pool and also a builder borrowing them would refer to itself. That is not expressible
with the origins the Mojo rules allow (no pointer type in a public signature, no wildcard origins). Changing
the builder and the Parquet source to hold the cache and pool by shared ownership (`ArcPointer`) instead
of a borrow would avoid the thread. That change is larger, across `pipeline_exec`'s and `parquet_scan`'s
generic parameters and their tests. It stays open as later work if a thread per open stream proves costly.

### 5.11 What streams, what runs materialised inside the stream, and what runs inside open

`komira_sql_open` and `komira_plan_open` accept every statement the materialised calls accept. Each
statement is one of three kinds.

**A statement with effects runs to completion inside open.** That is `COPY ... TO`, and through the plan
door a plan with a write target (the pandas `to_*` and polars `sink_*` writers). For these, open does
exactly what `komira_sql_stream_run` does today, on the caller's thread:

- It runs the statement, writing the file all or nothing, before the call returns.
- Its errors are the call's status, with the code and step in the context's last error and on the run
  handle.
- A cancel through the run handle stops it, as today.
- Only then does it fill `*out`, with a stream of its one `Count` row.

So whether the file is written never depends on the caller reading the stream. A caller that opens a
`COPY` and releases the stream unread has the file, and a failure is reported by the open call itself.
When streamed writes land (§8, the writes slice), the write streams inside the engine, still within open.
Writes are the one kind of statement whose open call does not return before the work is done.

**A query whose shape cannot stream yet is run materialised inside the stream.**

- Its first request makes the driver run the plan's own lowered plan, its limits included (§5.5),
  exactly as `run_lowered_plan_with` does today. The driver passes the batches through the same hand-out
  step as streamed batches (§5.12), queues them, and the stream hands them out.
- Its memory is today's, and its errors come from that first call.
- The SDK reads such a stream like any other: Python's `sql()` pulls the first batch, which runs the whole
  query, and the rest of the `Result` reads from memory. Node does the same. So the result reaches the SDK
  computed whole, as it does today.

**When the choice is made.** Every reason to run materialised that the plan shows is decided at open,
before anything runs. In the first slices that is one reason: a join probe in the last pipeline. One reason can show only when the last stage is built: a Parquet file set whose files disagree
on a column (§6.3). A Parquet last stage has nothing below it but join builds: the optimizer turns
subqueries into joins, an `IN` over a subquery becomes a semi-join probe, and a shared subplan cut as a
breaker is read through `SOURCE_SINK_OUTPUT`, not Parquet. A probe is decided at open, so in that case
nothing has run when the stage is built. The driver drops the stage, and runs the root segment whole
through the same builder, with the plan's full operator list, as `run_segment` runs it today. The
progress counter is started once, at the first request (`RunProgress.start`, `run_plan.mojo:64`, which
adds to the total), and the fall-back does not start it again; it counts the root segment when it
finishes (`:85`). The cost is the footers read twice, never the answer.

**A result whose columns depend on its data** has no schema before it runs: a pivot, whose column names
are values in the data, is one. Such a query is run in two parts. The first part's result, the values
that become columns, returns to the SDK. The SDK then builds the second part, whose columns are now
known, and runs it, and the second part streams like any other query. The plan has no node for such a
query today: `pivot`, `pivot_table`, `melt` and their kin are refused with "the plan has no node for it"
([dataframe_surface_verbs.md](dataframe_surface_verbs.md)). So no such shape exists in the first slices.
A result with a nested column is not one of them: it streams like any other, and its child types come
from the first batch (§6.3).

**Every other query streams.** After the first slice that is the last pipeline over a Parquet file set, a
table in memory, a breaker's output, a `UNION ALL`, or a whole-decoded CSV, JSONL or Iceberg file,
through filters, projections and limits.

So no binding needs a fallback of its own, and no statement is left undone through the open call. No
statement that works today fails through it either, within the one limit §6.3 states ("What the promise
covers"). The shapes below are the ones that do not stream fully in the first slices:

| shape | what happens | streams fully from |
|---|---|---|
| a CSV source in the last pipeline | the file is decoded whole when the last stage is built (§3), then handed out in rounds | the CSV slice, which claims byte ranges |
| a JSONL or Iceberg source in the last pipeline | the same | a later slice |
| `UNION ALL` | each branch is its own segment, run whole and published, then concatenated into one batch when the last stage is built (`cut_union.mojo`, `real_builder.mojo:552-566`); the hand-out then runs in rounds | a later slice, when branches stream into the union |
| a join probe in the last pipeline | runs materialised inside the stream, its limits kept: one claim's output is not bounded (§5.3) | a later slice |
| a Parquet file set whose files disagree on a projected column's decimal precision or scale, timestamp unit or zone, width hint, presence, list item name, struct field order, or nested child type | runs materialised inside the stream, decided when the last stage is built (§6.3) | not planned: the files themselves disagree |

The test of each materialised row asserts that the answer equals the materialised one, and that the
source's claims before the first batch are all of them, which is what "materialised" means. The test of
each row that streams after a whole decode asserts that the answer equals the materialised one, and that
the hand-out takes no more claims than the claim limit before the first batch.

### 5.12 The hand-out step

Every batch a stream hands out passes through one step in the result sink, in this order:

1. **Order.** The round's chunks are sorted by position (§5.4).
2. **Selection.** A selection mask is materialised where one is present. For a streamed round this is
   already done: `CollectSink.consume` materialises a morsel's mask before it keeps the chunk
   (`sink_collect.mojo:100`). So the step does it only for the batches of a root breaker and of a run
   materialised inside the stream, as `arrow_result` does today.
3. **Limit.** A trailing `LIMIT` (§5.5) cuts the batch that crosses its count, with
   `_slice_batch_first_n`, the function the limit operator uses today. The cut batch has every column at
   offset 0.
4. **Schema.** The batch is checked against the stream's schema, and conformed where it can be (§6.3).
5. **Offsets.** Which columns of a handed-out batch can start at a non-zero offset:
   - The morsel split leaves only non-nullable fixed-width and dictionary columns at a non-zero offset, as
     zero-copy views (`morsel.mojo:838-841`, `Column.supports_zero_copy_slice`,
     `src/arrow/column.mojo:634-660`). It gives strings, binaries, booleans and nullable fixed-width
     columns offset 0: strings get rebased offsets (`morsel.mojo:863`), and the rest are copied (`:975`).
   - It refuses nested, large string and large binary columns outright (§5.3), so a cut morsel never holds
     one. Such a column reaches the hand-out only uncut:
     - in a root breaker's output (§5.6);
     - in a run materialised (§5.11);
     - in a decoded Parquet row group of at most one morsel's rows, which the source hands out whole. For
       Parquet that size is the segment's own `morsel_rows`, which the morsel sizing policy sets per host
       and row width (`morsel_sizing_policy.mojo`; 0 means one row group per morsel). It is not
       `DEFAULT_MORSEL_ROWS`, which applies to the other sources (`real_builder.mojo:455-507`).

     A larger row group is cut by `split_and_stash_first` (`parquet_source_emit.mojo:99`), which uses
     the same split and so refuses those columns today, in a materialised run as in a stream.
   - The exporter exports fixed-width and dictionary-index columns at their offset
     (`src/arrow_ipc/c_data_stream.mojo:1448`). So a column at a non-zero offset of any other type, at any
     depth, is not expected. Should one appear, the step copies it to offset 0 and counts the copy before
     it is made, so the bound covers it.
   - **A column whose buffers borrow a file mapping has its window copied.** A local Parquet read hands
     out buffers that borrow the file's mapping (`borrow_mmap_erased`, `parquet/file_reader.mojo:538-542`).
     Whether a decoded column can still alias such a buffer cannot be read from the decoder's code alone.
     So the step does not depend on the answer:
     - for each column whose data, offsets, validity or dictionary buffer borrows a mapping
       (`is_mmap_backed()`), the step copies the column's window, its `offset` to `offset + length`, into
       fresh buffers at offset 0, rebasing string offsets and validity, and recursing into children;
     - a buffer shared whole, such as a dictionary's values, is copied once per distinct buffer, not once
       per morsel.

     A morsel's column is a slice that shares the whole buffer (`Column.slice`,
     `src/arrow/column.mojo:662-716`), so copying the buffer instead of the window would copy the whole
     column chunk once per morsel. The copy is counted (§5.3). The file-change rule (§5.9) depends on this,
     and a test plants a mapping-backed column to show the copy is made.
6. **Export check.** The batch is checked as `check_record_batch_stream` checks every batch of a
   materialised answer today (`src/arrow_ipc/c_data_stream_check.mojo:47-110`):
   - Every array is built and released, and every dictionary column is checked against its field
     (`_check_dictionary_export`).
   - That check builds each array from its column alone and compares no other type property with the
     field (`c_data_stream.mojo:1615-1700`). So it is step 4, not this step, that guards against a batch
     whose types differ from the stream's schema.
   - The function also builds the stream's schema on every call (`:102-103`), so the rounds slice splits
     out a per-batch check that does only the per-batch part, and the stream's schema is built once.
   - A batch that fails is not queued, and its error becomes the stream's error at that batch (§6.3). So a
     queued batch always exports, and `get_next` never fails while building an array.
7. **Queue.** A batch of no rows is dropped here, never queued. The old calls' drain keeps its one batch of
   no rows for an empty answer (§6.5).

The step runs for every path: the batches of a streamed round, a root breaker's output, the batches of a
run materialised inside the stream (§5.11), and, after the old calls slice, the drained batches of the old
calls (§6.5). The one `Count` row a statement with effects answers is built by the open call itself and is
not passed through it.

**Small batches.** A selective filter leaves small batches, one per morsel, and the step does not
coalesce them in the first slices. The open-call slice measures batches handed out per second, and the
cost of pyarrow's `to_arrow` over them, on a filter that keeps 1% of a 64-row-group file. Coalescing is
added if that measurement shows the per-batch cost matters.

**The importer.** The Arrow importer refuses every array with a non-zero offset (`_import_column`,
`c_data_stream.mojo:1821-1825`), and the batch import calls it for every top-level column (`:2860`). A
komira stream registered back into komira (`komira_register_arrow_stream`, Python's
`register(name, result)`) would meet that refusal for every zero-copy fixed-width morsel, and so would a
foreign stream such as a pyarrow slice.

The importer copies by design: it "copies all buffer bytes" (`c_data_stream.mojo:1786-1790`), taking
`length` elements from the start of each buffer (`:2450-2470`). So the source limits slice changes the
copy, not the copying:

- it takes an array at any offset, of every type, and copies only its window;
- for a fixed-width or dictionary-index buffer, the window is `length` elements from
  `base + offset * width`;
- for a variable-length array, it is the offsets from `offset` to `offset + length`, rebased to start at 0,
  and the payload bytes they cover;
- the validity bitmap is rebased to offset 0 in the same pass, so nulls stay at their rows;
- children of a nested array take their own offsets the same way.

The copy is no larger than today's for an array at offset 0, and it copies the window rather than
`offset + length` elements. Keeping the offset instead would copy each morsel's whole prefix, quadratic
over the morsels of one column. Copying at hand-out instead would copy the zero-copy slices of every
query, a cost on the common path that the throughput check would carry.

## 6. The C interface

### 6.1 One shape, new calls

The result stays an Arrow C stream (`struct ArrowArrayStream`), allocated by the caller and filled by
libkomira. That is the one shape every Arrow consumer imports: pyarrow, Arrow C++, arrow-rs, DuckDB,
polars, ADBC. Only when it is produced changes. Four rows are added, in the golden's form
(`symbol<TAB>return<TAB>arguments<TAB>since`, `src/so/abi/komira.tsv`):

```text
version	1.12
komira_run_error_code	Int32	Handle,UnsafePointer[UInt8],UInt64,UnsafePointer[UInt64]	1.11
komira_run_error_step	Int32	Handle	1.11
komira_sql_open	Int32	Handle,CStr,Handle,ArrowStream	1.11
komira_plan_open	Int32	Handle,ConstBytes,UInt64,Handle,ArrowStream	1.12
```

The minors shown are examples. Each change takes the next minor at the time it lands (§6.6), and other
open changes also claim 1.11.

```c
int32_t komira_sql_open(komira_handle ctx, const char *sql, komira_handle run,
                        struct ArrowArrayStream *out);
int32_t komira_plan_open(komira_handle ctx, const uint8_t *plan, uint64_t plan_len,
                         komira_handle run, struct ArrowArrayStream *out);
int32_t komira_run_error_code(komira_handle run, uint8_t *buf, uint64_t cap, uint64_t *needed);
int32_t komira_run_error_step(komira_handle run);
```

No existing row changes, and no constant or status code is added. The errno values the stream returns
come from a C shim, as today (platform constants come from a C shim, never from literals).

**Why new calls, and not new behaviour behind the old ones.** Each of these reasons alone would break a
binding that is already shipped:

1. **The status contract.** A binding of `komira_sql_stream` today learns of an execution error from the
   call's status, with the code and step in `komira_last_error_code` and `komira_last_error_step`. A
   stream that returns `KOMIRA_OK` and fails later would turn every such error into an errno from
   `get_next`, which the shipped Python and Node packages do not expect. Python would raise a pyarrow
   `OSError` from a read instead of a `KomiraError` from `sql()`, and both would lose the code and step.
   That is a silent re-meaning of a shipped call, which the rule that a shipped call or format changes
   only by addition rules out.
2. **The plan door has no run handle.** `komira_plan_stream` cannot be cancelled today, and a stream that
   runs after the call returns needs a cancel that does not depend on reading it.
3. **Lifetime.** A materialised stream holds batches and nothing else. A streamed one holds a share of an
   engine core and of a run. A caller that relied on the old calls finishing their work before they
   returned (for example, timing a query by the call) keeps that.

Not chosen: **a handle of our own** with `next`, `cancel` and `progress` calls. The run handle already is
the cancel and progress half, and the Arrow stream already is the `next` half. A third type would be a
second way to read a result, and no consumer could import it.

### 6.2 What `komira_*_open` does

The order of checks is `komira_sql_stream_run`'s:

1. A NULL `ctx` returns -1.
2. The context's last error is cleared.
3. A NULL `sql`, `plan` or `out` returns -2. A NULL `run` is allowed: the stream then has no out-of-band
   cancel and no structured late error, and release is still a cancel.
4. The length checks of today's calls (-5).
5. Parse, bind, optimise and lower. A refusal returns -3 (or -6 if `run` was already cancelled), with the
   code, step and text in the context's last error, exactly as today. `*out` is untouched.
6. A statement with effects (`COPY ... TO`, a plan with a write target) runs to completion here, as
   `komira_sql_stream_run` runs it today (§5.11). Its refusal or failure is the call's status, and `*out`
   is untouched. On success `*out` is a stream of its one `Count` row.
7. Any other statement is marked streamed or materialised (§5.11), and its driver thread is started
   (§5.10).
8. `*out` is filled, and the call returns `KOMIRA_OK`. **For a query, no file has been opened.**

Today's calls refuse, before `*out` is written, a result column whose type the exporter cannot carry,
because they check the finished answer (`check_record_batch_stream`). An open call has no schema yet: the
schema exists once the first batch exists, or, for an empty answer, once the last stage is built (§6.3). So that refusal moves to the first `get_schema` or
`get_next` (§6.3).

### 6.3 The stream's callbacks, its schema, and the run's error

| callback | before the first batch | while reading | after the end, an error or a cancel |
|---|---|---|---|
| `get_schema` | asks the driver for the first batch, as `get_next` would, and keeps that batch for the first `get_next`; returns the stream's schema (below). For a result run materialised, that runs the query (§5.11) | the same schema | the schema, if one was settled; if the first batch failed or was cancelled before a schema was settled, the same errno as `get_next` |
| `get_next` | asks the driver for rounds until a batch, the end or an error (§5.2) | the next held batch, or more rounds | at the end: 0 and a released array, every time. After an error: `ENOMEM` or `EIO`, every time. After a cancel: `ECANCELED`, every time |
| `get_last_error` | NULL | NULL | the text of the error or cancel, valid until the next callback or `release` |
| `release` | ends the run and joins its driver, freeing everything (§5.8) | the same | frees what is left; idempotent |

For a statement with effects, the work is done by the open call, so the stream holds only its one `Count`
row, already computed: `get_next` returns that row, then the end, and `release` frees it (§5.11).

**The stream's schema.** Today the stream's schema is the first batch's
(`src/sdk_exec/arrow_result.mojo:73`, `schema = batches[0].schema.copy()`), which is also the
concatenation's (`concat_record_batches_nway` takes `batches[0].schema`, `arrow/concat.mojo`). The
lowered plan carries no schema (`src/lowering/lowered_plan.mojo`: segments, parameters, the result
segment's id). A streamed run keeps today's rule, with one change:

- **It is the first batch's schema, with every field nullable.** The first `get_schema` or `get_next`
  runs the breakers, builds the last stage, and runs rounds until the first batch exists or the end
  (§5.2). The stream's schema is then that batch's schema, with every field marked nullable.
  - A schema taken from the first batch cannot disagree with it. Nothing has been handed out before it is
    settled, the schema included.
  - It costs `get_schema` the first round. Python and Node pull the first batch inside `sql()` anyway
    (§7), so for them nothing changes.
  - A nested column's child types come from that batch, as today's export builds them
    (`_build_record_batch_schema(schema, batches[0])`, `c_data_stream.mojo:2880-2903`). So a result with
    a nested column streams like any other.
- **Nullability.** Every field nullable is the one way a streamed schema differs from today's. Today a
  field's nullability is the first batch's. A later batch of a stream can carry a null where the first
  batch had none: the union merges validity, and outer joins and aggregates can make nulls. A schema that
  said otherwise would make such a query fail when its first null arrived. Every field nullable is always
  true of the batches, and every Arrow reader accepts it. The old calls keep today's rule (§6.5).
- **An empty answer.** With no batch, the stream's schema is the one the engine derives for an empty
  answer today, with every field nullable:
  - for a last pipeline whose sink is a collect, a sort or a top-N, `RealBuilder._result_schema`
    (`real_builder.mojo:637`, `:698`, `:718`; it is what `CollectSink` answers an empty result with);
  - for a root aggregate or window, the output schema the plan declares in the sink's data
    (`sink_agg.mojo:273`, `sink_window.mojo:88-99`).

  It is turned into the Arrow schema exactly as today's: today an empty answer is one batch of no rows
  (`so/sources.mojo`, `sql_result`), which the sink builds with `empty_batch_like_schema`
  (`CollectSink.take_output`, `sink_collect.mojo:136-141`; `sink_window.mojo:252`;
  `column_kernels/compiler_helpers.mojo:1227`), and the export builds the schema from that batch as its
  sample (`c_data_stream.mojo:2885-2903`). The stream builds the same batch of no rows and passes it to
  the same schema builder, without handing it out. So an empty answer with a nested column gets whatever
  schema today's gives it, or the refusal today's gives it, and never a different one. A test runs an
  empty nested result through the old and the new path and asserts the two agree. Where today's engine
  cannot build the derived schema at all (`_result_schema` returns none through a bare `except`, and
  `CollectSink` raises when there are no rows and no schema), the stream fails the same way.
- **A root breaker** (a final sort or aggregate, handed out as one batch, §5.6) follows the same rule:
  its schema is its one batch's, with every field nullable, or its sink's schema when it is empty.
- **Every later batch must agree with it.** The type, the string and binary width, the decimal precision
  and scale, the timestamp unit and zone, dictionary or not, and list item names and struct field order
  must be the same in the schema and in every later batch. The hand-out step (§5.12, step 4):
  - converts a string or binary column whose width differs from the schema's, in either direction. A
    later batch the engine promoted to the large form, where the schema says the plain form, is narrowed
    back, and split into batches that each fit a 32-bit offset when its data does not. A plain later
    batch under a schema the first batch made large is widened. `RecordBatchBuilder.build` widens a
    schema to match a wide column and refuses the reverse (`arrow/record_batch.mojo:261-320`). So both
    conversions, and the split, are new code, listed in the rounds slice. The copies they make are counted
    as the batch's bytes (§5.3);
  - needs nothing for nullability, since every field is nullable;
  - refuses any other difference by name at that batch (`STREAM_BATCH_TYPE_DIVERGED: <column>: <what
    differs>`, as `EIO` from that batch's `get_next`), rather than export a batch its schema misdescribes.
    The export check does not compare types (§5.12, step 6), so this is the only guard.
- **A file set whose files disagree.** The one known way a later batch can disagree is a Parquet file set
  whose files differ on a column. The source takes each field from the first file that holds the column
  (`parquet_source.mojo:596-628`). It checks only the Arrow type's tag across files
  (`parquet/parquet_source_helpers.mojo:279-322`), while the decimal precision and scale and the
  timestamp zone are properties of the field (`arrow/schema.mojo:1010-1022`). It builds a missing column's
  nulls from the tag alone (`parquet_source_helpers.mojo:388-389`, `_build_typed_all_null_column`). A
  nested column's list item name, its struct field order and its child types are properties of the field
  too, and files written by different writers differ on exactly these (a list's item called `item` in one
  and `element` in another). So a batch from file k could disagree with the schema from file 1 after
  earlier batches were handed out. The source has every file's footer when the last stage is built (§5.3).
  So the build compares each projected column's properties across all files (a column the query does not
  read cannot reach a batch, so a difference there does not matter): decimal precision and scale, timestamp
  unit and zone, width hint, presence, and for a nested column its item names, its field order and its
  child types, at every depth. Any difference makes the run fall back to materialised before any claim
  (§5.11). Today's run concatenates such files under the first file's schema, and the fall-back is that
  run.
- **What the promise covers.** This is the one place the promise is stated; §5.11, §10 and §12 refer to
  it. No query that works today fails because it streams: the first batch defines the schema, the files
  are compared before any claim, and width differences are converted in both directions. The
  one case left is a later batch that disagrees for a reason neither of those can see. That would be an
  engine defect, and it fails by name at that batch. The open-call slice looks for such cases on real
  queries: a Mojo runner in `src/sdk_exec/tests` reads every case of the SQL conformance corpus
  (`src/tests/conformance/komira_sql_conformance/cases/`). It registers each case's tables twice: from
  Parquet files, as the corpus's existing runner does, and as resident tables in memory, so that both
  kinds of source are swept. The corpus's tables are small, so most answers would be one morsel and the
  check of later batches would be thin. The runner therefore forces the smallest morsel size the sizing
  policy allows (1,024 rows) and, through a test hook, a claim limit of one, so every case with more than 1,024 rows yields
  several batches over several rounds. It runs every query streamed and materialised, and asserts that
  every streamed batch agrees with the stream's schema and that the two answers are equal. The existing
  runner belongs to the TypeScript package and cannot stream before the bindings slice. A case the sweep
  finds disagreeing is either fixed in the engine or made a reason to run materialised, before the slice
  lands.
- **What the sweep cannot cover.** It cannot cover data the corpus does not have: file sets from several
  writers (which the build's comparison covers instead), answers of fewer than 1,024 rows (which are one
  batch, so cannot disagree with themselves), and engine paths no corpus case reaches. A later batch that
  disagrees on such a path is the residual of the promise: it fails by name at that batch, after the
  batches before it were handed out.

**Export refusals.** Today `check_record_batch_stream` builds every array of every batch before the call
returns, so `get_next` never fails while building one (`c_data_stream_check.mojo:47-110`). A streamed run
cannot check batches that do not exist yet. Where each refusal goes now:

| refusal | today | streamed |
|---|---|---|
| a column type the exporter cannot carry (for example run-end encoded) | the call, -3 | the first `get_schema` or `get_next`, `EIO` |
| a dictionary column with numeric values, a dictionary-encoded child of a nested column | the call, -3 | the `get_next` of the first batch that has it, `EIO`, from the hand-out step's export check (§5.12, step 6) |
| a dictionary column under a string field, or an index width that disagrees with the field | cannot happen: the field is the batch's own | cannot happen for the first batch, for the same reason; a later batch whose column differs from the first batch's is refused by the schema step as a divergence |
| a column at a non-zero offset the exporter refuses | cannot happen (one concatenated batch) | cannot happen: the hand-out step copies it first (§5.12, step 5) |

Every refusal in the first two rows is one today's call also makes, so none of them fails a query that
works today.
A query that fails today now fails at a read instead of at the call. Python and Node pull the first batch
inside `sql()` (§7), so for them it still fails at `sql()`, unless the first such batch comes later. A
queued batch has passed the export check, so `get_next` never fails while building an array.

**The run's error.**

- **`komira_run_error_code(run, buf, cap, &needed)`** writes the failed run's code (for example
  `MEMORY_BUDGET_EXCEEDED`, `QUERY_CANCELLED`) in the two-call form of `komira_last_error_code`.
- **`komira_run_error_step(run)`** returns its `KOMIRA_STEP_*`.
- Both read the run handle, which outlives the context. The caller keeps the handle for as long as it
  wants the code and step. The stream holds only its own share of the handle's control, so a freed handle
  is not read.
- They return an empty code and `KOMIRA_STEP_NONE` while the run has not failed, and may be called from
  any thread, like `komira_run_progress`.
- Today `RunControl` holds a cancel token, a progress counter and a claim cell, and no error
  (`src/sdk_exec/run_control.mojo:28-34`). The handle itself is an `OwnedPointer` freed by
  `komira_run_free` (`src/so/_c_abi.mojo`). The open-call slice adds the code and step in a shared cell
  (an `ArcPointer`, like the claim cell), so the stream's share of the control can set them after the
  caller has freed the handle. From then on today's run calls given a handle set them as well, so one way
  of reading a run's error serves both kinds of call.

**Also:**

- **`EINVAL`** for a NULL argument or a call on a released stream, as today.
- **A batch with no rows** is never handed out by a stream: an empty answer is its schema, then the end.
  The old calls keep their one batch of no rows (§6.5).
- **A batch's size** is one morsel's output. Batches are not coalesced in the first slices.

### 6.4 Threads

- **One reader at a time.** `get_schema`, `get_next` and `release` are serialised by the reader (the
  Arrow rule). They may be called from any thread, one after another.
- **`komira_run_cancel`, `komira_run_progress` and the two error calls** may be called from any thread,
  at any time, also while a `get_next` is running. That was already true of the run call.
- **`get_next` blocks** while the driver runs a round or a breaker for it. While it waits it holds no lock
  of the context.
- **Each stream whose run is still going has one driver thread** (§5.10), parked between requests. It
  ends when the run is over; release joins it if the run is not.
- **The context.** `komira_ctx_free` may run before the stream is read or released (§5.10).
- **The library stays loaded** while a stream is live, as today: the callbacks are its code.

### 6.5 The existing calls

`komira_sql_stream`, `komira_sql_stream_run` and `komira_plan_stream` keep their contract:

- the answer is computed before the call returns;
- every execution error, an export refusal included, is a status;
- `*out` is written only on `KOMIRA_OK`;
- an answer of no rows is one batch of no rows with the answer's schema (`src/so/sources.mojo`,
  `sql_result`);
- the schema is today's: the first batch's, in position order (`concat_record_batches_nway` takes
  `batches[0].schema`; `arrow_result.mojo:73`).

In the old calls slice they are rebuilt inside libkomira as open-then-drain on the calling thread, so
there is one run mechanism. The drain runs every round before the call returns, keeps the batches, and
builds today's stream over them. Every drained batch has passed the hand-out step's export check before
`*out` is written, so a refusal is still the call's status and `get_next` still cannot fail. The schema is
the first drained batch's, as the concatenation takes it today, not the stream's every-field-nullable
schema. An answer of no rows is still one batch of no rows, built from the schema the engine derives for
an empty answer today (§6.3), with that schema's own nullability. For these calls the change is then
invisible except that:

- the answer arrives as one batch per morsel, instead of one concatenated batch. That saves the
  concatenation's copy and half of the peak (§3);
- a final `LIMIT` returns the first rows in file order (§5.5), which matches DuckDB where today's result
  may not.

### 6.6 Versions and bindings

- **The version.** Each change that adds rows takes the next minor when it lands on `main`. A row's
  `since` is that minor. The change raises `ABI_MINOR`, the `gate_version` pin and the export list
  (`gate_no_extra_exports.mojo`), adds the `abi_driver.c` cases, and regenerates `komira.h`.
- **Older library, newer binding.** A binding that finds no `komira_sql_open` falls back to
  `komira_sql_stream_run`, so the user gets the answer, materialised, as before. The binding checks each
  symbol at its first use ([libkomira_run_abi.md](libkomira_run_abi.md) §11).
- **Newer library, older binding.** An older binding never calls the new symbols, and the old calls keep
  their contract (§6.5).
- **The cross-version tests** run a binding of each version against the existing stand-in library of the
  previous minor (`node/tests/fake_libkomira.c`, `python/tests/fake_libkomira.c`). The test is
  `binding_falls_back_when_the_library_has_no_open_call` (§9).

## 7. The SDKs

### 7.1 Python

- **`Session.sql(query)`** calls `komira_sql_open` when the library has it, and then **pulls the first
  batch before it returns** (§12, decision 5).
  - An error before the first batch (every parse, bind, optimise and lower refusal, every execution error
    of a breaker below, and every error of a query run materialised, §5.11) still raises `KomiraError`
    from `sql()` with its code and step, as today.
  - Only an error after the first batch is raised later, by whichever read reaches it.
  - A query that finds nothing returns at once.
  - The batch pulled is kept and handed out first.
- **Every read happens on the helper thread.** The pull, and every later read by every terminal, runs on
  the helper thread that runs `komira_sql_stream_run` today (`python/komira/_run.py`). The calling
  thread waits as it does today, so Ctrl-C cancels through the run handle. The terminals are
  `to_reader()`'s batches, `to_arrow()`, `to_pandas()`, `to_polars()` and `_repr_html_`.
- **The run handle lives as long as the `Result`.** Today `_Call.finish` frees it before the `Result`
  exists (`_run.py:110-120`). A streamed `Result` keeps it, for Ctrl-C, for `Result.cancel()` (below),
  and for the late error's code and step.
- **The schema a `Result` reports changes.** A streamed result's schema marks every field nullable
  (§6.3). A Parquet file with required columns used to answer `int64 not null`, and now answers `int64`.
  That is visible in `Result.to_reader().schema`, in `to_arrow()`'s table schema, and in anything that
  compares schemas. The bindings slice says so in its changelog entry and updates the binding tests that
  compare schemas.
- **`Result.to_reader()`** returns a `pyarrow.RecordBatchReader` that streams. To keep komira's error type,
  it is `pa.RecordBatchReader.from_batches(schema, gen)`, whose generator reads the next batch on the
  helper thread. It turns pyarrow's exception into `KomiraError`, with the code and step read from the run
  handle (`komira_run_error_code`, `komira_run_error_step`), never from the text. `ECANCELED` becomes the
  cancelled status.
- **`to_arrow()`, `to_pandas()`, `to_polars()`** read everything and are all or nothing. A late error
  raises and returns nothing, as today.
- **`__arrow_c_stream__`** hands the raw stream to DuckDB, polars or pyarrow, which read it lazily on
  their own threads. Errors are then theirs to raise. Ctrl-C reaches the run only through the handle the
  `Result` keeps, so the slice adds `Result.cancel()`, which calls `komira_run_cancel`. It is a new public
  method, and the bindings slice's pull request marks it as an interface change.
- **`_repr_html_`** reads only the first rows it shows (`_read_head`), so for a streamed result it reads
  one or two rounds, not the whole answer.
- **The pandas DataFrame path** (`DataFrame.materialize()`) and `komira.pl`'s `collect()` go through the
  plan door, so they stream only once `komira_plan_open` lands (the plan-door slice).
- **GIL.** pyarrow calls `get_next` with the GIL released. Neither SQL nor the plan door runs a Python
  function in the engine's threads (§5.10). So a round never waits on the reader's interpreter, and a
  release under the GIL joins a driver thread that needs nothing from Python.

**`read_csv(path, chunksize=n)` and `iterator=True`.** pandas returns a `TextFileReader`. It iterates over
chunks of `n` rows, has `get_chunk(size)` and `close()`, and is a context manager. Each chunk is a pandas
`DataFrame` with a `RangeIndex` that continues across chunks. komira's form:

- `read_csv(path, chunksize=n)` or `iterator=True` returns `komira.TextFileReader`, with `__iter__`,
  `get_chunk(size=None)`, `close()` and `with`.
- It opens one streamed run of the file's scan, with the column types the engine infers today.
- It cuts the stream's batches into chunks of exactly `n` rows by slicing, and joins slices only across a
  batch boundary.
- A malformed line raises when the chunk that holds it is read, and the reader then closes, as pandas'
  does.
- `chunksize < 1` raises pandas' `ValueError`.
- **What a chunk is** is the one open decision (§11).
- **Prerequisite:** a CSV source that streams (the CSV slice). Today the CSV source decodes the whole file before the
  first morsel, so a chunked read would read the whole file before its first chunk.

**polars (`komira.pl`).**

- `LazyFrame.collect(engine=...)` takes `"auto"`, `"streaming"` and `"in-memory"`, which all run the same
  engine, and refuses `"gpu"` by name. It still returns a `Result`.
- `LazyFrame.collect_batches(chunk_size=None, maintain_order=True)` returns an iterator over the streamed
  run, with chunks of the type §11 decides. `maintain_order=False` is refused by name (§12, decision 4). It
  lands with that decision.
- `sink_parquet`, `sink_csv` and `sink_ndjson` already write through the engine, with no row returned to
  Python. They stream their writes when §8 lands, with no change to their signatures.

### 7.2 Node

`Result` keeps its two reads (`node/src/result.ts`). The addon's `sql` calls `komira_sql_open` and pulls
the first batch on the session's native thread before the promise settles, for the reason given for
Python. It then keeps the stream, instead of draining it.

- **`for await (const batch of result)`** runs each `get_next` on the session's native thread, and
  settles one promise per batch.
- **`return()`** (a `break` out of the loop) releases the stream, which ends the run.
- **`toArrow()`** reads everything.
- **`sql(query, { signal })`** binds the run handle; it is the cancel the TypeScript design already plans
  ([typescript_package.md](typescript_package.md), "Cancellation"). An abort while reading rejects the
  pending `next()` with the cancelled `KomiraError`.
- **A collected `Result`** is released on the session's native thread (§5.10).
- **A late error.** The Node `Result` keeps the run handle the addon made for the query, beside the
  stream. When a `get_next` on the session's native thread returns `EIO`, `ENOMEM` or `ECANCELED`, the
  addon reads `komira_run_error_code` and `komira_run_error_step` from that handle on the same thread, and
  rejects the pending `next()` with a `KomiraError` carrying the code, the step and `get_last_error`'s text.
- **The schema** of a streamed `Result` marks every field nullable, as in Python, and the TypeScript
  package's goldens that hold schemas change with the bindings slice.

### 7.3 Mojo

The Mojo SDK's design is pull request komira-ai/komira#2496. Its `Result` lends one materialised batch
(`batch()`, a `ref [self] RecordBatch`) over `run_sql`. The streamed form is a second type beside it,
not a change to `Result`:

```mojo
struct ResultStream(Movable):
    def schema(self) -> Schema
    def next(mut self) raises -> Optional[RecordBatch]   # None at the end; raises KomiraError late
    def cancel(self)                                     # any thread, through a shared RunControl
    # dropping it before the end ends the run, as release does
```

`Session.sql_stream(query: String) raises -> ResultStream` wraps `sdk_exec.open_sql` directly, in process,
with no C call. It lands after the first slice, in the Mojo SDK's own slice, with a README example, as every new public Mojo API has.

## 8. Writes

**EXISTS.** `COPY ... TO` and the SDK writers (`to_csv`, `to_parquet`, `sink_*`) do not stream today.

- They run the query to one batch.
- They encode the whole file in memory: Parquet with `parquet_writer`, CSV and JSON with
  `engine_write_text`, and gzip or zstd compressed whole.
- They write it with `write_file_atomic`: a temporary file in the destination's directory, synced and
  renamed (`src/sdk_exec/engine_write.mojo:5-12`).
- A failure leaves the destination as it was.

**PROPOSED (the writes slice).** A write is a streamed run whose reader is a writer inside the engine: the same
`StreamedRun`, the same rounds and the same bound, without the C stream. The writer takes the earlier
engine's streaming writer's shape (§2.1):

1. It opens the temporary file first.
2. It appends batches as they arrive, coalescing them up to a row group: Parquet row groups of
   `DEFAULT_MAX_ROWS_PER_RG` rows, and CSV or NDJSON lines through a streaming gzip or zstd encoder.
3. At the end it writes the footer, syncs and renames, then answers its one `Count` row.
4. On an error or a cancel it removes the temporary file, and the destination stays as it was.

The guarantee "all or nothing" is unchanged. The memory is the stream's bound plus one row group, instead
of the answer plus its encoded file. The rows are written in the stream's order (§5.4).

So writes share the mechanism (the streamed run), not the interface (the C stream). The write's reader is
in the engine, so the round loop runs on the thread of the call that runs the statement. For
`komira_sql_open` and `komira_plan_open` that is the open call itself (§5.11). The call returns when the
file is renamed.

## 9. Tests

Every test is hermetic (no network, no fixed paths, no shared state) and asserts no time: "first",
"before" and "after" are counted in bytes, claims, batches and events. Where they live:

- the engine tests in `src/pipeline_exec/tests`, `src/parquet_scan/tests`, `src/op_sources/tests`,
  `src/arrow_ipc/tests` and `src/sdk_exec/tests`;
- the C tests in the C driver (`src/so/tests/c/abi_driver.c`);
- the binding tests in `python/tests` and `node/tests`.

Four test-only parts make the counts possible:

- **A generated source.** A `pipeline_exec` source that makes each claim from its index and stores
  nothing. A claim is a counter column of 131,072 rows of 8 bytes, 1 MiB, and one morsel unless a test
  asks for more. Its estimate of a claim is exact. It counts its claims and the bytes it has made. It can
  fail at a chosen claim, and it can signal an event and then wait on another at a chosen claim. "A 10 GB
  scan" is 10 GiB / 1 MiB = 10,240 claims of 1 MiB from it, generated and never held.
- **A counting file system.** The run takes an opener for remote stores (`run_sql_with`'s
  `ScanFsOpener`), but a local path never reaches it: `build_source` reads a local spec through the local
  file system directly (`real_builder.mojo`, `spec.parquet_fs.is_local()`). So the engine tests that count
  bytes name their files under a test scheme. The test's opener serves that scheme with a file system over
  the scratch directory that counts every byte read, every footer read and every file opened and closed,
  and that does not map files. The C-level tests cannot inject an opener (the session's opener is
  `store_opener(session)`), so they count claims, not bytes.
- **A counting builder.** A test wrapper over `RealBuilder` counts each `build_source` and each
  `build_op`, by segment. An operator's shared parts are made privately (`_parts_index`), and dropped only
  by `build_source`, so "`build_source` once" is what proves "parts made once".
- **Anonymous resident memory.** The process's peak resident memory (`Counters.now()`, `getrusage`'s
  `ru_maxrss`, `src/engine_runtime/counters.mojo`) is no use here. It counts the pages of mapped files, and
  the local file system maps a whole file with `MADV_WILLNEED` and keeps its touched pages
  (`byte_buffer/src/byte_buffer/mmap_region.mojo`, `fs/local_fs.mojo`). So a streamed scan of a local file
  would show the file's size whether it streamed or not. The tests instead sample the process's anonymous
  resident memory after each `get_next` and take the largest sample. On Linux that is `RssAnon` from
  `/proc/self/status`; on macOS it is the task's physical footprint *(inferred: that it counts anonymous
  pages and not clean file pages)*. `engine_runtime` gains a small helper that reads it. Each test also
  reads its files through the counting file system, which does not map them. Its fixture files are written
  by a separate build step, not by the test process. Each test pairs its streamed case with a control case
  that shows the measurement can see the memory in question.

### 9.1 The four tests that prove the promise

- `first_batch_arrives_before_the_scan_ends`. A streamed run over the 10 GiB generated source, with four
  workers. When `get_next` returns batch 1, the source has taken at most 4 claims, one per worker in the
  first round, of the 10,240 claims there are. Its estimates are exact and its columns need no copy, so
  there is no excess. The same over a Parquet file of 64 row groups written by a build step: at the first
  batch the counting file system has read the footer and at most 4 row groups. Later rounds take at most
  8 claims each.
- `a_streamed_scans_resident_memory_is_its_bound_not_its_file`. A Parquet file of 128 MiB in 64 row groups,
  written by a build step, read to its end through a stream with a byte limit of 4 MiB (set through a test hook), one batch per
  `get_next`, through the counting file system. The largest sample of anonymous resident memory rises by
  under 32 MiB over the read: the bound, one decoded row group per worker, and a margin. The control,
  reading the same file through the materialised run, rises by over 128 MiB. The stream's own counter's high-water
  mark of outstanding bytes is checked too, and is at most 4 MiB plus one row group per worker.
- `early_release_stops_reading_the_source`. Read 3 batches, record the claims and the bytes read, then
  release. When release returns, the stream's driver thread has ended. There is no further claim and no
  further byte read, every file the opener opened is closed, the pool's granted bytes are 0, and an array
  taken before the release still reads its values.
- `an_error_in_the_37th_batch_arrives_on_the_37th_get_next`. The generated source (one batch per claim,
  claims numbered from 1, four workers, the real dispatcher) fails at claim 37. Calls 1 to 36 return
  batches whose first values are `0, 131072, 2 × 131072, ..., 35 × 131072`, in order. Call 37 returns
  `EIO`, with `get_last_error` exactly `GENERATED_SOURCE_FAILED: execute: claim 37`, and the run handle's
  code `GENERATED_SOURCE_FAILED` and step `KOMIRA_STEP_EXECUTE`. Call 38 returns the same. The error is not
  seen before call 37.

### 9.2 The rest of the contract

**Rounds** (the rounds slice, with the fake dispatcher, the generated source and the counting builder):

- `the_last_stage_is_built_once_for_every_round`: a stream read over 20 rounds calls `build_source` and
  makes each operator's shared parts once.
- `a_claim_is_taken_only_within_the_limit`: with a claim limit of 3 and four workers, no more than three
  claims are ever outstanding, read from the limit's counter after each round.
- `one_claim_is_allowed_when_nothing_is_outstanding`: a byte limit below one claim's size. Every
  `get_next` still returns a batch, and the high-water mark is one claim.
- `a_claim_and_its_reservation_are_one_step`: workers race on the last claim under a limit with room for
  one. Exactly one takes it, and the limit's counter returns to its start once every batch is handed out.
- `a_first_round_that_yields_nothing_runs_another`: a filter rejects every row of the first round's
  claims. The first `get_next` causes a second round and returns its first batch.
- `batches_come_out_in_position_order_whatever_the_schedule`: workers finish in reverse order (fake
  dispatcher). Every batch's positions increase, across rounds.
- `a_lower_position_error_wins`: the source fails at claims 40 and 38 in one round, the failure at 40
  first. The fake dispatcher (`fake_dispatch.mojo`) runs each task to the end in turn, so with one shared
  cursor the first task would take consecutive claims and meet 38 first. In this test the generated source
  therefore hands each worker its claims by worker id: worker k takes the round's claims k, k + workers,
  and so on, as a per-worker source does. Every claim of a round is still below every claim of the next.
  The dispatcher runs the worker that holds 40 first. The stream hands out 37 batches, then claim 38's
  error.
- `an_error_discards_the_failing_claims_own_chunks`: a claim that yields three batches fails after its
  second. Neither of its batches is handed out, and the error follows the batches of the claims below it.
- `cancel_from_another_thread_ends_a_waiting_get_next`: the source signals an event when a worker reaches
  claim 5, then waits there on a second event. The reading thread's `get_next` is waiting for the round.
  The cancelling thread waits for the first event, calls `komira_run_cancel`, then sets the second. The
  reading thread's `get_next` returns `ECANCELED`, with exactly
  `QUERY_CANCELLED: execute: pipeline_exec: the query was cancelled: the caller cancelled the run`, and
  the next call returns the same.
- `a_trailing_limit_returns_the_first_rows_and_stops_claiming`: `LIMIT 1000` over the generated source
  returns its first 1000 rows, in position order, and ends, with no more claims taken than the claim limit.
- `a_limit_below_a_projection_counts_across_rounds`: `LIMIT 300000` with a projection above it, over
  several rounds of the generated source. Exactly 300,000 rows come out in total, not 300,000 per round,
  and the counting builder shows `build_source` called once.
- `a_spent_limit_below_a_projection_ends_the_stream`: the same query over the 10 GiB generated source. The
  stream ends in the round after the budget is spent, and the source has taken no more claims than the
  limit's rows need plus one round.

**The hand-out step** (the rounds slice):

- `every_handed_out_column_follows_the_offset_rules`: a table in memory with a column of every type the
  cut serves, nullable and not (integer, float, boolean, decimal, date, timestamp, dictionary, string,
  binary), cut into morsels. In every batch handed out, only non-nullable fixed-width and dictionary
  columns start at a non-zero offset, and every other column starts at 0. Every batch exports.
- `a_root_breaker_with_nested_and_large_columns_is_handed_out_uncut`: an aggregate whose output holds a
  list, a struct and a large string column (from a Parquet file with the large-string hint). The stream
  hands out its output as one batch, every child starts at offset 0, and the answer equals the
  materialised one.
- `a_mapping_backed_column_has_its_window_copied_at_hand_out`: a test hook makes the sink receive, from
  eight morsels of one row group, a column whose buffer borrows the file's mapping. Each batch handed out
  holds a heap copy of its own rows only (the bytes copied are its window's, not the chunk's), and no
  queued batch has a mapping-backed buffer.
- `a_column_left_at_an_offset_is_copied_before_it_is_queued`: a test hook hands the step a string column
  and a list child at a non-zero offset. Both are copied to offset 0, the copy is counted before it is
  made, and the batch exports.
- `a_trailing_limit_cuts_as_the_limit_operator_does`: a trailing `LIMIT` over a Parquet file with a large
  string and an integer column, in row groups of fewer than 1,024 rows (below the morsel sizing policy's
  floor, so they reach the sink uncut on every host), and the same over a resident table with a dictionary
  column. (A Parquet scan decodes a dictionary column to strings unless a string-keyed aggregate asks it
  not to, `real_builder.mojo:462-465`, so the dictionary case needs a table in memory.) The batch that
  crosses the count is cut by `_slice_batch_first_n`, every column of it starts at offset 0, it exports,
  and the answer equals today's. The same with a list column fails with the error today's run of the same
  query fails with.
- `limit_zero_ends_after_the_schema`: `LIMIT 0` returns its schema and the end, and the source has taken
  no claim.
- `a_materialised_join_with_a_limit_stops_early`: a join of two 64-row-group files with `LIMIT 10`, which
  runs materialised because its last pipeline has a probe. The probe side's claims before the end are no
  more than the workers' first claims and one more each, as in today's run of the same query, and not all
  64.
- `a_growing_projection_stays_within_the_bound`: a projection that casts an integer column to text over
  the generated source, so each claim's output is larger than its estimate. After every `get_next`, the
  stream's outstanding bytes are at most the byte limit plus one claim's real output per worker, and they
  equal what the retained-bytes function measures over the held batches.
- `the_first_round_takes_one_claim_per_worker`: with four workers, the first round takes at most four
  claims and every later round at most eight.
- `the_retained_bytes_function_counts_a_shared_buffer_once`: eight morsels cut from one decoded row group
  are counted with that row group's buffers once.
- `a_decode_error_is_ordered_by_its_claim`: the generated source raises inside `next_morsel` while
  decoding claim 12. The stream hands out the batches of claims 1 to 11, then that error.
- `the_end_stays_the_end_after_a_cancel` and `a_returned_error_stays_after_a_cancel`: after `get_next`
  returned the end, or an error, a cancel of the run handle changes nothing: the next `get_next` returns
  the same again.
- `a_finished_stream_holds_only_its_queue`: for each way a run can be over (the end queued, a trailing
  limit reached, an error, a cancel, and a join run materialised inside the stream), with batches still
  queued and the stream not released. A test hook reports that the driver's frame is gone: no builder, no
  source, no published output, no footer cache, no expression pool, no open file or mapping (the
  counting file system's open count is 0), the driver thread has ended, and the engine core's share is
  dropped. The anonymous resident memory, less the queued batches' bytes, is back to what it was before
  the query, within a margin.
- `an_export_refusal_is_the_error_of_its_batch`: a table in memory whose third morsel holds a dictionary
  column with numeric values. Batches 1 and 2 are handed out. The third `get_next` returns `EIO` with the
  exporter's message for it, and no batch with that column is ever handed out.

**The sources and the importer** (the source limits slice). These run before `komira_sql_open` exists.
They drive the rounds slice's three calls (build the segment, run a round, finish) directly from the
test, over real sources, so "a stream" in them means those calls:

- `a_parquet_decode_error_is_ordered_by_its_claim`: a Parquet file whose row group 12 is corrupt. The
  source reports the claim it was decoding, and the stream hands out the batches of row groups 1 to 11,
  then the decode error.
- `claim_of_maps_positions_to_claims_for_each_source`: for the Parquet source (row group times
  `SUB_SLOT_STRIDE` plus sub-slot) and for the in-memory source (the slot), every position the source
  stamps maps back to the claim that produced it.
- `a_resident_batch_read_once_is_moved_not_copied`: a plan that reads a resident table once builds its
  source without a copy, and a plan that reads it twice still copies it for each reader.
- `a_row_group_larger_than_a_morsel_keeps_its_order`: a Parquet file whose row groups are four morsels
  each, with a claim limit small enough that the limit refuses claims in the middle of the file. The rows
  come out in file order, and no round ends with a worker holding a parked sub-morsel.
- `the_claim_reorder_modes_are_off_in_a_streamed_run`: a streamed Parquet scan builds its source with
  stride 1, file claim order and no row-range split, and a streamed in-memory source with stride 1 and no
  stealing.
- `a_refused_source_is_asked_again_next_round`: for the Parquet source and for `BatchMorselSource`, a claim
  refused by the limit returns `None` with `is_exhausted()` false. The next round's claims continue from
  the next position, and every morsel is handed out once.
- `a_published_output_is_taken_once_for_the_whole_stream`: a stream over an aggregate's output read over
  10 rounds takes the output from `PublishedOutputs` once and hands out every row once.
- `a_union_all_concatenates_its_branches_once`: a stream over `UNION ALL` of two Parquet scans
  concatenates once, takes no more claims than the claim limit from the concatenation before the first
  batch, and answers as the materialised run does, in branch order.
- `a_glob_reads_each_footer_once_per_stream`: a stream over a 64-file glob, read over many rounds, reads
  each file's footer once (counting opener).
- `a_sliced_fixed_width_array_imports_its_window`, `a_sliced_dictionary_array_imports_its_window`,
  `a_sliced_string_array_imports_its_window`, `a_sliced_binary_array_imports_its_window`,
  `a_sliced_boolean_array_imports_its_window` (a bit offset that is not a multiple of 8) and
  `a_sliced_list_array_imports_its_window` (a parent and a child offset): komira's importer takes an exported array at a non-zero
  offset, copies only its window, and reads the same values. A counter in the test shows the bytes copied
  are the window's, not the offset's prefix and the window.
- `a_sliced_nullable_array_imports_with_its_nulls`: a pyarrow slice of an integer column with nulls,
  registered into komira, keeps every value and every null at its row.

**The schema** (the streamed-run slice, in Mojo against `StreamedRun`; each is run again through the C
stream in the open-call slice, where `get_schema` and `get_next` exist):

- `get_schema_waits_for_the_first_batch`: a `get_schema` before any `get_next` returns the first batch's
  schema with every field nullable, after at most one round of claims. The first `get_next` then returns
  that batch without another round.
- `every_streamed_field_is_nullable`: a Parquet file whose columns are required gives a stream schema with
  every field nullable. The old call over the same file keeps today's schema.
- `a_large_string_hinted_file_streams_with_todays_width`: a Parquet file pyarrow wrote with large strings,
  in row groups of fewer than 1,024 rows, the sizing policy's floor. The stream's schema says `large_string`, as today's answer does,
  and no batch is converted.
- `a_nested_result_streams`: a query whose result has a list and a struct column, over a table in memory
  handed out through a root aggregate. The stream's schema has the child types of the first batch, and the
  answer equals today's.
- `an_empty_answers_schema_is_todays_empty_schema`: an empty answer from a collect root and from a root
  aggregate. The stream's schema is the one the engine derives for an empty answer today (the collect
  sink's, and the aggregate's declared output schema), with every field nullable.
- `a_file_set_that_disagrees_runs_materialised`: globs whose files disagree on a decimal's scale, on a
  timestamp's zone, on the presence of a column, on the large-string hint, on a list's item name (`item`
  in one file and `element` in the other), on a struct's field order, and on a nested child's type. Each
  runs materialised, as decided when the stage is built, before any claim, and each answer equals
  today's.
- `an_empty_nested_result_agrees_with_the_old_path`: a query that answers zero rows with a list and a
  struct column, through `komira_sql_stream` and through `komira_sql_open`. Both give the same schema, or
  both refuse with the same error.
- `the_conformance_corpus_streams_with_todays_answers`: the Mojo runner of §6.3 reads every case of the
  SQL conformance corpus, registers its tables from Parquet and again as resident tables, and runs every
  query streamed and materialised. Every streamed batch agrees with the stream's schema, and the answers
  are equal.
- `a_large_string_batch_is_converted_to_the_schemas_width`: a test hook makes the engine promote one later
  batch's string column to its large form. The batch is handed out at the schema's width, with the same
  values.
- `a_plain_string_batch_under_a_large_string_schema_is_widened`: the first batch's string column is large
  and a later batch's is plain. The later batch is handed out widened, with the same values.
- `a_string_batch_beyond_32_bit_offsets_is_split`: a test hook lowers the split threshold from the 32-bit
  offset limit to 1 MiB, and one batch carries 3 MiB of string data. It is handed out as several batches at
  the schema's width, each within the threshold, with the same rows in the same order. The threshold is the
  only thing the hook changes, so the test holds a few MiB and stays in the pull request's set.
- One test per property the schema step compares, each with a test hook that makes one later batch differ
  from the stream's schema in that property alone, and each asserting that batch's `get_next` returns
  `EIO` with the exact `STREAM_BATCH_TYPE_DIVERGED` message:
  - `a_diverging_column_type_is_refused_by_name` (an integer column where the schema says a float);
  - `a_diverging_decimal_precision_is_refused_by_name`;
  - `a_diverging_decimal_scale_is_refused_by_name`
    (`STREAM_BATCH_TYPE_DIVERGED: <column>: decimal(18, 2) in a decimal(18, 3) column`);
  - `a_diverging_timestamp_zone_is_refused_by_name`;
  - `a_diverging_timestamp_unit_is_refused_by_name`;
  - `a_dictionary_column_under_a_string_field_is_refused_by_name`;
  - `a_diverging_struct_field_order_is_refused_by_name`;
  - `a_diverging_list_item_name_is_refused_by_name`.
- `a_type_the_exporter_cannot_carry_fails_when_the_schema_is_built`: a table in memory with a column of a
  type the exporter refuses. The open call succeeds, and the first `get_schema` returns `EIO` naming the
  column.

**The run, memory and the C interface** (the streamed-run slice in Mojo, and the open-call slice through
the C stream; the C-interface tests are the open-call slice's alone):

- `an_integer_keyed_sorted_stream_registered_into_its_own_context` and
  `a_string_keyed_sorted_stream_registered_into_its_own_context`: `komira_register_arrow_stream` given a
  sorted stream from `komira_sql_open` on the same context, once with only fixed-width columns and once
  with a string key. Both complete, and the registered table equals the answer.
- `releasing_one_stream_leaves_the_handle_and_its_other_streams_alive`: two streams opened with one run
  handle. The first is released after one batch. The second reads to its end, and a later
  `komira_sql_stream_run` given the same handle succeeds. The handle's own token is not cancelled.
- `release_joins_the_streams_driver_thread` and `an_idle_open_stream_holds_one_parked_thread`: the
  process's thread count rises by one at open, stays so between rounds, and falls back when release
  returns.
- `a_get_next_waiting_for_the_dispatch_lock_is_cancellable`: stream 1's round is held at an event, stream
  2's `get_next` waits for the lock, a cancel of stream 2's run makes it return `ECANCELED`, and stream 1
  then reads to its end.
- `a_materialised_query_and_a_round_share_one_context`: a `komira_sql_stream` query on one thread while a
  stream's round runs on another. Both answers equal their materialised answers.
- `two_streams_and_a_query_share_one_context`: two open streams read alternately, and a third query runs
  between their rounds. Each answer equals its materialised answer.
- `an_unread_stream_does_not_make_a_later_sort_fail`: a context whose budget fits one sort of a test
  table, and three open streams over large files, each read once and left. The sort runs and answers as
  it does with no stream open. The pool's granted bytes, with the three streams open and between rounds,
  are 0.
- `each_run_checks_its_own_pool_tally` (the engine-core slice): two materialised runs on one context's
  pool, one after the other under the dispatch lock, the first with a sink planted to keep a reservation.
  The first run's end-of-run check fails with `EXECUTE_POOL_NOT_RELEASED`, and the second run's passes.
  In the streamed-run slice the same test is repeated with a stream's round and a materialised query.
- `a_file_truncated_in_place_fails_by_name`: a stream over a 64-row-group local file. The test reads until
  the queue is empty, then truncates the file in place. The `get_next` that needs the next round returns
  `EIO` with exactly `STREAM_SOURCE_CHANGED: <path>`, the process does not fault, and the batches already
  taken still read their values.
- `a_file_replaced_by_a_rename_is_read_as_it_was`: the same, but the file is replaced by writing another
  file and renaming it over the path. The stream reads to its end from the old file and answers as
  today's run did.
- `a_replaced_remote_object_fails_by_name`: the same against the test scheme's store, whose object is
  replaced with a new entity tag between rounds.
- `closing_the_session_waits_only_for_running_streams`: closing a session with one finished `Result` and
  one running stream stops the worker threads when the running stream is released, and a finished
  `Result` keeps no worker alive.
- `an_in_memory_roots_resident_memory_is_its_copies_plus_the_bound`: a resident table of 64 MiB with
  nullable columns, read by one segment, streamed with a byte limit of 4 MiB (a test hook). The largest sample of
  anonymous resident memory rises by at least the table's size, so the source's copy is seen. It rises by
  at most the copies, the cut into morsels, the bound and a margin, as §5.3's table states (one copy once
  the source limits slice moves a once-read batch into its source). The control reads the same table through
  the materialised run, and rises by more, by the collect sink's copies.
- `a_sorted_roots_resident_memory_is_the_sorts_peak_then_its_output_plus_the_bound`: an `ORDER BY` with
  a string column over 64 MiB of Parquet, streamed with a byte limit of 4 MiB (a test hook). During the sort the largest
  sample is the sort's own peak (its pool high-water mark plus its uncharged input). Over the read after
  it, the samples stay at most its output plus the bound, as §5.3 and §5.6 state: the output is handed out
  uncut through the hand-out step. The concatenated
  batches equal the materialised answer, and every batch exports.
- `a_cancel_during_a_breaker_returns_ecanceled_on_the_first_get_next`: the cancel test, with the source
  waiting below an aggregate.
- `the_stream_outlives_its_context`: `komira_ctx_free` after open and after batch 1. The stream is then
  read to its end and released, and its arrays are read after that.
- One test per row of §5.11:
  - `a_csv_source_is_decoded_whole_then_handed_out_in_rounds`, and the same for JSONL and Iceberg: the
    answer equals the materialised one, and the hand-out takes no more claims than the claim limit
    before the first batch;
  - `a_root_probe_runs_materialised_inside_the_stream`: the answer equals the materialised one, the claims
    before the first batch are all of them, and every batch passed the hand-out step (a test hook counts
    the batches the step saw);
  - `a_union_all_concatenates_its_branches_once` (in the source limits group above);
  - the file-set case, `a_file_set_that_disagrees_runs_materialised` (in the schema group above).
- `a_copy_opened_and_never_read_writes_its_file`: `komira_sql_open` of a `COPY ... TO` returns
  `KOMIRA_OK`. The file is already complete when it returns. The stream is released at once, unread, and
  the file is still there with every row.
- `a_cancel_during_a_copy_inside_open_returns_cancelled`: the query of a `COPY ... TO` waits on an event at
  a chosen claim. Another thread cancels the run handle and sets the event. `komira_sql_open` returns -6,
  and no file or temporary file is left.
- `a_failing_copy_fails_the_open_call`: a `COPY ... TO` whose query fails returns -3 from
  `komira_sql_open`, with the code and step in the context's last error. No temporary file is left, and the
  destination is as it was.
- `an_empty_answer_is_its_schema_then_the_end`.
- The lifetime cases carried from the earlier engine (§2.4), run against a stream that is still producing:
  every buffer read after release in the three release orders, and a thousand open, read and release
  cycles with the pool back at 0 and the thread count back where it was.
- **C interface:** the golden rows, the `gate_version` pin, the export list, the `abi_driver.c` cases for
  each status of §6.2 and for the two error calls before and after a failure, and
  `binding_falls_back_when_the_library_has_no_open_call` (a binding of this version against the stand-in
  library of the previous minor).

**The old calls** (the old calls slice):

- `the_drained_old_calls_keep_todays_answer`: for every query of the SQL conformance corpus, the old calls
  rebuilt as open-then-drain return the same statuses, the same schema (the first batch's), the
  same rows, one batch of no rows for an empty answer, and refuse at the call what today's calls refuse.

**The bindings** (the bindings slice):

- **Python:**
  - `sql_raises_for_an_error_before_the_first_batch`;
  - `to_reader_raises_komira_error_for_a_late_error`, with the exact message, and the code and step from
    the handle;
  - one Ctrl-C test per terminal (`ctrl_c_during_to_reader_cancels_the_run`, and the same for `to_arrow`,
    `to_pandas`, `to_polars` and the repr);
  - `result_cancel_stops_a_capsule_consumer`, where DuckDB reads `__arrow_c_stream__` on its own thread;
  - `repr_reads_only_the_rows_it_shows`, by the run's claim count, read through a test hook;
  - `releasing_the_last_share_from_a_finalizer_joins_cleanly`: drop the session, then let the garbage
    collector release the last open reader. The driver and worker threads are joined, and the process's
    thread count returns to what it was before the session;
  - one test per row of §5.11 through `sql()`, whose answer arrives;
  - `a_copy_through_sql_writes_its_file_though_the_result_is_never_read`: `sql("COPY ... TO ...")`, the
    `Result` dropped unread, and the file complete;
  - later, the `read_csv` chunk cases: exact chunk sizes across batch boundaries, `get_chunk(size)`, a
    malformed line in chunk 3 raising at chunk 3, and `with` closing the run.
- **Node:** `breaking_out_of_the_iterator_ends_the_run`, `abort_while_reading_rejects_next`,
  `a_collected_result_is_released_on_the_session_thread`, one test per row of §5.11 through `sql()`, whose
  answer arrives and equals the materialised one, and
  `a_copy_through_sql_writes_its_file_though_the_result_is_never_read`.
- **The plan-door slice:** `a_plan_with_a_write_target_opened_and_never_read_writes_its_file`, through
  `komira_plan_open` in the C driver and through `to_parquet` and `sink_parquet` in Python.

### 9.3 Why this list is complete

Each promise of §5 and §6 has a test that fails when the promise breaks:

- **The bound:**
  - the claim count, one claim per worker in the first round, the always-allowed claim and the one-step
    reservation;
  - the first batch, a growing projection, and a shared buffer counted once;
  - resident memory for a scan, a table in memory and a sorted root, each with a control that shows the
    measurement sees the memory;
- **What a stream holds:** a finished stream holding only its queue, for every way a run can be over; an
  unread stream that does not make a later sort fail; each run's own pool tally; and a session closed
  with streams open.
- **The file window:** a file truncated in place, a remote object replaced, and a mapping-backed column
  copied at hand-out.
- **Rounds:** the last stage built once, a refused source asked again, a published output taken once, a
  union concatenated once, footers read once, a limit counted across rounds, and a spent limit ending the
  stream.
- **Limits:** the trailing cut over every column type, `LIMIT 0`, and a materialised join with a limit
  stopping early.
- **Early stop:** release (with its thread joined, and the handle and its other streams left alive), the
  trailing `LIMIT`, and `break`.
- **Late errors:** the 37th call, the lower position, a decode error at its claim (generated and Parquet),
  the failing claim's own chunks, an error that stays after a cancel, the code and step from the handle,
  and an export refusal at its batch.
- **Cancel:** from another thread, while waiting for the dispatch lock, during a breaker, inside a `COPY`
  in open, through Ctrl-C on each terminal, and through `Result.cancel()`. Also the end staying the end
  after a cancel.
- **Order:** the schedule test and the split row group, with the source modes that would break order
  tested apart.
- **Export and import:**
  - the offset rules for every type the cut serves, and a root breaker's nested and large columns handed
    out uncut;
  - the planted offset;
  - the importer's window for fixed-width, dictionary and string arrays, and with nulls;
  - sorted streams registered back with fixed-width and with string columns.
- **Schema:**
  - `get_schema` waiting for the first batch, every field nullable, a file with the large-string hint, a
    nested result, and the empty answer's schema;
  - a file set that disagrees, nested properties included; an empty nested result through both paths; the
    conformance sweep; a converted width and a split batch;
  - one planted divergence per compared property, and an unexportable type.
- **Effects:** a `COPY` opened and never read (in C, Python and Node), a plan with a write target opened
  and never read, a `COPY` that fails at open, and a `COPY` cancelled inside open.
- **Also:** every shape of §5.11, lifetime (against the context, against release and against a
  finalizer), concurrency on one context, the old calls drained over the whole corpus, the empty answer,
  both directions of version skew, and each binding's own mapping.

The boundaries are an empty answer, `LIMIT 0`, one batch, a claim larger than the byte limit, a first round
that yields nothing, an error in the first claim, a cancel before the first round, a cancel after the end,
and a release before the first `get_next`.

## 10. Slices

The first slice is five pull requests, each tested alone and each leaving the tree working, in this
order. Each lists every part of the mechanism it needs from the engine, and the libraries it changes.

- **The engine-core slice, in `sdk_exec`, `pipeline_exec` and `async_rt`.** No streaming yet.
  - The engine core: the worker runtime moved behind the dispatch lock, the context's one pool, and the
    core held by `ArcPointer` (§5.9, §5.10).
  - The builder drawing its operators' reservations from the context's pool, with a per-run tally layered
    over the pool's shared counter, and the end-of-run check reading that tally (§5.3). Today
    `set_memory_budget` replaces the pool (`real_builder.mojo:351-355`).
  - The dispatch lock taken around each `run_segment` call, waited on in 1 ms slices that re-read a token
    (§5.9). The one call site of `ctx.runtime.dispatcher()` and the tests that reach `EngineContext.runtime`
    change with it.

  Tested by today's tests, unchanged, and `each_run_checks_its_own_pool_tally`. A user sees nothing.
- **The rounds slice, in `pipeline_exec`, `arrow`, `column_kernels` and `arrow_ipc`.**
  - `run_plan` split so a driver can run everything below the root with today's plan check, ready set and
    progress, then hold the root (§5.2).
  - `run_segment` split into three calls that keep today's order: build the segment, run one round, finish
    it (tails, `combine` or `finalize`, the pool check). Today's `run_segment` becomes the three in a row.
    The build call takes an operator count, so a trailing limit can be left out of the built operators
    (§5.5).
  - The result sink, with its per-round drain and its forwarder in `PipelineSink`, and its hand-out step
    (§5.12): position order, selection, the trailing-limit cut with `_slice_batch_first_n`, the schema
    check, the narrowing, widening and split of a string or binary column's width (new code, §6.3), the
    offset fallback, the copy of mapping-backed buffers, the dropping of empty batches, and a per-batch
    export check split out of `check_record_batch_stream` in `arrow_ipc`.
  - The function in `arrow` that measures the bytes a set of batches keeps alive, each shared buffer
    counted once by its region, and the stream's own counter that the limit reads (§5.3).
  - The read-ahead limit and its one-step reservation, with one claim per worker in the first round,
    applied to the generated source.
  - On the source trait: `is_exhausted()`, `claim_of(position)`, and the claim each worker is decoding,
    with their forwarders. The generated source follows the Parquet position encoding.
  - The position of a failing claim kept across `_push`, the lowest-position error slot, and the
    streamed variant of `SegmentRun.fail` (§5.2, §5.7).
  - An accessor for a limit's spent budget, and the check after each round that ends the run once a
    non-trailing limit's budget is spent (§5.5).

  Tested with the fake dispatcher, the generated source and the counting builder (§9.2, the rounds and
  hand-out groups), with no file and no C call. A user sees nothing.
- **The source limits slice, in `parquet_scan`, `parquet`, `parquet_api`, `op_sources`, `pipeline_exec`,
  `arrow_ipc`, `fs` and the S3, Azure and GCS file systems.**
  - The limit at the Parquet cursor (`_claim`), with stride 1 and no row-range split for a streamed run,
    passed through a new parameter of both `build_parquet_source` (local) and `build_parquet_source_on`.
  - The limit at `BatchMorselSource`'s slot claim, with a new stride option on `BatchMorselOptions`.
  - For both: `None` on a refusal that leaves the source askable next round, `is_exhausted()`,
    `claim_of(position)`, and the claim each worker is decoding.
  - The per-chunk size accessor for a projection's column chunks, and the in-memory source's per-slot size
    array, for the claims' estimates (§5.3).
  - The comparison of a file set's columns across files when the source is built, nested properties
    included (§6.3).
  - The check of each file before each claim, in streamed runs only: a stat call added to the file
    system's C shim, comparing a local file's device, inode, size and modification time; and a conditional
    ranged read added to the `FileSystem` trait as a defaulted method, implemented by the S3, Azure and GCS
    file systems (§5.9).
  - The builder call that counts each resident handle's readers before the first segment, and a resident
    batch read by one segment moved into its source, not copied (§5.3).
  - The importer's window copy, at any offset, with validity rebased (§5.12).

  Tests: §9.2, the sources group, driven through the rounds slice's three calls. A user sees one change:
  registering a sliced pyarrow table no longer fails.
- **The streamed-run slice, in `sdk_exec`, `async_rt` and `engine_runtime`.**
  - The failed run's code and step added to `RunControl` in a shared cell (§6.3), so the stream sets them
    and the C calls of the next slice can read them.
  - The driver-thread entry in `async_rt`'s thread boundary (§5.10).
  - `StreamedRun` and `open_sql`:
    - the driver's frame holds the cache, the pool, the builder, the published outputs and the last stage,
      and is dropped when the run is over (§5.2, step 7);
    - every reason to run materialised that the plan shows is decided at open, and the lowered plan is
      never changed;
    - a trailing `LIMIT` of a streamed run is left out through the build call's operator count, and its
      count goes to the result sink;
    - the stream's child token;
    - a root breaker's output is handed out uncut.
  - The stream's schema from the first batch, with every field nullable, and the empty answer's schema
    built as today's; the fall-back when a file set disagrees; and the conformance sweep with its Mojo
    runner.
  - Statements with effects run inside open, and the other unstreamed shapes run materialised inside the
    stream (§5.11).
  - The helper in `engine_runtime` that reads the process's anonymous resident memory, and the
    resident-memory tests.

  Tests: §9.1, and §9.2's schema and run groups, through `open_sql` in Mojo. A user sees nothing: no C
  call exists yet.
- **The open-call slice, in `arrow_ipc` and `so`.**
  - The incremental exporter state in `arrow_ipc`: a `get_next` that asks a driver for batches, with its
    error and cancel returns (§5.2).
  - `komira_sql_open`, `komira_run_error_code` and `komira_run_error_step` (the next minor), reading the
    cell the streamed-run slice added.
  - The throughput measurement, the reviewer's gate (§5.3), and the small-batch measurement (§5.12).

  Tests: the C-interface tests of §9.2. After it, a C caller can stream. Python and Node do not call it
  yet.

The slices after it:

- **The bindings slice: Python and Node read streams.**
  - `sql()` goes through `komira_sql_open`, with the first-batch pull.
  - Every terminal reads on the helper thread, and the `Result` keeps the run handle and gains
    `Result.cancel()`.
  - It also brings `to_reader()`'s wrapper, and Node's iterator, `signal`, finalizer and late-error path
    (§7.2).
  - **What a user sees change.** A streamed `Result`'s schema marks every field nullable (§6.3, §7). The
    slice names that in its changelog entry, and updates the binding tests and the TypeScript package's
    goldens that compare schemas. The docs that say `to_reader()` reads only what is asked change with it.
  - **How streaming is turned off if it misbehaves.** There is no switch (§12, decision 5). The old calls
    stay as they are until the old calls slice, so the way back is a binding release that calls
    `komira_sql_stream_run` again, with no library change.

  Because §5.11 runs every statement with effects inside open, and every unstreamed shape materialised
  inside the stream, no statement is left undone after this slice, and none that works today fails,
  within the limit §6.3 states.
- **The plan-door slice.** `komira_plan_open` (the next minor) and `open_plan`. `DataFrame.materialize()`,
  `komira.pl`'s `collect()` and `collect(engine=...)` stream, and the pandas `to_*` and polars `sink_*`
  writers run inside open.
- **The CSV slice: a CSV source that streams.** It claims byte ranges cut at line ends, decodes one range
  per claim, and keeps the types inferred at open. Then `read_csv(chunksize=n)` and `iterator=True` once
  §11 is decided, with `collect_batches` beside them.
- **The writes slice: streamed writes.** `COPY ... TO` and the SDK writers as a streamed run with an
  in-engine writer (§8), still run to completion inside open.
- **The read-ahead slice, if measured.** The driver thread starts the next round by itself when half the
  bound is free. It is built only if a later measurement (a slow reader, or a query the throughput check
  did not cover) shows the idle time matters (§12, decision 2). If the open-call slice's own throughput
  check needs it, it is built there instead (§5.3).
- **The old calls slice, deferred.** The old run calls are rebuilt as open-then-drain (§6.5), checked over
  the whole conformance corpus. `CollectSink`'s concatenation stays only where a breaker's input needs one
  batch. It lands only after the bindings have streamed in released packages through at least one release
  with no streaming defect open, because once it lands the old calls are no longer a way back.
- **Later slices.**
  - The keyed join probes split their output into chunks, as CROSS does, and a probe in the last pipeline
    streams.
  - The JSONL and Iceberg sources claim parts of a file instead of decoding it whole.
  - A `UNION ALL`'s branches stream into the union.
  - The limit goes on the row-range split's counter, so a streamed scan may split large row groups
    (§5.4).
  - Charging a source's copy and cut, and a join's build side, to the pool, for every run.
  - Exporter and importer offset support for the variable-length, nested and union types, if anything
    comes to need it (§5.12).
  - A cancel check inside a sort, merge and combine.
  - The Mojo SDK's `ResultStream` (§7.3).

The five parts of the first slice touch the libraries each names. This document is their design, as a
change across several packages needs one. The CSV slice and the writes slice do not depend on each other.

## 11. Open decision: what a `read_csv(chunksize=n)` chunk is

pandas' chunk is a pandas `DataFrame`. The task examples run with only pyarrow and protobuf installed
(`python/docs/tasks/BUCK`), so komira cannot return a pandas frame there. The choice decides what user
code over a chunk can do, and it cannot be changed later without breaking that code. The options:

- **A pyarrow table** (`pyarrow.Table`).
  - Works in the examples environment today, with no new engine work.
  - pandas code over a chunk (`chunk[chunk.x > 0]`, `chunk.groupby(...)`) does not run.
- **A komira frame**: a komira `DataFrame` over the chunk's rows.
  - The same verbs as the frame `read_csv` returns without `chunksize`, and `.to_pandas()` when pandas
    is installed.
  - The plain cost: a frame over rows held in memory needs an in-memory scan in the plan wire, which it
    does not have today ([dataframe_surface_verbs.md](dataframe_surface_verbs.md), `scan_in_memory` not
    built). That is a plan-wire change, with its goldens and the tests of old and new releases on each other's data that a format change needs. It
    lands before `chunksize` does.
  - komira frames have no index ([dataframe_surface.md](dataframe_surface.md)), so pandas' continuing
    `RangeIndex` has no counterpart.
- **A pandas frame**: a pandas `DataFrame`, which requires pandas.
  - Exactly pandas' type.
  - It cannot run in the examples environment, and it makes pandas a hard dependency of one komira path.

**Recommended: a komira frame**, with `read_csv(chunksize=n)` refused by name until the in-memory scan lands. A
komira user writes komira verbs, and a komira frame is the only option under which the code they write for the
frame without `chunksize` also runs on a chunk.

## 12. Decisions taken

Each is decided here so the slices can start, with its reason.

1. **The model is rounds pulled by the reader** (§5.1). It fits the fork-join executor unchanged. No
   worker and no lock waits on a reader, so a stream read back into its own context cannot deadlock. A
   blocking queue would hold the context's dispatcher while a reader pauses. Pull per batch would lose
   either the parallelism or a dispatch per batch.
2. **No read-ahead for now** (§5.1). The engine idles while the reader works. Whether that matters is
   measured in the open-call slice. The driver thread starts rounds by itself only if a measurement shows
   it matters, at the cost of a release that waits for the round in flight.
3. **The bound is fixed by the engine** (§5.3). No caller sets the claim limit or the byte limit until a
   user shows a case the default serves badly (no speculative knob). The default sizes the byte limit from
   the scan's row groups, so that every worker can be busy.
4. **No unordered stream** (§5.4). A stream's order is the materialised order, and DuckDB's with its
   default settings. An unordered hand-out would be faster only by the wait for a round's slowest claim,
   and it would need a second hand-out path. polars' `maintain_order=False` is refused by name.
5. **`sql()` returns after the first batch** (§7.1). Errors before the first batch stay at `sql()` with
   their code and step, so existing code that catches errors around `sql()` still catches every error a
   query meets before it produces rows, and streaming is the default. The cost is that `sql()` runs one
   round, or the breakers, even when nothing is read. Opening without a pull would move every execution
   error to the reads, and an opt-in flag would be a second way to run a query.
6. **The plan door's cancel is `komira_plan_open`** (the plan-door slice). A `komira_plan_stream_run`
   added now would be a row that the old calls slice makes redundant.
7. **A shape that cannot stream yet runs materialised inside the stream, and a statement with effects
   runs to completion inside open** (§5.11). Neither is refused, so the bindings need no fallback of their
   own, and turning streaming on in the bindings slice breaks no statement that works today, within the
   limit §6.3 states. A statement
   with effects must not depend on the caller reading: a C caller that opens a `COPY` and releases the
   stream unread still has its file, and learns of a failure from the open call.
8. **One operator pool per context, with a tally per run; what a stream holds for its reader is not
   charged to it** (§5.3). Two runs can now be open on one context, so their operators share the
   context's budget, and the dispatch lock keeps them from running at once, as today. Charging a stream's
   held batches to the pool would let an unread `Result` make another query's sort fail where it runs
   today. So a stream's held bytes are bounded by its own limits instead, outside the pool, as today's
   answer is. There is no cap on the number of open streams, as there is none on today's results.
9. **Each running stream has a driver thread, whose frame holds the run, and the frame goes when the run
   is over** (§5.10, §5.2 step 7). Some sources can be taken or built only once, a limit's budget must
   survive every round, and the builder borrows the cache and pool from the frame that made them. A frame
   that lives as long as the run satisfies all three without a pointer type or a change to the builder.
   Dropping it at the run's end, not at release, means a finished `Result` holds only its queue, as
   today's holds only its answer. Holding the cache and pool by shared ownership
   instead would avoid the thread, at the cost of a larger change across two libraries' generic
   parameters, and stays open.
10. **The stream's schema is the first batch's, as today, with every field nullable** (§6.3). The lowered
    plan carries no schema, and a schema derived from the built stage could disagree with the first batch
    after it had been handed out, failing a query that works today. Taken from the first batch, it cannot
    disagree with it, and nested results stream too. The cost is that `get_schema` waits for the first
    round. A file set whose files disagree is found when the stage is built, and runs materialised. Every
    field nullable, because a later batch can carry a null where the first had none. The conformance
    sweep looks for any later disagreement on real queries.
11. **A late error's code and step are on the run handle** (§6.3), read by `komira_run_error_code` and
    `komira_run_error_step`, which the open-call slice adds to `RunControl`. A binding never parses the
    text, and the context's last error, which a stream outlives, is not overloaded. `ENOMEM` is used for
    `MEMORY_BUDGET_EXCEEDED`, so a raw consumer such as DuckDB or pyarrow sees a memory error, and `EIO`
    for every other engine error.
12. **A failed stream stays failed.** Every `get_next` after an error or a cancel returns the same errno
    and text. Arrow defines no stream that resumes.
13. **An error's position decides, not its time** (§5.7). It makes the rule about which call returns the
    error deterministic, at the cost of letting the claims being worked on finish after an error.
14. **The limit sits at the source's claim, and a claim and its reservation are one step** (§5.3, §5.4). A
    claim is the unit that is either wholly in one round or wholly in a later one, which keeps order
    across rounds without a window.
15. **A streamed run claims one unit per cursor move** (§5.4). The claim order and stealing are not used by
    the real builder today, so stride 1 costs only the adaptive stride of up to 32 claims per move, which
    the throughput check measures. A window instead would cost memory the bound would have to cover.
16. **The importer copies the window of an array at any offset, with its validity rebased** (§5.12). The
    importer copies by design, so taking the offset costs nothing extra, and keeping it would copy each
    morsel's prefix. The hand-out does not copy the zero-copy slices, which would cost every query. It
    copies only a column of another type left at an offset, which the morsel split does not produce. Every
    batch passes the per-batch export check before it is queued, on every path.
17. **Only a trailing root limit of a run decided to stream moves to the hand-out, and it is cut with the
    limit operator's own function** (§5.5). The lowering and the plan wire are unchanged. A run that runs
    materialised keeps the plan's own limits, so a join with a limit stops early as today. A limit with an
    operator above it stays an operator whose budget, made once, counts every round. The driver ends the
    stream once that budget is spent, so later rounds do not decode the rest of the input for nothing.
18. **A root breaker's output is handed out uncut, as one batch** (§5.6). The in-memory cut refuses nested
    and large columns that a breaker's output can hold, so cutting it would fail queries that work today.
    The output is in memory whole already. Handing it out in slices waits for a cut that serves every type.
19. **A file set whose files disagree on a column runs materialised, decided when the last stage is built**
    (§6.3, §5.11). The source has every footer by then and nothing has run, so falling back costs the
    footers read twice. Without it, a later batch would disagree with the schema after earlier batches
    were handed out.
20. **A resident batch read once is moved into its source** (§5.3). It removes one of the two copies
    today's engine makes, for materialised runs as well.
21. **The dispatch lock is taken around each segment of a materialised run, and around each breaker,
    build and round of a streamed run, only by driver and caller threads, and its wait is cancellable**
    (§5.9).
22. **No empty batch is handed out by a stream, and batches are not coalesced** in the first slices. A
    morsel's output is the unit. The open-call slice measures what small batches cost.
23. **A stream cancels a child of the run handle's token, never the handle's own** (§5.2, §5.8). A cancel of
    the handle is permanent and reaches every run given it, so an early release or a limit's end must not
    use it.
24. **The first round takes one claim per worker** (§5.2, §5.3). Two claims per worker would make every
    `sql()` and every `LIMIT` decode and hold about twice the row groups today's run does before its first
    batch.
25. **A stream refuses a changed file by name, and hands out no batch that refers to a mapping**
    (§5.9, §5.12). A file truncated in place under a live mapping crashes the process. The check before
    each claim turns that into `STREAM_SOURCE_CHANGED` for the stream's life, leaving only one claim's
    decode exposed, as a materialised run's reads are today. The copy at hand-out keeps a reader's batches
    out of the file's reach.
26. **A NULL run handle is allowed** in `komira_*_open`. Release still cancels the stream's own token.
27. **The old run calls are unchanged until the old calls slice, which waits for streaming to have run
    in released bindings** (§6.5, §10). Until then they are the way back. When it lands they change only
    in batch count and in which rows a final `LIMIT` keeps. They keep their schema rule (the first
    batch's), their one batch of no rows, and every refusal at the call.

## 13. Docs this design finds stale

Docs describe only what the code does, so each of these is fixed by the slice that changes the behaviour, not here:

- `Result.to_reader()`'s docstring says it "reads its batches as they are asked for". That is true of
  the reader, and not of the engine, which has computed them all. It is fixed in the bindings slice.
- [libkomira_run_abi.md](libkomira_run_abi.md) §5 ("Materialized first") and §10 (`ECANCELED` "when one
  exists") point forward to this document once the open-call slice lands.
- The `read_csv` task page (rank 28, "process a CSV larger than memory") says `to_reader()` reads batches
  as they are asked for. It is fixed with the bindings slice and the CSV slice.
