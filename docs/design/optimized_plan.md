# Design: `OptimizedPlan`, a serializable optimized plan

Status: proposed, not built. Scope: komira's plan wire, optimizer, plan cutter, executor admission, user code in
plans (UDF nodes and the environment image, §10, specified in [`optimized_plan_udfs.md`](optimized_plan_udfs.md)),
and sources, index access paths and graph operators (§15, specified in
[`optimized_plan_sources.md`](optimized_plan_sources.md)).

Pinned state: komira `main` as merged by komira-ai/komira#967. Paths are cited as `path:line`; the line numbers were
read at `main` as merged by komira-ai/komira#931, and nothing changed from there through komira-ai/komira#977 in
`src/komira_plan_proto`, `komira_plan_wire`, `komira_plan_ir`, `komira_optimizer`, `komira_plan_stats`,
`komira_join_assembly`, `komira_shuffle`, `komira_shuffle_streaming` and `src/komira_morsel/streaming_source.mojo`.
Statements marked *(inferred)* are my reading, not facts taken from the code. Nothing was built or run to write this
document.

---

## 1. Problem

A query plan reaches an executor today as a `WirePlanEnvelope` (`src/komira_plan_proto/plan.proto:1615`). That
format was built for plans taken **before** the optimizer runs. It refuses optimizer output by name:
`estimated_groups` (`src/komira_plan_wire/plan_wire_codec.mojo:3285`) and `TableStats`
(`plan_wire_codec.mojo:337`, `:2990`). It also has no field for several decisions the optimizer makes, such as the
build side of a join or the PARTIAL/FINAL split of an aggregate.

A scheduler that accepted that raw logical plan would force one of two things on the system: either the scheduler
runs the optimizer, or every executor host does. Both are expensive, and in both the optimizer runs far from the
party that wrote the query.

This design makes the **optimized logical plan** a defined, serializable type. There is no raw SQL submission: SQL
is written inside the Mojo, TypeScript or Python SDK (or a notebook built on one), and the SDK parses it into a
logical plan, optimizes it once and submits that type. A scheduler places it. An executor host **lowers** it to
physical operators and does not optimize it again. When the plan runs on more than
one host, it is cut into **optimized segments**, a second defined type built from the same pieces.

### 1.1 Goals

1. One type, `komira.plan.v1.OptimizedPlan`, which is the plan payload a scheduler accepts.
2. One type, `komira.plan.v1.OptimizedSegment`, for a piece of a cut plan travelling between processes of one
   engine build.
3. The optimizer's decisions are explicit, typed and checkable. They are not implied by convention.
4. A host validates the plan before it runs it, and every refusal has a name.
5. **Backward compatibility, always.** Every later host build accepts and executes every `OptimizedPlan` that any
   released producer ever emitted (§9). Producer and host builds may therefore differ without limit in that
   direction.
6. A physical-plan form is reserved so it can be added later without a format break.
7. A user's Python or TypeScript function, written as a plain function (in Python a module function, a notebook
   function, a lambda or a closure), runs as a plan node with no required decorator, no wrapper class and no packaging
   step. Its return type is explicit in the plan, given as a type hint or an argument on the verb. The plan identifies
   the code by digest, and the code itself travels in an environment image beside the plan (§10).
8. A plan says whether it is streaming: a scan of a source with no end is marked `UNBOUNDED`, and such a plan runs in
   streaming mode (§5.2).

### 1.2 Non-goals

- A second node vocabulary. The body reuses `WirePlan` (§3).
- Shipping physical plans now. Physical choices depend on the host, which is picked after submission, and the
  physical IR (`src/komira_plan_ir/physical_plan.mojo`) is tied to a single engine build. It has no producer or
  consumer in this tree yet (`physical_plan.mojo:5-6`).
- Trusting producer statistics for correctness or for resource reservation (§6).
- Forward compatibility. An older engine need not accept a newer plan. A scheduler routes by version, or, where the
  engine comes from the environment image, refuses by name and asks for a rebuild (§9.5, §10.11).
- Code bytes in the plan. A plan carries digests of user code, never the code or its captured data (§10.6).
- A raw SQL or bound-plan door on the scheduler. Every submission is already optimized (§2).

---

## 2. Roles

| Role | What it does |
|---|---|
| **Producer** | Parses SQL (or takes a dataframe expression, including the user functions it calls), binds, gathers statistics, optimizes, captures user code (§10.6), and emits an `OptimizedPlan`. It is a program that links the engine and the producer library: the Mojo, TypeScript or Python SDK, or a notebook built on one. A **service that re-optimizes a stored query** on each run (for example a scheduler running a recurring job) is a producer too: it starts from a bound plan that an SDK produced and stored, links the same library, and stamps `kind = "komira/server"`. When the stored query has an environment image, the service runs the producer library from that image's base (§10.11). It is not a path for clients without an engine; there is none. For identical inputs every producer yields the same `plan_digest` (§7.1). The stamps differ, so the header bytes do not. |
| **Scheduler** | Any system that places work. It is not part of komira. It accepts plan work only as an `OptimizedPlan`, never as SQL text or a bound plan, so it never runs the optimizer. It reads only the header, through the header-only library (§4.1), and never decodes the body. When the plan travels with an environment image, it checks that pair against the release records it is given, from the image manifest alone (§10.11). |
| **Coordinator** | Learns the host count once placement is done. It verifies `plan_digest`, then **cuts** the plan into `OptimizedSegment`s (§8). The cut is mechanical and changes no decision. |
| **Executor host** | Admits a segment or a plan (§7), lowers it, and applies only the named host-local rules (§5.3). It never re-optimizes. It runs user code in worker processes started from the plan's environment image (§10.10). |

The producer optimizes, the scheduler places, the coordinator cuts and the host lowers. Each step runs once.

*A future option, not part of this design:* a SQL gateway for BI tools that speak only SQL would itself be a producer,
built on the SDK's producer library. It would submit `OptimizedPlan`s like any other producer and need no scheduler
change.

---

## 3. Why the body reuses `WirePlan`

`WirePlan` has 16 node arms in fields 4-19 (`plan.proto:1524`), mirroring `PLAN_TAG_COUNT = 16`
(`src/komira_plan_ir/logical_plan.mojo:174`). The format already carries much of what an optimized plan contains:

- equi-keys, `residual` and `algo_hint` on joins (`plan.proto:1252`);
- pushed `filter` and `projection` on scans (`plan.proto:1133`);
- `is_cse_introduced` on projects (`plan.proto:1235`);
- `over_fetch_k` on partition top-N (`plan.proto:1383`);
- `cse_ref` with a `canonical_hash` (`WireCseRefNode`, field 18, arm 15; field number is not arm ordinal,
  `plan.proto:1563-1565`).

An optimized logical plan is still a `LogicalPlan`. A parallel node set would double `komira_plan_wire`, which is
12,861 source lines in five files (`wc -l src/komira_plan_wire/*.mojo`; the codec alone is 4,310), and the two sets
would drift apart.

**The codec gets a decode context instead:** `WireContext { RAW, OPTIMIZED }`.

- **RAW** is today's behaviour. Every existing refusal stays. It is used for view bodies, the existing plan
  endpoint, and a bound plan stored for re-optimization (§2).
- **OPTIMIZED** accepts the decision fields in §5.2, requires the ones marked required, and refuses the
  statistics fields listed there.

The same bytes can mean different things in the two contexts, so the context comes from the **enclosing message**:
a `WirePlanEnvelope` is RAW; an `OptimizedPlanBody` or an `OptimizedSegment` is OPTIMIZED. It never comes from a
flag inside `WirePlan`, which a producer could set wrongly.

---

## 4. Messages

There is one new file, `src/komira_plan_proto/optimized_plan.proto`, in package `komira.plan.v1`. It imports
`plan.proto` and is commented in that file's house style. New enums go in `plan_vocabulary.proto` with a
`*_WIRE_UNSPECIFIED = 0` entry, a "Derived from" line and an engine prefix, as `JoinAlgo` does
(`plan_vocabulary.proto:225-234`).

### 4.1 The plan: header and body

```proto
// What a producer submits and a scheduler accepts. A scheduler reads fields 1-7.
message OptimizedPlan {
  uint32           format_version      = 1;  // minimum reader capability; set membership (§9.2)
  ProducerStamp    producer            = 2;
  bytes            plan_digest         = 3;  // 32 bytes (§7.1)
  bytes            recurring_signature = 4;  // 32 bytes or empty; advisory
  DeclaredNeeds    needs               = 5;  // the only input to placement (§6.1)
  WireWriteTarget  write_target        = 6;  // same meaning as WirePlanEnvelope.write_target
  PlanAdvice       advice              = 7;  // advisory; outside the digest (§6.3)
  bytes            body                = 8;  // a canonical OptimizedPlanBody; a scheduler never parses it
}

message ProducerStamp {
  bytes        engine_build               = 1;  // digest of the engine build output; provenance and revocation key
  uint32       optimizer_contract_version = 2;  // meaning frozen per version (§9.3)
  bytes        optimizer_config_digest    = 3;  // digest of the OptimizerConfig values used; reproduction only
  string       kind                       = 5;  // open, namespaced, same grammar as a UDF runtime id (§10.3):
                                                  // "komira/python-sdk", "komira/typescript-sdk", "komira/mojo-sdk",
                                                  // "komira/server" (a service re-optimizing a stored query, §2)
  reserved 4;                                     // a draft's closed ProducerKind enum
}

// The type is the "do not re-optimize" mark; §7.3 says how that is enforced.
message OptimizedPlanBody {
  WirePlan               plan      = 1;  // one uncut plan, decoded in the OPTIMIZED context
  repeated SharedSubplan shared    = 2;  // targets of cse_ref (§4.3)
  repeated ScanPin       scan_pins = 3;  // the snapshot each scan was optimized against (§6.2)
  repeated PinGroup      pin_groups = 4; // recorded multi-table snapshot sets (§15.3.4)
}

message PlanAdvice {
  repeated NodeEstimate estimates   = 1;  // {node_ordinal, node_tag, rows, bytes, source}; preorder ordinal
  repeated ScanStats    stats_basis = 2;  // the statistics the optimizer used
  repeated UdfOrigin    udf_origins = 3;  // {udf_index, display_name, file, line, captured_version}; diagnostics
                                          // only (§10.3)
  repeated IndexCoverage index_coverage = 4;  // what each pinned index generation does not cover (§15.5.2)
}
```

**The header is separate from the body on purpose.** `body` is `bytes`, so a reader of the header does not need
`komira_plan_wire`. The header codec and its checks (§7.2 steps 1-3) live in their own library target,
`komira_optimized_plan_header`, whose dependency closure must exclude `komira_plan_wire`. A Buck2 closure assertion
checks it, proven by planting the dependency and watching the build go red. "A scheduler never decodes the body"
is then a property of what a scheduler links, not only a policy.

**`write_target`** is in the header because a scheduler needs it to authorize the write. It is also bound into
`plan_digest` (§7.1), because it changes the plan's effect.

**There is no hop-1 segment form and no `final` flag.** An `OptimizedPlan` always carries one uncut plan; segments
exist only after the cut (§8). A boolean "final" would be a check that cannot fail: the enclosing message already
fixes the context.

### 4.2 Header invariants

| # | Field | Invariant | Checked by |
|---|---|---|---|
| 1 | `format_version` | In the reader's accepted set, which holds **every released version** and loses none (§9.2); never `>=`. An understated version (a field present that its version does not include) is refused, as `plan.proto:1631` does for `write_target`. | header library, host |
| 2 | `producer` | Required. `engine_build` not on the revocation set passed in by the caller. `optimizer_contract_version` a released version the host knows; every released version stays known (§9.3). `kind` is provenance only: neither admission nor the optimizer reads it. | header library (revocation), host (revocation and contract) |
| 3 | `plan_digest` | Exactly 32 bytes; the host recomputes it (§7.1). | host, coordinator |
| 4 | `recurring_signature` | 32 bytes or empty. It cannot be verified from the body, so it keys only history and caches, never authorization or limits. | none (advisory) |
| 5 | `needs` | Required (§6.1). The host cross-checks it against the body. With UDFs, `needs.runtimes` lists every runtime used and the pair (plan, environment image) passes §10.11. | header library (caps, environment checks 1-3), host (cross-check, environment checks 1-7) |
| 6 | `write_target` | Same rules as in `WirePlanEnvelope`: an empty path is refused. A write-carrying plan declares the format version that includes it. | header library, host |
| 7 | `advice` | Advisory. No reader refuses a plan for its content; a mismatch between an estimate's `node_tag` and the node at its ordinal is shown as such by diagnostics and otherwise ignored. | none |
| 8 | `body` | Canonical (§7.1) and decodes as `OptimizedPlanBody` in the OPTIMIZED context. | host |

### 4.3 Shared subplans

```proto
message SharedSubplan {
  uint64   canonical_hash = 1;   // matches WireCseRefNode.canonical_hash
  WirePlan plan           = 2;
}
```

Every `cse_ref` must resolve to exactly one entry, and every entry must be referenced. The host materializes each
entry once and fans it out. Aggregate CSE today substitutes a materialized `InMemorySource` leaf
(`src/komira_optimizer/optimizer_agg_cse.mojo:33`, `:426`); that stays refused on the wire, and the producer emits
`cse_ref` plus a `shared` entry instead. Scan dedup takes the same form. The producer owns the decision; the host
only materializes.

---

## 5. Pinning the optimizer's decisions

### 5.1 Rule: a decision is a node field, an estimate is advice

A decision that the lowering must obey is a typed field on the node it governs, for three reasons:

1. Neither the IR nor the wire has node ids; every reference to a node is positional. A table keyed by node would
   need ids plus uniqueness, dangling-key and orphan checks, each a new way to fail silently.
2. The lowering already reads `left_on`, `right_on` and `residual` from the node. Reading `build_side` there is one
   field access, and it cannot fall out of step after a rewrite.
3. A typed field appears in the text goldens (`src/komira_plan_wire/tests/fixtures/golden/*.txtpb`), so a named
   mutant can target it.

Estimates are the exception. They are numerous, nothing obeys them, and they must stay out of the digest. They go
in the header's `advice` (§6.3).

### 5.2 Wire changes (OPTIMIZED context only; RAW refuses each new field by name)

Field numbers are the next free numbers at the pinned commit.

| Message | Change | Meaning |
|---|---|---|
| `WireJoinNode` | `JoinBuildSide build_side = 9` (`LEFT`, `RIGHT`) | Required. The side the host builds its hash table on. **Child order still fixes the output schema** (column order and the `_right` collision names, `src/komira_join_assembly/compiler_join_assembly.mojo:81-83`); `build_side` chooses only the hash-table side. Today's convention is probe = left, build = right. |
| `WireJoinNode` | `bool adaptive_allowed = 10` | The host may switch this join between broadcast and partitioned at runtime (§8.3). |
| `WireJoinNode` | `algo_hint` (existing field 6) | OPTIMIZED requires a decided algorithm; `JOIN_ALGO_AUTO` and unspecified are refused (`OPTIMIZED_JOIN_ALGO_UNDECIDED`). |
| `WireAggregateNode` | `AggMode mode = 8` (`SINGLE`, `PARTIAL`, `FINAL`) | Required. The producer records the mode only; the host derives the partial-state layout from the aggregate expressions, because that layout belongs to the engine build, not to the optimizer. |
| `WireAggregateNode`, `WireDistinctNode` | `estimated_groups` (existing field 5) | Admitted. The host uses it only to pre-size hash tables, clamped to its memory budget, so a wrong value costs speed, never correctness. The refusal at `plan_wire_codec.mojo:3285` becomes RAW-only. |
| `WireScanNode` | `uint32 pin_ref = 12` | Required. Index into `scan_pins`. |
| `WireScanNode` | `row_count` (9), `has_table_stats` (11) | **Refused in OPTIMIZED.** Statistics have one home, `advice.stats_basis`, outside the digest; no host decision reads a producer statistic. |
| `WireScanNode` | `Boundedness boundedness = 13` (`BOUNDED`, `UNBOUNDED`) | Required in OPTIMIZED; admitted in RAW too (below). Marks a source with no end, which makes the plan a streaming plan. |
| `WireScanNode` | `WireAccessPath access_path = 14` | Required in OPTIMIZED; admitted in RAW. The scan's access path (full, text index, vector index), with its index generation and consistency mode (§15.5). |
| `WirePlan` | new arms `index_lookup = 23`, `expand = 24` | A query per input row against an index, and graph traversal (§15.6, §15.7). Admitted in both contexts. |
| `WirePlan` | new arm `WireExchangeNode exchange = 20` | `{child = 1, kind = 2 (GATHER, BROADCAST, HASH, RANGE), keys = 3, key_encoding = 4, ordering = 5, partitions = 6, adaptive_allowed = 7, key_groups = 8}`. `partitions = 0` means "filled in at the cut" (§8); `key_groups` is set only below keyed state (§8.4). |

The UDF arms of §10.4 (`WireUdfApply`, `WireMapBatchesNode`, `WireStepNode`, the `AGG_UDF` aggregate function),
the `WireField` addition `children`, `WireScanNode.boundedness`, and the §15 additions (`access_path` and the two
arms above) are an exception to this table's heading: they are admitted in both contexts, because a stored bound plan
contains UDFs, streaming sources, searches and traversals too. OPTIMIZED refuses
the name-keyed `WireUdfCall` and the node-level `WireUdf` (`OPTIMIZED_UDF_LEGACY_FORM`).

**A join's distribution is derived, not recorded.** No exchange below a join means local; a broadcast exchange on
its build input means broadcast; hash exchanges on both inputs with the same keys and key encoding mean partitioned.
Any other shape is refused (`OPTIMIZED_JOIN_EXCHANGE_INCONSISTENT`). A separate `distribution` field would be a
second statement of the same fact that nothing could keep in agreement.

**Streaming is selected by the plan.** An `UNBOUNDED` scan reads a source that has no end, such as a message stream
or a table read as it grows. A plan with at least one `UNBOUNDED` scan is a **streaming plan**: the host runs it under
the streaming driver, over the same decoded plan and in the same environment image as any other plan. There is no
run-kind field and no image compiled per pipeline; the scan's mark is the only statement.

- **RAW and OPTIMIZED.** The logical plan states boundedness too, so RAW admits the field and reads it unset as
  `BOUNDED`, which is what every RAW plan means today. OPTIMIZED requires it (`OPTIMIZED_SCAN_BOUNDEDNESS_MISSING`).
- **It is checked against the source.** A source that can only be read to its end marked `UNBOUNDED`, or a source
  that never ends marked `BOUNDED`, is refused (`OPTIMIZED_SCAN_BOUNDEDNESS_UNSUPPORTED`). The engine's streaming
  source contract, which tells "no data now" (`Idle`) from "no more data" (`Closed`), is `StreamingMorselSource`
  (`src/komira_morsel/streaming_source.mojo:321`), and its read position is an opaque, checkpointable value (`:70`).
- **Every other node's boundedness is derived:** a node's output is unbounded if any of its inputs is. An operator
  that must read all of an unbounded input before it emits (a sort, an aggregate with no streaming form, the build
  side of a hash join, a grouped `MAP_BATCHES_FRAME`) is refused (`OPTIMIZED_UNBOUNDED_INPUT_UNSUPPORTED`) unless the plan's
  `optimizer_contract_version` admits a streaming form for it. That set is part of the contract version (§9.3) and
  only grows, as the lowerable `(join type, build side)` pairs do. Windows, watermarks and the streaming forms of
  operators are added under new format versions; this document fixes how a plan says it is streaming, and that
  refusal.
- **The header repeats it for a scheduler,** which never decodes the body: `needs.unbounded` (§6.1). The host refuses
  a header that disagrees with the body (`OPTIMIZED_NEEDS_UNBOUNDED_MISMATCH`). It is a summary checked against the
  body, as `needs.udfs` is, not a second switch.

**Not every `(join type, build side)` pair can be lowered.** `build_side = LEFT` with `RIGHT`, `FULL`, `SEMI` or
`ANTI` joins (`logical_plan.mojo:471-474`) needs build-side-outer, right-semi and right-anti operators *(inferred:
komira has none today)*. The supported set is part of `optimizer_contract_version` (§9.3), so a producer knows it in
advance, and it only grows: a pair that any released contract version admits stays lowerable by every later host.
A host refuses a pair that no contract version up to the plan's admits with `OPTIMIZED_JOIN_BUILD_SIDE_UNSUPPORTED`;
no correct producer emits one.

**`group_topk` gets no wire field.** It exists on the IR (`logical_plan_variants.mojo:661`), nothing sets it, and its
semantics are unspecified. The encoder refuses a plan carrying it in both contexts (§5.4). A field that is always
refused would be an unobservable slot.

**The exchange arm takes plan tag id 18, not 16.** Tag ids 16 and 17 are retired, and the comment says "THE NEXT TAG
ADDED TAKES 18" (`logical_plan.mojo:170-180`; `plan_vocabulary.proto:56-57` reserves wire numbers 17 and 18). So
`PLAN_EXCHANGE = 18` and its `PlanTag` wire number is 19. The UDF nodes of §10.4 follow it: engine tags
`PLAN_MAP_BATCHES = 19` and `PLAN_STEP = 20` (`PlanTag` 20 and 21; WirePlan fields 21 and 22), and
`PLAN_TAG_COUNT` becomes 21. On the expression side, engine tag `EXPR_UDF_APPLY = 27` (`ExprTag` 28; WireExpr field
27), and `EXPR_TAG_COUNT` becomes 28. Every consumer sized from those constants, the vocabulary census and the
enum-number tests (`src/komira_plan_proto/tests/test_plan_enum_numbers_nodes.mojo`,
`test_plan_enum_numbers_functions.mojo` and `test_plan_census_complete.mojo`; `git grep -l ExprTag`) change in the
same stage.

**Join order, predicate placement and projection placement are expressed by shape.** Shape is binding: the host
does not link the optimizer (§7.3), so it cannot reorder.

### 5.3 What the producer decides and what the host decides

Some of today's optimizer passes are local to one process or need to execute part of the plan. The producer entry
point takes a **portable profile** as a required argument. It turns those passes off and hands their work to the
host as **named host-local rules**. The profile is an argument rather than a non-defaulted `OptimizerConfig` field
because `OptimizerConfig()` is constructed with no arguments in 20 places across 3 files today
(`git grep -c "OptimizerConfig()"`; the docstring at `src/komira_optimizer/optimizer_config.mojo:23` says to), and
in-process use keeps that default.

| Output | Producer, portable profile | Host |
|---|---|---|
| Join order, build side, algorithm | Decides and records it (§5.2) | Obeys it |
| PARTIAL/FINAL aggregate split, eager aggregation | Decides and records `mode` | Obeys it; derives the state layout |
| Predicate and projection pushdown, CSE projects, top-N and window fusion, group-key elision | Decides; expressed as shape | Obeys it |
| Exchange placement | Decides, for the declared maximum host count | The coordinator fills in `partitions` (§8) |
| Aggregate CSE to a materialized result, scan dedup | Emits `cse_ref` plus `shared` | Materializes once |
| `estimated_groups` | Records it | Pre-sizes, clamped |
| Scalar-subquery literal folding (`optimizer_scalar_deps.mojo`, `optimizer_resolve_scalar_subqueries.mojo`) | Keeps the decorrelated broadcast shape (`scalar_subquery_decorrelate.mojo`); does not execute | May fold the scalar to a literal at lowering (`SCALAR_FOLD`) |
| Payload narrowing (`optimizer_payload_narrow.mojo`) | Off | Derives it from footers it opened after the pin check (§7.2) |
| Scan sharing and its dynamic-filter slot (`optimizer_scan_share.mojo`) | Off | Derives it at lowering; the filter direction follows the recorded `build_side`; row-count thresholds read the host's own verified footers, never a producer number |
| Where each UDF is evaluated; conjunct order around UDF predicates; CSE of non-`VOLATILE` UDFs | Decides; expressed as shape (§10.9) | Obeys it |
| UDF worker count, threads, batch slicing | Records the bounds (`UdfResources`) and every return type (§10.5) | Chooses within the bounds |
| Batch or streaming execution | Marks each scan's boundedness (§5.2) | Runs a plan with an `UNBOUNDED` scan under the streaming driver; this follows from the plan and is not a host choice |

All paths in this table are under `src/komira_optimizer/` at the pinned commit.

The **complete list of host-local rules**:

1. lowering to physical operators;
2. `SCALAR_FOLD`;
3. payload narrowing;
4. scan sharing, honouring `build_side`;
5. shared-subplan materialization;
6. choice of morsel size, and of operator variant within a node's recorded algorithm;
7. spill;
8. the adaptive changes of §8.3, only where `adaptive_allowed` is set;
9. UDF worker count, thread limits and batch slicing, within `UdfResources` (§10.8, §10.10);
10. the three source rules of §15.8.3 (numbered 10-12 there): a reaped topic span read from a descendant snapshot,
    top-k per split, and the uncovered-file overlay of an `EXACT` index read.

A host change that alters a §5.2 field or the shape, other than by these rules, is a defect, and the post-condition
in §7.3 catches it.

**Why payload narrowing moves to the host.** It truncates values. A wrong `[min, max]` from a producer would be a
correctness defect, not a performance one, so no producer statistic ever drives it.

**Why scan sharing changes.** Today its both-filtered direction tie-break reads raw `row_count` from the scan node
(`optimizer_scan_share.mojo:178`, `:367-408`) and picks the direction whose small side builds. Under this design
that question is answered by the recorded `build_side`, and the remaining thresholds use footers the host has
itself verified.

*Cost (inferred):* a host-side scalar fold does not re-run the folding and pruning that the bound literal would
have enabled. Plans shaped like TPC-H Q11, Q15 and Q22 may run with a less pruned shape than a fixed-point optimizer
would produce. A producer links the engine and could execute a scalar subquery before it optimizes; whether it
should is question 2 in §14, decided for `SCALAR_FOLD`.

### 5.4 Fields that are silently dropped today

`LogicalPlan` scan data carries `payload_narrow` (`src/komira_plan_ir/logical_plan_variants.mojo:193`); aggregate
data carries `group_topk` (`logical_plan_variants.mojo:661`). Neither name appears anywhere in
`src/komira_plan_wire/` (`git grep`, 0 matches). *(Inferred)* Both are therefore lost on encode without a refusal.

This defect is independent of this design. In both contexts the encoder must refuse a plan that carries either
field. It ships first, with a test that fails before the fix (§12, stage 1).

---

## 6. Needs, snapshots and advice

### 6.1 Declared needs

```proto
message DeclaredNeeds {
  ResourceNeeds    resources   = 1;  // cpu_millis, peak_mem_bytes, scanned_bytes, max_parallelism,
                                     // spill_ok, host_count_max, interruptible, accelerators
                                     // (closed enum and count); covers every UdfRef.resources (§10.8)
  repeated UdfRef  udfs        = 2;  // §10.3; the body references entries by index
  reserved 3; reserved "images";     // the environment image travels beside the plan (§10.11)
  repeated Hint    hints       = 4;  // closed enum key + typed value; an unknown key is refused
  repeated string  data_scopes = 5;  // scan binding keys the plan reads
  reserved 6, 7; reserved "python_abi", "node_abi";  // a draft's per-language ABI fields; see runtimes
  bool             unbounded   = 8;  // true iff some scan in the body is UNBOUNDED (§5.2)
  repeated RuntimeNeed runtimes = 9; // one entry per runtime id used by udfs, sorted by id
  repeated DataScope scopes    = 10; // every table, tail, index, topic and prefix the pins name (§15.10.2)
}

message RuntimeNeed {               // udf_runtime_interface.md §3.2
  string runtime     = 1;           // a UdfCode.runtime id (§10.3)
  string runtime_abi = 2;           // the runtime's own ABI tag: "cp312", "cp313t", "node22"; may be empty
}
```

(`images`, `python_abi` and `node_abi` were never released, so §9.2 allows reserving them.)

`needs` is what a scheduler places by, capped by its own limits. The producer derives it from its estimates; the
scheduler never sees those estimates as anything but advice. A producer that overstates needs reserves more than it
uses; one that understates spills or is refused by the host's memory budget.

The host checks against the decoded body:

- every `udf_index` in the plan, in `shared` and in every segment is in range (`OPTIMIZED_UDF_UNDECLARED`);
- on the uncut plan only, every `udfs` entry is referenced (`OPTIMIZED_UDF_UNREFERENCED`); a segment keeps the
  parent's whole list (§8.1) and may use only part of it;
- each reference matches the entry's kind: `WireUdfApply` names `SCALAR`, `ROW` or `MAP_BATCHES_COLUMN`, or
  `AGGREGATE` as the argument of an `AGG_UDF` measure; `WireMapBatchesNode` names `MAP_BATCHES_FRAME`; and `WireStepNode` names
  `STEP` (`OPTIMIZED_UDF_KIND_ARM_MISMATCH`);
- `runtimes` has exactly one entry per runtime id used by `udfs`, sorted by id (`OPTIMIZED_UDF_RUNTIME_UNDECLARED`,
  `OPTIMIZED_NEEDS_RUNTIME_UNUSED`, `OPTIMIZED_NEEDS_RUNTIME_ABI_CONFLICT`);
- `unbounded` is true if and only if some scan in the plan or in `shared` is `UNBOUNDED`
  (`OPTIMIZED_NEEDS_UNBOUNDED_MISMATCH`);
- every scan's binding appears in `data_scopes`;
- closures, notebook functions and lambdas are **admitted** in their `VALUE` form (§10.6), and their
  code must be present in the environment image (§10.11).

### 6.2 Snapshot pins (binding)

```proto
message ScanPin {
  string binding_key      = 1;  // the scan's binding identity
  bytes  data_fingerprint = 2;  // sha256 over sorted (path, size, etag); typed pins are in §15.3
}
```

Every scan pins the data it was optimized against. `WireScanBinding` already distinguishes a pinned snapshot from a
live one (`snapshot_policy` and `snapshot_token`, `plan.proto:382-389`); a pin generalizes that to every scan source.
The host resolves each pin **before
lowering** and refuses a mismatch with `OPTIMIZED_PLAN_SNAPSHOT_STALE`. It neither re-optimizes nor reads newer
data. The footers that payload narrowing and scan sharing read come from that verified open, and data reads are
conditional on the pinned identity (for example an etag precondition) so a file that changes after the check fails
the read rather than being truncated by a stale narrowing *(inferred mechanism)*. Pins are part of the digest.

**An `UNBOUNDED` scan pins the stream, not its contents,** which keep growing: `data_fingerprint` names the stream and
its schema, and the stale-pin check refuses a stream whose identity or schema changed. Where a run starts reading is
run state, a checkpointed source position, outside the plan and its digest.

**Typed pins** (§15.3). `ScanPin` gains typed arms: an Iceberg snapshot with its table uuid and metadata file, a
topic's offsets with its rolled table, a row store's (snapshot, log seq), a Delta version, an index generation; and
pin groups for a recorded multi-table snapshot set. The producer resolves a `SNAPSHOT_LIVE` binding into its pin at
optimize time, and an unresolved one is refused (`OPTIMIZED_SCAN_LIVE_UNRESOLVED`).

A file list that would push the message over the 16 MiB reader budget (`plan_wire_admit.mojo:255`) travels as a
manifest object referenced by digest *(inferred need: large partitioned listings)*.

### 6.3 Advice: estimates and the statistics basis

```proto
message ScanStats {
  uint32      pin_index            = 1;  // which ScanPin these describe
  uint64      row_count            = 2;
  StatsSource source               = 3;  // PARQUET_METADATA | FILE_SIZE_HEURISTIC | RUNTIME_FEEDBACK | UNKNOWN
  repeated ColumnStatsWire columns = 4;  // name, ndv, min, max, null_count, from_sketch
}
```

`ScanStats` mirrors `TableStats` and `ColumnStats` (`src/komira_plan_stats/table_stats.mojo:154`, `:57`). It records
what the optimizer saw, for reproduction and diagnosis. Advice is advisory everywhere:

- A scheduler places by `needs`, capped by its own limits. It does not reserve resources or set limits from
  `advice`.
- No correctness-relevant host action reads a producer statistic (§5.3).
- Actual rows and bytes per node can be recorded against `recurring_signature`. A producer may read them back as a
  `RUNTIME_FEEDBACK` source for the **next** plan. Feedback never changes the current one.

`advice` is in the header and outside `plan_digest`: the digest identifies what will execute, not why it was
chosen.

---

## 7. Admission

### 7.1 Canonical form and the digest

The existing format has no canonical encoding and says so: "Do NOT compare plan bytes for equality, use them as a
cache key, sign them" (`plan.proto:36-50`). It names the remedy: "omit defaults, order fields by number". This design
defines **canonical form** for every message reachable from `OptimizedPlanBody` and `OptimizedSegment`:

- fields in ascending field-number order;
- default-valued scalars omitted, including the `has_*` booleans when false;
- repeated scalars packed;
- no unknown fields (a body with one is refused, never re-emitted);
- minimal varints;
- floats: every NaN canonicalized to one bit pattern; -0.0 kept distinct from 0.0;
- `oneof`: exactly the set arm is emitted.

The Mojo encoder writes defaults explicitly today (`plan.proto:36-41`), so the canonical encoder is a second encoder
mode. This change amends the `plan.proto:36-50` comment for these two messages. The existing
`tests/fixtures/golden/*.canonical.hex` files are protoc renderings, not this form; the new goldens get a distinct
suffix.

**The digest.** The body must already be canonical: the host decodes it, re-encodes it canonically and compares
bytes (`OPTIMIZED_PLAN_NOT_CANONICAL`). Then

```
plan_digest = sha256(body ‖ canonical(DigestTrailer))
DigestTrailer = { format_version, optimizer_contract_version, write_target, needs.udfs, needs.runtimes,
                  needs.data_scopes, needs.scopes }
```

The trailer binds the plan's effect, the code it runs (by digest; the environment image that holds it is outside the
digest, §10.11), the data it may read and the contract version under which its
fields have their meaning. The check proves integrity and that producer and host agree on canonical form. It does
**not** prove who wrote the plan; authenticating the submitter is the transport's job.

`structural_hash` (`logical_plan.mojo:1807`) is not reused. It is an FNV-1a hash over a render, which is not
collision-resistant, and the render omits `output_schema`.

### 7.2 Admission order and refusal tokens

The header library runs steps 1-3 on the header only:

1. **Size.** At most the 16 MiB plan budget plus a fixed header allowance, checked before parsing.
   `OPTIMIZED_PLAN_LIMIT_EXCEEDED`.
2. **Format.** `OPTIMIZED_PLAN_VERSION_UNSUPPORTED`: `format_version` not in the set, or understated. Every
   released version is in every later reader's set (§9.2), so this refuses only a version newer than the reader, or
   one never released.
3. **Producer and needs.** `OPTIMIZED_PLAN_PRODUCER_REVOKED`: `engine_build` is in the revocation set the caller
   passes. `OPTIMIZED_PLAN_NEEDS_OVER_LIMIT`: `needs` exceeds the limits the caller passes. When the caller passes an
   environment (image digest and manifest bytes) and the base release records, the header library also runs §10.11
   checks 1-3: `OPTIMIZED_ENV_BASE_UNRELEASED`, `OPTIMIZED_ENV_ENGINE_TOO_OLD`, `OPTIMIZED_ENV_RUNTIME_MISSING`.

The host, or the coordinator before a cut, runs steps 1-12:

4. **Contract.** `OPTIMIZED_PLAN_CONTRACT_UNSUPPORTED`: `optimizer_contract_version` newer than the host knows (an
   older released version is always known, §9.3). The refusal carries the accepted set, so a scheduler can route or ask for a rebuild (§9.5).
5. **Limits.** `plan_wire_admit`'s limits over the plan and `shared` together: depth 64, nodes 65,536
   (`src/komira_plan_wire/plan_wire_admit.mojo:197`, `:228`). `OPTIMIZED_PLAN_LIMIT_EXCEEDED`.
6. **Decode** in the OPTIMIZED context; the value checks in `plan_wire_values.mojo` still run.
7. **Canonical, digest, upgrade.** `OPTIMIZED_PLAN_NOT_CANONICAL` (against the canonical form of the plan's own
   version), then `OPTIMIZED_PLAN_DIGEST_MISMATCH` (over the bytes as produced). Then, for a plan whose contract
   version has upgrade steps (§9.3), the chain runs on the decoded plan, and steps 8-11 see the upgraded plan.
8. **Structure**, each refused by name:
   - `OPTIMIZED_JOIN_BUILD_SIDE_MISSING`, `OPTIMIZED_JOIN_BUILD_SIDE_UNSUPPORTED`, `OPTIMIZED_JOIN_ALGO_UNDECIDED`
   - `OPTIMIZED_JOIN_EXCHANGE_INCONSISTENT`
   - `OPTIMIZED_AGG_MODE_MISSING`
   - `OPTIMIZED_AGG_PAIR_MISMATCH` (a FINAL whose input does not reach a PARTIAL with the same group keys and
     aggregate list, through exchanges only)
   - `OPTIMIZED_CSE_REF_UNRESOLVED`, `OPTIMIZED_SHARED_SUBPLAN_UNREFERENCED`
   - `OPTIMIZED_SCAN_PIN_MISSING`
   - `OPTIMIZED_SCAN_BOUNDEDNESS_MISSING`, `OPTIMIZED_SCAN_BOUNDEDNESS_UNSUPPORTED`,
     `OPTIMIZED_UNBOUNDED_INPUT_UNSUPPORTED`, `OPTIMIZED_NEEDS_UNBOUNDED_MISMATCH`
   - `OPTIMIZED_UDF_UNDECLARED`, `OPTIMIZED_UDF_UNREFERENCED` (uncut plan only), `OPTIMIZED_UDF_KIND_ARM_MISMATCH`,
     `OPTIMIZED_UDF_STEP_NOT_VOLATILE`, `OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH`, `OPTIMIZED_SCOPE_UNDECLARED`
   - `OPTIMIZED_UDF_RUNTIME_MALFORMED`, `OPTIMIZED_UDF_RUNTIME_UNDECLARED`, `OPTIMIZED_NEEDS_RUNTIME_UNUSED`,
     `OPTIMIZED_NEEDS_RUNTIME_ABI_CONFLICT`
   - `OPTIMIZED_UDF_LEGACY_FORM`, `OPTIMIZED_UDF_IN_SCAN_FILTER`, `OPTIMIZED_UDF_GROUP_EXCHANGE_INCONSISTENT`,
     `OPTIMIZED_UDF_RESOURCES_UNDECLARED`
   - `OPTIMIZED_UDF_RETURN_TYPE_MISSING`, `OPTIMIZED_UDF_STATE_TYPE_MISSING`, `OPTIMIZED_UDF_SCHEMA_DISAGREES`
   - `OPTIMIZED_UDF_AGGREGATE_OUTSIDE_AGGREGATE`, `OPTIMIZED_UDF_AGGREGATE_NOT_DECOMPOSABLE`,
     `OPTIMIZED_UDF_AGGREGATE_UNBOUNDED_GROUP`
   - `OPTIMIZED_UDF_ROW_READ_SET_INVALID`, `OPTIMIZED_UDF_ROW_NULL_MODE`
   - `OPTIMIZED_FIELD_UNSUPPORTED` (a statistics field on a node, §5.2)
   - on a segment only: `OPTIMIZED_EXCHANGE_PARTITIONS_UNSET`
   - the structural refusals of §15.10.1 (its pin refusals run in step 9)
9. **Pins and environment.** Resolve and verify every pin (`OPTIMIZED_PLAN_SNAPSHOT_STALE`). Repeat §10.11 checks 1-3
   and run checks 4-7 against the image this host runs (`OPTIMIZED_ENV_CODE_MISSING`, `OPTIMIZED_ENV_PACKAGE_MISSING`,
   `OPTIMIZED_ENV_RESERVED_PATH`, `OPTIMIZED_UDF_DESCRIPTOR_INVALID`, `OPTIMIZED_UDF_KIND_UNSUPPORTED`). Bind each
   runtime and its transport, and load every `UdfRef` and data blob before any data is read
   (`OPTIMIZED_UDF_CODE_DIGEST_MISMATCH`, `OPTIMIZED_UDF_CODE_UNLOADABLE`).
10. **Lower**, applying only the §5.3 rules, with footers from the verified open.
11. **Post-condition.** `OPTIMIZED_LOWERING_DIVERGED` (§7.3).
12. **Run.**

A host repeats step 3's revocation check itself, because a stored or replayed plan may never pass a scheduler.
Refusal names are permanent. A retired check keeps its name reserved.

### 7.3 Making "do not re-optimize" checkable

A flag cannot be checked, so the rule is backed by two checks that can each be made to fail.

1. **Build graph.** The host lowering target's closure must not contain `komira_optimizer`. Three host-local rules
   live in that package today (payload narrowing, scan sharing and the scalar-subquery passes), and it is one
   library (`srcs = glob(["**/*.mojo"])`, `src/komira_optimizer/BUCK`). So those passes move first into a new
   package, `komira_lowering_rules`, whose closure also must not contain `komira_optimizer` (§12, stage 6). A
   Buck2 closure assertion checks both, proven by planting the dependency and watching the build go red.
2. **Post-condition** (step 11). The physical plan's join tree, build sides, algorithms, aggregate modes,
   exchanges and UDF evaluation sites (each UDF evaluated at the node that carries it, and a non-`VOLATILE` CSE'd call
   evaluated once) must equal the admitted plan **modulo an enumerated rewrite set**, one entry per host-local rule, each
   a named and checkable difference. For example: `SCALAR_FOLD` removes exactly one CROSS join whose other input is
   a single-row scalar subplan, and replaces the reference with a literal; shared-subplan materialization replaces
   each `cse_ref` with a read of the materialized entry; an adaptive change of §8.3 appears in the run's record.
   Named mutants:
   - a lowering that flips `build_side` is refused;
   - a lowering that re-derives the build side from row counts, as scan sharing does today, is refused;
   - a `SCALAR_FOLD` that also drops a sibling join is refused;
   - a lowering that evaluates a `VOLATILE` UDF twice for one row, or moves it below a filter, is refused.

---

## 8. Segments: cross-host splits

### 8.1 Messages

```proto
// One piece of a cut plan. Produced and consumed by the SAME engine build; no cross-build promise.
// A stored cut does not outlive an engine upgrade; it is re-derived from its stored OptimizedPlan (§9.6).
message OptimizedSegment {
  bytes                  engine_build       = 1;  // the coordinator's build; a host of another build refuses
  bytes                  parent_plan_digest = 2;  // the verified OptimizedPlan.plan_digest
  uint32                 segment_id         = 3;
  bytes                  segment_digest     = 4;  // sha256 over the canonical segment with this field cleared
  SegmentContract        contract           = 5;  // output schema; partitioning (keys, key_encoding,
                                                  // partitions); ordering; write_target on the final segment
  DeclaredNeeds          needs              = 6;  // udfs is the parent's list, unchanged, so udf_index stays valid
  repeated SharedSubplan shared             = 7;  // the entries this segment references
  repeated ScanPin       scan_pins          = 8;  // the parent's list, unchanged, so pin_ref stays valid
  repeated PinGroup      pin_groups         = 12; // the parent's list, unchanged (§15.3.4)
  oneof body {
    WirePlan logical = 10;                        // OPTIMIZED context; exchange leaves replaced (§8.2)
  }
  reserved 11; reserved "physical";               // §11
}

message OptimizedSegmentDag {
  repeated OptimizedSegment segments = 1;  // topologically ordered, producers first
  repeated ExchangeEdge     edges    = 2;
}

message ExchangeEdge {
  uint32       producer_segment = 1;
  uint32       consumer_segment = 2;
  ExchangeKind kind             = 3;
  repeated uint32 keys          = 4;
  KeyEncoding  key_encoding     = 5;
  uint32       partitions       = 6;  // non-zero
  uint32       key_groups       = 7;  // the exchange's key_groups, copied unchanged (§8.4)
}
```

A segment host refuses a build mismatch (`OPTIMIZED_SEGMENT_BUILD_MISMATCH`) and an unset or unknown body
(`OPTIMIZED_SEGMENT_BODY_UNKNOWN`), recomputes `segment_digest` (`OPTIMIZED_SEGMENT_DIGEST_MISMATCH`), and then
runs §7.2 steps 5-12 on the segment. On a single host the cut still runs and emits a one-segment DAG with every
exchange elided, so hosts admit one form.

### 8.2 Who decides what

1. The producer declares `needs.resources.host_count_max`. When it is above 1, the producer places
   `WireExchangeNode`s for that maximum, with `partitions = 0`, and marks those whose kind or fan-out may change at
   runtime as `adaptive_allowed`. A keyed stateful node's `HASH` exchange is placed at any maximum (§8.4).
2. The scheduler picks hosts.
3. The coordinator is the first party that knows the host count, and it is the same build as the hosts. It verifies
   `plan_digest` on the uncut plan (§7.2 steps 1-8), then runs the **cutter**:
   - each exchange becomes an edge;
   - below it, a sink leaf is added (a new `WireSinkBinding`, which does not exist yet);
   - above it, a scan of the shuffle partition is added (a new scan source over the reader in
     `src/komira_shuffle/source.mojo`);
   - `partitions` is filled in;
   - with one host, every exchange is elided, including one placed for keyed state (§8.4).

**The cut is not optimization.** It changes no §5.2 field, reorders no join and adds no aggregate split. A test
asserts this by comparing the decisions of the uncut plan with the union of the segments. Mutants: a cutter that
reorders a join, and one that flips a build side, must each go red.

**Cutter limit.** A `cse_ref` whose shared subplan feeds more than one segment is refused
(`OPTIMIZED_SEGMENT_CSE_CROSSES_CUT`) until the cutter can materialize a shared subplan as its own segment.

### 8.3 Adaptive execution

At sealed stage boundaries a host may coalesce reducers and split skewed partitions on an exchange marked
`adaptive_allowed`, and switch a join between broadcast and partitioned when the **join** is marked
`adaptive_allowed` (the switch changes the exchanges on both inputs, so one exchange cannot authorize it). Each such
change is recorded so a replay reproduces it, and the post-condition compares against the recorded change. A join
reorder, a build-side flip or an aggregate-mode change during execution is never allowed; a large estimate miss
spills instead.

### 8.4 Key groups

The streaming forms of stateful operators, and their state contract, come under a later `format_version` (§5.2;
[`plan_models.md`](plan_models.md) §3.5-§3.6). Their exchanges are fixed here, so the cut can carry them.

- **The field.** A `HASH` exchange that feeds a keyed stateful node sets `key_groups > 0`: keys hash into that many
  buckets, and state is laid out per bucket. Every `HASH` exchange feeding one stateful node has the same
  `key_groups` and `key_encoding`. On every other exchange `key_groups` is 0, so the canonical form (§7.1) has one
  encoding. The producer fixes it for the plan's life and refuses `host_count_max > key_groups`
  (`OPTIMIZED_KEY_GROUPS_TOO_FEW`).
- **The cut.** The cutter copies `key_groups` onto the edge unchanged, fills `partitions` with the host count, and
  gives each host a contiguous range of groups. A rescale moves state group by group; a key never changes group.
- **Placement.** Such an exchange is in the plan even when `host_count_max = 1`, the exception in §8.2 step 1. At one
  host the cut elides it as it elides every exchange, and the state is still laid out by key group, so a single-host
  run can be rescaled.
- **Frozen meaning.** The key → group function (the hash function, its seed and the key encoding) is frozen per
  `optimizer_contract_version` (§9.3); otherwise state written by one build would be routed wrongly by another.
- **Numbers.** `WireExchangeNode.key_groups = 8` and `ExchangeEdge.key_groups = 7` are the next free numbers, never
  released. The first is added under the `format_version` that adds the stateful streaming forms (§9.2); the second,
  like every segment message, carries no cross-build promise (§9.6).

---

## 9. Versioning: backward compatibility, always

### 9.1 The promise

The format promises **backward compatibility with no window**: every header reader, coordinator and host built from
any later release accepts and executes every `OptimizedPlan` that any released producer ever emitted. The promise
covers plans in flight, plans a scheduler or a run record keeps for replay, and plans stored in the definition of a
recurring job. It also covers a bound plan (`WirePlanEnvelope`, RAW) that a service stores in order to re-optimize it
on each run (§2): every later producer binds and optimizes it.

"Accepts and executes" means the plan passes admission (§7.2) unless it is invalid for a reason unrelated to its age
(a digest mismatch, a stale snapshot pin, `needs` over a limit), and on the same pinned data it produces the result it
produced under the build that first ran it. For a plan with UDFs, the engine that executes it is the one in its
environment image: the plan executes forever with the image it was recorded with, and with any later image that passes
§10.11; it is never refused for its age (§10.12). The one exception is revocation of a specific producer build (§9.7).

### 9.2 `format_version` and how the messages evolve

`format_version` follows the envelope's rule (`plan.proto:1615-1640`): a **minimum reader capability**, checked by
set membership and never by `>=`, and an understated version is refused. Because a host refuses unknown fields in
the body (§7.1), **every new body field bumps it**; there is no "harmless field" exception for this type. Each
version is defined by the set of fields it may carry, and a producer writes the lowest version whose field set the
plan actually uses.

Every reader's accepted set holds **every released version**; a version is never retired. The evolution rules, for
every message reachable from `OptimizedPlan` and for the enums they use:

- Add fields and enum values only, each under a new `format_version`.
- Never renumber a field, never reuse a number or a name, never change a field's type, and never change the meaning
  of a field or an enum value. A different meaning is a new field or a new value.
- A field or value that a released version may carry stays in the schema and in the reader forever. A producer may
  stop writing it; readers keep accepting and executing it.
- A field or value removed before any release could carry it is `reserved`, number and name, as
  `plan_vocabulary.proto:56-57` does for retired plan tags.
- `*_WIRE_UNSPECIFIED = 0` keeps its meaning: refused wherever a value is required.
- The canonical form (§7.1) of a released version is frozen. A new canonical rule applies only to versions defined
  after it, and a host checks each plan against its own version's form.

### 9.3 `optimizer_contract_version`

It names the meaning, as a host must lower them, of the decisions in the body. It bumps when any of these changes:

- the lowering meaning of a §5.2 field, including the set of `(join type, build side)` pairs a host can lower;
- the set of host-local rules or the rewrite set of §7.3;
- the canonical form;
- the meaning of a snapshot pin;
- the key → group function of a keyed exchange (§8.4).

It does **not** bump when optimizer heuristics improve: a host executes an older optimizer's decisions correctly; it
just executes older choices.

**Meaning is frozen per version.** Once version N is released, its meaning never changes, and every later host
executes version-N plans with version-N meaning, in one of two ways:

1. **Keep the lowering.** The host keeps code for every decision value any released contract version admits. This is
   the default, because most changes add a value (a new join algorithm, a newly lowerable `(join type, build side)`
   pair), and an addition leaves older plans untouched.
2. **A versioned upgrade step on read.** `upgrade_N_to_N+1` is a total function from valid version-N plans to
   version-N+1 plans with the same result. It runs after the digest check (§7.2 step 7), and steps compose into a
   chain up to the host's version. It translates; it does not optimize. It changes no join order, build side,
   algorithm or aggregate mode except through named entries in its own rewrite set, and the post-condition (§7.3)
   compares the lowering against the upgraded plan. An upgrade step never refuses a valid plan of its source
   version: there is no "too old".

A new decision is preferably a new field or enum value under a new `format_version`; a contract bump is the last
resort. A host's accepted set is every released contract version up to its own.

### 9.4 The golden corpus

For each released `format_version` and each released `optimizer_contract_version`, the release's producer emits a
corpus of plans. They are committed at release time under `src/komira_optimized_plan/tests/fixtures/corpus/`, with
the small pinned data files they read and the expected output of each. The corpus is **append-only**: a release adds
files, and a CI check refuses a change that edits or deletes one.

The header, admission and lowering targets each weld a test (`test_srcs`) that, for every corpus plan, decodes it,
recomputes `plan_digest`, admits it with an empty revocation set, runs the upgrade chain, lowers it, executes it on
the pinned data and compares the output with the expected output. A second assertion checks coverage: every field
and enum value that any released version admits appears in at least one corpus plan, so a new decision value cannot
ship without one. The corpus also holds bound plans (`WirePlanEnvelope`) as a released producer stores them for
re-optimization (§9.1); a test welded into `komira_plan_producer` optimizes each one and admits the result.

UDF plans and streaming plans are in the corpus too. Each UDF kind, each runtime, each code form and both aggregate
forms has at least one corpus plan:

- The `komira/python` `PACKAGE` and `BUNDLE` forms reference a pure-Python fixture module committed with the corpus;
  the `komira/node` `BUNDLE` form references a fixture bundle.
- Each UDF corpus plan, with its environment, is executed on the newest released base of its runtime ABI. When new
  bases stop shipping a minor, its plans keep running on the last base that shipped it, which stays released
  (§10.12). No corpus test asserts a refusal for age.
- A streaming corpus plan reads an `UNBOUNDED` fixture source that delivers a fixed sequence and then reports
  `Closed`, so the runner can compare the output emitted once the fixture is drained.

The coverage assertion covers every `UdfKind` value (`ROW`, `MAP_BATCHES_COLUMN` and `MAP_BATCHES_FRAME` included),
every `CodeForm`, `UdfStability`, `UdfNullMode` and `Boundedness` value, and each shipped runtime id. Mutants: a
lowering that treats `PROPAGATE` as `MANUAL` for the first contract version; a corpus runner that executes a UDF plan
on the newest base regardless of its runtime ABI (the payload fails to load).

**`ROW` cases** (`udf_runtime_interface.md` §6.3). A plan case reads 2 fields of a 100-column scan through a `ROW`
UDF and asserts that the scan's `projection` and the call's arguments equal the read set (mutant: lowering passes
the whole input row). Run cases: `f(r) = r.a if r.flag else r.b` with read set `{flag, a}`, over a batch where some
row has `flag` false, fails with `UDF_FIELD_NOT_DECLARED` naming `b` and never returns null (mutant: the row proxy
returns null for an unknown name); the same function with read set `{flag, a, b}` passes; one that catches the
exception around the undeclared read still fails.

**Runtime-swap invariance** (`udf_runtime_interface.md` §3.2). Every query in the UDF corpus is planned twice; the
second time every `UdfRef.code` is replaced by `{runtime: "komira-test/null"}` with its other fields empty, and every
`needs.runtimes` entry likewise. After the same substitution is applied to the first result, the two optimized plans
must be equal: the optimizer never reads `code`. Mutant: an optimizer rule that skips CSE when
`runtime == "komira/python"`; the test must go red.

What it catches, each with a planted mutant that must turn it red:

- a renumbered or reused field, or a changed field type: decoding fails or the digest differs. Mutant: swap two
  field numbers in `WireJoinNode`.
- a released version dropped from an accepted set: admission refuses. Mutant: remove the oldest `format_version`.
- a canonical rule changed for an old version: `OPTIMIZED_PLAN_NOT_CANONICAL`. Mutant: change NaN canonicalization
  for every version.
- a changed meaning of a field or enum value, or a lowering removed for an old decision value: a refusal or a wrong
  result. Mutant: lower `AggMode.FINAL` as `SINGLE` for the first contract version.
- an upgrade step that changes a result or refuses a valid plan. Mutant: an upgrade step that drops a scan's pushed
  `filter`.
- a field or value released with no corpus plan: the coverage assertion. Mutant: add a `JoinAlgo` value without a
  corpus entry.

The corpus starts with the first release that ships this type; there is nothing to backfill.

### 9.5 Not promised: forward compatibility

An older engine need not accept a newer plan. It refuses with `OPTIMIZED_PLAN_VERSION_UNSUPPORTED` or
`OPTIMIZED_PLAN_CONTRACT_UNSUPPORTED`, each carrying its accepted set. A scheduler reads `format_version` and
`optimizer_contract_version` from the header and acts according to its deployment model:

- **Hosts with a fixed engine.** It **routes by version**: it places the plan only on hosts whose build accepts both
  versions. The header library exposes each build's accepted sets for that purpose. During a rolling deploy, a plan
  that only new hosts accept goes to new hosts.
- **The engine comes from the environment image (§10.11).** There is nowhere to route. The scheduler checks the
  image's base release before any host starts and refuses with `OPTIMIZED_ENV_ENGINE_TOO_OLD`, naming the accepted
  sets and the oldest released base that accepts the plan. The remedy is to rebuild the environment on a newer base.
  Every newer base accepts every older plan (§9.1), so a rebuild never has to choose between plans.

Because a producer writes the lowest `format_version` its plan needs, a newer producer's plans that use no new field
still run on older engines.

### 9.6 Segments, and a cut that is stored

`OptimizedSegment` and `OptimizedSegmentDag` travel between processes of one engine build within one run (§8.1). They
carry no compatibility promise: a host of another build refuses them (`OPTIMIZED_SEGMENT_BUILD_MISMATCH`), and the
segment format may change in any release.

A party that keeps a cut beyond one run, such as a long-running streaming query that restarts, stores the
`OptimizedPlan` beside it. The same build may reuse its stored cut after re-verifying `segment_digest`. After an
engine upgrade:

| Option | Verdict |
|---|---|
| The new build **re-derives** the cut from the stored `OptimizedPlan`, with the same host count | **Chosen.** The plan already carries the backward-compatibility promise. The cut is mechanical and changes no decision (§8.2), so re-cutting a fixed plan reproduces the same decisions; nothing is re-optimized, so the statistics that would change a re-optimized plan play no part. One format is promised forever instead of two, and the segment format stays free to change; its reserved physical arm (§11) is meaningful only between equal builds and could never carry such a promise. |
| Give stored segments the same backward-compatibility promise | Rejected: a second permanent format, impossible for the physical arm. |

Anything keyed to the cut, such as per-operator state identifiers, is derived from the plan and not from segment
layout, so a re-cut by a new build yields the same keys. Test: for every corpus plan with `host_count_max > 1`, the
current cutter's keys equal those recorded at release. Mutant: a cutter that numbers state by segment order. Whether
operator state written by one build can be read by another is a separate question, outside this design.

### 9.7 Revocation: the one exception

A header reader takes a set of revoked `engine_build` digests, and a host repeats the check (§7.2). It stops plans
from a specific producer build later found to be compromised or to emit wrong plans
(`OPTIMIZED_PLAN_PRODUCER_REVOKED`). Revocation names **builds, never versions**: no `format_version` or
`optimizer_contract_version` is ever revoked, and a plan of the same versions from another build is still accepted.
The remedy for a revoked plan is to produce it again with a good build.

### 9.8 The options considered

| Option | Verdict |
|---|---|
| Accept only an equal producer and host build | Rejected. Every executor deploy would break every installed client and every stored plan. |
| Always re-optimize next to the host | Rejected. It brings back the cost this design removes, and it makes the submitted plan advisory. |
| A compatibility window (the current contract version and a few before it) | Rejected. A stored plan, a recurring job's definition or a replayed run record outlives any window and would start failing on a date its owner did not choose. |
| Backward compatibility with no window, no forward promise, revocation by build | **Chosen.** Its cost is that every lowering and every upgrade step is kept forever; the corpus (§9.4) makes that checkable. |

---

## 10. User code: UDF nodes and the environment image

Specified in [`optimized_plan_udfs.md`](optimized_plan_udfs.md), §10.1-§10.14. In brief:

- A plain Python or TypeScript function becomes a `UdfRef` in `needs.udfs`, referenced by index from three new arms
  (`WireUdfApply`, an n-ary expression; `WireMapBatchesNode`; `WireStepNode`) and from the `AGG_UDF` aggregate
  function. The kinds are scalar, map-batches over a column, map-batches over a frame, aggregate (a plain function
  over a group, or a mergeable accumulator) and step. A `UdfRef` names its runtime by an open string, so native and
  managed UDFs in any language use the same reference ([`udf_runtime_interface.md`](udf_runtime_interface.md)). GPU
  UDFs come later.
- Every return type is explicit in the plan: a Python type hint or a `return_dtype=`/`schema=` argument, or in
  TypeScript a type value on the verb. A function with no type is refused by name on the user's machine.
- The plan identifies code by content digest only, through a neutral `CodeForm` (`PACKAGE`, `BUNDLE`, `VALUE`) and a
  runtime-owned descriptor. Installed Python code is referenced by module and name, project
  source by bundle digest, notebook functions and closures by the digest of a cloudpickle payload, and TypeScript by a
  bundle digest and export, or by a closure's source and its plain-data captures. The bytes live in an **environment
  image** that travels beside the plan, built FROM a released komira base that holds the engine.
- Admission checks the pair: the image derives from a released base whose engine accepts the plan's versions, every
  runtime and ABI tag in `needs.runtimes` is in the image, and the code is present and loads.
- The plan format keeps its forever-backward-compatible promise; whether code loads is a property of the image, and a
  UDF plan always runs with the image it was recorded with (§10.12).

---

## 11. The reserved physical arm

`OptimizedSegment.body` field 11 is reserved, number and name, for a later self-contained physical form: opaque
bytes with a format tag, or a reference to a compiled image. It belongs on the segment and not on the plan, because
a physical form is meaningful only between equal builds, and only the segment has that property. Reserving it now
means adding it later is not a format break. Today a segment that sets field 11 is refused
(`OPTIMIZED_SEGMENT_BODY_UNKNOWN`).

---

## 12. Implementation plan

Each stage is independently reviewable and leaves `main` green. Every stage ships its tests welded to the library
(`test_srcs`), each with a named mutant that must turn a test red.

| Stage | Package(s) | Change | Proving test and mutant |
|---|---|---|---|
| 1 | `komira_plan_wire` | Refuse `payload_narrow` and `group_topk` on encode (§5.4). | A plan carrying each is refused by name. Mutant: remove the refusal; the round-trip test sees an unequal plan. |
| 2 | `komira_plan_ir`, `komira_join_assembly`, `komira_optimizer` | Add `build_side`, aggregate `mode`, `adaptive_allowed` and the exchange variant (tag 18) to `LogicalPlan`. Join assembly honours `build_side` while output order still follows child order. The optimizer records each decision it makes. | Mutant: a join assembly that ignores `build_side` and always builds right; a test on a `build_side = LEFT` inner join sees the wrong physical build side. |
| 3 | `komira_plan_proto`, `komira_plan_wire` | The §5.2 fields and enums, the `exchange` arm and its `PlanTag` entry, `WireScanNode.boundedness`; the `WireContext` decode parameter; RAW keeps every refusal; OPTIMIZED refuses scan statistics. New goldens. | Every new field refused in RAW and required in OPTIMIZED, except `boundedness`, which RAW reads unset as `BOUNDED`; protoc text goldens round-trip; the enum-number tests cover tag 19. |
| 4 | `komira_plan_proto` | `optimized_plan.proto` (§4, §6, §8). | protoc golden fixtures for each message. |
| 5 | new `komira_optimized_plan_header`, new `komira_optimized_plan` | Header codec and steps 1-3 in the first; body and segment codecs, canonical encoder, both digests and steps 4-9 in the second. Each file under 1,000 lines. | Canonical bytes cross-checked against protoc for every golden without NaN. Mutant: perturb field order; the digest test goes red. One hostile test per refusal token. The header target's closure must exclude `komira_plan_wire`; planting it goes red. |
| 6 | new `komira_lowering_rules`, `komira_optimizer` | Move payload narrowing, scan sharing and the scalar-subquery passes out of `komira_optimizer`. Scan sharing reads `build_side` and takes row counts from an argument. | Closure lint excludes `komira_optimizer`; planting it goes red. Mutant: scan sharing that ignores `build_side`. |
| 7 | `komira_optimizer`, new `komira_plan_producer` | The portable profile (§5.3) and the producer library over SQL parsing, bind, the optimizer driver and the statistics readers, linked by every SDK and by a service re-optimizing a stored query. Cost comparisons break ties on a total integer order. | For the same bound plan, statistics and build, every producer platform yields the same `plan_digest`. Mutant: a producer that reads its config from the environment instead of its argument (`optimizer_config.mojo` reads none today). |
| 8 | `komira_optimized_plan`, `komira_shuffle` | `WireSinkBinding`, the shuffle-partition scan source, and the cutter (§8) with its "no decision changed" assertion. | Mutants: a cutter that reorders a join; one that flips a build side. |
| 9 | the host lowering target | The post-condition (§7.3) and the closure lint excluding `komira_optimizer`. | A planted dependency goes red; each §7.3 mutant is refused. |
| 10 | `komira_optimized_plan`, the host lowering target, the release machine | The golden corpus (§9.4): emitted at each release that ships this type, append-only, welded into the header, admission and lowering targets, with the coverage assertion and the stored-cut key test (§9.6). | Each §9.4 mutant goes red; editing or deleting a corpus file is refused by the CI check. |
| 11 | `komira_plan_proto`, `komira_plan_wire`, `komira_plan_ir`, `komira_plan_expr` | `UdfRef`, `UdfCode`, `CodeDigest`, `UdfKind` (with `ROW`), `CodeForm`, `RuntimeNeed`; `WireUdfApply`, `WireMapBatchesNode`, `WireStepNode`, `AggFn.AGG_UDF`, `WireField.children`, `WirePlanEnvelope.udfs`; engine tags 19, 20, expression tag 27 and aggregate tag 37; the OPTIMIZED refusal of the legacy forms. | Every §10.4 refusal by name. Mutants: a decoder that accepts `WireUdfCall` in OPTIMIZED; a `udf_index` off by one; a `WireField` that drops a grandchild; an admission that accepts a `UdfRef` with no `return_type`; one that accepts a `PARTIAL` node with a plain-form aggregate; one that accepts a `ROW` under `PROPAGATE` or with a repeated read-set name. |
| 12 | `komira_optimized_plan_header`, `komira_optimized_plan` | §10.11 checks 1-3 in the header library (the release record and the manifest bytes are arguments, never fetched), checks 4-7 and step 9's code load in the host. | One hostile test per `OPTIMIZED_ENV_*` token. Mutants: a prefix check that compares layer sets instead of an ordered prefix; a path check that ignores whiteouts; a manifest whose sha256 is not the digest. |
| 13 | the host lowering target, new Python and Node UDF worker packages, the `komira/native` loader | Native UDFs in-process by default and in workers on request; the supervisor's heartbeat token kept out of the engine; worker processes under their own user id, Arrow over shared memory, load-once caching, thread limits, the §10.10 errors, the per-batch return-type check, both aggregate forms, and the §10.9 optimizer rules in the portable profile. | Mutants: a worker that reloads the payload per batch (a load counter goes red); a host that retries a `VOLATILE` batch; a float batch accepted into an int64 return type; a Node worker that accepts an unsafe integer into int64; a mergeable aggregate whose partial state is dropped at the exchange; a group state over 64 MiB that does not fail `UDF_STATE_TOO_LARGE`; a supervisor that passes its heartbeat token to the engine (a native fixture that searches its own process's arguments, environment, readable files and descriptors finds it). |
| 14 | the host lowering target, `komira_shuffle_streaming` | The streaming driver: a plan with an `UNBOUNDED` scan runs over `StreamingMorselSource`, with the §5.2 boundedness checks and the §10.10 streaming rules for UDFs. | Mutants: a host that runs an `UNBOUNDED` plan under the batch driver (an `Idle` fixture is taken for end of input and the output is short); an admission that takes the mode from `needs.unbounded` instead of the body; a plain aggregate admitted over an unbounded input. |

**Critical path.** komira has no optimizer driver at the pinned commit: no `def optimize` exists under `src/`, and
there is no `select_join_build_side` (`git grep`). It also has no lowering target: the physical IR has no producer
or consumer in this tree (`physical_plan.mojo:5-6`). Neither producer can emit this type until a driver is written,
and no host can admit it until the lowering exists. Stages 1-6 can proceed in parallel with both; stage 7 depends on
the driver and stage 9 on the lowering.

UDFs and streaming add three items to the critical path:

- Python and Node worker runtimes, the `komira/native` loader, and the bases: one per supported CPython minor and one
  per supported Node major (§10.11). Today the base image has no engine, no Python and no Node
  (`packaging/images/base/README.md` in komira-ai/komira#1070).
- The engine's UDF executor: an in-process call (native UDFs' default) and a worker transport.
- The streaming driver. The streaming source contract exists (`src/komira_morsel/streaming_source.mojo`), but
  `git grep -l StreamingMorselSource` finds only the contract, its tests and the streaming shuffle
  (`src/komira_shuffle_streaming`); no driver runs a plan over it.

Stages 11 and 12 can proceed now. Stage 13 depends on the first two items, and stage 14 on the third.

**Size, inferred from current sizes.** `komira_plan_wire` is 12,861 source lines in five files and `plan.proto` is
1,646 lines. I expect stages 3-9 to add roughly 5,500-8,000 source lines and 11,000-14,000 test lines across 12-14
files, excluding the driver and the lowering. That is an estimate, not a measurement.

**Client prerequisites.**

- Cost decisions need Parquet footer row counts (`optimizer_eager_agg.mojo:44-60`). A producer that cannot read
  footers (no read access, or too far from the data) optimizes on default statistics (`optimizer_stats.mojo:13`) and
  records the source as `UNKNOWN` in `advice`; the plan is valid, possibly slower. There is no server-side fallback.
- `recurring_signature` needs a literal-normalizing render of the bound plan, a few hundred lines in stage 5.
- A cache of optimized plans is keyed by the sha256 of the canonical **bound** plan with its literals, plus the
  pins, the engine build, the config digest and `optimizer_contract_version`. Never by `recurring_signature`: two
  queries that differ only in a literal share a signature, and a hit would run one query's plan with the other's
  predicates.

---

## 13. Comparison with other systems

Moved to [`optimized_plan_decisions.md`](optimized_plan_decisions.md): Trino, DataFusion, Spark Connect, Substrait.

---

## 14. Questions, now decided

Moved to [`optimized_plan_decisions.md`](optimized_plan_decisions.md), with its numbering, so references to "question
N in §14" stay valid.

---

## 15. Sources, index operators and graph operators

Specified in [`optimized_plan_sources.md`](optimized_plan_sources.md), §15.1-§15.13. In brief: Iceberg, Delta,
Hive-style Parquet, topic (tail plus rolled table) and row-store reads are scan kinds with typed snapshot pins; text
and vector search over a table are an access path on its scan, pinned to an index generation with a consistency mode,
and every hit is checked against the scan's pin; a per-row index lookup and a graph traversal are two new arms; the
optimizer's choice of index or scan is a node field that hosts obey; and every SDK emits the same nodes.
