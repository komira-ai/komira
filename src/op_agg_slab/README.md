# op_agg_slab

The struct-state hash aggregation table: `SlabStorage`, a hash table of groups keyed by a packed composite key (one to eight fixed-width columns, Int64 by default) that probes sixteen 1-byte fingerprints per SIMD compare, with one columnar state slab per aggregate. Each slab is read as its aggregate's `op_agg_state.AggregatorWithStruct` state struct (Welford, bivariate Welford, median buffer, largest-k), so the aggregates fold in place: `init_state_with_struct` on a new group, `commit_aggregator_with_struct` (and `commit_corr_aggregator_with_struct` for the two-input CORR) per batch, `combine_donor_keys_with_struct` to merge one worker's table into another with one probe per donor group, and `finalize_aggregator_with_struct` plus the `finalize_keys_*` methods to emit the result in group order. Keys and outputs are passed as spans whose lengths are checked; no public method takes a pointer. On top of it, `SlabHashAggSinkStruct[INPUT_COLS, *Ss]` (a variadic pack of `AggregatorWithStruct` kernels) and `SlabHashAggSinkStructCorr` (CORR(x, y)) are `operator_api.MorselSink`s for one or two Int64 group keys: each worker probes its rows into 64 hash partitions held by `SlabHashAggGlobal`, `combine` and `combine_partition` merge the workers partition by partition, and `finalize` emits one RecordBatch of the keys and each aggregate's result.

## Example

This groups four rows by an Int64 key, then reads the keys back in group order. The key is passed as its eight little-endian bytes. The repeated key 7 finds its group again instead of adding one.

```mojo
from std.testing import assert_equal, assert_true
from op_agg_slab.slab_storage import SlabStorage

var table = SlabStorage(num_keys=1, num_aggs=0, initial_capacity=64)
var schema = List[DType]()
schema.append(DType.int64)
table.init_multi_key_mode(schema^)

var key = List[UInt8](length=8, fill=0)
var values = List[Int]()
values.append(7)
values.append(9)
values.append(7)
values.append(11)

var ids = List[Int]()
var fresh = List[Bool]()
for i in range(len(values)):
    key[0] = UInt8(values[i])
    var pair = table.probe_or_insert_multi_key(Span(key))
    ids.append(pair[0].entry_idx())
    fresh.append(pair[1])

assert_equal(fresh[0], True)
assert_equal(fresh[1], True)
assert_equal(fresh[2], False)
assert_equal(fresh[3], True)
assert_equal(ids[0], ids[2])
assert_equal(table.num_groups(), 3)

var out = List[UInt8](length=24, fill=0)
table.finalize_keys_int64(Span(out))
assert_equal(Int(out[0]), 7)
assert_equal(Int(out[8]), 9)
assert_equal(Int(out[16]), 11)
assert_true(table.capacity() >= 3)
```
