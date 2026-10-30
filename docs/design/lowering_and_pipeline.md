# Design: lowering a bound plan and running it, from SQL text to record batches

Status: design, not built. **EXISTS** names code on `main`; everything marked **PROPOSED** is new. The new names (all
absent from `main`): the packages `komira_lowering` and `komira_pipeline_exec`; the entry `lower`; `LoweringInputs`,
`LoweredPlan` and `ParamTable`; the sink capability table (`sink_capability`) and the sink variant (`PipelineSink`); the pure leaf package that
holds the host profile and morsel sizing (`komira_host_profile`, §2.5); the driver entry `run_plan`; the refining source trait `GrainSourceImpl` (§3.3); `EngineContext` and `EngineOptions` in `komira_sdk_exec`; the door `run_sql`; and the
`read_parquet` footer reader (`ParquetFooters`). Nothing was built or run to write this document. Citations of code
refer to `main`; citations of other designs name the doc and section.

It builds on [plan models](plan_models.md) (§4.2 and decision D7: the pipeline model, lowering as a pure function) and
on [the optimized plan](optimized_plan.md) (§5.3, the closed list of host-local rules; §8, the cut). It does not repeat
them. It does not describe streaming, which [plan models](plan_models.md) §4.3 covers over the same physical plan.

**Where the code and the docs disagree today.**
[Plan models](plan_models.md) §4.1 describes the physical IR as version 13 in `komira_plan_ir`; the code is version 14
in `komira_physical_plan`. That section is stale on this point and is corrected in the same change as this document's
slice 1. The same section declares `lower(segment, host_profile, resolved_inputs)`; §2.1 below says how this document's
entry relates to it. [The architecture](../architecture.md) names the lowering layer `komira_compiler`; no such
package exists, and the evaluators and rewrite passes that name once covered live in `komira_batch_eval` and
`komira_optimizer`. This document replaces that name with the two packages below.

Two claims of the traits are not what the code does today (§3.3): `Morsel` carries a morsel id and a partition id, but
every source on `main` assigns the id from an arrival counter (`fetch_add` on `morsel_counter` at eight sites in four files of
`komira_parquet_scan`, in `komira_morsel.vtable_source`, and in `komira_op_sources.batch_morsel_source`), so the id is claim order, not source position; and
`MorselSourceImpl.next_morsel` claims one morsel at a time, not a group. Both matter only for reproducible float sums,
which no MVP query needs (§7.1), so both are built with the first float sink (step 9 of §7.3), not before.

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
  ([the optimized plan](optimized_plan.md) §8.2). An exchange read is a source kind and an exchange write is a sink kind of the same IR, so a host that is
  handed a cut segment can lower and run it with the same cutter and driver (§2.1). With one host every exchange is
  elided, which is the case this document implements; the segment-in form is not built here.
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

`run_sql` composes the five steps of §6.1 (parse, bind, optimize, lower, run). `EngineContext` holds what they share (§5). Lowering is pure; running is the
only step that opens a file or starts a thread.

## 2. Lowering

### 2.1 The entry

```mojo
def lower(
    plan: LogicalPlan,
    host_profile: HostProfile,       # komira_host_profile.host_profile
    inputs: LoweringInputs,          # the resolved inputs of plan_models §4.2
) raises -> LoweredPlan
```

`host_profile` is the one `komira_engine_runtime` measures once per host process: the engine build, the worker thread
count, the memory budget and the spill tiers. `inputs` holds what the host-local rules read from data, already read:
one `Optional[TableStats]` per scan in scan pre-order (the footers' statistics that `derive_payload_narrow` takes), the
value of a folded scalar subquery when the plan has one, and the facts the sink choice needs from the files: per scan
column whether every row group of every pinned file is dictionary encoded, and for an integer key column the minimum
and maximum the footers record over all pinned row groups (absent when any row group records none) and the scan's
row-group count (§4.3). Lowering is pure, so it cannot look
at the file; the host reads these once, from the footer cache of §6.2. `lower` opens no file, reads no clock, reads no
environment variable and touches no global. Equal arguments give an equal `LoweredPlan`, byte for byte when rendered;
a test says so (§8).

A `LoweredPlan` is a value: the list of `SegmentDescPod` in dependency order, the `ParamTable` the segments index
(§2.2), and the id of the segment whose output is the query's result. **Relation to plan models §4.2.** That section declares
`lower(segment, host_profile, resolved_inputs)` over an optimized, admitted segment. The entry here takes a whole
`LogicalPlan` and is the degenerate single-segment case of it: the optimizer's admission step (the optimized-plan
header and its gates) is the caller's, and `run_sql` runs it in step 3 of §6.1 through `optimize`. A cut segment of a
distributed plan lowers through the same entry once exchange nodes are kept instead of elided; that form is not built
here. The cutter's output is complete or `lower` raises.

`lower` calls, in this order and no others:

1. the cutter (§2.3), which classifies nodes and emits segments and edges;
2. `derive_payload_narrow` over `inputs`, the one host-local rule on `main` (the others of
   [the optimized plan](optimized_plan.md) §5.3 join as they are built). Its output, one `PayloadNarrowSpec` per column,
   is stored in `ParquetSourceData.payload_narrow` of the scan's source spec. The field is advisory and one leaf honours
   it (the build-side join materializer), so a plan without a join, which is every plan of the MVP, gets an empty list;
   the rule is wired in the slice that adds joins;
3. `record_segment_morsel_rows(host_profile, segment, schema)`, which records the morsel size in each segment;
4. admission (§2.4 and §4.2): each segment's sink triple must be a row of the sink capability table, or `lower`
   raises.

### 2.2 The target IR (D1)

**Recommended: the first slices lower to the IR that exists, `komira_physical_plan` version 14**, behind the `lower`
signature above, and the self-contained IR of [plan models](plan_models.md) §4.2 becomes its own later design and
slice. This is the alternative that [plan models](plan_models.md) D7 rejected ("port as is and fix later", because side
tables in the IR block the wire form). It is recommended here only with a stated exit (below) and because the
`ParamTable` keeps every out-of-band index inside the `LoweredPlan`, where D7's property (nothing a segment needs lives
in a driver global) holds from the first commit.

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
   check of [plan models](plan_models.md) D8. `ParamTable` entries need a wire form of their own (`komira_pplan_wire`
   is the only pplan wire today and does not carry them), which is part of this item.
6. Per-pipeline memory budget and spill tier. `SegmentDescPod` has only `mem_estimate_bytes`, an initial-shape throttle
   hint, and the one budget field is `SortSinkData.memory_budget`; `AggSinkData` has none. [Plan models](plan_models.md)
   §4.2 asks for a per-pipeline budget and spill. Until this item, lowering records none: the render shows no memory
   decision, and a denied grow fails the query (§3.4).

**Exit condition.** No consumer of the interim IR exists outside `komira_pipeline_exec`, and nothing serializes a
`LoweredPlan`, until the self-contained IR lands; a wire form, a plan cache keyed on it, or a second consumer starts the
slice that replaces it.

None of the six changes the signature of `lower`, the cutter's classification or the driver's loop, which is why D1
recommends not waiting for them.

**Alternative: build the self-contained IR first.** No query runs until it exists. It is the right end state, and the
wrong first step: the six changes above are independent of the cut and of the driver, and each is testable by the
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

The first slices emit `E1` and `E3`. Q6 as one segment has no edge; the first `E3` of the MVP is the one between Q1's
aggregation and its sort (§7.1), and the joins of the later steps use `E3` too. Of the five kinds, `E1` and `E3` are
emitted; `E2` and `E4` are latent (a tag and a policy comment in the IR, lowered to `E3`), and `E5` is emitted when a
join has independent build sides. The driver raises on a tag it has no policy for, and a test says so (§8), so a cutter
that starts to emit `E4` cannot be silently serialized.

**Combine order** (`order_key_kind`): `ORDER_NONE` is for exact folds (integer sums, counts, min, max, `DECIMAL`
sums, §7.1) and for every segment of the MVP: the merge order cannot change a bit. `ORDER_ROW_RANGE` reduces grain
states in source row-range order and is set on a segment whose sink folds floats into grain state (a float `SUM` or
`AVG`, ungrouped or dense; step 9 of §7.3). `ORDER_PARTITION_ID` emits the partitions of a partitioned sink in
partition id order: it fixes the output order and says nothing about the float reduction inside a partition (§4.3). The
first slices set `ORDER_NONE` only. What `ORDER_ROW_RANGE` asks of the driver is in §3.3 and open point O1.

**What the cutter refuses.** An `ASOF` join (`SINK_ASOF_JOIN`), a union, a sort-merge join (`SINK_SMJ_BUILD`), the IR's `SOURCE_CONCAT` and
`SINK_JOIN_PROBE` (a second, sink-form probe the cutter does not emit; the probe is `OP_JOIN_PROBE`, §3.6), a view reference, a shared-subplan reference (`PLAN_CSE_REF`) and
a cast to string in a pipeline's spine are not cut yet: the IR has the tags, the cutter does not emit them, and "a union is refused" means the cutter does not
produce a `SOURCE_CONCAT` for it. The cutter raises a named refusal
(`LOWERING_UNCUTTABLE_NODE`, naming the node tag), and does not produce a segment that reads "some batch". A resident
batch standing in for a subtree discards the subtree's meaning and gives a well-formed plan that computes something
else; "not yet cut" must stay visible as a refusal. The same holds for a plan with an `EXCHANGE` node when there is one
host: the cutter elides the exchange ([the optimized plan](optimized_plan.md) §8.2) once the exchange slice exists;
slice 1b has no arm for `EXCHANGE` and refuses it by name, which is safe and is the only divergence from this
paragraph. A plan with a `STEP` or `MAP_BATCHES` (a UDF) is refused until the UDF slice exists. A limit above a sort is
refused too (`LOWERING_UNCUTTABLE_NODE`): no segment records an order before the order slice, so the rows such a limit
keeps are not defined. A float `SUM` or `AVG` is cut with `ORDER_NONE`, as §2.3 allows for the first slices, and is not
bit-reproducible across worker counts until `ORDER_ROW_RANGE` exists (step 9 of §7.3).

### 2.4 What lowering may and may not do

| May | May not |
|---|---|
| Classify nodes and cut (§2.3) | Run an optimizer pass, call `komira_optimizer`, or import it |
| Apply the closed list of host-local rules of [the optimized plan](optimized_plan.md) §5.3 over the verified `inputs` | Read a statistic a producer recorded in the plan |
| Choose morsel rows from the host profile (memory shares and spill tiers are not recorded until §2.2 item 6) | Reorder joins, change a build side, push a filter or change a stream form |
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
| `cut_walk` | the three-role walk of §2.3, with the edges, `order_key_kind` and the fused operator chain of a spine inline (slice 1b has no `E3` choice or probe to split out) |
| `sink_capability` | the table of sink triples a host serves (§4.2): data, no operator |
| `render` | the deterministic text render of a `LoweredPlan` the corpus compares |

Each file stays under 1000 lines. **Dependencies:** `komira_plan_ir`, `komira_plan_expr`, `komira_physical_plan`,
`komira_lowering_rules`, `komira_host_profile` (new, below) and the foundation packages. It imports no operator
package, no file-system or object-store package and no async runtime package. Since `deps` is the full transitive
closure, the list is also what the build admits, and it is longer than the imports: it holds `komira_host` (through
`komira_buffer`, which `komira_arrow` needs) and `komira_async_api` (through `komira_arrow_ipc`, which
`komira_scan_source` and so `komira_physical_plan` need). Neither is refused: the first is host probing code and the
second a trait surface, and `lower` imports neither. "Pure" is therefore a property of a dependency list that review can
read, plus the rule that `lower` calls no probe.

**`komira_host_profile` (new, D9).** `HostProfile` and the morsel sizing policy live in `komira_engine_runtime` today,
whose `deps` include `komira_fs`, `komira_objectstore`, `komira_async` and `komira_shuffle`; a dependency on it would
make the list above false. The modules do not move whole, because of what they import on `main`:
`host_profile.mojo` imports `hardware` and `hardware_detect` (it calls `detect_hardware_profile`);
`morsel_sizing_policy.mojo` imports `hardware`, `host_profile`, `l1_chunk_sizing`, `komira_arrow.schema` and
`komira_physical_plan`; `hardware.mojo` imports `komira_host.cpu_topology` for one function, `HardwareProfile.defaults()`,
which reads the process-wide core-count snapshot; and `hardware_detect.mojo` imports `komira_host` probes and
`komira_engine_runtime.l2_share`. Moving detection would bring those probes, `l2_share` and the topology modules into the
leaf. **The HostProfile value is split from detection instead.** The move list (slice 1a), with the new imports:

- **Moves to `komira_host_profile`:** `hardware.mojo` (the `HardwareProfile` value, its constants and derived methods,
  without `defaults()`; imports `komira_arrow.schema`), `l1_chunk_sizing.mojo` (no imports of its own),
  `host_profile.mojo` (`HostProfile`, `reference_host_profile`, the spill-tier helpers, without `detect_host_profile`) and
  `morsel_sizing_policy.mojo` (without `from_defaults`; imports `komira_physical_plan`). The four modules are about 1,700
  lines, and their four test files about 1,300, which move with them.
- **Stays in `komira_engine_runtime`:** `hardware_detect`, `hardware_topology`, `machine_topology`, `l2_share`, a
  new module `host_detect` holding `detect_host_profile`, and `default_hardware_profile()` (the body of the former
  `defaults()`, the one reader of the core-count snapshot), which is in `hardware_detect` and not in `host_detect`:
  `host_detect` imports `hardware_detect`, and the three former `HardwareProfile.defaults()` calls of `hardware_detect`
  call `default_hardware_profile()`, so a home in `host_detect` would be an import cycle.
  `MorselSizingPolicy.from_defaults` had one user, `test_inmem_source` (two calls), which uses
  `for_host(reference_host_profile(...))`. The tests that called `defaults()` or `detect_host_profile` (the document
  counted five calls in `test_hardware_profile`; there were eight there, and more in `test_host_profile`,
  `test_morsel_sizing_policy`, `test_hardware_profile_detect` and `test_hw_ecore_l2_morsel_sizing`) split off or stay in
  `komira_engine_runtime`: `test_host_detect` (the fallback profile, the probe and `detect_host_profile`),
  `test_run_context` and `test_fan_out_grain` are new files there, and the leaf's formula tests build their fallback-shaped
  profile from the `DEFAULT_*` constants.
- **The leaf's closure** is the closure of `komira_arrow` and `komira_physical_plan`, read from their `BUCK` `deps`: 20
  packages (`komira_arrow`, `komira_arrow_ipc`, `komira_async_api`, `komira_atomic_alias`, `komira_buffer`,
  `komira_collections`, `komira_compression`, `komira_counters`, `komira_dynamic_filter`, `komira_host`, `komira_libc`,
  `komira_lz4`, `komira_physical_plan`, `komira_plan_expr`, `komira_plan_ir`, `komira_plan_stats`,
  `komira_scalar_arithmetic`, `komira_scan_source`, `komira_simd`, `komira_zlib`). It adds nothing to the closure
  `komira_lowering` already has, imports `komira_host` nowhere itself, and holds none of `komira_fs`,
  `komira_objectstore`, `komira_async` or `komira_shuffle`. The leaf's `BUCK` file holds this with `closure_excludes`
  (exact import names, checked at analysis over the whole closure), and
  `tests//negative/closure_excludes` with `analysis_refusals_mojo` shows that each of the four is refused.
- **Callers:** 26 files name the old module paths (a `git grep` of the four module names under `src` at the base of
  this slice: 25 `.mojo` files and the `komira_engine_runtime` README, 15 inside
  `komira_engine_runtime`, 3 in `komira_parquet_scan`, 4 in `komira_op_typed_source_api`, 2 in `komira_dispatch_sources`,
  one each in `komira_morsel` and `komira_physical_plan`); slice 1a rewrites them in the same change, with no re-export
  module left behind.

Slice 1b holds the refused-deps check in `komira_lowering/BUCK` with `closure_excludes`, the exact-name closure check
that `komira_host_profile` already uses (`komira_async_api`, which the closure needs, is not refused because the
names are compared whole): `komira_fs`, `komira_objectstore`, `komira_async`, `komira_shuffle`,
`komira_engine_runtime`, `komira_optimizer` and `komira_sql`. It replaces the shared Starlark function this
document proposed: the rule attribute already checks the whole closure, so one way does one thing, and
`komira_lowering_rules/BUCK` moves onto the same attribute (its prefix comprehension is removed). That the check can
fail is shown by `selftest_scenario` rows of `analysis_refusals_mojo`, one negative fixture per refused package
under `tests//negative/closure_excludes` (the four of slice 1a and `engine_runtime`, `optimizer` and `sql`), and the
real package, which depends on `komira_async_api`, is the positive control (§8).

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
(`komira_op_agg_hash` first), `komira_host_profile`, `komira_engine_runtime` and `komira_async_api`.

| Module | Holds |
|---|---|
| `run_plan` | the entry: segments in dependency order, results out |
| `run_segment` | one segment: build, run, combine, finalize, take |
| `source_variant`, `source_parquet`, `source_batch`, `source_sink_output` | a closed set of sources behind one runtime tag (§3.5) |
| `op_variant`, `op_filter`, `op_project`, `op_limit`, `op_join_probe` | a closed set of operators behind one runtime tag |
| `pipeline_sink`, `sink_rows` | `PipelineSink` and the sink registry of §4.2 |
| `sinks/` | one module per sink (§4) |
| `segment_task` | the worker body handed to the dispatcher |

`komira_morsel` is not the place: its README says it "does not schedule work or run a query itself", and every
operator package imports it. `komira_engine_runtime` is not the place either: it holds primitives and no algorithms.

### 3.2 The loop

`run_plan(lowered, ctx)` runs the segments in dependency order. Segments joined by `E5` edges, and segments with no
path between them, may run concurrently. The first slices run one segment at a time, but the loop is written as a
scheduler over a ready set (a segment is ready when every `deps` entry has finished), not as a `for` over a list, so
the concurrent form changes the size of the ready set and not the loop; a join with two independent build sides (§3.6)
and a plan with a CTE are the first plans that need it. For each segment,
`run_segment`:

1. **Build.** Construct the source from `source_kind` and `source_spec` (§3.5), the operator chain from `ops`, and the
   sink from the segment's triple and its `ParamTable` entry (§4.2). Apply the source hooks the plan asks for
   (projection, pushed predicate, morsel rows) before the first pull, as the source trait requires.
2. **Size.** `sink.resize_worker_state(num_workers)`, once, before any `consume`.
3. **Run.** Hand the dispatcher a worker body through `ParallelDispatch.run_with_state` (the fork-join surface of
   `komira_async_api`, never the standard library's `parallelize`). Each worker loops:
   - claim work from the source with `source.next_morsel(worker_id)`, the trait's one claim and the source's own atomic
     cursor, so there is no driver-side queue; it returns `None` at the end of input and never twice after it. A segment
     whose `order_key_kind` is `ORDER_ROW_RANGE` (step 9 of §7.3; no MVP segment) claims a whole grain with
     `GrainSourceImpl.next_grain` instead (§3.3) and runs the chain over the grain's morsels in position order;
   - check the cancel flag, which is read at every morsel boundary;
   - for each morsel: run the operator chain (`execute`), which may shrink or replace the morsel, and stops it when an
     operator reports it finished (a limit reached); then `sink.consume(worker_id, morsel)`.
   - A filter followed by a projection does not materialize a batch between them. The mechanism is the one already on
     `main`: the batch's deferred selection mask (`RecordBatch.set_selection_mask`, `take_selection_mask`; the split
     path of `komira_morsel.morsel` slices it per sub-morsel). The filter sets the mask and the projection evaluates
     under it; no second selection representation is added to `Morsel`. A swap through `Morsel.replace_batch` drops an
     unapplied mask, so an operator that replaces the batch transfers the mask first, as `map_op` does. Of Q6's five
     conjuncts, the ones the scan's staged filter decodes (`komira_parquet_scan.staged_filter`) are pushed; the
     remainder run as an `OP_FILTER` over the mask.
4. **Combine.** After every worker has joined, `sink.combine(pipeline)` runs once, on one thread, merging the
   per-worker or per-grain states of the ungrouped and dense sinks in the segment's `order_key_kind` order (§2.3,
   §3.3). A partitioned sink (§4.3) does not merge serially: its `combine` only hands out partitions.
5. **Finalize and take.** `sink.finalize()` (for a partitioned sink, one `ParallelDispatch.run_with_state` task per
   partition, partitions emitted in partition id order, so the output order does not depend on the schedule), then `sink.take_output()` moves the result out as a `RecordBatch`. A
   segment whose sink is a breaker publishes that batch as the `SOURCE_SINK_OUTPUT` of its dependents (or, for a hash
   build, the build table itself).

The number of workers is the context's worker count. `capped_worker_count` in `komira_engine_runtime` is a pure
function whose own header says its opt-in gate lives at the call site and defaults to off; the gate is
`EngineOptions.cap_workers` (§5.2), default off, so a run uses every worker of the host profile. It is never capped
below the core count for a pipeline with few large units: a tail of idle workers is cut by the source's own
sub-row-group split (`parquet_source_subrg`), not by forking fewer workers. The worker body holds no
state of its own beyond a worker id; per-worker state belongs to the sink and the operators, in slabs the driver owns
(§4.5).

### 3.3 Edges, combine order and determinism

Edge kinds select policy as the table of §2.3 says. **The MVP needs none of the machinery below.** Q1 and Q6 are
`DECIMAL(15,2)` exact folds (§7.1): the merge order cannot change a bit, `order_key_kind` is `ORDER_NONE`, and the
morsel id plays no part. The rest of this section is built in step 9 of §7.3, with the first float sink, and until then
nothing in this document claims bit-identical floats. Reproducible float results are a contract between four parties,
and **two of the four are changes to code on `main`**, not something the driver can supply:

- **The source ids (change to `komira_parquet_scan`).** Every morsel's id is a function of its position in the source:
  `(unit position, sub-morsel index)`, packed to one ordered integer (unit position in the high bits, sub-morsel index in
  the low 20). The unit position is the claimed unit's ordinal in the flattened (file, row group, chunk) sequence the
  footers give; the sub-morsel index counts the morsels cut from that unit. Today the id is a `fetch_add` on an arrival
  counter at eight sites in four files (`parquet_source` 1, `parquet_source_emit` 4, `parquet_source_grain` 1,
  `parquet_source_subrg` 2); the emit helpers mint several ids for one claim (`mid0`, `mid_k`). The change gives each
  emit helper the claimed unit's position and a local sub-index, mints nothing from a counter, and removes the counter.
  The type-erased `vtable_source` is deleted, not changed (slice 2c). `komira_op_sources.batch_morsel_source`
  (`SOURCE_BATCH`, an MVP source) also mints its id from an arrival counter (`morsel_counter.fetch_add` per claimed slot
  in `next_morsel`). Step 9a changes it too: its unit position is the slot index `c` it already claims (the partition id is
  already `c`), the sub-morsel index is 0 (one morsel per slot), and its counter is removed. Until then `SOURCE_BATCH`
  is not in a float class (§3.3). Step 9a has a test that two schedules over one file
  give the same id for the same morsel, and that ids are distinct and ordered.
- **The source claim (new capability, additive).** `MorselSourceImpl.next_morsel` claims one morsel. The unit of a float
  fold is a **grain**: a fixed run of consecutive morsel positions that does not depend on the worker count, so that one
  worker folds a grain's morsels in position order and two workers never fold into one grain. The claim is a new trait,
  **`GrainSourceImpl`, which refines `MorselSourceImpl`** with `next_grain(worker_id)`, implemented by the Parquet source
  and by `SourceVariant` (whose other members return one-morsel grains). It is not a method added to
  `MorselSourceImpl`: that would change all 13 structs that implement it today, in four packages (the sources of
  `komira_morsel/tests`, `komira_op_sources`, `komira_operator_api` and `komira_parquet_scan`), including the test
  sources in `komira_morsel/tests`. With the refining trait none of those is edited. The Parquet source maps a grain to
  one row group, or to the sub-row-group chunks `parquet_source_subrg` already produces for a large group. A source
  that cannot give grains refuses a plan that asks for bit-identity.
- **The cutter** sets `order_key_kind` from the sink (§2.3).
- **The sink** folds into state keyed by what the order names. For `ORDER_NONE` the state is per worker and the merge
  is in worker id order; every fold in this class is exact. For `ORDER_ROW_RANGE` the state is per grain and the merge
  is in grain order.

The reason is that a per-worker state under dynamic claiming holds an arbitrary subset of morsels, so a float sum
merged in worker order is not reproducible. **The guarantee is scoped, because grain state costs memory** (D7):
per-grain state is grains times groups, and the grain count grows with the input. Bit-identity across worker counts is
promised for the ungrouped sinks and for the dense grouped sinks of §4.3, whose state is bounded by facts the footers
hold (row groups x key domain x state width, under a byte cap the cutter holds). Every other grouped float sum uses the
partitioned sink of §4.3, whose results are not reproducible bit for bit (§4.3 says why); they hold within the
tolerance the fixture states and are disclosed as such on the benchmark board. Exact folds (integer, `DECIMAL`) are
bit-identical everywhere. Tests (§8): in the MVP, an exact fold on one, two and seven workers gives equal bits; from
step 9, a float `SUM` and `AVG` in the promised classes do.

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
| The memory budget is denied | the MVP has no spill: the sink's `try_grow` (§4.5) fails, the worker records a named error in the first-error slot, and the query fails; never an allocation failure. A later slice lets a sink whose capability row says `spillable` spill instead (step 6 of §7.3); the IR records no spill tier until §2.2 item 6. **The root reservation of the context (§5.1) is the only bound on memory in the MVP**: no per-segment, per-sink or per-operator budget exists (§2.2 item 6), and every sink draws from the root through the segment pool of §4.5 |
| The process crashes | the run is lost; nothing was persisted; the caller reruns the query. Single node, no recovery state, by scope |
| Cancellation by the caller | the same flag; the query returns a cancelled error and every sink drops its state |
| Connectivity to remote storage is lost mid-scan | the file-system layer's error surfaces through the first-error slot; the query fails whole. Retrying a read is the file-system layer's, not the driver's, and a morsel is never replayed by the driver |

A query is never answered from a part of its input.

### 3.5 Runtime dispatch without function pointers

The source, operator and sink traits of `komira_morsel` are monomorphized at compile time. `komira_morsel` also ships a
type-erased source, `vtable_source`, which has a `MutExternalOrigin` widening at a private field. (`scan_resolver_c_box`
is a different thing and stays: it is the one place an erased scan resolver crosses `komira.so`'s C ABI, for the scan
kinds consumers register through `register_scan_kind`, with its own test and its entries in the pointer-lint holds; the
engine's plans do not use it and slice 2c does not touch it.) **`SourceVariant` replaces it for the engine's plans and does not reuse it**: the erased source is the
pointer-rule exception the closed variant exists to avoid (D3), and a second source dispatch beside it would be a
second way to do one thing. Replacing it is a migration with an owner (a search of `src` finds no user of it outside
`komira_morsel` and its tests, so slice 2c deletes it with those tests in one change, right after slice 2b makes `SourceVariant` the only source dispatch
and rather than leaving two)
and not a parallel API. A SQL plan has N operators and a sink chosen at run time, so the driver cannot name the
concrete types in a type. It uses **closed variants**: a struct per role (`SourceVariant`, `OpVariant`, `PipelineSink`) that holds exactly one of a fixed, compile-time list of
concrete types and a `UInt8` tag, and implements the trait by testing the tag and calling the member. The cost is one
tag test per morsel per role, which is the same order as the virtual call it replaces and well below the cost of the
morsel's work. There is no function-pointer table, no erased box, no `UnsafePointer` in a signature and no
`MutExternalOrigin`. How a variant holds its member (the standard library's `Variant`, or one `Optional` per member
with the tag as the discriminator) is an implementation choice for the Mojo review; either keeps the pointer rules.

The Parquet source is generic over its file system and discovery (`ParquetSource[FS, DISC, ...]`). The runtime plan
selects among a closed list of instantiations by the scan's file-system kind (the local file system first; an object
store when the cloud slice exists), each in its own module so no module names every instantiation.

**The fused scan-aggregate path.** `komira_parquet_scan` has a fused path (`subrg_agg_executor`, `subrg_agg_fold`,
`parquet_codes_feed`) that folds dictionary codes inside the scan. The MVP **bypasses** it: Q1 and Q6 run through the
generic `SOURCE_PARQUET` -> filter -> sink spine, because that is the path every other plan needs and the board must
measure it. Whether the fused path is later driven from a sink row (a `(SINK_AGG, ...)` row whose source is the scan
itself) is a step after the first board numbers, decided from the measured gap to DuckDB, not before.

### 3.6 Join build, finalize and probe (design constraints, built in step 3 of §7.3)

Joins are not in the MVP, but four properties of the IR must hold before slice 1 commits to the cutter, because a
retrofit would change edges and segment fields:

- **The build is its own segment** ending in `SINK_HASH_BUILD`, with parallel per-worker (partitioned) collection and a
  finalize step that sizes the table from the exact build row count and builds it in parallel, as a partitioned sink
  finalizes (§3.2 step 5).
- **What the probe reads is a published table, not a batch.** `OP_JOIN_PROBE.probe_build_seg` names the build segment;
  the build segment's published value is a read-only built table owned by the driver (an entry of the `ParamTable`
  keyed by segment id). The `SOURCE_SINK_OUTPUT` source of §2.3 is typed as a batch, so a build segment publishes a
  table through a second published kind, which the IR's `sink_state_id` ("two segments share a sink") is the index of.
- **The build side is an `E3` edge** and lowering does not reorder (§2.4): the optimizer chose the build side. Several
  builds feeding one probe pipeline are `E5` among themselves and may run concurrently (§3.2).
- **Runtime filters.** A build may publish a min/max or a bloom filter that the probe-side scan applies
  (`komira_dynamic_filter`, `komira_morsel.dynamic_join_filter`). It reaches the scan through `source_hooks` before
  the probe segment's first pull. It is an `E2`-like publication, built with joins; the first join slice runs without
  it, and says so on the board.

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
  the three tags, each arm in its own module, returning a `PipelineSink` (§3.5). One translation unit never names every
  sink: the ladder calls one small constructor function per row, and each row's module is imported by the ladder only.
  The compile-time axis that remains is the one the IR calls "the one comptime axis", the key block's width, and it is
  paid inside a kernel, not by the shape of the query.
- **A dtype row is a column-chunk fact decided from `inputs`.** `sink_orientation` is chosen at lowering, which does
  not read the file; whether a string column is dictionary encoded is a fact of each column chunk. `LoweringInputs`
  carries it (§2.1): `DICT_ENCODED` is chosen only when every row group of every pinned file of the scan has a
  dictionary for the column, and otherwise lowering chooses the `COLUMNAR` string row (§4.3). A file whose chunks mix
  both is therefore served by the by-value row; it does not refuse, and it does not guess.
- **One list.** A test walks the capability table and constructs every row, and walks the constructor ladder and
  checks every arm is in the table. A row without a constructor, or a constructor without a row, fails it: that is
  the guard that the table lowering admits against is the table the driver can run.

**What the table serves and refuses.** The MVP rows are the four of the list above plus the fixed-width key rows of
§4.3. Rows that do not exist yet are refused as `LOWERING_SINK_UNSERVED`: a group key mixing types or with more than
one column of a non-string type (ClickBench `GROUP BY UserID, SearchPhrase`; most h2o `id1, id2` and `id4, id5`
queries), a `DECIMAL`, `DATE` or `BOOL` key, and a composite key wider than 8 bytes. Which ClickBench and h2o queries
the board therefore skips is listed in the board plan (§7.4), so "no erased box for every sink the suites need" is
bounded by that list and not claimed for the suites as a whole. D8 names the row that closes the gap (a composite
row-layout key); step 8 of §7.3 builds it.

**Alternatives.** (a) Port the earlier engine's erased state box and thunk table: the box is an `OwnedPointer` home
plus a destroy function, and the function-pointer aliases need `MutExternalOrigin`, which the pointer rules allow only
inside a module's FFI internals; that needs a rule exception. (b) Enumerate the typed `HashAggTable` combinations:
unbounded, as §4.1 says.

### 4.3 The aggregation sinks

All aggregation sinks wrap `komira_op_agg_hash`; they differ in how keys reach it.

**The shared parts.** From `AggSinkData` (group-by expressions, aggregate expressions, output schema, and an optional group-count hint that
sizes the first table and selects nothing) the sink builds an `AggLayout` and a list of `AggSpec`. Per morsel it evaluates the group-by and
aggregate-argument expressions with `komira_batch_eval` (`SUM(l_extendedprice * l_discount)` evaluates the product as a
column first), then commits the argument columns into the table through `AggCommitPlan`. The output batch has exactly
the declared schema; the typing of `MIN`, `MAX`, `FIRST` and `LAST` outputs is `komira_dispatch_agg_exec`'s existing
conform (`agg_pick_output_conform`). `AVG` keeps a sum and a count and divides at the end, and its result type is `DOUBLE` for every input type, a `DECIMAL`
included (`komira_plan_expr.agg_expr`, and the plan IR test that pins `avg` over a `DECIMAL(12,2)` to `DOUBLE`); for a
`DECIMAL` the sum is exact, so the result is one conversion and one division of an exact sum and count, bit-identical on
every schedule; a `SUM` over an empty
input is NULL and a `COUNT` is zero, with one output row for the ungrouped sink and none for the grouped.

| Row | Key block | State | Combine |
|---|---|---|---|
| `(SINK_AGG, NONE, COLUMNAR)` | none | one accumulator array per worker (exact folds); per grain for a float fold (step 9) | merge in the segment's order |
| `(SINK_AGG, I64, COLUMNAR)`, `I32` | the key column as `Int64` cells (an `I32` widened) | **dense** (`PerfectHashAggregator`) when the footers' min and max over all pinned row groups give a domain of at most 65,536 keys, else **partitioned** | dense: per-worker (exact) or per-grain (float, under the byte cap of §3.3) arrays merged key by key in the segment's order; partitioned: below |
| `(SINK_AGG, F32 or F64, COLUMNAR)` | the key by its bit pattern after canonicalizing `-0.0` and NaN | partitioned (a float key has no dense domain) | below |
| `(SINK_AGG, STRING, DICT_ENCODED)` | dictionary codes of the key column, mapped to an interned id | partitioned; the partition comes from the content hash carried with each interned entry, never from the id | below; the merge keys on string content (see Dictionary string keys) |
| `(SINK_AGG, STRING, COLUMNAR)` | the key hashed by value (64-bit hash of the string, compared by bytes on a hit); no dictionary used | partitioned; the partition comes from the 64-bit string hash | below |

**Which sink class, and from what.** The class is a function of the row and one footer fact, never of an estimated group
count. A footer's min and max statistics give an integer key's domain; nothing in a footer gives the distinct count of a
string, float or sparse key, so for every row but the dense case the group count is unknown and the sink is the
partitioned one. When a column has no min or max in some row group, the dense class is not chosen. The group-count hint
of `AggSinkData` only sizes the first table when the optimizer recorded one (absent means a default capacity), and
chooses nothing. (D7, D8.)

**Partitioned sinks (D8).** Each worker folds into a thread-local table whose rows are routed to one of a fixed number
of radix partitions by a **routing hash of the key's content** (`PartitionedFlatHashAggregator`, `FlatHashPartitionFlush`; the partition count is
a constant of the sink). `finalize` merges one partition per task on `ParallelDispatch`, through the sink trait's
existing partition hooks (`num_partitions`, `combine_partition`, `prepare_finalize`, `finalize` of
`komira_operator_api.morsel_sink`), taking the workers' fragments of that partition in worker id order and emitting
partitions in partition id order. The routing hash is a function of the key's content alone: the cell bits of a fixed-width key, the bytes of a string, never a
worker-local id or address. So a group lands in the same partition in every worker, on every schedule and with any worker
count, and the partitions come out in a fixed order. (Order of groups inside one partition follows the merge order and is not a promise; a plan that needs an order sorts.) **That is all it fixes.** An exact fold (integer, `DECIMAL`, count, min, max) is bit-identical on
every schedule. A float fold is not: which morsels a worker's table saw depends on dynamic claiming, so a float sum
inside a group varies in its last bits, and partition-id order does not change that. Float aggregates of a partitioned
sink are therefore within the tolerance of D7, never bit-identical, and the dense rows are the only grouped rows that
promise bit-identity. A serial merge of W tables would be O(W x groups) on one core and the first thing the board shows
on a 10-million-group query; the dense rows pay it, bounded by W x 65,536 cells.

**Dictionary string keys.** A Parquet dictionary is per row group, so a code is meaningful only inside one chunk.
The `DICT_ENCODED` sink keeps, per worker, a table from `(dictionary identity, code)` to an interned id and a
sink-owned string table that holds each distinct string once, with a **64-bit content hash of the string's bytes computed
once per entry, when the entry is interned**, and stored beside it. The `Int64` key the worker's table probes is the
interned id (cheap, worker-local); the id is never hashed for routing, because each worker numbers strings in its own
order.
Decoding happens once per distinct string per dictionary, not once per row, and the output column is built from the
string table. A multi-column key (two dictionary strings, as TPC-H Q1 has) packs the interned ids into one composite
key through the table's composite key mode for the worker-local probe, and its **routing hash** is the existing
multi-key mix (`_fib_hash_n`) over the per-column content hashes in column order, gathered per row from the entries; the
partition is that hash's top bits, passed to the table as a per-row partition id (`commit_batch_partitioned` already takes
one). **Fragment merge.** A partition's fragments from different workers carry keys as worker-local ids, so the merge
resolves each fragment entry through its worker's string table to the content hashes and bytes, and probes a
partition-local merge table keyed by the composite content hash and compared by bytes on a hit (the `COLUMNAR` row's
method). No string is re-hashed at merge, since the hash travels with the entry; the merge pays one byte compare per entry on a hit. The same
string interned as id 3 in one worker and id 9 in another therefore lands in one partition and merges to one group; a
test forces different intern orders in two workers to prove it. This is the part of the design with the most uncertainty, and a spike on the farm (§7.2, slice 4) measures
the interning cost before the string sinks of slice 6 fix their table layout.

Two costs the spike must settle. (1) The carried-hash design above against its alternatives: a shared concurrent intern
table (one id space, so routing could use the id), and the `COLUMNAR` method for the dictionary column too (hash every
row). The spike measures the hashing cost per distinct string at intern time against per-row hashing, the merge's
byte-compare and probe cost per fragment entry as the group count grows, and the fragment memory of W string tables
(each worker holds a copy of every string it saw). Q1 has four groups and any of them is cheap; the acceptance set therefore includes a high-cardinality
dictionary query that is not Q1. (2) A column chunk that fell back to plain encoding has no dictionary: a plan whose
inputs say any chunk is plain is lowered to `(STRING, COLUMNAR)` (§4.2), and a fixture with a fallback row group
tests that the answer equals the dictionary row's.

**Spike result (slice 4).** `src/komira_pipeline_exec/spike/intern_spike.mojo` (target `intern_spike`, run on the farm with
`[run_check]`) times the layouts on a synthetic workload: 8 workers, 4 row groups of 65,536 rows each, a dictionary of up to
8,192 strings per row group drawn from a universe of 4 to 1,000,000 strings, 16-byte strings (and 48-byte at 100,000 groups).
Every layout's counts are checked against a direct count. This is one farm run, best of three trials inside the run, on an unpinned worker; no machine description and no run-to-run variance was recorded, so read the ratios and treat the absolute nanoseconds as indicative. CI compiles the program and does not run it. The hash is
FNV-1a a byte at a time (about 2.2 ns a byte), the same for every layout, so absolute hashing costs are high; a word-at-a-time
hash would lower every cell that includes a hash; that it does not change which layout wins is an inference (the gaps are 9 times and more), not a measurement.

| groups (dictionary) | interned, ns/row | by value, ns/row | shared table, ns/row | merge, carried hash, ns/entry | merge, rehash, ns/entry | fragment entries per merged group | W string tables / merged table |
|---|---|---|---|---|---|---|---|
| 4 (4) | 1.6 | 133 | 6.5 | 139 | 183 | 8.0 | 8.0x (34 KB / 4 KB) |
| 1,000 (1,000) | 3.8 | 141 | 8.8 | 111 | 150 | 8.0 | 8.0x (450 KB / 56 KB) |
| 100,000 (8,192) | 22 | 197 | 28 | 131 | 170 | 3.8 | 3.8x (10.3 MB / 2.7 MB) |
| 1,000,000 (8,192) | 22 | 202 | 29 | 139 | 176 | 1.5 | 1.4x (14.7 MB / 10.6 MB) |
| 100,000 (8,192), 48-byte strings | 44 | 403 | 53 | 258 | 367 | 3.8 | 3.8x (15.7 MB / 4.1 MB) |

The three costs:

1. **Content hash per interned entry.** Hashing a dictionary entry costs 35 ns at 16 bytes and 103 ns at 48 bytes, and
   hashing a row costs the same per row, so hashing per row is `rows / entries` times dearer (8 times at these shapes). Interning
   a dictionary entry (hash, probe, byte compare on a hit, append the bytes) costs 140 to 215 ns at 16 bytes and 330 ns at 48.
   With that amortized over the rows of the row group, the interned layout is 9 to 80 times cheaper per row than hashing
   every row and probing the string table (22 against 197 ns at 100,000 groups; 1.6 against 133 ns at four). The interned
   per-row figure counts into an array indexed by the id: the probe of the aggregate table by the id, which a real sink pays
   once per row, is slice 5's integer-key cost and is not in it. Inference, not measured: interning loses only where a
   dictionary has more entries than the chunk has rows that use them, since its cost is per entry and the alternative's is per row.
2. **Fragment merge per entry.** 110 to 140 ns an entry at 16 bytes and 258 at 48, and it grows with the byte compare and the
   cache misses of a large merge table, not with the rows. Carrying the hash saves 21 to 30 percent of it (the hash that
   would be recomputed: 35 ns at 16 bytes, 109 at 48), so the carried hash stays. The number of entries the merge
   handles is the workers' total, up to W times the distinct strings (8.0 when every worker sees every string): at 1,000,000
   groups and eight workers that would be about a second on one thread. That figure is extrapolated, not measured: the spike's largest merge was 262,144 fragment entries (about 35 ms), and the extrapolation assumes the per-entry cost stays at 139 ns as the merge table outgrows the cache, which it may not. If it holds, it makes the merge by partition on the dispatcher
   (this section's design) a requirement and not an optimization.
3. **String-table memory per worker.** About 60 bytes an entry at 16-byte strings (the bytes, a carried hash, a start, a
   length, a count and a slot at half load), so 1.3 to 1.8 MB a worker at 8,192-entry dictionaries. The W tables hold up to
   W copies of the groups (8.0 at the high-overlap shapes, 1.4 where the workers' dictionaries barely overlap), against
   one copy in the merged table. The sink must charge the growth of its string table to the segment pool when it interns
   (the pool draws in blocks), not only the aggregate state.

**The shared concurrent intern table** (one id space; the `shared table` column) was measured uncontended on one thread only: 28 ns a row against 22
for the per-worker tables at 100,000 groups, because every worker's dictionary entries probe one larger table. It would
remove the merge (about 130 ns a fragment entry) and keep one copy of the strings, and it would put W threads on one
table at every dictionary boundary. Threads and cache-line traffic are not in the spike. Decision for slice 6: keep the
per-worker tables of this section, whose costs are measured and whose merge runs in parallel by partition. Revisit the shared
table only if the memory of W string tables, or the merge, shows on the board at a million groups.

**Two requirements the spike adds to slice 6.** (a) An interned entry is not a group: 2 of 44,691 entries at 100,000
groups, and 34 of 177,656 at 1,000,000, were pointed at by no row (a selection mask or a filter makes this common), and
an entry that no row used must not appear in the output. A group exists when a row reached it, so the group count and the
"seen" state of an aggregate belong to the aggregate table keyed by the interned id, which rows populate, not to the intern table.
(b) The spike's workload has no NULL key and no plain-encoded chunk; the NULL group and the fallback fixture stay in slice 6 as
written.

**Why wrap, and not port the earlier untyped sinks.** The earlier engine's untyped aggregation family is route ladders
around the same kernels, with most of its size in routes particular to benchmark shapes. The kernels on `main` are the runtime-spec layer; what is missing is a thin sink over them. D4 below sets the
size at which the sink gets its own package.

### 4.4 The other sinks

| Sink | Used by | Built from | Lane |
|---|---|---|---|
| `SINK_COLLECT` | every plan's root; the passthrough | resident batches, concatenated serially in morsel-position order for now (parallel concat is a follow-up) | slice 2b |
| `SINK_SORT` over a small result (in memory, one batch) | Q1's `ORDER BY` over its grouped output | `komira_op_sort.sort_batch_by_keys` over the collected batch | slice 4 (MVP) |
| `SINK_SORT`, `SINK_TOPN` in general | `ORDER BY`, `ORDER BY ... LIMIT` | `komira_op_sort` kernels (the top-N indices) and the sinks of komira#1384; parallel sort komira#1420 and komira#1421; external sort komira#1436 | step 1 of §7.3 |
| distinct sinks | `SELECT DISTINCT`, `COUNT(DISTINCT x)` | `komira_op_agg_distinct` and komira#1385, #1390, #1401, then #1455, #1467, #1474 for string keys | step 2 |
| `SINK_HASH_BUILD` and `OP_JOIN_PROBE` | joins | `komira_op_join_build` with komira#1396 and #1397; probes komira#1427 to #1431, #1459, #1465; semi and anti marking komira#1485; fused kernels komira#1413 | step 3 |
| `SINK_PARTITION_BY`, `SINK_PARTITION_TOPN` | window functions | komira#1469 to #1472 | step 4 |

Each of these pull requests is open and none is on `main`; some are typed stage operators and some are runtime-spec
kernels, and which a sink wraps is read from the pull request when its slice starts. The capability table has a `spillable` column per row, false for every row of the MVP, so the arbitrator of step 6 knows
which sinks it may ask and a denial of a non-spillable row fails the query (§3.4). A sink whose kernels are not
merged has no row in the capability table, and a plan that needs it is refused at lowering (§2.4), not run slowly.

### 4.5 Ownership and the pointer rules

- A sink owns its per-worker (or per-grain) states in a slab the driver or the sink creates before the workers start,
  indexed by worker id; `consume` takes `self` and writes only the caller's slot, and anything shared is atomic. This is
  the shape the traits of `komira_morsel` document. Those traits hold the slab behind an `UnsafePointer`; that pointer
  stays private to the sink's module under a `# SAFETY:` comment, and no signature of either package exposes it.
- No partial move through a pointer: a state is taken out with `Optional.take()`, `OwnedPointer.take()`, `swap` or
  `List.pop()`, and the slab is emptied explicitly after `combine`.
- No public function of either package takes or returns an `UnsafePointer`. A concrete-origin pointer inside a kernel
  body carries a `# SAFETY:` comment. FFI stays in the module that owns the foreign resource.
- Nothing in the packages uses `MutAnyOrigin`, `ImmutAnyOrigin` or `MutExternalOrigin`.
- `MemoryReservation` is a plain tally (`mut self`), not an atomic. A sink calls `try_grow` at morsel boundaries, on
  the reservation of the worker's own slot, never inside the kernel's inner loop; a denial is reported through the
  first-error slot (§3.4). A fixed per-worker share of the budget starves a skewed worker while others sit idle, so the
  slot reservations draw from one segment pool in blocks (an atomic grant of a block, a plain tally inside it). The
  pool itself must be shareable by two running segments; the scheduler of §3.2 makes concurrent segments likely
  (joins, CTEs), so the segment pool is atomic from slice 3, the first slice with a sink that grows (D10). In the MVP the root reservation is the only bound on memory (§3.4).

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
| host profile | the engine build, workers, memory budget, spill tiers | `komira_engine_runtime.host_detect`, overridden by `EngineOptions` |
| worker pool | the dispatcher the driver forks onto | `komira_engine_runtime.engine_runtime_build` |
| memory | the root reservation, sized from the host profile | `MemoryReservation.for_host` |
| catalog | table names to schemas and scans | `komira_sql.SqlCatalog` |
| source registry | scan kinds to resolvers | `komira_scan_resolver.ScanSourceResolvers` |
| footer cache | parsed footers, one version per path, capped with a per-query pin (planned; built today: `komira_parquet_footers.FooterCache`, unbounded) | `komira_parquet_footers` |
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
| `cap_workers: Bool` | the opt-in gate of `capped_worker_count`; default off (§3.2) |
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
column)`). The engine supplies one, `ParquetFooters`. It lives in `komira_parquet_footers`, a package of its own, because `EngineContext` (which would hold it in `komira_sdk_exec`) is not written yet; the context will hold the package's `FooterCache`:

- `footer_schema` reads the footer of one file through the `FooterCache` (built: a file; a glob is refused by name;
  planned: the footers of a glob's files unioned by name). The cache is `komira_parquet_footers`' own, which never
  re-reads a held footer; it is not `komira_parquet.ParquetMetadataCache`'s revalidating surface, which would let bind
  and lowering see two versions of one file;
- `column_null_count` sums a column's null counts over the row groups, and returns `None` when any row group records
  none, as the trait asks.

**One cache, two readers.** Lowering's `inputs` (the statistics for payload narrowing and the key domains for the
perfect-hash row) come from the same cache the binder used, so the plan the binder saw and the plan the host lowers
read one version of each footer. Each cached footer is stored with the file's identity (size, modification time, inode, device). Built:
`ParquetFooters` and the `lowering_facts` functions refuse, naming the file, a file whose identity differs from the
stamp when they are asked for its footer. Planned (no slice of §7.3 names it; the `komira_lowering` owner adds the stamp to `ScanFacts` and, as a follow-up to slice 2b tracked in #2024, `SOURCE_PARQUET` checks it at open): `ScanFacts` carries the stamp and the source checks it at open and
refuses a file that changed between bind and execution (§3.4). **Until then a file replaced between lowering and the scan is read with the old plan's schema and min/max: a wrong-result risk.** Today the scan reads through the metadata cache of
`komira_parquet`, which revalidates on its own, so a file replaced after the last lowering call is not refused by this
package. The stamp does not apply the settle rule of `komira_buffer.file_identity`: a same-size rewrite inside the
timestamp tick of a file younger than the settle window can go unseen. The alternative, to read the footer separately at lowering, can bind against one
version of a file and run against another.

A table registered by name (`add_parquet(name, path, schema)`) takes its schema from the same reader at registration.

## 7. The MVP and the order of work

### 7.1 The MVP

TPC-H Q6 and Q1 over Parquet files. Q6 is one segment: `SCAN(parquet) -> FILTER -> AGGREGATE`. **Q1 has an
`ORDER BY l_returnflag, l_linestatus`, so Q1 is two segments**: the aggregation, then a sort of its (four-row) output
over one `E3` edge. Dropping the `ORDER BY` would not be Q1, and the board must not report a query that is not Q1 as
Q1; so the MVP includes the in-memory `SINK_SORT` over one small collected batch (§4.4), which sorts one already-collected batch with
`sort_batch_by_keys`, and the general sort stays step 1 of §7.3.

- **Q6** is an ungrouped `SUM(l_extendedprice * l_discount)` under five conjuncts: the `(SINK_AGG, NONE, COLUMNAR)`
  sink.
- **Q1** groups by two dictionary strings and computes four `SUM`, three `AVG` and a `COUNT(*)` under one filter: the
  `(SINK_AGG, STRING, DICT_ENCODED)` sink, with the filter pushed into the scan and the pushed predicate decoded
  conjunct by conjunct (`komira_parquet_scan.staged_filter`), then `SINK_SORT`.

**Column types.** TPC-H Parquet as DuckDB writes it has `DECIMAL(15,2)` money and quantity columns and `DATE` columns,
not doubles. Q1 and Q6 over those need an exact widened `SUM` (an integer accumulator of the unscaled value, wider than
the column's precision) and `AVG`, whose result is `DOUBLE` (§4.3). The kernels on `main` that cover decimal and date columns are named in slice 3's pull request, or
the slice records the gap and the plan is refused until they exist; the end-to-end fixtures use the same column types
as the real files (§8), so a fixture of doubles cannot pass where a real file would fail. With decimal sums, Q1 and Q6
are exact folds and bit-identical on every schedule. **The MVP therefore builds none of the float machinery of §3.3**:
no position ids, no `next_grain`, `ORDER_NONE` everywhere; step 9 of §7.3 builds it with the first float sink, which is
where ClickBench and h2o need it. An MVP need would be a float column in Q1 or Q6, and neither has one.

Slice 5 also serves `GROUP BY` an integer key, which is the row the sink registry needs to prove its selection
across key dtypes.

### 7.2 The slices, in order

Each slice is one pull request of at most about 3,500 lines with its tests, and lands on `main` with the farm's
`local: 0` build. The sizes are ranges of lines, tests included, and are judgment, not measurement: the analogues are
measured on `main` (`komira_physical_plan` 1.8k source and 0.85k tests; `komira_lowering_rules` 0.35k and 0.94k;
`komira_sdk_exec` 2.6k and 1.0k; `komira_op_agg_hash` 5.4k source; `komira_op_sort` 3.0k and 2.8k; the four modules and
four test files of slice 1a 1.7k and 1.3k; the `vtable_source` deletion 2.6k). A slice that measures over 3,500 lines is
split at the line named in its row, not merged into a larger pull request.

| Slice | Content | Size (lines) | Needs |
|---|---|---|---|
| 1a | `komira_host_profile`: the value/detection split and move of D9 (§2.5), `host_detect`, the import rewrite in 26 files | about 3.0k moved (renames), 0.3 to 0.5k new | this design |
| 1b | `komira_lowering` for the MVP node set (scan, filter, project, limit, aggregate, sort, root): cutter, edges, `LoweredPlan`, `ParamTable`, render, admission, refusals (a join, union or window is refused by name); the `closure_excludes` check on the package, its negative fixtures and `analysis_refusals_mojo` rows (§8) | 2.5 to 3.5k; if over, render and admission go to a slice 1c | 1a |
| 2a | `komira_pipeline_exec` core over fakes: `run_plan` as a ready-set scheduler, `run_segment`, the closed variants, cancel and first-error handling, the driver-over-fakes tests | 2.5 to 3.3k | 1b; `komira_morsel`, `komira_operator_api` on `main` |
| 2b | the real members: `SOURCE_PARQUET` (the builder from `SourceSpecPod`), `SOURCE_BATCH`, `SOURCE_SINK_OUTPUT`; `OP_FILTER`, `OP_PROJECT` (over the selection mask, §3.2), `OP_LIMIT`; `SINK_COLLECT`; the hand-built-plan harness | 2.8 to 3.5k; if over, the harness is its own slice | 2a; `komira_parquet_scan` on `main` |
| 2c | delete `komira_morsel.vtable_source` and its three test files (`test_vtable_source_parity`, `test_vtable_source_failure_paths`, `test_vtable_seam_cost`); remove those three from `test_srcs` in `komira_morsel/BUCK`; edit the `vtable_source` mention in `komira_morsel/README.md`; drop the `vtable_source.mojo`, `test_vtable_source_parity.mojo` and `test_vtable_seam_cost.mojo` rows from `tests/pointer_lint_holds.tsv` and the failure-paths row from `tests/pointer_lint_ffi.tsv`; `scan_resolver_c_box.mojo`, `test_scan_resolver_c_box.mojo` and their rows stay | about 0.2k added, 2.6k deleted | 2b |
| 3 | the atomic segment pool (D10); the ungrouped aggregation sink over `komira_op_agg_state` kernels with exact folds (integer, `DECIMAL`; NULL, overflow and empty-input rules) and the `DOUBLE` `AVG`; Q6 from a hand-built plan | 2.2 to 3.2k | 2b |
| 4 | the farm spike (a Buck target) that measures dictionary interning against a by-value string row, with a high-cardinality dictionary query in its acceptance set, and that reports the three costs of §4.3 (content hash per interned entry, fragment merge per entry, string-table memory per worker); the in-memory `SINK_SORT` | 1.6 to 2.4k | 3 |
| 5 | the grouped aggregation sink over fixed-width keys: per-worker hash tables with a serial merge, for one or more integer keys (rows I64, I32) or float keys (rows F64, F32), the pool charged as the tables grow (built; see below). The dense row and the radix-partitioned row with parallel finalize through the trait's partition hooks (§4.3, D8) are a later slice, 5b, `Needs` 5 | 2.5 to 3.5k | 3 |
| 6 | the `DICT_ENCODED` string sink (content hash carried per interned entry, composite routing hash, string-keyed fragment merge as §4.3 says) and the `COLUMNAR` string sink, output typing, the two-worker different-intern-order test, the plain-fallback fixture; Q1 from a hand-built plan (built; see below) | 2.5 to 3.5k | 4, 5 |
| 7 | `EngineContext`, `EngineOptions`, `run_plan` over the context | 2.0 to 3.0k | 1b, 2b, 6 |
| 8 | `run_sql`, `ParquetFooters`, the end-to-end tests for Q1 and Q6 and their fixtures; the footer-answered `COUNT(*)` and `MIN`/`MAX` | 2.5 to 3.5k | 7 and the binder, komira#1216 |

**What slice 3 built, against the row above.** The ungrouped sink does not use the `komira_op_agg_state` kernels, `AggLayout` or `AggSpec`: none of them folds a `DECIMAL128` value, or an integer, into an exact 128-bit accumulator with the overflow rule of §4.3 (the accumulators there are 64-bit or float, typed at compile time; `int_sum_overflow` only refuses a 64-bit overflow). The sink therefore folds in its own small module (`komira_pipeline_exec.agg_fold`: one count and one 128-bit integer per aggregate and worker, merged in worker order) and uses `komira_batch_eval` for the argument expressions, through the `MapOp` projection under the selection mask. The grouped sinks of slices 5 and 6 are the ones that need `komira_op_agg_hash`, and they take the table kernels there; whether they take their value folds from `agg_fold` or from the kernels is decided when they start.

**What slice 5 built, against the row above.** `komira_pipeline_exec.sink_group_agg` does not use `komira_op_agg_hash` either: its entries hold Int64 keys with no NULL flag (SQL groups the NULLs of a key as one group) and 64-bit or float accumulators, with no exact 128-bit fold. It keeps its own small table (`group_table`: a 64-bit cell and a NULL flag per key, one `AggCell` per aggregate), folds rows with `agg_fold` per row, and merges the workers' tables serially in worker order with the same overflow rule. Each doubling of a table is charged to the segment pool before it is made. The sink serves composite keys of several columns of one family (all integers, or all floats) with the same table, so those arrive with slice 5 and not with step 8 of §7.3, which remains the mixed-type and string composites. `komira_lowering` (`cut_walk._agg_triple`) still refuses a key of more than one column unless every column is a dictionary string, so admitting the same-family composite is a change there that this slice does not make (it touches only `komira_pipeline_exec`). Not built, and the follow-up slice 5b: the dense table for a domain of at most 65,536 keys and the radix-partitioned table with a parallel finalize of D8. Until then the merge is O(workers x groups) on one core, which D8 names as its cost.

**What slice 6 built, against the row above.** `komira_pipeline_exec.sink_string_group_agg` serves `(SINK_AGG, STRING, DICT_ENCODED)` and `(SINK_AGG, STRING, COLUMNAR)` for one or more STRING key columns, over slice 5's group table, folds, merge rule, refusals and pool charging. It follows section 4.3's decision (per-worker intern tables with the content hash carried) with these differences, each because the code found a simpler form: a worker keeps one intern table (`string_keys.InternTable`: the bytes of each distinct key string once in an arena, a start, a length and the 64-bit content hash) shared by all its key columns, and the group table is keyed by the string's id there, one cell per key column; the dictionary is not interned whole but one code at a time, on first use by a selected row, through a per-morsel code-to-id array (the design's `(dictionary identity, code)` table is a per-morsel array, since nothing in a column identifies a dictionary across morsels), so a dictionary entry no selected row used is never interned and the spike's requirement (a) holds by construction as well as by the rule that a group is a row of the group table; a group's hash mixes the content hashes of its strings (the same in every worker) and is used to probe the table, not to route a partition, because the merge is still serial (slice 5b's partitioned merge will route by it). The two rows differ only in how a DICTIONARY column reaches the table: DICT_ENCODED interns by code, COLUMNAR hashes and interns every row; a flat STRING column is interned per row by both, so a chunk that fell back to plain encoding under a DICT_ENCODED sink gives the same answer (the planner picks DICT_ENCODED only when it can prove every row group is dictionary encoded, and that proof buys speed, not correctness). `RealBuilder` asks the Parquet source to keep dictionaries only for the DICT_ENCODED row. `combine` merges by value in worker order: each string of a worker's groups (its carried hash and its bytes) is interned into a merge table, and the merged group table is keyed by the merge ids, so the string that is id 3 in one worker and id 9 in another is one group and nothing is re-hashed. Both intern tables and group tables are charged to the pool as they grow, before they grow, and returned once merged. A fixed-width key beside a string key is not served and is refused by name when the sink is built (`komira_lowering` never asks for one). `tpch_q1` is TPC-H Q1 as a two-segment hand-built plan (scan, filter, project and the string sink; then SINK_SORT by the two keys) over a lineitem-shaped table written to Parquet with dictionary-encoded and with plain flag columns; its tests compare the exact result with a row-at-a-time oracle in both orientations. Not built: the partitioned parallel merge (5b), a hash faster than FNV-1a a byte at a time, and the join-side uses of the intern table.

The hand-built-plan harness of slice 2b gives a measured number at slice 3 (Q6) and slice 6 (Q1) before the binder
exists; the end-to-end tests over SQL text come last only because the binder is another lane's open draft.

The binder's own slices are another lane's. This design needs `bind_statement` to produce a plan for Q1 and Q6; it
does not need the binder's window, correlated-subquery or union arms.

### 7.3 After the MVP

Each step adds a sink, an edge or an operator, and none changes the cutter's three roles or the driver's loop.

| Step | Adds | Tied to |
|---|---|---|
| 1. Sort, top-N, limit | `SINK_SORT` beyond one small batch, `SINK_TOPN` | komira#1384; komira#1420, #1421, #1436 |
| 2. `COUNT(DISTINCT)`, `SELECT DISTINCT` | distinct sinks; string-key route | komira#1385, #1390, #1401; #1455, #1467, #1474 |
| 3. Joins (design constraints in §3.6) | the build segment, `OP_JOIN_PROBE`, `E3` edges, outer, semi and anti; the build-side and runtime-filter handling | komira#1396, #1397, #1413, #1427 to #1431, #1459, #1465, #1485; the optimizer records the build side, and which pairs the lowering must accept follows komira#1426 |
| 4. Window and partition top-N | `SINK_PARTITION_BY`, `SINK_PARTITION_TOPN` | komira#1469 to #1472 |
| 5. Scalar subqueries | the optimizer's dependency loop in `engine_optimize`, run before lowering | `komira_optimizer` |
| 6. Spill | the arbitrator over each breaker; a spillable aggregation | komira#1484; the arbitrator in `komira_engine_runtime` |
| 7. Writes, ASOF | COPY and CREATE TABLE AS; the ASOF cut | komira#1487 |
| 8. Composite group key | the row that serves what §4.2 refuses: a group key of 2 to 4 mixed-type columns, compared by row, over the partitioned sink of slice 5 (D8); 2.5 to 3.5k lines | slice 5 |
| 9. Reproducible float sinks | 9a: position-derived morsel ids in `komira_parquet_scan` (§3.3), 1.0 to 1.6k lines. 9b: `GrainSourceImpl`, `ORDER_ROW_RANGE`, grain state in the ungrouped and dense sinks and the determinism tests (D7), 2.0 to 3.0k lines | the first float sink; slices 3 and 5 |

Some pull requests of the list are stacked on others; their order is theirs. A step lists only what it needs. Joins are
step 3 and 20 of the 22 TPC-H queries need one, so the board covers two TPC-H queries until step 3; the post-MVP order
favors ClickBench and h2o, whose single-table queries it serves first: step 8 comes before steps 1 to 7 because it removes the
board's largest refusal list, and step 9 starts when the first float sink does.

### 7.4 The board plan

The comparison rules are part of the design, because a board that cannot be trusted is worse than none:

- **Threads.** Both engines run with all cores of the same host, DuckDB's default; the thread count is on the board.
- **Cold and warm.** Both are reported separately; a warm run is the median of several runs after one discarded run,
  a cold run drops the file cache first. Scale factors are stated per table (TPC-H at a small and a medium factor).
- **Results.** The answer is checked against DuckDB's output over the same files, exact for integers, strings and
  decimals, within a stated relative tolerance for floats. A query whose answer differs is reported as failed, not
  timed.
- **Disclosure.** Any option that costs throughput for reproducibility (the grain state of D7) is shown on the board.
  Shortcuts both engines take, such as a `COUNT(*)`, `MIN` or `MAX` answered from the footer, are marked as such, so a
  win is not a shortcut DuckDB also takes.
- **Refusals.** A query refused at lowering (§4.2) is listed on the board as unserved, with its token, never omitted.
  Until the composite-key row of D8 exists that list includes ClickBench queries that group by a pair of mixed-type
  columns and the h2o group-bys over `id1, id2` and `id4, id5`.

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
| Morsel ids (step 9a) | two schedules over one file give the same id for the same morsel; ids are distinct and ordered by (unit position, sub-morsel index), also for a unit cut into several morsels | an id from an arrival counter; two emit helpers minting overlapping ids |
| Exact folds across workers (MVP) | a decimal `SUM`, an integer `SUM`, a `COUNT` and the `DOUBLE` `AVG` of a decimal over a fixed input are bit-identical on one, two and seven workers, also in a partitioned sink | a merge that depends on the schedule; an `AVG` computed from rounded partial quotients |
| Float determinism (step 9b) | in the promised classes (§3.3): a float `SUM` and `AVG` over a fixed input, ungrouped and dense, are bit-identical on one, two and seven workers | a combine in completion order; two workers folding one grain |
| Driver policy | the driver raises on an edge tag it has no policy for | a cutter that emits `E4` early and is silently serialized |
| Purity closure | a `selftest_scenario` of `komira//tools/build/selftest` (the family of `analysis_refusals_mojo`: a `buck2 test` target that drives a nested buck2 on the farm) analyzes, for each refused package, a negative fixture under `tests//negative/closure_excludes` that lists that package in `deps` and expects the exact refusal message, and the real `komira_lowering`, which depends on `komira_async_api`, is the positive control: a dep named `komira_async_api` is not refused | a purity claim the build cannot see; a check that matches by prefix |
| Sinks against an oracle | each aggregation sink matches a naive row-at-a-time oracle on random inputs with NULLs, empty input, one group, many groups, repeated and colliding keys, dictionary keys across several row groups with different dictionaries | a dictionary code used as a group key across chunks |
| Footer identity | a file replaced between bind and run is refused at open | a result computed over a different version than the plan was bound to |
| End to end | `run_sql` over fixture Parquet files equals recorded expected answers (below) | a wrong filter, projection, key or aggregate anywhere on the path |

**Recorded answers.** The end-to-end fixtures are small Parquet files a test writes deterministically from a seed
through `komira_parquet_writer` (a lineitem-shaped table with the column types of the real files, `DECIMAL(15,2)` and `DATE` among them, dictionary strings, several row groups, one row group that fell back to plain encoding, and NULLs), and a
checked-in file of expected results, one per query, produced once by a reference engine over the same file and
recorded with the SQL that produced it. The test never runs the reference engine. A mismatch of one value fails the
test and prints the row. Integer, string and count results compare exactly. Float aggregates compare with a relative
tolerance that the fixture file states with its reason (a sum of many doubles differs by rounding between any two
correct orders), and the same results are also compared bit-for-bit between runs of this engine (above). Q1's `AVG` columns are doubles, so they compare under that tolerance. The suites'
full-size files are never committed and are not a test of this design; a larger-scale run is the benchmark's job.

**Coverage.** Each new package enters the coverage census at the 99% target; a branch of a refusal or a failure path
that no test reaches is a defect of the tests.

## 9. What exists and what must be built

| Piece | Exists | Must be built |
|---|---|---|
| Plan IR, expressions, wire | `komira_plan_ir`, `komira_plan_expr`, `komira_plan_wire` | none |
| Optimizer | `komira_optimizer` and its driver | the shared-subplan and scan-dedup passes, in the optimizer (D5) |
| Physical IR | `komira_physical_plan`, version 14, with driver-table indices | the self-contained IR (§2.2) |
| Host rules, morsel sizing | `derive_payload_narrow`; `record_segment_morsel_rows` and `HostProfile` in `komira_engine_runtime` | the other host-local rules; `komira_host_profile` and `host_detect` (D9, §2.5) |
| **Lowering** | none | `komira_lowering` (§2) |
| **Driver** | traits, `PipelineExecution`, segment execution context, `ParallelDispatch` | `komira_pipeline_exec` (§3) |
| **Sinks** | table kernels in `komira_op_agg_hash`, `komira_op_agg_state`, `komira_op_agg_slab`; sort, join and distinct kernels, some open | the untyped aggregation sinks and the registry (§4) |
| Parquet source | `komira_parquet_scan`; morsel ids are arrival order today | position-derived morsel ids and `GrainSourceImpl` (§3.3, step 9); the source builder from `SourceSpecPod` (§3.5) |
| **Context** | twelve leaves in `komira_sdk_exec` | `EngineContext`, `EngineOptions` (§5) |
| **Door** | `komira_sql` parse; binder draft komira#1216 | `run_sql`, `ParquetFooters` (§6) |

## 10. Decisions

Recommendation first. D1 to D10 are the questions of this document; the open points below them are smaller and have a
recommendation each.

| # | Question | Recommended | Alternative | Why |
|---|---|---|---|---|
| D1 | Which IR do the first slices lower to | The existing `komira_physical_plan` version 14, with a `ParamTable` owned by the `LoweredPlan`, behind the final `lower(plan, host_profile, inputs)` signature; the self-contained IR is a later, separate design and slice (§2.2) | Build the self-contained IR first, so no query runs until it exists | The six changes the self-contained IR needs do not change the cut, the driver or the signature, so they can follow; the refusal gates (a non-total Parquet arm, an uncuttable node) keep the interim IR honest. This is the alternative [plan models](plan_models.md) D7 rejected ("port as is and fix later"), taken with an exit condition (no consumer outside `komira_pipeline_exec` and no serialization until the self-contained IR lands, §2.2) and with the `ParamTable` as the single place the side tables live; a deviation in time, not in direction. The cost: a `ParamTable` wire form is one more item of the later slice. |
| D2 | Which packages | New `komira_lowering` (pure, no operator, no I/O) and new `komira_pipeline_exec`; the context stays in `komira_sdk_exec`; the `komira_compiler` row of [the architecture](../architecture.md) points here | One `komira_engine` for lowering, driver and context; or reuse the name `komira_compiler` | Purity is a property of a dependency list, and a package that also drives execution cannot show it; the name `komira_compiler` names nothing on `main`, and what it once covered is in `komira_batch_eval` and `komira_optimizer`. The costs: two packages to review, and `komira_sdk_exec` gains a heavier dependency closure, which splitting its leaves from the context can undo if it matters. |
| D3 | How a runtime plan selects a sink | A closed registry of untyped sinks selected by `(sink_kind, sink_key_dtype, sink_orientation)`, an `if` ladder with one module per row returning a closed variant, no erased box, no function pointer (§4.2) | Port the erased state box and thunk table, with a rule exception for `MutExternalOrigin`; or enumerate typed `HashAggTable` combinations | A closed variant keeps every pointer rule. The enumeration is unbounded for runtime key and aggregate types, and one module naming every sink is a very large translation unit, which the file-size rule exists to avoid. |
| D4 | Who owns the untyped aggregation sinks, and at what size | Slices 3 to 6 here, over `komira_op_agg_hash`, behind a farm spike for the dictionary route; if the sinks pass about 8,000 lines, they move to their own package; and tell the owners of the operator pull requests that those do not cover SQL aggregation | Port the earlier engine's untyped aggregation family (several times the size of the kernels it wraps) | The kernels are the runtime-spec layer already on `main`; what is missing is a thin driver, and measuring before writing the dictionary path is cheaper than rewriting it. |
| D5 | Where the shared-subplan elimination and the scan-dedup passes go | Into `komira_optimizer`, as plan rewrites, after the MVP; Q1 and Q6 do not need them | Into lowering as host rules | Lowering runs no optimizer pass (§2.4); a pass that rewrites the plan is the optimizer's by definition, and a host that applies it differently from the producer breaks "hosts never re-optimize". |
| D6 | How configuration reaches the engine | One `EngineOptions` struct filled by the caller from its flags; options that change the plan are inputs of `lower` through the host profile; no environment read in any package of this design (§5.2) | Keep some environment variables as mode markers | A flag is required and parsed at startup; the project rule admits environment variables only for platform-set markers, secret material and provider credentials, and a performance switch is none of these. |

| D7 | What determinism is promised for float aggregates | Exact folds (integer, `DECIMAL`, count, min, max) are bit-identical on every schedule at no cost, and the MVP promises exactly that. For floats (step 9): bit-identity across worker counts for ungrouped sinks and for dense grouped sinks, whose per-grain state is bounded by footer facts (row groups x key domain x state width, under a byte cap); every other grouped float sum uses the partitioned sink and is stated within tolerance, disclosed on the board | (a) Bit-identity for every float sink, with grain state in the grouped sinks: reproducible, but memory is grains x groups and grows with the input (unbounded at 10^5 to 10^7 groups). (b) Order-insensitive float folds (compensated or fixed-width accumulators) everywhere: reproducible at a measured throughput cost. (c) No promise: cheapest, and no test can assert it | The grain state is the only scheme that reproduces a plain double sum, and it is affordable exactly where the footers bound it. For the partitioned case the choice between (b) and tolerance is a measured one; recommendation: tolerance first, (b) if the board shows a comparison that needs it. Open: whether a published board may carry a tolerance for the partitioned float case. |
| D8 | How grouped aggregation scales | A grouped sink is dense when the footers bound an integer key's domain at 65,536 keys or fewer, and radix-partitioned otherwise, with a fixed partition count and a parallel finalize of one task per partition through the sink trait's existing partition hooks (§4.3); the class is chosen from the row and the footer's key range, never from an estimated group count. A composite row-layout key (2 to 4 mixed columns, compare-by-row) is the later row that serves the mixed-key queries (step 8 of §7.3) | Per-worker tables with a serial merge, partitioned only above an estimated group count | A serial merge is Amdahl-bound on high-cardinality GROUP BY, and a footer cannot estimate group counts for string, float or sparse keys, so an estimate gate would be a guess; the partition-flush kernel and the trait's partition hooks are already on `main`. The cost: a small fixed partitioning cost on low-cardinality queries such as Q1, which the board will show; and a float fold in a partitioned sink is not reproducible bit for bit (§4.3). |
| D9 | How `komira_lowering` stays pure | A new leaf `komira_host_profile` holding the `HostProfile` value and morsel sizing, with detection split from the value and left in `komira_engine_runtime` (`host_detect`); an exact-name `closure_excludes` attribute in `komira_lowering/BUCK` (and `komira_lowering_rules/BUCK`), shown able to fail by `analysis_refusals_mojo` rows (§2.5, §8) | Move the four modules whole, bringing detection and its probe imports into the leaf; or keep `komira_engine_runtime` as a dependency and drop the claim that the build enforces purity | `deps` is the full transitive closure and the runtime package depends on file-system, object-store, async and shuffle packages, so the claim is false with it as a dependency. The split keeps probe code and `l2_share` out of the leaf and leaves `lower` nothing that reads the host; `komira_host` is in the closure regardless, through `komira_buffer`. Cost: touching four modules and 26 importers in a package other lanes edit, in slice 1a, and splitting one test file. |
| D10 | Whether the memory pool of a segment is atomic | Yes, from slice 3, the first slice with a sink that grows: each worker's slot reservation draws blocks from one segment pool by atomic grant and tallies plainly inside the block, so workers of one segment and, later, two running segments can share it (§4.5); the root reservation is the only bound in the MVP (§3.4) | A plain tally per breaker, which neither workers of one segment nor two running segments can share | A fixed per-worker share starves a skewed worker while others sit idle; a plain tally shared by workers races. |

**Open points** (each with a recommendation; none blocks slice 1):

| # | Question | Recommended | Alternative |
|---|---|---|---|
| O1 | The grain constant and its memory bound | A grain is one row group or one sub-row-group chunk; the cutter's dense-domain rule keeps grain state (row groups x key domain x state width, all from footers) under a stated byte cap, with the number measured in step 9b (D7) | A grain of a fixed number of morsels independent of the row group |
| O2 | How a closed variant holds its member | The standard library's `Variant` if it passes the Mojo review for moves and destruction; else one `Optional` per member with a tag | A hand-written tagged struct per role |

## 11. Prior art consulted

- DuckDB's `Pipeline` is a source, a list of operators and a sink; `MetaPipeline` groups the pipelines that feed one
  sink and an event DAG with finish and complete events schedules them. Its grouped aggregation builds radix-partitioned
  thread-local tables and finalizes one task per partition; its hash join finalizes the table from the exact build
  count in parallel. §2.3, §3.2, §3.6 and D8 follow these. DuckDB's pipeline construction classifies each operator as a source, a streaming operator or a sink, and cuts at
  sinks; the three roles of §2.3 follow it.
- The morsel-driven scheduling of Leis et al. (SIGMOD 2014): workers claim fixed-size chunks of a source and run a
  pipeline over each, with per-worker state merged at the end; §3.2 is that loop on komira's traits.
- Flink persists its compiled plan because a re-planned topology cannot restore state; the same reasoning as
  [plan models](plan_models.md) D1 is why lowering here is a deterministic function and never an optimizer.
