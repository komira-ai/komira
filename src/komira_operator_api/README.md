# komira_operator_api

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
| `MapOp` | `map_op` | projection: evaluates a list of expressions over each morsel's batch with `komira_batch_eval` |
| `BinaryFnOp`, `HashFnOp`, `StringHashFnOp`, `MatchFnOp`, `UnaryMatchFnOp` | `binary_fn_op`, `hash_fn_op`, `match_fn_op` | the comptime-monomorphized adapters that run one `komira_kernels` kernel per morsel |
| `_MapFnFusedKernel`, `_FilterFnFusedKernel` | `map_fn_fused_kernel`, `filter_fn_fused_kernel` | engine-internal chunk paths over the `komira_udf` map and filter traits |
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
komira_operator_api -> komira_morsel          (Morsel, the source and operator seams, dynamic join filters)
komira_operator_api -> komira_batch_eval      (MapOp's expression evaluation)
komira_operator_api -> komira_exec_types      (ExecResult)
komira_operator_api -> komira_udf, komira_kernels, komira_expr  (kernel and UDF traits, breaker tags)
komira_operator_api -> komira_arrow, komira_buffer, komira_collections, komira_column_kernels, komira_plan_expr
komira_operator_api -> komira_async, komira_async_api   (the dispatcher and cancellation a sink's finalize takes)
komira_operator_api -> komira_metrics, komira_counters, komira_name_registry, komira_atomic_alias
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
| `test_udf_traits` | conformers of the typed `komira_udf` map, filter and aggregate traits, and the comptime paths over them |
