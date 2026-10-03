# `komira_eval`

The row-mode expression executor over `komira_core`.

## Responsibility

`komira_eval` is the residual of the old evaluation layer. It owns:

- **The executor.** `expression_executor` walks a runtime expression over a
  row block or a column view, with the adaptive filter-ordering state
  (`adaptive_filter`, `filter_state`) and its random source (`xorshift64`).
- **Typed conformers.** `expr_x_conformers` provides the concrete column,
  literal and operator structs that conform to the `komira_expr` typed
  expression traits.
- **Column-kernel tests.** 26 tests of the `komira_core.eval` kernels (string
  and numeric comparison, arithmetic, casts, fused predicates, selection) run
  here, because they exercise the evaluation layer through `komira_core`
  imports only.
- **Sum of an expression.** `builtin_agg_fns_sum_expr`, the aggregate over an
  expression-valued aggregand.

Everything else the old layer held is its own package, imported directly:

| Package | Holds |
| --- | --- |
| `komira_row_format` | row blocks, directory, sort, Arrow row encoding, xxh3, `RowOutput` / `RowSink`, `cell_source` |
| `komira_kernels` | selection and comparison kernels, Kleene logic, builtin binary, match and hash functions |
| `komira_udf` | the UDF trait surface, schema descriptors, and `float_quotient_order` (the float equality and ordering model) |
| `komira_expr` | the runtime expression trees, `ExprX` traits, `stage_program` |
| `komira_agg` | aggregate-function traits, builtin aggregates, hash-aggregate state |
| `komira_core` | the `komira_core.eval` kernels (arithmetic, comparison, casts, selection vectors, regexp) |
| `komira_hash` | the FNV-1a constants and byte-span hash |

There are no root re-exports: import each name from the module that defines it.

## Dependency direction

```
komira_eval -> komira_row_format, komira_kernels, komira_expr, komira_udf,
               komira_agg, komira_core
```

`komira_atomic_alias` is listed as a dependency only for
`tests/test_adaptive_filter_convergence.mojo`.

Operator, compiler, dispatch and SDK packages that run the executor depend on
`komira_eval`; `komira_eval` must not import any of them.
