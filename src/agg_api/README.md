# agg_api

The aggregation accumulator contract: Accumulator trait, plan-time AggLayout, strategy selection, typed column pointers, COUNT(DISTINCT) key.

The package has no root re-exports; import each name from its module.

The accumulator layout is decided at plan time. The first example builds the
slot layout for a SUM and a COUNT over float values, which fits two narrow
16-byte slots, and shows that adding a MIN switches to the wide four-field
slot.

```mojo
from std.testing import assert_equal, assert_true, assert_false
from agg_api.agg_layout import (
    ACC_SUM_COUNT_F64,
    agg_layout_is_quartet,
    layout_for_funcs,
)

# Function bytes: 0 is SUM, 1 is COUNT, 2 is MIN.
var narrow = layout_for_funcs([UInt8(0), UInt8(1)])
assert_equal(narrow.num_aggs, 2)
assert_equal(narrow.total_width, 32)
assert_equal(narrow.slot_offset(1), 16)
assert_equal(Int(narrow.slot_tag(0)), Int(ACC_SUM_COUNT_F64))
assert_false(agg_layout_is_quartet(narrow))

var wide = layout_for_funcs([UInt8(0), UInt8(2)])
assert_equal(wide.total_width, 64)
assert_true(agg_layout_is_quartet(wide))
```

The strategy chooser picks how a group-by runs from the estimated number of
groups, whether the input is already sorted, and the worker count. The
streaming-sort strategy is only chosen for small, presorted, single-worker
inputs.

```mojo
from std.testing import assert_equal, assert_true, assert_false
from agg_api.agg_strategy import (
    STRATEGY_S1_RADIX,
    STRATEGY_S3_STREAMING_SORT,
    S3_SORTED_THRESHOLD,
    choose_strategy,
    is_s3_eligible,
)

assert_equal(choose_strategy(500, True, 1).strategy, STRATEGY_S3_STREAMING_SORT)
assert_equal(choose_strategy(500, False, 1).strategy, STRATEGY_S1_RADIX)
assert_equal(choose_strategy(100_000, False, 4).strategy, STRATEGY_S1_RADIX)
assert_true(is_s3_eligible(S3_SORTED_THRESHOLD - 1, True, 1))
assert_false(is_s3_eligible(S3_SORTED_THRESHOLD, True, 1))
```

The COUNT(DISTINCT) key helpers say which Arrow types can be counted and fold
floating-point zero into one key.

```mojo
from std.testing import assert_equal, assert_true, assert_false
from arrow.arrow_types import ArrowType
from agg_api.cd_distinct_key import (
    CDK_I32,
    CDK_UNSUPPORTED,
    cd_distinct_key_channel,
    cd_f64_distinct_key,
    cd_value_type_supported,
)

assert_equal(cd_distinct_key_channel(ArrowType.DATE32), CDK_I32)
assert_equal(cd_distinct_key_channel(ArrowType.STRING), CDK_UNSUPPORTED)
assert_true(cd_value_type_supported(ArrowType.INT64))
assert_false(cd_value_type_supported(ArrowType.STRING))
assert_equal(cd_f64_distinct_key(Float64(-0.0)), cd_f64_distinct_key(Float64(0.0)))
assert_true(cd_f64_distinct_key(Float64(1.0)) != cd_f64_distinct_key(Float64(2.0)))
```
