"""`komira_op_join_build` -- the build side of the engine's joins.

The untyped hash-join table `JoinBuildTable_Untyped` (`join_build_untyped`), its
packed open-addressing `HashDirectory` (`hash_directory`), its per-column cell
kernels (`join_build_untyped_cells`) and key hashes (`join_untyped_key_hash`);
the CROSS-join kernel (`cross_join_kernel`); the blocking functions of
non-equi joins (`join_blocking`); the probe-side NULL mask
(`join_probe_null_mask`); and the settings, pure predicates and witness
counters of the build's levers (`join_bloom_l1_resident`,
`join_bloom_selectivity`, `join_probe_phase_split`, `join_layout_counter`,
`join_parallel_build_counter`). Settings are set once per process from flags;
nothing here reads the environment.

Public API: import directly from sub-modules. No facade.
"""
