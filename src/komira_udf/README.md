# `komira_udf`

The trait surface a library user writes user-defined functions against, built
on `komira_core` alone.

- Schema descriptors: `schema_descriptor`, `schema_auto`, `auto_komira_schema`,
  `udf_descriptor`.
- Function traits: `agg_fn`, `map_fn`, `map_fn_rt`, `filter_fn`, `window_fn`,
  `row_udf`, `scalar_udf`, `expr_scalar_fn`, with `window_frame_spec`,
  `frame_view`, `partition_row_view` and `partition_local_map_fn`.
- Shared leaves: `purity`, `predicate`, `row_transform`, `column_resolver`,
  `row_builder`, `stateful_contract`.
- `float_quotient_order`: the float equality and ordering model; it moves to
  `komira_column_kernels` with the `komira_core` split.

There are no root re-exports; import each name from its module.
