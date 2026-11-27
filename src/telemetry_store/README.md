# telemetry_store

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

## Examples

A key is computed, never listed: the UTC day is in it, its depth is a constant,
and the text sidecar's key is derived from the data key.

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from telemetry_store import (
    NS_PER_DAY,
    TELEMETRY_DATA_KEY_DEPTH,
    TELEMETRY_DATASET_LOGS,
    TELEMETRY_ROOT,
    day_string_from_ns,
    days_covering,
    telemetry_data_key,
    telemetry_key_depth,
    telemetry_partition_prefix,
    telemetry_text_sidecar_key,
)

var t0 = Int64(1790812800) * Int64(1_000_000_000)  # 2026-10-01T00:00:00Z
assert_equal(day_string_from_ns(t0 + NS_PER_DAY - Int64(1)), String("20261001"))
assert_equal(day_string_from_ns(t0 + NS_PER_DAY), String("20261002"))

var days = days_covering(t0 + NS_PER_DAY - Int64(1), t0 + NS_PER_DAY)
assert_equal(len(days), 2)
assert_equal(days[0], String("20261001"))
assert_equal(days[1], String("20261002"))

var key = telemetry_data_key(
    TELEMETRY_ROOT,
    TELEMETRY_DATASET_LOGS,
    days[0],
    Int64(1790812800123),
    Array[UInt8, 16](fill=UInt8(7)),
)
var uuid_hex_text = String("0707070707070707") + String("0707070707070707")
assert_equal(
    key,
    String("telemetry/logs/20261001/data/00000001790812800123-") + uuid_hex_text + String(".parquet"),
)
assert_equal(telemetry_key_depth(key), TELEMETRY_DATA_KEY_DEPTH)
assert_equal(
    telemetry_text_sidecar_key(key),
    String("telemetry/logs/20261001/text/00000001790812800123-") + uuid_hex_text + String(".textidx"),
)

var refused = False
try:
    _ = telemetry_partition_prefix(TELEMETRY_ROOT, String("logs/us"), days[0])
except:
    refused = True
assert_true(refused)
```

The manifest body carries the time range and, for metrics, the series range.
It round-trips through its binary envelope, and a truncated body is refused
instead of decoding to zeros:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from telemetry_store import (
    TELEMETRY_SEGMENT_ENTRY_VERSION,
    TELEMETRY_UUID_BYTES,
    decode_telemetry_segment_entry,
    encode_telemetry_segment_entry,
    make_metric_segment_entry,
    uuid_in_flat,
)

var uuid = Array[UInt8, 16](fill=UInt8(3))
var entry = make_metric_segment_entry(
    uuid.copy(),
    String("telemetry/metrics/20261001/data/x.parquet"),
    Int64(100),
    Int64(200),
    Int64(5),
    Int64(9),
    Int64(40),
    Int64(4096),
)
var body = encode_telemetry_segment_entry(entry)
var back = decode_telemetry_segment_entry(body)
assert_equal(Int(back.version), Int(TELEMETRY_SEGMENT_ENTRY_VERSION))
assert_equal(back.object_key, entry.object_key)
assert_equal(back.min_ts_ns, Int64(100))
assert_equal(back.max_ts_ns, Int64(200))
assert_equal(back.min_series_id, Int64(5))
assert_equal(back.max_series_id, Int64(9))
assert_equal(back.row_count, Int64(40))
assert_equal(back.byte_size, Int64(4096))
assert_false(back.is_merged())
assert_equal(back.num_merge_inputs(), 0)

# The prunes are closed at both ends.
assert_true(back.overlaps_time(Int64(200), Int64(300)))
assert_false(back.overlaps_time(Int64(201), Int64(300)))
assert_true(back.overlaps_series(Int64(9), Int64(20)))
assert_false(back.overlaps_series(Int64(10), Int64(20)))

var flat = List[UInt8]()
for i in range(TELEMETRY_UUID_BYTES):
    flat.append(uuid[i])
assert_true(uuid_in_flat(flat, uuid))

var truncated = List[UInt8]()
for i in range(len(body) - 1):
    truncated.append(body[i])
var refused = False
try:
    _ = decode_telemetry_segment_entry(truncated)
except:
    refused = True
assert_true(refused)
```
