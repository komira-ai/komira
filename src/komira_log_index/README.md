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

- `flush_stage`: the safety primitives of the off-core stage.
  `InFlightBytesGate` is the memory cap on unpublished bytes (an atomic counter;
  a reservation over the cap is rejected, except that an over-sized reservation
  runs alone on an empty pool). `LogIndexFlushBuffer` flushes at a byte ceiling
  or a time ceiling, whichever comes first, so a low-volume stream still becomes
  searchable. `FlushRetryPolicy` bounds the publish retry by attempts and by a
  total time budget.
- `handoff`: `LogIndexHandoff`, a spinlock-guarded single-producer,
  single-consumer queue of transposed batches (`HandoffUnit`) from the drain
  core to the flush thread, bounded by depth and by the shared gate.
  `offer` never blocks: when the queue is full or the gate rejects, it returns
  False, counts the rejection, gives back any reservation it took and drops the
  batch, and the caller decides (count the drop, or stop draining so the ring's
  overflow policy throttles the producer). `offer_log_views` is the on-core
  transpose and offer.
- `consumer`: `LogIndexConsumer[Storage]`, the off-core driver. It buffers
  handed-off batches, and at a flush ceiling builds one split with `SearchSink`
  and publishes it: `store.put` of the split object first, then
  `SearchMetastore.publish` of its summary. A failed build or publish is
  counted in `PublishStats` and printed, and the reserved bytes are released
  either way. Split uuids are the worker discriminant byte, the install-time
  epoch and a sequence, so a restarted consumer does not overwrite an earlier
  one's objects. The retry stops starting backoffs once the policy budget is
  spent; a `put` or `publish` already in flight is not interrupted. A summary
  append that lands but raises can be appended again by the retry, leaving a
  duplicate summary for one object.
- `flush_thread`: `OffCoreFlushThread[Storage]`, the drive loop
  (`run_until_shutdown`) and shutdown protocol for the dedicated flush thread.
  It does not create the OS thread; the owner launches a thread whose body calls
  `run_until_shutdown`, and joins it before dropping the handoff and gate. On
  shutdown the loop drains the handoff once more and flushes the last partial
  segment; the owner quiesces the producer first. The handoff and gate methods
  take `mut self`, so how they are shared with a producer on another thread is
  part of that thread-launch design, not of this package.
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
