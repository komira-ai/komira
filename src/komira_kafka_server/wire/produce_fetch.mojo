# =============================================================================
# src/komira_kafka_server/wire/produce_fetch.mojo — Produce / Fetch / ListOffsets codecs
# =============================================================================
#
# The DATA-path request/response message schemas on top of the wire
# primitives (wire.mojo) + the v2 RecordBatch codec (record_batch_v2.mojo).
# Pure bytes, no first-party deps.
#
# Versions (NON-flexible, RecordBatch-v2-carrying — chosen so a kafka-python
# `api_version=(2,0,0)` client negotiates a shape we fully encode/decode and we
# avoid the v9+/v12+ flexible/compact forms):
#   * Produce      v3..v7   (request header v1, transactional_id NULLABLE_STRING)
#   * Fetch        v4..v6   (request header v1)
#   * ListOffsets  v1..v2   (request header v1)
#
# The flexible (tagged-field) forms are not decoded here. Within each range
# we decode the request as its MAX version's shape (the extra fields the lower
# versions omit are all trailing per-partition response fields, which we always
# emit at the advertised max so the client parses them).
#
# Encapsulation: ZERO UnsafePointer in any signature. Decode borrows
# `Span[UInt8, origin]` via KafkaDecoder; encode appends to an owned List.
# =============================================================================

from komira_kafka_server.wire.messages import encode_response_header_v0
from komira_kafka_server.wire.wire import KafkaDecoder, KafkaEncoder


comptime ERROR_NONE_I16: Int16 = 0
# Kafka standard per-partition Fetch error: the requested offset is outside the
# readable range (below log_start after retention reaped the head, or above the
# high-watermark). A well-behaved client's auto.offset.reset triggers on this.
comptime ERROR_OFFSET_OUT_OF_RANGE: Int16 = 1
comptime ERROR_UNKNOWN_TOPIC_OR_PARTITION: Int16 = 3
# Kafka standard per-partition RETRIABLE Produce error: this node is not (or no
# longer effectively) the writer for this partition — the client should refresh
# metadata and RETRY (kafka-python retries this automatically). The broker emits
# it when a Produce cannot win the object-store CAS offset slot under genuine
# multi-writer contention before the manifest RetryPolicy budget is exhausted.
# It is the most semantically honest
# retriable code for "couldn't acquire the offset slot": the loser definitively
# did NOT write (the CAS arbitrates), so unlike REQUEST_TIMED_OUT (7) there is
# no partial-write / duplicate ambiguity — a clean "didn't happen, retry".
comptime ERROR_NOT_LEADER_OR_FOLLOWER: Int16 = 6
# Kafka standard RETRIABLE Produce error: the request's outcome is unknown (it
# may or may not have been written), so a retry can duplicate it.
comptime ERROR_REQUEST_TIMED_OUT: Int16 = 7
# Kafka standard: an unexpected server error (not retriable by itself).
comptime ERROR_UNKNOWN_SERVER_ERROR: Int16 = -1


# =============================================================================
# §1 — Produce request (v3..v7).
# =============================================================================
#
#   transactional_id  NULLABLE_STRING
#   acks              INT16
#   timeout_ms        INT32
#   topic_data        ARRAY of {
#       name          STRING
#       partition_data ARRAY of {
#           index     INT32
#           records   RECORDS   (INT32 byte length + the v2 message-set bytes)
#       }
#   }


struct ProducePartitionData(Copyable, Movable, Deinitable):
    """One (partition, message-set-bytes) pair in a Produce request."""

    var index: Int32
    var records: List[UInt8]  # the raw v2 RecordBatch message-set bytes

    def __init__(out self, index: Int32, var records: List[UInt8]):
        self.index = index
        self.records = records^

    def copy(self) -> Self:
        return Self(self.index, self.records.copy())


struct ProduceTopicData(Copyable, Movable, Deinitable):
    """One topic's partitions in a Produce request."""

    var name: String
    var partitions: List[ProducePartitionData]

    def __init__(
        out self, var name: String, var partitions: List[ProducePartitionData]
    ):
        self.name = name^
        self.partitions = partitions^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.partitions.copy())


struct ProduceRequest(Movable, Deinitable):
    """A decoded Produce request body (v3..v7)."""

    var transactional_id: Optional[String]
    var acks: Int16
    var timeout_ms: Int32
    var topics: List[ProduceTopicData]

    def __init__(
        out self,
        var transactional_id: Optional[String],
        acks: Int16,
        timeout_ms: Int32,
        var topics: List[ProduceTopicData],
    ):
        self.transactional_id = transactional_id^
        self.acks = acks
        self.timeout_ms = timeout_ms
        self.topics = topics^


def _read_records[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> List[UInt8]:
    """RECORDS: INT32 byte length (-1 == null) + that many bytes."""
    var n = Int(dec.get_int32())
    var out = List[UInt8]()
    if n <= 0:
        return out^
    for _ in range(n):
        out.append(dec.get_int8().cast[DType.uint8]())
    return out^


def decode_produce_request[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> ProduceRequest:
    """Decode a Produce request body (v3..v7), positioned just after the
    request header."""
    var txn_id = dec.get_nullable_string()
    var acks = dec.get_int16()
    var timeout = dec.get_int32()
    var n_topics = dec.get_array_len()
    var topics = List[ProduceTopicData]()
    for _ in range(n_topics):
        var name = dec.get_string()
        var n_parts = dec.get_array_len()
        var parts = List[ProducePartitionData]()
        for _ in range(n_parts):
            var idx = dec.get_int32()
            var records = _read_records(dec)
            parts.append(ProducePartitionData(idx, records^))
        topics.append(ProduceTopicData(name^, parts^))
    return ProduceRequest(txn_id^, acks, timeout, topics^)


# =============================================================================
# §2 — Produce response (v7).
# =============================================================================
#
#   responses  ARRAY of {
#       name        STRING
#       partitions  ARRAY of {
#           index            INT32
#           error_code       INT16
#           base_offset      INT64
#           log_append_time  INT64   (v2+)
#           log_start_offset INT64   (v5+)
#       }
#   }
#   throttle_time_ms  INT32   (v1+)


struct ProducePartitionResult(Copyable, Movable, Deinitable):
    """The per-partition ack in a Produce response."""

    var index: Int32
    var error_code: Int16
    var base_offset: Int64

    def __init__(out self, index: Int32, error_code: Int16, base_offset: Int64):
        self.index = index
        self.error_code = error_code
        self.base_offset = base_offset


struct ProduceTopicResult(Copyable, Movable, Deinitable):
    var name: String
    var partitions: List[ProducePartitionResult]

    def __init__(
        out self, var name: String, var partitions: List[ProducePartitionResult]
    ):
        self.name = name^
        self.partitions = partitions^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.partitions.copy())


def encode_produce_response_v7(
    correlation_id: Int32, topics: List[ProduceTopicResult]
) -> List[UInt8]:
    """Encode a Produce v7 response (response header v0 + body)."""
    return encode_produce_response(correlation_id, topics, Int16(7))


def encode_produce_response(
    correlation_id: Int32,
    topics: List[ProduceTopicResult],
    api_version: Int16,
) -> List[UInt8]:
    """Encode a Produce response matching the REQUEST's api_version (v3..v7).

    The per-partition body is `(index, error_code, base_offset, log_append_time)`
    at v3/v4, with `log_start_offset` ADDED at v5+. Emitting a v7-shaped body to
    a v3 client mis-aligns every partition past the first (the trailing
    log_start_offset shifts subsequent fields → garbage offsets), which breaks
    a multi-partition transactional produce. The client negotiates Produce
    down to its release (a transactional producer at api_version=(0,11) sends
    ProduceRequest_v3), so the response MUST match the request version."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    enc.put_array_len(len(topics))
    for ti in range(len(topics)):
        ref t = topics[ti]
        enc.put_string(t.name)
        enc.put_array_len(len(t.partitions))
        for pi in range(len(t.partitions)):
            ref p = t.partitions[pi]
            enc.put_int32(p.index)
            enc.put_int16(p.error_code)
            enc.put_int64(p.base_offset)
            enc.put_int64(Int64(-1))  # log_append_time (-1 == not set, v2+)
            if api_version >= 5:
                enc.put_int64(Int64(0))  # log_start_offset (v5+ ONLY)
    enc.put_int32(Int32(0))  # throttle_time_ms
    return enc.take_bytes()


# =============================================================================
# §3 — Fetch request (v4..v6).
# =============================================================================
#
#   replica_id        INT32
#   max_wait_ms       INT32
#   min_bytes         INT32
#   max_bytes         INT32   (v3+)
#   isolation_level   INT8    (v4+)
#   topics  ARRAY of {
#       name      STRING
#       partitions ARRAY of {
#           index            INT32
#           fetch_offset     INT64
#           log_start_offset INT64   (v5+)
#           partition_max_bytes INT32
#       }
#   }


struct FetchPartitionRequest(Copyable, Movable, Deinitable):
    var index: Int32
    var fetch_offset: Int64
    var max_bytes: Int32

    def __init__(out self, index: Int32, fetch_offset: Int64, max_bytes: Int32):
        self.index = index
        self.fetch_offset = fetch_offset
        self.max_bytes = max_bytes


struct FetchTopicRequest(Copyable, Movable, Deinitable):
    var name: String
    var partitions: List[FetchPartitionRequest]

    def __init__(
        out self, var name: String, var partitions: List[FetchPartitionRequest]
    ):
        self.name = name^
        self.partitions = partitions^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.partitions.copy())


# Kafka Fetch isolation levels (request INT8, v4+).
comptime ISOLATION_READ_UNCOMMITTED: Int8 = 0
comptime ISOLATION_READ_COMMITTED: Int8 = 1


struct FetchRequest(Movable, Deinitable):
    var max_wait_ms: Int32
    var min_bytes: Int32
    var topics: List[FetchTopicRequest]
    # The request isolation level (v4+): 0 = read_uncommitted (default,
    # sees txn-open data), 1 = read_committed (filters uncommitted/aborted txn
    # chunks via the pinned control-object snapshot).
    var isolation_level: Int8

    def __init__(
        out self,
        max_wait_ms: Int32,
        min_bytes: Int32,
        var topics: List[FetchTopicRequest],
        isolation_level: Int8 = ISOLATION_READ_UNCOMMITTED,
    ):
        self.max_wait_ms = max_wait_ms
        self.min_bytes = min_bytes
        self.topics = topics^
        self.isolation_level = isolation_level


def decode_fetch_request[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin], api_version: Int16) raises -> FetchRequest:
    """Decode a Fetch request body (v4..v6)."""
    _ = dec.get_int32()  # replica_id
    var max_wait = dec.get_int32()
    var min_bytes = dec.get_int32()
    _ = dec.get_int32()  # max_bytes (v3+)
    var isolation_level = dec.get_int8()  # isolation_level (v4+)
    var n_topics = dec.get_array_len()
    var topics = List[FetchTopicRequest]()
    for _ in range(n_topics):
        var name = dec.get_string()
        var n_parts = dec.get_array_len()
        var parts = List[FetchPartitionRequest]()
        for _ in range(n_parts):
            var idx = dec.get_int32()
            var fetch_offset = dec.get_int64()
            if api_version >= 5:
                _ = dec.get_int64()  # log_start_offset
            var part_max_bytes = dec.get_int32()
            parts.append(FetchPartitionRequest(idx, fetch_offset, part_max_bytes))
        topics.append(FetchTopicRequest(name^, parts^))
    return FetchRequest(max_wait, min_bytes, topics^, isolation_level)


# =============================================================================
# §4 — Fetch response (v6).
# =============================================================================
#
#   throttle_time_ms  INT32
#   responses ARRAY of {
#       name STRING
#       partitions ARRAY of {
#           index               INT32
#           error_code          INT16
#           high_watermark      INT64
#           last_stable_offset  INT64  (v4+)
#           log_start_offset    INT64  (v5+)
#           aborted_transactions ARRAY of { producer_id INT64, first_offset INT64 }  (v4+, nullable)
#           records             RECORDS
#       }
#   }


struct FetchPartitionResult(Copyable, Movable, Deinitable):
    var index: Int32
    var error_code: Int16
    var high_watermark: Int64
    var records: List[UInt8]  # the v2 RecordBatch message-set bytes (may be empty)

    def __init__(
        out self,
        index: Int32,
        error_code: Int16,
        high_watermark: Int64,
        var records: List[UInt8],
    ):
        self.index = index
        self.error_code = error_code
        self.high_watermark = high_watermark
        self.records = records^

    def copy(self) -> Self:
        return Self(
            self.index, self.error_code, self.high_watermark, self.records.copy()
        )


struct FetchTopicResult(Copyable, Movable, Deinitable):
    var name: String
    var partitions: List[FetchPartitionResult]

    def __init__(
        out self, var name: String, var partitions: List[FetchPartitionResult]
    ):
        self.name = name^
        self.partitions = partitions^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.partitions.copy())


def encode_fetch_response_v6(
    correlation_id: Int32, topics: List[FetchTopicResult]
) -> List[UInt8]:
    """Encode a Fetch v6 response (response header v0 + body)."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    enc.put_int32(Int32(0))  # throttle_time_ms
    enc.put_array_len(len(topics))
    for ti in range(len(topics)):
        ref t = topics[ti]
        enc.put_string(t.name)
        enc.put_array_len(len(t.partitions))
        for pi in range(len(t.partitions)):
            ref p = t.partitions[pi]
            enc.put_int32(p.index)
            enc.put_int16(p.error_code)
            enc.put_int64(p.high_watermark)
            enc.put_int64(p.high_watermark)  # last_stable_offset (v4+)
            enc.put_int64(Int64(0))  # log_start_offset (v5+)
            enc.put_array_len(0)  # aborted_transactions (v4+) — empty
            # records (RECORDS = INT32 length + bytes; length 0 if empty)
            enc.put_int32(Int32(len(p.records)))
            for i in range(len(p.records)):
                enc.put_int8(Int8(p.records[i].cast[DType.int8]()))
    return enc.take_bytes()


# =============================================================================
# §5 — ListOffsets request (v1..v2) + response (v2).
# =============================================================================
#
#   request:
#     replica_id       INT32
#     isolation_level  INT8   (v2+)
#     topics ARRAY of { name STRING, partitions ARRAY of {
#         index INT32, timestamp INT64 } }
#       (-2 == earliest, -1 == latest)
#   response (v1/v2):
#     throttle_time_ms INT32  (v2+)
#     topics ARRAY of { name STRING, partitions ARRAY of {
#         index INT32, error_code INT16, timestamp INT64, offset INT64 } }

comptime LIST_OFFSETS_EARLIEST: Int64 = -2
comptime LIST_OFFSETS_LATEST: Int64 = -1


struct ListOffsetsPartitionRequest(Copyable, Movable, Deinitable):
    var index: Int32
    var timestamp: Int64

    def __init__(out self, index: Int32, timestamp: Int64):
        self.index = index
        self.timestamp = timestamp


struct ListOffsetsTopicRequest(Copyable, Movable, Deinitable):
    var name: String
    var partitions: List[ListOffsetsPartitionRequest]

    def __init__(
        out self,
        var name: String,
        var partitions: List[ListOffsetsPartitionRequest],
    ):
        self.name = name^
        self.partitions = partitions^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.partitions.copy())


struct ListOffsetsRequest(Movable, Deinitable):
    var topics: List[ListOffsetsTopicRequest]

    def __init__(out self, var topics: List[ListOffsetsTopicRequest]):
        self.topics = topics^


def decode_list_offsets_request[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin], api_version: Int16) raises -> ListOffsetsRequest:
    """Decode a ListOffsets request body (v1..v2)."""
    _ = dec.get_int32()  # replica_id
    if api_version >= 2:
        _ = dec.get_int8()  # isolation_level
    var n_topics = dec.get_array_len()
    var topics = List[ListOffsetsTopicRequest]()
    for _ in range(n_topics):
        var name = dec.get_string()
        var n_parts = dec.get_array_len()
        var parts = List[ListOffsetsPartitionRequest]()
        for _ in range(n_parts):
            var idx = dec.get_int32()
            var ts = dec.get_int64()
            parts.append(ListOffsetsPartitionRequest(idx, ts))
        topics.append(ListOffsetsTopicRequest(name^, parts^))
    return ListOffsetsRequest(topics^)


struct ListOffsetsPartitionResult(Copyable, Movable, Deinitable):
    var index: Int32
    var error_code: Int16
    var timestamp: Int64
    var offset: Int64

    def __init__(
        out self,
        index: Int32,
        error_code: Int16,
        timestamp: Int64,
        offset: Int64,
    ):
        self.index = index
        self.error_code = error_code
        self.timestamp = timestamp
        self.offset = offset


struct ListOffsetsTopicResult(Copyable, Movable, Deinitable):
    var name: String
    var partitions: List[ListOffsetsPartitionResult]

    def __init__(
        out self,
        var name: String,
        var partitions: List[ListOffsetsPartitionResult],
    ):
        self.name = name^
        self.partitions = partitions^

    def copy(self) -> Self:
        return Self(self.name.copy(), self.partitions.copy())


def encode_list_offsets_response_v2(
    correlation_id: Int32, topics: List[ListOffsetsTopicResult]
) -> List[UInt8]:
    """Encode a ListOffsets v2 response (response header v0 + body)."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    enc.put_int32(Int32(0))  # throttle_time_ms
    enc.put_array_len(len(topics))
    for ti in range(len(topics)):
        ref t = topics[ti]
        enc.put_string(t.name)
        enc.put_array_len(len(t.partitions))
        for pi in range(len(t.partitions)):
            ref p = t.partitions[pi]
            enc.put_int32(p.index)
            enc.put_int16(p.error_code)
            enc.put_int64(p.timestamp)
            enc.put_int64(p.offset)
    return enc.take_bytes()
