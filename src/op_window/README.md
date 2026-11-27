# op_window

The window and top-N operators of the engine.
`partition_scan_sink._execute_partition_by_sink`
runs a `PartitionBySinkData` (`physical_plan`) over one batch: it
sorts the rows by (partition keys ++ order keys), finds the partitions,
evaluates each `PartitionExpr` into one new column, and returns the sorted
input columns followed by the new columns.

Results follow DuckDB (docs/design/query_semantics.md §4 and §9):

- Rows come out ordered by partition keys ascending and order keys in their
  own direction, each order key's NULLs where `nulls_first` places them (last
  in both directions when it is empty), floats with NaN above +inf.
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
  sort of `op_sort` when no key holds a NULL or is a dictionary,
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
  offsets on one INT64, INT32 or FLOAT64 key as DuckDB answers them (a NULL
  key frames over the NULL group, NaN compares above +inf, a bound that
  leaves the key's type raises DuckDB's overflow error; other RANGE offsets
  raise).
- `partition_sliding_frame`: COUNT and INT64 SUM / AVG over a bounded frame
  on a two-pointer window; FLOAT64 SUM / AVG on a sum tree, so each frame is
  summed from its own values alone (subtracting a value that leaves would
  take with it what it absorbed, or leave NaN behind an infinity); MIN / MAX
  by rescan; every aggregate over the whole partition.
- `partition_narrow_int`: SUM / AVG / MIN / MAX over an INT8, INT16 or INT32
  column: the sink widens the argument once (INT64, or FLOAT64 for the AVG of
  an INT8 or INT16, which DuckDB divides in double), runs the kernels above
  and narrows a MIN / MAX result back to the input type.
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
  `MorselSink` of `operator_api`; `finalize` runs the parallel driver.
  Every route emits the same rows in the same order
  (`exec_types.partition_by_output_contract`).
- `topn_sink`: `TopNSink`, the global top-N of a pipeline as a `MorselSink`;
  `finalize` runs `op_sort.sort_topn_sink._execute_topn_sink` over the
  folded batch, so its rows (and its NULL placement) are that kernel's.
  That kernel does not read `nulls_first` and orders a numeric NULL slot by
  its stored value, so the sink's NULL placement is not the NULLS LAST of
  `TopNState` and `PartitionTopNState`.
- `bounded_heap`: bounded heaps over INT64 keys (capacity at compile time or
  at run time) and over STRING keys compared byte-wise. Slots order by
  (key, payload id), so equal keys keep the smaller payload (row) first and
  the kept rows do not depend on feed or merge order.
- `topn_stage`, `stage_topn`: the top-N of one INT64 key, and
  `Stage_TopN_1_I64` / `Stage_TopN_Dynamic_1_I64`, its `FusedMorselOp`s over
  an `ExprXI64` key (payload: the row's index across all batches fed).
  DESC stores the bitwise NOT of the key, which reverses every INT64
  (negation overflows on `Int64.MIN`).
- `topn_state`: `TopNState`, the typed stage's TOPN breaker state: the top N
  of an INT64 key column, mergeable (`combine`) and spillable. NULL keys
  come last in both directions (there is no NULLS FIRST setting); the NULL-key
  rows kept are the smallest payload ids, so the result does not depend on
  feed or merge order.
- `partition_topn_state`: `PartitionTopNState`, top N per partition over
  INT64 columns (NULL partition keys one partition, NULL order keys last in
  both directions, as in `TopNState`).
- `partition_topn_hash_state`, `part_key_block`, `ptn_dense_directory`:
  `PartitionTopNHashState`, top N full rows per partition for any mix of
  partition key types (`PartKeyBlock`) and an INT32 / INT64 / FLOAT32 /
  FLOAT64 or STRING order key, in a hashed partition directory. ROW_NUMBER
  keeps N rows per partition, RANK every row tied within N. Ties go to the
  earlier row (a running row count is the heap payload), so the kept rows do
  not depend on slot reuse; `combine` of states fed consecutive row ranges,
  left to right, equals one state fed every row. NULL order keys sort last in
  both directions; a NULL partition key is one partition.
- `partition_state`: the per-partition state holders of a typed window stage.
- `partition_topn_sink`: `PartitionTopNSink`, the rows of each partition whose
  ROW_NUMBER or RANK over the sort keys is at most k (`PartitionTopNSinkData`),
  optionally with that number as a column. One INT32 / INT64 partition key
  and one INT32 / INT64 / FLOAT64 sort key with no NULL take the bounded-heap
  path (`partition_topn_compact`, built on the engine's workers when given a
  pool); any other keys take the window sort and one walk. Both give the
  window operator's rows; among equal sort keys ROW_NUMBER keeps the earliest
  input rows, whatever the number of workers. Within a partition the rows
  come best first, ties in input order, and a partition's rows are
  contiguous. The order of the partitions differs between the two paths (the
  heap path emits them in first-seen order, the sort path in sorted key
  order): callers must not rely on it.
- `partition_null_policy`: the NULL policy every aggregate kernel shares,
  and the output allocators that size a validity bitmap only when a NULL can
  be written.

Import from the sub-modules; there is no facade.

## Examples

The bounded heaps keep the N best slots under (key, payload id), and the slot
a push displaces is reported, so a caller can recycle its storage. Ties go to
the smaller payload id (the earlier row) however the rows arrive:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from op_window.bounded_heap import BoundedHeapInt64Payload, BoundedHeapInt64PayloadDynamic, BoundedHeapStringPayload

var keys: List[Int64] = [50, 10, 40, 20, 30]
var heap = BoundedHeapInt64Payload[3]()
var evicted = List[Int64]()
for i in range(len(keys)):
    evicted.append(heap.push_returning_evicted(keys[i], Int64(i)))
assert_equal(heap.capacity(), 3)
assert_equal(heap.size(), 3)
assert_equal(evicted[0], Int64(-1))
assert_equal(evicted[3], Int64(0))
assert_equal(evicted[4], Int64(2))
assert_equal(heap.peek_root().key, Int64(30))
var kept = heap.extract_sorted()
assert_equal(len(kept), 3)
assert_equal(kept[0].key, Int64(10))
assert_equal(kept[0].payload_row_id, Int64(1))
assert_equal(kept[1].key, Int64(20))
assert_equal(kept[1].payload_row_id, Int64(3))
assert_equal(kept[2].key, Int64(30))
assert_equal(kept[2].payload_row_id, Int64(4))
assert_equal(heap.size(), 0)

var ties = BoundedHeapInt64PayloadDynamic(2)
ties.push(Int64(7), Int64(9))
ties.push(Int64(7), Int64(3))
ties.push(Int64(7), Int64(6))
ties.push(Int64(7), Int64(1))
var winners = ties.extract_sorted()
assert_equal(len(winners), 2)
assert_equal(winners[0].payload_row_id, Int64(1))
assert_equal(winners[1].payload_row_id, Int64(3))

var words = BoundedHeapStringPayload[2, 0]()
_ = words.push_returning_evicted("b".as_bytes(), Int64(0))
_ = words.push_returning_evicted("a".as_bytes(), Int64(1))
_ = words.push_returning_evicted("a".as_bytes(), Int64(2))
assert_equal(words.push_returning_evicted("a".as_bytes(), Int64(3)), Int64(3))
var first_two = words.extract_sorted()
assert_equal(len(first_two), 2)
assert_equal(first_two[0].payload_row_id, Int64(1))
assert_equal(first_two[1].payload_row_id, Int64(2))
```

The typed stage's top-N scaffold stores the bitwise NOT of a DESC key, so the
largest and smallest INT64 values order correctly in both directions:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from expr.expr_sortable_key import SORT_DIR_ASC, SORT_DIR_DESC
from op_window.topn_stage import TopNStageScaffoldI64

var keys: List[Int64] = [0, Int64.MIN, Int64.MAX, -5, 7]
var desc = TopNStageScaffoldI64[3].new(SORT_DIR_DESC)
var asc = TopNStageScaffoldI64[3].new(SORT_DIR_ASC)
for i in range(len(keys)):
    desc.push_row(keys[i], Int64(i))
    asc.push_row(keys[i], Int64(i))
var largest = desc.finalize_emit()
var smallest = asc.finalize_emit()
var want_largest: List[Int64] = [Int64.MAX, 7, 0]
var want_smallest: List[Int64] = [Int64.MIN, -5, 0]
assert_equal(len(largest), 3)
assert_equal(len(smallest), 3)
for i in range(3):
    assert_equal(largest[i].key, want_largest[i])
    assert_equal(smallest[i].key, want_smallest[i])
assert_equal(largest[0].payload_row_id, Int64(2))
assert_equal(smallest[0].payload_row_id, Int64(1))
```
