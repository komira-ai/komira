# komira_telemetry_read

The direct query path over the at-rest telemetry format of
`komira_telemetry_store`: a time range in, object keys out, with no service in
the middle. Any Parquet engine can query the objects; what it cannot do alone is
turn a time range into the set of keys, because that needs the manifest replayed.

- `scan_plan`: `plan_telemetry_scan(store, dataset, t0_ns, t1_ns)` computes the
  UTC day partitions the range touches (arithmetic, no I/O), enumerates writer
  shards with one LIST per day plus one per shard, replays each shard's manifest by exact GETs, and
  prunes on the catalog entries alone: time overlap, an optional series range
  (`TelemetrySeriesFilter`, off by default so logs are never emptied by it), and
  the merge-input skip that stops a compaction's inputs being read twice. The
  replay probes forward past a lagging durable `_HEAD`, steps over tombstones,
  and walks over reaped gaps below the head. `TelemetryScanPlan.object_keys()` is
  the handoff to DuckDB, pyarrow or Polars; the plan also carries counters
  (`entries_replayed`, `pruned_by_time`, `pruned_by_series`, `skipped_absorbed`)
  so "nothing matched" and "nothing was read" are different observations.
- `segment_read`: `read_telemetry_segments` GETs exactly the planned keys,
  prunes row groups against the footer's min/max with the closed time range, and
  decodes the rest to `RecordBatch`es. A corrupt object raises. The batches are
  not time-filtered at row level; `TelemetryReadStats` reports objects fetched
  and row groups total, pruned and decoded.
- `log_search`: `TelemetryLogSearch` is a `komira_log_query` `ServiceLogSearch`
  over the logs dataset: plan, read, a row-level window filter, substring term
  matching on `message`, newest first, truncated to the query's limit.

The key layout, the UTC day arithmetic and the catalog entry are defined once,
in `komira_telemetry_store`, and re-exported from this package's `__init__`. The
store is a trait parameter (`CloneableConditionalWriteStore`). Keys are read
under the writers' default root, `TELEMETRY_ROOT`.
