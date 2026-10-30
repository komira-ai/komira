# komira_pipeline_exec

The driver that runs the segments of a physical plan. A plan is a list of
`SegmentDescPod` (`komira_physical_plan`): each segment is a source, a chain of
operators and a sink, with dependencies on other segments. `run_plan` runs the
segments in dependency order, and `run_segment` runs one segment on the workers
of a `ParallelDispatch` (`komira_async_api`), over the source, operator and sink
traits of `komira_morsel`.

Import each module by name; the package root exports nothing.

- `run_plan`: `run_plan(descs, builder, dispatch, num_workers, token)` checks
  the plan, then repeats: take the ready set, start its lowest segment id,
  publish its output. It returns the outputs no dependent took, by segment id.
  A segment that raises ends the run and the segments not started do not start.
- `run_segment`: build the members, size the sink for the workers, run one
  `SegmentTask` per worker, then combine once, finalize and take the output. A
  recorded error, or a cancellation by the caller's `CancellationToken`, is
  raised after the workers joined, and the sink is never combined or read.
- `segment_task`: `SegmentRun`, the state the workers share, and `SegmentTask`,
  the worker body. A worker reads the cancel flag and the token at every morsel
  boundary, claims a morsel (`None` at the end of input, never asked again by
  that worker), runs the operator chain and hands the rest to the sink. An
  operator returning HAVE_MORE_OUTPUT is executed again on the same morsel, each
  chunk pushed on before the next is asked for; FILTERED_EMPTY drops the morsel;
  FINISHED lets the rows it held go on and stops the worker's claims. A raise is
  recorded in the pipeline's first-error slot, which keeps the first error, and
  cancels the pipeline so the other workers stop at their next boundary.
- `plan_check`: `check_plan` refuses, by name and before any segment is built,
  a plan the driver cannot run; `ready_set` lists the segments that may start.
- `edge_policy`: what the driver does with each edge tag and order key. E1, E2
  and E3 make a consumer wait for its producer, E5 does not, E4 is refused;
  ORDER_NONE and ORDER_PARTITION_ID are served and ORDER_ROW_RANGE is refused.
- `published_outputs`: `PublishedOutputs`, the batch each finished segment left.
- `segment_builder`: the `SegmentBuilder` trait through which a plan's members
  are constructed from a descriptor. `build_source` is given the worker count
  (a source that sizes per-worker state at construction needs it) and
  `build_sink` the schema of the source's morsels (a sink that must name its
  output when no morsel reaches it needs it).
- `source_variant`, `op_variant`, `pipeline_sink`: the closed variants. Each
  holds one of three member types, fixed where the variant is named, and a tag;
  its trait methods test the tag and call the member. `unused_members` fills
  the slots a list leaves empty with members that refuse to run.
- `source_parquet`, `source_batch`, `source_sink_output`: the sources of a
  plan. `build_parquet_source` makes a `komira_parquet_scan` `ParquetSource` on
  the local file system from the Parquet arm of a `SourceSpecPod`: it refuses a
  spec that is not total, resolves the projection names through the footer of
  the first file the path lists (a path may be a file, a directory or a glob),
  and installs the filter as the decode filter (every conjunct is applied; a row
  whose predicate is UNKNOWN is dropped) and as the pushed predicate that
  row-group statistics are checked against. The source borrows the caller's
  footer cache and expression pool. `BatchSource` serves a copy of a resident
  batch and `SinkOutputSource` the batch a finished segment published, each as
  morsels claimed from one shared cursor.
- `op_filter`, `op_project`, `op_limit`: the operators. A filter evaluates its
  predicate and records the rows it keeps as the batch's selection mask instead
  of gathering them; all rows kept leaves no mask, none kept is FILTERED_EMPTY,
  a batch that arrives with a mask is gathered first, and a predicate whose NULL
  scope the evaluator cannot derive is refused by name, when the first non-empty
  batch reaches the filter (a query in which no row arrives is not refused). A projection is
  `komira_operator_api.MapOp` over expressions registered once and shared by the
  workers; it honours the mask as that package states. A limit counts the
  selected rows of every worker against one atomic budget, cuts the morsel that
  crosses it, and reports FINISHED once it is spent. With several workers which
  rows survive depends on the claim order; how many does not.
- `sink_collect`: `CollectSink` keeps each worker's morsels (gathered if masked)
  in the worker's own slot, orders them at `combine` by (partition id, origin
  hint) so a scan collects in file order whatever the schedule, and concatenates
  them. With no row it returns no rows under the schema the segment would have
  had.
- `sink_agg`, `agg_fold`, `agg_output`: the ungrouped aggregation sink
  `(SINK_AGG, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR)`: SUM, COUNT, COUNT(*), MIN,
  MAX and AVG. The aggregate arguments (`AggSinkData.agg_exprs`) are run by each
  worker as a projection over the morsel, under its selection mask; the state
  of a worker is one cell per aggregate, a count and one 128-bit integer. The
  folds are exact integer folds over signed integers, DECIMAL128 (the
  unscaled value; the scale rides beside it) and, for MIN and MAX, DATE32, so
  the merge in worker order does not depend on the schedule. No float is
  folded: a float input is refused by name. SUM over a decimal is a DECIMAL128 of
  the input's scale in the declared precision, over an integer an INT64; a sum
  that leaves 128 bits, has more digits than the declared precision, or leaves
  INT64 is refused rather than wrapped. AVG is a DOUBLE: one conversion of the
  exact sum (`decimal_to_float64` for a decimal) divided by the count. Over no
  non-NULL row SUM, MIN, MAX and AVG are NULL and COUNT is zero, in one row of
  the declared schema. `AggSinkData.presorted` and `estimated_groups` belong to
  grouped sinks and are ignored.
- `segment_pool`: `SegmentPool`, an atomic byte count with an optional budget
  that any number of handles share, and `WorkerReservation`, a worker's plain
  tally inside the blocks it drew (a grant is a compare-and-swap, so the count
  never passes the budget and a request that fits is not refused). A
  reservation returns its blocks when it is dropped. The aggregation sink's
  state is fixed in size, so it draws once per worker; the pool is the draw
  point for sinks that grow.
- `sink_sort`, `sort_nulls`: the in-memory sort `(SINK_SORT, KEY_DTYPE_NONE,
  SINK_ORIENT_COLUMNAR)`, for a small result (TPC-H Q1's ORDER BY over its
  grouped rows). It collects with a `CollectSink` (morsels in position order),
  then sorts the one batch by `SortSinkData`: keys, directions and per-key
  NULL placement (an empty `nulls_first` means the engine's default, NULLS
  LAST). `komira_op_sort.sort_batch_by_keys` is the sort and is stable, so tied
  rows keep the collected order; it does not read a NULL placement, so
  `sort_nulls` gives it, for each key that has a NULL, an INT32 rank column and
  the key with its NULL slots overwritten by a valid value, and gathers the
  input by the sorted row numbers. Each worker draws the bytes of the morsels it
  keeps from the segment pool; at `combine` the sink draws twice the bytes kept
  (the concatenation and the sorted copy: the peak is about three copies of the
  input) and refuses, by name, when the pool or `SortSinkData.memory_budget` (when
  positive) cannot hold them. There is no spill. `sort_harness` is the table
  and the oracle of its tests.
- `spike/intern_spike.mojo` (target `intern_spike`, not part of the library): the
  dictionary-interning spike of the string group-by. A standalone program that times
  interned dictionary codes, hashing every row, the fragment merge and the string-table
  memory on a synthetic workload and checks each layout's counts; its numbers and what
  they decided are in `docs/design/lowering_and_pipeline.md` (section 4.3).
- `real_builder`: `RealBuilder`, the `SegmentBuilder` over these members. It
  serves SOURCE_PARQUET, SOURCE_BATCH, SOURCE_SINK_OUTPUT, OP_FILTER,
  OP_PROJECT, OP_LIMIT and the sinks `(SINK_COLLECT, KEY_DTYPE_NONE,
  SINK_ORIENT_COLUMNAR)`, `(SINK_AGG, KEY_DTYPE_NONE,
  SINK_ORIENT_COLUMNAR)` and `(SINK_SORT, KEY_DTYPE_NONE,
  SINK_ORIENT_COLUMNAR)`, and refuses every other kind by name. It keeps the
  resident batches (`add_resident`), the aggregation sink data a descriptor's
  `sink_param_id` indexes (`add_agg_sink`), the sort sink data (`add_sort_sink`) and the segment pool
  (`set_memory_budget`, unbounded until set), shares one set of operator parts among the
  workers of a segment run, and derives the empty-output schema by running the
  chain's projections over a batch of no rows. Three origins name the borrows of
  the Parquet source (the footer cache, the expression pool, an absent dynamic
  filter).
- `plan_harness`: segment descriptors for the three sources with an operator
  chain and a collect sink (`with_agg_sink` turns one into an aggregation),
  `project_columns`, and a sample table with readers, for plans written by hand.
- `tpch_q6`: TPC-H Q6 as such a plan (scan, filter, project, SUM into a
  DECIMAL(38,4)) and a lineitem-shaped table with the types of the real files
  (DECIMAL(15,2), DATE32) whose first rows sit on every predicate's boundary.
- `fake_support`, `fake_members`, `fake_builder`, `fake_dispatch`: sources,
  an operator, sinks, a builder and dispatchers that record what the driver does
  in shared counters, and run the workers one after another in an order a test
  chooses.

Per-worker state lives in a typed `List`, never in a byte-backed `Slab`
reached through `get_mut_interior`: a value that holds heap (a `List`, an
`ArcPointer`, a `CancellationToken`) must be owned by an element the compiler
tracks. `SegmentRun.ops` is a `List` of operators (one chain per worker, index
`worker * n_ops + op`) mutated through the run's `mut` borrow; a sink keeps its
slots as `List[ArcPointer[Slot]]`, each worker touching only the slot of its own
task id. Atomics-only cells (the fakes' tally) may stay in a `Slab`. The task id
that `ParallelDispatch` passes selects the slot, not the worker id, which only
names the thread that runs the task; a dispatcher may run more tasks than it has
workers.

The combine order is a property of the sink. `CollectSink` merges its per-worker
slots at `combine` into one order by (partition id, origin hint), and morsels
that tie keep the order of the worker slots (worker id, then arrival within the
slot); a sink without such a key (the fakes) concatenates the slots in worker id
order. Either way the order is decided after every worker has joined. A
memory budget is a property of the sink too: a sink that cannot grow raises, and
the raise fails the query through the first-error slot.

## Known limits

- **A limit does not stop the other workers' scans.** `LimitOp` reports FINISHED
  to the worker that sees the budget run out, and `SegmentTask` stops only that
  worker's claims. A worker whose morsels are all FILTERED_EMPTY by an operator
  upstream of the limit never reaches it, so it keeps draining the source after
  the budget is spent. The result stays exact (no morsel past the budget
  reaches the sink); the scan work is wasted. A pipeline-level stop (a shared
  "finished" flag in `PipelineExecution` that every worker reads at the morsel
  boundary, set by the first FINISHED) is the follow-up.
- **The filter gathers a masked morsel first.** A morsel that reaches `op_filter`
  with a selection mask is materialized (fully copied) before the predicate is
  evaluated. Whether a mask-aware evaluation is worth it is for slice 3 to
  measure.
- **The collect sink holds every chunk until `take_output`.** Chunks stay in the
  worker slots, then in the merged list, and `take_output` concatenates them
  into the output batch, so a segment's peak memory is about twice its output.

## Example

Two segments over fake members. The first produces twelve rows; the second reads
them back and counts them. The workers run one after another, so the result does
not depend on a schedule.

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_async_api.token import CancellationToken
from komira_physical_plan.physical_plan import (
    EDGE_E3_PUBLISH_WAIT,
    SegmentDescPod,
)
from komira_pipeline_exec.fake_builder import (
    FROM_CURSOR,
    FROM_DEP,
    TO_COUNT,
    FakeBuilder,
    FakeScript,
    fake_desc,
)
from komira_pipeline_exec.fake_dispatch import InlineDispatch
from komira_pipeline_exec.fake_support import batch_values
from komira_pipeline_exec.run_plan import run_plan

var descs = List[SegmentDescPod]()
descs.append(fake_desc(0))
var deps = List[Int]()
deps.append(0)
var tags = List[UInt8]()
tags.append(EDGE_E3_PUBLISH_WAIT)
descs.append(fake_desc(1, deps^, tags^))

var builder = FakeBuilder()
_ = builder.add(FakeScript(FROM_CURSOR, n_morsels=4, rows=3))
_ = builder.add(FakeScript(FROM_DEP, rows=5, dep=0, to_kind=TO_COUNT))

var dispatch = InlineDispatch()
var out = run_plan(descs, builder, dispatch, 2, CancellationToken.new())
assert_false(out.has(0))  # the consumer took it
var counted = batch_values(out.take(1))
assert_equal(counted[0], Int64(12))
```
