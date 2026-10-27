# komira_dispatch_project

The lowering layer of the engine dispatcher's computed projection: the translator from a plan expression to the runtime-expression pool `komira_eval.ExpressionExecutor` walks, and the census a projection refusal reports.

## Entry points

| function | module | does |
| --- | --- | --- |
| `translate_expr(e, pool, ...)` | `lower_untyped_expr` | lowers a plan `Expr` into the `RuntimeExpr` pool `komira_eval.ExpressionExecutor` walks; raises `UnsupportedByLowerUntypedExpr:` on a shape it has no node for |
| `count_and_conjuncts(pool, root)` | `lower_untyped_expr` | the conjunct count of a translated AND chain |
| `format_project_decline_census(in_schema, exprs, out_schema)` | `project_decline_census` | the lines a projection refusal reports |

## Lowering

`translate_expr` is deterministic: the same expression and column maps always append the same nodes in the same order. It rewrites nothing; the plan it lowers arrives optimized. The runtime family of an expression (`_infer_runtime_dtype`, `lower_untyped_expr_dtype`) picks the node of each operator and the walker channel of a computed column.

## Modules

| module | holds |
| --- | --- |
| `lower_untyped_expr` | the translator's entry points, its tag dispatch, the CASE, math and cast arms, and the `RUNTIME_DTYPE_*` families |
| `lower_untyped_expr_ops` | the column, literal, binary, unary, LIKE and IN-list arms |
| `lower_untyped_expr_dtype` | the runtime family of an expression |
| `project_decline_census` | the refusal census |

`lower_untyped_expr`, `lower_untyped_expr_ops` and `lower_untyped_expr_dtype` call one another, so they are one unit of the package.

## Tests

`tests/` holds the package's tests; every one is listed in `test_srcs` in the package `BUCK` file, so the library is not produced unless all of them pass.
