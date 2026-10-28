# komira_op_window

The window operator of the engine. `partition_scan_sink._execute_partition_by_sink`
runs a `PartitionBySinkData` (`komira_physical_plan`) over one batch: it
sorts the rows by (partition keys ++ order keys), finds the partitions,
evaluates each `PartitionExpr` into one new column, and returns the sorted
input columns followed by the new columns.

Results follow DuckDB (docs/design/query_semantics.md §4 and §9):

- Rows come out ordered by partition keys ascending and order keys in their
  own direction, NULLs last in both directions, floats with NaN above +inf.
  A float ORDER BY key column comes back with each -0.0 written as 0.0.
- NULL partition keys form one partition; NULL order keys are peers of each
  other; NaN equals NaN and -0.0 equals +0.0 as keys.
- Aggregates skip NULLs; an aggregate over no value is NULL (COUNT is 0).
  Float MIN / MAX order NaN above every number.
- LAG / LEAD answer NULL past the partition edge unless the plan gives a
  non-NULL default; FIRST_VALUE / LAST_VALUE / NTH_VALUE read their frame;
  all five respect NULLs.

Modules:

- `partition_keys`: the window sort (`sort_partition_batch`: the multi-key
  sort of `komira_op_sort` when no key holds a NULL or is a dictionary,
  otherwise a stable pass per key over the key columns alone), key equality
  (`key_cells_equal`), and the partition and peer boundaries.
- `partition_scan_sink`: the driver, `_execute_partition_by_sink`, and the
  dispatch of one `PartitionExpr` to its kernel.
- `partition_scan_kernels`: ROW_NUMBER, RANK, DENSE_RANK, PERCENT_RANK,
  CUME_DIST, NTILE, and the running (`UNBOUNDED PRECEDING .. CURRENT ROW`)
  SUM / COUNT / AVG / MIN / MAX; under RANGE the driver gives every peer the
  value of the group's last row.
- `partition_frame_index`: every row's frame as row indices: ROWS bounds,
  RANGE bounds without an offset (peer groups, any key type), and RANGE
  offsets on one INT64 / FLOAT64 key with no NULL and no NaN (other RANGE
  offsets raise).
- `partition_sliding_frame`: COUNT and INT64 SUM / AVG over a bounded frame
  on a two-pointer window; FLOAT64 SUM / AVG on a sum tree, so each frame is
  summed from its own values alone (subtracting a value that leaves would
  take with it what it absorbed, or leave NaN behind an infinity); MIN / MAX
  by rescan; every aggregate over the whole partition.
- `partition_value_fns`: LAG, LEAD, FIRST_VALUE, LAST_VALUE, NTH_VALUE over
  INT64, FLOAT64 and STRING columns.
- `partition_scan_sink_parallel`: `_execute_partition_by_sink_parallel`, the
  same rows on the engine's workers: one sort, then whole-partition buckets
  evaluated in parallel and concatenated in order; below 65,536 rows, four
  partitions or two workers it runs on the calling thread.
- `partition_scan_sink_hash_scatter`: above that size, with one or more INT64 partition
  keys holding no NULL, rows are scattered by key range (sampled equi-depth
  splitters) and each bucket is sorted and evaluated on its own worker.
- `partition_by_sink`: `PartitionBySink`, the window operator as a
  `MorselSink` of `komira_operator_api`; `finalize` runs the parallel driver.
  Every route emits the same rows in the same order
  (`komira_exec_types.partition_by_output_contract`).
- `partition_null_policy`: the NULL policy every aggregate kernel shares,
  and the output allocators that size a validity bitmap only when a NULL can
  be written.

Import from the sub-modules; there is no facade.
