"""`op_window` -- the window operator.

`partition_scan_sink._execute_partition_by_sink` runs a `PartitionBySinkData`
over one batch: it sorts by (partition keys ++ order keys) as DuckDB orders
them (each order key's NULLs placed by `nulls_first`, last when it is
empty; NaN above +inf), evaluates every window function and emits
the sorted input columns followed by one column per function. Import from the
sub-modules; there is no facade.
"""
