# komira_telemetry_store

The at-rest format of telemetry (logs and metrics) in an object store. A segment
is one time-sorted Parquet object, published before the manifest entry that
makes it readable, so any Parquet reader can query the objects directly.

- `keys`: `<root>/<dataset>/<YYYYMMDD>/data/<start_ms:020d>-<uuid>.parquet`. The
  UTC day is in the key, so a reader holding a time range computes the day
  prefixes by arithmetic and never lists to find them (`days_covering`, at most
  400 days per query). Key depth is a constant: a caller-supplied segment with
  a `/` or no characters is refused. An optional text-index sidecar's key is
  derived from the data key (`telemetry_text_sidecar_key`).
- `segment_entry`: `TelemetrySegmentEntry`, the CAS-manifest chunk body. It
  carries the object key, `[min_ts_ns, max_ts_ns]`, a series-id range (metrics),
  row count, byte size, the compaction maturity and the uuids a merged segment
  absorbed. The envelope is a fixed binary layout; a truncated, empty or
  unknown-version body raises, and version 1 is reserved and refused by name.
- `manifest`: one writer shard's catalog for one `(dataset, day)` partition on
  `CasManifestStore`. Replay is exact GETs: a gap-tolerant pass up to the
  durable `_HEAD`, then a forward probe of computed keys until the first
  not-found (the durable head can lag the warm appends). The merge-input skip
  drops a compaction's inputs while both are live. The only LIST is
  writer-shard enumeration (`discover_partition_writer_ids`);
  `plan_time_range_read` runs the whole read: days, writers, replay, prune.
- `log_writer`: `TelemetryLogSegmentWriter` takes batches with a `timestamp`
  column (TIMESTAMP_NS or INT64 nanoseconds), splits the rows by UTC day,
  stable-sorts each day by time, writes Parquet (Snappy by default), PUTs the
  object and then appends the manifest entry.
- `metric_writer`: `TelemetryMetricSegmentWriter` does the same for a fact
  table with `ts` and `series_id` columns, sorted `(series_id, ts)`, and its
  entry also carries the series range. It never writes a text sidecar.

The store is a trait parameter (`CloneableConditionalWriteStore`); the writers
read no environment and resolve no bucket. Not here: the per-partition series
side table of the metrics dataset, a compactor, retention, and a flush cadence.
