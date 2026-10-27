# komira_broker_compaction

The compaction adapter over `komira_broker`. The broker core stores everything
in an object store and may not depend on the Arrow-IPC decoder or the Parquet
writer; this package layers the format-aware half above it.

- `transcode_segments_to_parquet` decodes N live Arrow-IPC `.seg` streams
  (`decode_segment_stream`), checks that they share one schema
  (`assert_uniform_schema`, which raises on a divergence instead of merging) and
  writes them as one Parquet object's bytes in offset order. Values, nullability
  and column order round-trip; dictionary columns are expanded to plain.
- `CompactionWorker` runs one bounded compaction round for a topic-partition:
  it selects a contiguous prefix of uncompacted live segments, reads and
  transcodes them, PUTs the Parquet object, appends a `CompactedEntry` to the
  separate compaction index, and only then tombstones the superseded live
  chunks, so a crash between steps leaves the live tier readable.
  `CompactionRoundResult` reports the round, and `slo_backpressure` answers how
  many live segments are not yet compacted.
- `DualTierConsumer` reads `[start_offset, tail)` across both tiers: compacted
  Parquet objects (`decode_compacted_parquet_bytes`) and live Arrow-IPC
  segments. A live segment that is gone because compaction reaped it is
  re-resolved against the compacted tier (read-repair). `read_from_pushdown`
  applies a predicate and a projection on both tiers: the compacted tier prunes
  row groups by their min/max statistics (`decode_compacted_parquet_bytes_pushdown`,
  `CompactedDecodeResult`, `DualTierPushdownResult` report the row-group
  accounting); the live tier filters then projects after decode. Both tiers
  return the same row set. `SubLineageDualTierConsumer` does the same over the
  sub-lineage model (the folded `_base` plus the serve-merged tail).
- `ProductionLogCleaner` is the log cleaner for `cleanup.policy=compact`
  partitions: it decodes cleanable `.seg` objects, keeps the latest record per
  key with a wall-clock tombstone grace, re-encodes the survivors as a new
  `.seg` at the original offsets, swaps the manifest chunk body by
  compare-and-swap, and schedules the orphaned original `.seg` for deletion
  after a grace period (`CompactionReapWorker`). A chunk with no survivors
  becomes an empty-segment marker, so a second round does not rewrite it.
- `run_maintenance_pass` is the run-once maintenance entry point for a
  scheduler: it enumerates the cluster's topics and dispatches retention, the
  log cleaner or both by `cleanup.policy`, and the auto-merge scan.
  `run_sublineage_maintenance_pass` additionally folds sub-lineage tails into
  `_base` and runs the contiguity-audited retention. Neither loops, sleeps or
  reads a clock; the caller passes `now_ms`, and a topic whose maintenance
  raises is recorded in the summary's `errors` and skipped.

The store is a type parameter on every driver (a `ConditionalWriteStore` or
`CloneableConditionalWriteStore`), so the same code runs over the in-memory
store in tests and an object-store client in a deployment.
