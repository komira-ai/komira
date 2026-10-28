"""`komira_op_join_probe` -- the probe side of the engine's joins.

The composite-key hash join: `MultiKeyHashJoinBuilder`
(`join_multi_key_builder`) with its INNER and LEFT probes, the SEMI and ANTI
probes (`join_multi_key_filter`), the RIGHT and FULL probes
(`join_multi_key_outer`), the key slots, hashes and equality arms they share
(`join_multi_key`), the parallel INNER probe over the engine's dispatcher
(`join_multi_key_parallel`, `join_multi_key_parallel_task`), the extraction
of a batch's join-key columns into key slots (`join_key_extract`), and the
composite join probe operator over a physical plan's `MorselOp`
(`join_probe_multi_key`). Float keys follow the query semantics' float model.
Settings are set once per process from flags (`join_probe_settings`); nothing
here reads the environment.

Public API: import directly from sub-modules. No facade.
"""
