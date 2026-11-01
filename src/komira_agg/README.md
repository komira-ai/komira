# `komira_agg`

The aggregate kernels, built on `komira_udf` and `komira_arrow`.

- `aggregator` and `agg_op_traits`, with `agg_fn_agg` and `pod_state_gate`.
- Built-in aggregate functions: `builtin_agg_fns_*` (avg, bool, corr, count,
  firstlast, minmax, states, stddev, string, sum, sum_product, vec).
- Hash-aggregate state machines: `hash_agg_op_aggregator`, `hash_agg_op_dt`,
  and `count_star_op` (COUNT(*), which counts rows, NULL or not; `CountOp` is
  COUNT(col)).
- NULLs: every `Aggregator` says whether a row's input is NULL
  (`input_is_null`, required), how a NULL folds (`update_null`, a no-op except
  FIRST / LAST), and what a group with no non-NULL value answers
  (`EMPTY_IS_NULL`: NULL, or COUNT's 0). `komira_op_agg_stage.AggSlot` applies them.

There are no root re-exports; import each name from its module.
