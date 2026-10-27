# Design: lowering a bound plan and running it, from SQL text to record batches

Status: design, not built. **EXISTS** names code on `main`; everything marked **PROPOSED** is new. The new names (all
absent from `main`): the packages `komira_lowering` and `komira_pipeline_exec`; the entry `lower`; `LoweringInputs`,
`LoweredPlan` and `ParamTable`; the sink capability table (`sink_capability`) and the sink variant (`SinkVariant`);
the driver entry `run_plan`; `EngineContext` and `EngineOptions` in `komira_sdk_exec`; the door `run_sql`; and the
`read_parquet` footer reader (`ParquetFooters`). Nothing was built or run to write this document. Citations of code
refer to `main`; citations of other designs name the doc and section.

It builds on [plan models](plan_models.md) (§4.2 and decision D7: the pipeline model, lowering as a pure function) and
on [the optimized plan](optimized_plan.md) (§5.3, the closed list of host-local rules; §8, the cut). It does not repeat
them. It does not describe streaming, which [plan models](plan_models.md) §4.3 covers over the same physical plan.

**Where the code and the docs disagree today.**
[Plan models](plan_models.md) §4.1 describes the physical IR as version 13 in `komira_plan_ir`; the code is version 14
in `komira_physical_plan`. [The architecture](../architecture.md) names the lowering layer `komira_compiler`; no such
package exists, and the evaluators and rewrite passes that name once covered live in `komira_batch_eval` and
`komira_optimizer`. This document replaces that name with the two packages below.

## 1. Overview and scope

### 1.1 The gap

A SQL string can be tokenized and parsed (`komira_sql`), a bound plan can be optimized (`komira_optimizer`) and a
Parquet file can be read as batches (`komira_parquet_scan`). Nothing connects them: no function takes a bound plan to
batches, and no function takes SQL text to a result. The benchmark suites (TPC-H, ClickBench, h2o) are SQL text over
Parquet files, so they cannot run until the middle exists.

| Step | State on `main` | This document |
|---|---|---|
| Parse | `komira_sql`: `tokenize`, `parse_sql`, `SqlCatalog` | none |
| Bind | open draft, komira#1216: `bind_statement(stmt, catalog, footers)` returns a `BoundStatement` holding a `LogicalPlan`; footers come from a caller-supplied `SqlParquetFooters` | the caller (§6.2) |
| Optimize | `komira_optimizer.optimizer_driver.optimize` | called, not changed (§6.1) |
| **Lower** | `komira_physical_plan` holds the IR (`SegmentDescPod`, version 14); `komira_lowering_rules` holds one rule (`derive_payload_narrow`); `komira_engine_runtime.record_segment_morsel_rows` sizes morsels; **no function produces segments from a plan** | §2, new `komira_lowering` |
| **Drive** | `komira_morsel` holds the source, operator and sink traits and `PipelineExecution`; `komira_engine_runtime` holds the segment execution context; `komira_async_api.ParallelDispatch` holds the fork-join surface; **no function runs a segment** | §3, new `komira_pipeline_exec` |
| **Sinks a SQL plan can pick at run time** | `komira_op_agg_hash` holds the table kernels (`FlatHashAggregator`, `AggCommitPlan`); the typed stage tables of the open operator pull requests are compile-time typed | §4 |
| **Session state** | `komira_sdk_exec` holds twelve leaf modules; its README says the context is not there | §5 |
| **Door** | none | §6 |

### 1.2 Scope

In scope: one process, one node. A bound `LogicalPlan` goes in; a list of `RecordBatch` comes out; every pipeline of
the plan runs in this process on one worker pool.

Out of scope, with the point where each attaches later:

- **Distributed execution.** The coordinator cuts an optimized plan into segments with exchange edges
  ([the optimized plan](optimized_plan.md) §8.2). `lower` takes either a whole plan or one cut segment (§2.1), and an
  exchange read is a source kind and an exchange write is a sink kind of the same IR, so a host that is handed a
  segment lowers and runs it with the code below. With one host every exchange is elided, which is the case this
  document implements.
- **Shuffle through an object store** ([shuffle](shuffle.md)): the sink behind an exchange write and the source behind
  an exchange read; neither is built here.
- **Streaming** ([plan models](plan_models.md) §4.3): the streaming driver executes the same physical plan in epochs.
  This document's driver is the batch driver of §4.2 there.
- **UDFs, cloud sources, writes (COPY, CREATE TABLE AS), views, materialized results and the SDK's typed DataFrame
  layer.** None is on the path of a SELECT over Parquet.

### 1.3 The path

```
SQL text
  -> tokenize, parse_sql                       komira_sql                  EXISTS
  -> bind_statement(stmt, catalog, footers)    komira_sql                  open draft komira#1216
  -> optimize(plan, config, deps)              komira_optimizer            EXISTS
  -> lower(plan, host_profile, inputs)         komira_lowering             PROPOSED   (pure)
  -> run_plan(lowered, ctx)                    komira_pipeline_exec        PROPOSED   (runs the pipelines)
  -> List[RecordBatch]
```

`run_sql` composes the five calls (§6). `EngineContext` holds what they share (§5). Lowering is pure; running is the
only step that opens a file or starts a thread.

## 2. Lowering

### 2.1 The entry

```mojo
def lower(
    plan: LogicalPlan,
    host_profile: HostProfile,       # komira_engine_runtime.host_profile
    inputs: LoweringInputs,          # the resolved inputs of plan_models §4.2
) raises -> LoweredPlan
```

`host_profile` is the one `komira_engine_runtime` measures once per host process: the engine build, the worker thread
count, the memory budget and the spill tiers. `inputs` holds what the host-local rules read from data, already read:
one `Optional[TableStats]` per scan in scan pre-order (the footers' statistics that `derive_payload_narrow` takes), and
the value of a folded scalar subquery when the plan has one. `lower` opens no file, reads no clock, reads no
environment variable and touches no global. Equal arguments give an equal `LoweredPlan`, byte for byte when rendered;
a test says so (§8).

A `LoweredPlan` is a value: the list of `SegmentDescPod` in dependency order, the `ParamTable` the segments index
(§2.2), and the id of the segment whose output is the query's result. It takes a plan, never a segment of a plan under
construction; the cutter's output is complete or `lower` raises.

`lower` calls, in this order and no others:

1. the cutter (§2.3), which classifies nodes and emits segments and edges;
2. `derive_payload_narrow` over `inputs`, the one host-local rule on `main` (the others of
   [the optimized plan](optimized_plan.md) §5.3 join as they are built);
3. `record_segment_morsel_rows(host_profile, segment, schema)`, which records the morsel size in each segment;
4. admission (§2.4 and §4.2): each segment's sink triple must be a row of the sink capability table, or `lower`
   raises.

### 2.2 The target IR (D1)

**Recommended: the first slices lower to the IR that exists, `komira_physical_plan` version 14**, behind the `lower`
signature above, and the self-contained IR of [plan models](plan_models.md) §4.2 becomes its own later design and
slice.

What that IR holds, and where it is not what §4.2 asks for:

| Field of `SegmentDescPod` | State | What the lowering does with it |
|---|---|---|
| `source_kind`, `source_spec`, `ops`, `sink_kind`, `sink_key_dtype`, `sink_orientation` | plain data | filled by the cutter |
| `deps`, `edge_tags`, `partition_count`, `order_key_kind` | plain data | filled by the cutter |
| `morsel_rows`, `mem_estimate_bytes`, `card_estimate_rows` | plain data | morsel size from the host profile; the estimates from `inputs`, never from producer statistics |
| `sink_param_id`, `sink_state_id` | indices into a driver-owned table | indices into the `ParamTable` the `LoweredPlan` carries; `sink_state_id` is the segment's own id until two segments share a sink |
| `cancel_slot`, `error_slot` | indices into driver tables | not used: the driver owns one `PipelineExecution` per segment run (§3.4) and no segment names its cancel or error cell |
| `source_spec.batch_handle_id` (SOURCE_BATCH) | index into a driver-owned table of resident batches | an index into the same `ParamTable`, which owns the batches |
| `source_spec.parquet_*` (SOURCE_PARQUET) | carries part of the source; `parquet_spec_is_total` says whether it carries all | lowering sets it true only for a scan whose every field the Parquet arm represents, and refuses a scan that is not total (§2.4) |
| `MorselOp.filter_predicate`, `project_exprs` | plan expressions inside the IR | copied from the plan; the purity gate (`assert_physical_plan_carries_no_logical_plan`) runs on the result |

The `ParamTable` is a plain owned value: sink parameters (`AggSinkData`, `SortSinkData` and the others), resident
batches and the build side of a probe, all stored by index in cut order. It lives in the `LoweredPlan`, is built by
`lower` and read by the driver, and is not a global or a driver-owned side channel. That keeps the one property
[plan models](plan_models.md) D7 wants from the first commit, that nothing a segment needs is out of band, true for
everything but the in-memory batches, and it keeps the index space deterministic: indices are dense and follow the cut
order, so equal inputs give equal indices.

**What must change for a fully self-contained IR** ([plan models](plan_models.md) §4.2, D7), as its own slice after the
benchmark path runs:

1. The Parquet arm carries the complete source description (pinned files with sizes and etags, projection, pushed
   filter, hive predicate, row window, file-system descriptor), so `parquet_spec_is_total` is removed rather than
   checked.
2. `sink_param_id` and the `ParamTable` give way to sink parameters inline in the segment, and resident batches give
   way to a content-addressed blob reference verified by digest.
3. `cancel_slot` and `error_slot` are removed.
4. Operator payloads that are whole logical subtrees (a probe's build side) become a reference to the producing
   pipeline.
5. The deterministic render of a segment becomes a wire form, and the version door is replaced by the build-digest
   check of [plan models](plan_models.md) D8.

None of the five changes the signature of `lower`, the cutter's classification or the driver's loop, which is why D1
recommends not waiting for them.

**Alternative: build the self-contained IR first.** No query runs until it exists. It is the right end state, and the
wrong first step: the five changes above are independent of the cut and of the driver, and each is testable by the
corpus render check of [plan models](plan_models.md) §7 only once there is a lowering to render.

### 2.3 Segment cutting: where pipelines break

The cutter walks the optimized plan once. It has no knowledge of query shapes; a chain, a bushy tree and a sort over a
join are cut by the same classification of each node into one of three roles:

| Role | Logical nodes | Effect |
|---|---|---|
| **Source** (a leaf; starts a pipeline) | `PLAN_SCAN` (Parquet, then in-memory) | `SOURCE_PARQUET` or `SOURCE_BATCH` |
| **Streaming operator** (fused into the pipeline below it) | `PLAN_FILTER`, `PLAN_PROJECT`, `PLAN_LIMIT`, and a join's probe side | `OP_FILTER`, `OP_PROJECT`, `OP_LIMIT`, `OP_JOIN_PROBE` appended to `ops` |
| **Breaker** (ends a pipeline; its output is the next pipeline's source) | `PLAN_AGGREGATE`, `PLAN_SORT`, `PLAN_TOPN`, `PLAN_DISTINCT`, `PLAN_PARTITION_BY`, `PLAN_PARTITION_TOPN`, a join's build side, the root | `SINK_AGG`, `SINK_SORT`, `SINK_TOPN`, a distinct sink, `SINK_PARTITION_BY`, `SINK_PARTITION_TOPN`, `SINK_HASH_BUILD`, `SINK_COLLECT` (the root) |

A breaker ends the pipeline below it and starts one whose source is `SOURCE_SINK_OUTPUT` over the breaker's segment.
A join is two edges: the build side is a segment ending in `SINK_HASH_BUILD`, and the probe side's pipeline gains an
`OP_JOIN_PROBE` whose `probe_build_seg` names it. The root of the plan is a `SINK_COLLECT` unless its top node is
itself a breaker whose output is the result.

**Edge kinds** (`edge_tags`, parallel to `deps`; the five kinds are a closed set so the driver reads a tag to pick a
policy and never instantiates one code path per edge):

| Tag | Meaning | The driver's policy |
|---|---|---|
| `E1_MORSEL_STREAM` | fuse into the producer's operator chain | no separate segment run: the operator runs in the producer's pipeline |
| `E2_INGEST_STREAM` | the producer folds each morsel as it arrives | the consumer segment runs concurrently, consuming morsels as they are produced (first slices: treated as `E3`) |
| `E3_PUBLISH_WAIT` | the consumer needs the producer's whole state before its first output | the consumer's segment starts after the producer's `combine` and `finalize` |
| `E4_PARTITION_WISE` | the consumer needs one complete partition, not the whole producer | latent: lowered to `E3` until a slice builds it |
| `E5_INDEPENDENT` | no data dependency | scheduling only; the segments may run in either order |

The first slices emit `E1` and `E3`, which is every edge of TPC-H Q1 and Q6 and of the joins of the later steps.

**Combine order** (`order_key_kind`): the per-worker partial states of a breaker are reduced in a fixed order that does
not depend on completion order, so a float fold gives the same bits on every schedule. `ORDER_NONE` is for exact folds
(integer sums, counts, min, max), `ORDER_PARTITION_ID` reduces in partition id order and `ORDER_ROW_RANGE` in the order
of the source row ranges. The cutter sets `ORDER_ROW_RANGE` on a segment whose sink folds floats (a float `SUM` or
`AVG`), `ORDER_PARTITION_ID` on a partitioned sink, and `ORDER_NONE` otherwise. What this asks of the driver is in §3.3
and open point O1.

**What the cutter refuses.** An `ASOF` join, a union, a view reference, a shared-subplan reference (`PLAN_CSE_REF`) and
a cast to string in a pipeline's spine are not cut yet. The cutter raises a named refusal
(`LOWERING_UNCUTTABLE_NODE`, naming the node tag), and does not produce a segment that reads "some batch". A resident
batch standing in for a subtree discards the subtree's meaning and gives a well-formed plan that computes something
else; "not yet cut" must stay visible as a refusal. The same holds for a plan with an `EXCHANGE` node when there is one
host: the cutter elides the exchange ([the optimized plan](optimized_plan.md) §8.2); a plan with a `STEP` or
`MAP_BATCHES` (a UDF) is refused until the UDF slice exists.

### 2.4 What lowering may and may not do

| May | May not |
|---|---|
| Classify nodes and cut (§2.3) | Run an optimizer pass, call `komira_optimizer`, or import it |
| Apply the closed list of host-local rules of [the optimized plan](optimized_plan.md) §5.3 over the verified `inputs` | Read a statistic a producer recorded in the plan |
| Choose morsel rows, per-segment memory shares and spill tiers from the host profile | Reorder joins, change a build side, push a filter or change a stream form |
| Fill `ParamTable` and the dense segment ids | Open a file, read a footer, read a clock or an environment variable |
| Refuse by name | Fall back to a different shape, an opaque source or a different sink than the plan's node asks for |
| Check admission against the sink capability table (§4.2) | Instantiate a sink or an operator (it names no operator package) |

**Refuse, never downgrade.** A segment whose sink triple has no row in the capability table makes `lower` raise
`LOWERING_SINK_UNSERVED`, naming the triple. The alternative, to turn that segment into a generic collect and
compute the sink another way, changes what runs without changing what the plan says; the plan's author sees a slow
or different answer and no refusal. The same applies to the Parquet arm that is not total (§2.2) and to a join the
probe operator cannot take: `LOWERING_JOIN_UNSERVED`, naming the join type and the strategy.

A host that has to re-optimize to lower is a bug in the optimizer, not a thing for lowering to do. If a plan reaches
`lower` in a form the cutter cannot cut, the fix is a rewrite in `komira_optimizer`, run before `lower`.

### 2.5 The package: `komira_lowering` (new, pure, no I/O)

| Module | Holds |
|---|---|
| `lower` | the entry of §2.1 |
| `lowered_plan` | `LoweredPlan`, `LoweringInputs`, `ParamTable` and the refusal tokens |
| `cut_walk` | the three-role walk of §2.3 |
| `cut_edges` | edge classification and `order_key_kind` |
| `cut_ops` | the operator chain of a spine: filter, project, limit, probe |
| `sink_capability` | the table of sink triples a host serves (§4.2): data, no operator |
| `render` | the deterministic text render of a `LoweredPlan` the corpus compares |

Each file stays under 1000 lines. **Dependencies:** `komira_plan_ir`, `komira_plan_expr`, `komira_physical_plan`,
`komira_lowering_rules`, `komira_engine_runtime` (for the host profile and morsel sizing) and the foundation packages.
It names no operator package, no file-system package and no async package, so that the claim "pure" is a property of
the dependency list that review can read and the build can enforce through the package's `deps`.

Why a new package and not a module of an existing one:

- `komira_physical_plan` is the IR and its two gates; its README forbids the optimizer to import it, and the cutter
  imports both the logical plan and the IR. Putting the producer in the IR's package makes the IR depend on the
  logical plan's walkers.
- `komira_lowering_rules` holds rules that are pure functions of one plan and the verified facts; the cutter is the
  caller of those rules, not one of them.
- `komira_engine_runtime` states "no algorithm logic".

## 3. Pipeline execution

### 3.1 The package: `komira_pipeline_exec` (new)

The driver that runs a `LoweredPlan`. **Dependencies:** `komira_physical_plan`, `komira_lowering` (for the capability
table), `komira_morsel` (the traits and `PipelineExecution`), `komira_operator_api`, `komira_parquet_scan`,
`komira_scan_resolver`, `komira_batch_eval`, `komira_dispatch_project`, the operator packages the sinks wrap
(`komira_op_agg_hash` first), `komira_engine_runtime` and `komira_async_api`.

| Module | Holds |
|---|---|
| `run_plan` | the entry: segments in dependency order, results out |
| `run_segment` | one segment: build, run, combine, finalize, take |
| `source_variant`, `source_parquet`, `source_batch`, `source_sink_output` | a closed set of sources behind one runtime tag |
| `op_variant`, `op_filter`, `op_project`, `op_limit`, `op_join_probe` | a closed set of operators behind one runtime tag |
| `sink_variant`, `sink_rows` | the sink registry of §4.2 |
| `sinks/` | one module per sink (§4) |
| `segment_task` | the worker body handed to the dispatcher |

`komira_morsel` is not the place: its README says it "does not schedule work or run a query itself", and every
operator package imports it. `komira_engine_runtime` is not the place either: it holds primitives and no algorithms.

### 3.2 The loop

`run_plan(lowered, ctx)` runs the segments in dependency order. Segments joined by `E5` edges, and segments with no
path between them, may run concurrently; the first slices run them one at a time in dependency order, which is
correct for every plan and leaves the concurrent form to a later slice with its own tests. For each segment,
`run_segment`:

1. **Build.** Construct the source from `source_kind` and `source_spec` (§3.5), the operator chain from `ops`, and the
   sink from the segment's triple and its `ParamTable` entry (§4.2). Apply the source hooks the plan asks for
   (projection, pushed predicate, morsel rows) before the first pull, as the source trait requires.
2. **Size.** `sink.resize_worker_state(num_workers)`, once, before any `consume`.
3. **Run.** Hand the dispatcher a worker body through `ParallelDispatch.run_with_state` (the fork-join surface of
   `komira_async_api`, never the standard library's `parallelize`). Each worker loops:
   - claim a morsel with `source.next_morsel(worker_id)`, which returns `None` at the end of input and never twice
     after it; the claim is the source's own atomic cursor, so there is no driver-side queue;
   - check the cancel flag, which is read at every morsel boundary;
   - run the operator chain on the morsel (`execute`), which may shrink or replace it, and stops the morsel when an
     operator reports it finished (a limit reached);
   - `sink.consume(worker_id, morsel)`.
4. **Combine.** After every worker has joined, `sink.combine(pipeline)` runs once, on one thread, merging the
   per-worker states in the segment's `order_key_kind` order (§2.3, §3.3).
5. **Finalize and take.** `sink.finalize()`, then `sink.take_output()` moves the result out as a `RecordBatch`. A
   segment whose sink is a breaker publishes that batch as the `SOURCE_SINK_OUTPUT` of its dependents (or, for a hash
   build, the build table itself).

The number of workers is the context's worker count, capped by the policy `komira_engine_runtime` already has
(`capped_worker_count`) so a small input does not fork more workers than it has morsels. The worker body holds no
state of its own beyond a worker id; per-worker state belongs to the sink and the operators, in slabs the driver owns
(§4.5).

### 3.3 Edges, combine order and determinism

Edge kinds select policy as the table of §2.3 says. The combine order is a contract between three parties:

- **The cutter** sets `order_key_kind` from the sink (§2.3).
- **The driver** gives every morsel an id that is a function of its position in the source (file index, row group,
  row offset within the group), not of the worker that claimed it or of when. `komira_morsel`'s `Morsel` already
  carries a morsel id and a partition id.
- **The sink** folds into state keyed by what the order names. For `ORDER_NONE` the state is per worker and the merge is
  in worker id order; every fold in this class is exact, so the order cannot change a bit. For `ORDER_ROW_RANGE` the
  state is per **grain**, a fixed group of consecutive morsel ids that does not depend on the worker count (open point
  O1), and the merge is in grain order.

The reason is that a per-worker state under dynamic claiming holds an arbitrary subset of morsels, so a float sum
merged in worker order is not reproducible. A fold keyed by source position is reproducible for every worker count,
and a test says so (§8): the same plan on one, two and seven workers gives bit-identical float aggregates.

### 3.4 Cancel, errors and failure modes

The driver owns one `PipelineExecution` per segment run: a cancel flag read at morsel boundaries, a panic flag, and a
first-error slot written once by compare-and-swap, so the first error wins and the rest are dropped. A worker that
raises records its error and sets the cancel flag; the other workers stop at their next morsel boundary; after the
join the driver raises the recorded error. The segments that have not started do not start. Every sink's state is
dropped by ownership, not by a cleanup the failing path might skip.

| Failure | What happens |
|---|---|
| A worker raises (a decode error, an overflow, a refused expression) | first error wins; workers stop at the next morsel; the query fails with that error; no partial result |
| A file disappears or its footer changed since bind | the source refuses at open when the footer's identity differs from the one the plan was bound with (§6.2), naming the file |
| The memory budget is denied | a breaker that cannot grow its reservation spills if its sink supports it (spill arbitration is in `komira_engine_runtime`); a sink that does not fails the query with a named error, never an allocation failure |
| The process crashes | the run is lost; nothing was persisted; the caller reruns the query. Single node, no recovery state, by scope |
| Cancellation by the caller | the same flag; the query returns a cancelled error and every sink drops its state |
| Connectivity to remote storage is lost mid-scan | the file-system layer's error surfaces through the first-error slot; the query fails whole. Retrying a read is the file-system layer's, not the driver's, and a morsel is never replayed by the driver |

A query is never answered from a part of its input.

### 3.5 Runtime dispatch without function pointers

The source, operator and sink traits of `komira_morsel` are monomorphized at compile time. A SQL plan has N operators
and a sink chosen at run time, so the driver cannot name the concrete types in a type. It uses **closed variants**: a
struct per role (`SourceVariant`, `OpVariant`, `SinkVariant`) that holds exactly one of a fixed, compile-time list of
concrete types and a `UInt8` tag, and implements the trait by testing the tag and calling the member. The cost is one
tag test per morsel per role, which is the same order as the virtual call it replaces and well below the cost of the
morsel's work. There is no function-pointer table, no erased box, no `UnsafePointer` in a signature and no
`MutExternalOrigin`. How a variant holds its member (the standard library's `Variant`, or one `Optional` per member
with the tag as the discriminator) is an implementation choice for the Mojo review; either keeps the pointer rules.

The Parquet source is generic over its file system and discovery (`ParquetSource[FS, DISC, ...]`). The runtime plan
selects among a closed list of instantiations by the scan's file-system kind (the local file system first; an object
store when the cloud slice exists), each in its own module so no module names every instantiation.

## 4. Sinks

### 4.1 Why the typed operator tables cannot serve a runtime plan

The aggregation stage operators in the open operator pull requests (for example `HashAggTable[KB: KeyTuple,
*Aggs: AggColumn]`, komira#1495) are typed at compile time over the key and over each aggregate. That is the right
shape for a program written against the typed SDK, where the schema is a compile-time value. A SQL plan carries its
group keys, their types and its aggregates as **data**: `GROUP BY l_returnflag, l_linestatus` with `SUM`, `AVG` and
`COUNT` is known only after the binder has run. To use a typed table the engine would have to instantiate it for every
combination of key types and aggregate lists the SQL can express, which is unbounded; a ladder of the most likely
combinations compiles slowly and silently misses the rest. The same holds for the typed join and sort stage tables.

The kernels under them are not typed that way. `komira_op_agg_hash` holds `FlatHashAggregator`, whose layout is a
runtime value (`AggLayout` over a list of `AggSpec`, each an op tag, a source column and a state width), and
`AggCommitPlan`, which folds a batch's value columns into the slots of any of its tables. Those are what a runtime plan
drives. What `main` lacks is the sink between a morsel and the table: it evaluates the group and argument expressions,
encodes the keys, commits, and merges per-worker tables at the end.

### 4.2 The registry (D3)

**Recommended: a closed registry of untyped sinks, selected by the triple the IR already carries:**
`(sink_kind, sink_key_dtype, sink_orientation)`, with no erased box and no function pointer.

- **The capability table** (`komira_lowering.sink_capability`) is data: the list of triples a host serves, such as
  `(SINK_AGG, KEY_DTYPE_NONE, COLUMNAR)`, `(SINK_AGG, KEY_DTYPE_I64, COLUMNAR)`, `(SINK_AGG, KEY_DTYPE_STRING,
  DICT_ENCODED)` and `(SINK_COLLECT, KEY_DTYPE_NONE, COLUMNAR)`. Lowering reads it for admission (§2.4). It names no
  sink type, so lowering stays pure.
- **The constructor ladder** (`komira_pipeline_exec.sink_rows`) maps a triple to a constructor with an `if` ladder on
  the three tags, each arm in its own module, returning a `SinkVariant` (§3.5). One translation unit never names every
  sink: the ladder calls one small constructor function per row, and each row's module is imported by the ladder only.
  The compile-time axis that remains is the one the IR calls "the one comptime axis", the key block's width, and it is
  paid inside a kernel, not by the shape of the query.
- **One list.** A test walks the capability table and constructs every row, and walks the constructor ladder and
  checks every arm is in the table. A row without a constructor, or a constructor without a row, fails it: that is
  the guard that the table lowering admits against is the table the driver can run.

**Alternatives.** (a) Port the earlier engine's erased state box and thunk table: the box is an `OwnedPointer` home
plus a destroy function, and the function-pointer aliases need `MutExternalOrigin`, which the pointer rules allow only
inside a module's FFI internals; that needs a rule exception. (b) Enumerate the typed `HashAggTable` combinations:
unbounded, as §4.1 says.

### 4.3 The aggregation sinks

All aggregation sinks wrap `komira_op_agg_hash`; they differ in how keys reach it.

**The shared parts.** From `AggSinkData` (group-by expressions, aggregate expressions, output schema, the estimated
group count) the sink builds an `AggLayout` and a list of `AggSpec`. Per morsel it evaluates the group-by and
aggregate-argument expressions with `komira_batch_eval` (`SUM(l_extendedprice * l_discount)` evaluates the product as a
column first), then commits the argument columns into the table through `AggCommitPlan`. The output batch has exactly
the declared schema; the typing of `MIN`, `MAX`, `FIRST` and `LAST` outputs is `komira_dispatch_agg_exec`'s existing
conform (`agg_pick_output_conform`). `AVG` keeps a sum and a count and divides at the end; a `SUM` over an empty
input is NULL and a `COUNT` is zero, with one output row for the ungrouped sink and none for the grouped.

| Row | Key block | State | Combine |
|---|---|---|---|
| `(SINK_AGG, NONE, COLUMNAR)` | none | one accumulator array per worker | merge in the segment's order |
| `(SINK_AGG, I64, COLUMNAR)`, `I32`, `F32`, `F64` | the key column as `Int64` cells (an `I32` widened, a float by its bit pattern after canonicalizing `-0.0` and NaN) | per-worker `FlatHashAggregator`; the `PerfectHashAggregator` when the key's domain is small and dense (at most 65,536 keys, from `inputs`) | merge the per-worker tables key by key in order |
| `(SINK_AGG, STRING, DICT_ENCODED)` | dictionary codes of the key column, mapped to an interned id | as above, over interned ids | remap ids by string, then merge |
| the same with a large estimated group count | as the row above | `PartitionedFlatHashAggregator`, one table per radix partition, with `FlatHashPartitionFlush` | partition by partition, in partition id order |

**Dictionary string keys.** A Parquet dictionary is per row group, so a code is meaningful only inside one chunk.
The `DICT_ENCODED` sink keeps, per worker, a table from `(dictionary identity, code)` to an interned id and a
sink-owned string table that holds each distinct string once; the `Int64` key the table sees is the interned id.
Decoding happens once per distinct string per dictionary, not once per row, and the output column is built from the
string table. A multi-column key (two dictionary strings, as TPC-H Q1 has) packs the interned ids into one composite
key through the table's composite key mode. This is the part of the design with the most uncertainty, and slice 6
begins with a spike on the farm (§7) to measure the interning cost before the sink is written around it.

**Why wrap, and not port the earlier untyped sinks.** The earlier engine's untyped aggregation family is route ladders
around the same kernels, with most of its size in routes particular to benchmark shapes. The kernels on `main` are the runtime-spec layer; what is missing is a thin sink over them. D4 below sets the
size at which the sink gets its own package.

### 4.4 The other sinks

| Sink | Used by | Built from | Lane |
|---|---|---|---|
| `SINK_COLLECT` | every plan's root; the passthrough | resident batches, concatenated by `komira_engine_runtime`'s parallel concat | slice 2 |
| `SINK_SORT`, `SINK_TOPN` | `ORDER BY`, `ORDER BY ... LIMIT` | `komira_op_sort` kernels (`sort_batch_by_keys`, the top-N indices) and the sinks of komira#1384; parallel sort komira#1420 and komira#1421; external sort komira#1436 | step 1 of §7 |
| distinct sinks | `SELECT DISTINCT`, `COUNT(DISTINCT x)` | `komira_op_agg_distinct` and komira#1385, #1390, #1401, then #1455, #1467, #1474 for string keys | step 2 |
| `SINK_HASH_BUILD` and `OP_JOIN_PROBE` | joins | `komira_op_join_build` with komira#1396 and #1397; probes komira#1427 to #1431, #1459, #1465; semi and anti marking komira#1485; fused kernels komira#1413 | step 3 |
| `SINK_PARTITION_BY`, `SINK_PARTITION_TOPN` | window functions | komira#1469 to #1472 | step 4 |

Each of these pull requests is open and none is on `main`; some are typed stage operators and some are runtime-spec
kernels, and which a sink wraps is read from the pull request when its slice starts. A sink whose kernels are not
merged has no row in the capability table, and a plan that needs it is refused at lowering (§2.4), not run slowly.

### 4.5 Ownership and the pointer rules

- A sink owns its per-worker states in a slab the driver or the sink creates before the workers start, indexed by worker
  id; `consume` takes `self` and writes only the caller's slot, and anything shared is atomic. This is the shape the
  traits of `komira_morsel` document.
- No partial move through a pointer: a state is taken out with `Optional.take()`, `OwnedPointer.take()`, `swap` or
  `List.pop()`, and the slab is emptied explicitly after `combine`.
- No public function of either package takes or returns an `UnsafePointer`. A concrete-origin pointer inside a kernel
  body carries a `# SAFETY:` comment. FFI stays in the module that owns the foreign resource.
- Nothing in the packages uses `MutAnyOrigin`, `ImmutAnyOrigin` or `MutExternalOrigin`.
- `MemoryReservation` is a plain tally (`mut self`), not an atomic. A breaker grows it only from points it serializes,
  and the driver gives a breaker its own reservation sized from a share of the host budget; per-worker growth takes a
  per-worker share. Whether a shared atomic reservation is needed is open point O3.

## 5. The engine context

### 5.1 Where, and its shape

`EngineContext` lives in `komira_sdk_exec`, as [the architecture](../architecture.md) and that package's README say.
It is a **small state struct plus free functions in separate modules**. Mojo has no partial structs, and a struct whose
methods all live in one file passes the 1000-line limit (Mojo also hangs on very large files). A context that grows one
method per feature is that file, and most of its methods would serve paths a SELECT over Parquet never takes. Each new feature (views, writes, EXPLAIN
ANALYZE, cloud scans) arrives as its own module of functions over the same struct.

| Module | Holds |
|---|---|
| `engine_options` | `EngineOptions` (§5.2) |
| `engine_context` | the struct, its constructor and accessors |
| `engine_catalog` | register a table, a Parquet path, an in-memory batch; resolve a name |
| `engine_footers` | `ParquetFooters` and the footer cache (§6.2) |
| `engine_optimize` | the call into `optimizer_driver.optimize` and the plan gates |
| `engine_lower` | `LoweringInputs` from the footers; the call into `lower` |
| `engine_execute` | `run_plan` over the context |
| `engine_sql` | `run_sql` (§6) |

The context owns:

| Field | What | From |
|---|---|---|
| host profile | the engine build, workers, memory budget, spill tiers | `komira_engine_runtime.detect_host_profile`, overridden by `EngineOptions` |
| worker pool | the dispatcher the driver forks onto | `komira_engine_runtime.engine_runtime_build` |
| memory | the root reservation, sized from the host profile | `MemoryReservation.for_host` |
| catalog | table names to schemas and scans | `komira_sql.SqlCatalog` |
| source registry | scan kinds to resolvers | `komira_scan_resolver.ScanSourceResolvers` |
| footer cache | parsed footers, capped, with eviction | `komira_sdk.parquet_footer` |
| plan cache | the two-layer compile cache | `komira_sdk_exec.plan_compile_cache` (LRU, capped) |
| options | the flags struct (§5.2) | the caller |

A context holds no process-global state. Every cache has a cap and an eviction rule, so a long-lived context does not
grow without bound, and one context's caches are never visible to another.

### 5.2 Configuration: one flags struct

**`EngineOptions` is one struct of fields the caller fills from its flags.** No package of this design reads an
environment variable: an absent environment variable and an empty one are the same bytes, and a flag can be required
and parsed at startup. A field whose absence differs from a value is an `Optional`.

| Field | Meaning |
|---|---|
| `worker_count: Optional[Int]` | workers; absent means the host profile's count |
| `memory_budget_bytes: Optional[Int]` | the memory cap; absent means the host profile's default |
| `spill_enabled`, `spill_directory: Optional[String]` | whether and where a breaker may spill (spill tiers go through the host profile) |
| `morsel_rows: Optional[Int]` | override of the morsel size policy, for tests |
| `plan_validation: Bool` | arms the plan validation gate (default off, as `plan_validation_enabled(armed)` takes it) |
| `dense_f64`, `dense_par: Bool` | the two switches of `komira_dispatch_project`, both on by default |

The rule that keeps the options honest: **an option that changes the lowered plan is an input of `lower`.** Worker
count, memory budget, spill tiers and morsel size reach lowering through the host profile, so a plan's render shows
them and two runs under different options cannot be mistaken for the same plan. An option that changes only how a plan
runs (the two project switches) stays in the context. A switch added to a kernel as a hidden knob is refused in
review.

## 6. The SQL door

### 6.1 `run_sql`

```mojo
def run_sql(text: String, mut ctx: EngineContext) raises -> List[RecordBatch]
```

The catalog is the context's `SqlCatalog`; a caller registers tables on the context (`register_parquet(name, path)`)
and passes the context, which is the one place a name, a footer and a worker pool meet. It composes, in order:

1. `tokenize` and `parse_sql`.
2. `bind_statement(stmt, ctx.catalog, ctx.footers)`, the binder of komira#1216. Binding opens no file itself; it asks
   the footers object.
3. `take_plan()`, then `optimizer_driver.optimize(plan, config, deps)`, where the config comes from the context. The
   scalar-subquery loop (the optimizer's `ScalarDepTable` hand-off, §7 step 5) is not in the first slices; a plan whose
   optimization leaves an unresolved dependency is refused with the optimizer's own named token.
4. `lower(plan, ctx.host_profile, inputs)`, with `inputs` built from the same footer cache the binder read (§6.2).
5. `run_plan(lowered, ctx)`.

A statement that is not a query (`COPY`, `CREATE TABLE AS`) is refused with a named error until a writes slice exists;
the binder reports the statement kind and the door does not guess. Each step's refusal reaches the caller unchanged.
The door does not retry, does not catch and rerun on another route, and does not keep a second path for the plans the
first rejects.

### 6.2 `read_parquet` and the footer reader

`read_parquet('path')` binds off the file's own footer, as `sql_tvf_bind` documents. The binder takes that footer
through the `SqlParquetFooters` trait, which a caller implements (`footer_schema(path)`, `column_null_count(path,
column)`). The engine supplies one, `ParquetFooters`, in `komira_sdk_exec`:

- `footer_schema` reads the footer of a file, or the footers of a glob's files unioned by name, through
  `komira_sdk.parquet_footer` (`read_parquet_footer_with_cache`), so the cache of §5.1 serves it;
- `column_null_count` sums a column's null counts over the row groups, and returns `None` when any row group records
  none, as the trait asks.

**One cache, two readers.** Lowering's `inputs` (the statistics for payload narrowing and the key domains for the
perfect-hash row) come from the same cache the binder used, so the plan the binder saw and the plan the host lowers
read one version of each footer. Each cached footer is stored with the file's identity (size and modification
identity where the store gives one); the source checks that identity at open and refuses a file that changed between
bind and execution, naming it (§3.4). The alternative, to read the footer separately at lowering, can bind against one
version of a file and run against another.

A table registered by name (`add_parquet(name, path, schema)`) takes its schema from the same reader at registration.

## 7. The MVP and the order of work

### 7.1 The MVP

TPC-H Q1 and Q6 over a Parquet file: one segment, `SCAN(parquet) -> FILTER -> [PROJECT] -> AGGREGATE`, one breaker.

- **Q6** is an ungrouped `SUM(l_extendedprice * l_discount)` under five conjuncts: the `(SINK_AGG, NONE, COLUMNAR)`
  sink.
- **Q1** groups by two dictionary strings and computes four `SUM`, three `AVG` and a `COUNT(*)` under one filter: the
  `(SINK_AGG, STRING, DICT_ENCODED)` sink, with the filter pushed into the scan and the pushed predicate decoded
  conjunct by conjunct (`komira_parquet_scan.staged_filter`).

The same slice also serves `GROUP BY` an integer key, which is the row the sink registry needs to prove its selection
across key dtypes.

### 7.2 The slices, in order

Each slice is one pull request of at most about 3,500 lines with its tests, and lands on `main` with the farm's
`local: 0` build. Sizes are estimates.

| Slice | Content | Needs |
|---|---|---|
| 1 | `komira_lowering`: the cutter, edges, `LoweredPlan`, `ParamTable`, the render, admission, refusals. No execution. | this design |
| 2 | `komira_pipeline_exec` core: `run_plan`, `run_segment`, the variants, `SOURCE_PARQUET`, `SOURCE_BATCH`, filter, project, limit, `SINK_COLLECT`; the first segment-level test (Parquet file in, batch out) | slice 1; `komira_morsel`, `komira_parquet_scan` on `main` |
| 3 | The ungrouped aggregation sink over `komira_op_agg_state` kernels; NULL, overflow and empty-input rules | slice 2 |
| 4 | The grouped aggregation sink, fixed-width keys, over `FlatHashAggregator` and `AggCommitPlan`; per-worker tables and the grain-ordered combine | slice 3 |
| 5 | The spike on the farm (a Buck target) that measures the dictionary interning against the code-decode route | slice 4 |
| 6 | The `DICT_ENCODED` grouped sink; output typing; group-count estimate to sizing | slices 4 and 5 |
| 7 | `EngineContext`, `EngineOptions`, `run_plan` over the context | slices 1, 2, 6 |
| 8 | `run_sql`, `ParquetFooters`, the end-to-end tests for Q1 and Q6; the footer-answered `COUNT(*)` and `MIN`/`MAX` | slice 7 and the binder, komira#1216 |

The binder's own slices are another lane's. This design needs `bind_statement` to produce a plan for Q1 and Q6; it
does not need the binder's window, correlated-subquery or union arms.

### 7.3 After the MVP

Each step adds a sink, an edge or an operator, and none changes the cutter's three roles or the driver's loop.

| Step | Adds | Tied to |
|---|---|---|
| 1. Sort, top-N, limit | `SINK_SORT`, `SINK_TOPN` | komira#1384; komira#1420, #1421, #1436 |
| 2. `COUNT(DISTINCT)`, `SELECT DISTINCT` | distinct sinks; string-key route | komira#1385, #1390, #1401; #1455, #1467, #1474 |
| 3. Joins | the build segment, `OP_JOIN_PROBE`, `E3` edges, outer, semi and anti; the build-side and dynamic-filter handling | komira#1396, #1397, #1413, #1427 to #1431, #1459, #1465, #1485; the optimizer records the build side, and which pairs the lowering must accept follows komira#1426 |
| 4. Window and partition top-N | `SINK_PARTITION_BY`, `SINK_PARTITION_TOPN` | komira#1469 to #1472 |
| 5. Scalar subqueries | the optimizer's dependency loop in `engine_optimize`, run before lowering | `komira_optimizer` |
| 6. Spill | the arbitrator over each breaker; a spillable aggregation | komira#1484; the arbitrator in `komira_engine_runtime` |
| 7. Writes, ASOF | COPY and CREATE TABLE AS; the ASOF cut | komira#1487 |

Some pull requests of the list are stacked on others; their order is theirs. A step lists only what it needs.

## 8. Testing

Every test of the packages is welded into its library's `test_srcs`, so the library does not exist unless they pass.
**No test asserts timing**: none compares an elapsed time, a deadline or a rate, and none sleeps to wait for a
condition. A test that needs a worker to be cancelled uses a source that cancels after N morsels, or a progress event.

| Layer | What it proves | A defect it catches |
|---|---|---|
| Cutter tables | each logical shape (a chain, a filter under an aggregate, a join, a sort over a join, a plan with a refused node) gives the expected segments, edges, tags and order keys | a join cut as one segment; a breaker fused into its producer; an edge with the wrong tag |
| Render determinism | the same plan, host profile and inputs render byte-equal; changing the worker count changes the render only where the profile is named | a lowering that reads a clock, a global or the iteration order of a map |
| Refusals | every refusal token is raised by a plan that should raise it, and by no other | a refusal that falls back; a token spelled twice |
| Admission | the capability table and the constructor ladder list the same rows (§4.2) | a row served at lowering and unconstructible at run time |
| Driver over fakes | source, operator and sink fakes: every morsel reaches the sink once; the end of input is seen once; the first error wins and stops the others; a limit stops the source | a lost or doubled morsel; a worker that keeps running after a failure |
| Determinism across workers | a float `SUM` and `AVG` over a fixed input are bit-identical on one, two and seven workers | a combine in completion order |
| Sinks against an oracle | each aggregation sink matches a naive row-at-a-time oracle on random inputs with NULLs, empty input, one group, many groups, repeated and colliding keys, dictionary keys across several row groups with different dictionaries | a dictionary code used as a group key across chunks |
| Footer identity | a file replaced between bind and run is refused at open | a result computed over a different version than the plan was bound to |
| End to end | `run_sql` over fixture Parquet files equals recorded expected answers (below) | a wrong filter, projection, key or aggregate anywhere on the path |

**Recorded answers.** The end-to-end fixtures are small Parquet files a test writes deterministically from a seed
through `komira_parquet_writer` (a lineitem-shaped table with dictionary strings, several row groups and NULLs), and a
checked-in file of expected results, one per query, produced once by a reference engine over the same file and
recorded with the SQL that produced it. The test never runs the reference engine. A mismatch of one value fails the
test and prints the row. Integer, string and count results compare exactly. Float aggregates compare with a relative
tolerance that the fixture file states with its reason (a sum of many doubles differs by rounding between any two
correct orders), and the same results are also compared bit-for-bit between runs of this engine (above). The suites'
full-size files are never committed and are not a test of this design; a larger-scale run is the benchmark's job.

**Coverage.** Each new package enters the coverage census at the 99% target; a branch of a refusal or a failure path
that no test reaches is a defect of the tests.

## 9. What exists and what must be built

| Piece | Exists | Must be built |
|---|---|---|
| Plan IR, expressions, wire | `komira_plan_ir`, `komira_plan_expr`, `komira_plan_wire` | none |
| Optimizer | `komira_optimizer` and its driver | the shared-subplan and scan-dedup passes, in the optimizer (D5) |
| Physical IR | `komira_physical_plan`, version 14, with driver-table indices | the self-contained IR (§2.2) |
| Host rules, morsel sizing | `derive_payload_narrow`; `record_segment_morsel_rows` | the other host-local rules |
| **Lowering** | none | `komira_lowering` (§2) |
| **Driver** | traits, `PipelineExecution`, segment execution context, `ParallelDispatch` | `komira_pipeline_exec` (§3) |
| **Sinks** | table kernels in `komira_op_agg_hash`, `komira_op_agg_state`, `komira_op_agg_slab`; sort, join and distinct kernels, some open | the untyped aggregation sinks and the registry (§4) |
| Parquet source | `komira_parquet_scan` | the source builder from `SourceSpecPod` (§3.5) |
| **Context** | twelve leaves in `komira_sdk_exec` | `EngineContext`, `EngineOptions` (§5) |
| **Door** | `komira_sql` parse; binder draft komira#1216 | `run_sql`, `ParquetFooters` (§6) |

## 10. Decisions

Recommendation first. D1 to D6 are the questions of this document; the open points below them are smaller and have a
recommendation each.

| # | Question | Recommended | Alternative | Why |
|---|---|---|---|---|
| D1 | Which IR do the first slices lower to | The existing `komira_physical_plan` version 14, with a `ParamTable` owned by the `LoweredPlan`, behind the final `lower(plan, host_profile, inputs)` signature; the self-contained IR is a later, separate design and slice (§2.2) | Build the self-contained IR first, so no query runs until it exists | The five changes the self-contained IR needs do not change the cut, the driver or the signature, so they can follow; the refusal gates (a non-total Parquet arm, an uncuttable node) keep the interim IR honest. This is a deviation in time from [plan models](plan_models.md) D7, not in direction. |
| D2 | Which packages | New `komira_lowering` (pure, no operator, no I/O) and new `komira_pipeline_exec`; the context stays in `komira_sdk_exec`; the `komira_compiler` row of [the architecture](../architecture.md) points here | One `komira_engine` for lowering, driver and context; or reuse the name `komira_compiler` | Purity is a property of a dependency list, and a package that also drives execution cannot show it; the name `komira_compiler` names nothing on `main`, and what it once covered is in `komira_batch_eval` and `komira_optimizer`. The costs: two packages to review, and `komira_sdk_exec` gains a heavier dependency closure, which splitting its leaves from the context can undo if it matters. |
| D3 | How a runtime plan selects a sink | A closed registry of untyped sinks selected by `(sink_kind, sink_key_dtype, sink_orientation)`, an `if` ladder with one module per row returning a closed variant, no erased box, no function pointer (§4.2) | Port the erased state box and thunk table, with a rule exception for `MutExternalOrigin`; or enumerate typed `HashAggTable` combinations | A closed variant keeps every pointer rule. The enumeration is unbounded for runtime key and aggregate types, and one module naming every sink is a very large translation unit, which the file-size rule exists to avoid. |
| D4 | Who owns the untyped aggregation sinks, and at what size | Slices 3 to 6 here, over `komira_op_agg_hash`, behind a farm spike for the dictionary route; if the sinks pass about 8,000 lines, they move to their own package; and tell the owners of the operator pull requests that those do not cover SQL aggregation | Port the earlier engine's untyped aggregation family (several times the size of the kernels it wraps) | The kernels are the runtime-spec layer already on `main`; what is missing is a thin driver, and measuring before writing the dictionary path is cheaper than rewriting it. |
| D5 | Where the shared-subplan elimination and the scan-dedup passes go | Into `komira_optimizer`, as plan rewrites, after the MVP; Q1 and Q6 do not need them | Into lowering as host rules | Lowering runs no optimizer pass (§2.4); a pass that rewrites the plan is the optimizer's by definition, and a host that applies it differently from the producer breaks "hosts never re-optimize". |
| D6 | How configuration reaches the engine | One `EngineOptions` struct filled by the caller from its flags; options that change the plan are inputs of `lower` through the host profile; no environment read in any package of this design (§5.2) | Keep some environment variables as mode markers | A flag is required and parsed at startup; the project rule admits environment variables only for platform-set markers, secret material and provider credentials, and a performance switch is none of these. |

**Open points** (each with a recommendation; none blocks slice 1):

| # | Question | Recommended | Alternative |
|---|---|---|---|
| O1 | The unit of a float fold's state under dynamic morsel claiming | Per grain of consecutive morsel ids, merged in grain order (§3.3); the grain is a fixed constant of the sink, not a function of the worker count | Per worker, merged in worker order, and state that float results vary with the worker count within the stated tolerance; cheaper in memory, but a test cannot then assert bit-equality across worker counts |
| O2 | How a closed variant holds its member | The standard library's `Variant` if it passes the Mojo review for moves and destruction; else one `Optional` per member with a tag | A hand-written tagged struct per role |
| O3 | Whether concurrent breakers need an atomic memory reservation | No for the first slices: each breaker has its own reservation under its own serialization (§4.5) | A shared atomic reservation in `komira_engine_runtime`, needed when two segments run at once and share one budget |

## 11. Prior art consulted

- DuckDB's pipeline construction classifies each operator as a source, a streaming operator or a sink, and cuts at
  sinks; the three roles of §2.3 follow it.
- The morsel-driven scheduling of Leis et al. (SIGMOD 2014): workers claim fixed-size chunks of a source and run a
  pipeline over each, with per-worker state merged at the end; §3.2 is that loop on komira's traits.
- Flink persists its compiled plan because a re-planned topology cannot restore state; the same reasoning as
  [plan models](plan_models.md) D1 is why lowering here is a deterministic function and never an optimizer.
