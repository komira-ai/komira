# komira_batch_eval

Evaluates SQL expressions over Arrow record batches: the vectorized projection
and predicate evaluators an executor host runs inside its operators.

## Entry points

| function | module | returns |
| --- | --- | --- |
| `evaluate_column(expr, batch)` | `evaluate` | the projection: one value per row, as a `Column` |
| `evaluate_predicate(expr, batch)` | `evaluate` | the predicate: one bit per row; UNKNOWN is data 0 with validity 0 |

`evaluate_predicate` reports UNKNOWN; turning UNKNOWN into FALSE at a filter
boundary is the caller's step.

The evaluator only evaluates. It rewrites no plan and registers no expression:
the plan an executor host lowers arrives optimized, and this package is called
with the expressions that plan carries.

## Dependency direction

```
komira_batch_eval -> komira_arrow, komira_buffer   (batches, columns, bitmaps)
komira_batch_eval -> komira_plan_expr     (Expr, ScalarValue)
komira_batch_eval -> komira_plan_ir       (udf_call_column_key)
komira_batch_eval -> komira_column_kernels, komira_kernels, komira_scalar_arithmetic  (the kernels)
komira_batch_eval -> komira_json_index    (the json_extract kernel)
komira_batch_eval -> komira_counters      (the dictionary-materialization reach counter)
```

The operators and the executor depend on this package; it depends on no
operator, no reader or writer, and no SDK.

## UDF calls

The `EXPR_UDF_CALL` arm reads the call's output column from the batch, under
the name `komira_plan_ir.expr_udf_sites.udf_call_column_key` derives. The
evaluator calls no UDF itself: whatever runs the call materializes its output
onto the batch first, and a call whose column is missing is refused by name.

## Modules

| module | holds |
| --- | --- |
| `evaluate` | the public entry points |
| `eval_column` | `_eval_column_expr`, the projection ladder over the `EXPR_*` tags |
| `project_access`, `project_ops`, `project_cast`, `project_string`, `project_string_n` | its large arms |
| `column_compare`, `column_arith`, `column_decimal` | comparison under numeric promotion, column-scalar arithmetic, DECIMAL128 and temporal typing and casts |
| `string_metrics`, `string_bytes` | byte-level string measures and transforms |
| `eval_predicate` | `_eval_predicate`, the predicate ladder |
| `predicate_binary`, `predicate_compare`, `predicate_numeric_dict`, `predicate_logic` | its binary arm, comparison kernels, dictionary-encoded numeric predicates, AND/OR short-circuit |
| `eval_case` | CASE/WHEN, each arm evaluated over the rows it answers |
| `eval_in_list`, `eval_dict` | IN lists; dictionary-to-string materialization |
| `arm_rows`, `literal_arm_domain`, `integer_literal_value`, `temporal_literal_value`, `numeric_dict_lut_scan`, `dict_mat_counter` | shared helpers |

`eval_column`, `eval_predicate` and `eval_case` (with the `project_*` and
`predicate_binary` arms) call one another, so they are one unit of the package.

## Tests

`tests/` holds the package's tests; every one is listed in `test_srcs` in the
package `BUCK` file, so the library is not produced unless all of them pass.
