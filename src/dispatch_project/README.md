# dispatch_project

The computed-projection evaluator of the engine dispatcher. A physical plan's project operator carries its output expressions (`ExprArray`) and their declared output schema; this package evaluates them over a resident `RecordBatch`.

## Entry points

| function | module | does |
| --- | --- | --- |
| `eval_project_exprs_over_batch(batch, exprs, out_schema)` | `compute_project` | the projected batch, or None when an output is outside the evaluator's reach (the caller declines) |
| `eval_project_exprs_over_batch_on_dispatcher(dispatcher, batch, exprs, out_schema)` | `compute_project` | the same, with the dense FLOAT64 evaluator fanned over the dispatcher's workers |
| `translate_expr(e, pool, ...)` | `lower_untyped_expr` | lowers a plan `Expr` into the `RuntimeExpr` pool `eval.ExpressionExecutor` walks; raises `UnsupportedByLowerUntypedExpr:` on a shape it has no node for |
| `count_and_conjuncts(pool, root)` | `lower_untyped_expr` | the conjunct count of a translated AND chain |
| `is_literal_output_expr(e)` | `compute_project_routes` | whether a projected output is a constant (a literal, under any number of aliases) |
| `try_eval_dense_f64(pool, root, names, batch)`, `try_eval_dense_f64_pooled(...)`, `dense_par_task_rows(n, nw)`, `DENSE_PAR_MIN_ROWS` | `project_dense_f64` | the column-at-a-time evaluator of the FLOAT64 arithmetic subset |
| `format_project_decline_census(in_schema, exprs, out_schema)` | `project_decline_census` | the lines a projection refusal reports |

The output batch matches the declared schema (one column per expression, each of the declared type and of the batch's row count) or the evaluator returns None. An integer overflow raises, as do the errors of the column evaluator.

Two switches are arguments, both on by default: `dense_f64 = False` runs the walker for every FLOAT64 computed column, and `dense_par = False` keeps the dense evaluator on the calling thread.

## Routes

Each output expression takes one route (`compute_project_routes` holds the predicates). An alias is a name only, so an expression under any number of aliases takes the route of the expression itself:

- a column reference is copied (with its NULLs) when its type shares storage with the declared type, or is the same variable-length type at the other offset width;
- a literal is broadcast to the batch's row count;
- CASE, REGEXP, SUBSTRING, the string functions, `abs`/`sign`/`trunc`/`round`/`bit_count`, a UDF call anywhere in the tree, EXTRACT, the null tests, the nested extracts and CAST go to the column evaluator (`batch_eval`);
- a strict arithmetic expression over an input that holds a NULL, or one holding a math op whose domain is checked, goes to the column evaluator, which keeps validity and checks the domain;
- everything else is translated and evaluated by the walker channel of its family (I64 or F64).

## Lowering

`translate_expr` is deterministic: the same expression and column maps always append the same nodes in the same order. It rewrites nothing; the plan it lowers arrives optimized. The runtime family of an expression (`_infer_runtime_dtype`, `lower_untyped_expr_dtype`) picks the node of each operator and the walker channel of a computed column.

## Modules

| module | holds |
| --- | --- |
| `compute_project` | the evaluator and its entry points |
| `compute_project_routes` | the route predicates, the passthrough storage checks and the column maps |
| `lower_untyped_expr` | the translator's entry points, its tag dispatch, the CASE, math and cast arms, and the `RUNTIME_DTYPE_*` families |
| `lower_untyped_expr_ops` | the column, literal, binary, unary, LIKE and IN-list arms |
| `lower_untyped_expr_dtype` | the runtime family of an expression |
| `project_dense_f64` | the dense FLOAT64 evaluator, serial and pooled |
| `project_decline_census` | the refusal census |

`lower_untyped_expr`, `lower_untyped_expr_ops` and `lower_untyped_expr_dtype` call one another, so they are one unit of the package.

## The dense FLOAT64 evaluator

`try_eval_dense_f64` admits a tree of FLOAT64 and INT64 column leaves, literals and the four FLOAT64 arithmetic operators (`+ - * /`), and declines any other node, a column of another type or layout, a column the batch does not hold, a column shorter than the batch, and a cyclic pool; the caller then runs the walker. Over an admitted tree its answer, and the answer of `try_eval_dense_f64_pooled` over a started runtime, is bit-identical to the walker's: NaN, signed zero, infinities and division by zero included. Like the walker it reads a NULL slot's payload and returns a column with no validity bitmap; `compute_project` routes a strict arithmetic expression over an input that holds a NULL to the column evaluator before the dense evaluator is asked. `tests/test_project_dense_f64_differential.mojo` compares the two evaluators by bit pattern, including NaN payloads and, for the pooled form, the same special values and NULL slots over a ragged last task, and `tests/test_project_dense_f64_admission.mojo` checks each decline.

## Tests

`tests/` holds the package's tests; every one is listed in `test_srcs` in the package `BUCK` file, so the library is not produced unless all of them pass.

## Examples

Both examples run as tests when the package is built, so they cannot go stale. The package exports nothing at its top level; each name is imported from the module in the table above.

### Evaluating a projection

`eval_project_exprs_over_batch` takes the input batch, the output expressions and the declared output schema. This one copies a column and computes `CAST(num AS DOUBLE) / den`. The cast makes the division exact (an integer division would truncate 303 / 8 to 37). A projected literal is broadcast to the batch's row count, and `is_literal_output_expr` tells a literal output from a computed one.

```mojo
from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatchBuilder
from arrow.schema import Field, SchemaBuilder
from dispatch_project.compute_project import eval_project_exprs_over_batch
from dispatch_project.compute_project_routes import is_literal_output_expr
from plan_expr.expr import BIN_ADD, BIN_DIV, Expr
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import ExprArray
from std.testing import assert_equal, assert_false, assert_true

var nums = PrimitiveArray[DType.int64].allocate(2)
var dens = PrimitiveArray[DType.int64].allocate(2)
nums.store[1](0, SIMD[DType.int64, 1](Int64(303)))
nums.store[1](1, SIMD[DType.int64, 1](Int64(75)))
dens.store[1](0, SIMD[DType.int64, 1](Int64(8)))
dens.store[1](1, SIMD[DType.int64, 1](Int64(32)))
var in_schema = SchemaBuilder()
in_schema.add_field(Field(String("num"), ArrowType.INT64, False))
in_schema.add_field(Field(String("den"), ArrowType.INT64, False))
var rbb = RecordBatchBuilder.with_capacity(2)
rbb.add_column(Column.from_primitive[DType.int64](nums))
rbb.add_column(Column.from_primitive[DType.int64](dens))
var batch = rbb.build(in_schema.build())

var exprs = ExprArray()
exprs.append(Expr.col_ref(String("num")))
exprs.append(
    Expr.alias(
        Expr.binary(
            BIN_DIV,
            Expr.cast(Expr.col_ref(String("num")), DType.float64),
            Expr.col_ref(String("den")),
        ),
        String("ratio"),
    )
)
exprs.append(
    Expr.alias(Expr.literal(ScalarValue.from_int64(Int64(1))), String("one"))
)
var out_schema = SchemaBuilder()
out_schema.add_field(Field(String("num"), ArrowType.INT64, False))
out_schema.add_field(Field(String("ratio"), ArrowType.FLOAT64, True))
out_schema.add_field(Field(String("one"), ArrowType.INT64, False))

var out_opt = eval_project_exprs_over_batch(
    batch^, exprs, out_schema.build()
)
assert_true(Bool(out_opt))
var out = out_opt.take()
assert_equal(out.num_columns(), 3)
assert_equal(out.num_rows(), 2)
assert_equal(Int(out.column_as_primitive_int64(0).get(1)), 75)
assert_equal(Float64(out.column_as_primitive_float64(1).get(0)), Float64(37.875))
assert_equal(Float64(out.column_as_primitive_float64(1).get(1)), Float64(2.34375))
var one = out.column_as_primitive_int64(2)
assert_equal(one.length, 2)
assert_equal(Int(one.get(0)), 1)
assert_equal(Int(one.get(1)), 1)

var lit = Expr.alias(Expr.literal(ScalarValue.from_int64(Int64(1))), String("one"))
assert_true(is_literal_output_expr(lit))
assert_false(is_literal_output_expr(Expr.col_ref(String("num"))))
assert_false(
    is_literal_output_expr(
        Expr.binary(BIN_ADD, Expr.col_ref(String("num")), Expr.col_ref(String("den")))
    )
)
```

### The refusal census

When a caller has to decline a projection, `format_project_decline_census` renders the lines a refusal reports: the counts, one line per output expression and one per input column.

```mojo
from arrow.arrow_types import ArrowType
from arrow.schema import Field, SchemaBuilder
from dispatch_project.project_decline_census import (
    format_project_decline_census,
)
from plan_expr.expr import Expr
from plan_ir.logical_plan import ExprArray
from std.testing import assert_true

var in_schema = SchemaBuilder()
in_schema.add_field(Field(String("url"), ArrowType.LARGE_STRING, True))
in_schema.add_field(Field(String("c"), ArrowType.INT64, False))
var out_schema = SchemaBuilder()
out_schema.add_field(Field(String("url"), ArrowType.STRING, True))
out_schema.add_field(Field(String("n"), ArrowType.INT64, False))

var exprs = ExprArray()
exprs.append(Expr.col_ref(String("url")))
exprs.append(Expr.alias(Expr.col_ref(String("c")), String("n")))

var text = format_project_decline_census(
    in_schema.build(), exprs, out_schema.build()
)
assert_true(
    text.find(
        "[project-decline] CENSUS out_exprs=2 out_schema_cols=2 in_batch_cols=2"
    )
    >= 0
)
assert_true(
    text.find("expr[0] tag=EXPR_COL_REF out_name='url' declared=string(id=13)") >= 0
)
assert_true(
    text.find("src='url'@in[0] src_type=large_string(id=26) src_nullable=1") >= 0
)
assert_true(text.find("expr[1] tag=EXPR_ALIAS>EXPR_COL_REF out_name='n'") >= 0)
assert_true(text.find("in_batch[1] name='c' type=int64(id=5) nullable=0") >= 0)
```
