# komira_dispatch_project

The computed-projection evaluator of the engine dispatcher. A physical plan's project operator carries its output expressions (`ExprArray`) and their declared output schema; this package evaluates them over a resident `RecordBatch`.

## Entry points

| function | module | does |
| --- | --- | --- |
| `eval_project_exprs_over_batch(batch, exprs, out_schema)` | `compute_project` | the projected batch, or None when an output is outside the evaluator's reach (the caller declines) |
| `eval_project_exprs_over_batch_on_dispatcher(dispatcher, batch, exprs, out_schema)` | `compute_project` | the same, with the dense FLOAT64 evaluator fanned over the dispatcher's workers |
| `translate_expr(e, pool, ...)` | `lower_untyped_expr` | lowers a plan `Expr` into the `RuntimeExpr` pool `komira_eval.ExpressionExecutor` walks; raises `UnsupportedByLowerUntypedExpr:` on a shape it has no node for |
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
- CASE, REGEXP, SUBSTRING, the string functions, `abs`/`sign`/`trunc`/`round`/`bit_count`, a UDF call anywhere in the tree, EXTRACT, the null tests, the nested extracts and CAST go to the column evaluator (`komira_batch_eval`);
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

`try_eval_dense_f64` admits a tree of FLOAT64 and INT64 column leaves, literals and the four FLOAT64 arithmetic operators (`+ - * /`), and declines any other node, a column of another type or layout, a column the batch does not hold, a column shorter than the batch, and a cyclic pool; the caller then runs the walker. Over an admitted tree its answer, and the answer of `try_eval_dense_f64_pooled` over a started runtime, is bit-identical to the walker's: NaN, signed zero, infinities and division by zero included. Like the walker it reads a NULL slot's payload and returns a column with no validity bitmap; `compute_project` routes a strict arithmetic expression over an input that holds a NULL to the column evaluator before the dense evaluator is asked. `tests/test_project_dense_f64_differential.mojo` compares the two evaluators by bit pattern and `tests/test_project_dense_f64_admission.mojo` checks each decline.

## Tests

`tests/` holds the package's tests; every one is listed in `test_srcs` in the package `BUCK` file, so the library is not produced unless all of them pass.
