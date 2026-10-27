"""`komira_op_join_stage` -- the typed hash join of the engine's stage pipelines.

`JoinBuildTable[KB, *Payload]` (`join_build_table`), a hash-join build table
over a key block of any arity (`join_key_bundle`: `KeyBundleVar`,
`KeyBundle1`..`KeyBundle4`; its batch-row entry points read up to four key
columns) and a pack of payload columns
(`join_payload_column`: `PayloadSlot`, `PayloadCol_JoinString`); its key
columns and key model (`join_key_slot`: every value a key, float keys under
the float model); its free functions over typed keys
(`join_build_table_fns`).

Public API: import directly from sub-modules. No facade.
"""
