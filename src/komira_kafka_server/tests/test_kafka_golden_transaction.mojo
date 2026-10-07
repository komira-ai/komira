# =============================================================================
# test_kafka_golden_transaction.mojo — AddPartitionsToTxn / AddOffsetsToTxn /
# EndTxn / TxnOffsetCommit against independent reference bytes
# =============================================================================
#
# Every reference message below is assembled by hand from the Apache Kafka
# message schemas (tag 3.9.0, clients/src/main/resources/common/message/):
# RequestHeader.json, ResponseHeader.json, AddPartitionsToTxnRequest.json,
# AddPartitionsToTxnResponse.json, AddOffsetsToTxnRequest.json,
# AddOffsetsToTxnResponse.json, EndTxnRequest.json, EndTxnResponse.json,
# TxnOffsetCommitRequest.json, TxnOffsetCommitResponse.json. Provenance and
# license: tests/GOLDENS.md.
#
# Requests: header v1 + body; decode, assert every field, check the message
# is consumed exactly and every strict prefix is refused. Responses: encode
# the reference's field values, assert byte equality.
#
# Versions: the codec (transaction.mojo) serves v0 of each, non-flexible
# (flexible at v3+ for all four).
#
# TxnOffsetCommit v0 CommittedMetadata is a NULLABLE string in the schema
# ("nullableVersions": "0+"); test_txn_offset_commit_request_v0_null_metadata
# checks that the decoder accepts the null form and reports it as null, and
# test_txn_offset_commit_request_v0 that "" stays a present empty string.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_kafka_server.wire.wire import KafkaDecoder
from komira_kafka_server.wire.messages import parse_request_header
from komira_kafka_server.wire.transaction import (
    API_KEY_ADD_PARTITIONS_TO_TXN,
    API_KEY_ADD_OFFSETS_TO_TXN,
    API_KEY_END_TXN,
    API_KEY_TXN_OFFSET_COMMIT,
    ERROR_INVALID_TXN_STATE,
    ERROR_INVALID_PRODUCER_ID_MAPPING,
    decode_add_partitions_to_txn_request,
    AddPartitionsToTxnPartitionResult,
    AddPartitionsToTxnTopicResult,
    encode_add_partitions_to_txn_response,
    decode_add_offsets_to_txn_request,
    encode_add_offsets_to_txn_response,
    decode_end_txn_request,
    encode_end_txn_response,
    decode_txn_offset_commit_request,
    TxnOffsetCommitPartitionResult,
    TxnOffsetCommitTopicResult,
    encode_txn_offset_commit_response,
)

# -----------------------------------------------------------------------------
# Golden plumbing (each welded test builds from its one file, so this block is
# repeated in every test_kafka_golden_*.mojo file).
# -----------------------------------------------------------------------------


def _nibble(c: UInt8) raises -> UInt8:
    if c >= 48 and c <= 57:  # '0'..'9'
        return c - 48
    if c >= 97 and c <= 102:  # 'a'..'f'
        return c - 87
    raise Error("golden: bad hex digit " + String(Int(c)))


struct _Golden(Movable):
    """Reference bytes written as hex, one schema field per `add` call."""

    var b: List[UInt8]

    def __init__(out self):
        self.b = List[UInt8]()

    def add(mut self, hex: String) raises:
        """Append the bytes spelled by `hex` (lower-case digits; spaces are
        ignored). An odd digit count is a typo in the golden: refuse it."""
        var s = hex.as_bytes()
        var digits = List[UInt8]()
        for i in range(len(s)):
            if s[i] != 32:
                digits.append(_nibble(s[i]))
        if len(digits) % 2 != 0:
            raise Error("golden: odd hex digit count in '" + hex + "'")
        for i in range(0, len(digits), 2):
            self.b.append((digits[i] << 4) | digits[i + 1])

    def bytes(self) -> List[UInt8]:
        return self.b.copy()


def _assert_bytes_eq(got: List[UInt8], want: List[UInt8], ctx: String) raises:
    for i in range(min(len(got), len(want))):
        if got[i] != want[i]:
            raise Error(
                ctx
                + ": first differing byte at offset "
                + String(i)
                + ": got "
                + String(Int(got[i]))
                + ", want "
                + String(Int(want[i]))
            )
    assert_equal(len(got), len(want), ctx + ": length mismatch")


def _every_prefix_refused(
    full: List[UInt8], decode: def (List[UInt8]) raises thin -> Int, ctx: String
) raises:
    """The decoder consumes the reference exactly, and refuses every strict
    prefix of it with the decoder's short-read error (never accepts one)."""
    assert_equal(decode(full), len(full), ctx + ": bytes consumed")
    for n in range(len(full)):
        var p = List[UInt8]()
        for i in range(n):
            p.append(full[i])
        var err = String("<accepted>")
        try:
            _ = decode(p)
        except e:
            err = String(e)
        assert_true(
            err.startswith("komira_kafka_server.wire: short read"),
            ctx + ": prefix of " + String(n) + " bytes: " + err,
        )


# =============================================================================
# §1 — AddPartitionsToTxn (api_key 24), v0.
# =============================================================================


def _apt_req_v0() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0018")  # RequestApiKey = 24
    g.add("0000")  # RequestApiVersion = 0
    g.add("000000a1")  # CorrelationId = 161
    g.add("0001 63")  # ClientId = "c"
    # AddPartitionsToTxnRequest v0 (the V3AndBelow* fields)
    g.add("0003 747831")  # V3AndBelowTransactionalId string = "tx1"
    g.add("000000000000abcd")  # V3AndBelowProducerId int64 = 43981
    g.add("0003")  # V3AndBelowProducerEpoch int16 = 3
    g.add("00000002")  # V3AndBelowTopics array length = 2
    g.add("0002 7431")  #   [0] Name string = "t1"
    g.add("00000002")  #   [0] Partitions []int32 length = 2
    g.add("00000000")  #     0
    g.add("00000001")  #     1
    g.add("0002 7432")  #   [1] Name = "t2"
    g.add("00000000")  #   [1] Partitions length = 0
    return g.bytes()


def _decode_apt(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    _ = parse_request_header(dec, False)
    _ = decode_add_partitions_to_txn_request(dec)
    return dec.pos()


def test_add_partitions_to_txn_request_v0() raises:
    var b = _apt_req_v0()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_key, API_KEY_ADD_PARTITIONS_TO_TXN)
    assert_equal(h.api_version, Int16(0))
    assert_equal(h.correlation_id, Int32(161))
    var r = decode_add_partitions_to_txn_request(dec)
    assert_equal(r.transactional_id, "tx1")
    assert_equal(r.producer_id, Int64(43981))
    assert_equal(r.producer_epoch, Int16(3))
    assert_equal(len(r.topics), 2)
    assert_equal(r.topics[0].topic, "t1")
    assert_equal(len(r.topics[0].partitions), 2)
    assert_equal(r.topics[0].partitions[0], Int32(0))
    assert_equal(r.topics[0].partitions[1], Int32(1))
    assert_equal(r.topics[1].topic, "t2")
    assert_equal(len(r.topics[1].partitions), 0)
    assert_equal(dec.remaining(), 0)
    _every_prefix_refused(b, _decode_apt, "AddPartitionsToTxn request v0")


def test_add_partitions_to_txn_response_v0() raises:
    var g = _Golden()
    g.add("000000a1")  # CorrelationId = 161
    g.add("00000000")  # ThrottleTimeMs int32 = 0
    g.add("00000002")  # ResultsByTopicV3AndBelow array length = 2
    g.add("0002 7431")  #   [0] Name = "t1"
    g.add("00000002")  #   [0] ResultsByPartition array length = 2
    g.add("00000000")  #     [0] PartitionIndex int32 = 0
    g.add("0000")  #     [0] PartitionErrorCode int16 = 0
    g.add("00000001")  #     [1] PartitionIndex = 1
    g.add("0030")  #     [1] PartitionErrorCode = 48
    g.add("0002 7432")  #   [1] Name = "t2"
    g.add("00000000")  #   [1] ResultsByPartition length = 0
    var parts = List[AddPartitionsToTxnPartitionResult]()
    parts.append(AddPartitionsToTxnPartitionResult(Int32(0), Int16(0)))
    parts.append(
        AddPartitionsToTxnPartitionResult(Int32(1), ERROR_INVALID_TXN_STATE)
    )
    var results = List[AddPartitionsToTxnTopicResult]()
    results.append(AddPartitionsToTxnTopicResult("t1", parts^))
    results.append(
        AddPartitionsToTxnTopicResult(
            "t2", List[AddPartitionsToTxnPartitionResult]()
        )
    )
    var got = encode_add_partitions_to_txn_response(Int32(161), results^)
    _assert_bytes_eq(got, g.bytes(), "AddPartitionsToTxn response v0")


# =============================================================================
# §2 — AddOffsetsToTxn (api_key 25), v0.
# =============================================================================


def _aot_req_v0() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0019")  # RequestApiKey = 25
    g.add("0000")  # RequestApiVersion = 0
    g.add("000000b1")  # CorrelationId = 177
    g.add("ffff")  # ClientId = null
    g.add("0003 747831")  # TransactionalId string = "tx1"
    g.add("000000000000abcd")  # ProducerId int64 = 43981
    g.add("0003")  # ProducerEpoch int16 = 3
    g.add("0002 6731")  # GroupId string = "g1"
    return g.bytes()


def _decode_aot(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    _ = parse_request_header(dec, False)
    _ = decode_add_offsets_to_txn_request(dec)
    return dec.pos()


def test_add_offsets_to_txn_request_v0() raises:
    var b = _aot_req_v0()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_key, API_KEY_ADD_OFFSETS_TO_TXN)
    assert_equal(h.correlation_id, Int32(177))
    var r = decode_add_offsets_to_txn_request(dec)
    assert_equal(r.transactional_id, "tx1")
    assert_equal(r.producer_id, Int64(43981))
    assert_equal(r.producer_epoch, Int16(3))
    assert_equal(r.group_id, "g1")
    _every_prefix_refused(b, _decode_aot, "AddOffsetsToTxn request v0")


def test_add_offsets_to_txn_response_v0() raises:
    var g = _Golden()
    g.add("000000b1")  # CorrelationId = 177
    g.add("00000000")  # ThrottleTimeMs int32 = 0
    g.add("0031")  # ErrorCode int16 = 49
    var got = encode_add_offsets_to_txn_response(
        Int32(177), ERROR_INVALID_PRODUCER_ID_MAPPING
    )
    _assert_bytes_eq(got, g.bytes(), "AddOffsetsToTxn response v0")


# =============================================================================
# §3 — EndTxn (api_key 26), v0.
# =============================================================================


def _et_req_v0(committed: Bool) raises -> List[UInt8]:
    var g = _Golden()
    g.add("001a")  # RequestApiKey = 26
    g.add("0000")  # RequestApiVersion = 0
    g.add("000000c1")  # CorrelationId = 193
    g.add("0001 63")  # ClientId = "c"
    g.add("0003 747831")  # TransactionalId string = "tx1"
    g.add("fffffffffffffffe")  # ProducerId int64 = -2
    g.add("7fff")  # ProducerEpoch int16 = 32767
    g.add("01" if committed else "00")  # Committed bool
    return g.bytes()


def _decode_et(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    _ = parse_request_header(dec, False)
    _ = decode_end_txn_request(dec)
    return dec.pos()


def test_end_txn_request_v0() raises:
    for i in range(2):
        var committed = i == 1
        var b = _et_req_v0(committed)
        var dec = KafkaDecoder(Span(b))
        var h = parse_request_header(dec, False)
        assert_equal(h.api_key, API_KEY_END_TXN)
        assert_equal(h.correlation_id, Int32(193))
        var r = decode_end_txn_request(dec)
        assert_equal(r.transactional_id, "tx1")
        assert_equal(r.producer_id, Int64(-2))
        assert_equal(r.producer_epoch, Int16(32767))
        assert_equal(r.committed, committed)
        _every_prefix_refused(b, _decode_et, "EndTxn request v0")


def test_end_txn_response_v0() raises:
    var g = _Golden()
    g.add("000000c1")  # CorrelationId = 193
    g.add("00000000")  # ThrottleTimeMs int32 = 0
    g.add("0030")  # ErrorCode int16 = 48
    var got = encode_end_txn_response(Int32(193), ERROR_INVALID_TXN_STATE)
    _assert_bytes_eq(got, g.bytes(), "EndTxn response v0")


# =============================================================================
# §4 — TxnOffsetCommit (api_key 28), v0.
# =============================================================================


def _toc_req_v0() raises -> List[UInt8]:
    var g = _Golden()
    g.add("001c")  # RequestApiKey = 28
    g.add("0000")  # RequestApiVersion = 0
    g.add("000000d1")  # CorrelationId = 209
    g.add("0001 63")  # ClientId = "c"
    g.add("0003 747831")  # TransactionalId string = "tx1"
    g.add("0002 6731")  # GroupId string = "g1"
    g.add("000000000000abcd")  # ProducerId int64 = 43981
    g.add("0003")  # ProducerEpoch int16 = 3
    g.add("00000002")  # Topics array length = 2
    g.add("0002 7431")  #   [0] Name = "t1"
    g.add("00000002")  #   [0] Partitions array length = 2
    g.add("00000000")  #     [0] PartitionIndex int32 = 0
    g.add("000000000000002a")  #     [0] CommittedOffset int64 = 42
    g.add("0002 6d64")  #     [0] CommittedMetadata nullable string = "md"
    g.add("00000005")  #     [1] PartitionIndex = 5
    g.add("0000000100000000")  #     [1] CommittedOffset = 4294967296
    g.add("0000")  #     [1] CommittedMetadata = ""
    g.add("0002 7432")  #   [1] Name = "t2"
    g.add("00000000")  #   [1] Partitions length = 0
    return g.bytes()


def _toc_req_v0_null_metadata() raises -> List[UInt8]:
    var g = _Golden()
    g.add("001c")  # RequestApiKey = 28
    g.add("0000")  # RequestApiVersion = 0
    g.add("000000d2")  # CorrelationId = 210
    g.add("ffff")  # ClientId = null
    g.add("0003 747831")  # TransactionalId = "tx1"
    g.add("0002 6731")  # GroupId = "g1"
    g.add("000000000000abcd")  # ProducerId = 43981
    g.add("0003")  # ProducerEpoch = 3
    g.add("00000001")  # Topics array length = 1
    g.add("0002 7431")  #   [0] Name = "t1"
    g.add("00000001")  #   [0] Partitions array length = 1
    g.add("00000000")  #     [0] PartitionIndex = 0
    g.add("000000000000002a")  #     [0] CommittedOffset = 42
    g.add("ffff")  #     [0] CommittedMetadata nullable string = null
    return g.bytes()


def _decode_toc(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    _ = parse_request_header(dec, False)
    _ = decode_txn_offset_commit_request(dec)
    return dec.pos()


def test_txn_offset_commit_request_v0() raises:
    var b = _toc_req_v0()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_key, API_KEY_TXN_OFFSET_COMMIT)
    assert_equal(h.api_version, Int16(0))
    assert_equal(h.correlation_id, Int32(209))
    var r = decode_txn_offset_commit_request(dec)
    assert_equal(r.transactional_id, "tx1")
    assert_equal(r.group_id, "g1")
    assert_equal(r.producer_id, Int64(43981))
    assert_equal(r.producer_epoch, Int16(3))
    assert_equal(len(r.topics), 2)
    ref t0 = r.topics[0]
    assert_equal(t0.topic, "t1")
    assert_equal(len(t0.partitions), 2)
    assert_equal(t0.partitions[0].partition, Int32(0))
    assert_equal(t0.partitions[0].offset, Int64(42))
    assert_equal(t0.partitions[0].metadata.value(), "md")
    assert_equal(t0.partitions[1].partition, Int32(5))
    assert_equal(t0.partitions[1].offset, Int64(4294967296))
    assert_true(Bool(t0.partitions[1].metadata))
    assert_equal(t0.partitions[1].metadata.value(), "")
    assert_equal(r.topics[1].topic, "t2")
    assert_equal(len(r.topics[1].partitions), 0)
    _every_prefix_refused(b, _decode_toc, "TxnOffsetCommit request v0")


def test_txn_offset_commit_request_v0_null_metadata() raises:
    var b = _toc_req_v0_null_metadata()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_key, API_KEY_TXN_OFFSET_COMMIT)
    assert_equal(h.correlation_id, Int32(210))
    assert_false(Bool(h.client_id))
    var r = decode_txn_offset_commit_request(dec)
    assert_equal(r.transactional_id, "tx1")
    assert_equal(r.group_id, "g1")
    assert_equal(len(r.topics), 1)
    assert_equal(len(r.topics[0].partitions), 1)
    assert_equal(r.topics[0].partitions[0].offset, Int64(42))
    assert_false(Bool(r.topics[0].partitions[0].metadata))
    assert_equal(dec.remaining(), 0)
    _every_prefix_refused(
        b, _decode_toc, "TxnOffsetCommit request v0 (null metadata)"
    )


def test_txn_offset_commit_response_v0() raises:
    var g = _Golden()
    g.add("000000d1")  # CorrelationId = 209
    g.add("00000000")  # ThrottleTimeMs int32 = 0
    g.add("00000002")  # Topics array length = 2
    g.add("0002 7431")  #   [0] Name = "t1"
    g.add("00000002")  #   [0] Partitions array length = 2
    g.add("00000000")  #     [0] PartitionIndex int32 = 0
    g.add("0000")  #     [0] ErrorCode int16 = 0
    g.add("00000005")  #     [1] PartitionIndex = 5
    g.add("0031")  #     [1] ErrorCode = 49
    g.add("0002 7432")  #   [1] Name = "t2"
    g.add("00000000")  #   [1] Partitions length = 0
    var parts = List[TxnOffsetCommitPartitionResult]()
    parts.append(TxnOffsetCommitPartitionResult(Int32(0), Int16(0)))
    parts.append(
        TxnOffsetCommitPartitionResult(
            Int32(5), ERROR_INVALID_PRODUCER_ID_MAPPING
        )
    )
    var topics = List[TxnOffsetCommitTopicResult]()
    topics.append(TxnOffsetCommitTopicResult("t1", parts^))
    topics.append(
        TxnOffsetCommitTopicResult("t2", List[TxnOffsetCommitPartitionResult]())
    )
    var got = encode_txn_offset_commit_response(Int32(209), topics^)
    _assert_bytes_eq(got, g.bytes(), "TxnOffsetCommit response v0")


def main() raises:
    test_add_partitions_to_txn_request_v0()
    test_add_partitions_to_txn_response_v0()
    test_add_offsets_to_txn_request_v0()
    test_add_offsets_to_txn_response_v0()
    test_end_txn_request_v0()
    test_end_txn_response_v0()
    test_txn_offset_commit_request_v0()
    test_txn_offset_commit_response_v0()
    test_txn_offset_commit_request_v0_null_metadata()
    print("test_kafka_golden_transaction: OK")
