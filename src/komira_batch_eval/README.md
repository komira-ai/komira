# komira_batch_eval

Evaluates SQL expressions over Arrow record batches. This package will hold the
vectorized projection and predicate evaluators an executor host runs inside its
operators; today it holds the arms those evaluators share.

## Modules

| module | holds |
| --- | --- |
| `eval_in_list` | `_eval_in_list`: `x IN (...)` over a column, with SQL NULL semantics (a NULL operand, or no match against a list holding NULL, is UNKNOWN) |
| `eval_dict` | `_materialize_dict_to_string`, `_densify_dict_column`: a dictionary-encoded string column resolved to a plain `StringArray` |
| `dict_mat_counter` | the process-wide count of those materializations, so a test can assert that a path did or did not reach it |
| `literal_arm_domain` | whether a literal can be compared with a column at all, and the refusal when it cannot |
| `integer_literal_value`, `temporal_literal_value` | an integer or temporal literal read in the column's own type and unit |
| `numeric_dict_lut_scan` | `numeric_dict_codes_to_mask`: a per-entry decision mapped over a numeric dictionary column's codes |
| `arm_rows` | `batch_nulled_outside`, `undecided_rows`: the rows an arm answers, for arms that may only be evaluated there |

The evaluator only evaluates: it rewrites no plan and registers no expression.

## Dependency direction

```
komira_batch_eval -> komira_arrow, komira_buffer   (batches, columns, bitmaps)
komira_batch_eval -> komira_plan_expr              (Expr, ScalarValue)
komira_batch_eval -> komira_column_kernels         (string comparison, compiler helpers)
komira_batch_eval -> komira_counters               (the materialization counter)
```

## Tests

`tests/` holds the package's tests; every one is listed in `test_srcs` in the
package `BUCK` file, so the library is not produced unless all of them pass.
