# op_agg_hash

The hash aggregation tables of the engine: `FlatHashAggregator`, a split-index table (a compact tag array to probe, a slot directory, and an insertion-order entry buffer of hash, Int64 keys and accumulator slots laid out by an `AggLayout`); `PerfectHashAggregator`, a flat array for small dense integer key domains (at most 65,536 keys); `PartitionedFlatHashAggregator`, one `FlatHashAggregator` per radix partition; `FlatHashPartitionFlush`, the per-partition row buffers a table scatters into when it reaches its cache-resident cap; and `AggCommitPlan`, which folds a record batch's value columns into the accumulator slots of any of these tables, per row (`commit_row`, `commit_row_ph`) or loop-transposed per batch (`commit_batch`, `commit_batch_partitioned`, `commit_batch_indexed`). Batches of keys, rows and handles are passed as spans; no public function takes a pointer. The row kernels are `op_agg_state`'s; the sinks that drive these tables are in the packages above.

## Example

`PerfectHashAggregator` keeps one accumulator slot per key of a small dense domain. This folds values into key 1 and key 3, then merges a second table into the first and reads sum, count, min and max back.

```mojo
from std.testing import assert_equal
from op_agg_hash.flat_hash_agg_perfect import PerfectHashAggregator

var left = PerfectHashAggregator(domain_size=4, key_offset=0, num_aggs=1)
left.update(1, 0, 5.0)
left.update(1, 0, 2.0)
left.update(3, 0, 4.0)
var right = PerfectHashAggregator(domain_size=4, key_offset=0, num_aggs=1)
right.update(1, 0, 10.0)
left.merge(right)
assert_equal(left.get_sum(1, 0), 17.0)
assert_equal(left.get_count(1, 0), 3)
assert_equal(left.get_min(1, 0), 2.0)
assert_equal(left.get_max(1, 0), 10.0)
assert_equal(left.get_count(3, 0), 1)
assert_equal(left.get_count(0, 0), 0)
```

`PartitionedFlatHashAggregator` routes each key to one radix partition, so repeated keys land in the same group.

```mojo
from std.testing import assert_equal
from op_agg_hash.partitioned_flat_hash_agg import PartitionedFlatHashAggregator

var agg = PartitionedFlatHashAggregator(num_keys=1, num_aggs=1)
agg.insert_1(7, 1.0)
agg.insert_1(7, 2.0)
agg.insert_1(8, 3.0)
assert_equal(agg.num_groups(), 2)
```
