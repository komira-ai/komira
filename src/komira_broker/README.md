# komira_broker

The core of a message broker whose only storage is an object store. Every
structure (segments, the per-partition manifest, partition maps, assignments,
transaction markers) is an object written with conditional writes, so the
broker is generic over `komira_objectstore`'s `ConditionalWriteStore` and the
program that instantiates it picks the store (the in-memory stores in tests).

- Produce: `BrokerCore[Storage]` buffers Arrow record batches for one partition
  and flushes them at 8 MiB or 250 ms (`FLUSH_BYTES`, `FLUSH_MS`; the caller
  passes the clock). A flush PUTs one segment (an Arrow IPC stream plus a fixed
  footer) and then appends a manifest chunk, which assigns the contiguous offset
  range; the returned `ProduceResult` is the acknowledgement, and it exists only
  after both writes landed. `BrokerCoalescingProduce` batches concurrent
  produces; producer idempotence, transactions and lease fencing are on the same
  core.
- Consume: `ConsumeCore[Storage]` resolves the manifest into an offset index and
  reads the segments covering an offset (`read_from`, `read_from_checked`,
  `next_offset`, `log_start_offset`); `MessageBrokerConsumer` and
  read-committed filtering sit on top.
- Partitions: hash-range `PartitionMap`s with split, merge and their triggers,
  the persisted cluster assignment (`ClusterAssignmentStore`,
  `assign_partitions`) with per-partition lease generations.
- Cleanup: time and size retention (`RetentionPolicy`, `evaluate_retention`,
  `ReapWorker`) and key-based log compaction (`compact_records`, `LogCleaner`),
  selected by a Kafka-style `cleanup.policy`.
- A scan kind that reads a topic as a relation for the query engine.

It has no network server and no wire protocol: protocol front ends (a Kafka
wire server, for one) and the node coordinator are other packages built on this
core.

## Examples

Produce two batches into one partition over the in-memory store, then read the
partition back. Offsets come from the manifest, so the second flush starts where
the first ended:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_broker import BrokerCore, ConsumeCore
from komira_objectstore import CasManifestStore, RetryPolicy, SharedInMemoryConditionalStore

comptime Store = SharedInMemoryConditionalStore


def int64_batch(values: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("val", ArrowType.INT64, False))
    var rb = RecordBatchBuilder.with_capacity(1)
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(values)))
    return rb.build(sb.build())


var store = Store()
var prefix = "c1/_meta/topics/orders/0"
var broker = BrokerCore[Store](
    segment_store=store.clone(),
    manifest=CasManifestStore[Store](store.clone(), prefix, RetryPolicy.default()),
    cluster="c1",
    topic="orders",
    partition=0,
    broker_id="broker-1",
)

# Below the size and time triggers a produce only buffers: no acknowledgement yet.
var pending = broker.produce(int64_batch([1, 2, 3]), 1_000)
assert_false(pending)
var first_ack = broker.flush_if_buffered(1_000)
ref first = first_ack.value()
assert_equal(first.base_offset, 0)
assert_equal(first.last_offset, 2)

_ = broker.produce(int64_batch([4, 5]), 2_000)
var second_ack = broker.flush_if_buffered(2_000)
ref second = second_ack.value()
assert_equal(second.base_offset, 3)
assert_equal(second.last_offset, 4)
assert_false(broker.flush_if_buffered(3_000))  # nothing buffered, nothing written

var reader = ConsumeCore[Store](
    segment_store=store.clone(),
    manifest=CasManifestStore[Store](store.clone(), prefix, RetryPolicy.default()),
    cluster="c1",
    topic="orders",
    partition=0,
)
assert_equal(reader.next_offset(), 5)
var segments = reader.read_from(3)  # only the segment holding offset 3 onwards
assert_equal(len(segments), 1)
assert_equal(segments[0].base_offset, 3)
assert_equal(segments[0].record_count, 2)
assert_true(len(segments[0].stream_bytes) > 0)  # the Arrow IPC stream
```

Log compaction keeps the latest record of each key at its original offset. A
tombstone (a record with no value) is kept unless the tombstone retention is 0:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_broker import CLEANUP_POLICY_COMPACT_DELETE, CleanRecord, cleanup_policy_from_name, compact_records

var records = List[CleanRecord]()
records.append(CleanRecord(key="a", abs_offset=0, chunk_seq=0, is_tombstone=False))
records.append(CleanRecord(key="b", abs_offset=1, chunk_seq=0, is_tombstone=False))
records.append(CleanRecord(key="a", abs_offset=2, chunk_seq=1, is_tombstone=False))
records.append(CleanRecord(key="b", abs_offset=3, chunk_seq=1, is_tombstone=True))

var keep_tombstones = compact_records(records, -1, 0)
assert_equal(keep_tombstones.survivor_count, 2)
assert_equal(keep_tombstones.survivors[0].abs_offset, 2)  # latest "a"
assert_equal(keep_tombstones.survivors[1].abs_offset, 3)  # the tombstone for "b"

var drop_tombstones = compact_records(records, 0, 0)
assert_equal(drop_tombstones.survivor_count, 1)
assert_equal(drop_tombstones.survivors[0].key, "a")
assert_equal(drop_tombstones.dropped_count, 3)

assert_equal(cleanup_policy_from_name("compact,delete"), CLEANUP_POLICY_COMPACT_DELETE)
```
