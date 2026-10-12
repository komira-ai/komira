"""`komira_op_join_build` -- the build side of the engine's joins.

So far: the untyped hash-join table `JoinBuildTable_Untyped`
(`join_build_untyped`), its packed open-addressing `HashDirectory`
(`hash_directory`), its per-column cell kernels (`join_build_untyped_cells`)
and the key hashes the untyped tables share (`join_untyped_key_hash`). Nothing
here reads the environment.

Public API: import directly from sub-modules. No facade.
"""
