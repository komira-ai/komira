# batch_eval

Evaluates SQL expressions over Arrow record batches: the vectorized projection
and predicate evaluators an executor host runs inside its operators.

## Entry points

| function | module | returns |
| --- | --- | --- |
| `evaluate_column(expr, batch)` | `evaluate` | the projection: one value per row, as a `Column` |
| `evaluate_predicate(expr, batch)` | `evaluate` | the predicate: one bit per row; UNKNOWN is data 0 with validity 0 |
| `evaluate_filter_narrowed(batch, predicate)` | `conjunction` | the surviving rows of a filter, as a `SelectionVector` |

`evaluate_filter_narrowed` narrows a selection vector conjunct by conjunct and
applies three-valued logic at the filter boundary: an UNKNOWN row is dropped,
and `TRUE OR NULL` is kept.

The evaluator only evaluates. It rewrites no plan and registers no expression:
the plan an executor host lowers arrives optimized, and this package is called
with the expressions that plan carries.

## Evaluating over a batch

`evaluate_column` computes one value per row and keeps an operand's NULL;
`evaluate_predicate` gives one bit per row, with UNKNOWN as data 0 and validity
0. The batch here is one nullable INT64 column `v` holding 10, NULL and 30.

```mojo
from arrow.arrow_types import ArrowType
from arrow.column_builder import ColumnBuilder
from arrow.record_batch import RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from batch_eval.evaluate import evaluate_column, evaluate_predicate
from plan_expr.expr import BIN_GT, BIN_SUB, Expr
from plan_expr.scalar_value import ScalarValue
from std.testing import assert_equal, assert_false, assert_true

var vb = ColumnBuilder[DType.int64].with_capacity(3)
vb.append(Int64(10))
vb.append_null()
vb.append(Int64(30))
var sb = SchemaBuilder()
sb.add_field(Field("v", ArrowType.INT64, True))
var rbb = RecordBatchBuilder()
rbb.add_column(vb^.materialize())
var batch = rbb.build(sb.build())

# 100 - v is [90, NULL, 70].
var diff = Expr.binary(
    BIN_SUB, Expr.literal(ScalarValue.from_int(100)), Expr.col_ref("v")
)
var out = evaluate_column(diff, batch)
assert_true(out.arrow_type == ArrowType.INT64)
assert_equal(out.length(), 3)
assert_true(out.is_null_at(1))
assert_equal(out.as_primitive[DType.int64]().get(0), Int64(90))
assert_equal(out.as_primitive[DType.int64]().get(2), Int64(70))

# v > 15 is [FALSE, UNKNOWN, TRUE].
var gt = Expr.binary(
    BIN_GT, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int(15))
)
var mask = evaluate_predicate(gt, batch)
assert_equal(len(mask), 3)
assert_false(mask.data.test(0))
assert_true(mask.data.test(2))
assert_true(Bool(mask.validity))
assert_false(mask.validity.value().test(1))
```

## Dependency direction

```
batch_eval -> arrow, byte_buffer, containers  (batches, columns, selection vectors)
batch_eval -> plan_expr     (Expr, ScalarValue)
batch_eval -> plan_ir       (udf_call_column_key)
batch_eval -> column_kernels, kernels, scalar_arithmetic  (the kernels)
batch_eval -> json_index    (the json_extract kernel)
batch_eval -> counters      (the dictionary-materialization reach counter)
```

The operators and the executor depend on this package; it depends on no
operator, no reader or writer, and no SDK.

## UDF calls

The `EXPR_UDF_CALL` arm reads the call's output column from the batch, under
the name `plan_ir.expr_udf_sites.udf_call_column_key` derives. The
evaluator calls no UDF itself: whatever runs the call materializes its output
onto the batch first, and a call whose column is missing is refused by name.

## Modules

| module | holds |
| --- | --- |
| `evaluate` | the public entry points |
| `eval_column` | `_eval_column_expr`, the projection ladder over the `EXPR_*` tags |
| `project_access`, `project_ops`, `project_cast`, `project_date_add`, `project_string`, `project_string_n` | its large arms |
| `column_compare`, `column_arith`, `column_decimal` | comparison under numeric promotion, column-scalar arithmetic, DECIMAL128 and temporal typing and casts |
| `string_metrics`, `string_bytes` | byte-level string measures and transforms |
| `eval_predicate` | `_eval_predicate`, the predicate ladder |
| `predicate_binary`, `predicate_compare`, `predicate_numeric_dict`, `predicate_logic` | its binary arm, comparison kernels, dictionary-encoded numeric predicates, AND/OR short-circuit |
| `eval_case` | CASE/WHEN, each arm evaluated over the rows it answers |
| `eval_in_list`, `eval_dict` | IN lists; dictionary-to-string materialization |
| `conjunction`, `predicate_null_scope` | selection-vector narrowing with three-valued logic; which columns' NULLs reach a predicate |
| `arm_rows`, `literal_arm_domain`, `integer_literal_value`, `temporal_literal_value`, `numeric_dict_lut_scan`, `dict_mat_counter` | shared helpers |

`eval_column`, `eval_predicate` and `eval_case` (with the `project_*` and
`predicate_binary` arms) call one another, so they are one unit of the package.

## Tests

`tests/` holds the package's tests; every one is listed in `test_srcs` in the
package `BUCK` file, so the library is not produced unless all of them pass.
