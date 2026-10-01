# komira_compiler

The compiler tier of the engine: plan-time rewrites over a `LogicalPlan`,
plan-time cardinality estimation, and the vectorized expression evaluators
the runtime calls to filter and project record batches.

## Dependency direction

```
komira_compiler -> komira_core   (LogicalPlan, Expr, StatsProvider trait,
                                  ScalarValue, Arrow arrays, helpers)
komira_compiler -> komira_eval   (selection vectors, scalar/SIMD kernels,
                                  the row-mode RuntimeExpr AST)
komira_compiler -> komira_jsonl   (the `json_extract` kernel)
```

The compiler must not depend on the engine runtime, `komira_parquet` or the
SDK. Those packages depend on it: the engine consumes the expression
evaluators and `ExprId` / `ExprPool`, the format packages implement
`StatsProvider`, and the SDK's optimizer drives the plan rewrites.

## What lives here

Plan-time rewrites and analysis:

- `flatten_dependent_joins` — lowers correlated subqueries to joins.
- `scalar_subquery_decorrelate`, `resolve_scalar_subqueries` — uncorrelated
  scalar subqueries (decorrelate to a broadcast cross join, or execute once
  and inline the literal; the executing driver lives in the SDK).
- `join_predicate_decompose` — lifts equi-keys out of a join residual.
- `partition_prune_scans` — Hive-partition path pruning.
- `view_resolution_pass` — inlines registered views.
- `plan_cse`, `scan_dedup_compile` — plan-level common-subexpression
  elimination and duplicate-subtree detection.
- `cardinality_estimator`, `plan_group_estimate`, `stats_helpers` — HLL and
  statistics-driven group-count estimation.
- `optimizer_perfect_hash` — a statistics-driven perfect-hash detector (not
  consulted by the live aggregation path).
- `plan_budget` — per-operator memory budget split.

Expression evaluation (Expr -> Arrow arrays):

- `compiler_eval_predicate` — `_eval_predicate`, the predicate entry point,
  and `lower_filter_predicate`.
- `compiler_eval_column` — `_eval_column_expr`, the projection entry point.
- `compiler_eval_case`, `compiler_eval_in_list`, `compiler_eval_dict` — CASE,
  IN-list and dictionary-materialization arms.
- `conjunction` — selection-vector narrowing for `A AND B AND ...` and the
  per-leaf three-valued NULL handling at the filter boundary.
- `arm_rows`, `literal_arm_domain`, `integer_literal_value`,
  `temporal_literal_value`, `numeric_dict_lut_scan` — shared helpers for the
  evaluators.
- `expr_to_runtime`, `bound_expression` — translation to the row-mode
  runtime AST and the index-resolved bound AST.
- `expr_id`, `expr_pool` — late-bound expression handles.

## Tests

`tests/` holds the library's tests; every one of them is declared in the
package `BUCK` file and gates the library's build.
