# `eval`

The row-mode expression executor over the core packages (`arrow`, `column_kernels`, `plan_expr`).

## Responsibility

`eval` is the residual of the old evaluation layer. It owns:

- **The executor.** `expression_executor` walks a runtime expression over a
  row block or a column view, with the adaptive filter-ordering state
  (`adaptive_filter`, `filter_state`) and its random source (`xorshift64`).
- **Typed conformers.** `expr_x_conformers` provides the concrete column,
  literal and operator structs that conform to the `expr` typed
  expression traits.
- **Column-kernel tests.** 26 tests of the evaluation kernels now in `column_kernels` (string
  and numeric comparison, arithmetic, casts, fused predicates, selection) run
  here, because they exercise the evaluation layer through core-package
  imports only.
- **Sum of an expression.** `builtin_agg_fns_sum_expr`, the aggregate over an
  expression-valued aggregand.

Everything else the old layer held is its own package, imported directly:

| Package | Holds |
| --- | --- |
| `row_format` | row blocks, directory, sort, Arrow row encoding, xxh3, `RowOutput` / `RowSink`, `cell_source` |
| `kernels` | selection and comparison kernels, Kleene logic, builtin binary, match and hash functions |
| `udf` | the UDF trait surface, schema descriptors, and `float_quotient_order` (the float equality and ordering model) |
| `expr` | the runtime expression trees, `ExprX` traits, `stage_program` |
| `agg` | aggregate-function traits, builtin aggregates, hash-aggregate state |
| `column_kernels` | the evaluation kernels (arithmetic, comparison, casts, selection vectors, regexp) |
| `hashing` | the FNV-1a constants and byte-span hash |

There are no root re-exports: import each name from the module that defines it.

## Dependency direction

```
eval -> row_format, kernels, expr, udf,
               agg, arrow, byte_buffer, containers,
               column_kernels, plan_expr,
               scalar_arithmetic, simd_ops
```

`atomic_alias` is listed as a dependency only for
`tests/test_adaptive_filter_convergence.mojo`.

Operator, compiler, dispatch and SDK packages that run the executor depend on
`eval`; `eval` must not import any of them.
