"""`komira_op_spill_rows` -- the spill of the engine's row-format breakers.

`agg_spill.RowHashAggSpillState` spills a `RowHashAggTable`'s partial groups
over a memory budget and folds them back by key at finalize (repartitioning by
key hash when the fold would pass the budget); `sort_spill.RowSortSpillState`
spills a `RowSortBuffer`'s sorted runs and k-way merges them back.
`agg_spill_codec` is the THSPILL2 write and read of a packed group-row image.

The budget and the spill directory are constructor arguments; the caller takes
them from its flags. It depends on `komira_row_format`, the spill layer of
`komira_engine_runtime` and `komira_op_sort`'s k-way merge.

Public API: import directly from sub-modules. No facade.
"""
