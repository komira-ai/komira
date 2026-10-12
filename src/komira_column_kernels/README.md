# komira_column_kernels

Vectorized compute over Arrow columns: arithmetic, comparison, casts, string, regexp, dictionary, union, decimal, case mapping, and the batch helpers that import them.

`cross_batch_gather` builds one batch from rows of several batches that share a
schema, in the order of a list of `(source, row)` pairs (the external sort
materializes its merge with it).
