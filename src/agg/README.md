# `agg`

The aggregate kernels, built on `udf` and `arrow`.

- `aggregator` and `agg_op_traits`, with `agg_fn_agg` and `pod_state_gate`.
- Built-in aggregate functions: `builtin_agg_fns_*` (avg, bool, corr, count,
  firstlast, minmax, states, stddev, string, sum, sum_product, vec).
- Hash-aggregate state machines: `hash_agg_op_aggregator`, `hash_agg_op_dt`,
  and `count_star_op` (COUNT(*), which counts rows, NULL or not; `CountOp` is
  COUNT(col)).
- NULLs: every `Aggregator` says whether a row's input is NULL
  (`input_is_null`, required), how a NULL folds (`update_null`, a no-op except
  FIRST / LAST), and what a group with no non-NULL value answers
  (`EMPTY_IS_NULL`: NULL, or COUNT's 0). `op_agg_stage.AggSlot` applies them.

There are no root re-exports; import each name from its module.

## Examples

A built-in aggregate function has four steps: `init` makes an empty state,
`update` folds in one row, `merge` combines two partial states (how workers
share a group), and `finalize` reads the answer. This example sums and counts
four values in two halves and merges the halves. The sum widens to a 64-bit
integer, so it is exact even where the input type would overflow.

```mojo
from std.testing import assert_equal
from agg.builtin_agg_fns_states import RowI32
from agg.builtin_agg_fns_sum import SumI32
from agg.builtin_agg_fns_count import CountI32

var left: List[Int32] = [Int32(2000000000), Int32(2000000000)]
var right: List[Int32] = [Int32(7), Int32(-3)]

var sum_left = SumI32().init()
var count_left = CountI32().init()
for v in left:
    SumI32().update(sum_left, RowI32(v))
    CountI32().update(count_left, RowI32(v))

var sum_right = SumI32().init()
var count_right = CountI32().init()
for v in right:
    SumI32().update(sum_right, RowI32(v))
    CountI32().update(count_right, RowI32(v))

var total = SumI32().merge(sum_left, sum_right)
var rows = CountI32().merge(count_left, count_right)
assert_equal(SumI32().finalize(total), Int64(4000000004))
assert_equal(CountI32().finalize(rows), Int64(4))
```

Averages, minimums and maximums follow the same four steps. An average is the
sum divided by the count as a 64-bit float. An average over no rows finalizes
to 0.0; a caller that needs NULL there checks the count.

```mojo
from std.testing import assert_equal
from agg.builtin_agg_fns_states import RowF64
from agg.builtin_agg_fns_avg import AvgF64
from agg.builtin_agg_fns_minmax import MinF64, MaxF64

var vals: List[Float64] = [Float64(2.5), Float64(-1.5), Float64(3.25), Float64(0.75)]
var avg = AvgF64().init()
var low = MinF64().init()
var high = MaxF64().init()
for v in vals:
    AvgF64().update(avg, RowF64(v))
    MinF64().update(low, RowF64(v))
    MaxF64().update(high, RowF64(v))

assert_equal(AvgF64().finalize(avg), Float64(1.25))
assert_equal(MinF64().finalize(low), Float64(-1.5))
assert_equal(MaxF64().finalize(high), Float64(3.25))
```
