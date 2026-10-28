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

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_plan_expr`, version 0.1.0
(`mopm.toml`). The library is `src/komira_plan_expr/`, its tests are `tests/`. It depends on three packages, sibling
directories (`[dependencies]` of `mopm.toml`): `komira_arrow`, `komira_collections` and `komira_scalar_arithmetic`, each
as `{ path = "../<name>", version = "0.1" }`. The `.conda` of this package records `mojo-<name> >=0.1,<0.2` for each of
them as a dependency and holds none of their files: installing `komira_plan_expr` installs them with it.
`komira_arrow` depends on `komira_buffer`, whose closure includes `komira_libc`, and `komira_libc` links a C shim of its
own; a dependent's link takes it from the closure, and this package owns no C. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies and where the library and its tests are |
| `mopm.lock` | the toolchain pins and the path dependencies, as `mopm lock` writes them (no registry is reached: every dependency is a sibling) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

`:lib` is the library file, built from the `:lib` of the siblings, and exists only once every test of `tests/` has
passed. After any change to a source, a test, a manifest of this package or of a sibling, run `buildrules mojo sync`
with the package and its siblings staged, commit what it writes, and build `komira//src/komira_plan_expr:lib` on the
farm.

`:conda` is buildrules' `mojo_conda` over `:lib`: the `.conda` of the mopm package
(`mojo-komira_plan_expr-0.1.0-mojo1.0.0_0.conda`), packed with the manifests of the path dependencies beside its own
(`members`), which therefore exists only once the tests have passed. Publishing it (`mopm publish`) uploads, so it is
a step of a CI job that takes that file, not a build action.
