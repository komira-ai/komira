# telemetry_read

The direct query path over the at-rest telemetry format of
`telemetry_store`: a time range in, object keys out, with no service in
the middle. Any Parquet engine can query the objects; what it cannot do alone is
turn a time range into the set of keys, because that needs the manifest replayed.

- `scan_plan`: `plan_telemetry_scan(store, dataset, t0_ns, t1_ns)` computes the
  UTC day partitions the range touches (arithmetic, no I/O), enumerates writer
  shards with one LIST per day plus two per shard, replays each shard's manifest by exact GETs, and
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
- `log_search`: `TelemetryLogSearch` is a `log_query` `ServiceLogSearch`
  over the logs dataset: plan, read, a row-level window filter, substring term
  matching on `message`, newest first, truncated to the query's limit.

The key layout, the UTC day arithmetic and the catalog entry are defined once,
in `telemetry_store`, and re-exported from this package's `__init__`. The
store is a trait parameter (`CloneableConditionalWriteStore`). Keys are read
under the writers' default root, `TELEMETRY_ROOT`.

## Examples

A plan turns a time range into object keys from the catalog entries alone: the
day partition prunes first, then each entry's time range, then (for metrics) an
optional series range. Here two segments are published by hand, one per day,
with the manifest entry the writers would append:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from objectstore.cas_manifest import CasManifestStore, RetryPolicy
from objectstore.path import Path
from objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from objectstore.sublineage_shard_keys import shard_manifest_prefix
from telemetry_read import (
    NS_PER_DAY,
    TELEMETRY_DATASET_LOGS,
    TELEMETRY_ROOT,
    TelemetrySeriesFilter,
    day_string_from_ns,
    encode_telemetry_segment_entry,
    make_raw_segment_entry,
    plan_telemetry_scan,
    telemetry_data_key,
    telemetry_partition_prefix,
)

var store = SharedInMemoryConditionalStore()
var hour = Int64(3_600_000_000_000)
var sep15 = Int64(1789430400_000_000_000)  # 2026-09-15T00:00:00Z
var keys = List[String]()
for i in range(2):
    var start = sep15 + Int64(i - 1) * NS_PER_DAY
    var day = day_string_from_ns(start)
    var uuid = Array[UInt8, 16](fill=UInt8(i + 1))
    var key = telemetry_data_key(
        String(TELEMETRY_ROOT),
        String(TELEMETRY_DATASET_LOGS),
        day,
        start // Int64(1_000_000),
        uuid,
    )
    _ = store.put(Path.parse(key), List[UInt8]())
    var entry = make_raw_segment_entry(
        key.copy(), start, start + hour, Int64(1), Int64(0), uuid
    )
    var lineage = shard_manifest_prefix(
        telemetry_partition_prefix(
            String(TELEMETRY_ROOT), String(TELEMETRY_DATASET_LOGS), day
        ),
        String("writer-a"),
    )
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store.clone(), lineage^, RetryPolicy.fast_test()
    )
    _ = manifest.append(encode_telemetry_segment_entry(entry), Int64(1))
    keys.append(key^)

# The 14th only: one partition is enumerated, and one entry replayed.
var one_day = plan_telemetry_scan(
    store, String(TELEMETRY_DATASET_LOGS), sep15 - NS_PER_DAY, sep15 - NS_PER_DAY + hour
)
var one_keys = one_day.object_keys()
assert_equal(len(one_keys), 1)
assert_equal(one_keys[0], keys[0])
assert_equal(len(one_day.days), 1)
assert_equal(one_day.entries_replayed, 1)
assert_equal(one_day.rows_selected(), Int64(1))

# Starting two hours into the 14th: both days are replayed, and the entry that
# ended an hour into the 14th is pruned by its own time range.
var entry_pruned = plan_telemetry_scan(
    store,
    String(TELEMETRY_DATASET_LOGS),
    sep15 - NS_PER_DAY + Int64(2) * hour,
    sep15 + hour,
)
assert_equal(len(entry_pruned.days), 2)
assert_equal(entry_pruned.entries_replayed, 2)
assert_equal(entry_pruned.pruned_by_time, 1)
var pruned_keys = entry_pruned.object_keys()
assert_equal(len(pruned_keys), 1)
assert_equal(pruned_keys[0], keys[1])

# A log entry carries series 0/0: the default filter is inert, an active one
# that does not reach 0 prunes it, and the counter says why.
var inert = plan_telemetry_scan(
    store, String(TELEMETRY_DATASET_LOGS), sep15, sep15 + hour
)
var inert_keys = inert.object_keys()
assert_equal(len(inert_keys), 1)
assert_equal(inert.pruned_by_series, 0)
var filtered = plan_telemetry_scan(
    store,
    String(TELEMETRY_DATASET_LOGS),
    sep15,
    sep15 + hour,
    TelemetrySeriesFilter.range(Int64(100), Int64(200)),
)
var filtered_keys = filtered.object_keys()
assert_equal(len(filtered_keys), 0)
assert_equal(filtered.pruned_by_series, 1)
```
