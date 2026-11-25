# lowering

Lowering: a bound `LogicalPlan`, a `HostProfile` and the resolved inputs go in;
the physical plan (`physical_plan`, IR version 21) and the `ParamTable`
its segments index come out. It is pure. `lower` opens no file, reads no clock
and no environment variable and touches no global, so equal arguments give a
`LoweredPlan` that renders byte-equal.

- `lower.lower(plan, host_profile, inputs)`: the entry. In this order: the
  cutter, the morsel size of each segment from the host profile, the purity
  gate (no segment holds a logical plan) with the IR version door, and
  admission against the sink capability table.
- `lowered_plan`: `LoweringInputs` (one `ScanFacts` per scan in scan
  pre-order: the footers' statistics and the columns every row group stores
  dictionary encoded, and for an Iceberg table scan the files the host planned
  (`add_iceberg_scan`); and the plan's `UdfRef` list), `ParamTable` (`agg`, `sort`, `topn`, `window`, `batches`, and the
  `UdfRef` list whole, as `udfs`), `LoweredPlan` and the eight refusal
  tokens.
- `cut_walk`: the cutter. A scan opens a pipeline (`SOURCE_PARQUET`, whose
  spec lists the files when there are several; `SOURCE_BATCH` for an in-memory
  scan; `SOURCE_CSV` for a CSV scan, whose spec carries the path, the dialect
  and every column of the file with the type the plan bound it at;
  `SOURCE_ICEBERG` for a scan of an Iceberg table, a binding of kind
  `komira.iceberg.table`, whose spec is the one the inputs carry for that scan
  (the data files that survive pruning, the delete files that apply, and the
  bound columns with their field ids): lowering reads no table metadata and
  does not depend on the package that does; `SOURCE_JSONL` for a scan of one
  newline-delimited JSON file, whose spec names the file and the schema it is
  read at: the scan's projection, in its order, at the types the plan was
  bound at, and its pushed filter, when it has one, an operator over every
  key; the pushed filter and projection of the batch, CSV and Iceberg arms
  become operators, and so do those of
  a Parquet scan with Hive partition columns, over the files' columns followed
  by the partition columns). A step, a user function run once, opens one too
  (`SOURCE_UDF_STEP`, see User functions). A filter, a projection, a limit and
  an ungrouped frame fuse into it.
  An aggregation, a distinct, a sort or a window ends it in a sink and opens a pipeline
  that reads that segment's output over an `E3` edge. A top-n, and a limit
  that reaches a sort or a top-n through only projections (without a UDF) and
  other limits, is cut as one `SINK_TOPN` segment that keeps the composed range
  of rows `[offset, offset + n)` of the sort's order (a limit of `n` after
  `offset` over a range `(start, count)` keeps `(start + offset, min(n, count -
  offset))`, at least zero rows, with offsets saturating at the largest
  integer); the projections between are fused, bottom up, onto the pipeline
  that reads that segment. A distinct is a
  `SINK_AGG` grouped by every column, in order, with no aggregate, so its
  sink row is the one an aggregation with those group keys gets. A union
  (`UNION ALL`) ends each branch in a segment of its own (a `SINK_COLLECT`
  segment, or the branch's aggregation, distinct or sort segment when nothing
  is fused after it) and opens a pipeline whose source is `SOURCE_CONCAT` over
  those segments in branch order, with an `E3` edge to each; what stands above
  the union fuses onto or closes that pipeline. A join
  (`cut_join`: INNER, LEFT, RIGHT, FULL, SEMI, ANTI and CROSS) ends its build
  child in a `SINK_HASH_BUILD` segment and fuses an `OP_JOIN_PROBE` into the
  probe child's pipeline, with an `E3` edge to the build segment. A window (`cut_window`, one node
  with every function of one `OVER` clause) ends its child in a
  `SINK_PARTITION_BY` segment whose `sink_param_id` indexes
  `ParamTable.window`, opens a pipeline that reads it, and marks that
  pipeline as a sorted stream when the node has a key. The root is a `SINK_COLLECT`
  segment unless the top node is a breaker, which is then the result.
  `cut_walk` is the dispatch on the node's tag and the resolution of shared
  subplans around it (below); each arm is its own module (`cut_scan` and
  its JSON arm `cut_scan_jsonl`, `cut_filter`, `cut_project`, `cut_limit`,
  `cut_aggregate`, `cut_distinct`, `cut_sort`, `cut_topn`, `cut_window`,
  `cut_union`, `cut_join`,
  `cut_shared`), and `cut_state` holds
  what they share: the open pipeline, the cutter's segments and ParamTable,
  the shared subplans cut so far, and the close and reopen of a breaker. A new
  node kind is a new arm module and one branch in `cut_walk`.
- `cut_shared`: shared subplans. A plan may hold a subtree once, its canonical
  occurrence, and every later occurrence as a `PLAN_CSE_REF` leaf carrying the
  canonical subtree's `structural_hash()` (`optimizer.plan_cse`, which the
  producer runs: `sdk_exec.engine_sql.optimize_for_run` for `run_sql`). The
  canonical subtree is the first node of that hash the walk reaches (a node
  before its children, a union's branches in order, and in a plan that holds
  a reference a join's right child before its left, the producer's order; the
  scan count is set for each child of the join, so the scans keep their
  pre-order indices). One that holds an aggregation, a distinct, a sort, a
  window, a limit or a join is cut once: it ends in a segment of its own, as
  a union branch does, and the canonical position and every reference read
  that segment over an `E3` edge (a union that holds two references names the
  segment twice in its `SOURCE_CONCAT`); the engine hands each reader the
  same rows. A reader of a sort's, a top-n's or a keyed window's output is a
  sorted input, as the breaker's own reader is. One that is only scans, filters, projections and unions of them
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
  group stores it dictionary encoded and no projection or join stands between
  the scan and the aggregation, and otherwise `COLUMNAR`. A key of several
  columns is `(STRING, DICT_ENCODED)` when every column is such a dictionary
  string, and `(COMPOSITE, COLUMNAR)` otherwise: any mix of those types, each
  column keeping its own (a distinct's columns are its group keys, so a
  distinct over several columns gets the same row). The last row is
  `(SINK_HASH_BUILD, NONE, COLUMNAR)`, a join's build segment; it indexes no
  ParamTable row, so its `sink_param_id` is -1. `(SINK_PARTITION_BY, NONE,
  COLUMNAR)`, after the sort row, is a window's segment; it indexes
  `ParamTable.window`.
- `udf_check`: what a user-function call is held to before it is cut (see
  User functions).
- `render`: the deterministic text of a `LoweredPlan`.

## User functions

A plan names a user function by its index in the `UdfRef` list beside it
(`LoweringInputs.add_udf`, in the list's order); the lowered plan carries the
list whole (`ParamTable.udfs`) and each call names its entry by the same
index. Three shapes are cut, each into the IR's `UdfCallSpec`:

- `PLAN_MAP_BATCHES` with no group key (`cut_map_batches`): an `OP_UDF_FRAME`
  fused onto the child's pipeline, called once per morsel with exactly the
  columns of the function's read set, in the set's order. Its output (the
  node's schema) replaces the morsel. Past it the pipeline keeps no row
  estimate, no dictionary encoded key and no sort order.
- `PLAN_STEP` (`cut_step`): a pipeline whose source is `SOURCE_UDF_STEP`, the
  call with its literal arguments. It is not a scan and takes no `ScanFacts`.
- A projection column that is wholly an `EXPR_UDF_APPLY` (under any aliases)
  of a `SCALAR`, `ROW` or `MAP_BATCHES_COLUMN` function (`cut_project`): an
  `OP_UDF_APPLY` fused before the projection's `OP_PROJECT`, which appends the
  call's result as column `__udf_apply:<i>` (`i` the column's position) for
  the `OP_PROJECT` to read in the call's place.

A shared subplan that holds a frame or a step is cut once, never again at
each reference, so its calls run once.

**The read set is explicit.** A `ROW` or `MAP_BATCHES_FRAME` function
receives the columns of its read set and nothing else. Lowering refuses,
with `LOWERING_UDF_UNDECLARED_READ` naming the column and the set, a call
that would hand it a column the set does not declare: a `ROW` call whose
argument reads one, and a frame whose group key reads one. A function of
either kind that declares no read set is refused with the same token; an
unset read set is never widened to every input column. A read the code makes
outside its set is refused when the code runs, by its runtime
(`UDF_FIELD_NOT_DECLARED`), since the engine passes no other column.

## Refusals

Lowering refuses by name and never replaces what it cannot lower with another
shape:

- `LOWERING_UNCUTTABLE_NODE`, naming the node: a partition top-n,
  view reference, cast to string or exchange node (the cutter has no
  arm for any of them, so an exchange is refused rather than elided on one
  host; a view reference is resolved before lowering, which has no view
  registry); a shared-subplan reference reached before its canonical subtree
  or with none in the plan, or whose schema is not the canonical subtree's
  (column count, and per column the name, Arrow type, decimal precision and
  scale and timezone); a filter, projection or aggregation that carries a
  UDF of the registered kind (`has_udf`), an aggregate function that is a UDF
  (`AGG_UDF`); a limit with a negative
  count or a negative offset, or a top-n with a negative count; a limit with
  an offset that does not reach a sort (only a sort's output has an order to
  skip rows of); a limit over a sorted stream that is not one range of its
  sort (a filter stands between them, or the sort or a node between is a
  shared subplan other readers read whole, or the stream is the output of a
  window with a partition or order key; see Order); a partial or final
  aggregation; an aggregation with a group top-k; a distinct over an explicit
  column list, over no column or over two columns of one name; a source other
  than Parquet, in memory, CSV, JSON or an Iceberg table; a JSON scan whose
  projection names a column its schema does not hold; a CSV scan with `header=false` (the reader
  would name its columns `col_0`, `col_1`, ..., where DuckDB names them
  `column0`, `column1`, ...); a union with no branch, or with a branch whose
  schema is not the union's (column count, and per column the name, Arrow
  type, decimal precision and scale and timezone; the concatenation reads
  every branch by position in the union's layout, so the producer casts and
  renames the branches first).
- `LOWERING_WINDOW_UNSERVED`, naming the reason, raised before the child of
  the window is walked: a descending list whose length is not the order keys';
  a partition or order key that is not a column of the child or whose type is
  not INT64, INT32, FLOAT64, BOOL or STRING; an `NTILE` bucket count or an
  `NTH_VALUE` n that is not above 0; a `LAG`, `LEAD`, `FIRST_VALUE`,
  `LAST_VALUE` or `NTH_VALUE` argument that is not an INT64, FLOAT64 or STRING
  column; a `SUM`, `AVG`, `MIN` or `MAX` argument that is not an INT64 or
  FLOAT64 column; an argument that is not a column of the child; a `LAG` or
  `LEAD` default the column would change (a float over INT64, a string over a
  number, anything but a string over STRING); a function the sink does not
  compute; and, for a value function or aggregate, a frame SQL refuses (a
  start of `UNBOUNDED FOLLOWING`, an end of `UNBOUNDED PRECEDING`, a
  `FOLLOWING` start ending at `CURRENT ROW` or `PRECEDING`, a `CURRENT ROW`
  start ending `PRECEDING`, each with DuckDB's reason), a negative offset,
  frame units that are
  neither `ROWS` nor `RANGE`, and a `RANGE` frame with an offset over a
  window whose `ORDER BY` is not one key of type INT64, INT32 or FLOAT64.
  Every other `ROWS` or `RANGE` frame is served. The sink declares a `SUM`,
  `AVG`, `MIN` or `MAX` column nullable when its argument is, and a `SUM`,
  `AVG`, `MIN`, `MAX`, `FIRST_VALUE` or `LAST_VALUE` column nullable when
  its frame need not hold the current row (and so can be empty).
- `LOWERING_JOIN_UNSERVED`, naming the reason, raised before either child of
  the join is walked: a join type the plan IR does not define, a SEMI or ANTI
  join that builds its left side, a CROSS join that names a key, an equi-join
  with no key or with key lists of different lengths, more than 8 keys, a
  residual predicate, the sort-merge algorithm hint, a build side the plan
  does not define, a key that is not a column of its side, a key pair whose
  types the probe does not compare (INT64 and INT32 in any pairing, FLOAT64
  with FLOAT64, STRING with STRING), and a join whose output names one column
  twice.
- `LOWERING_SINK_UNSERVED`, naming the triple or the key: a group key with a
  column of a type with no row (an 8- or 16-bit integer, a timestamp, a
  binary, ...), alone or beside served columns, or a segment whose triple has
  no row.
- `LOWERING_SCAN_NOT_TOTAL`: a Hive partitioned scan that lists its files
  lazily (a directory scan or a partition predicate), a Parquet scan on a
  store other than the local file system, S3, GCS and Azure (a scheme code
  that names none of them, by its number: `scheme 9://raw`), a local scan
  with an explicit file system binding, an Iceberg scan whose files the inputs
  do not carry (`an Iceberg scan whose files were not planned`), or a scan
  marked unbounded. The segment's Parquet arm carries the file list, the
  partition columns' constants and the store (`parquet_fs`: local, or an S3 or
  GCS bucket or an Azure container whose object keys the paths are), but no
  predicate, and its sources read a bounded input.
  The scan's display name is not part of the segment.
- `LOWERING_INPUTS_SCAN_COUNT`: the inputs do not hold one entry per scan.
- `LOWERING_UDF_UNDECLARED_READ`, naming the node, the `UdfRef` index and
  kind, the column and the read set: a `ROW` call's argument or a frame's
  group key that reads a column outside the function's read set, and a `ROW`
  or frame function that declares no read set.
- `LOWERING_UDF_UNSERVED`, naming the reason, raised before the node's child
  is walked: an index with no entry in the `UdfRef` list; an entry whose kind
  the node or call does not take (a frame node calls `MAP_BATCHES_FRAME`, a
  step node `STEP`, a call in an expression `SCALAR`, `ROW` or
  `MAP_BATCHES_COLUMN`); a call whose argument count, or a step whose literal
  count, is not the entry's declared argument count; a read set naming a
  column the input does not output, or outputs twice; a grouped frame (one
  call per group needs that group's rows gathered, which no segment does
  yet); a call inside another call's argument, inside a larger expression of
  a projection column (an operator, a function or a CASE, which evaluate it
  only on the rows they select), in a filter's predicate, in an aggregation's
  group key or argument, or in a frame's group key; a projection whose input
  already has the column name an `OP_UDF_APPLY` would append.

## What a segment records

`morsel_rows` comes from the host profile and the schema that flows into the
sink. `card_estimate_rows` is the row count of the scan's footers when the host
supplied statistics, an upper bound on the rows that reach the sink, and 0
otherwise and after a join or a frame (either can emit more rows than its
input has) and in a pipeline a step opens. `mem_estimate_bytes` is 0, and `AggSinkData.estimated_groups` is 0:
no memory decision is recorded, and no statistic a producer recorded in the
plan is read. Every segment has one partition, and its order key is the one
the Order section names. Whether an integer key's
aggregation is dense or partitioned is not a field of the IR and is not
recorded here. The payload narrowing rule of `lowering_rules` is not
called: the build segment of a join collects its rows whole.

## Joins

The build side is the one the plan records (`JoinData.build_side`). Lowering
never chooses or swaps it: RIGHT builds the right child, LEFT the left child,
and UNSET builds the right child. The left child is walked first, then the
right, so scans are met in pre-order whichever side builds; in a plan that
holds a shared-subplan reference the right child is walked first, as the
reference's producer visits a join, with the scan count set for each child,
so the scans keep their pre-order indices and the right child's segments take
the lower ids. The probe emits
its own columns and then the build columns (a SEMI or ANTI probe, its own
columns only). The `OP_JOIN_PROBE`'s join type is the probe's view, the probe
side as its left input: the plan's type when the right child builds; when the
left child builds, LEFT and RIGHT are exchanged and INNER, FULL and CROSS stay,
and a projection fused after the probe restores the node's column order and
names. A SEMI or ANTI join that builds its left child is refused. A CROSS join
names no key and its probe carries empty key lists. Several
joins on one probe pipeline each add their own build segment. A join, like a
projection, leaves no dictionary key to an aggregation above it.

## Order

An aggregation, grouped or not, with a `SUM` or `AVG` whose argument is
`FLOAT32` or `FLOAT64` in the child's schema is cut with `ORDER_ROW_RANGE`: the
engine's sink then folds each source position on its own (per group, in a
grouped sink) and adds the positions' sums in position order, so the double
sum is the same bits on every worker count and schedule of one lowered plan
(`pipeline_exec`). Every other segment is `ORDER_NONE`: an integer,
`DECIMAL`, `COUNT`, `MIN` or `MAX` fold is exact in any order. A
sort's output keeps the sort's order through filters,
projections and the final collect only as far as the engine's sink-output
source keeps it; lowering does not state more. A limit that reaches a
sort through projections and limits is cut as a `SINK_TOPN` segment, which
answers rows of the sort's order, ties kept in the collected order. A limit
above a sort with a filter between them is refused, because the rows it keeps
would depend on an order no segment records; so is a limit whose sort, or a
node between them, is a shared subplan other readers read whole (a sort that
only reads a shared subplan's segment is still one range), and a limit above a
window with a partition or order key (its rows come out in key order). A limit
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
