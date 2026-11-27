# dispatch_join_kernels

Join gather and payload kernels: the unrolled and narrow-width gathers of the deferred join assembly, its row-range-major work plan, build-side payload narrowing and its widen at the leaf exit, the parallel selection flatten, the build-key extraction, and three route counters.

The package exports nothing at its top level; import from the module that
defines a name. Every example below runs as a test when the package is built.

## Route counters

The join kernels keep process-wide counters of which route ran. The mark
counter counts firings and resets to zero. The two gather counters add the
number of column rows they are given, not one per call, and one reset clears
both.

```mojo
from dispatch_join_kernels.join_gather_unrolled import (
    join_gather_rolled_colrows,
    join_gather_unrolled_colrows,
    note_gather_rolled,
    note_gather_unrolled,
    reset_join_gather_counters,
)
from dispatch_join_kernels.mark_semi_anti_route_counter import (
    mark_semi_anti_fire_count,
    mark_semi_anti_fire_incr,
    reset_mark_semi_anti_fire_count,
)
from std.testing import assert_equal

reset_mark_semi_anti_fire_count()
for _ in range(4):
    mark_semi_anti_fire_incr()
assert_equal(mark_semi_anti_fire_count(), 4)

reset_join_gather_counters()
note_gather_unrolled(100)
note_gather_unrolled(23)
note_gather_rolled(7)
assert_equal(join_gather_unrolled_colrows(), 123)
assert_equal(join_gather_rolled_colrows(), 7)
reset_join_gather_counters()
assert_equal(join_gather_unrolled_colrows(), 0)
assert_equal(join_gather_rolled_colrows(), 0)
```

## Build-key extraction arms

The build-key extraction counts whether it shared the column's memory or had
to copy it. The two counts move independently.

```mojo
from dispatch_join_kernels.hbs_key_share_counter import (
    hbs_key_decline_shape_count,
    hbs_key_decline_shape_incr,
    hbs_key_share_count,
    hbs_key_share_incr,
)
from std.testing import assert_equal

var share0 = hbs_key_share_count()
var shape0 = hbs_key_decline_shape_count()
hbs_key_share_incr()
hbs_key_share_incr()
hbs_key_decline_shape_incr()
assert_equal(hbs_key_share_count() - share0, 2)
assert_equal(hbs_key_decline_shape_count() - shape0, 1)
```
