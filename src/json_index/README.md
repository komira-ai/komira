# json_index

The JSON structural index and the `json_extract` kernel, split out of `jsonl`.

- `simd_primitives`: the Stage 1 SIMD helpers (16-byte movemask, prefix-XOR, the character-class table, the escape state machine).
- `structural_index`: the structural-token indexer built on them.
- `input_limits`: the input size and column-count limits, checked before an index is built.
- `parse_string`: the JSON string unescaper.
- `json_extract_kernel`: `json_extract` over a string column of an Arrow batch.

## Dependency direction

`json_index` depends on `arrow`, `byte_buffer`, `plan_expr` and `simd_ops` only. `jsonl` depends on it, so a package that needs `json_extract` or the structural index and nothing else (the expression evaluators, for one) no longer pulls in the JSONL readers and writers, `async_rt` and `row_format`.
