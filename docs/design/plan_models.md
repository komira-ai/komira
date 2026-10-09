# Design: logical, optimized and physical plan models, with streaming

Status: draft for review. It builds on these specs, each on its own open pull request, and does not repeat them:

- `optimized_plan.md` (#1094): the `OptimizedPlan` header and body, pins, admission, segments, versioning;
- `optimized_plan_udfs.md` (#1094): UDF kinds, arms and the environment image;
- `optimized_plan_sources.md` (#1094): typed pins, source kinds, index and graph operators;
- `udf_runtime_interface.md` (#1132): the three UDF modes and the runtime ABI;
- `storage_stack.md` (#1134): Iceberg tables, tails and the roll into tables;
- `data_graph_storage.md` (#833): graph facts as tables.

Code citations refer to `main`. Spec citations name the spec and its section, because line numbers move between
revisions. Nothing was built or run to write this document.

**What this document adds.** The specs above define the logical plan and the optimized plan for bounded work. They
fix how a plan says it is streaming (an `UNBOUNDED` scan) and which operators are refused on unbounded input. They
also say that "windows, watermarks and the streaming forms of operators are added under new format versions"
(`optimized_plan.md` §5.2). This document defines those additions at all three levels as one system, says what the
physical level must become before it can carry streaming, and proposes three amendments to the specs above (§8).

---

## 1. Overview

### 1.1 The three levels

| Level | What it is | Who produces it | Who consumes it | On the wire? |
|---|---|---|---|---|
| **Logical** (RAW) | The bound relational algebra: what to compute, with no execution decisions. It is `WirePlan` decoded in the RAW context, wrapped in `WirePlanEnvelope` (`src/komira_plan_proto/plan.proto:1534`, `:1625`). | An SDK (dataframe or SQL front end), after binding. | The producer's optimizer; local runs; tools (render, diff, lint); a service that stores a bound query and re-optimizes it on each run (`optimized_plan.md` §2). | Yes, for local runs and tools. Never accepted by a scheduler. |
| **Optimized logical** (OPTIMIZED) | The same algebra with every optimizer decision pinned as a node field: join order and build side, algorithm, aggregate mode, exchanges, access paths, snapshot pins, and (this document) the streaming decisions of §3. An `OptimizedPlan` with an `OptimizedPlanBody` (`optimized_plan.md` §4.1). | The producer: the SDK, once, on the user's machine. A service that re-optimizes stamps `komira/server`. | A scheduler (header only), a coordinator (verifies and cuts), the executor hosts (admit and lower). | **Yes. It is the only plan form a scheduler accepts**, together with its environment image. |
| **Physical** | The host's executable form: pipelines between breakers, exchanges with partition counts, morsel sizes, memory budgets and spill; in streaming, also the epoch lifecycle, state bindings and sink commit protocols. | The executor host, by deterministic lowering of an `OptimizedSegment` (§4.2). | The same host process. | **No.** `OptimizedSegment` field 11 is reserved for a later self-contained physical form (`optimized_plan.md` §11). |

The producer optimizes, the scheduler places, the coordinator cuts and the host lowers. Each step runs once
(`optimized_plan.md` §2). Nothing after the producer re-optimizes. A host applies only the named host-local rules
(`optimized_plan.md` §5.3), and a streaming plan does not change that.

### 1.2 What crosses which boundary

```
 SDK / SQL front end
   │  bind
   ▼
 Logical (RAW WirePlan) ─────────► local run, tools, stored bound query
   │  optimize (once, on the producer)
   ▼
 OptimizedPlan  (header + canonical body, plan_digest)  ──►  scheduler  (with the environment image)
   │  coordinator: verify digest, cut at exchanges (mechanical)
   ▼
 OptimizedSegmentDag (same engine build only; logical arm 10; physical arm 11 reserved)
   │  host: admit, lower deterministically, apply named host-local rules
   ▼
 Physical plan (in-process only) ──► batch driver  |  streaming driver (if any scan is UNBOUNDED)
```

### 1.3 Versioning at each level

| Level | Rule | Where it is defined |
|---|---|---|
| Logical (RAW) | `WirePlanEnvelope.format_version` (`plan.proto:1651`) is a minimum reader capability, checked by set membership and never by `>=` (the comment from `plan.proto:1626`). A bound plan that a service stores to re-optimize later has the same no-window promise as the optimized plan. | `optimized_plan.md` §9.1 |
| Optimized | **Backward compatible forever, with no window**: every later reader accepts and executes every plan that any released producer emitted, with the result it first produced. Every new body field bumps `format_version`; the meaning of each decision is frozen per `optimizer_contract_version`; the golden corpus checks it. Only a revoked producer build is refused. | `optimized_plan.md` §9.1-§9.7 |
| Segments | No promise across builds. After an upgrade a stored cut is re-derived from the stored `OptimizedPlan`. | `optimized_plan.md` §9.6 |
| Physical | No wire form and no promise across builds. Within one build an exact-match canary checks it today (`PHYSICAL_PLAN_IR_VERSION = 13`, `src/komira_plan_ir/physical_plan.mojo:62`). §4.6 proposes keying the check to the engine build. | §4.6 |
| **Streaming state** (new) | A **savepoint** can be read by every later build, and by a later plan that maps its state ids (§5.3). A **checkpoint** is readable only by the build that wrote it. | §3.5, §4.4 |

`optimized_plan.md` §9.6 leaves the last row explicitly open: "Whether operator state written by one build can be
read by another is a separate question, outside this design". A streaming plan that keeps running across an engine
upgrade, or that is rolled from v1 to v2, cannot leave it open. §3.5 and §4.4 answer it.

### 1.4 The streaming rule, restated

An `UNBOUNDED` scan puts the engine in streaming mode for that plan. There is no run-kind field and no separate image:
the streaming driver runs the same decoded plan (`optimized_plan.md` §5.2). The boundedness of every other node is
derived, and the header repeats it as `needs.unbounded`, checked against the body (`optimized_plan.md` §6.1). This
document keeps that rule and adds what a streaming plan must state for its result to be defined: event time,
watermarks, windows, changelog, emit policy, sink semantics and state.

**"Watermark" has two meanings in the specs.** `storage_stack.md` ("The roll") persists the last rolled offset of each
partition as the table property `komira.tail.<lineage>.watermarks`, and `optimized_plan_sources.md` §15.4.3 calls it
`wm(p)`. In this document a **watermark** is always an **event-time watermark** (§2.2.2). Amendment A1 (§8) renames
the first before `storage_stack.md` lands, because that property name ends up in users' tables.

---

## 2. The logical plan model

### 2.1 What exists (RAW, `main`)

**Relations.** `LogicalPlan` has 16 tags (`PLAN_TAG_COUNT = 16`, `src/komira_plan_ir/logical_plan.mojo:174`): SCAN,
FILTER, PROJECT, AGGREGATE, JOIN, SORT, LIMIT, DISTINCT, TOPN, PARTITION_BY and PARTITION_TOPN (SQL `OVER()`),
ASOF_JOIN, UNION, VIEW_REF, CSE_REF, CAST_TO_VARCHAR. `WirePlan` has one arm per node in fields 4-19
(`plan.proto:1558-1583`). Join types are INNER, LEFT, RIGHT, FULL, SEMI, ANTI and CROSS. A write is the envelope field
`write_target` (`plan.proto:1655`, message `WireWriteTarget` at `:1610`), deliberately not a node arm.

**Expressions.** `WireExpr` (`plan.proto:1060`) carries column references, literals, operators, casts, IN-lists, CASE,
correlated subqueries that embed a `WirePlan`, aggregate, math, string, regexp, struct, map and JSON functions, SQL
analytic windows (`WireWindowFn`, `plan.proto:1007`) and a name-keyed `WireUdfCall`.

**Types.** `WireField` (`plan.proto:146`) follows the Arrow model: the engine's `ArrowType` id (an unknown id is
refused, not narrowed), nullability, decimal precision and scale, timezone, dictionary index type, union ids and
metadata. `optimized_plan.md` §5.2 adds recursive `children` for nested types.

**Sources.** A scan carries a `WireScanSource` (`plan.proto:1135`, message at `:456`), which holds the
`WireScanBinding` (kind id, params, pushdown gate, snapshot policy; `plan.proto:372`). The source kinds of
`optimized_plan_sources.md` §15.4 are Iceberg and Delta tables and Hive-style Parquet; `komira.broker.topic`, read as
**one relation** (the topic's Iceberg table up to each partition's rolled offset, then the tail above it, §15.4.3);
`komira.rowstore.table`, which is bounded (its change feed is "a separate `UNBOUNDED` kind, not specified here",
§15.4.4); `komira.search.index` and index access paths (§15.5); `index_lookup` (§15.6) and `expand` over graph tables
(§15.7). In-memory sources are refused on the wire.

**UDFs.** `optimized_plan_udfs.md` §10.2 defines six kinds: SCALAR, ROW, MAP_BATCHES_COLUMN, MAP_BATCHES_FRAME,
AGGREGATE (plain or mergeable) and STEP. A UDF runs in one of three modes: native, one interpreter per engine thread,
or one shared parallel virtual machine (`udf_runtime_interface.md` §1.2). **No plan field names the mode, at any
level**, and streaming changes none of this.

**Boundedness.** RAW admits `WireScanNode.boundedness` and reads an unset value as `BOUNDED` (`optimized_plan.md` §5.2).

### 2.2 The streaming additions

Everything below is added under the next `format_version` (`optimized_plan.md` §9.2). RAW and OPTIMIZED both admit
each new field, because it states what the user asked for, not how to execute it. An absent field means exactly what
a plan means today. The model answers the four questions of the Dataflow Model (Akidau et al., "The Dataflow Model",
VLDB): *what* is computed (the relational nodes), *where* in event time (window assignment, §2.2.3), *when* results
are emitted (watermark plus emit policy, §2.2.2 and §2.2.5), and *how* refinements relate (changelog kind, §2.2.4).
Each changes the result, so each belongs in the logical plan.

#### 2.2.1 Boundedness of every relation

Boundedness is stated only on scans and derived for every other node. This document adds one derived refinement for
state, modeled on DataFusion's `Boundedness::Unbounded { requires_infinite_memory }`:

| Derived class | Meaning |
|---|---|
| `BOUNDED` | The relation ends. Every operator is allowed. |
| `UNBOUNDED_BOUNDED_STATE` | The relation never ends, and every stateful node below it evicts its state by watermark. |
| `UNBOUNDED_UNBOUNDED_STATE` | The relation never ends, and some stateful node's state grows without bound unless the plan gives it an explicit retention (§3.5). |

The class is always derived, never stored. The optimizer uses it to refuse or admit (§3.3).

#### 2.2.2 Event time and the watermark declaration

**The convention.** Windows are half-open, `[window_start, window_end)`. A watermark `W` asserts that no later row
has event time `< W`. A window fires when `W ≥ window_end`. One convention, used everywhere below.

`WireScanNode` gains one optional message:

```proto
message WireEventTime {
  string            column              = 1;  // a column of the scan's output, by name (as `projection` is); Arrow timestamp or date
  WatermarkStrategy strategy            = 2;
  int64             max_delay_micros    = 3;  // BOUNDED_OUT_OF_ORDERNESS only; >= 0
  int64             idle_timeout_micros = 4;  // 0 = a split is never treated as idle
}
enum WatermarkStrategy {
  WATERMARK_STRATEGY_WIRE_UNSPECIFIED = 0;  // refused when WireEventTime is set
  BOUNDED_OUT_OF_ORDERNESS = 1;  // W = (max event time seen) - max_delay
  SOURCE_PROVIDED          = 2;  // the source yields Watermark(ts) itself
  ASCENDING                = 3;  // event time never decreases within a split; W = max seen
}
```

- **The column's Arrow type gives the unit and timezone of the data.** A column that is not temporal is refused
  (`PLAN_EVENT_TIME_NOT_TEMPORAL`). Watermarks themselves are UTC microseconds; the source contract's
  `watermark_ts: Int64` (`src/komira_morsel/streaming_source.mojo:147`, `:203`) has no unit today, and §7 fixes it.
- **The source contract already carries watermarks.** `StreamPoll` has the states Item, Idle, Watermark(ts) and
  Closed (`streaming_source.mojo:127`). `StreamSourceCaps.emits_watermark` says whether a source can honour
  `SOURCE_PROVIDED`; if it cannot, the producer refuses the plan (`PLAN_WATERMARK_SOURCE_UNSUPPORTED`).
- **Per split, then minimum.** A watermark is tracked per split (for a topic, per partition). The scan's watermark is
  the minimum over the splits that are not idle. A split stops holding the watermark back once it has been idle for
  `idle_timeout`. A split that reports `Closed` sets its watermark to +infinity, so a drained fixture closes every
  window. In SQL the declaration is `WATERMARK FOR ts AS ts - INTERVAL '5' SECOND`; in a dataframe,
  `.with_watermark("ts", delay="5s")`.
- **A split that starts with history holds its watermark.** A topic scan reads a partition's Iceberg history up to
  its rolled offset, then its tail (`optimized_plan_sources.md` §15.4.3). Morsels of the history are read in parallel
  and arrive out of offset order, so the split's watermark is held at −infinity until its history is read, then
  released. Without the hold, a start at `EARLIEST` would mark most of the history late. A partition added to a topic
  while the plan runs is a new split, held until it reports a watermark or goes idle.
- **A bounded scan may also declare event time.** Only window assignment uses it, and its watermark becomes +infinity
  at end of input.
- **Event time is not graph time.** The bi-temporal `valid_from`/`valid_to` filter on graph scans
  (`optimized_plan_sources.md` §15.7.3) is a predicate on stored columns, not a watermark.

#### 2.2.3 Window table functions

A new node, `WireWindowAssignNode`, is a table-valued function in the style of Flink's FLIP-145
(<https://cwiki.apache.org/confluence/display/FLINK/FLIP-145:+Support+SQL+windowing+table-valued+function>):

```proto
message WireWindowAssignNode {
  WirePlan        child         = 1;
  string          time_column   = 2;  // must be the child's derived event-time column (§3.2)
  WindowKind      kind          = 3;  // TUMBLE, HOP, SESSION
  int64           size_micros   = 4;  // TUMBLE, HOP
  int64           slide_micros  = 5;  // HOP; size % slide == 0
  int64           gap_micros    = 6;  // SESSION
  int64           offset_micros = 7;  // alignment origin; default 0 (the epoch)
  repeated string session_keys  = 8;  // SESSION: sessions are per key
}
```

- **It adds three columns:** `window_start`, `window_end` and `window_time = window_end − 1 µs`, all of the time
  column's type. `window_time` is the event time of the window's rows downstream, so a cascaded 1-minute → 1-hour
  window puts the row for `[59:00, 60:00)` in the hour that contains it, not the next one. Nothing else in the algebra
  changes: a window aggregate is an AGGREGATE whose group keys include `window_start` and `window_end`; a window join
  is a JOIN on them; a window top-N is a PARTITION_TOPN partitioned by them.
- **TUMBLE** puts each row in one window: `window_start = offset + floor((ts − offset) / size) * size`.
- **HOP** puts each row in `size / slide` windows, so the node multiplies rows.
- **SESSION** windows merge; a session's end is known only once `W ≥ last_ts + gap`. Only a window aggregate may
  consume one (`PLAN_SESSION_WINDOW_UNAGGREGATED`). The first streaming contract version refuses SESSION (decision D9);
  the fields are reserved for it now so that the message does not change later.
- **It is not `OVER()`.** SQL analytic windows (`WireWindowFn`, PARTITION_BY) are unchanged and refused on unbounded
  input (§3.3).

**Tags.** `optimized_plan.md` §5.2 gives the exchange engine tag 18 and the UDF nodes tags 19 and 20
(`PLAN_TAG_COUNT` 21); `optimized_plan_sources.md` gives `index_lookup` and `expand` engine tags 21 and 22 (`PlanTag`
22 and 23, `WirePlan` arms 23 and 24; `PLAN_TAG_COUNT` 23). The window-assign node is therefore engine tag 23,
`PlanTag` 24, `WirePlan` arm 25, and the upsert materializer and normalize node of §3.4 take the two after it. If the
specs before it change their numbers, these move with them; the corpus enum tests catch a collision.

#### 2.2.4 Changelog kind

Every relation has a **changelog kind**, which says how its rows relate over time:

| Kind | Rows mean | Example |
|---|---|---|
| `INSERT_ONLY` | Every row is a new fact, never revised. | A topic scan; a filter over it; a window aggregate emitted once its window closes. |
| `UPSERT(key)` | A row replaces the row with the same key; a delete row removes it. | An unwindowed aggregate keyed by its group. |
| `RETRACT` | A row either inserts a row or retracts an earlier identical one. | A join of two updating inputs. |

Every bounded plan is `INSERT_ONLY` throughout, which is what every plan means today.

**Semantics: a Z-set per epoch.** The changes a relation emits in one epoch (§4.3) are a multiset of rows with
weights, and their order within the epoch carries no meaning (DBSP, Budiu et al.). This matters because morsels are
reordered across workers (`streaming_source.mojo:17-22`): "last write wins" inside an epoch would depend on that
order. So every operator that emits an updating relation **consolidates** at the epoch barrier: equal rows' weights are
summed, zero-weight rows dropped, and under `UPSERT(k)` at most one row per key per epoch remains (the net change).

**Representation.** A relation that is not `INSERT_ONLY` carries one extra column, `_change: int8`, in its
`output_schema`: `+1` inserts (or upserts), `−1` deletes (or retracts). After consolidation an update is a `−1, +1`
pair under `RETRACT` and a single `+1` under `UPSERT`. Inside an operator the weight representation is the host's
choice; at an exchange and at a sink it is the consolidated `int8`. A union of two relations of one kind is their
concatenation. Mapping to Flink's four `RowKind`s at a sink is possible, but `UPDATE_BEFORE` and `DELETE` both become
`−1` and the before/after pairing is not kept; decision D2 compares the two.

In the logical plan the kind is **derived** by the rules of §3.4. The user states a kind only at the sink (§2.2.6).

#### 2.2.5 Emit policy and lateness

A window aggregate, and any other node that revises its output, carries an emit policy:

```proto
message WireEmitPolicy {
  EmitMode   mode                    = 1;  // ON_WINDOW_CLOSE (default), ON_UPDATE
  int64      early_every_micros      = 2;  // ON_WINDOW_CLOSE only: early firings in processing time; 0 = none
  int64      allowed_lateness_micros = 3;  // L >= 0
  LatePolicy late                    = 4;  // DROP (default), SIDE_OUTPUT
}
```

- **`ON_WINDOW_CLOSE`** emits a window's row when `W ≥ window_end`. With `L = 0` and no early firings the output is
  `INSERT_ONLY`; otherwise it is `UPSERT(group keys, window_start, window_end)`.
- **`ON_UPDATE`** emits, at every epoch, the groups that changed. The output is `UPSERT(group keys)`.
- **Late is per window.** A row is late when its window is closed for good: `window_end + L ≤ W`. That is also the
  point at which the window's state is evicted (§3.5), so a row is never dropped while its window's state exists, and
  never accepted after it is gone. For an interval join the bound is the join's horizon (§3.2). Under `DROP` a late
  row is counted and dropped; under `SIDE_OUTPUT` it goes to the `late_rows` target (§2.2.6). There is no "update
  forever" policy; that need is met by `ON_UPDATE` with a retention (§3.5).
- **A bounded plan ignores emit policy and lateness.** Each window closes at end of input with every row counted. The
  bounded form equals the consolidated union of the streaming emissions only when **no row is late by input order**:
  for every split, each row has `ts ≥ (max ts earlier in that split) − max_delay`, and no split goes idle while
  holding rows. That condition is a property of the input, not of how a host batches it, and the corpus pairs of §7
  use it.

#### 2.2.6 Sinks

`write_target` stays a field of the envelope and the header, not a node arm, because a scheduler authorizes the write
from the header alone (`optimized_plan.md` §4.1). It gains typed arms:

```proto
message WireWriteTarget {
  oneof destination {
    string          path    = 1;   // existing (COPY TO); moved into the oneof, same number
    WireIcebergSink iceberg = 10;  // {catalog, namespace, name, mode APPEND | UPSERT, key = repeated string}
    WireTopicSink   topic   = 11;  // {topic, key = repeated string, partitioner}
  }
  WriteFormat      format    = 2;  // existing; path only
  WriteCompression codec     = 3;  // existing; path only
  Delivery         delivery  = 12; // EXACTLY_ONCE (default) | AT_LEAST_ONCE (§4.4)
  WireWriteTarget  late_rows = 13; // LatePolicy SIDE_OUTPUT only; an APPEND table or a topic
}
```

Moving `path` into a oneof keeps its field number, so an existing plan decodes unchanged. The decoder refuses a target
with no destination, which is today's "empty path is refused" rule (`plan.proto:1610-1622`) generalized. `late_rows`
is a second write the scheduler authorizes on its own; it is in the header, so no body decode is needed.

**Admission rule.** The sink must accept the changelog kind of its input:

| Input kind | Iceberg `APPEND` | Iceberg `UPSERT(k)` | Topic |
|---|---|---|---|
| `INSERT_ONLY` | yes | yes | yes |
| `UPSERT(k')` | refused | yes if `k = k'`; otherwise through an upsert materializer (§3.4) | yes, keyed by `k'`, with tombstones for deletes |
| `RETRACT` | refused | yes, through an upsert materializer keyed by `k` | refused |

A mismatch names both kinds (`PLAN_SINK_CHANGELOG_MISMATCH`). **An Iceberg `UPSERT` sink writes a komira upsert tail**
(`persist_as(..., mode="upsert")`, `storage_stack.md`, "A broker topic persisted as an Iceberg table"), never delete files directly: `storage_stack.md` writes no
equality deletes ("Never equality deletes"), and position deletes need the previous row of every key, which the
storage stack resolves only in the roll ("The roll", step 4). The streaming sink's exactly-once is the tail commit;
the rows become visible in the Iceberg table at the tail's `target_lag`.

---

## 3. The optimized logical plan model

### 3.1 What the optimizer already pins, and the rule this document keeps

The OPTIMIZED context already pins (`optimized_plan.md` §5.2, §6): `build_side`, `adaptive_allowed` and a decided
`algo_hint` on joins; `AggMode` (SINGLE, PARTIAL, FINAL); `pin_ref`, `boundedness` and `access_path` on scans;
`WireExchangeNode` (GATHER, BROADCAST, HASH, RANGE) with `partitions = 0` until the cut; join order and predicate and
projection placement; UDF placement and arms; and the header's `DeclaredNeeds`, typed snapshot pins, `plan_digest`
and `PlanAdvice`. The host applies only the named host-local rules of §5.3.

**"A decision is a node field, an estimate is advice"** (`optimized_plan.md` §5.1). A fact the host derives by a fixed
rule is not stored, as join distribution is not. That splits the streaming facts:

| Fact | Stored or derived | Why |
|---|---|---|
| Event-time column and watermark at each node | Derived (§3.2), except a join's output time column | Fixed propagation rules; a join has two candidate columns, so the plan names one. |
| Changelog kind of each node | Derived (§3.4) | Fixed per contract version. |
| Normalize and upsert-materializer nodes | **Stored** as nodes (§3.4) | They hold state. |
| Streaming form of a stateful operator | **Stored** (§3.3) | One logical node can legally take two forms with different state layouts. |
| State identity, format, schema and retention | **Stored** (§3.5) | Must stay stable across builds and plan versions. |
| Keyed exchange and key groups | **Stored** (§3.6) | Fixes how state is partitioned for the plan's life. |

### 3.2 Watermark propagation

The rules are fixed per `optimizer_contract_version` (`optimized_plan.md` §9.3), so a host derives the watermark the
producer did. The producer refuses a plan in which a stateful node that needs a watermark gets none.

| Node | Output event-time column | Output watermark |
|---|---|---|
| Scan with `WireEventTime` | the declared column | per split, minimum over splits not idle (§2.2.2) |
| Filter, exchange | unchanged | unchanged; an exchange reader takes the minimum over all producers |
| Project | the column, if kept or renamed; otherwise none | unchanged while the column survives |
| Window assign | `window_time` (and the input column if kept) | unchanged |
| Window aggregate | `window_time` | `W − L` (re-fired rows then still lie at or above it) |
| Interval join `a.ts BETWEEN b.ts − x AND b.ts + y` | the side the node's `output_time_column` names | `min(W_a, W_b) − max(x, y)` |
| Window join, union, other multi-input node | the column `output_time_column` names, if every input carries one | minimum over inputs |
| UDF arm | unchanged for SCALAR, ROW, MAP_BATCHES_COLUMN; none for MAP_BATCHES_FRAME unless the UDF declares `preserves_event_time` | unchanged where the column is kept |
| Bounded input of a join | none | +infinity |

Two new fields carry the stored facts: `output_time_column` on JOIN and UNION when both inputs carry event time, and
`bool preserves_event_time` on `UdfRef` (`optimized_plan_udfs.md` §10.3, "`UdfRef`"; a new field there; amendment A3).

**Early firings are not a watermark source.** An early-fired row has `window_time ≥ W`. A window aggregate whose input
contains early firings is refused (`UNBOUNDED_WINDOW_OVER_EARLY_FIRING`), so a downstream window never sees one.

Watermarks move **out of band, at epoch barriers**, never on a morsel (`streaming_source.mojo:17-22`).

### 3.3 Which operators may read unbounded input

`optimized_plan.md` §5.2 refuses "an operator that must read all of an unbounded input before it emits" unless the
contract version admits a streaming form. The first streaming contract version admits the forms below. Every refusal
uses the token `OPTIMIZED_UNBOUNDED_INPUT_UNSUPPORTED` (as `optimized_plan_udfs.md` §10.10 does) with a **reason** in
its detail, listed in the last column, so a test asserts on the reason.

| Logical node over unbounded input | Streaming form (`StreamForm`) | State | Output kind | Refusal reason |
|---|---|---|---|---|
| Scan, filter, project, window assign | `STATELESS` | none | the input's | — |
| Union | `STATELESS` | none | §3.4 rule 3 | — |
| SCALAR, ROW, MAP_BATCHES_COLUMN UDF; ungrouped MAP_BATCHES_FRAME over `INSERT_ONLY` | `STATELESS` | none (worker state is not checkpointed, `optimized_plan_udfs.md` §10.10) | the input's | `UNBOUNDED_FRAME_ON_CHANGELOG` |
| PARTIAL aggregate below a FINAL | `EPOCH_PARTIAL`: pre-aggregates one epoch, flushes at its barrier | none across epochs | the input's | — |
| Aggregate grouped by `window_start, window_end` (plus keys), input with a watermark | `WINDOW_AGG` | per (key, window); evicted at `W ≥ window_end + L` | §2.2.5 | — |
| Aggregate with no window | `UPDATING_AGG` | per key | `UPSERT(group keys)` | `UNBOUNDED_AGG_NO_WINDOW` unless a retention is declared (§3.5) |
| Mergeable `AGG_UDF` | the form of its aggregate | its Arrow state | as that aggregate | — |
| Plain `AGG_UDF`; grouped MAP_BATCHES_FRAME | none | — | — | `UDF_AGGREGATE_UNBOUNDED_GROUP`, `UNBOUNDED_FRAME_GROUPED` |
| Join with one side bounded and pinned: INNER; LEFT, SEMI or ANTI with the stream as probe and preserved side | `LOOKUP_JOIN` | none keyed; the build side is rebuilt from its pin (§4.4) | the probe side's | `UNBOUNDED_LOOKUP_OUTER_BUILD` for FULL, or an outer join preserving the bounded side, which would have to emit unmatched build rows at the end of a stream that has none |
| `index_lookup`, `expand` with an unbounded probe or seed | `LOOKUP_JOIN` | none beyond the pinned index | the probe side's | — (`optimized_plan_sources.md` §15.8.2) |
| Inner join of two unbounded inputs with `a.ts BETWEEN b.ts − x AND b.ts + y` | `INTERVAL_JOIN` | both sides; evicted by watermark | `INSERT_ONLY` | — |
| Inner join of two unbounded inputs on `window_start, window_end` | `WINDOW_JOIN` | per window; evicted by watermark | §3.4 rule 4 | — |
| Any other join of two unbounded inputs | `UPDATING_JOIN` | both sides | `RETRACT` | `UNBOUNDED_JOIN_UNBOUNDED_STATE` unless a retention is declared |
| PARTITION_TOPN partitioned by window | `WINDOW_TOPN` | per window | §2.2.5 | — |
| Sort; Limit; TopN with no window; PARTITION_BY / `OVER()`; Distinct with no window | none | — | — | `UNBOUNDED_SORT`, `UNBOUNDED_LIMIT`, `UNBOUNDED_TOPN`, `UNBOUNDED_ANALYTIC_WINDOW`, `UNBOUNDED_DISTINCT_NO_WINDOW` |
| ASOF join with an unbounded side; access path on an unbounded scan | none | — | — | `UNBOUNDED_ASOF`, `ACCESS_ON_UNBOUNDED` (`optimized_plan_sources.md` §15.8.2) |
| Correlated subquery over an unbounded relation | none | — | — | `UNBOUNDED_SUBQUERY` |

**`StreamForm stream_form` is a node field** on AGGREGATE, JOIN and PARTITION_TOPN. (It is not called a "variant",
because `optimized_plan.md` §5.3 rule 6 already uses "operator variant" for a host's choice within an algorithm.)
OPTIMIZED requires it when the node has an unbounded input and refuses it otherwise (`OPTIMIZED_STREAM_FORM_MISSING`,
`OPTIMIZED_STREAM_FORM_ON_BOUNDED`). The host checks that the form is legal for the node's shape and inputs, as it
checks `(join type, build side)` pairs. The admitted set belongs to the contract version and only grows; a later
version may admit a temporal join (a versioned table read as of each row's event time) and outer stream-stream joins.

**A streaming plan refuses `adaptive_allowed`** on every exchange and every join (`OPTIMIZED_STREAM_ADAPTIVE`).
Adaptive changes happen at sealed stage boundaries (`optimized_plan.md` §8.3), and a continuous plan has none;
rescaling at a savepoint replaces them.

### 3.4 Changelog derivation

Fixed per contract version:

1. A scan takes its kind from its source kind and params. Every source kind of `optimized_plan_sources.md` §15.4 read
   as unbounded is `INSERT_ONLY` today. An upsert-mode topic table or a row-store change feed read as an `UPSERT(key)`
   stream is **new**, not specified there (§15.4.3, §15.4.4), and is left to the spec that defines those kinds.
2. Filter, project, window assign and the stateless UDF arms keep their input's kind.
3. Union of inputs of one kind keeps it (for `UPSERT`, only with equal keys). Any other union (different upsert keys,
   or `INSERT_ONLY` with `UPSERT`) needs every `UPSERT` input normalized first (below), and is then `RETRACT`.
4. `WINDOW_AGG` and `WINDOW_TOPN` over `INSERT_ONLY` are `INSERT_ONLY` under `ON_WINDOW_CLOSE` with `L = 0` and no
   early firings, and `UPSERT(keys, window)` otherwise. An inner `INTERVAL_JOIN` is always `INSERT_ONLY`: a late match
   is a new row, never a revision. A `WINDOW_JOIN` is `INSERT_ONLY` with `L = 0` and `RETRACT` otherwise, because a
   join output has no key to upsert on.
5. `UPDATING_AGG` is `UPSERT(group keys)`. Over a `RETRACT` input each aggregate function must be invertible (count,
   sum) or keep a multiset of its inputs (min, max); otherwise the producer refuses it
   (`UNBOUNDED_AGG_NOT_RETRACTABLE`).
6. `UPDATING_JOIN` is `RETRACT`.
7. **An `UPSERT` input to an aggregate, a join or a mixed union is normalized first.** An upsert stream does not carry
   the row it replaces, so it cannot be retracted directly. A `NORMALIZE(k)` node keeps the last row per key and turns
   each upsert into `−1 old, +1 new` (Flink's ChangelogNormalize does the same).

**Nodes the optimizer inserts and stores.**

- **`NORMALIZE(k)`**, per rule 7.
- **The upsert materializer**, wherever the sink's key differs from its input's key or the input is `RETRACT` (§2.2.6
  table). It keeps, per sink key, the rows currently live and emits net upserts on that key.

Both are stateful nodes with a `StateSpec` (§3.5) and their own plan tags (§2.2.3), not host-local rules, because they
hold state.

**Check.** The host re-derives every node's kind and refuses a body whose inserted nodes are missing, extra or keyed
wrongly (`OPTIMIZED_CHANGELOG_INCONSISTENT`). Mutants: a producer that omits the materializer below an `UPSERT(k)` sink
over an `UPDATING_JOIN`; one that marks a lateness-re-firing `WINDOW_JOIN` as `INSERT_ONLY`; one that feeds an
`UPSERT` input straight into `UPDATING_AGG`. Each must turn the check red.

### 3.5 State requirements per operator

Every node whose form holds state carries a `StateSpec`. OPTIMIZED requires it on such nodes and refuses it elsewhere:

```proto
message StateSpec {
  bytes          state_id         = 1;  // 16 bytes; stable across builds and plan versions (below)
  StateFormat    format           = 2;  // {kind: enum, version: uint32}: the canonical savepoint layout (§4.4)
  bytes          schema_digest    = 3;  // sha256 of the canonical Arrow schema of keys + accumulators
  repeated string key_columns     = 4;  // equals the HASH exchange keys below the node (§3.6)
  StateRetention retention        = 5;  // WATERMARK | TTL(micros) | UNBOUNDED_DECLARED
  uint32         key_groups       = 6;  // fixed for the plan's life; > 0 (§3.6)
}
```

**`state_id`** plays the role of a Flink operator uid: a v2 plan or a later build uses it to find v1's state.

- **Default:** the SDK derives it from the node's **logical path**: the digest of the stateful node's kind, its group
  or join keys, and the source bindings and logical operators below it. Optimizer decisions (build side, pins,
  exchanges) are left out, so the same query optimized again gets the same ids. A UDF below the node contributes its
  name, kind and signature, **not its code digest**, so a new environment image does not move the id; a changed state
  layout is caught by `schema_digest` instead.
- **Nodes with no logical node of their own** take the logical anchor plus a role: the FINAL of an aggregate split and
  an eager aggregate below a join anchor on the logical aggregate (roles `FINAL`, `EAGER`); `NORMALIZE` anchors on its
  input's path (role `NORMALIZE`); the upsert materializer anchors on the sink's identity (role `MATERIALIZE`).
- **Named:** the user may name a stateful operator (`.name("revenue_by_minute")`); the id is then the digest of the
  name plus the role. A name survives edits below the node; a derived id does not.
- **Unique** within a plan (`OPTIMIZED_STATE_ID_DUPLICATE`), and **independent of the cut**, as `optimized_plan.md`
  §9.6 already requires (its mutant: a cutter that numbers state by segment order).

**`format` and `schema_digest`.** `format` names the canonical savepoint layout of the state kind (window aggregate,
interval-join side, updating-join side, normalize, materializer) and its version; every later build reads every
released format, forever, and writes only the newest. `schema_digest` names what is in it. Adding `avg(usd)` to an
aggregate changes `schema_digest` and not `format`, so the roll check of §5.3 sees it. When a host changes how it holds
state in memory or in checkpoints, nothing in the plan changes.

**`retention`:**

- `WATERMARK`: evicted once the watermark passes the state's bound (`window_end + L`, or the interval-join horizon).
  The `WINDOW_*` and `INTERVAL_JOIN` forms require it; the others refuse it.
- `TTL(d)`: a key's state is dropped `d` after its last update, in event time if the input has a watermark and in
  processing time otherwise. `UPDATING_*`, `NORMALIZE` and the materializer admit it. It changes results (a key that
  returns after `d` starts empty), so it is set per operator in the plan, as in Flink's FLIP-292
  (<https://cwiki.apache.org/confluence/display/FLINK/FLIP-292:+Enhance+COMPILED+PLAN+to+support+operator-level+state+TTL+configuration>).
- `UNBOUNDED_DECLARED`: the user accepts unbounded growth, for example over a bounded key domain such as per-country
  totals. It is admitted and visible in the header.

**Header summary.** `DeclaredNeeds` gains `repeated StateNeed state` (`{state_id, format, schema_digest, retention
kind, key_groups}`, sorted by id), checked against the body (`OPTIMIZED_NEEDS_STATE_MISMATCH`). A scheduler checks a
roll's state mapping (§5.3) from the two headers alone, without decoding a body.

### 3.6 Exchanges for keyed state

- **A keyed stateful node sits above a `HASH` exchange whose keys are a non-empty subset of its group or join keys,**
  and `StateSpec.key_columns` equals those exchange keys (`OPTIMIZED_STATE_PARTITIONING`). The §6 example hashes a
  window aggregate on `category` alone, which keeps every window of one category on one host; a plan that needs more
  parallelism than the key domain gives hashes on more of the keys.
- **The exchange is in the plan even for one host.** `optimized_plan.md` §8.2 places exchanges only when
  `host_count_max > 1`. A keyed stateful node in a streaming plan always has its `HASH` exchange in OPTIMIZED; the cut
  elides it at one host (§8.1), and the state is still laid out by key group, so a single-host run can be rescaled.
  Amendment A2 (§8).
- **Key groups.** Keys hash into `key_groups` buckets (Flink's max parallelism). `WireExchangeNode` and
  `ExchangeEdge` gain a `key_groups` field (amendment A2), and every `HASH` exchange feeding one stateful node shares
  its `key_groups` and `key_encoding`. **The key → group function is frozen per contract version**: the hash function,
  its seed and the key encoding. Otherwise a savepoint written by one build is routed wrongly by another. Each host
  owns a contiguous range of groups; the cut fills `partitions` with the host count; the producer refuses
  `host_count_max > key_groups` (`OPTIMIZED_KEY_GROUPS_TOO_FEW`).

### 3.7 The deterministic segment cut

The coordinator cuts a streaming plan as it cuts a bounded one (`optimized_plan.md` §8.2): every exchange becomes an
edge, a sink leaf is added below and a scan above, `partitions` is filled in, and no decision changes. In a streaming
plan an edge is bound to a **streaming exchange**, sealed per epoch (§4.3); in a bounded plan, to a batch shuffle. The
plan's derived boundedness selects which. State ids, key groups and forms are plan fields, so a re-cut by a new build
addresses the same state.

---

## 4. The physical plan model

### 4.1 What exists

- **On `main`:** a copy of an earlier engine's physical IR at `PHYSICAL_PLAN_IR_VERSION = 13`, whose emitter and
  consumer are, in the file's words, "neither ... in this tree" (`src/komira_plan_ir/physical_plan.mojo:5-6`, `:62`);
  `komira_pplan_wire`, a deterministic byte format for one shape (`PROJECT? -> FILTER* -> SCAN(parquet)`);
  `komira_pplan` and `komira_pplan_chain`, compiled verb chains for a grouped aggregate over a filtered Parquet scan;
  and the streaming source, sink and exchange contracts (§4.3).
- **The IR's shape:** a segment is a source, morsel operators, then a sink. Sources: PARQUET, BATCH, SINK_OUTPUT,
  CONCAT. Operators: FILTER, PROJECT, LIMIT, JOIN_PROBE. Sinks (the breakers): AGG, SORT, TOPN, COLLECT, HASH_BUILD,
  PARTITION_BY, PARTITION_TOPN, SMJ_BUILD, ASOF_JOIN. A segment also carries dependencies with edge tags (fuse,
  incremental ingest, publish-and-wait, partition-wise, scheduling only), `partition_count`, a combine-order key that
  makes float folds deterministic, and memory and cardinality estimates.
- **It is not self-contained.** In-memory batches, sink parameters, operator payloads (whole logical subtrees),
  file-system descriptors and the cancel and error slots are indices into tables the driver owns. The Parquet arm
  carries only part of its source.
- **The earlier engine's lowering re-runs optimizer passes** on every breaker subtree. That breaks "hosts never
  re-optimize" and must not be ported.

### 4.2 The model: a self-contained physical IR and deterministic lowering

**Lowering is a function:** `lower(segment, host_profile, resolved_inputs) -> PhysicalPlan`, plus a recorded log of
the adaptive changes of `optimized_plan.md` §8.3 applied at runtime.

- `host_profile`: the engine build, thread count, memory budget, spill tiers and the host's policy for the named
  host-local rules.
- `resolved_inputs`: what the host-local rules read from data: the verified footers that payload narrowing and scan
  sharing use, and the value `SCALAR_FOLD` computes (`optimized_plan.md` §5.3, rules 2-4).

Equal inputs give byte-equal output. A host never reads producer statistics, never reorders and never changes a
stream form. Two hosts of one build produce the same physical plan only under equal profiles and inputs; the corpus
render check (§7) therefore lowers every segment under one fixed profile.

**The IR** is plain data, with no pointers, no closures and no indices into driver tables:

| Element | Contents |
|---|---|
| `Pipeline` | One source, a chain of streaming operators, one sink (a breaker or an output); its own memory budget and partition range. |
| Source | A scan of pinned files (the complete source description), an exchange read, the output of another pipeline, or a UDF STEP. |
| Streaming operators | Filter, project (including UDF arms bound to a runtime), hash probe, window assign, lookup and index probe, `_change` handling. |
| Breakers | Aggregate (SINGLE/PARTIAL/FINAL), sort, top-N, hash build, partition-by, partition-top-N, sort-merge build, asof; in streaming, also the stateful forms of §3.3. |
| Exchange | Write and read side, kind, keys, key encoding, key groups, partition count. |
| Morsel policy | Rows per morsel, chosen by the host and recorded. |
| Spill | Per breaker: whether it may spill, and to which tiers. Spill is never a checkpoint. |
| Dependencies | Edges between pipelines, with the edge kinds above, and the combine order for deterministic folds. |
| Streaming (§4.3) | The epoch lifecycle of each stateful breaker, the state binding per `state_id`, the sink protocol, the watermark wiring. |

**Self-contained means closed over** `(segment bytes, content-addressed blobs verified by digest, environment image)`,
with no table that a driver owns. It cannot mean "no other input": large file lists already travel as a manifest
object referenced by digest (`optimized_plan.md` §6.2), and UDF code lives in the image. A physical form may fill
`OptimizedSegment` field 11 only when it meets this definition. Decision D7 recommends building the IR to it from the
first commit.

**The batch driver** runs the pipelines in dependency order on morsels, with exchange edges between hosts.

### 4.3 The streaming form

**The driver.** A plan with an `UNBOUNDED` scan runs under the streaming driver, which executes the same physical plan
in **epochs**, coordinated per plan. One epoch:

1. **Open.** The coordinator assigns epoch `E`.
2. **Ingest.** Each source polls up to its epoch budget (rows, bytes or processing time; host-local, with a floor so
   per-epoch setup does not dominate). Stateless operators run unchanged; each stateful breaker's `Sink` updates
   thread-local state.
3. **Barrier.** Each source records its end position for `E` and emits the end of the epoch. Downstream of an
   exchange, a reader sees epoch `E` only once every producer has sealed it: `komira_shuffle_streaming` already works
   this way (a write sink seals an epoch; a read source returns Idle until it is sealed; `EpochCursor`,
   `src/komira_shuffle_streaming/shuffle_streaming_source.mojo:98`). The seal is the barrier, so alignment happens per
   exchange with no in-band marker.
4. **Log.** The coordinator writes the epoch's **offset-log entry** durably, before any output of `E` is committed:
   each split's `[lo, hi)`, each split's idle decision, the early-firing decisions, the processing-time clock reading
   used by TTL and early firings, and each source's watermark, from which `W_E` at every node follows by §3.2. This is
   the "offset-log-ahead-of-commit-log" invariant the sink contract already names (`src/komira_morsel/streaming_sink.mojo:31-41`).
5. **Combine, fire, evict.** Each stateful breaker runs `Combine(E)` (merging every thread's local state for `E`;
   without it a window fires with part of its rows), then `Fire/Evict(W_E)`: emit every window with
   `W_E ≥ window_end`, re-fire windows revised within lateness, evict state past its retention, and consolidate the
   epoch's output (§2.2.4). This per-epoch lifecycle replaces a batch breaker's one-shot Finalize.
6. **Snapshot and commit.** Each stateful operator snapshots its state for `E` (every epoch or every N, §4.4); each
   sink pre-commits. Once every participant acknowledges, the coordinator appends the commit-log entry for `E`, sinks
   commit and sources advance.

**What is deterministic, and what is not.** Replay reads the offset log and never re-derives a boundary, an idle
decision, a clock reading or a watermark. So replaying a logged epoch reprocesses the same input ranges under the
same `W_E`, and, because an epoch's output is a consolidated Z-set (§2.2.4) and float folds follow the combine order
keyed by `(epoch, producer)`, produces the same rows. Not deterministic across **runs**: which rows are late depends on
the epoch budget unless the input meets the order condition of §2.2.5. Not deterministic at all: a `VOLATILE` UDF
(`udf_runtime_interface.md` §3.1, `stability`) and processing-time choices made fresh. Two rules follow:

- **Exactly-once does not rely on determinism.** Exchange segments are scoped per attempt, and the sink commits each
  epoch once, keyed by its commit id (§4.4). A replay of an epoch that was never committed may differ from the lost
  attempt, and nothing saw that attempt.
- **A plan with a `VOLATILE` UDF or a processing-time trigger checkpoints at every committed epoch**, so recovery never
  recomputes a committed epoch, and its sinks must be `TRANSACTIONAL`, not `IDEMPOTENT` (whose duplicate collapse
  needs equal rows; `streaming_sink.mojo:93-99`).

**Limit.** The barrier is global per plan, so one slow partition holds back every epoch. That is a latency limit of
this design, not a correctness one.

**The exchange today.** `komira_shuffle_streaming` carries Int64 `(key, value)` rows only, and its exactly-once
relies on byte-identical rewrites. Before it can carry these plans it needs Arrow bodies (including `_change`) and
attempt-scoped epoch segments: one object per producer, epoch and attempt, the reader taking the committed attempt.

### 4.4 State, checkpoints, savepoints and sinks

**State backend.** Host-local: keyed state per `(state_id, key_group)` in memory, spilling to local disk. **Durable
state lives in the user's bucket**, like every durable byte in the storage stack (`storage_stack.md`, "Permissions the
user grants"). The root is a run parameter, not a plan field:

```
{state_root}/{run}/g{generation}/log/offsets/{E}                                   offset log (§4.3)
{state_root}/{run}/g{generation}/log/commits/{E}                                   commit log
{state_root}/{run}/g{generation}/checkpoints/HEAD                                  CAS-advanced manifest pointer
{state_root}/{run}/g{generation}/checkpoints/e{E}/{state_id}/{group_range}.*        build-local, incremental
{state_root}/{run}/g{generation}/savepoints/e{E}/manifest                          canonical, versioned
{state_root}/{run}/g{generation}/savepoints/e{E}/{state_id}/{group_range}.arrow    canonical, with a per-group offset index
{state_root}/{run}/g{generation}/staged/e{E}/{sink}/{host}                         pre-committed file lists
```

| | Checkpoint | Savepoint |
|---|---|---|
| Purpose | Recover the same run on the same build | Roll v1 → v2, engine upgrade, rescale, stop and resume |
| Format | Host-native; may be incremental | Canonical: Arrow IPC per `(state_id, key-group range)` in the `StateSpec.format` layout, with an index from key group to offset (one object per group would mean up to `key_groups` objects per state) |
| Readers | The same engine build | Every later build, and a plan that maps the `state_id` with an equal `schema_digest` or a declared migration (§5.3) |
| When | Every epoch or every N epochs (host-local), and every committed epoch under §4.3's rule | On request, and as the first step of every roll |
| Manifest | **Required**, advanced by compare-and-swap on `HEAD`, as the sink contract requires (`streaming_sink.mojo`, `StreamingMorselSink`, `:170`) | Required |

Both manifests record: format version, generation, epoch, source positions per split, **each split's watermark-tracker
state** (max event time seen and idle flag) and `W_E` (otherwise `W` falls back after a restore and rows that were
late before the crash are accepted on replay), sink commit tokens, the `state_id → (format, schema_digest,
key_groups)` map, the plan digest and the engine build. Flink draws the same line between checkpoints and savepoints
(<https://nightlies.apache.org/flink/flink-docs-master/docs/ops/state/checkpoints_vs_savepoints/>).

**Lookup state.** A `LOOKUP_JOIN` holds no keyed state; on recovery the host rebuilds its build side from the pin. A
pinned snapshot can be expired by the table's maintenance (on S3 Tables expiry keeps one snapshot,
`storage_stack.md`, "Maintenance"), and then a rebuild is impossible. Decision D13: each savepoint also stores the
build side in canonical form, and a restore uses it when the pin is gone. The dimension table never refreshes during
a run; a refresh is a roll that re-pins it, and a temporal join is a later stream form.

**Exactly-once into Iceberg: one committer, one commit per epoch.**

- During epoch `E`, each host writes Parquet data files to the table's location and, at pre-commit, stages their list
  under `staged/` and returns a token that names it (today's `CommitToken.txn_handle` is a `UInt64`,
  `streaming_sink.mojo:62-80`; it carries a staged-list id, not the list).
- **One committer per sink**, on the coordinator, gathers every host's staged list and makes **one Iceberg snapshot**
  through the catalog with `assert-ref-snapshot-id`, putting `komira.commit-id = (run, generation, E)` and
  `komira.generation` in the summary, and setting `komira.writer.<writer-id>.last-commit` in the same `commit_table`
  (`storage_stack.md`, "The commit client", steps 2-4). N hosts committing would conflict on the ref and rebase N
  times.
- **On recovery** the committer reloads and compares `last-commit` with its token by order within the generation
  (`≥ E` means done), not by equality, because epochs may be grouped.
- **Grouping.** The committer may group epochs into one commit, with the group's last epoch as the commit id, and
  keeps a minimum interval between commits (a host-local floor). Small commits grow `metadata.json`, and S3 Tables
  fails operations past 50 MB (`storage_stack.md`, "The catalog seam", *to confirm*).
- **Only on tables komira created.** The `last-commit` property exists only there (`storage_stack.md`, "What
  komira writes into an Iceberg table": on other tables komira writes no property). Elsewhere an expired commit cannot be told from a lost
  one, so exactly-once is refused there unless the target declares `AT_LEAST_ONCE` (`PLAN_SINK_NOT_EXACTLY_ONCE`).

**Exactly-once into a topic.** The topic sink writes each epoch's records under a producer id whose producer epoch is
the run's generation, and marks them committed when `E` commits; a reader at read-committed isolation sees only
committed epochs. The record model keeps producer id, epoch, sequence and transaction markers (`storage_stack.md`,
"Record fidelity"). *Inferred:* this needs the broker's transactional produce path; without it a topic sink is
`AT_LEAST_ONCE` and readers de-duplicate by sequence.

**Delivery is a plan field.** A sink with no exactly-once protocol, or a non-replayable source, is refused unless the
write target declares `delivery = AT_LEAST_ONCE` (`PLAN_SINK_NOT_EXACTLY_ONCE`). The sink contract today makes the
same case a **loud plan-time downgrade**, "ALO as downgrade, NOT a mode" (`streaming_sink.mojo:101-119`,
`streaming_source.mojo:270-276`). This document reverses that: at-least-once becomes a declared mode, so a plan shows
its guarantee before it runs. Decision D11.

**UDF state.** Under ABI 1.0 a worker's state does not survive a restart; a mergeable `AGG_UDF`'s Arrow state is
checkpointed (`optimized_plan_udfs.md` §10.10). Snapshotting a callable's own state needs the ABI 1.1 entries
`snapshot` and `restore` (`udf_runtime_interface.md` §8.1, "Candidates for ABI 1.1").

### 4.5 Recovery and rescale

- **Recovery.** A failed host or run restarts from the checkpoint `HEAD` names, on the same build: sources `seek` to
  the recorded positions (`streaming_source.mojo:362`), watermark trackers and state load per key group, sinks
  `restore_from` their tokens, every exchange starts a new attempt namespace, and the epochs after the checkpoint
  replay from the offset log. Epochs the commit log shows committed are recomputed only to rebuild state, and their
  sink output is skipped by commit id.
- **Engine upgrade.** Stop with a savepoint, then start the same `OptimizedPlan` on the new build from it. The new build
  re-derives the cut (`optimized_plan.md` §9.6) and reads the canonical state.
- **Rescale.** Only at a savepoint: the new host count reassigns key-group ranges, and state moves group by group; a key
  never changes group (§3.6). A host count above `needs.resources.host_count_max` is not a rescale but a roll,
  because that value is in the plan digest. Changing `key_groups` is a state migration (§5.3).

### 4.6 Versioning of the physical IR

The IR never crosses builds, so a version number guards nothing a build digest does not. Today's canary is bumped by
hand on every field or variant change (`physical_plan.mojo:31-55`), and a forgotten bump is silent: in the earlier
engine two separately built libraries exchanged these records across an FFI boundary and corrupted memory with no
diagnostic. Recommendation (D8): check the **engine build digest** at such a boundary, as `OptimizedSegment.engine_build`
does, and keep the constant only as a render label. When field 11 arrives, its format tag carries the build, and a host
of a different build refuses it (`OPTIMIZED_SEGMENT_BUILD_MISMATCH`).

---

## 5. The run protocol a scheduler drives

A scheduler is not part of komira (`optimized_plan.md` §2). This section fixes the protocol between any scheduler and
the coordinator; how a scheduler exposes it, gates it or bills it is the scheduler's business.

### 5.1 Starting a run

A run starts from an `OptimizedPlan` and its environment image, never SQL or a bound plan, so nothing downstream
optimizes. The scheduler reads the header only (`optimized_plan.md` §4.1, §10.11). **Run options are outside the
digest:** the start position of each unbounded source (`EARLIEST`, `LATEST`, a timestamp, or a savepoint), the state
root, the host count (at most `needs.resources.host_count_max`) and the checkpoint cadence. If `needs.unbounded` is
false the run is **bounded** and ends with the plan; if true it is **continuous** and ends only when stopped or rolled.
The header bit decides; there is no run-kind field.

### 5.2 Operations on a continuous run

| Operation | Meaning |
|---|---|
| `status` | Generation, last committed epoch, watermark per source, backlog per exchange (epochs sealed but not read), state bytes per `state_id`, late-row counts. |
| `savepoint` | Write a canonical savepoint at the next barrier and keep running; return the manifest reference. |
| `stop [--savepoint]` | Stop opening epochs after the next barrier, commit it, optionally write a savepoint, release the hosts. **It does not flush windows**: open windows are saved as state, so they are neither emitted early nor emitted twice after a resume. A run stopped without a savepoint loses its open windows. |
| `start --from-savepoint` | Start a run whose start position is a savepoint. |
| `rescale` | Savepoint, then start with a new host count (§4.5). |
| `roll` | Replace plan v1 with v2 (§5.3). |

### 5.3 The roll v1 → v2, and its fence

**Generations.** Every run has a generation `g`, recorded in its state root and stamped on every commit (§4.4). A
generation is never revived: v2 runs as `g+1`, and a rollback runs v1's plan as `g+2`.

1. **Preflight**, from the two headers (`needs.state`). Each `state_id` of v1 maps to one of: `KEEP` (same id, a
   format v2's build reads, **equal `schema_digest`**); `MAP(m)`, where `m` is one of a fixed list in the first
   version, namely "change `key_groups`" and "drop a measure"; or `RESET` (start empty, stated explicitly; the
   preflight report names the open windows that a reset discards). An added measure is a `RESET` in the first version
   (decision D14). The roll is refused, with v1 untouched, if an id is unmapped, a `KEEP` fails its check, v2's build
   cannot read v1's manifest version, or a source's retention is shorter than the rollback window.
2. **Warm.** v2's hosts are placed and its image loaded. v2 reads nothing and claims no source split.
3. **Barrier at `E`.** v1 stops after `E` and commits it. Windows are not flushed.
4. **Savepoint at `E`.**
5. **Fence.** v2's first act at each sink is a **fencing commit**: an empty snapshot whose summary carries
   `komira.generation = g+1` (and, on tables komira created, the property `komira.writer.<sink>.generation`). Every
   committer, after each reload, refuses to commit if the latest generation it finds on the table is newer than its
   own. Because every commit asserts the ref's snapshot id, the check and the commit are atomic: a v1 process still
   running after the fence (a zombie) gets a conflict, reloads, sees `g+1` and stops, instead of rebasing its append
   as the commit client otherwise would (`storage_stack.md`, "The commit client", step 3). A topic sink fences by
   producer epoch. *To confirm per catalog:* that an empty fencing snapshot is accepted.
6. **Audit.** Until v2 passes the scheduler's gates, its output must not be irreversible:
   - on an Iceberg table komira created (and not on S3 Tables, where a user branch breaks snapshot management,
     `storage_stack.md`, "Maintenance"), v2 commits to a branch, `komira-roll-g{g+1}`, and the gates read it;
   - elsewhere, v2 holds its epochs pre-committed (staged, not committed) while gates run on v2's own health; a check
     that must read v2's output reads a shadow sink the roll names;
   - a topic sink keeps v2's transactions open.
7. **Promote or roll back.** On success, the main ref is fast-forwarded to the branch (or the held epochs commit in
   order) and v1's resources are released. On failure, **v2 is parked, and v1 is kept**: nothing v2 wrote reached the
   main ref, so v1's plan resumes as generation `g+2` from savepoint `E`. Whether that resume is automatic or waits for
   an operator is the scheduler's choice; the protocol supports both, and the default is to wait.

No epoch is committed to a sink's main ref by two generations: the fence decides who may commit, and the audit step
keeps v2's epochs off the main ref until v1 can no longer resume.

---

## 6. Worked example

**The query.** A topic `events(user_id, item_id, amount: decimal(12,2), ts: timestamp[us, UTC])` joined to the Iceberg
dimension table `items(item_id, category)`; a Python scalar UDF `fx(amount, category) -> float64` normalizes the
amount; the result is aggregated per category per 1-minute tumbling window and written to the komira-created Iceberg
table `revenue_by_minute`.

```python
ev = kx.topic("events", table="lake.events").with_watermark("ts", delay="10s")    # unbounded=True for streaming
it = kx.iceberg("lake.items")
q = (ev.join(it, on="item_id")
       .with_columns(usd=fx(col("amount"), col("category")))
       .window(tumble("ts", "1m"))
       .group_by("window_start", "window_end", "category")
       .agg(revenue=sum("usd"), n=count())
       .emit(on="window_close", allowed_lateness="0s"))
q.write_iceberg("lake.revenue_by_minute", mode="append").name("revenue_by_minute")
```

### 6.1 Logical (RAW): one field differs between the two forms

```
WriteTarget: iceberg lake.revenue_by_minute APPEND, delivery EXACTLY_ONCE
AGGREGATE keys=[window_start, window_end, category] aggs=[sum(usd), count()]
          emit={ON_WINDOW_CLOSE, lateness=0, late=DROP}
└ WINDOW_ASSIGN TUMBLE(ts, 1m)                 → +window_start, +window_end, +window_time
  └ PROJECT [*, usd = UdfApply(fx#0, amount, category)]
    └ JOIN INNER on item_id
      ├ SCAN komira.broker.topic events (+table lake.events)
      │      boundedness = BOUNDED | UNBOUNDED      ← the only difference
      │      event_time = {ts, BOUNDED_OUT_OF_ORDERNESS, 10s}
      └ SCAN komira.iceberg.table lake.items   boundedness = BOUNDED
needs.udfs = [fx: SCALAR, runtime komira/python, (decimal, utf8) -> float64]
```

Derived: the events scan is `INSERT_ONLY` with watermark `max(ts) − 10s`, held per partition until its history is
read; the join keeps `ts` (one side carries event time), and its watermark is the events watermark, because `items` is
bounded (+infinity).

### 6.2 Optimized

**Bounded form** (`needs.unbounded = false`): the events scan pins each partition's span with the table snapshot;
`items` pins an Iceberg snapshot (`optimized_plan_sources.md` §15.3); the join has `build_side = RIGHT`,
`algo_hint = HASH` and a `BROADCAST` exchange on items; `usd` is computed above the join (`optimized_plan_udfs.md`
§10.9); the aggregate is `PARTIAL`, a `HASH` exchange on `category`, then `FINAL`. No stream forms, no `StateSpec`, no
emit behaviour; window assign is just computed columns.

**Streaming form** (`needs.unbounded = true`):

- **Pins.** The events scan pins the stream (identity and schema); the start position is run state. `items` stays
  pinned for the run (`optimized_plan_sources.md` §15.8.2).
- **Join.** `LOOKUP_JOIN`, INNER, stream as probe, `build_side = RIGHT`, `BROADCAST` of items. No keyed state.
- **Aggregate.** `PARTIAL` with `stream_form = EPOCH_PARTIAL`, then a `HASH` exchange on `category` with
  `key_groups = 128`, then `FINAL` with `stream_form = WINDOW_AGG` and
  `StateSpec{state_id = digest("revenue_by_minute", FINAL), format = WINDOW_AGG v1, schema_digest = digest(category,
  window_start, window_end, sum: float64, count: int64), key_columns = [category], retention = WATERMARK,
  key_groups = 128}`. The exchange keys are a subset of the group keys, as §3.6 allows.
- **Changelog.** `INSERT_ONLY` throughout (`ON_WINDOW_CLOSE`, `L = 0`), so the Iceberg `APPEND` sink is admitted.
- **Header.** `needs.unbounded = true`, `needs.state = [{revenue_by_minute/FINAL, WINDOW_AGG v1, schema_digest,
  WATERMARK, 128}]`.

### 6.3 Physical (two hosts)

**The cut** gives three segments: **S0** (each host) items scan → hash build, behind the broadcast edge; **S1** (each
host) events splits → hash probe → project with `fx` → window assign → epoch-partial aggregate → hash exchange write on
`category`; **S2** (host 1 owns key groups 0-63, host 2 owns 64-127) exchange read → final window aggregate → Iceberg
sink, with the committer on the coordinator.

**Bounded form.** S0, S1 and S2 run once; the final aggregate emits every window at end of input; one commit.

**Streaming form, epoch `E`.**

1. **Ingest and barrier.** S1 polls events to its budget, probes the resident items table, calls `fx` through the
   Python runtime in any of the three modes with no plan field changing, flushes its epoch-partial state into the
   exchange and seals `E`.
2. **Log.** The coordinator logs each partition's offsets, idle flags and watermark; `W_E` is their minimum.
3. **Combine, fire, evict.** S2 reads `E` once both producers sealed it, combines thread-local state, fires every
   `(category, minute)` window with `W_E ≥ window_end`, writes those rows as Parquet, evicts their state, snapshots the
   open windows per key group and stages its file list.
4. **Commit.** The committer makes one snapshot of `revenue_by_minute` with commit id `(run, g, E)`; sources advance.

**After a crash.** Recovery loads the checkpoint `HEAD` names, replays logged epochs, and the commit id skips any epoch
already in the table. **A roll to v2** that adds `avg(usd)` keeps the `state_id` but changes `schema_digest`, so
preflight refuses `KEEP`; in the first version the state contract must say `RESET`, and the preflight report names the
open windows it discards.

---

## 7. What exists and what must be built

| Piece | Exists | Must be built |
|---|---|---|
| Logical relations, expressions, Arrow types | `komira_plan_ir`, `komira_plan_proto`, `komira_plan_wire` | Recursive `children`; the fix for `payload_narrow` and `group_topk`, dropped silently today (`optimized_plan.md` §5.4) |
| RAW / OPTIMIZED contexts, `OptimizedPlan`, pins, admission, cut | Specified (#1094) | `optimized_plan.md` §12 |
| UDF arms, three modes, runtime ABI | Specified (#1094, #1132) | Their stages; ABI 1.1 `snapshot`/`restore` |
| Topic tail plus Iceberg history as one scan; Iceberg commits; upsert tails | Specified (#1094 §15.4.3; #1134) | The reader, the commit client, the tail |
| Boundedness, `needs.unbounded`, refusal of blocking operators | Specified (#1094 §5.2, §6.1) | Implementation |
| Event time, watermark, window assign, emit policy, typed sinks, `delivery` | **This document** | Proto fields, codec, SDK verbs, SQL `WATERMARK FOR` and window TVFs |
| Watermark propagation, changelog derivation, `StreamForm`, `NORMALIZE`, materializer, `StateSpec`, `needs.state`, key groups | **This document** | The optimizer's streaming phase, the host checks, the corpus |
| Streaming source and sink contracts | `streaming_source.mojo`, `streaming_sink.mojo` (contracts only) | Implementations; a unit for `watermark_ts`; a staged-list token |
| Streaming exchange with epochs and seal | `komira_shuffle_streaming` (Int64 pairs; byte-identical rewrites) | Arrow bodies with `_change`; attempt-scoped segments; a namespace per generation |
| Watermark tracker, window aggregate, single-node streaming driver | Prototypes in the earlier engine: row-at-a-time, Int64 columns, wired by hand | A plan-driven driver (§4.3) over the physical IR; vectorized stateful forms with the per-epoch lifecycle |
| Physical IR | A v13 copy that is not self-contained and has no producer or consumer | The self-contained IR (§4.2); lowering with no optimizer passes; a build-keyed boundary check (§4.6) |
| Offset and commit logs, state backend, checkpoints, savepoints, manifests | None | §4.3, §4.4 |
| Iceberg committer (one commit per epoch), topic sink, fencing commit, roll branch | The commit client's idempotence rule (specified, #1134) | The sinks; the broker's transactional produce path, if missing |
| Run operations and the roll | None | §5, in the coordinator; the scheduler side is outside komira |

**Proposed order.**

1. The plan fields of §2.2 and §3, with the golden corpus and its mutants: cheap, and they fix the contract every later
   piece is tested against.
2. The self-contained physical IR and the batch lowering, without the walker that re-optimizes.
3. The streaming exchange on Arrow, the offset and commit logs, and the streaming driver for `STATELESS` and
   `LOOKUP_JOIN` plans with one Iceberg commit per epoch: the first end-to-end exactly-once streaming plan.
4. `EPOCH_PARTIAL` and `WINDOW_AGG`, with the state backend, checkpoints and canonical savepoints.
5. The roll, with the fence and the audit step.
6. `INTERVAL_JOIN`, `UPDATING_*`, `NORMALIZE`, the materializer, and session windows.

**The tests that make this checkable.**

- **Corpus pairs.** Every streaming corpus plan has a bounded twin over the same pinned span. For inputs that meet the
  order condition of §2.2.5, the consolidated union of the streaming emissions equals the bounded result, for every
  epoch budget the test tries. Mutant: a window aggregate that fires at `W ≥ window_end − 1` emits a window before a
  row with `ts = window_end − 1 µs` that the input legally delivers later, and must turn the test red.
- **Replay.** Kill a host at each step of §4.3 and recover; the output table equals an uninterrupted run's. Mutants: a
  committer that commits before the commit-log entry; a restore that drops the watermark-tracker state (a row late
  before the crash is accepted after it).
- **Fence.** Run a zombie v1 committer after v2's fencing commit; it must not land. Mutant: a committer that rebases
  without re-reading the generation.
- **State identity.** Re-optimize every corpus plan under a different optimizer config; the `state_id`s must not
  change. Mutant: an id that digests the build side.
- **Roll table.** For each class of edit (add a filter, add a measure, change a key, change `key_groups`), a pair of a
  v1 savepoint and a v2 plan with the expected preflight verdict. The "refused" rows are the mutants.
- **Render.** Lower every corpus segment under one fixed profile and compare renders byte for byte.

---

## 8. Amendments to the open specs

| # | Spec | Change |
|---|---|---|
| A1 | `storage_stack.md` | Rename the per-partition "watermark" and the property `komira.tail.<lineage>.watermarks` to "rolled offsets" (`komira.tail.<lineage>.rolled-offsets`) before it lands; `optimized_plan_sources.md` §15.4.3 renames `wm(p)` to match. |
| A2 | `optimized_plan.md` §8 | `key_groups` on `WireExchangeNode` and `ExchangeEdge`; a keyed stateful node's `HASH` exchange is placed even when `host_count_max = 1`, and the cut elides it. |
| A3 | `optimized_plan_udfs.md` §10.3 ("`UdfRef`") | `preserves_event_time` on `UdfRef`. |

---

## 9. Decisions for the maintainers (recommendation first)

| # | Question | Recommended | Alternative | Why |
|---|---|---|---|---|
| D1 | Where the state contract lives | In the `OptimizedPlan`: `StateSpec` on stateful nodes, `needs.state` in the header, canonical savepoints keyed by `state_id` | Leave state to the host's lowering, as `optimized_plan.md` §9.6 does today | Flink persists its compiled plan because a re-planned topology cannot restore a savepoint (FLIP-190, <https://cwiki.apache.org/confluence/pages/viewpage.action?pageId=191336489>). Pinning only the state contract keeps "hosts lower" and still gives restorable state. |
| D2 | Changelog representation | Consolidated Z-set per epoch, carried as `_change: int8` (±1) at exchanges and sinks | A four-valued row kind (INSERT, UPDATE_BEFORE, UPDATE_AFTER, DELETE) | Weights compose under union and aggregation with no case analysis, and consolidation makes order within an epoch irrelevant. Cost: the before/after pairing is not kept at a sink. |
| D3 | Unwindowed aggregate or join over a stream | Admit `UPDATING_*` only with `TTL` or `UNBOUNDED_DECLARED`; otherwise refuse by name | Always refuse; or admit silently | Unbounded growth becomes a choice the header shows. |
| D4 | Streaming sinks | Typed arms on `write_target`, one sink per plan, an optional `late_rows` side target | A sink node arm, allowing several sinks | The header must authorize the write without decoding the body. |
| D5 | Watermark convention | `W` means no later row `< W`; windows `[start, end)` fire at `W ≥ end`; `window_time = end − 1 µs` | Flink's (`≤ W`, fire at `W ≥ end − 1`) | Either works if used everywhere; this one needs no `− 1` in the watermark, only in `window_time`. |
| D6 | Key groups | Fixed per stateful node by the producer (default 128, at most 32768), with a hash frozen per contract version; changing it is a `MAP` | Hash directly to the host count | Otherwise every rescale is a full state shuffle. |
| D7 | Porting the earlier physical IR | Port the pipeline model (source, operators, breaker; edge kinds; combine order), self-contained (§4.2) from the first commit; leave out the lowering walker that re-runs optimizer passes | Port as is and fix later | Side tables block field 11 and the binding of streaming state; the walker breaks "hosts never re-optimize". |
| D8 | Physical IR versioning | Guard boundaries with the engine build digest; keep `PHYSICAL_PLAN_IR_VERSION` as a label | An exact-match number bumped by hand | A forgotten bump fails silently. |
| D9 | Window kinds in the first streaming contract version | TUMBLE and HOP; SESSION fields reserved and refused | All three | Session windows need merging state and their own savepoint format. |
| D10 | Iceberg commit cadence | Host-local grouping, at most one snapshot per epoch, a minimum interval, commit id = the group's last epoch | A plan field `commit_every` | Cadence changes latency and file counts, never committed rows. |
| D11 | Delivery | Exactly-once by default; at-least-once only when the write target declares it. This reverses the contract's "downgrade, not a mode" (`streaming_sink.mojo:101-119`) | Keep the loud plan-time downgrade | A plan should show its guarantee before it runs, not in a plan-time message. |
| D12 | The bounded twin | A bounded run ignores emit policy and lateness, and the corpus pairs guard the equality under the input-order condition | Simulate watermarks in bounded runs | That would make bounded results depend on arrival order. |
| D13 | Lookup build side across snapshot expiry | Copy the build side into every savepoint; rebuild from the pin when it is live | Tag the pinned snapshot (impossible on tables komira did not create and on S3 Tables) | Recovery must not depend on someone else's expiry policy. |
| D14 | An added measure in a roll | `RESET` of that state in the first version; a "new measure is null for open windows" `MAP` later | Define the `MAP` now | Its meaning for open windows is a product choice; `RESET` is explicit and correct. |
| D15 | A roll's audit step on tables where branches are unavailable | Held pre-commits with a shadow sink for output checks | Let v2 commit directly, so a failed roll can only roll forward | Keeps "a failed roll parks v2 and keeps v1" true on every table. |

---

## 10. Prior art consulted

- **Flink:** FLIP-145, FLIP-190 and FLIP-292 (linked above); checkpoints and savepoints (linked above); dynamic tables
  and ChangelogNormalize (<https://nightlies.apache.org/flink/flink-docs-release-2.3/docs/concepts/sql-table-concepts/dynamic_tables/>);
  window TVFs (<https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/dev/table/sql/queries/window-tvf/>).
- **Spark Structured Streaming:** <https://spark.apache.org/docs/3.5.6/structured-streaming-programming-guide.html>.
- **RisingWave:** watermark operators
  (<https://github.com/risingwavelabs/rfcs/blob/main/rfcs/0016-watermark-operators-explained.md>) and its stream engine
  overview.
- **DBSP** (Budiu et al.) and Feldera's notes on Z-sets; **Differential Dataflow** (McSherry et al., CIDR); the
  **Dataflow Model** (Akidau et al., VLDB); DataFusion's `Boundedness`; Arroyo's notes on Arrow and DataFusion.
