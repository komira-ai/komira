# dispatch_agg_exec

Aggregate execution support: the conform that gives a min, max, first, last or any_value column its input column's type, the reachability counters of two aggregate routes, and the plan-time group-count estimate with the provenance of its weakest signal.

The package exports nothing at its top level; import from the module that
defines a name. Every example below runs as a test when the package is built.

## Route counters

Each aggregate route has a process-wide counter that is bumped once every time
the route serves a query, so a test can tell which route answered. The two
counters keep separate slots, and a reset clears only its own.

```mojo
from dispatch_agg_exec.computed_project_agg_route_counter import (
    computed_project_agg_route_fire_count,
    computed_project_agg_route_fire_incr,
    reset_computed_project_agg_route_fire_count,
)
from dispatch_agg_exec.semi_count_only_route_counter import (
    reset_semi_count_only_fire_count,
    semi_count_only_fire_count,
    semi_count_only_fire_incr,
)
from std.testing import assert_equal

reset_computed_project_agg_route_fire_count()
reset_semi_count_only_fire_count()
computed_project_agg_route_fire_incr()
computed_project_agg_route_fire_incr()
computed_project_agg_route_fire_incr()
semi_count_only_fire_incr()
assert_equal(computed_project_agg_route_fire_count(), 3)
assert_equal(semi_count_only_fire_count(), 1)

reset_computed_project_agg_route_fire_count()
assert_equal(computed_project_agg_route_fire_count(), 0)
assert_equal(semi_count_only_fire_count(), 1)
```
