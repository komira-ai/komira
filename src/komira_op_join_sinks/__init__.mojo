"""`komira_op_join_sinks` -- the per-worker operators a join pipeline
constructs over the join probe.

`JoinProbeOpAdapter` (`join_probe_op_adapter`), the single-key probe a driver
allocates per worker, which forwards to `komira_op_join_probe`'s
`JoinProbeOp`; the probe cascades (`multi_probe_op_adapter`):
`MultiProbeOpAdapter` over single-key `JoinProbeOp`s and
`MultiKeyProbeCascadeAdapter` over composite-key `MultiKeyJoinProbeOp`s, which
run several joins over one morsel in turn and refuse a probe that cannot
finish its morsel in one call; and the marking pass of a SEMI / ANTI join that
builds its LEFT side (`mark_semi_anti`, `MarkSemiAntiProbeOp`) over
`FinalizedHashIndex` (`finalized_hash_index`), a finished single-INT64-key
table with a matched flag per build row. A NULL key matches nothing; float
keys follow the query semantics' float model through the composite probe.

Public API: import directly from sub-modules. No facade.
"""
