# dispatch_agg_folds

Aggregate folds over resident batches: the grouped and scalar COUNT(DISTINCT) folds, the grouped string MIN/MAX fold, the mixed fold that serves COUNT(DISTINCT) or a string MIN/MAX beside fixed-cell aggregates, the ordered MIN/MAX reader and emitter of the scalar fold, the resolution of an aggregate's parquet leaf, and the process-global witnesses of which aggregate driver ran.

The package exports nothing at its top level; import from the module that
defines a name. Every example below runs as a test when the package is built.

## Which driver ran

The driver witness records which aggregate driver and route served a query,
the spill-envelope code behind that choice, and how many times a driver was
recorded. A reset puts every slot back to its starting value.

```mojo
from dispatch_agg_folds.agg_driver_witness import (
    AGG_DRIVER_NONE,
    AGG_DRIVER_STRATEGY_LEAF,
    AGG_ROUTE_SPILL_OR_STRATEGY,
    agg_driver_fire_count,
    agg_driver_last,
    agg_driver_name,
    agg_driver_record,
    agg_route_last,
    agg_route_name,
    agg_route_record,
    agg_spill_env_last,
    reset_agg_driver_witness,
)
from dispatch_agg_folds.agg_spill_envelope import (
    SPILL_ENV_DECLINE_NO_AGGS,
    SPILL_ENV_NOT_CONSULTED,
)
from std.testing import assert_equal

reset_agg_driver_witness()
agg_route_record(AGG_ROUTE_SPILL_OR_STRATEGY)
agg_driver_record(AGG_DRIVER_STRATEGY_LEAF, SPILL_ENV_DECLINE_NO_AGGS)
assert_equal(agg_driver_last(), AGG_DRIVER_STRATEGY_LEAF)
assert_equal(agg_driver_name(agg_driver_last()), "strategy_leaf")
assert_equal(agg_route_name(agg_route_last()), "spill_or_strategy")
assert_equal(agg_spill_env_last(), SPILL_ENV_DECLINE_NO_AGGS)
assert_equal(agg_driver_fire_count(), 1)

reset_agg_driver_witness()
assert_equal(agg_driver_last(), AGG_DRIVER_NONE)
assert_equal(agg_spill_env_last(), SPILL_ENV_NOT_CONSULTED)
assert_equal(agg_driver_fire_count(), 0)
```

## Reading a spill-envelope verdict

A `SpillEnvelopeVerdict` says whether the spilling aggregate can take a plan
and, if not, why. Only the admit code counts as admitted, and `describe`
prints the verdict as one token.

```mojo
from dispatch_agg_folds.agg_spill_envelope import (
    SPILL_ENV_ADMIT,
    SPILL_ENV_DECLINE_NO_KEYS,
    SpillEnvelopeVerdict,
)
from std.testing import assert_equal, assert_false, assert_true

var admit = SpillEnvelopeVerdict(SPILL_ENV_ADMIT, -1, 3, 4, 2, True)
assert_true(admit.admitted())
assert_equal(
    admit.describe(), "admit(keys=3,key_decode=True,aggs=4,avg_expanded=2)"
)

var decline = SpillEnvelopeVerdict(SPILL_ENV_DECLINE_NO_KEYS)
assert_false(decline.admitted())
assert_equal(decline.describe(), "decline(no_group_keys)")
```

## Counting streaming passes

The 0-key scalar aggregate counts each streaming pass it makes.

```mojo
from dispatch_agg_folds.scalar_agg_stream_pass_counter import (
    reset_scalar_agg_stream_pass_count,
    scalar_agg_stream_pass_count,
    scalar_agg_stream_pass_incr,
)
from std.testing import assert_equal

reset_scalar_agg_stream_pass_count()
scalar_agg_stream_pass_incr()
scalar_agg_stream_pass_incr()
assert_equal(scalar_agg_stream_pass_count(), 2)
reset_scalar_agg_stream_pass_count()
assert_equal(scalar_agg_stream_pass_count(), 0)
```
