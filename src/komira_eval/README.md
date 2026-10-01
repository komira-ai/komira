# `komira_eval`

The expression and aggregate evaluation layer of the engine, built on
`komira_core`.

## Responsibility

`komira_eval` owns the evaluation primitives that filter, project and
aggregate operators run against:

- **Kernel re-exports.** The comparison, arithmetic, string, cast/null,
  selection-vector, dictionary-filter and selective-decode kernels are
  defined in `komira_core.eval` and re-exported from this package's
  `__init__.mojo`, so `from komira_eval import eval_gt` resolves.
- **Three-valued logic.** Kleene AND/OR/NOT helpers (`kleene`,
  `comparison_kleene`) and the Kleene-aware column-vs-column comparisons.
- **Expression evaluation.** The runtime expression trees
  (`runtime_expr`, `runtime_expr_bool`), the expression interpreter and
  executor, the typed expression surface (`expr_x`, `expr_x_conformers`,
  `expr_traits_unified`, `eval_chunks`) and the column resolver that binds
  column names to physical indices.
- **Functions and UDFs.** Scalar, binary, match, map, hash and filter
  function traits and their built-ins; the UDF surfaces (`ScalarUdf`,
  `UdfDescriptor`, `ExprScalarFn`, row UDFs, typed UDF sugar) and the
  `AutoKomiraSchema` marker trait for UDF row structs.
- **Aggregation.** The aggregate-function traits (`agg_fn`,
  `agg_op_traits`), the built-in aggregates (`builtin_agg_fns_*`: count,
  sum, avg, min/max, first/last, stddev/variance, correlation, bool,
  string and vector aggregates) and hash-aggregate state
  (`hash_agg_op_*`).
- **Row format** (`row_format/`). Row blocks, the row directory, row
  sort and sort permutations, the Arrow row encoding and xxh3 hashing.
- **Windows.** Window-function traits and frame specifications.

It does not own the expression IR (`Expr`, `BinaryOp`, ...), which lives in
`komira_core.plan`, nor the operators and the runtime dispatch that call
these kernels.

## Dependency direction

```
komira_eval -> komira_core, komira_atomic_alias
```

Operator, compiler, dispatch, storage-format and SDK packages depend on
`komira_eval`; `komira_eval` must not import any of them.
