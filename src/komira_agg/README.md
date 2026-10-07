# `komira_agg`

The aggregate kernels, built on `komira_udf` and `komira_arrow`.

- `aggregator` and `agg_op_traits`, with `agg_fn_agg` and `pod_state_gate`.
- Built-in aggregate functions: `builtin_agg_fns_*` (avg, bool, corr, count,
  firstlast, minmax, states, stddev, string, sum, sum_product, vec).
- Hash-aggregate state machines: `hash_agg_op_aggregator`, `hash_agg_op_dt`.

There are no root re-exports; import each name from its module.
