"""`komira_op_agg_hash` -- the hash aggregation tables of the engine.

`FlatHashAggregator` is the split-index hash table of GROUP BY aggregation:
a compact tag array to probe, a slot directory, and an insertion-order entry
buffer that holds each group's hash, Int64 keys and accumulator slots (laid
out by a `komira_agg_api.AggLayout`). `PerfectHashAggregator` is a flat array
for small dense integer key domains, `PartitionedFlatHashAggregator` holds a
FlatHashAggregator per radix partition, and `FlatHashPartitionFlush` buffers
the rows a table scatters by partition when it reaches its cache-resident
cap. `AggCommitPlan` folds a record batch's value columns into the
accumulator slots of any of the three tables, per row or loop-transposed
per batch.

It depends on `komira_op_agg_state` (the row kernels), `komira_agg_api` (the
slot layout), `komira_udf` (the float order of MIN / MAX), the core
packages, and on no sink: the sinks that drive these tables are in the
packages above.

Modules: `flat_hash_agg` (with `flat_hash_agg_hash`, `flat_hash_agg_probe`,
`flat_hash_agg_accumulator`, `flat_hash_agg_dispatch`: package-private
helpers), `flat_hash_agg_perfect`, `partitioned_flat_hash_agg`,
`flat_hash_partition_flush`, `agg_commit` (with `agg_commit_batch`).

Public API: import directly from sub-modules. No facade.
"""
