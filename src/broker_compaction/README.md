# broker_compaction

The compaction adapter over `broker`. The broker core stores everything
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
  sub-lineage model (the folded `_base` plus the serve-merged tail). Import
  `SubLineageDualTierConsumer` and `decode_compacted_parquet_bytes` from
  `broker_compaction.dual_tier_consume`.
- `ProductionLogCleaner` is the log cleaner for `cleanup.policy=compact`
  partitions: it decodes cleanable `.seg` objects, keeps the latest record per
  key with a tombstone grace measured against `now_ms`, re-encodes the survivors as a new
  `.seg` at the original offsets, swaps the manifest chunk body by
  compare-and-swap, and schedules the orphaned original `.seg` for deletion
  after a grace period (`CompactionReapWorker`). A chunk with no survivors
  becomes an empty-segment marker, so a second round does not rewrite it.
- `run_maintenance_pass` is the run-once maintenance entry point for a
  scheduler: it enumerates the cluster's topics and dispatches retention, the
  log cleaner or both by `cleanup.policy`, and the auto-merge scan.
  `run_sublineage_maintenance_pass` (import it from
  `broker_compaction.maintenance`) additionally folds sub-lineage tails into
  `_base` and runs the contiguity-audited retention. Neither loops, sleeps or
  reads a clock; the caller passes `now_ms`, and a topic whose maintenance
  raises is recorded in the summary's `errors` and skipped.

The store is a type parameter on every driver (a `ConditionalWriteStore` or
`CloneableConditionalWriteStore`), so the same code runs over the in-memory
store in tests and an object-store client in a deployment.

## Examples

Both examples run as tests when the package is built, so they cannot go stale. They use the in-memory conditional store, so no object store is needed.

### Transcoding live segments to Parquet

Each live segment is an Arrow-IPC stream followed by a footer. `decode_segment_stream` reads one stream, `assert_uniform_schema` checks that a set of batches share a schema, and `transcode_segments_to_parquet` writes the streams as one Parquet object in order. `decode_compacted_parquet_bytes` reads that object back.

```mojo
from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch
from arrow.schema import Schema
from broker.broker_core import SegmentFooter, encode_segment
from broker_compaction.dual_tier_consume import decode_compacted_parquet_bytes
from broker_compaction.transcode import (
    assert_uniform_schema,
    decode_segment_stream,
    transcode_segments_to_parquet,
)
from containers.slab import Slab
from std.testing import assert_equal, assert_true

var streams = Slab[List[UInt8]]()
var decoded = Slab[RecordBatch]()
for s in range(3):
    var values: List[Int64] = [
        Int64(s * 4), Int64(s * 4 + 1), Int64(s * 4 + 2), Int64(s * 4 + 3)
    ]
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var col = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(values)
    )
    var batches = Slab[RecordBatch]()
    batches.append(RecordBatch.from_typed_columns_1(schema^, col^))
    var seg = encode_segment(batches^, Int64(s * 4))
    # Drop the footer: the stream is what the transcoder reads.
    var footer = SegmentFooter.decode(seg)
    var stream = List[UInt8]()
    for i in range(footer.arrow_stream_len(len(seg))):
        stream.append(seg[i])
    decoded.append(decode_segment_stream(stream.copy()))
    streams.append(stream^)

assert_uniform_schema(decoded)  # raises if the schemas diverge
var parquet_bytes = transcode_segments_to_parquet(streams^)
assert_true(len(parquet_bytes) > 8)

var rb = decode_compacted_parquet_bytes(parquet_bytes^)
assert_equal(rb.num_rows(), 12)
assert_equal(rb.num_columns(), 1)
var vals = rb.column_at(0).as_primitive[DType.int64]()
for i in range(12):
    assert_equal(vals.get(i), Int64(i))
```

### A compaction round and a dual-tier read

This example produces five live segments, runs one `CompactionWorker` round that folds them into one Parquet object, and reads the whole range back with `DualTierConsumer`. The result is one batch served from the compacted tier, with the same values the live segments held. The superseded live chunks are tombstoned only after the compacted object and its index entry are written.

```mojo
from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch
from arrow.schema import Schema
from broker.broker_core import BrokerCore
from broker.compacted_index import CompactionIndex
from broker.consume_core import ConsumeCore
from broker_compaction.compaction_worker import (
    CompactionRoundResult,
    CompactionWorker,
)
from broker_compaction.dual_tier_consume import DualTierConsumer
from objectstore.cas_manifest import CasManifestStore, RetryPolicy
from objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from std.testing import assert_equal, assert_true

var store = SharedInMemoryConditionalStore()
var cluster = String("demo")
var topic = String("t")
var pid = Int64(0)
var prefix = cluster + "/_meta/topics/" + topic + "/" + String(pid)

# Five live segments of ten rows each; each row's value is its offset.
var broker = BrokerCore[SharedInMemoryConditionalStore](
    segment_store=store.clone(),
    manifest=CasManifestStore[SharedInMemoryConditionalStore](
        store=store.clone(), prefix=String(prefix), retry=RetryPolicy.fast_test()
    ),
    cluster=cluster,
    topic=topic,
    partition=pid,
    broker_id=String("broker-A"),
)
for s in range(5):
    var values = List[Int64]()
    for r in range(10):
        values.append(Int64(s * 10 + r))
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var col = Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(values)
    )
    var rb = RecordBatch.from_typed_columns_1(schema^, col^)
    var ts = Int64(1000) + Int64(s) * Int64(1000)
    _ = broker.produce(rb^, ts)
    _ = broker.flush_if_buffered(ts)

var worker = CompactionWorker[SharedInMemoryConditionalStore](
    consume=ConsumeCore[SharedInMemoryConditionalStore](
        segment_store=store.clone(),
        manifest=CasManifestStore[SharedInMemoryConditionalStore](
            store=store.clone(), prefix=String(prefix), retry=RetryPolicy.fast_test()
        ),
        cluster=cluster,
        topic=topic,
        partition=pid,
    ),
    index=CompactionIndex[SharedInMemoryConditionalStore].build(
        store.clone(), String(prefix), RetryPolicy.fast_test()
    ),
    segment_store=store.clone(),
    live_manifest=CasManifestStore[SharedInMemoryConditionalStore](
        store=store.clone(), prefix=String(prefix), retry=RetryPolicy.fast_test()
    ),
    cluster=cluster,
    topic=topic,
    partition=pid,
)
var res: CompactionRoundResult = worker.run_once(
    now_ms=Int64(100000), min_segments=Int64(2), max_segments=Int64(64)
)
assert_true(res.compacted)
assert_equal(res.base_offset, Int64(0))
assert_equal(res.last_offset, Int64(49))
assert_equal(res.record_count, Int64(50))
assert_equal(res.segments_compacted, Int64(5))
assert_equal(res.tombstoned_count, Int64(5))

var dual = DualTierConsumer[SharedInMemoryConditionalStore](
    consume=ConsumeCore[SharedInMemoryConditionalStore](
        segment_store=store.clone(),
        manifest=CasManifestStore[SharedInMemoryConditionalStore](
            store=store.clone(), prefix=String(prefix), retry=RetryPolicy.fast_test()
        ),
        cluster=cluster,
        topic=topic,
        partition=pid,
    ),
    index=CompactionIndex[SharedInMemoryConditionalStore].build(
        store.clone(), String(prefix), RetryPolicy.fast_test()
    ),
    object_store=store.clone(),
)
var batches = dual.read_from(Int64(0))
assert_equal(len(batches), 1)
assert_true(batches[0].is_compacted)
assert_equal(batches[0].base_offset, Int64(0))
assert_equal(batches[0].last_offset, Int64(49))
assert_equal(batches[0].batch.num_rows(), 50)
var cvals = batches[0].batch.column_at(0).as_primitive[DType.int64]()
for r in range(50):
    assert_equal(cvals.get(r), Int64(r))
```
