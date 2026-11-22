# lowering

Lowering: a bound `LogicalPlan`, a `HostProfile` and the resolved inputs go in;
the physical plan (`physical_plan`, IR version 16) and the `ParamTable`
its segments index come out. It is pure. `lower` opens no file, reads no clock
and no environment variable and touches no global, so equal arguments give a
`LoweredPlan` that renders byte-equal.

- `lower.lower(plan, host_profile, inputs)`: the entry. In this order: the
  cutter, the morsel size of each segment from the host profile, the purity
  gate (no segment holds a logical plan) with the IR version door, and
  admission against the sink capability table.
- `lowered_plan`: `LoweringInputs` (one `ScanFacts` per scan in scan
  pre-order: the footers' statistics and the columns every row group stores
  dictionary encoded), `ParamTable`, `LoweredPlan` and the four refusal tokens.
- `cut_walk`: the cutter. A scan opens a pipeline (`SOURCE_PARQUET`, whose
  spec lists the files when there are several; `SOURCE_BATCH` for an in-memory
  scan; `SOURCE_CSV` for a CSV scan, whose spec carries the path, the dialect
  and every column of the file with the type the plan bound it at; the pushed
  filter and projection of the last two become operators, and so do those of
  a Parquet scan with Hive partition columns, over the files' columns followed
  by the partition columns). A filter, a projection and a limit fuse into it.
  An aggregation, a distinct or a sort ends it in a sink and opens a pipeline
  that reads that segment's output over an `E3` edge. A distinct is a
  `SINK_AGG` grouped by every column, in order, with no aggregate, so its
  sink row is the one an aggregation with those group keys gets. A union
  (`UNION ALL`) ends each branch in a segment of its own (a `SINK_COLLECT`
  segment, or the branch's aggregation, distinct or sort segment when nothing
  is fused after it) and opens a pipeline whose source is `SOURCE_CONCAT` over
  those segments in branch order, with an `E3` edge to each; what stands above
  the union fuses onto or closes that pipeline. The root is a `SINK_COLLECT`
  segment unless the top node is a breaker, which is then the result.
  `cut_walk` is the dispatch on the node's tag and the resolution of shared
  subplans around it (below); each arm is its own module (`cut_scan`,
  `cut_filter`, `cut_project`, `cut_limit`, `cut_aggregate`, `cut_distinct`,
  `cut_sort`, `cut_union`, `cut_shared`), and `cut_state` holds what they
  share: the open pipeline, the cutter's segments and ParamTable, the shared
  subplans cut so far, and the close and reopen of a breaker. A new node kind
  is a new arm module and one branch in `cut_walk`.
- `cut_shared`: shared subplans. A plan may hold a subtree once, its canonical
  occurrence, and every later occurrence as a `PLAN_CSE_REF` leaf carrying the
  canonical subtree's `structural_hash()` (`optimizer.plan_cse`, which the
  producer runs: `sdk_exec.engine_sql.optimize_for_run` for `run_sql`). The canonical subtree is
  the first node of that hash the walk reaches (a node before its children,
  a union's branches in order). One that holds an aggregation, a distinct, a
  sort or a limit is cut once: it ends in a segment of its own, as a union
  branch does, and the canonical position and every reference read that
  segment over an `E3` edge (a union that holds two references names the
  segment twice in its `SOURCE_CONCAT`); the engine hands each reader the
  same rows. A reader of a sort's output is a sorted input, as the sort's own
  reader is. One that is only scans, filters, projections and unions of them
  is cut again at every reference, over the same scans: the references take
  no `ScanFacts` of their own, and the recut keeps the scans' statistics,
  dictionary-encoded keys and parallel read.
- `sum_fuse`: SUM(CAST(e AS DECIMAL(38, 0))) over a signed integer `e`, the
  SQL integer sum, is put into a sink's data as SUM(e); the node's declared
  output stays DECIMAL(38, 0) and the sink writes its 128-bit total there.
- `sink_capability`: the table of `(sink_kind, key_dtype, orientation)` rows a
  host serves, and admission. A group key picks its row from its column type
  (INT64, INT32, FLOAT64, FLOAT32, DATE32, BOOL, DECIMAL128 or STRING);
  a string key is `DICT_ENCODED` only when the scan's footers say every row
  group stores it dictionary encoded and no projection stands between the scan
  and the aggregation, and otherwise `COLUMNAR`.
- `render`: the deterministic text of a `LoweredPlan`.

## Refusals

Lowering refuses by name and never replaces what it cannot lower with another
shape:

- `LOWERING_UNCUTTABLE_NODE`, naming the node: a join, top-n,
  window, view reference, cast to string or exchange node (the cutter has no
  arm for any of them, so an exchange is refused rather than elided on one
  host; a view reference is resolved before lowering, which has no view
  registry); a shared-subplan reference reached before its canonical subtree
  or with none in the plan, or whose schema is not the canonical subtree's
  (column count, and per column the name, Arrow type, decimal precision and
  scale and timezone); a filter, projection or aggregation that carries a
  UDF, an aggregate function that is a UDF; a limit with an offset or a
  negative count; a limit above a sort (see Order); a partial or final
  aggregation; an aggregation with a group top-k; a distinct over an explicit
  column list, over no column or over two columns of one name; a source other
  than Parquet, in memory or CSV; a CSV scan with `header=false` (the reader
  would name its columns `col_0`, `col_1`, ..., where DuckDB names them
  `column0`, `column1`, ...); a union with no branch, or with a branch whose
  schema is not the union's (column count, and per column the name, Arrow
  type, decimal precision and scale and timezone; the concatenation reads
  every branch by position in the union's layout, so the producer casts and
  renames the branches first).
- `LOWERING_SINK_UNSERVED`, naming the triple or the key: a group key of a
  type with no row (an 8- or 16-bit integer, a timestamp, a binary, ...), a
  key of several columns that are not all dictionary encoded strings (a
  distinct's columns are its group keys, so a distinct over several columns is
  served only when they are), or a segment whose triple has no row.
- `LOWERING_SCAN_NOT_TOTAL`: a Hive partitioned scan that lists its files
  lazily (a directory scan or a partition predicate), a scan on a file system
  other than the local one, or a scan marked unbounded. The segment's Parquet
  arm carries the file list and the partition columns' constants, but no
  predicate or file system descriptor, and its sources read a bounded input.
  The scan's display name is not part of the segment.
- `LOWERING_INPUTS_SCAN_COUNT`: the inputs do not hold one entry per scan.

## What a segment records

`morsel_rows` comes from the host profile and the schema that flows into the
sink. `card_estimate_rows` is the row count of the scan's footers when the host
supplied statistics, an upper bound on the rows that reach the sink, and 0
otherwise. `mem_estimate_bytes` is 0, and `AggSinkData.estimated_groups` is 0:
no memory decision is recorded, and no statistic a producer recorded in the
plan is read. Every segment has one partition, and its order key is the one
the Order section names. Whether an integer key's
aggregation is dense or partitioned is not a field of the IR and is not
recorded here. The payload narrowing rule of `lowering_rules` has no
consumer without a join and is not called.

## Order

An aggregation with no group key and a `SUM` or `AVG` whose argument is
`FLOAT32` or `FLOAT64` in the child's schema is cut with `ORDER_ROW_RANGE`: the
engine's ungrouped sink then folds each source position on its own and adds
the positions' sums in position order, so the double sum is the same bits on
every worker count and schedule of one lowered plan (`pipeline_exec`). Every
other segment is `ORDER_NONE`: an integer, `DECIMAL`, `COUNT`, `MIN` or `MAX`
fold is exact in any order, and the grouped sinks fold no float argument. A
sort's output keeps the sort's order through filters,
projections and the final collect only as far as the engine's sink-output
source keeps it; lowering does not state more. A limit above a sort is
refused, because the rows it keeps would depend on that order, and a limit
above an aggregation that reads a sort is cut: the aggregation ends the sorted
stream.

## Dependencies

It depends on `host_profile`, `physical_plan`, `plan_ir`,
`plan_expr`, `plan_stats`, `scan_source`, `arrow`,
`containers` and the packages they need. Its `BUCK` file lists
`fs`, `objectstore`, `async_rt`, `shuffle`,
`engine_runtime`, `optimizer` and `sql` in
`closure_excludes`, so analysis fails if any of them enters the closure,
directly or through another package. The names are compared exactly:
`async_api`, a trait surface the closure needs, is not refused.
