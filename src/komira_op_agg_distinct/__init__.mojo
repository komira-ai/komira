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
COUNT(DISTINCT) of a STRING column (`cd_string_parallel`), the per-worker
state of the streaming COUNT(DISTINCT) aggregation
(`streaming_agg_count_distinct`, with its row loop `cd_stream_consume`, the
global group directory `cd_global_dir` and the route counters
`cd_passenger_lane_counter`), the streaming COUNT(DISTINCT) sink
(`agg_sink_count_distinct`, with its ungrouped union
`agg_count_distinct_kernel`), and the parallel per-group finalize of the stage
MEDIAN drain (`median_parallel_drain`).

Public API: import directly from sub-modules. No facade.
"""
