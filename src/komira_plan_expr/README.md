# komira_plan_expr

The expression language of a plan (Expr, AggExpr, ScalarValue, ColExpr builder, UDF payloads, ExprId/ExprPool) and the comptime schema descriptor.

There is no facade: import from the sub-modules (`komira_plan_expr.col_expr`,
`komira_plan_expr.expr`, `komira_plan_expr.agg_expr`,
`komira_plan_expr.scalar_value`, and so on).

- `col(name)` and `lit(value)` start a `ColExpr`, a builder whose comparison
  (`> < == !=`) and boolean (`& |`) operators return an `Expr`, and whose
  arithmetic (`+ - * /`) returns another `ColExpr`. `.alias(name)` names the
  output column.
- `Expr` is the tree a plan holds. Its text (`write_to`, so `String(e)`) names
  every node and value; a plan's render, and so its structural hash, is built
  from it, so two different expressions render differently.
- `AggExpr` is an aggregation (`sum`, `count`, `min`, `max`, `mean`, ...) with
  an optional output name.
- `ScalarValue` is one typed value: a literal, a statistic, a NULL.

## Examples

A filter predicate and a computed column, and their text:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_plan_expr.col_expr import ColExpr, col
from komira_plan_expr.expr import BIN_AND, BIN_GT

var adult = col("age") > 25
assert_true(adult.is_binary())
assert_equal(Int(adult.binary_op()), Int(BIN_GT))
assert_equal(adult.binary_left_ref().col_ref_name(), "age")
assert_equal(String(adult), "BinaryOp(GT, ColRef(age), Literal(ScalarValue(int64, 25)))")

# `&` combines two predicates into one AND node.
var both = ColExpr(adult^) & (col("score") > col("bar"))
assert_equal(Int(both.binary_op()), Int(BIN_AND))
assert_equal(
    String(both),
    "BinaryOp(AND, BinaryOp(GT, ColRef(age), Literal(ScalarValue(int64, 25))),"
    + " BinaryOp(GT, ColRef(score), ColRef(bar)))",
)

# Arithmetic stays a ColExpr until `.alias` names the output column.
var total = (col("price") * col("quantity")).alias("total")
assert_true(total.is_alias())
assert_equal(total.alias_name(), "total")
assert_equal(String(total), 'Alias(BinaryOp(MUL, ColRef(price), ColRef(quantity)), "total")')
```

Aggregations, named and unnamed:

<!-- mojo-hidden from std.testing import assert_equal, assert_false -->
```mojo
from komira_plan_expr.agg_expr import AGG_COUNT, AGG_SUM, count, sum
from komira_plan_expr.col_expr import col

var revenue = sum(col("amount")).alias("revenue")
assert_equal(Int(revenue.func), Int(AGG_SUM))
assert_equal(revenue.alias_name.value(), "revenue")
assert_equal(String(revenue), 'SUM(ColRef(amount)).alias("revenue")')

var rows = count()  # COUNT(*): no argument, no name
assert_equal(Int(rows.func), Int(AGG_COUNT))
assert_false(Bool(rows.alias_name))
assert_equal(String(rows), "COUNT(*)")
```

Scalar values compare by type and value, and a NULL is its own kind:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_plan_expr.scalar_value import ScalarValue

var seven = ScalarValue.from_int(7)
assert_true(seven.is_int())
assert_true(seven == ScalarValue.from_int(7))
assert_true(seven != ScalarValue.from_int(8))
assert_equal(String(seven), "ScalarValue(int64, 7)")
assert_equal(String(ScalarValue.from_string("eu")), 'ScalarValue(utf8, "eu")')
assert_equal(String(ScalarValue.from_bool(True)), "ScalarValue(bool, true)")

var missing = ScalarValue.null(DType.int64)
assert_true(missing.is_null())
assert_false(missing.is_int())
assert_true(missing.null_type() == DType.int64)  # the NULL keeps its column type
```
