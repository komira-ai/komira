# `komira_expr`

The typed expression vocabulary, above `komira_udf` and `komira_kernels`.

- The `ExprX` trait family (`ExprXBool`, `ExprXI64`, `ExprXF64`, `ExprXF32`,
  `ExprXI32`, `ExprXString`) in `expr_x`, and the unified chunk traits in
  `expr_traits_unified`.
- The `Stage[Program]` IR in `stage_program`, with `typed_projects` and
  `typed_udf_sugar`.
- `runtime_expr_bool`, `composite_key` and `expr_sortable_key`.

The row-mode executor that implements these traits is `komira_eval`. There are
no root re-exports; import each name from its module.
