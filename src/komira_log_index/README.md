# komira_log_index

The native log index. Log records are transposed to a typed columnar batch, an
L0 index is built over them, and L0 splits are read and searched. It sits on
`komira_log` (the plain `LogRecordView` seam) and `komira_search` (record
batches, the search sink and the split format), so `komira_log` itself carries
no search dependency.

- `transpose`: `log_index_schema` is the one frozen schema of the log index
  (`message`, `_source`, `timestamp`, `level`, `module`, `corr_id`, `flags`,
  `site_id`). It is the same for every drain worker and every split, and
  dynamic arguments fold into `_source` without changing it.
  `log_views_to_record_batch` builds the batch from a `List[LogRecordView]`;
  `corr_id`, `flags` and `site_id` are widened to Int64 because the search sink
  skips unsigned columns. `build_log_index_plan` returns the schema and batch
  together.
- `l0_index`: the cheap index. `L0PostingBuilder` keeps an unsorted term-hash to
  doc-ids map with the per-document term frequency; `L0SegmentBuilder` ingests
  batches and serializes an L0 split, a SPLIT_VERSION=1 container with an empty
  term dictionary and postings region, a doc store and fast-field region
  byte-identical to the optimized writer's, and the posting in the additive
  `l0_posting` footer slot. `L0PostingIndex` parses and probes that region and
  refuses a truncated or out-of-range one.
- `l0_read`: `search_l0_split(view, query)` answers a match query over one L0
  split. It probes the posting, ranks by summed term frequency (no BM25) and
  applies the filter, sort and aggregations through the same code as the
  optimized path, so a read over a mix of L0 and optimized splits merges
  without losing or duplicating documents. A reader routes on
  `SplitView.has_l0_posting()`.
- `l0_build_task`: `L0BuildTask[Storage]`, a small run-to-completion
  `SpawnableTask` that transposes a batch, builds the L0 split, writes the
  split object to the store and then publishes its summary with
  `SearchMetastore.publish`. A failure is returned in `L0BuildResult.failed`,
  never swallowed.
- `idle_index_hook`: the hook a per-core runtime fires in an idle window. It
  drains up to `DRAIN_CAP` records from that worker's log ring, builds an L0
  split and publishes it to the worker's own shard, with the same
  object-first, summary-second order. `install_native_index_idle_hook` installs
  it and returns an `InstalledIndexHook`, which the owner passes to
  `flush_all_pending_via_hook` (the final flush after the runtime joins its
  workers) and then to `drop_installed_hook`.

The store is a type parameter bounded by `komira_objectstore`'s
`ConditionalWriteStore` (`CloneableConditionalWriteStore` for the hook). No
cloud client is named here, and the package reads no environment variable:
every setting is an argument.

- `metric_transpose`: `metric_points_to_record_batch` lowers a
  `List[MetricPoint]` to the eleven-column `metrics` fact batch
  (`metrics_fact_schema`) that `komira_telemetry_store`'s metric writer
  publishes. `metric_series_id` derives the series id from the point's
  `(name_id, scope_id, attrset_id)`, which are also kept as their own columns.
  The value is two typed columns, selected by `MFLAG_VALUE_IS_DOUBLE`.
- `object_store_metric_sink`: `ObjectStoreMetricSink[Storage]`, the at-rest
  store for metrics. `offer_points` buffers a drain (bounded; overflow drops the
  oldest and is counted), `flush_pending_now` and `final_flush` publish through
  the telemetry store's metric writer, which writes the Parquet object first and
  appends its manifest entry second. An empty buffer touches the store zero
  times, and a failed publish keeps the points pending.
- `split_log_search`: `SplitIndexLogSearch[Storage]`, a `komira_log_query`
  `ServiceLogSearch` over L0 and optimized splits. It is built with the
  `(meta_root, index)` pair the writer used, lists the live splits across shards,
  searches each (routing on `has_l0_posting()`), merges newest first with the
  manifest publish sequence as the tie-break, and filters to the time window.
  It requires a search term: the split catalog carries no time range.

This package is split across three pull requests. The L0 index, build task and
idle hook (`transpose`, `l0_index`, `l0_read`, `l0_build_task`,
`idle_index_hook`) and the metric and split-search modules above are here; the
flush stage, handoff queue and consumer that feed the index are in their own
change.
