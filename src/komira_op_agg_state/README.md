# komira_op_agg_state

The running state of the query engine's aggregations: what holds and updates
an aggregate (`SUM`, `COUNT`, `MIN`, `MAX`, `AVG`, first and last value,
variance and standard deviation, median, the largest values, percentiles,
user-defined aggregates) per group, and the hash tables and sets that map a
group key to its state. The package root re-exports nothing; import from the
modules. The main ones:

- `hash_agg_table` with `agg_state_slab`: `HashAggTableI64[Op]`,
  `HashAggTableF64[Op]` (and `I32`/`F32`) group on an `Int64` key and fold
  values with an aggregate operation such as `SumI64`, `CountI64`, `MinI64`,
  `MaxI64`, `SumF64`, `AvgF64` or `StddevSampF64`; groups are dense slots
  numbered from 0, and the table grows without a limit on the number of
  groups (`dense_hash_agg_table` is the growing key directory under them).
  `byte_hash_agg_table` and `composite_hash_table` do the same for
  byte-encoded keys and keys of two or three columns.
- `hashset_parametric` (`HashSet1` to `HashSet8`, sets of tuples of 1 to 8
  numeric columns), `growable_hash_set_i64` and `byte_hashset`: the sets
  `COUNT(DISTINCT ...)` and `DISTINCT` use.
- `aggregator_trait`, `aggregators_builtin`, `aggregators_struct_builtin`:
  aggregators as a state type plus `init`/`update`/`merge`/`finalize`, among
  them `MedianAggregator` (exact for up to `MAX_MEDIAN_VALUES`, 64, values per
  group) and `LargestKAggregator`.
- `accumulator_trait`, `accumulator_set`, `dyn_accumulator` and the
  `columnar_acc_*` modules: accumulators that update many groups from a whole
  column at once, as the engine's hash-aggregate operator drives them, and
  `agg_fn_acc` for a user-defined aggregate function.

It does not read input or plan an aggregation; the operators that feed it are
in the packages above.

## Examples

`GROUP BY` an integer key with a hash table per aggregate:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_op_agg_state.agg_state_slab import AvgF64, CountI64, MaxI64, SumI64
from komira_op_agg_state.hash_agg_table import HashAggTableF64, HashAggTableI64

# (store, amount) rows: store 7 sells 10, 30 and 20; store 9 sells 5.
var stores: List[Int64] = [7, 9, 7, 7]
var amounts: List[Int64] = [10, 5, 30, 20]

var total = HashAggTableI64[SumI64]()
var count = HashAggTableI64[CountI64]()
var largest = HashAggTableI64[MaxI64]()
var mean = HashAggTableF64[AvgF64]()
for i in range(len(stores)):
    total.update_scalar(stores[i], amounts[i])
    count.update_scalar(stores[i], amounts[i])
    largest.update_scalar(stores[i], amounts[i])
    mean.update_scalar(stores[i], Float64(amounts[i]))

assert_equal(total.size(), 2)  # two groups
var s7 = total.lookup_or_insert(7)
assert_equal(total.key_at(s7), 7)
assert_equal(total.finalize_at(s7), 60)
assert_equal(count.finalize_at(count.lookup_or_insert(7)), 3)
assert_equal(largest.finalize_at(largest.lookup_or_insert(7)), 30)
assert_equal(mean.finalize_at(mean.lookup_or_insert(7)), 20.0)
assert_equal(total.finalize_at(total.lookup_or_insert(9)), 5)
```

Distinct sets, and a median:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_op_agg_state.aggregators_struct_builtin import MedianAggregator
from komira_op_agg_state.growable_hash_set_i64 import GrowableHashSetI64
from komira_op_agg_state.hashset_parametric import HashSet2

# COUNT(DISTINCT user_id): insert reports whether the value was new.
var users = GrowableHashSetI64()
assert_true(users.insert(42))
assert_true(users.insert(7))
assert_true(not users.insert(42))
assert_equal(users.size(), 2)

# DISTINCT over two columns.
var pairs = HashSet2[DType.int64, DType.int64]()
_ = pairs.insert(1, 10)
_ = pairs.insert(1, 20)
_ = pairs.insert(1, 10)
assert_equal(pairs.size(), 2)
assert_true(pairs.contains(1, 20))
assert_true(not pairs.contains(2, 10))

var state = MedianAggregator.init()
for v in [9.0, 1.0, 4.0, 7.0, 3.0]:
    MedianAggregator.update(state, v)
assert_equal(Float64(MedianAggregator.finalize(state)), 4.0)
```
