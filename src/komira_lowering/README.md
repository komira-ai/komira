# komira_lowering

Lowering: a bound `LogicalPlan`, a `HostProfile` and the resolved inputs go in;
the physical plan (`komira_physical_plan`, IR version 14) and the `ParamTable`
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
- `cut_walk`: the cutter. A scan opens a pipeline (`SOURCE_PARQUET`, or
  `SOURCE_BATCH` for an in-memory scan, whose pushed filter and projection
  become operators). A filter, a projection and a limit fuse into it. An
  aggregation or a sort ends it in a sink and opens a pipeline that reads that
  segment's output over an `E3` edge. The root is a `SINK_COLLECT` segment
  unless the top node is a breaker, which is then the result.
- `sink_capability`: the table of `(sink_kind, key_dtype, orientation)` rows a
  host serves, and admission. A group key picks its row from its column type;
  a string key is `DICT_ENCODED` only when the scan's footers say every row
  group stores it dictionary encoded and no projection stands between the scan
  and the aggregation, and otherwise `COLUMNAR`.
- `render`: the deterministic text of a `LoweredPlan`.

## Refusals

Lowering refuses by name and never replaces what it cannot lower with another
shape:

- `LOWERING_UNCUTTABLE_NODE`, naming the node: a join, union, distinct, top-n,
  window, view or shared-subplan reference, cast to string, exchange or UDF
  node; a limit with an offset; a partial or final aggregation; a source other
  than Parquet or in memory.
- `LOWERING_SINK_UNSERVED`, naming the triple or the key: a group key of a
  type with no row (date, decimal, bool, ...), a key of several columns that
  are not all dictionary encoded strings, or a segment whose triple has no row.
- `LOWERING_SCAN_NOT_TOTAL`: a Parquet scan of several files, a Hive
  partitioned scan, or a scan on a file system other than the local one. The
  segment's Parquet arm names one file and carries no partition columns or
  file system descriptor.
- `LOWERING_INPUTS_SCAN_COUNT`: the inputs do not hold one entry per scan.

## What a segment records

`morsel_rows` comes from the host profile and the schema that flows into the
sink. `card_estimate_rows` is the row count of the scan's footers when the host
supplied statistics, an upper bound on the rows that reach the sink, and 0
otherwise. `mem_estimate_bytes` is 0, and `AggSinkData.estimated_groups` is 0:
no memory decision is recorded, and no statistic a producer recorded in the
plan is read. Every segment is `ORDER_NONE` with one partition. Whether an
integer key's aggregation is dense or partitioned is not a field of the IR and
is not recorded here. The payload narrowing rule of `komira_lowering_rules` has
no consumer without a join and is not called.

## Dependencies

It depends on `komira_host_profile`, `komira_physical_plan`, `komira_plan_ir`,
`komira_plan_expr`, `komira_plan_stats`, `komira_scan_source`, `komira_arrow`,
`komira_collections` and the packages they need. Its `BUCK` file lists
`komira_fs`, `komira_objectstore`, `komira_async`, `komira_shuffle`,
`komira_engine_runtime`, `komira_optimizer` and `komira_sql` in
`closure_excludes`, so analysis fails if any of them enters the closure,
directly or through another package. The names are compared exactly:
`komira_async_api`, a trait surface the closure needs, is not refused.
