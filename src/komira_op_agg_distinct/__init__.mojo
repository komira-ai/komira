"""`komira_op_agg_distinct` -- the COUNT(DISTINCT) kernels of grouped aggregation.

The string-key encode of the grouped COUNT(DISTINCT) driver
(`agg_count_distinct_strenc`, with its per-range and hash-sharded Phase B
bodies `agg_cd_strenc_rowdict` and `agg_cd_strenc_parb`), the
dictionary-code encode (`agg_cd_dictkey_encode`), the per-worker
distinct-pair set (`agg_cd_distinct_set`), the heavy-group split
(`agg_cd_heavy_split`), the group-table sizing rule
(`agg_cd_group_ht_sizing`), the string key emit (`agg_cd_key_emit`), the
radix-parallel COUNT(DISTINCT) of Int64 buffers (`cd_radix_parallel`) and of
every group of a grouped drain (`cd_radix_grouped`), the parallel
COUNT(DISTINCT) of a STRING column (`cd_string_parallel`), and the parallel
per-group finalize of the stage MEDIAN drain (`median_parallel_drain`).

Public API: import directly from sub-modules. No facade.
"""
