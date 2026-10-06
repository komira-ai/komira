"""`komira_op_agg_row_api` -- the shared types of the engine's row-hash aggregation.

The aggregate-op tags (`AGG_*`) and the per-aggregate descriptor `AggSpec`, the
op predicates and the op-to-merge-class map (`agg_spec`), the merge-cell classes
and their widths (`combine_agg_plan`), the ingest probe's monomorphic key class
(`agg_key_class`) and the key-staging window arithmetic (`agg_chunk_rows`).
Pointer-free, no table state, and nothing here reads the environment.

It depends on `komira_column_format` only.

Public API: import directly from sub-modules. No facade.
"""
