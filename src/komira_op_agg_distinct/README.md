# komira_op_agg_distinct

The COUNT(DISTINCT) kernels of grouped aggregation. This part holds the STRING-key encode of the grouped COUNT(DISTINCT) driver; the driver, the streaming sink and the stage distinct state are added by the changes that follow.

- `agg_count_distinct_strenc`: the STRING / LARGE_STRING group-key encode. A parallel pass hashes every row (FNV-1a 64 plus a length mix); dict ids are then assigned in FIRST-SEEN row order, verifying every hash hit against the bytes, by the first of three bodies that serves the key: one dictionary per row range merged in row order (`agg_cd_strenc_rowdict`, for keys with few distinct values), one dictionary per hash shard merged in parallel with the numbering preserved (`agg_cd_strenc_parb`, for at least 1,048,576 rows), or a serial open-addressed table. The first two leave the reverse map pointing into the source column's value buffer; the serial one builds an arena.

The numbering is the driver's output group order, so every body must number identically; the tests hold each parallel body to the serial one. The `cd_strenc_rowdict_*_count` / `reset_*` functions are process-wide counters that let a test see which body ran. The entry points take the raw value and offset buffers of a column and are package-private.
