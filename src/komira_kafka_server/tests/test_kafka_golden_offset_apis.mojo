# =============================================================================
# test_kafka_golden_offset_apis.mojo — FindCoordinator / OffsetCommit /
# OffsetFetch against independent reference bytes
# =============================================================================
#
# Every reference message below is assembled by hand from the Apache Kafka
# message schemas (tag 3.9.0, clients/src/main/resources/common/message/):
# RequestHeader.json, ResponseHeader.json, FindCoordinatorRequest.json,
# FindCoordinatorResponse.json, OffsetCommitRequest.json,
# OffsetCommitResponse.json, OffsetFetchRequest.json, OffsetFetchResponse.json.
# Provenance and license: tests/GOLDENS.md. No byte here was produced by the
# codec under test or by a Kafka client.
#
# Requests: the reference carries request header v1 (api_key, api_version,
# correlation_id, client_id); the test parses the header, decodes the body at
# the header's version, asserts every field, checks the whole message was
# consumed, and checks every strict prefix is refused with the short-read
# error. Responses: the codec has encoders only, so the test encodes the
# reference's field values and asserts byte equality with the reference.
#
# Versions: the codec's ranges (consumer_group.mojo) are FindCoordinator
# request v0..v1 / response v0..v1, OffsetCommit v2, OffsetFetch v1..v3. All
# are non-flexible (FindCoordinator is flexible at v3+, OffsetCommit at v8+,
# OffsetFetch at v6+), so there are no compact forms or tag buffers.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_kafka_server.wire.wire import KafkaDecoder
from komira_kafka_server.wire.messages import parse_request_header
from komira_kafka_server.wire.consumer_group import (
    API_KEY_FIND_COORDINATOR,
    API_KEY_OFFSET_COMMIT,
    API_KEY_OFFSET_FETCH,
    COORDINATOR_KEY_TYPE_GROUP,
    COORDINATOR_KEY_TYPE_TRANSACTION,
    decode_find_coordinator_request,
    encode_find_coordinator_response,
    OffsetCommitTopicResult,
    OffsetCommitPartitionResult,
    decode_offset_commit_request,
    encode_offset_commit_response_v2,
    OffsetFetchTopicResult,
    OffsetFetchPartitionResult,
    decode_offset_fetch_request,
    encode_offset_fetch_response,
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
# §1 — FindCoordinator (api_key 10).
# =============================================================================


def _fc_req_v0() raises -> List[UInt8]:
    var g = _Golden()
    # RequestHeader v1
    g.add("000a")  # RequestApiKey int16 = 10
    g.add("0000")  # RequestApiVersion int16 = 0
    g.add("00000011")  # CorrelationId int32 = 17
    g.add("0001 63")  # ClientId nullable string = "c"
    # FindCoordinatorRequest v0
    g.add("0002 6731")  # Key string = "g1"
    return g.bytes()


def _fc_req_v1() raises -> List[UInt8]:
    var g = _Golden()
    g.add("000a")  # RequestApiKey = 10
    g.add("0001")  # RequestApiVersion = 1
    g.add("00000012")  # CorrelationId = 18
    g.add("ffff")  # ClientId = null
    # FindCoordinatorRequest v1
    g.add("0003 747831")  # Key string = "tx1"
    g.add("01")  # KeyType int8 = 1 (transaction)
    return g.bytes()


def _decode_fc(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    _ = decode_find_coordinator_request(dec, h.api_version)
    return dec.pos()


def test_find_coordinator_request_v0() raises:
    var b = _fc_req_v0()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_key, API_KEY_FIND_COORDINATOR)
    assert_equal(h.api_version, Int16(0))
    assert_equal(h.correlation_id, Int32(17))
    assert_equal(h.client_id.value(), "c")
    var r = decode_find_coordinator_request(dec, h.api_version)
    assert_equal(r.key, "g1")
    # KeyType is absent at v0; the schema default is 0 (group).
    assert_equal(r.key_type, COORDINATOR_KEY_TYPE_GROUP)
    assert_equal(dec.remaining(), 0)
    _every_prefix_refused(b, _decode_fc, "FindCoordinator request v0")


def test_find_coordinator_request_v1() raises:
    var b = _fc_req_v1()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_version, Int16(1))
    assert_equal(h.correlation_id, Int32(18))
    assert_false(Bool(h.client_id))
    var r = decode_find_coordinator_request(dec, h.api_version)
    assert_equal(r.key, "tx1")
    assert_equal(r.key_type, COORDINATOR_KEY_TYPE_TRANSACTION)
    _every_prefix_refused(b, _decode_fc, "FindCoordinator request v1")


def test_find_coordinator_response_v0() raises:
    var g = _Golden()
    g.add("00000011")  # ResponseHeader v0: CorrelationId = 17
    g.add("000f")  # ErrorCode int16 = 15
    g.add("00000007")  # NodeId int32 = 7
    g.add("0002 6831")  # Host string = "h1"
    g.add("00002384")  # Port int32 = 9092
    var got = encode_find_coordinator_response(
        Int32(17), Int16(0), Int16(15), Int32(7), "h1", Int32(9092)
    )
    _assert_bytes_eq(got, g.bytes(), "FindCoordinator response v0")


def test_find_coordinator_response_v1() raises:
    var g = _Golden()
    g.add("00000012")  # CorrelationId = 18
    g.add("00000000")  # ThrottleTimeMs int32 = 0 (v1+)
    g.add("0000")  # ErrorCode = 0
    g.add("ffff")  # ErrorMessage nullable string = null (v1+)
    g.add("00000007")  # NodeId = 7
    g.add("0002 6831")  # Host = "h1"
    g.add("00002384")  # Port = 9092
    var got = encode_find_coordinator_response(
        Int32(18), Int16(1), Int16(0), Int32(7), "h1", Int32(9092)
    )
    _assert_bytes_eq(got, g.bytes(), "FindCoordinator response v1")


# =============================================================================
# §2 — OffsetCommit (api_key 8), v2.
# =============================================================================


def _oc_req_v2() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0008")  # RequestApiKey = 8
    g.add("0002")  # RequestApiVersion = 2
    g.add("00000021")  # CorrelationId = 33
    g.add("0001 63")  # ClientId = "c"
    # OffsetCommitRequest v2
    g.add("0002 6731")  # GroupId string = "g1"
    g.add("00000005")  # GenerationIdOrMemberEpoch int32 = 5 (v1+)
    g.add("0002 6d31")  # MemberId string = "m1" (v1+)
    g.add("0000000000002710")  # RetentionTimeMs int64 = 10000 (v2-4)
    g.add("00000002")  # Topics array length = 2
    g.add("0002 7431")  #   [0] Name string = "t1"
    g.add("00000002")  #   [0] Partitions array length = 2
    g.add("00000000")  #     [0] PartitionIndex int32 = 0
    g.add("000000000000002a")  #     [0] CommittedOffset int64 = 42
    g.add("0002 6d64")  #     [0] CommittedMetadata nullable string = "md"
    g.add("00000003")  #     [1] PartitionIndex = 3
    g.add("ffffffffffffffff")  #     [1] CommittedOffset = -1
    g.add("ffff")  #     [1] CommittedMetadata = null
    g.add("0002 7432")  #   [1] Name = "t2"
    g.add("00000000")  #   [1] Partitions array length = 0
    return g.bytes()


def _decode_oc(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    _ = parse_request_header(dec, False)
    _ = decode_offset_commit_request(dec)
    return dec.pos()


def test_offset_commit_request_v2() raises:
    var b = _oc_req_v2()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_key, API_KEY_OFFSET_COMMIT)
    assert_equal(h.api_version, Int16(2))
    assert_equal(h.correlation_id, Int32(33))
    var r = decode_offset_commit_request(dec)
    assert_equal(r.group_id, "g1")
    assert_equal(r.generation_id, Int32(5))
    assert_equal(r.member_id, "m1")
    assert_equal(r.retention_time_ms, Int64(10000))
    assert_equal(len(r.topics), 2)
    # copy() is field-for-field (the topic copy also copies its partitions).
    var t0 = r.topics[0].copy()
    assert_equal(t0.name, "t1")
    assert_equal(len(t0.partitions), 2)
    assert_equal(t0.partitions[0].partition_index, Int32(0))
    assert_equal(t0.partitions[0].committed_offset, Int64(42))
    assert_equal(t0.partitions[0].metadata.value(), "md")
    assert_equal(t0.partitions[1].partition_index, Int32(3))
    assert_equal(t0.partitions[1].committed_offset, Int64(-1))
    assert_false(Bool(t0.partitions[1].metadata))
    assert_equal(r.topics[1].name, "t2")
    assert_equal(len(r.topics[1].partitions), 0)
    assert_equal(dec.remaining(), 0)
    _every_prefix_refused(b, _decode_oc, "OffsetCommit request v2")


def test_offset_commit_response_v2() raises:
    var g = _Golden()
    g.add("00000021")  # CorrelationId = 33
    # OffsetCommitResponse v2: no ThrottleTimeMs (v3+)
    g.add("00000002")  # Topics array length = 2
    g.add("0002 7431")  #   [0] Name = "t1"
    g.add("00000002")  #   [0] Partitions array length = 2
    g.add("00000000")  #     [0] PartitionIndex int32 = 0
    g.add("0000")  #     [0] ErrorCode int16 = 0
    g.add("00000003")  #     [1] PartitionIndex = 3
    g.add("0016")  #     [1] ErrorCode = 22
    g.add("0002 7432")  #   [1] Name = "t2"
    g.add("00000000")  #   [1] Partitions array length = 0
    var p = List[OffsetCommitPartitionResult]()
    p.append(OffsetCommitPartitionResult(Int32(0), Int16(0)))
    p.append(OffsetCommitPartitionResult(Int32(3), Int16(22)))
    var topics = List[OffsetCommitTopicResult]()
    topics.append(OffsetCommitTopicResult("t1", p^))
    topics.append(
        OffsetCommitTopicResult("t2", List[OffsetCommitPartitionResult]())
    )
    var got = encode_offset_commit_response_v2(Int32(33), topics)
    _assert_bytes_eq(got, g.bytes(), "OffsetCommit response v2")
    # The encoder reads the same bytes back from a field-for-field copy.
    var again = encode_offset_commit_response_v2(Int32(33), topics.copy())
    _assert_bytes_eq(again, g.bytes(), "OffsetCommit response v2 (copy)")


# =============================================================================
# §3 — OffsetFetch (api_key 9), v1..v3.
# =============================================================================


def _of_req_v1() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0009")  # RequestApiKey = 9
    g.add("0001")  # RequestApiVersion = 1
    g.add("00000031")  # CorrelationId = 49
    g.add("0001 63")  # ClientId = "c"
    # OffsetFetchRequest v1
    g.add("0002 6731")  # GroupId string = "g1"
    g.add("00000001")  # Topics array length = 1
    g.add("0002 7431")  #   [0] Name = "t1"
    g.add("00000002")  #   [0] PartitionIndexes []int32 length = 2
    g.add("00000000")  #     0
    g.add("00000007")  #     7
    return g.bytes()


def _of_req_v2_null() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0009")  # RequestApiKey = 9
    g.add("0002")  # RequestApiVersion = 2
    g.add("00000032")  # CorrelationId = 50
    g.add("ffff")  # ClientId = null
    g.add("0002 6731")  # GroupId = "g1"
    g.add("ffffffff")  # Topics = null (nullable at v2-7: all topics)
    return g.bytes()


def _of_req_v3() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0009")  # RequestApiKey = 9
    g.add("0003")  # RequestApiVersion = 3
    g.add("00000033")  # CorrelationId = 51
    g.add("0001 63")  # ClientId = "c"
    g.add("0002 6731")  # GroupId = "g1"
    g.add("00000002")  # Topics array length = 2
    g.add("0002 7431")  #   [0] Name = "t1"
    g.add("00000001")  #   [0] PartitionIndexes length = 1
    g.add("00000004")  #     4
    g.add("0002 7432")  #   [1] Name = "t2"
    g.add("00000000")  #   [1] PartitionIndexes length = 0
    return g.bytes()


def _decode_of(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    _ = parse_request_header(dec, False)
    _ = decode_offset_fetch_request(dec)
    return dec.pos()


def test_offset_fetch_request_v1() raises:
    var b = _of_req_v1()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_key, API_KEY_OFFSET_FETCH)
    assert_equal(h.api_version, Int16(1))
    assert_equal(h.correlation_id, Int32(49))
    var r = decode_offset_fetch_request(dec)
    assert_equal(r.group_id, "g1")
    ref topics = r.topics.value()
    assert_equal(len(topics), 1)
    var t0 = topics[0].copy()
    assert_equal(t0.name, "t1")
    assert_equal(len(t0.partition_indexes), 2)
    assert_equal(t0.partition_indexes[0], Int32(0))
    assert_equal(t0.partition_indexes[1], Int32(7))
    _every_prefix_refused(b, _decode_of, "OffsetFetch request v1")


def test_offset_fetch_request_v2_null_topics() raises:
    var b = _of_req_v2_null()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_version, Int16(2))
    var r = decode_offset_fetch_request(dec)
    assert_equal(r.group_id, "g1")
    assert_false(Bool(r.topics))
    _every_prefix_refused(b, _decode_of, "OffsetFetch request v2 (null)")


def test_offset_fetch_request_v3() raises:
    var b = _of_req_v3()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_version, Int16(3))
    assert_equal(h.correlation_id, Int32(51))
    var r = decode_offset_fetch_request(dec)
    ref topics = r.topics.value()
    assert_equal(len(topics), 2)
    assert_equal(topics[0].name, "t1")
    assert_equal(len(topics[0].partition_indexes), 1)
    assert_equal(topics[0].partition_indexes[0], Int32(4))
    assert_equal(topics[1].name, "t2")
    assert_equal(len(topics[1].partition_indexes), 0)
    _every_prefix_refused(b, _decode_of, "OffsetFetch request v3")


def _of_topics() -> List[OffsetFetchTopicResult]:
    var p = List[OffsetFetchPartitionResult]()
    p.append(
        OffsetFetchPartitionResult(
            Int32(0), Int64(42), Optional[String]("md"), Int16(0)
        )
    )
    p.append(
        OffsetFetchPartitionResult(
            Int32(7), Int64(-1), Optional[String](), Int16(3)
        )
    )
    var topics = List[OffsetFetchTopicResult]()
    topics.append(OffsetFetchTopicResult("t1", p^))
    return topics^


def _of_resp_topics_hex(mut g: _Golden) raises:
    g.add("00000001")  # Topics array length = 1
    g.add("0002 7431")  #   [0] Name = "t1"
    g.add("00000002")  #   [0] Partitions array length = 2
    g.add("00000000")  #     [0] PartitionIndex int32 = 0
    g.add("000000000000002a")  #     [0] CommittedOffset int64 = 42
    g.add("0002 6d64")  #     [0] Metadata nullable string = "md"
    g.add("0000")  #     [0] ErrorCode int16 = 0
    g.add("00000007")  #     [1] PartitionIndex = 7
    g.add("ffffffffffffffff")  #     [1] CommittedOffset = -1 (no offset)
    g.add("ffff")  #     [1] Metadata = null
    # Nonzero and distinct from every top-level code, so an encoder that
    # writes a constant 0 (or the top-level code) here is caught.
    g.add("0003")  #     [1] ErrorCode = 3 (UNKNOWN_TOPIC_OR_PARTITION)


def test_offset_fetch_response_v1() raises:
    var g = _Golden()
    g.add("00000031")  # CorrelationId = 49
    # v1: no ThrottleTimeMs (v3+), no top-level ErrorCode (v2+)
    _of_resp_topics_hex(g)
    var topics = _of_topics()
    var got = encode_offset_fetch_response(
        Int32(49), Int16(1), topics, Int16(16)
    )
    _assert_bytes_eq(got, g.bytes(), "OffsetFetch response v1")
    var again = encode_offset_fetch_response(
        Int32(49), Int16(1), topics.copy(), Int16(16)
    )
    _assert_bytes_eq(again, g.bytes(), "OffsetFetch response v1 (copy)")


def test_offset_fetch_response_v2() raises:
    var g = _Golden()
    g.add("00000032")  # CorrelationId = 50
    _of_resp_topics_hex(g)
    g.add("0010")  # ErrorCode int16 (top level, v2+) = 16
    var got = encode_offset_fetch_response(
        Int32(50), Int16(2), _of_topics(), Int16(16)
    )
    _assert_bytes_eq(got, g.bytes(), "OffsetFetch response v2")


def test_offset_fetch_response_v3() raises:
    var g = _Golden()
    g.add("00000033")  # CorrelationId = 51
    g.add("00000000")  # ThrottleTimeMs int32 = 0 (v3+)
    _of_resp_topics_hex(g)
    g.add("0000")  # ErrorCode (top level) = 0
    var got = encode_offset_fetch_response(
        Int32(51), Int16(3), _of_topics(), Int16(0)
    )
    _assert_bytes_eq(got, g.bytes(), "OffsetFetch response v3")


def main() raises:
    test_find_coordinator_request_v0()
    test_find_coordinator_request_v1()
    test_find_coordinator_response_v0()
    test_find_coordinator_response_v1()
    test_offset_commit_request_v2()
    test_offset_commit_response_v2()
    test_offset_fetch_request_v1()
    test_offset_fetch_request_v2_null_topics()
    test_offset_fetch_request_v3()
    test_offset_fetch_response_v1()
    test_offset_fetch_response_v2()
    test_offset_fetch_response_v3()
    print("test_kafka_golden_offset_apis: OK")
