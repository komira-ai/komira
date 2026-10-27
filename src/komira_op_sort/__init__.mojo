"""`komira_op_sort` -- the sort kernels of the engine.

Stable sorts of one key column into a permutation (`sort`: a merge sort per
key DType; `sort_radix`: an LSD radix sort over 64-bit keys), top-K heap
selection over one key column (`sort_topn`), the loser tree that k-way
merges sorted runs (`sort_loser_tree`), and the sort and top-N sink kernels
(`sort_topn_sink`, with the bounded-heap selection in `sort_topn_heap`), and
the run-time-typed multi-key sort buffer (`sort_buffer_untyped`). A
sort never moves data: it returns Int32 row indices and the caller gathers by
them.

Float keys sort in DuckDB's total order: NaN above +inf, all NaNs equal,
-0.0 equal to +0.0 (`sort.sort_key_lt`).

Public API: import directly from sub-modules. No facade.
"""
