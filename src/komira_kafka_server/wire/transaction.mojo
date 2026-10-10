# =============================================================================
# src/komira_kafka_server/wire/transaction.mojo — Kafka transactional RPCs
# =============================================================================
#
# Transactions. The wire codecs for the four transactional RPCs a
# kafka-python transactional producer drives (KIP-98):
#
#   AddPartitionsToTxn (api_key 24) — register the partitions a txn will write.
#   AddOffsetsToTxn    (api_key 25) — register the consumer-group offsets a txn
#                                     will commit (read-process-write).
#   TxnOffsetCommit    (api_key 28) — commit consumer offsets inside the txn.
#   EndTxn             (api_key 26) — commit OR abort the txn.
#
# (InitProducerId v0..v5 — the transactional-id binding — lives in
# init_producer_id.mojo; every version carries `transactional_id`, which is all
# the rebind needs. kafka-python 2.3.2 caps InitProducerId at v1.)
#
# Wire format pinned against the INSTALLED kafka-python 2.3.2 schemas (the
# authoritative source for what that client sends). We advertise the v0 of
# each (v0 is NON-flexible — no tagged fields), so the client negotiates down to
# v0. Layouts (all non-flexible, NULLABLE only where the schema says):
#
#   AddPartitionsToTxnRequest_v0:
#     transactional_id STRING, producer_id INT64, producer_epoch INT16,
#     topics ARRAY{ topic STRING, partitions ARRAY<INT32> }
#   AddPartitionsToTxnResponse_v0:
#     throttle_time_ms INT32,
#     results ARRAY{ topic STRING, partitions ARRAY{ partition INT32, error_code INT16 } }
#
#   AddOffsetsToTxnRequest_v0:
#     transactional_id STRING, producer_id INT64, producer_epoch INT16, group_id STRING
#   AddOffsetsToTxnResponse_v0: throttle_time_ms INT32, error_code INT16
#
#   EndTxnRequest_v0:
#     transactional_id STRING, producer_id INT64, producer_epoch INT16, committed BOOLEAN
#   EndTxnResponse_v0: throttle_time_ms INT32, error_code INT16
#
#   TxnOffsetCommitRequest_v0:
#     transactional_id STRING, group_id STRING, producer_id INT64,
#     producer_epoch INT16,
#     topics ARRAY{ topic STRING, partitions ARRAY{ partition INT32, offset INT64,
#                                                    metadata NULLABLE_STRING } }
#   (CommittedMetadata is "nullableVersions": "0+" in TxnOffsetCommitRequest.json;
#   v1 is the same as v0, so these bytes also decode a v1 body.)
#   TxnOffsetCommitResponse_v0:
#     throttle_time_ms INT32,
#     topics ARRAY{ topic STRING, partitions ARRAY{ partition INT32, error_code INT16 } }
#
# Encapsulation: ZERO UnsafePointer in any signature — a pure wire edge like the
# rest of komira_kafka_server.wire (Span in / owned List[UInt8] out). The decoded structs
# are POD-ish (Int64s + owned String/List); transient stack values (no pointer
# field).
# =============================================================================

from komira_kafka_server.wire.wire import KafkaEncoder, KafkaDecoder
from komira_kafka_server.wire.messages import encode_response_header_v0


comptime API_KEY_ADD_PARTITIONS_TO_TXN: Int16 = 24
comptime API_KEY_ADD_OFFSETS_TO_TXN: Int16 = 25
comptime API_KEY_END_TXN: Int16 = 26
comptime API_KEY_TXN_OFFSET_COMMIT: Int16 = 28

# Canonical Kafka error codes used by the transactional path.
comptime ERROR_NONE: Int16 = 0
comptime ERROR_INVALID_TXN_STATE: Int16 = 48  # INVALID_TXN_STATE
comptime ERROR_INVALID_PRODUCER_ID_MAPPING: Int16 = 49
comptime ERROR_TRANSACTIONAL_ID_AUTHORIZATION_FAILED: Int16 = 53


# =============================================================================
# §1 — AddPartitionsToTxn (api_key 24)
# =============================================================================


@fieldwise_init
struct TxnTopicPartitions(Copyable, Movable, Deinitable):
    """One topic + its partition indices in an AddPartitionsToTxn request."""

    var topic: String
    var partitions: List[Int32]


struct AddPartitionsToTxnRequest(Movable, Deinitable):
    """A decoded AddPartitionsToTxn request (v0)."""

    var transactional_id: String
    var producer_id: Int64
    var producer_epoch: Int16
    var topics: List[TxnTopicPartitions]

    def __init__(
        out self,
        var transactional_id: String,
        producer_id: Int64,
        producer_epoch: Int16,
        var topics: List[TxnTopicPartitions],
    ):
        self.transactional_id = transactional_id^
        self.producer_id = producer_id
        self.producer_epoch = producer_epoch
        self.topics = topics^


def decode_add_partitions_to_txn_request[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> AddPartitionsToTxnRequest:
    """Decode an AddPartitionsToTxn v0 request body (after the request header)."""
    var tid = dec.get_string()
    var pid = dec.get_int64()
    var epoch = dec.get_int16()
    var n_topics = dec.get_array_len()
    var topics = List[TxnTopicPartitions]()
    for _ in range(n_topics):
        var name = dec.get_string()
        var n_parts = dec.get_array_len()
        var parts = List[Int32]()
        for _ in range(n_parts):
            parts.append(dec.get_int32())
        topics.append(TxnTopicPartitions(name^, parts^))
    return AddPartitionsToTxnRequest(tid^, pid, epoch, topics^)


@fieldwise_init
struct AddPartitionsToTxnPartitionResult(
    Copyable, Movable, Deinitable
):
    var partition: Int32
    var error_code: Int16


@fieldwise_init
struct AddPartitionsToTxnTopicResult(Copyable, Movable, Deinitable):
    var topic: String
    var partitions: List[AddPartitionsToTxnPartitionResult]


def encode_add_partitions_to_txn_response(
    correlation_id: Int32,
    var results: List[AddPartitionsToTxnTopicResult],
) -> List[UInt8]:
    """Encode an AddPartitionsToTxn v0 response (response header v0 + body)."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    enc.put_int32(Int32(0))  # throttle_time_ms
    enc.put_array_len(len(results))
    for ti in range(len(results)):
        ref t = results[ti]
        enc.put_string(t.topic)
        enc.put_array_len(len(t.partitions))
        for pi in range(len(t.partitions)):
            ref p = t.partitions[pi]
            enc.put_int32(p.partition)
            enc.put_int16(p.error_code)
    return enc.take_bytes()


# =============================================================================
# §2 — AddOffsetsToTxn (api_key 25)
# =============================================================================


struct AddOffsetsToTxnRequest(Movable, Deinitable):
    """A decoded AddOffsetsToTxn request (v0)."""

    var transactional_id: String
    var producer_id: Int64
    var producer_epoch: Int16
    var group_id: String

    def __init__(
        out self,
        var transactional_id: String,
        producer_id: Int64,
        producer_epoch: Int16,
        var group_id: String,
    ):
        self.transactional_id = transactional_id^
        self.producer_id = producer_id
        self.producer_epoch = producer_epoch
        self.group_id = group_id^


def decode_add_offsets_to_txn_request[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> AddOffsetsToTxnRequest:
    """Decode an AddOffsetsToTxn v0 request body."""
    var tid = dec.get_string()
    var pid = dec.get_int64()
    var epoch = dec.get_int16()
    var group_id = dec.get_string()
    return AddOffsetsToTxnRequest(tid^, pid, epoch, group_id^)


def encode_add_offsets_to_txn_response(
    correlation_id: Int32, error_code: Int16
) -> List[UInt8]:
    """Encode an AddOffsetsToTxn v0 response (header v0 + throttle + error)."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    enc.put_int32(Int32(0))  # throttle_time_ms
    enc.put_int16(error_code)
    return enc.take_bytes()


# =============================================================================
# §3 — EndTxn (api_key 26)
# =============================================================================


struct EndTxnRequest(Movable, Deinitable):
    """A decoded EndTxn request (v0). `committed` True = commit, False = abort."""

    var transactional_id: String
    var producer_id: Int64
    var producer_epoch: Int16
    var committed: Bool

    def __init__(
        out self,
        var transactional_id: String,
        producer_id: Int64,
        producer_epoch: Int16,
        committed: Bool,
    ):
        self.transactional_id = transactional_id^
        self.producer_id = producer_id
        self.producer_epoch = producer_epoch
        self.committed = committed


def decode_end_txn_request[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> EndTxnRequest:
    """Decode an EndTxn v0 request body."""
    var tid = dec.get_string()
    var pid = dec.get_int64()
    var epoch = dec.get_int16()
    var committed = dec.get_bool()
    return EndTxnRequest(tid^, pid, epoch, committed)


def encode_end_txn_response(
    correlation_id: Int32, error_code: Int16
) -> List[UInt8]:
    """Encode an EndTxn v0 response (header v0 + throttle + error)."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    enc.put_int32(Int32(0))  # throttle_time_ms
    enc.put_int16(error_code)
    return enc.take_bytes()


# =============================================================================
# §4 — TxnOffsetCommit (api_key 28)
# =============================================================================


@fieldwise_init
struct TxnOffsetCommitPartition(Copyable, Movable, Deinitable):
    var partition: Int32
    var offset: Int64
    var metadata: Optional[String]  # null when the client sent none


@fieldwise_init
struct TxnOffsetCommitTopic(Copyable, Movable, Deinitable):
    var topic: String
    var partitions: List[TxnOffsetCommitPartition]


struct TxnOffsetCommitRequest(Movable, Deinitable):
    """A decoded TxnOffsetCommit request (v0)."""

    var transactional_id: String
    var group_id: String
    var producer_id: Int64
    var producer_epoch: Int16
    var topics: List[TxnOffsetCommitTopic]

    def __init__(
        out self,
        var transactional_id: String,
        var group_id: String,
        producer_id: Int64,
        producer_epoch: Int16,
        var topics: List[TxnOffsetCommitTopic],
    ):
        self.transactional_id = transactional_id^
        self.group_id = group_id^
        self.producer_id = producer_id
        self.producer_epoch = producer_epoch
        self.topics = topics^


def decode_txn_offset_commit_request[
    origin: Origin[mut=False]
](mut dec: KafkaDecoder[origin]) raises -> TxnOffsetCommitRequest:
    """Decode a TxnOffsetCommit v0 request body."""
    var tid = dec.get_string()
    var group_id = dec.get_string()
    var pid = dec.get_int64()
    var epoch = dec.get_int16()
    var n_topics = dec.get_array_len()
    var topics = List[TxnOffsetCommitTopic]()
    for _ in range(n_topics):
        var name = dec.get_string()
        var n_parts = dec.get_array_len()
        var parts = List[TxnOffsetCommitPartition]()
        for _ in range(n_parts):
            var part = dec.get_int32()
            var offset = dec.get_int64()
            var metadata = dec.get_nullable_string()
            parts.append(TxnOffsetCommitPartition(part, offset, metadata^))
        topics.append(TxnOffsetCommitTopic(name^, parts^))
    return TxnOffsetCommitRequest(tid^, group_id^, pid, epoch, topics^)


@fieldwise_init
struct TxnOffsetCommitPartitionResult(
    Copyable, Movable, Deinitable
):
    var partition: Int32
    var error_code: Int16


@fieldwise_init
struct TxnOffsetCommitTopicResult(Copyable, Movable, Deinitable):
    var topic: String
    var partitions: List[TxnOffsetCommitPartitionResult]


def encode_txn_offset_commit_response(
    correlation_id: Int32,
    var topics: List[TxnOffsetCommitTopicResult],
) -> List[UInt8]:
    """Encode a TxnOffsetCommit v0 response (header v0 + body)."""
    var enc = KafkaEncoder()
    encode_response_header_v0(enc, correlation_id)
    enc.put_int32(Int32(0))  # throttle_time_ms
    enc.put_array_len(len(topics))
    for ti in range(len(topics)):
        ref t = topics[ti]
        enc.put_string(t.topic)
        enc.put_array_len(len(t.partitions))
        for pi in range(len(t.partitions)):
            ref p = t.partitions[pi]
            enc.put_int32(p.partition)
            enc.put_int16(p.error_code)
    return enc.take_bytes()
