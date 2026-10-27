# komira_kafka_broker

The broker half of the Kafka server. `komira_kafka_server` holds the Kafka wire codec: bytes in, values out, no dependencies. This package is the layer above it that a broker needs to act on those values: decompressing what producers send, compressing what a fetch returns, keeping the committed offsets of consumer groups, and turning Kafka records into Arrow batches.

## Modules

| module | holds |
| --- | --- |
| `kafka_compression` | `decompress_kafka_records` (a records blob by codec id), `decode_record_batches_decompressing` (a message set to a flat record list), `decode_producer_batches_decompressing` (a message set to one `DecodedProducerBatch` per batch, with its producer id, epoch, sequence range and transactional bit) |
| `kafka_fetch_compress` | `compress_kafka_records` (the inverse), `fetch_compression_codec_name` |
| `group_offsets` | `GroupOffsetStore`, committed offsets as objects in a `komira_objectstore` conditional-write store |
| `group_coordinator` | `GroupCoordinator`, the JoinGroup / SyncGroup / Heartbeat / LeaveGroup state machine over a conditional-write store; `JoinResult` |
| `group_state` | `GroupState`, `GroupMember`, the `GROUP_STATE_*` names, `encode_group_state_json`, `decode_group_state_json` |
| `group_membership` | `reconcile_members` (which members a closing round carries), `assignment_is_valid` (whether a leader's SyncGroup may complete the round) |
| `group_assignor` | `range_assign`, `pick_protocol_name` |
| `group_clock` | `GroupClock`, `SystemGroupClock`, `ManualGroupClock` |
| `envelope_bridge` | `kafka_records_to_envelope`, `envelope_to_kafka_records`, `envelope_schema` |

## Compression

A v2 RecordBatch names its codec in bits 0-2 of its attributes: 0 none, 1 gzip, 2 snappy, 3 lz4, 4 zstd. Everything after the batch header is one compressed blob. The framing is Kafka's: gzip is RFC 1952, snappy is the xerial framing (a bare raw block is also accepted on the way in), lz4 is the LZ4 frame format, zstd is a zstd frame. A blob that does not decode, or that ends early, is refused with an error that names the codec; an unknown codec id is refused with the id. Output is capped at 256 MiB, so a hostile blob cannot make the broker allocate without bound.

```mojo
from std.testing import assert_equal
from komira_kafka_broker import (
    KAFKA_COMPRESSION_GZIP,
    KAFKA_COMPRESSION_LZ4,
    KAFKA_COMPRESSION_NONE,
    KAFKA_COMPRESSION_SNAPPY,
    KAFKA_COMPRESSION_ZSTD,
    FETCH_COMPRESSION_GZIP,
    FETCH_COMPRESSION_LZ4,
    FETCH_COMPRESSION_NONE,
    FETCH_COMPRESSION_SNAPPY,
    FETCH_COMPRESSION_ZSTD,
    compress_kafka_records,
    decompress_kafka_records,
    fetch_compression_codec_name,
)

var records_blob = List[UInt8]("some record bytes, some record bytes".as_bytes())
assert_equal(KAFKA_COMPRESSION_NONE, FETCH_COMPRESSION_NONE)
assert_equal(KAFKA_COMPRESSION_GZIP, FETCH_COMPRESSION_GZIP)
assert_equal(KAFKA_COMPRESSION_SNAPPY, FETCH_COMPRESSION_SNAPPY)
assert_equal(KAFKA_COMPRESSION_LZ4, FETCH_COMPRESSION_LZ4)
assert_equal(KAFKA_COMPRESSION_ZSTD, FETCH_COMPRESSION_ZSTD)

for codec in range(1, 5):
    var packed = compress_kafka_records(codec, Span(records_blob))
    var unpacked = decompress_kafka_records(codec, Span(packed))
    assert_equal(len(unpacked), len(records_blob))
    assert_equal(String(fetch_compression_codec_name(codec)) != "unknown", True)

var refused = False
try:
    _ = decompress_kafka_records(9, Span(records_blob))
except e:
    refused = String(e).find("unsupported codec id 9") >= 0
assert_equal(refused, True)
```

A whole message set decodes in one call. The producer's batches come back flat, or grouped per batch when the idempotent path needs each batch's producer identity.

```mojo
from std.testing import assert_equal
from komira_kafka_broker import (
    FETCH_COMPRESSION_ZSTD,
    compress_kafka_records,
    decode_producer_batches_decompressing,
    decode_record_batches_decompressing,
)
from komira_kafka_server.wire.record_batch_v2 import (
    KafkaRecord,
    encode_record_array_plaintext,
    encode_record_batch_v2_compressed,
)

var records = List[KafkaRecord]()
for i in range(3):
    records.append(
        KafkaRecord(
            Optional(List[UInt8]("key".as_bytes())),
            Optional(List[UInt8]("value".as_bytes())),
            [],
            Int64(1000 + i),
            Int64(i),
        )
    )

var plain = encode_record_array_plaintext(records, Int64(0))
var blob = compress_kafka_records(FETCH_COMPRESSION_ZSTD, Span(plain))
var batch = encode_record_batch_v2_compressed(
    Span(blob), 3, Int64(1000), Int64(1002), Int64(0), Int32(2), FETCH_COMPRESSION_ZSTD
)

var flat = decode_record_batches_decompressing(Span(batch))
assert_equal(len(flat), 3)
assert_equal(flat[2].offset, Int64(2))

var grouped = decode_producer_batches_decompressing(Span(batch))
assert_equal(len(grouped), 1)
assert_equal(grouped[0].producer_id, Int64(-1))  # a producer without idempotence
assert_equal(len(grouped[0].records), 3)
```

## Consumer-group offsets

`GroupOffsetStore` keeps one object per (group, topic, partition) at `<cluster>/_meta/groups/<group>/offsets/<topic>/<partition>.json`, in any `CloneableConditionalWriteStore`. A commit is an unconditional put: the last write wins, and the store does not order commits, so a stale committer (a member that lost its partition in a rebalance) overwrites a newer offset unless the caller checks the member generation first. `%` and `/` of a group id are percent-encoded in the key. An empty topic or a negative partition is refused at commit. `fetch` answers `None` for an offset that was never committed (a store error that is not "not found" is raised, not read as `None`; a store error counts as "not found" only when the marker is at the start of the message, so a group id or topic that spells a marker cannot turn a 403 into `None`). The offset body is JSON written by `encode_offset_json`; a body written by another writer is returned as stored, and invalid UTF-8 in its metadata is not rejected. An id with `/` or `%` is keyed differently from one written before they were encoded, so such offsets are not found under the new key. `fetch_all_for_group` lists a group's offsets, following the store's sub-directory prefixes, so it works on a store that answers a listing the way S3 does.

```mojo
from std.testing import assert_equal
from komira_kafka_broker import (
    CommittedOffset,
    GroupOffsetStore,
    decode_offset_json,
    encode_offset_json,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

var offsets = GroupOffsetStore(SharedInMemoryConditionalStore(), String("cluster-1"))
offsets.commit(String("g"), String("orders"), Int32(0), CommittedOffset(Int64(42), String("m"), Int64(1)))
offsets.commit(String("g"), String("orders"), Int32(1), CommittedOffset(Int64(7), String(""), Int64(2)))

var got = offsets.fetch(String("g"), String("orders"), Int32(0))
assert_equal(got.value().offset, Int64(42))
assert_equal(Bool(offsets.fetch(String("g"), String("orders"), Int32(9))), False)

var all = offsets.fetch_all_for_group(String("g"))
assert_equal(len(all), 2)
assert_equal(all[0].topic, "orders")

var body = encode_offset_json(CommittedOffset(Int64(5), String("x"), Int64(3)))
assert_equal(decode_offset_json(body).offset, Int64(5))
```

## Consumer-group coordinator

`GroupCoordinator` runs the consumer-group rebalance for `subscribe()` consumers with no process holding the group. A group is one object, `<cluster>/_meta/groups/<group>/state.json` (`GroupState`: generation, leader, protocol, state, rebalance deadline, session timeout, the instant the round opened, and the members with their subscription and assignment blobs). Every change is a compare-and-swap on that object (`If-None-Match` for the first writer, `If-Match` after), and a lost swap re-reads and decides again, so two coordinators over one store serialize.

The states are `Empty`, `PreparingRebalance`, `CompletingRebalance` and `Stable`. A `join_group` that finds the group `Stable` or `Empty` opens a round: generation plus one, a deadline of the clock's now plus `rebalance_timeout_ms`, and `round_opened_ms` stamped. A join that finds a round open (`Preparing` or `Completing`) joins it at its generation, and drops a `Completing` round back to `Preparing`, so members joining at different coordinators converge on one generation. It then polls the stored state and waits on the clock between polls (`JOIN_POLL_INTERVAL_MS`) until every member has rejoined at the generation or the deadline has passed.

When the window closes, `reconcile_members` fixes the member set. A member at the current generation stays. A member at an older generation is carried into the new one only if its session is alive (`now - last_active_ms < session_timeout_ms`) and it was active within `GHOST_STALE_GRACE_MS` of the instant the round opened; otherwise it is dropped, so a stale id left by a consumer that reconnected under a new member id cannot widen the leader's split. The leader is the smallest member id at the generation and is stored once per generation, so every member's response names the same leader. The leader's response lists the members and their subscriptions; a follower's list is empty.

`sync_group` from the leader checks the assignment with `assignment_is_valid` before it stores it and moves the group to `Stable`. The leader is told to rejoin (`REBALANCE_IN_PROGRESS`) if the round was reopened, a member at the generation is not in the assignment, a partition goes to a member not at the generation, a partition is assigned twice, or the assigned partitions are not the contiguous range `0..max`. A follower polls until `Stable` and reads back its own blob. `heartbeat` answers `NONE` for a `Stable` group at the member's generation, `REBALANCE_IN_PROGRESS` otherwise, `UNKNOWN_MEMBER_ID` for a member not in the group, and refreshes the member's `last_active_ms` with a best-effort swap; `leave_group` removes the member, bumps the generation and returns the group to `Preparing`, or to `Empty` when it was the last member. `range_assign` is Kafka's range assignor.

Every timestamp and every wait goes through the coordinator's `GroupClock`. `SystemGroupClock` reads the Unix wall clock and sleeps; `ManualGroupClock` moves only through `set`, `advance` and `sleep_ms` (which moves it by the wait), so a session timeout fires when the test moves the clock past it and a deadline wait ends without a real wait.

```mojo
from std.testing import assert_equal
from komira_kafka_broker import (
    GroupCoordinator,
    GROUP_STATE_COMPLETING,
    GROUP_STATE_EMPTY,
    GROUP_STATE_STABLE,
    ManualGroupClock,
    range_assign,
)
from komira_kafka_server.wire import KafkaEncoder
from komira_kafka_server.wire.consumer_group import (
    CONSUMER_PROTOCOL_VERSION,
    decode_consumer_assignment,
    encode_consumer_assignment,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

var coordinator = GroupCoordinator[SharedInMemoryConditionalStore, ManualGroupClock](
    SharedInMemoryConditionalStore(), String("cluster-1"), ManualGroupClock(Int64(1000))
)

var enc = KafkaEncoder()
enc.put_int16(CONSUMER_PROTOCOL_VERSION)
enc.put_array_len(1)
enc.put_string(String("orders"))
enc.put_int32(Int32(-1))
var subscription = enc.take_bytes()

var protocols = List[String]()
protocols.append(String("range"))
var joined = coordinator.join_group(
    String("g"), String(""), String("client"), protocols, subscription, Int32(0)
)
assert_equal(joined.generation_id, Int32(1))
assert_equal(joined.leader_id, joined.member_id)
assert_equal(len(joined.members), 1)
assert_equal(coordinator.load_state(String("g")).value().state, String(GROUP_STATE_COMPLETING))

var members = List[String]()
members.append(joined.member_id.copy())
var split = range_assign(members, String("orders"), 4)
var ids = List[String]()
ids.append(joined.member_id.copy())
var blobs = List[List[UInt8]]()
blobs.append(encode_consumer_assignment(split))
var synced = coordinator.sync_group(String("g"), joined.member_id.copy(), joined.generation_id, ids, blobs)
assert_equal(synced[1], Int16(0))
assert_equal(len(decode_consumer_assignment(synced[0])[0].partitions), 4)
assert_equal(coordinator.load_state(String("g")).value().state, String(GROUP_STATE_STABLE))
assert_equal(coordinator.heartbeat(String("g"), joined.member_id.copy(), Int32(1)), Int16(0))

assert_equal(coordinator.leave_group(String("g"), joined.member_id.copy()), Int16(0))
assert_equal(coordinator.load_state(String("g")).value().state, String(GROUP_STATE_EMPTY))
```

## The envelope

`kafka_records_to_envelope` makes an Arrow `RecordBatch` of five columns: `__key` and `__value` (binary, nullable), `__timestamp` and `__offset` (int64) and `__headers` (binary, nullable: the serialized header block; a record without headers has the block of count 0, and a null or empty cell reads as no headers). Null and empty are kept apart in both directions. `envelope_to_kafka_records` numbers the records it returns `base_offset`, `base_offset + 1`, ..., whatever the batch's own `__offset` column holds.

```mojo
from std.testing import assert_equal
from komira_kafka_broker import (
    ENVELOPE_KEY,
    envelope_schema,
    envelope_to_kafka_records,
    kafka_records_to_envelope,
)
from komira_kafka_server.wire.record_batch_v2 import KafkaHeader, KafkaRecord

var headers = List[KafkaHeader]()
headers.append(KafkaHeader(List[UInt8]("trace".as_bytes()), Optional(List[UInt8]("abc".as_bytes()))))
var records = List[KafkaRecord]()
records.append(KafkaRecord(Optional[List[UInt8]](), Optional(List[UInt8]("v".as_bytes())), headers^, Int64(1000), Int64(0)))

var batch = kafka_records_to_envelope(records)
assert_equal(batch.num_rows(), 1)
assert_equal(envelope_schema().field_name(0), ENVELOPE_KEY)

var back = envelope_to_kafka_records(batch, Int64(500))
assert_equal(Bool(back[0].key), False)  # a null key stays null
assert_equal(back[0].offset, Int64(500))
assert_equal(len(back[0].headers), 1)
```

## Tests

`tests/` holds the package's tests; every one is listed in `test_srcs` in the package `BUCK` file, so the library is not produced unless all of them pass.
