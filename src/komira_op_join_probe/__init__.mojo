"""`komira_op_join_probe` -- the probe side of the engine's joins.

The composite-key hash join: `MultiKeyHashJoinBuilder`
(`join_multi_key_builder`) with its INNER and LEFT probes, the SEMI and ANTI
probes (`join_multi_key_filter`), the RIGHT and FULL probes
(`join_multi_key_outer`), the key slots, hashes and equality arms they share
(`join_multi_key`), and the extraction of a batch's join-key columns into key
slots (`join_key_extract`). Float keys follow the query semantics' float model.
Nothing here reads the environment.

Public API: import directly from sub-modules. No facade.
"""
