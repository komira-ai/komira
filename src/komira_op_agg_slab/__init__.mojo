"""`komira_op_agg_slab` -- the struct-state hash aggregation table.

`SlabStorage` is a hash table of groups keyed by a packed composite key (one
to eight fixed-width columns; Int64 by default) with one columnar state slab
per aggregate. A slab is read as its aggregate's
`komira_op_agg_state.AggregatorWithStruct` state struct (a Welford, bivariate
Welford, median or largest-k state), so aggregates whose state is wider than
one scalar fold in place. The table probes sixteen 1-byte fingerprints per
SIMD compare; `probe_or_insert_multi_key[_with_hash]` and
`probe_or_insert_2int64_with_hash` return an `EntryHandle` and whether the
group is new; `init_state_with_struct`, `commit_aggregator_with_struct`,
`commit_corr_aggregator_with_struct`, `combine_donor_keys_with_struct` and
`finalize_aggregator_with_struct` run the aggregates over it; the
`finalize_keys_*` methods emit the keys in group order.

It depends on `komira_op_agg_hash` (the hash functions and `EntryHandle`),
`komira_op_agg_state` (the aggregates) and the core packages.

Modules: `slab_storage` (with `slab_storage_ck_helpers`, package-private).

Public API: import directly from sub-modules. No facade.
"""
