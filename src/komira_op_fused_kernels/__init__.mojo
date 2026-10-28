"""`komira_op_fused_kernels` -- INNER join kernels that fuse a
probe with its output.

The parallel single-INT64-key INNER probes of a `HashJoinBuilder` or a
`PerfectHashJoin` over the engine's dispatcher (`parallel_inner_probe`) and
the row count that selects them (`parallel_gate`); the single-pass fused INNER
join, full or projected (`join_fused_gather`); the chunked INNER join
(`join_chunked_gather`); which inputs those two can carry
(`join_fused_route`).

Public API: import directly from sub-modules. No facade.
"""
