"""`komira_op_agg_distinct` -- the COUNT(DISTINCT) kernels of grouped aggregation.

The STRING-key encode of the grouped COUNT(DISTINCT) driver
(`agg_count_distinct_strenc`, with its per-range and hash-sharded Phase B
bodies `agg_cd_strenc_rowdict` and `agg_cd_strenc_parb`).

Public API: import directly from sub-modules. No facade.
"""
