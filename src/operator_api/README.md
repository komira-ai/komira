# operator_api

The operator interfaces of the engine's pipelines: what a pipeline stage, a
sink and a blocking operator implement. The concrete operators and sinks
(aggregation, join, sort, window, stage execution) live in the packages that
depend on this one; it depends on none of them.

It rewrites no plan and reads no environment or host property. A switch an
operator honours (the map operator's project-share arm, the diagnostic dumps)
is an argument its caller passes from the physical plan.

## Entry points

| name | module | what it is |
| --- | --- | --- |
| `MorselSink` | `morsel_sink` | the sink contract: per-worker `Local` state, `consume`, a whole-segment `combine` and a two-arm `finalize` (`FinalizeOutput`) |
| `SinkCapabilities` | `morsel_sink` | what a sink declares about partitioning and ordering |
| `MemoryReservation` | `memory_reservation` | the byte tally against an optional budget that `combine` receives |
| `SinkPhaseTimings` | `sink_timings` | per-phase atomic counters of a sink run; `dump` prints only when its caller passes `enabled=True` |
| `BreakerState`, `BreakerStateCombinable`, `NoState` | `breaker_state_trait` | the state every blocking operator (hash table, sort buffer, join build) implements |
| `FusedMorselOp` | `fused_morsel_op` | a per-batch operator that owns its breaker state and drains it at `finalize` |
| `MapOp` | `map_op` | projection: evaluates a list of expressions over each morsel's batch with `batch_eval` |
| `BinaryFnOp`, `HashFnOp`, `StringHashFnOp`, `MatchFnOp`, `UnaryMatchFnOp` | `binary_fn_op`, `hash_fn_op`, `match_fn_op` | the comptime-monomorphized adapters that run one `kernels` kernel per morsel |
| `_MapFnFusedKernel`, `_FilterFnFusedKernel` | `map_fn_fused_kernel`, `filter_fn_fused_kernel` | engine-internal chunk paths over the `udf` map and filter traits |
| `apply_dyn_filter_int64` | `dyn_filter_apply` | a build side's dynamic join filter applied to an in-memory probe batch |
| `fold_batches_into_one` | `sink_batch_fold` | the one N-way concatenation sinks use for their staged batches |
| `_EmitColDesc`, `_EmitColTarget` | `emit_at_offset_target` | the type-erased output columns a partitioned drain writes into at offsets |
| `join_build_fold_*`, `wd_*`, `wave_decomp_dump` | `join_build_fold_census`, `wave_decomp` | copy and timing counters; off unless the caller turns them on |

## The selection-mask contract

A batch may carry an unapplied selection mask: rows a pushed predicate
rejected are still present. When every projected expression is total over rows
(it cannot raise on a value), `MapOp` evaluates over the physical rows and then
compacts only its output; otherwise it materializes the selection first, so a
row the filter excluded never reaches an expression that could fail on it.
`map_op.mojo` holds the full statement.

## Dependency direction

```
operator_api -> morsel          (Morsel, the source and operator seams, dynamic join filters)
operator_api -> batch_eval      (MapOp's expression evaluation)
operator_api -> exec_types      (ExecResult)
operator_api -> udf, kernels, expr  (kernel and UDF traits, breaker tags)
operator_api -> arrow, byte_buffer, containers, column_kernels, plan_expr
operator_api -> async_rt, async_api   (the dispatcher and cancellation a sink's finalize takes)
operator_api -> metrics, counters, name_registry, atomic_alias
```

## Tests

`tests/` holds the package's tests; every one is listed in `test_srcs` in the
package `BUCK` file, so the library is not produced unless all of them pass.

| test | proves |
| --- | --- |
| `test_morsel_sink_trait` | a minimal sink conforms to `MorselSink` and runs consume, combine and finalize |
| `test_sink_timings_keepalive` | `SinkPhaseTimings` stays alive and readable across heap allocation while borrowed |
| `test_memory_reservation` | the budget contract: refusal leaves the tally, the exact-fit grow succeeds, release makes room, a negative budget is none |
| `test_map_op_total_eval_compact` | `MapOp` evaluates total expressions over the physical rows and compacts their output; a raising one sees only the selected rows |
| `test_binary_fn_kernel`, `test_hash_fn_kernel`, `test_match_fn_kernel` | the function-operator adapters against their kernels |
| `test_udf_traits` | conformers of the typed `udf` map, filter and aggregate traits, and the comptime paths over them |

## Examples

A `MemoryReservation` tallies bytes against an optional budget. A refused grow
leaves the tally alone and is counted, a grow that lands exactly on the budget
fits, and a release makes room again:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from operator_api.memory_reservation import BUDGET_UNSET, MemoryReservation

var unbounded = MemoryReservation()
assert_false(unbounded.has_budget())
assert_equal(unbounded.budget_bytes(), BUDGET_UNSET)
assert_true(unbounded.try_grow(1 << 40))
assert_equal(unbounded.held_bytes(), 1 << 40)

var budgeted = MemoryReservation.with_budget(100)
assert_true(budgeted.has_budget())
assert_true(budgeted.try_grow(60))
assert_false(budgeted.try_grow(41))
assert_equal(budgeted.held_bytes(), 60)
assert_equal(budgeted.try_grow_denied_count(), 1)
assert_true(budgeted.try_grow(40))
assert_equal(budgeted.held_bytes(), 100)
budgeted.release(50)
assert_true(budgeted.try_grow(41))
assert_equal(budgeted.held_bytes(), 91)
assert_equal(budgeted.try_grow_denied_count(), 1)

var negative = MemoryReservation.with_budget(-5)
assert_false(negative.has_budget())
assert_true(negative.try_grow(1 << 30))
```

`SinkPhaseTimings` adds each phase's nanoseconds to its own atomic counter, and
`dump` prints nothing unless the caller passes `enabled=True`. `SinkCapabilities`
starts as a plain batch-producing sink and a sink sets the fields it differs in:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from operator_api.morsel_sink import SinkCapabilities
from operator_api.sink_timings import SinkPhaseTimings

var timings = SinkPhaseTimings()
var p = Pointer(to=timings)
p[].record_consume(UInt64(100))
p[].record_consume(UInt64(50))
p[].record_combine_local(UInt64(20))
p[].record_combine_partition(UInt64(30))
p[].record_finalize(UInt64(40))
assert_equal(p[].load_consume(), UInt64(150))
assert_equal(p[].load_combine_local(), UInt64(20))
assert_equal(p[].load_combine_partition(), UInt64(30))
assert_equal(p[].load_finalize(), UInt64(40))
p[].dump("example")

var caps = SinkCapabilities()
assert_true(caps.output_is_batch)
assert_false(caps.supports_spill)
assert_equal(caps.max_combine_parallelism, Int16(0))
caps.supports_spill = True
caps.max_combine_parallelism = Int16(4)
assert_true(caps.supports_spill)
assert_equal(caps.max_combine_parallelism, Int16(4))
```
