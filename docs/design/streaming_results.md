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

Three words are used throughout:

- **A claim** is the unit of input a worker takes from a source at a time: for Parquet, one row group or
  one row range of a split row group; for a table in memory, one morsel.
- **A round** is one ordinary parallel run of the last pipeline: every worker takes claims and runs
  them through the pipeline's operators until the source is exhausted or no further claim is allowed.
- **The read-ahead limit** decides whether a worker may take one more claim. It is the bound on how far
  the engine runs ahead of the reader.

## 1. Summary

| item | design |
|---|---|
| the model | **rounds pulled by the reader** (§5). The breakers below the last pipeline run as today. The last pipeline runs in rounds, each one ordinary parallel dispatch in which workers take claims while the read-ahead limit allows. A round therefore stops by itself, and the reader's `get_next` starts the next round when nothing is left to hand out. No engine thread ever waits on a reader |
| the bound | no more claims than the claim limit (twice the workers) and no more bytes than the byte limit (64 MiB or more, §5.3) taken and not yet handed out, counting the claims still being worked on. One claim is always allowed when nothing is outstanding, and estimates can be exceeded by at most the excess §5.3 states. The bytes of all open streams of a context come from the context's one memory budget |
| what streams | the last pipeline over a Parquet scan or over a table in memory, through filters, projections and a final `LIMIT`. Every other query runs as today inside its first `get_next` and is handed out from memory; it works the same and only does not stream yet. A statement with effects (`COPY ... TO`, a write) runs to completion inside the open call, so it never depends on the stream being read (§5.11) |
| order | a streamed result comes out in the order the materialised result has today: file order for a scan, the sort's order for `ORDER BY`. A final `LIMIT` without `ORDER BY` is applied as rows are handed out, so it returns the first `n` rows in that order (§5.4, §5.5) |
| what cannot stream | a sort, an aggregate, a window, a distinct and a join's build side finish before their output exists. The first `get_next` waits for them; progress and cancel work meanwhile (§5.6) |
| a late error | an error while producing a claim is returned by the `get_next` that would have returned that claim's batch, after every batch before it, when each claim yields one batch. The code and step are read from the run handle, not from the text (§5.7, §6.3) |
| cancel | `komira_run_cancel(run)` from any thread, as today; a waiting `get_next` returns `ECANCELED`. Releasing the stream before its end ends the run and frees everything it holds (§5.8) |
| the C interface | the Arrow C stream stays the one result shape. `komira_sql_open` and `komira_plan_open` return it before the run, with the run handle that cancels it; `komira_run_error_code` and `komira_run_error_step` give a late error's code and step (§6) |
| the existing calls | `komira_sql_stream`, `komira_sql_stream_run` and `komira_plan_stream` keep their contract: the answer computed before the call returns, every engine error a status (§6.5) |
| ABI version | the next minor for each call, as it lands (§6.6) |
| SDKs | Python's `sql()` pulls the first batch, so an error before it still raises there; every terminal reads on the helper thread, so Ctrl-C cancels. `read_csv(chunksize=n)` needs a CSV source that streams first. Node's async iterator reads batch by batch. The Mojo SDK gets a stream form beside its `Result` (§7) |
| writes | `COPY ... TO` and the SDK writers do not stream today. They move onto the same streamed run, with a writer appending to a temporary file renamed at the end (§8) |
| first slice | three pull requests that together stream one SQL query over Parquet end to end through `komira_sql_open`, proven by the engine tests and the C driver (§10) |

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
| 6 | `src/pipeline_exec/sink_collect.mojo:104`, `:118`, `:144` | **the sink that materialises**: `consume` appends each morsel's batch to the worker's slot; `combine` orders all chunks by source position (`position_order`); `take_output` concatenates them into one batch (`concat_record_batches_nway`) |
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
3. **Rounds pulled by the reader** (chosen). The last pipeline runs as a series of ordinary dispatches. In
   each, a worker takes a new claim only while the read-ahead limit allows, so the round stops by itself
   once the claims outstanding reach the bound. The reader's `get_next` hands out a held batch, and starts
   the next round when nothing is held. Between rounds no worker is busy and the dispatcher is free.

**Chosen: 3**, and the reasons are in §12 (decision 1). It keeps every guarantee the executor gives
today:

- `run_with_state` still returns only after every shard.
- A worker never blocks.
- Order is still bought by sorting positions.
- It is parallel.

It bounds memory by construction: the limit is what lets work in, so nothing has to watch memory and
react. It is pull in the Arrow sense: nothing runs unless a reader asks. Between rounds a stream holds
memory, but no thread and no open file (§5.10).

Its cost is that the engine is idle while the reader works through the batches of a round. A driver that
starts the next round when half the bound is free would close that gap. The cost of that driver is one
thread per open stream, and a release that must wait for the round in flight. It is left until the
throughput check of the open-call slice shows the idle time matters (§12, decision 2).

### 5.2 How a streamed run works

**PROPOSED.** The engine-level object is a `StreamedRun` in `sdk_exec`. It is built by
`open_sql(ctx, text, control)` and `open_plan(ctx, plan, control)`, beside today's `run_sql_with` and
`run_plan_with`.

1. **Open (the caller's thread).**
   - Parse, bind, optimise and lower, exactly as today. Every refusal of those steps is still a status,
     and `*out` is untouched.
   - The result schema is known from the lowered plan, and the export check (`check_record_batch_stream`'s
     type rules) runs on it.
   - A statement with effects runs to completion here, and the call ends with its one-row stream
     (§5.11). For any other statement, the run decides whether it can stream the plan. If it cannot, it
     is marked to run materialised.
   - The run takes into itself, by value, what it reads from the context: the lowered plan, the opener
     and credentials it resolved, its own footer cache (today `begin_query` replaces the context's cache
     at every query; `engine_context.mojo:126-128`), and its expression pool. After open, the run reads
     no mutable context state.
   - Nothing is claimed from any source yet.
2. **The breakers (in the first `get_next`).** Every segment below the root runs as today, one dispatch
   each, in `run_plan`'s order. Their outputs are published as today.
3. **The last pipeline, one round at a time.**
   - The root segment's per-round parts are built for each round from state the run owns by value: the
     source, with its claim cursor's position, and its operators. They borrow the run's footer cache and
     expression pool for the length of that round only. The **result sink** (below) persists across
     rounds.
   - A round is one `run_with_state` over that segment.
   - A worker first drains the sub-morsels of the claim it holds. The source parks them on the worker's
     pending slab and hands them out on its next calls. The worker asks for a new claim only when it holds
     none.
   - A new claim is taken only if the read-ahead limit allows it (§5.3). When it does not, `next_morsel`
     returns `None` and the source records whether it was refused by the limit or is exhausted. Today
     `None` means "never ask this worker again" (`src/pipeline_exec/README.md`); a source with a limit is
     asked again in the next round.
   - The round ends when every worker has returned. At that point no worker holds part of a claim.
4. **Handing out.**
   - The result sink is `CollectSink` without its concatenation.
   - It is charged for each chunk as it takes it (§5.3).
   - At the end of a round it orders the round's chunks by position (`position_order`, as `combine` does
     today). It materialises a selection mask where one is present, makes every column exportable
     (§5.12), drops empty chunks, and appends the batches to the run's queue.
   - `get_next` pops the queue's head and exports it as `get_next` does today: an array over the batch's
     buffers, with no copy.
5. **The end.**
   - When a round ends with the source exhausted, the run pushes the operator tails (the unmatched rows of
     a RIGHT or FULL join, `run_segment`'s `_push_tails`). Then `finalize` runs, and the run checks that
     its share of the pool is returned (`EXECUTE_POOL_NOT_RELEASED`, as today).
   - A round that ended at the limit pushes no tails.

**`get_next`**, written out:

```text
loop:
    if the queue holds a batch:           pop it, return 0 and the batch
    if the run has failed:                 return its errno (every time)
    if the run's token is cancelled:       mark the run cancelled, return ECANCELED (every time)
    if the run is finished:                return 0 and a released array (the end, every time)
    if the run is marked materialised:     run the whole plan as today, queue its batches, mark finished
    else if a breaker has not run:         run the next breaker segment
    else:                                  run one round (and, when the source is exhausted, the tails
                                           and finalize, then mark finished)
```

So one `get_next` may run several rounds: one whose filter rejects every row it read yields no batch,
and the loop starts another. A cancel is seen between rounds and, inside a round, at every claim and
morsel the workers check (§5.8).

**What the first batch costs.** The first `get_next` costs the breakers below, if any, and then one
whole round of up to the claim limit's number of claims. A round cannot hand out a batch before it ends, because the result sink
orders the round's chunks only then. So the first-batch bound of §9.1 holds for a scan that yields
output per claim. A filter that rejects a whole round makes the first `get_next` run another round. A
smaller first round (one claim per worker) would hand out the first batch sooner, at the cost of a
second rule for the limit. It is not taken, because the claim limit, twice the workers, already makes the first round at
most two claims per worker.

Nothing in the run waits on a reader, and the reader waits only on engine work: a breaker segment, or one
round. That one property is what lets a reader pause, read from another thread, or feed the stream back
into the same engine.

### 5.3 The read-ahead limit and the bound

**The two limits.** The read-ahead limit has two parts, both fixed by the engine (§12, decision 3):

- **the claim limit**, a number of claims: twice the number of workers;
- **the byte limit**, a number of bytes: the larger of 64 MiB and twice the number of workers times the
  scan's largest claim estimate, and at most half the context's memory budget when one is set. The second
  term keeps every worker busy when row groups are large. The budget cap keeps one stream from taking the
  context's whole budget.

**The rule, stated once.** A claim is *outstanding* from the moment a worker takes it until every batch
it produced has been handed out to the reader, or discarded. That covers claims being worked on, claims
whose chunks sit in the result sink during the round, and claims whose batches sit in the queue. A worker
may take one more claim only if, with that claim counted,

```text
outstanding claims ≤ the claim limit   and   outstanding bytes ≤ the byte limit
```

where the outstanding bytes are

- the real size of every chunk and batch the result sink and the queue hold, copies included (§5.12),
- plus the estimate of every outstanding claim that has not yet produced its output.

When nothing is outstanding, one claim is always allowed, so a claim larger than the byte limit still
makes progress, as DuckDB's buffer admits one unit when empty.

- **A claim's estimate** is the source's own size for it, known before it is taken. For Parquet it is
  the row group's (or row range's) uncompressed size from the footer. For a table in memory it is the
  morsel's size. It is replaced by the real size as the claim's output reaches the sink. A claim that
  yields nothing (a row group pruned, skipped or filtered empty) stops being outstanding, and returns its
  reservation, when its worker moves on.
- **Taking a claim is one step.** The claim index is known only once the cursor has moved, so the check
  and the cursor's move are done together, in a compare-and-swap loop:

  ```text
  loop:
      next_claim = cursor.load();  if next_claim >= end: return EXHAUSTED
      claim_bytes = estimate(next_claim)
      if not limit.try_reserve(1 claim, claim_bytes): return REFUSED   # one atomic word holds both counts
      if cursor.compare_exchange(next_claim, next_claim + 1): return next_claim
      limit.release(1 claim, claim_bytes)              # another worker took that claim; try again
  ```

  The two counts share one 64-bit atomic word (claims in the low 16 bits, bytes in KiB above them), so
  the reservation is all or nothing.

**What that bounds.** At any moment a stream's last pipeline holds no more claims than the claim limit,
and no more bytes than

```text
the larger of (the byte limit, one claim's estimate)
  + the excess of real output over estimate, for the claims still being worked on
```

Only claims a worker is working on can exceed their estimate, so the excess is at most one claim's excess
per worker. For a scan through filters and projections a claim's output is at most its decoded size. The
Parquet source decodes a whole row group before it cuts it into morsels (`parquet_source.mojo` header),
and the decoded size can exceed the footer's uncompressed size for dictionary or run-length encoded
columns. That is the excess.

**Where the rule applies.** It applies to a last pipeline whose source is a scan or a table in memory.
Three cases are not covered by it:

- **A keyed join probe** emits one batch as large as the fan-out of its morsel. Only a CROSS join splits
  its output (`HAVE_MORE_OUTPUT`); the keyed probes do not (`src/pipeline_exec/README.md`, Known
  limits). One claim's output is therefore not bounded, so a last pipeline with a probe runs materialised
  (§5.11) until the keyed probes split their output (a later slice).
- **A breaker's held output.** A sort's or an aggregate's output is held whole before the first batch.
  It is published as today, and not charged to the pool, as published outputs are not today. The peak for
  such a query is that output plus the byte limit (§5.6); a test counts it (§9.2).
- **The tails of a RIGHT or FULL join** are pushed after the last claim, chunk by chunk, on the reader's
  thread, through the same limit: the push stops when the bound is reached and goes on at the next
  `get_next`. (These come with probes, so with that later slice.)

**One budget per context.** Today each run builds its own segment pool, sized by the context's memory
budget (`real_builder.mojo`, `set_memory_budget`). With one run at a time per context, that was one
budget per context. With open streams it would not be, so the engine core (§5.10) holds one pool for the
context:

- Every run, materialised or streamed, draws from that pool.
- Each run counts its own grants for the end-of-run check (`EXECUTE_POOL_NOT_RELEASED`).
- A stream's outstanding bytes are charged to the pool, so all open streams of a context, and every
  query beside them, share the one budget.
- **A stream's own state is charged too.** At open the run charges the size of what it holds by value:
  its lowered plan, its expression pool, and its footer cache as the cache grows (each footer is charged
  when it is parsed). A stream whose state cannot be charged fails at open, or at the read that parses
  the footer, with `MEMORY_BUDGET_EXCEEDED`. So the number of open streams is bounded by the budget, with
  no separate cap on their count.
- A charge the pool refuses for a claim counts as a refusal by the limit (the stream waits for its own
  queue to drain). The exception is when nothing of that stream is outstanding: then the pool's refusal
  fails the stream with `MEMORY_BUDGET_EXCEEDED: execute: the open results of this session hold <n>
  bytes`. The reader frees memory by reading or releasing the other results.

An open stream that is not being read holds its outstanding bytes and its own state, all charged to the
pool, and no thread or open file (§5.10). An abandoned stream holds those until it is released, by the
caller or by a binding's finalizer. When no memory budget is set, the pool counts without a cap, as it
does today, and the limits above still bound each stream.

**The throughput check.** The open-call slice measures a streamed full scan against the materialised run
of the same Parquet file, at 1 and at 16 workers, and reports both in its pull request. It is a
measurement, not a test (rule T10), and it is also a condition for that slice to land: the streamed scan
must reach at least 90% of the materialised run's rows per second at each worker count. If it does not,
the byte limit's default is doubled and the measurement repeated, up to the budget cap. If it still does
not reach 90%, the slice does not land until the cause is fixed within it: the stride-1 claims, the
per-round rebuild, or the idle time between rounds. If the cause is the idle time, the read-ahead driver
(§5.1) is built inside the open-call slice, and the read-ahead slice is folded into it.

No queue in this design is unbounded, and nothing watches memory at run time: the limit is the bound.

### 5.4 Order

**The rule.** A streamed result comes out in the order the same query's materialised result has today:

- **A scan, filter or project pipeline** comes out in source position order, the order
  `CollectSink.combine` sorts by. For Parquet that is file order, then row group order, then the order
  within a row group. That is the order DuckDB gives with `preserve_insertion_order` on (its default), so
  B21's "same result as DuckDB" holds for the order too.
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

**The claim sites.** Two cursors take every claim a streamed last pipeline can take, and the limit sits at
each of them:

- **The Parquet source:** `_claim` (`src/parquet_scan/parquet_source.mojo:551-572`), whose
  `rg_cursor.fetch_add` at `:565` is the plain scan's cursor move. The cursor-grain route hands out
  grains of a claim this cursor took (`_plain_claim` opens it after `_claim`), so it needs no limit of
  its own. The row-range split of a large row group has its own counter
  (`src/parquet_scan/parquet_source_subrg.mojo:297`, `c.next.fetch_add`), which `_next_morsel_claim`
  reaches before `_claim`. It is a third claim site. It is off by default (`subrg_mode = 0`,
  `parquet_source_options.mojo`), and a streamed run keeps it off until a later slice puts the limit on its counter.
- **The in-memory batch source:** the shared cursor of `BatchMorselSource`
  (`src/op_sources/batch_morsel_source.mojo`), which serves registered tables, breakers' published
  outputs and the branches of a `UNION ALL`.

**The modes that break condition 1**, which a streamed run builds each source with off:

- the cursor stride, which hands each worker a range of several claims at once: a streamed run uses
  stride 1, one claim per cursor move. That applies to both sources. Parquet has the option today
  (`forced_cursor_stride`). The in-memory source's stride is a constant, so the claim-sites slice adds a stride option to
  `BatchMorselOptions`;
- the Parquet row-range split (`subrg_mode`): off, as above;
- the Parquet claim order (`claim_order`, a permutation of the row groups, heaviest first): off, so claims
  go in file order;
- the in-memory source's work stealing (a per-worker sub-cursor a stealer may advance): off.

Sharing parked sub-morsels between workers (`share_parked`) and the cursor-grain route move or cut work
inside a claim the round finishes anyway, so they may stay on. The ordered hand-out then needs no window
beyond the round. The cost is one cursor move per claim instead of one per stride, and the load balance
the claim order and stealing bought. The throughput check (§5.3) measures that cost.

**An unordered stream**, handing out each claim as it finishes, is not offered (§12, decision 4).

### 5.5 LIMIT

Today a `LIMIT` without `ORDER BY` is exact in count, but not in which rows survive. With several workers,
whichever worker reached the shared budget first keeps its rows (`op_limit.mojo`), and the other
workers' scans keep running after the budget is spent (`src/pipeline_exec/README.md`, Known limits). A
limit that is not over a sort is lowered into the pipeline as an `OP_LIMIT` (`cut_limit.mojo`).

In a streamed run, **a limit that is the last operator of the root pipeline** is taken off the root
segment's operator list by `open_sql`, after lowering, and its count is given to the result sink. The
lowering, the lowered plan's rendering and its goldens, and the plan wire do not change. The result sink
counts the rows it hands out in position order, slices the batch that crosses `n`, and then ends the
stream. No further round runs, and the run is released as on an early release (§5.8). So that `LIMIT`
returns the first `n` rows in file order, which DuckDB returns too, and reads no more than one round past
them.

A limit with an operator above it in the same pipeline stays an operator. It keeps today's behaviour:
exact in count, and the rows that survive depend on the schedule. A `LIMIT` over a sort is the top-N
breaker, as today. The lowering cuts no limit offset outside a sort (`cut_limit.mojo`), so the result
sink carries a count only.

### 5.6 What does not stream by nature

A breaker finishes before its output exists: a sort, a top-N, a grouped or ungrouped aggregate, a
`DISTINCT`, a window, and a join's build side. When the last pipeline's input comes from one of them,
the stream waits for it:

- **The first `get_next` returns only after the breakers below have finished.** For
  `SELECT region, sum(x) FROM t GROUP BY region`, the whole scan and aggregation happen inside the first
  `get_next`. The answer is then handed out batch by batch over the aggregate's published output, through
  the in-memory batch source.
- **Meanwhile** `komira_run_progress(run, &done, &total)` counts segments as today, and
  `komira_run_cancel(run)` stops the run at its next check, which is the next morsel inside a breaker's
  pipeline. A breaker's `combine`, sort or merge does not check the token today, so a cancel that lands
  there waits for it to finish.
- **Memory** for these queries is what the breakers hold, as today, plus the byte limit for the batches handed out
  from it. The breaker's own output stays uncharged, as today. Streaming saves the collect sink's copy of
  the root output, about half the peak today (§3).
- **A root segment that is itself a breaker** (a final `ORDER BY` or aggregate, with no pipeline above
  it) has its output as the result today: "the root of the plan is a `SINK_COLLECT` unless its top node is
  itself a breaker whose output is the result" ([lowering_and_pipeline.md](lowering_and_pipeline.md)). In a
  streamed run, `open_sql` adds, after lowering, a last pipeline with no operators that reads that
  breaker's published output through the in-memory batch source. The output is then handed out like any
  other published output, and the lowering does not change.

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
  for the run's token.
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
  - A `get_next` that is running a round or a breaker returns `ECANCELED` once the workers reach their
    next check (the next morsel, or the next chunk of an emitting operator).
  - `get_last_error` then returns
    `QUERY_CANCELLED: execute: pipeline_exec: the query was cancelled: the caller cancelled the run`,
    today's cancel text (`src/so/tests/c/abi_driver.c`).
  - A `get_next` after the cancel returns the same, without running anything.
  - A cancel after the stream ended does nothing.
- **`release` before the end** ends the run. Release is called by the reader, never concurrently with
  `get_next` (the Arrow rule). With rounds pulled by the reader, no round is running when release is
  called, so release has nothing to wait for. It cancels the run's token, so a breaker's spill files and
  the like see a cancel. Before it returns it frees:
  - the queued batches, the result sink's chunks, and their charge to the context's pool;
  - the source's resumable state (its cursor position) and the published outputs of the breakers below
    that the root has not consumed;
  - the run's footer cache, expression pool, opener, credentials and lowered plan;
  - its share of the run handle's control, and its share of the engine core (§5.10).
- **After release the source is read no more.** Zero bytes, by construction, since no round can start. The
  Parquet source gives the operating system an advisory read-ahead hint for the next row group at the end
  of each claim (`_prefetch_next`). In a streamed run the hint is given only for a claim the limit has
  allowed, so a round that stops at the limit leaves no hint for unread data.
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
session thread serialise every run. With streams, two readers on two threads may each want a round, so
a lock serialises them.

- **Where it is taken.** Every dispatch on a context's dispatcher comes from one place: `run_segment`'s
  `run_with_state` (`src/pipeline_exec/run_segment.mojo:115`), reached through
  `run_lowered_plan_with`'s `ctx.runtime.dispatcher()` (`src/sdk_exec/engine_execute.mojo:159`). No
  other code in `sdk_exec` or `so` takes the dispatcher. Inside a segment, a breaker's `combine` may run
  further fork-join passes on the same dispatcher (the sort's gather, through `fork_join_shared`). Those
  run within the segment, under the same lock. So the lock is taken in exactly two places:
  - around each `run_segment` call, materialised or streamed, covering its dispatch, tails, `combine`,
    `finalize` and `take_output`;
  - around each round of a streamed run.
- **Who takes it.** Only reader threads and callers' threads take it, never a worker. A worker blocking on
  its own runtime is the hazard [async_runtime.md](async_runtime.md) rules out.
- **Waiting for it.** The wait watches the run's token, so a `get_next` waiting for the lock still returns
  `ECANCELED` on a cancel.
- **What a waiter waits for.** A run that wants the dispatcher waits for the round or segment in progress.
  That is engine work, never a reader.

Consequences:

- **Two open streams on one context** interleave by rounds. A third query, materialised, runs between
  their rounds.
- **A run reads no mutable context state after open** (§5.2). So registering a table, adding a binding or
  starting another query while a stream is open does not change what the open stream reads. It reads the
  catalog as it was when it opened.
- **A stream fed back into the engine** (`komira_register_arrow_stream` given a komira stream, or Python's
  `register(name, result)`) is drained whole by the registering call into the registered table, as any
  registered stream is (`src/so/sources.mojo`). Its `get_next` calls run rounds, taking the dispatch lock
  per round. The registering call holds the session (Python takes its session lock), but not the dispatch
  lock while it reads, so the two do not wait on each other.

The cost: a long breaker in one run holds back every other run on the context for its duration. That is
already the case today, since runs on one context are serialised.

### 5.10 What the stream owns

The stream must outlive the context. `komira_ctx_free` may come first today, and §5 of
[libkomira_run_abi.md](libkomira_run_abi.md) requires the stream to hold an `ArcPointer` on any state it
needs that `komira_ctx_free` tears down.

**The engine core.** A streamed run needs the worker runtime with its dispatcher, the dispatch lock and
the context's pool. These move into an engine core held by `ArcPointer`:

- The context holds one share, and each open stream holds one.
- `komira_ctx_free` drops the context's share.
- The core, and with it the worker threads, stops when the last share is dropped: by the context, or by
  the release of the last stream.
- The thread that drops the last share joins the worker threads, which are idle between rounds, so the
  join waits on nothing else. That thread is never a worker. It may be a garbage collector's: pyarrow
  releases an imported stream when the reader is collected, with the GIL held. No worker ever needs the
  GIL, because Python UDFs run in worker processes ([udf_python_worker.md](udf_python_worker.md)), so
  that join cannot wait on the GIL.
- The Node addon's finalizer hands the release to the session's native thread, rather than running it on
  the event loop.

**The run's own state** is held by value, with no pointer types and no reference into itself:

- the lowered plan, footer cache, expression pool, opener and credentials;
- the source's resumable state (its cursor position, and whether it is exhausted);
- the result sink and its queue;
- the error slot;
- the published outputs of the breakers.

The root segment's source and operators borrow the footer cache and expression pool
(`build_parquet_source_on` takes `ref [cache_o] cache` and `ref [pool_o] pool`,
`src/pipeline_exec/source_parquet.mojo`). A struct that held both those values and a source borrowing
them would refer to itself, which Mojo's origins cannot express without the pointer types the rules bar
(M1, M4). So the source and operators are rebuilt at the start of each round, in `get_next`'s frame,
borrowing the run's values for that round, and seeded with the cursor position. At the end of the round
the cursor position is read back. Nothing from a round outlives it but the result sink's batches and the
cursor position. Between rounds the stream therefore has no open file and no mapping.

The cost is building the source once per round. The footer cache is the run's and survives, so a rebuild
reads no footer twice. The rounds slice starts with a minimal Mojo program of this shape, before the rest is built.

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

- Its first `get_next` runs the whole plan exactly as `run_sql_with` does today, queues its batches, and
  hands them out.
- A result whose columns cannot be known before the data is read (today, a result with a nested column,
  whose child types come from a batch, §6.3) has its `get_schema` do the same. So such a result is
  computed whole and returned to the SDK as it is today, through the same stream.
- Its memory is today's, and its errors come from that first call.

**Every other query streams.** After the first slice that is the last pipeline over a Parquet scan or a
table in memory, through filters, projections and a final `LIMIT`.

So no binding needs a fallback of its own, and no statement that works today fails, or is left undone,
through the open call. Each shape below runs materialised until the slice named beside it:

| shape | why | streams from |
|---|---|---|
| a CSV source in the last pipeline | the source decodes the whole input first (§3) | the CSV slice |
| a JSONL or Iceberg source in the last pipeline | the same | a later slice |
| a join probe in the last pipeline | one claim's output is not bounded (§5.3) | a later slice |
| a result with a nested column | its columns need a batch before `get_schema` can answer (§6.3) | a later slice |
| `UNION ALL` | each branch is its own segment, run whole and published, and the union reads the published outputs in branch order (`cut_union.mojo`) | the hand-out streams from the first slice, through the in-memory source; the branches themselves still run whole first, as breakers do (§5.6) |

The test of each row asserts that the answer equals the materialised one, and that the source's claims
before the first batch are all of them, which is what "materialised" means. Streaming any row later
changes only that count. The `UNION ALL` test asserts the same for its branches, and that its hand-out
goes through the read-ahead limit.

### 5.12 Making a batch exportable

Batches handed out are cut from larger ones: morsels from a resident table, slices of a breaker's output,
and the batch that crosses a `LIMIT`. Any column of such a batch can start at a non-zero offset.

- The Arrow exporter refuses a string, binary, nested or union column with a non-zero offset
  (`src/arrow_ipc/c_data_stream.mojo:1421-1443`), and exports a fixed-width column at its offset
  (`:1448`).
- The Arrow importer refuses every array with a non-zero offset (`_import_column`, `:1821-1825`), and the
  batch import calls it for every top-level column (`:2860`), fixed-width ones included. A komira stream
  registered back into komira (`komira_register_arrow_stream`, Python's `register(name, result)`) would
  meet that refusal for any sliced column.

So **the result sink compacts every column at a non-zero offset**, of every type, before it queues the
batch. It copies the column so that it starts at offset 0. A batch whose columns all start at 0 is queued
as it is. The copy is charged to the pool before it is made, as part of the batch's real size, and the
uncopied original is released once the copy exists. So the bound of §5.3 covers the copy, and while it is
being made both the original and the copy are counted.

Exporter offset support for the variable-length, nested and union types (rewriting the offsets buffer)
and importer offset support for every type are named later work in `arrow_ipc` (a later slice). They
remove the copy without changing anything a reader sees.

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
come from a C shim, as today (rule M8).

**Why new calls, and not new behaviour behind the old ones.** Each of these reasons alone would break a
binding that is already shipped:

1. **The status contract.** A binding of `komira_sql_stream` today learns of an execution error from the
   call's status, with the code and step in `komira_last_error_code` and `komira_last_error_step`. A
   stream that returns `KOMIRA_OK` and fails later would turn every such error into an errno from
   `get_next`, which the shipped Python and Node packages do not expect. Python would raise a pyarrow
   `OSError` from a read instead of a `KomiraError` from `sql()`, and both would lose the code and step.
   That is a silent re-meaning of a shipped call, which rule B8 rules out.
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
5. Parse, bind, optimise, lower, and the export check of the result schema. A refusal returns -3 (or -6
   if `run` was already cancelled), with the code, step and text in the context's last error, exactly as
   today. `*out` is untouched.
6. A statement with effects (`COPY ... TO`, a plan with a write target) runs to completion here, as
   `komira_sql_stream_run` runs it today (§5.11). Its refusal or failure is the call's status, and `*out`
   is untouched. On success `*out` is a stream of its one `Count` row.
7. Any other statement is marked streamed or materialised (§5.11).
8. `*out` is filled, and the call returns `KOMIRA_OK`. **For a query, no source has been read.**

### 6.3 The stream's callbacks, and the run's error

| callback | before the first batch | while reading | after the end, an error or a cancel |
|---|---|---|---|
| `get_schema` | the result schema from the plan, without running anything (a nested result: see below) | the same schema | the same schema |
| `get_next` | runs the breakers and rounds until a batch, the end or an error (§5.2) | the next held batch, or more rounds | at the end: 0 and a released array, every time. After an error: `ENOMEM` or `EIO`, every time. After a cancel: `ECANCELED`, every time |
| `get_last_error` | NULL | NULL | the text of the error or cancel, valid until the next callback or `release` |
| `release` | ends the run, frees everything (§5.8) | the same | frees what is left; idempotent |

For a statement with effects, the work is done by the open call, so the stream holds only its one `Count`
row, already computed: `get_next` returns that row, then the end, and `release` frees it (§5.11).

- **`komira_run_error_code(run, buf, cap, &needed)`** writes the failed run's code (for example
  `MEMORY_BUDGET_EXCEEDED`, `QUERY_CANCELLED`) in the two-call form of `komira_last_error_code`.
  **`komira_run_error_step(run)`** returns its `KOMIRA_STEP_*`. Both read the run handle, which outlives
  the context. The caller keeps the handle for as long as it wants the code and step; the stream holds
  only its own share of the handle's control, so a freed handle is not read. They return an empty code and `KOMIRA_STEP_NONE` while the
  run has not failed. They may be called from any thread, like `komira_run_progress`. Today's run calls
  given a handle set them too, so one way of reading a run's error serves both kinds of call.
- **The schema is the schema of every batch.** `get_schema` builds the schema from the plan's types alone,
  before any batch exists. Every batch handed out must then match it, field for field:
  - the type, with string and binary widths. A batch whose string or binary column the engine promoted
    to its large form is converted back to the schema's width by the result sink. When its data does not
    fit a 32-bit offset, it is split into batches that do. So a query that works today never fails here;
  - the decimal precision and scale, and the timestamp unit and zone;
  - list item names and struct field order;
  - nullability: a column the plan calls non-nullable carries no null.

  The result sink checks each batch against the schema before it queues it. Apart from string and binary
  width, which it converts, every field above comes from the plan's types in both the schema and the
  batch, so a mismatch is an engine defect. The check reports it by name
  (`STREAM_BATCH_TYPE_DIVERGED: <column>: <what differs>`, returned by that batch's `get_next` as `EIO`)
  rather than export a batch its schema misdescribes. The §9 test
  reads every batch of every exportable type against the schema with a strict importer.
- **A nested result.** Today a nested column (LIST, STRUCT, MAP, UNION) needs a sample batch, because
  its child types come from the column (`c_data_stream.mojo:2880-2903`). Until the export builds nested
  child formats from the plan's types (a later slice), such a query runs materialised (§5.11), and its `get_schema`
  runs it.
- **`EINVAL`** for a NULL argument or a call on a released stream, as today.
- **A batch with no rows** is never handed out: an empty answer is its schema, then the end.
- **A batch's size** is one morsel's output. Batches are not coalesced in the first slices.

### 6.4 Threads

- **One reader at a time.** `get_schema`, `get_next` and `release` are serialised by the reader (the
  Arrow rule). They may be called from any thread, one after another.
- **`komira_run_cancel`, `komira_run_progress` and the two error calls** may be called from any thread,
  at any time, also while a `get_next` is running. That was already true of the run call.
- **`get_next` blocks** for a round or a breaker. While it waits for the dispatch lock it holds no lock of
  the context.
- **The context.** `komira_ctx_free` may run before the stream is read or released (§5.10).
- **The library stays loaded** while a stream is live, as today: the callbacks are its code.

### 6.5 The existing calls

`komira_sql_stream`, `komira_sql_stream_run` and `komira_plan_stream` keep their contract:

- the answer is computed before the call returns;
- every execution error is a status;
- `*out` is written only on `KOMIRA_OK`.

In the one-mechanism slice they are rebuilt inside libkomira as open-then-drain on the calling thread, so there is one
run mechanism. The drain keeps the batches in a list and builds today's stream over it. For these calls the
change is then invisible except that:

- the answer arrives as one batch per morsel, instead of one concatenated batch. That saves the
  concatenation's copy and half of the peak (§3);
- a final `LIMIT` returns the first `n` rows in file order (§5.5), which matches DuckDB where today's
  result may not.

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
- **GIL.** pyarrow calls `get_next` with the GIL released, and Python UDFs run in worker processes, not
  in-process ([udf_python_worker.md](udf_python_worker.md)). So a round never waits on the reader's
  interpreter, and a release under the GIL joins nothing that needs it (§5.10).

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
with no C call. It lands after the first slice, in the Mojo SDK's own slice, with a README example (rule T18).

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

Every test is hermetic (T12) and asserts no time (T10): "first", "before" and "after" are counted in
bytes, claims, batches and events. Where they live:

- the engine tests in `src/pipeline_exec/tests`, `src/parquet_scan/tests`, `src/op_sources/tests` and
  `src/sdk_exec/tests`;
- the C tests in the C driver (`src/so/tests/c/abi_driver.c`);
- the binding tests in `python/tests` and `node/tests`.

Two test-only parts make the counts possible:

- **A generated source.** A `pipeline_exec` source that makes each claim from its index (a counter column
  of 131,072 rows of 8 bytes, 1 MiB, one morsel per claim unless a test asks for more) and stores nothing. Its
  estimate of a claim is exact. It counts its claims and the bytes it has made. It can fail at a chosen
  claim, and it can signal an event and then wait on another at a chosen claim. "A 10 GB scan" is
  10 GiB / 1 MiB = 10,240 claims of 1 MiB from it, generated and never held.
- **A counting opener.** The run already takes an opener (`run_sql_with`). A test opener over the scratch
  directory counts every byte read and every file opened and closed.

### 9.1 The four tests that prove the promise

- `first_batch_arrives_before_the_scan_ends`. A streamed run over the 10 GiB generated source, with four
  workers, a claim limit of 8 and a byte limit of 8 MiB, set through a test hook. When `get_next` returns
  batch 1, the source has taken at most 8 claims and made at most 8 MiB, of the 10,240 claims there are.
  Its estimates are exact and its columns need no copy, so there is no excess. The same over a Parquet
  file of 64 row groups written to scratch by the test: at the first batch the counting opener has read
  the footer and at most 8 row groups.
- `peak_memory_is_the_bound_not_the_input_size`. The same 10 GiB source read to its end, one batch per
  `get_next`. After every `get_next`, the high-water mark of the bytes charged for outstanding claims (a
  counter the pool gains) is at most 8 MiB. A second run over a 1 GiB source has the same high-water
  mark: the bound depends on the two limits, not on the input.
- `early_release_stops_reading_the_source`. Read 3 batches, record the claims and the bytes read, then
  release. Afterwards: no further claim, no further byte read, every file the opener opened is closed, the
  pool's granted bytes are 0, and an array taken before the release still reads its values.
- `an_error_in_the_37th_batch_arrives_on_the_37th_get_next`. The generated source (one batch per claim, claims
  numbered from 1, four workers, the real dispatcher) fails at claim 37. Calls 1 to 36 return batches
  whose first values are `0, 131072, 2 × 131072, ..., 35 × 131072`, in order (131,072 rows of 8 bytes make
  each 1 MiB claim). Call 37 returns `EIO`, with `get_last_error` exactly
  `GENERATED_SOURCE_FAILED: execute: claim 37`, and the run handle's code `GENERATED_SOURCE_FAILED` and
  step `KOMIRA_STEP_EXECUTE`. Call 38 returns the same. The error is not seen before call 37.

### 9.2 The rest of the contract

Rounds and the limit (the rounds slice, with the fake dispatcher and the generated source):

- `a_claim_is_taken_only_within_the_limit`: with a claim limit of 3 and four workers, no more than three
  claims are ever outstanding, read from the limit's counter after each round.
- `one_claim_is_allowed_when_nothing_is_outstanding`: a byte limit below one claim's size; every `get_next` still
  returns a batch, and the high-water mark is one claim.
- `a_first_round_that_yields_nothing_runs_another`: a filter rejects every row of the first round's claims;
  the first `get_next` runs a second round and returns its first batch.
- `batches_come_out_in_position_order_whatever_the_schedule`: workers finish in reverse order (fake
  dispatcher). Every batch's positions increase, across rounds.
- `a_lower_position_error_wins`: the source fails at claims 40 and 38 in one round, the failure at 40 first,
  with workers run in an order a fake dispatcher chooses (`fake_dispatch.mojo`). The stream hands out 37
  batches, then claim 38's error.
- `an_error_discards_the_failing_claims_own_chunks`: a claim that yields three batches fails after its
  second. Neither of its batches is handed out, and the error follows the batches of the claims below it.
- `cancel_from_another_thread_ends_a_waiting_get_next`: the source signals an event when a worker reaches
  claim 5, then waits there on a second event. The reading thread's `get_next` is running the round. The
  cancelling thread waits for the first event, calls `komira_run_cancel`, then sets the second. The
  reading thread's `get_next` returns
  `ECANCELED`, with exactly
  `QUERY_CANCELLED: execute: pipeline_exec: the query was cancelled: the caller cancelled the run`, and
  the next call returns the same.
- `a_streamed_limit_returns_the_first_rows_and_stops_claiming`: `LIMIT 1000` over the generated source
  returns its first 1000 rows and ends, with no more claims taken than the claim limit. With a projection above the limit,
  the limit stays an operator, and only the row count is asserted.

The sources (the claim-sites slice):

- `a_row_group_larger_than_a_morsel_keeps_its_order`: a Parquet file whose row groups are four morsels
  each, with a claim limit small enough that the limit refuses claims in the middle of the file. The rows come out in
  file order, and no round ends with a worker holding a parked sub-morsel.
- `the_claim_reorder_modes_are_off_in_a_streamed_run`: a streamed Parquet scan builds its source with
  stride 1, file claim order and no row-range split, and a streamed in-memory source with stride 1 and no
  stealing.
- `a_claim_and_its_reservation_are_one_step`: workers race on the last claim under a limit with room for
  one; exactly one takes it, and the limit's counter returns to its start once every batch is handed out.
- `every_sliced_column_is_compacted_before_it_is_queued`: a table in memory with a column of every type
  the exporter supports (among them integer, float, boolean, decimal, date, timestamp, string, binary,
  list, struct, map and union), cut into morsels at non-zero offsets. Every column of every
  batch handed out starts at offset 0, every batch exports, every batch imports back through komira's own
  importer, and the bytes counted include the copies.
- `schema_equals_every_batch_for_each_exportable_type`: for every type the exporter supports, with nulls
  in nullable columns, the stream's schema is read before any batch. Every batch is then imported against
  it with a strict importer (types, widths, precision and scale, units and zones, child names and order,
  nullability).
- `a_large_string_batch_is_converted_to_the_schemas_width`: a test hook makes the engine promote one
  batch's string column to its large form. The batch is handed out at the schema's width, with the same
  values.
- `a_string_batch_beyond_32_bit_offsets_is_split`: a test hook lowers the split threshold from the 32-bit
  offset limit to 1 MiB, and one batch carries 3 MiB of string data. It is handed out as several batches at
  the schema's width, each within the threshold, with the same rows in the same order. The threshold is the
  only thing the hook changes, so the test holds a few MiB and stays in the pull request's set.
- `a_null_in_a_non_nullable_column_is_refused_by_name`: a test hook plants a null in a column the plan
  calls non-nullable. That batch's `get_next` returns `EIO` with exactly
  `STREAM_BATCH_TYPE_DIVERGED: <column>: a null in a column the schema calls non-nullable`.
- `a_diverging_batch_type_is_refused_by_name`: a test hook makes one batch's decimal scale differ from the
  plan's. That batch's `get_next` returns `EIO` with exactly
  `STREAM_BATCH_TYPE_DIVERGED: <column>: decimal(18, 2) in a decimal(18, 3) column`, so the check is shown
  to fire.

The run and the C interface (the open-call slice):

- `schema_is_known_before_any_claim_is_taken`: after open, `get_schema` returns the plan's schema, and the
  source has taken 0 claims.
- `a_get_next_waiting_for_the_dispatch_lock_is_cancellable`: stream 1's round is held at an event, stream
  2's `get_next` waits for the lock, a cancel of stream 2's run makes it return `ECANCELED`, and stream 1
  then reads to its end.
- `a_materialised_query_and_a_round_share_one_context`: a `komira_sql_stream` query on one thread while a
  stream's round runs on another. Both answers equal their materialised answers.
- `two_streams_and_a_query_share_one_context`: two open streams read alternately, and a third query runs
  between their rounds. Each answer equals its materialised answer.
- `open_streams_share_the_contexts_budget`: two open streams that each hold 8 MiB, in a context whose
  budget leaves no room for a third stream's first claim. That stream's first `get_next` fails with
  exactly `MEMORY_BUDGET_EXCEEDED: execute: the open results of this session hold 16777216 bytes`.
  Releasing one of the two lets a new stream read.
- `a_streams_own_state_is_charged`: opening a stream raises the pool's granted bytes by the size of its
  plan and expression pool, and reading a footer raises it by that footer's size. Release returns all of
  it.
- `an_order_by_on_a_string_column_is_handed_out_in_batches`: `ORDER BY` with a string column. The first
  `get_next` returns after the sort segment (progress shows it done), every batch exports, and the
  concatenated batches equal the materialised answer.
- `a_sorted_roots_peak_is_its_output_plus_the_byte_limit`: an `ORDER BY` over 64 MiB of rows, read one
  batch per `get_next`, with a byte limit of 8 MiB. The sort's published output is measured, and the
  high-water mark of the bytes charged for outstanding claims, copies included, is at most 8 MiB however
  large that output is. The test repeats over 32 MiB of rows and sees the same mark. With the output
  measured and nothing else held by the run beyond the charged bytes (the pool's granted bytes, less the
  stream's own state, equal the charged bytes), the peak is that output plus the byte limit.
- `a_cancel_during_a_breaker_returns_ecanceled_on_the_first_get_next`: the same cancel test, with the
  source waiting below an aggregate.
- `the_stream_outlives_its_context`: `komira_ctx_free` after open and after batch 1. The stream is then
  read to its end and released, and its arrays are read after that.
- `a_sorted_komira_stream_registered_into_its_own_context`: `komira_register_arrow_stream` given a sorted
  stream, with a string column, from the same context completes, and the registered table equals the
  answer.
- `an_integer_keyed_sorted_stream_registered_into_its_own_context`: the same with a sort on an integer key
  and only fixed-width columns, so every column of the sliced output would sit at a non-zero offset
  without compaction. The registration completes, and the registered table equals the answer.
- One test per row of §5.11 (`a_csv_source_runs_materialised_inside_the_stream`,
  `a_jsonl_source_runs_materialised_inside_the_stream`, `an_iceberg_source_runs_materialised_inside_the_stream`,
  `a_root_probe_runs_materialised_inside_the_stream`,
  `a_nested_result_runs_materialised_inside_the_stream`): the answer equals the materialised answer, and
  the claims before the first batch are all of them.
- `a_union_all_hands_out_through_the_limit`: `UNION ALL` of two Parquet scans. Each branch's claims are all
  taken before the first batch, the hand-out takes no more claims than the claim limit from the published
  outputs at the first batch, and the answer equals the materialised one in branch order.
- `a_copy_opened_and_never_read_writes_its_file`: `komira_sql_open` of a `COPY ... TO` returns `KOMIRA_OK`.
  The file is already complete when it returns. The stream is released at once, unread, and the file is
  still there with every row.
- `a_cancel_during_a_copy_inside_open_returns_cancelled`: the query of a `COPY ... TO` waits on an event at
  a chosen claim. Another thread cancels the run handle and sets the event. `komira_sql_open` returns -6,
  and no file or temporary file is left.
- `a_failing_copy_fails_the_open_call`: a `COPY ... TO` whose query fails returns -3 from
  `komira_sql_open`, with the code and step in the context's last error. No temporary file is left, and the
  destination is as it was.
- `an_empty_answer_is_its_schema_then_the_end`.
- The lifetime cases carried from the earlier engine (§2.4), run against a stream that is still producing:
  every buffer read after release in the three release orders, and a thousand open, read and release
  cycles with the pool back at 0.
- **C interface:** the golden rows, the `gate_version` pin, the export list, the `abi_driver.c` cases for
  each status of §6.2 and for the two error calls before and after a failure, and
  `binding_falls_back_when_the_library_has_no_open_call` (a binding of this version against the stand-in
  library of the previous minor).

The bindings (the bindings slice):

- **Python:**
  - `sql_raises_for_an_error_before_the_first_batch`;
  - `to_reader_raises_komira_error_for_a_late_error`, with the exact message, and the code and step from
    the handle;
  - one Ctrl-C test per terminal (`ctrl_c_during_to_reader_cancels_the_run`, and the same for `to_arrow`,
    `to_pandas`, `to_polars` and the repr);
  - `result_cancel_stops_a_capsule_consumer`, where DuckDB reads `__arrow_c_stream__` on its own thread;
  - `repr_reads_only_the_rows_it_shows`, by the run's claim count, read through a test hook;
  - `releasing_the_last_share_from_a_finalizer_joins_cleanly`: drop the session, then let the garbage
    collector release the last open reader. The worker threads are joined, and the process's thread count
    returns to what it was before the session;
  - one test per row of §5.11 through `sql()`, whose answer arrives;
  - `a_copy_through_sql_writes_its_file_though_the_result_is_never_read`: `sql("COPY ... TO ...")`, the
    `Result` dropped unread, and the file complete;
  - later, the `read_csv` chunk cases: exact chunk sizes across batch boundaries, `get_chunk(size)`, a
    malformed line in chunk 3 raising at chunk 3, and `with` closing the run.
- **Node:** `breaking_out_of_the_iterator_ends_the_run`, `abort_while_reading_rejects_next`,
  `a_collected_result_is_released_on_the_session_thread`, and one test per row of §5.11 through `sql()`
  (CSV, JSONL, probe, nested, `UNION ALL`), whose answer arrives and equals the materialised one, and
  `a_copy_through_sql_writes_its_file_though_the_result_is_never_read`.
- **The plan-door slice:** `a_plan_with_a_write_target_opened_and_never_read_writes_its_file`, through
  `komira_plan_open` in the C driver and through `to_parquet` and `sink_parquet` in Python.

### 9.3 Why this list is complete

Each promise of §5 and §6 has a test that fails when the promise breaks:

- **The bound:** the limit's claim count, the always-allowed claim, the first batch, the peak, the shared
  budget, and the one-step reservation.
- **Early stop:** release, `LIMIT` and `break`.
- **Late errors:** the 37th call, the lower position, the failing claim's own chunks, stickiness, and the
  code and step from the handle.
- **Cancel:** from another thread, while waiting for the dispatch lock, during a breaker, through Ctrl-C
  on each terminal, and through `Result.cancel()`.
- **Order:** the schedule test and the split row group, with the source modes that would break order
  tested apart.
- **Export:** the schema against every batch of every type, a converted string width, a planted null and a
  planted type that the check refuses, a batch split at 32-bit offsets, the compaction of sliced columns
  of every exportable type, and a sliced
  stream imported back by komira with string and with fixed-width columns.
- **Effects:** a `COPY` opened and never read (in C, Python and Node), a plan with a write target opened
  and never read, a `COPY` that fails at open, and a `COPY` cancelled inside open.
- **Memory of breakers and of open streams:** the counted peak of a sorted root, and a stream's own state
  charged to the pool.
- **Also:** the schema before running, what cannot stream, every shape run materialised, lifetime
  (against the context, against release and against a finalizer), concurrency on one context, feeding a
  stream back into the engine, the empty answer, both directions of version skew, and each binding's own
  mapping.

The boundaries are an empty answer, one batch, a claim larger than the byte limit, a first round that
yields nothing,
an error in the first claim, a cancel before the first round, and a release before the first `get_next`.

## 10. Slices

The first slice is three pull requests, each tested alone, in this order:

- **The rounds slice, in `pipeline_exec`.** First, the minimal Mojo program of §5.10: a run that owns its
  values and rebuilds a borrowing source each round, with no pointer types. Then:
  - the round loop and the source's "refused" versus "exhausted";
  - the result sink, with its position order and its charge;
  - the read-ahead limit and its one-step reservation, over the generated source;
  - the lowest-position error slot.

  Tested with the fake dispatcher and the generated source (§9.2, the rounds group), with no file, no C
  call and no change to any source.
- **The claim-sites slice, in `parquet_scan`, `op_sources` and `pipeline_exec`.**
  - The limit at the Parquet cursor (`_claim`) and at the in-memory source's cursor.
  - Each source's streamed options (§5.4): Parquet's stride 1, file claim order and no row-range split,
    and a new stride option on `BatchMorselOptions` with stealing off.
  - The compaction of every column at a non-zero offset (§5.12), and the conversion and check of each
    batch against the schema (§6.3).

  Tests: §9.2, the sources group. The row-range split's own counter gets the limit in a later slice.
- **The open-call slice, in `sdk_exec` and `so`.**
  - `StreamedRun` and `open_sql` in `sdk_exec`, with the trailing `LIMIT` taken off the root's operators;
  - the engine core, with its context pool, its charge for each stream's own state, and its dispatch
    lock;
  - statements with effects run inside open, and the other unstreamed shapes run materialised inside the
    stream (§5.11);
  - `komira_sql_open`, `komira_run_error_code` and `komira_run_error_step` (the next minor);
  - the throughput measurement and its condition (§5.3).

  Tests: §9.1, and §9.2's run and C-interface group. Python and Node do not call it yet, and the C driver
  is the reader.

The slices after it:

- **The bindings slice: Python and Node read streams.**
  - `sql()` goes through `komira_sql_open`, with the first-batch pull.
  - Every terminal reads on the helper thread, and the `Result` keeps the run handle and gains
    `Result.cancel()`.
  - It also brings `to_reader()`'s wrapper, and Node's iterator, `signal` and finalizer.
  - The docs that say `to_reader()` reads only what is asked change with it.

  Because §5.11 runs every statement with effects inside open, and every unstreamed shape materialised
  inside the stream, no statement that works today fails or is left undone after this slice.
- **The plan-door slice.** `komira_plan_open` (the next minor) and `open_plan`. `DataFrame.materialize()`,
  `komira.pl`'s `collect()` and `collect(engine=...)` stream, and the pandas `to_*` and polars `sink_*`
  writers run inside open.
- **The CSV slice: a CSV source that streams.** It claims byte ranges cut at line ends, decodes one range
  per claim, and keeps the types inferred at open. Then `read_csv(chunksize=n)` and `iterator=True` once
  §11 is decided, with `collect_batches` beside them.
- **The writes slice: streamed writes.** `COPY ... TO` and the SDK writers as a streamed run with an
  in-engine writer (§8), still run to completion inside open.
- **The read-ahead slice, if measured.** A driver that starts the next round when half the bound is free.
  It is built only if a later measurement (a slow reader, or a query the throughput check did not cover)
  shows the idle time matters (§12, decision 2). If the open-call slice's own throughput check needs it,
  it is built there instead (§5.3).
- **The one-mechanism slice.** The old run calls are rebuilt as open-then-drain (§6.5). `CollectSink`'s
  concatenation stays only where a breaker's input needs one batch.
- **Later slices.**
  - The keyed join probes split their output into chunks, as CROSS does, and a probe in the last pipeline
    streams.
  - The JSONL and Iceberg sources stream.
  - A nested result schema is built from the plan's types.
  - Exporter and importer offset support in `arrow_ipc` (§5.12).
  - The limit goes on the row-range split's counter, so a streamed scan may split large row groups
    (§5.4).
  - A cancel check inside a sort, merge and combine.
  - The Mojo SDK's `ResultStream` (§7.3).

The three parts of the first slice touch `pipeline_exec`, then `parquet_scan` and `op_sources`, then
`sdk_exec` and `so`. This document is their design (rule B22). The CSV slice and the writes slice do not
depend on each other.

## 11. Open decision: what a `read_csv(chunksize=n)` chunk is

pandas' chunk is a pandas `DataFrame`. The task examples run with only pyarrow and protobuf installed
(`python/docs/tasks/BUCK`), so komira cannot return a pandas frame there. The choice decides what user
code over a chunk can do, and it cannot be changed later without breaking that code. The options:

- **(a) A `pyarrow.Table`.**
  - Works in the examples environment today, with no new engine work.
  - pandas code over a chunk (`chunk[chunk.x > 0]`, `chunk.groupby(...)`) does not run.
- **(b) A komira `DataFrame` over the chunk's rows.**
  - The same verbs as the frame `read_csv` returns without `chunksize`, and `.to_pandas()` when pandas
    is installed.
  - The plain cost: a frame over rows held in memory needs an in-memory scan in the plan wire, which it
    does not have today ([dataframe_surface_verbs.md](dataframe_surface_verbs.md), `scan_in_memory` not
    built). That is a plan-wire change, with its goldens and the cross-version tests rule B8 asks for. It
    lands before `chunksize` does.
  - komira frames have no index ([dataframe_surface.md](dataframe_surface.md)), so pandas' continuing
    `RangeIndex` has no counterpart.
- **(c) A pandas `DataFrame`, which requires pandas.**
  - Exactly pandas' type.
  - It cannot run in the examples environment, and it makes pandas a hard dependency of one komira path.

**Recommended: (b)**, with `read_csv(chunksize=n)` refused by name until the in-memory scan lands. A
komira user writes komira verbs, and (b) is the only option under which the code they write for the
frame without `chunksize` also runs on a chunk.

## 12. Decisions taken

Each is decided here so the slices can start, with its reason.

1. **The model is rounds pulled by the reader** (§5.1). It fits the fork-join executor unchanged, and no
   thread waits on a reader, so a stream read back into its own context cannot deadlock. Release frees
   everything at once. A blocking queue with a driver thread would hold the context's dispatcher while a
   reader pauses. Pull per batch would lose either the parallelism or a dispatch per batch.
2. **No read-ahead driver for now** (§5.1). The engine idles while the reader works. Whether that matters
   is measured in the open-call slice, and the read-ahead slice adds the driver only if it does, at the cost of a thread per stream and a
   release that waits.
3. **The bound is fixed by the engine** (§5.3). No caller sets the claim limit or the byte limit until a user shows a case the
   default serves badly (rule B20: no speculative knob). The default sizes the byte limit from the scan's row groups,
   so that every worker can be busy.
4. **No unordered stream** (§5.4). A stream's order is the materialised order, and DuckDB's with its
   default settings. An unordered hand-out would be faster only by the wait for a round's slowest claim,
   and it would need a second hand-out path. polars' `maintain_order=False` is refused by name.
5. **`sql()` returns after the first batch** (§7.1). Errors before the first batch stay at `sql()` with
   their code and step, so existing code that catches errors around `sql()` still catches every error a
   query meets before it produces rows, and streaming is the default. The cost is that `sql()` runs one
   round, or the breakers, even when nothing is read. Opening without a pull would move every execution
   error to the reads, and an opt-in flag would be a second way to run a query.
6. **The plan door's cancel is `komira_plan_open`** (the plan-door slice). A `komira_plan_stream_run` added now would be a
   row that the one-mechanism slice makes redundant.
7. **A shape that cannot stream yet runs materialised inside the stream, and a statement with effects
   runs to completion inside open** (§5.11). Neither is refused, so the bindings need no fallback of their
   own, and turning streaming on in the bindings slice breaks no statement that works today. A statement
   with effects must not depend on the caller reading: a C caller that opens a `COPY` and releases the
   stream unread still has its file, and learns of a failure from the open call.
8. **One memory budget per context, each stream's own state charged to it, and no cap on the number of
   open streams** (§5.3). The pool bounds the bytes of all open streams together, their plans and footer
   caches included, so their number is bounded by the budget. An open stream that is not read holds no
   thread and no file. A separate cap on the count would fail ordinary code that keeps several results.
9. **A late error's code and step are on the run handle** (§6.3), read by `komira_run_error_code` and
   `komira_run_error_step`. A binding never parses the text, and the context's last error, which a stream
   outlives, is not overloaded. `ENOMEM` is used for `MEMORY_BUDGET_EXCEEDED`, so a raw consumer such as
   DuckDB or pyarrow sees a memory error, and `EIO` for every other engine error.
10. **A failed stream stays failed.** Every `get_next` after an error or a cancel returns the same errno
    and text. Arrow defines no stream that resumes.
11. **An error's position decides, not its time** (§5.7). It makes the rule about which call returns the error deterministic, at
    the cost of letting the claims being worked on finish after an error.
12. **The limit sits at the source's claim, and a claim and its reservation are one step** (§5.3, §5.4). A
    claim is the unit that is either wholly in one round or wholly in a later one, which keeps order across
    rounds without a window.
13. **The claim-reordering modes are off in a streamed run** (§5.4). They cost load balance, which the
    throughput check measures. A window would cost memory the bound would have to cover.
14. **Sliced columns are copied before they are queued, and the copy is counted** (§5.12). Exporter offset
    support would avoid the copy, and it comes later (a later slice) without changing anything a reader sees.
15. **The source and operators are rebuilt each round from values the run owns** (§5.10). A struct that
    owns values and a borrower of them would refer to itself, which the Mojo rules allow only through
    pointer types they bar.
16. **Only a trailing root limit moves to the hand-out, and `open_sql` moves it** (§5.5). The lowering and
    the plan wire are unchanged. A limit with an operator above it keeps today's behaviour.
17. **The dispatch lock is taken around each segment and each round, only by reader and caller threads,
    and its wait is cancellable** (§5.9).
18. **No empty batch is handed out, and batches are not coalesced** in the first slices. A morsel's output
    is the unit.
19. **A NULL run handle is allowed** in `komira_*_open`. Release still cancels.
20. **The old run calls are unchanged until the one-mechanism slice**, and then change only in batch count and in which rows a
    final `LIMIT` keeps (§6.5).

## 13. Docs this design finds stale

Rule P10. These are fixed by the slice that changes the behaviour, not here:

- `Result.to_reader()`'s docstring says it "reads its batches as they are asked for". That is true of
  the reader, and not of the engine, which has computed them all. It is fixed in the bindings slice.
- [libkomira_run_abi.md](libkomira_run_abi.md) §5 ("Materialized first") and §10 (`ECANCELED` "when one
  exists") point forward to this document once the open-call slice lands.
- The `read_csv` task page (rank 28, "process a CSV larger than memory") says `to_reader()` reads batches
  as they are asked for. It is fixed with the bindings slice and the CSV slice.
