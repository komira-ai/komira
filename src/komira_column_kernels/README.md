# komira_column_kernels

Vectorized compute over Arrow columns: arithmetic, comparison, casts, string, regexp, dictionary, union, decimal, case mapping, and the batch helpers that import them.

`cross_batch_gather` builds one batch from rows of several batches that share a
schema, in the order of a list of `(source, row)` pairs (the external sort
materializes its merge with it). It gathers INT8 to INT64, UINT8 to UINT64,
FLOAT16 to FLOAT64, DATE32, DATE64, TIME32 and TIME64, TIMESTAMP (every unit),
DURATION (every unit), STRING, BINARY, LARGE_STRING, BOOL and NULL columns;
every other type (DECIMAL128, DECIMAL256, INTERVAL_MONTH_DAY_NANO, DICTIONARY,
LIST, STRUCT, ...) raises "unsupported column type".

The kernels take `komira_arrow` typed arrays and return new ones: arithmetic
(`komira_column_kernels.arithmetic`) returns a `PrimitiveArray`, comparisons
(`komira_column_kernels.comparison`, `komira_column_kernels.string_comparison`)
return a `BooleanArray` mask. A mask turns into row indices with
`filter_to_indices`, or feeds a masked aggregate such as `filtered_sum`.
The element-wise integer kernels (`eval_add`, `eval_sub`, `eval_mul` and their
`*_scalar` forms) are checked: an overflow raises instead of wrapping.
`filtered_sum` is not checked; its integer total wraps.

Every example below runs as a test when the package is built, so it cannot
go stale.

## Arithmetic, a predicate and a filtered sum

```mojo
from komira_arrow.primitive_array import PrimitiveArray
from komira_column_kernels.arithmetic import eval_add_scalar, eval_mul, filtered_sum
from komira_column_kernels.comparison import eval_gt, filter_to_indices
from std.testing import assert_equal, assert_true

var price: List[Int64] = [12, 5, 40, 7, 30]
var quantity: List[Int64] = [3, 10, 1, 2, 4]
var revenue = eval_mul(
    PrimitiveArray[DType.int64].from_list(price),
    PrimitiveArray[DType.int64].from_list(quantity),
)
assert_equal(revenue.length, 5)
assert_equal(revenue.get(0), Int64(36))
assert_equal(revenue.get(4), Int64(120))

var with_fee = eval_add_scalar(revenue, Int64(1))
assert_equal(with_fee.get(3), Int64(15))

# revenue = [36, 50, 40, 14, 120]: rows over 39 are 1, 2 and 4.
var big = eval_gt(revenue, Int64(39))
assert_equal(big.true_count(), 3)
var rows = filter_to_indices(big)
assert_equal(len(rows), 3)
assert_equal(rows[0], 1)
assert_equal(rows[1], 2)
assert_equal(rows[2], 4)
assert_equal(filtered_sum(revenue, big), Int64(210))

# Integer overflow is refused, not wrapped.
var huge: List[Int64] = [Int64.MAX]
var two: List[Int64] = [2]
var raised = False
try:
    _ = eval_mul(
        PrimitiveArray[DType.int64].from_list(huge),
        PrimitiveArray[DType.int64].from_list(two),
    )
except e:
    raised = True
    assert_true("Overflow" in String(e))
assert_true(raised)
```

## String predicates

```mojo
from komira_arrow.string_array import StringArray
from komira_column_kernels.comparison import filter_to_indices
from komira_column_kernels.string_comparison import eval_string_eq, eval_string_starts_with
from std.testing import assert_equal, assert_false, assert_true

var paths: List[String] = ["/api/users", "/static/app.js", "/api/orders", "/health"]
var col = StringArray.from_strings(paths)

var api = eval_string_starts_with(col, "/api/")
assert_true(api.get(0))
assert_false(api.get(1))
var api_rows = filter_to_indices(api)
assert_equal(len(api_rows), 2)
assert_equal(api_rows[1], 2)

var health = eval_string_eq(col, "/health")
assert_equal(health.true_count(), 1)
assert_true(health.get(3))
```
