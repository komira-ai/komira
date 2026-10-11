"""`komira_op_sort` -- the sort kernels of the engine.

Stable sorts of one key column into a permutation (`sort`: a merge sort per
key DType; `sort_radix`: an LSD radix sort over 64-bit keys), top-K heap
selection over one key column (`sort_topn`), and the loser tree that k-way
merges sorted runs (`sort_loser_tree`). A sort never moves data: it returns
Int32 row indices and the caller gathers by them. `sort_parallel` and
`sort_parallel_string` run the single-key sorts, and the merges of sorted
partitions, on the engine's fork-join runtime, with the serial kernels'
result.

Float keys sort in DuckDB's total order: NaN above +inf, all NaNs equal,
-0.0 equal to +0.0 (`sort.sort_key_lt`).

Public API: import directly from sub-modules. No facade.
"""
