# =============================================================================
# test_kafka_golden_create_topics.mojo — CreateTopics (api_key 19) against
# independent reference bytes
# =============================================================================
#
# Every reference message below is assembled by hand from the Apache Kafka
# message schemas (tag 3.9.0, clients/src/main/resources/common/message/):
# RequestHeader.json, ResponseHeader.json, CreateTopicsRequest.json,
# CreateTopicsResponse.json. Provenance and license: tests/GOLDENS.md.
#
# Requests: header v1 + body; decode at the header's version, assert every
# field the codec keeps (Assignments is read and discarded), check the
# message is consumed exactly and every strict prefix is refused.
# Responses: encode the reference's field values, assert byte equality.
#
# Versions: the codec's range (create_topics.mojo) is v0..v3, non-flexible
# (CreateTopics is flexible at v5+). Version-dependent fields: request
# validateOnly (v1+); response ErrorMessage (v1+) and ThrottleTimeMs (v2+).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_kafka_server.wire.wire import KafkaDecoder
from komira_kafka_server.wire.messages import parse_request_header
from komira_kafka_server.wire.create_topics import (
    API_KEY_CREATE_TOPICS,
    CreateTopicsTopicResult,
    decode_create_topics_request,
    encode_create_topics_response,
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
# §1 — Requests.
# =============================================================================


def _ct_req_v0() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0013")  # RequestApiKey = 19
    g.add("0000")  # RequestApiVersion = 0
    g.add("00000081")  # CorrelationId = 129
    g.add("0001 63")  # ClientId = "c"
    # CreateTopicsRequest v0
    g.add("00000002")  # Topics array length = 2
    g.add("0002 7431")  #   [0] Name string = "t1"
    g.add("00000003")  #   [0] NumPartitions int32 = 3
    g.add("0001")  #   [0] ReplicationFactor int16 = 1
    g.add("00000000")  #   [0] Assignments array length = 0
    g.add("00000002")  #   [0] Configs array length = 2
    g.add("000e 636c65616e75702e706f6c696379")  #     [0] Name = "cleanup.policy"
    g.add("0007 636f6d70616374")  #     [0] Value nullable string = "compact"
    g.add("000c 726574656e74696f6e2e6d73")  #     [1] Name = "retention.ms"
    g.add("ffff")  #     [1] Value = null
    g.add("0002 7432")  #   [1] Name = "t2"
    g.add("ffffffff")  #   [1] NumPartitions = -1 (broker default)
    g.add("ffff")  #   [1] ReplicationFactor = -1
    g.add("00000002")  #   [1] Assignments array length = 2
    g.add("00000000")  #     [0] PartitionIndex int32 = 0
    g.add("00000002")  #     [0] BrokerIds []int32 length = 2
    g.add("00000001")  #       1
    g.add("00000002")  #       2
    g.add("00000001")  #     [1] PartitionIndex = 1
    g.add("00000000")  #     [1] BrokerIds length = 0
    g.add("00000000")  #   [1] Configs array length = 0
    g.add("00007530")  # timeoutMs int32 = 30000
    return g.bytes()


def _ct_req_v1_v3(version: Int, validate_only: Bool) raises -> List[UInt8]:
    var g = _Golden()
    g.add("0013")  # RequestApiKey = 19
    g.add("000" + String(version))  # RequestApiVersion = 1, 2 or 3
    g.add("00000082")  # CorrelationId = 130
    g.add("ffff")  # ClientId = null
    g.add("00000001")  # Topics array length = 1
    g.add("0002 7433")  #   [0] Name = "t3"
    g.add("00000001")  #   [0] NumPartitions = 1
    g.add("0003")  #   [0] ReplicationFactor = 3
    g.add("00000000")  #   [0] Assignments length = 0
    g.add("00000001")  #   [0] Configs length = 1
    g.add("000c 726574656e74696f6e2e6d73")  #     [0] Name = "retention.ms"
    g.add("0003 313030")  #     [0] Value = "100"
    g.add("0000ea60")  # timeoutMs = 60000
    g.add("01" if validate_only else "00")  # validateOnly bool (v1+)
    return g.bytes()


def _decode_ct(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    _ = decode_create_topics_request(dec, h.api_version)
    return dec.pos()


def test_create_topics_request_v0() raises:
    var b = _ct_req_v0()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_key, API_KEY_CREATE_TOPICS)
    assert_equal(h.api_version, Int16(0))
    assert_equal(h.correlation_id, Int32(129))
    assert_equal(h.client_id.value(), "c")
    var r = decode_create_topics_request(dec, h.api_version)
    assert_equal(len(r.topics), 2)
    # copy() is field-for-field (the topic copy also copies its configs).
    var t0 = r.topics[0].copy()
    assert_equal(t0.name, "t1")
    assert_equal(t0.num_partitions, Int32(3))
    assert_equal(t0.replication_factor, Int16(1))
    assert_equal(len(t0.configs), 2)
    assert_equal(t0.configs[0].name, "cleanup.policy")
    assert_equal(t0.configs[0].value.value(), "compact")
    assert_equal(t0.configs[1].name, "retention.ms")
    assert_false(Bool(t0.configs[1].value))
    ref t1 = r.topics[1]
    assert_equal(t1.name, "t2")
    assert_equal(t1.num_partitions, Int32(-1))
    assert_equal(t1.replication_factor, Int16(-1))
    assert_equal(len(t1.configs), 0)
    assert_equal(r.timeout_ms, Int32(30000))
    # validateOnly is absent at v0; the schema default is false.
    assert_false(r.validate_only)
    assert_equal(dec.remaining(), 0)
    _every_prefix_refused(b, _decode_ct, "CreateTopics request v0")


def test_create_topics_request_v1_v3() raises:
    for v in range(1, 4):
        var validate = v != 2  # v1 and v3 true, v2 false
        var b = _ct_req_v1_v3(v, validate)
        var dec = KafkaDecoder(Span(b))
        var h = parse_request_header(dec, False)
        assert_equal(h.api_version, Int16(v))
        assert_equal(h.correlation_id, Int32(130))
        assert_false(Bool(h.client_id))
        var r = decode_create_topics_request(dec, h.api_version)
        assert_equal(len(r.topics), 1)
        assert_equal(r.topics[0].name, "t3")
        assert_equal(r.topics[0].num_partitions, Int32(1))
        assert_equal(r.topics[0].replication_factor, Int16(3))
        assert_equal(len(r.topics[0].configs), 1)
        var c0 = r.topics[0].configs[0].copy()
        assert_equal(c0.name, "retention.ms")
        assert_equal(c0.value.value(), "100")
        assert_equal(r.timeout_ms, Int32(60000))
        assert_equal(r.validate_only, validate)
        _every_prefix_refused(
            b, _decode_ct, "CreateTopics request v" + String(v)
        )


# =============================================================================
# §2 — Responses.
# =============================================================================


def _results() -> List[CreateTopicsTopicResult]:
    var out = List[CreateTopicsTopicResult]()
    out.append(CreateTopicsTopicResult("t1", Int16(0)))
    out.append(
        CreateTopicsTopicResult("t2", Int16(40), Optional[String]("bad"))
    )
    return out^


def test_create_topics_response_v0() raises:
    var g = _Golden()
    g.add("00000081")  # CorrelationId = 129
    # v0: no ThrottleTimeMs (v2+), no ErrorMessage (v1+)
    g.add("00000002")  # Topics array length = 2
    g.add("0002 7431")  #   [0] Name = "t1"
    g.add("0000")  #   [0] ErrorCode int16 = 0
    g.add("0002 7432")  #   [1] Name = "t2"
    g.add("0028")  #   [1] ErrorCode = 40
    var got = encode_create_topics_response(Int32(129), _results(), Int16(0))
    _assert_bytes_eq(got, g.bytes(), "CreateTopics response v0")


def test_create_topics_response_v1() raises:
    var g = _Golden()
    g.add("00000082")  # CorrelationId = 130
    # v1: ErrorMessage, still no ThrottleTimeMs
    g.add("00000002")  # Topics array length = 2
    g.add("0002 7431")  #   [0] Name = "t1"
    g.add("0000")  #   [0] ErrorCode = 0
    g.add("ffff")  #   [0] ErrorMessage nullable string = null
    g.add("0002 7432")  #   [1] Name = "t2"
    g.add("0028")  #   [1] ErrorCode = 40
    g.add("0003 626164")  #   [1] ErrorMessage = "bad"
    var results = _results()
    var got = encode_create_topics_response(Int32(130), results, Int16(1))
    _assert_bytes_eq(got, g.bytes(), "CreateTopics response v1")
    var again = encode_create_topics_response(
        Int32(130), results.copy(), Int16(1)
    )
    _assert_bytes_eq(again, g.bytes(), "CreateTopics response v1 (copy)")


def test_create_topics_response_v2_v3() raises:
    for v in range(2, 4):
        var g = _Golden()
        g.add("00000083")  # CorrelationId = 131
        g.add("00000000")  # ThrottleTimeMs int32 = 0 (v2+)
        g.add("00000002")  # Topics array length = 2
        g.add("0002 7431")  #   [0] Name = "t1"
        g.add("0000")  #   [0] ErrorCode = 0
        g.add("ffff")  #   [0] ErrorMessage = null
        g.add("0002 7432")  #   [1] Name = "t2"
        g.add("0028")  #   [1] ErrorCode = 40
        g.add("0003 626164")  #   [1] ErrorMessage = "bad"
        var got = encode_create_topics_response(
            Int32(131), _results(), Int16(v)
        )
        _assert_bytes_eq(
            got, g.bytes(), "CreateTopics response v" + String(v)
        )


def test_create_topics_response_empty() raises:
    var g = _Golden()
    g.add("00000084")  # CorrelationId = 132
    g.add("00000000")  # ThrottleTimeMs = 0
    g.add("00000000")  # Topics array length = 0
    var got = encode_create_topics_response(
        Int32(132), List[CreateTopicsTopicResult](), Int16(3)
    )
    _assert_bytes_eq(got, g.bytes(), "CreateTopics response v3 (empty)")


def main() raises:
    test_create_topics_request_v0()
    test_create_topics_request_v1_v3()
    test_create_topics_response_v0()
    test_create_topics_response_v1()
    test_create_topics_response_v2_v3()
    test_create_topics_response_empty()
    print("test_kafka_golden_create_topics: OK")
