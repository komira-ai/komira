# =============================================================================
# test_kafka_golden_group_apis.mojo — JoinGroup / SyncGroup / Heartbeat /
# LeaveGroup against independent reference bytes
# =============================================================================
#
# Every reference message below is assembled by hand from the Apache Kafka
# message schemas (tag 3.9.0, clients/src/main/resources/common/message/):
# RequestHeader.json, ResponseHeader.json, JoinGroupRequest.json,
# JoinGroupResponse.json, SyncGroupRequest.json, SyncGroupResponse.json,
# HeartbeatRequest.json, HeartbeatResponse.json, LeaveGroupRequest.json,
# LeaveGroupResponse.json. Provenance and license: tests/GOLDENS.md.
#
# Requests: header v1 + body; decode at the header's version, assert every
# field, check the message is consumed exactly and every strict prefix is
# refused. Responses: encode the reference's field values, assert byte
# equality.
#
# Versions: the codec's ranges (consumer_group.mojo) are JoinGroup v2..v4,
# SyncGroup v1..v3, Heartbeat v1..v2, LeaveGroup v1..v2, all non-flexible
# (flexible at JoinGroup v6+, SyncGroup v4+, Heartbeat v4+, LeaveGroup v4+).
# The v0 cases below are outside those ranges: they exist to drive the
# codec's own `api_version >= 1` / `>= 2` gates down their false branch, and
# their bytes follow the v0 schema.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_kafka_server.wire.wire import KafkaDecoder
from komira_kafka_server.wire.messages import parse_request_header
from komira_kafka_server.wire.consumer_group import (
    API_KEY_JOIN_GROUP,
    API_KEY_SYNC_GROUP,
    API_KEY_HEARTBEAT,
    API_KEY_LEAVE_GROUP,
    decode_join_group_request,
    JoinGroupResponseMember,
    encode_join_group_response,
    decode_sync_group_request,
    encode_sync_group_response,
    decode_heartbeat_request,
    encode_heartbeat_response,
    decode_leave_group_request,
    encode_leave_group_response,
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
# §1 — JoinGroup (api_key 11).
# =============================================================================


def _jg_req_v0() raises -> List[UInt8]:
    var g = _Golden()
    g.add("000b")  # RequestApiKey = 11
    g.add("0000")  # RequestApiVersion = 0
    g.add("00000041")  # CorrelationId = 65
    g.add("0001 63")  # ClientId = "c"
    # JoinGroupRequest v0: no RebalanceTimeoutMs (v1+)
    g.add("0002 6731")  # GroupId string = "g1"
    g.add("00007530")  # SessionTimeoutMs int32 = 30000
    g.add("0000")  # MemberId string = "" (first join)
    g.add("0008 636f6e73756d6572")  # ProtocolType string = "consumer"
    g.add("00000001")  # Protocols array length = 1
    g.add("0005 72616e6765")  #   [0] Name string = "range"
    g.add("00000003 010203")  #   [0] Metadata bytes = 01 02 03
    return g.bytes()


def _jg_req_v1() raises -> List[UInt8]:
    # v1 is the only version with RebalanceTimeoutMs (v1+) but without the
    # v2 response's ThrottleTimeMs, so it pins the request gate at exactly 1.
    var g = _Golden()
    g.add("000b")  # RequestApiKey = 11
    g.add("0001")  # RequestApiVersion = 1
    g.add("00000043")  # CorrelationId = 67
    g.add("0001 63")  # ClientId = "c"
    g.add("0002 6733")  # GroupId string = "g3"
    g.add("00001388")  # SessionTimeoutMs int32 = 5000
    g.add("00009c40")  # RebalanceTimeoutMs int32 = 40000 (v1+)
    g.add("0002 6d33")  # MemberId string = "m3"
    g.add("0008 636f6e73756d6572")  # ProtocolType string = "consumer"
    g.add("00000001")  # Protocols array length = 1
    g.add("0002 7272")  #   [0] Name string = "rr"
    g.add("00000001 07")  #   [0] Metadata bytes = 07
    return g.bytes()


def _jg_req_v2() raises -> List[UInt8]:
    var g = _Golden()
    g.add("000b")  # RequestApiKey = 11
    g.add("0002")  # RequestApiVersion = 2
    g.add("00000042")  # CorrelationId = 66
    g.add("ffff")  # ClientId = null
    g.add("0002 6731")  # GroupId = "g1"
    g.add("00007530")  # SessionTimeoutMs = 30000
    g.add("0000ea60")  # RebalanceTimeoutMs int32 = 60000 (v1+)
    g.add("0002 6d31")  # MemberId = "m1"
    g.add("0008 636f6e73756d6572")  # ProtocolType = "consumer"
    g.add("00000002")  # Protocols array length = 2
    g.add("0005 72616e6765")  #   [0] Name = "range"
    g.add("00000000")  #   [0] Metadata bytes = (empty)
    g.add("0002 7272")  #   [1] Name = "rr"
    g.add("00000002 aabb")  #   [1] Metadata bytes = aa bb
    return g.bytes()


def _jg_req_v3_v4(version: Int) raises -> List[UInt8]:
    # v3 and v4 have the v2 layout (GroupInstanceId is v5+).
    var g = _Golden()
    g.add("000b")  # RequestApiKey = 11
    g.add("000" + String(version))  # RequestApiVersion = 3 or 4
    g.add("00000044")  # CorrelationId = 68
    g.add("0001 63")  # ClientId = "c"
    g.add("0002 6732")  # GroupId = "g2"
    g.add("00002710")  # SessionTimeoutMs = 10000
    g.add("00004e20")  # RebalanceTimeoutMs = 20000
    g.add("0000")  # MemberId = ""
    g.add("0008 636f6e73756d6572")  # ProtocolType = "consumer"
    g.add("00000000")  # Protocols array length = 0
    return g.bytes()


def _decode_jg(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    _ = decode_join_group_request(dec, h.api_version)
    return dec.pos()


def test_join_group_request_v0() raises:
    var b = _jg_req_v0()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_key, API_KEY_JOIN_GROUP)
    assert_equal(h.api_version, Int16(0))
    assert_equal(h.correlation_id, Int32(65))
    var r = decode_join_group_request(dec, h.api_version)
    assert_equal(r.group_id, "g1")
    assert_equal(r.session_timeout_ms, Int32(30000))
    # Absent at v0; the schema default is -1.
    assert_equal(r.rebalance_timeout_ms, Int32(-1))
    assert_equal(r.member_id, "")
    assert_equal(r.protocol_type, "consumer")
    assert_equal(len(r.protocols), 1)
    var p0 = r.protocols[0].copy()
    assert_equal(p0.name, "range")
    assert_equal(len(p0.metadata), 3)
    assert_equal(p0.metadata[0], UInt8(1))
    assert_equal(p0.metadata[2], UInt8(3))
    _every_prefix_refused(b, _decode_jg, "JoinGroup request v0")


def test_join_group_request_v1() raises:
    var b = _jg_req_v1()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_key, API_KEY_JOIN_GROUP)
    assert_equal(h.api_version, Int16(1))
    assert_equal(h.correlation_id, Int32(67))
    var r = decode_join_group_request(dec, h.api_version)
    assert_equal(r.group_id, "g3")
    assert_equal(r.session_timeout_ms, Int32(5000))
    assert_equal(r.rebalance_timeout_ms, Int32(40000))
    assert_equal(r.member_id, "m3")
    assert_equal(r.protocol_type, "consumer")
    assert_equal(len(r.protocols), 1)
    assert_equal(r.protocols[0].name, "rr")
    assert_equal(len(r.protocols[0].metadata), 1)
    assert_equal(r.protocols[0].metadata[0], UInt8(7))
    assert_equal(dec.pos(), len(b))
    _every_prefix_refused(b, _decode_jg, "JoinGroup request v1")


def test_join_group_request_v2() raises:
    var b = _jg_req_v2()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_version, Int16(2))
    assert_false(Bool(h.client_id))
    var r = decode_join_group_request(dec, h.api_version)
    assert_equal(r.group_id, "g1")
    assert_equal(r.session_timeout_ms, Int32(30000))
    assert_equal(r.rebalance_timeout_ms, Int32(60000))
    assert_equal(r.member_id, "m1")
    assert_equal(r.protocol_type, "consumer")
    assert_equal(len(r.protocols), 2)
    assert_equal(r.protocols[0].name, "range")
    assert_equal(len(r.protocols[0].metadata), 0)
    assert_equal(r.protocols[1].name, "rr")
    assert_equal(len(r.protocols[1].metadata), 2)
    assert_equal(r.protocols[1].metadata[0], UInt8(0xAA))
    assert_equal(r.protocols[1].metadata[1], UInt8(0xBB))
    _every_prefix_refused(b, _decode_jg, "JoinGroup request v2")


def test_join_group_request_v3_v4() raises:
    for v in range(3, 5):
        var b = _jg_req_v3_v4(v)
        var dec = KafkaDecoder(Span(b))
        var h = parse_request_header(dec, False)
        assert_equal(h.api_version, Int16(v))
        assert_equal(h.correlation_id, Int32(68))
        var r = decode_join_group_request(dec, h.api_version)
        assert_equal(r.group_id, "g2")
        assert_equal(r.session_timeout_ms, Int32(10000))
        assert_equal(r.rebalance_timeout_ms, Int32(20000))
        assert_equal(r.member_id, "")
        assert_equal(r.protocol_type, "consumer")
        assert_equal(len(r.protocols), 0)
        _every_prefix_refused(
            b, _decode_jg, "JoinGroup request v" + String(v)
        )


def test_join_group_response_v0() raises:
    var g = _Golden()
    g.add("00000041")  # CorrelationId = 65
    # v0: no ThrottleTimeMs (v2+)
    g.add("0000")  # ErrorCode int16 = 0
    g.add("00000001")  # GenerationId int32 = 1
    g.add("0005 72616e6765")  # ProtocolName string = "range"
    g.add("0002 6d31")  # Leader string = "m1"
    g.add("0002 6d31")  # MemberId string = "m1"
    g.add("00000001")  # Members array length = 1
    g.add("0002 6d31")  #   [0] MemberId = "m1"
    g.add("00000003 010203")  #   [0] Metadata bytes = 01 02 03
    var members = List[JoinGroupResponseMember]()
    var md = List[UInt8]()
    md.append(1)
    md.append(2)
    md.append(3)
    members.append(JoinGroupResponseMember("m1", md^))
    var got = encode_join_group_response(
        Int32(65), Int16(0), Int16(0), Int32(1), "range", "m1", "m1", members
    )
    _assert_bytes_eq(got, g.bytes(), "JoinGroup response v0")
    var again = encode_join_group_response(
        Int32(65),
        Int16(0),
        Int16(0),
        Int32(1),
        "range",
        "m1",
        "m1",
        members.copy(),
    )
    _assert_bytes_eq(again, g.bytes(), "JoinGroup response v0 (copy)")


def test_join_group_response_v1() raises:
    # v1 has the v0 response layout: ThrottleTimeMs starts at v2. This pins
    # the response gate at exactly 2.
    var g = _Golden()
    g.add("00000043")  # CorrelationId = 67
    g.add("0019")  # ErrorCode int16 = 25
    g.add("00000003")  # GenerationId int32 = 3
    g.add("0002 7272")  # ProtocolName string = "rr"
    g.add("0002 6d33")  # Leader string = "m3"
    g.add("0002 6d34")  # MemberId string = "m4"
    g.add("00000000")  # Members array length = 0
    var got = encode_join_group_response(
        Int32(67),
        Int16(1),
        Int16(25),
        Int32(3),
        "rr",
        "m3",
        "m4",
        List[JoinGroupResponseMember](),
    )
    _assert_bytes_eq(got, g.bytes(), "JoinGroup response v1")


def test_join_group_response_v2() raises:
    var g = _Golden()
    g.add("00000042")  # CorrelationId = 66
    g.add("00000000")  # ThrottleTimeMs int32 = 0 (v2+)
    g.add("001b")  # ErrorCode = 27
    g.add("00000002")  # GenerationId = 2
    g.add("0005 72616e6765")  # ProtocolName = "range"
    g.add("0002 6d31")  # Leader = "m1"
    g.add("0002 6d32")  # MemberId = "m2" (a follower)
    g.add("00000000")  # Members array length = 0
    var got = encode_join_group_response(
        Int32(66),
        Int16(2),
        Int16(27),
        Int32(2),
        "range",
        "m1",
        "m2",
        List[JoinGroupResponseMember](),
    )
    _assert_bytes_eq(got, g.bytes(), "JoinGroup response v2")


def test_join_group_response_v3_v4() raises:
    for v in range(3, 5):
        var g = _Golden()
        g.add("00000044")  # CorrelationId = 68
        g.add("00000000")  # ThrottleTimeMs = 0
        g.add("0000")  # ErrorCode = 0
        g.add("00000003")  # GenerationId = 3
        g.add("0002 7272")  # ProtocolName = "rr"
        g.add("0002 6d31")  # Leader = "m1"
        g.add("0002 6d31")  # MemberId = "m1"
        g.add("00000002")  # Members array length = 2
        g.add("0002 6d31")  #   [0] MemberId = "m1"
        g.add("00000001 07")  #   [0] Metadata bytes = 07
        g.add("0002 6d32")  #   [1] MemberId = "m2"
        g.add("00000000")  #   [1] Metadata bytes = (empty)
        var members = List[JoinGroupResponseMember]()
        var md = List[UInt8]()
        md.append(7)
        members.append(JoinGroupResponseMember("m1", md^))
        members.append(JoinGroupResponseMember("m2", List[UInt8]()))
        var got = encode_join_group_response(
            Int32(68), Int16(v), Int16(0), Int32(3), "rr", "m1", "m1", members
        )
        _assert_bytes_eq(got, g.bytes(), "JoinGroup response v" + String(v))


# =============================================================================
# §2 — SyncGroup (api_key 14).
# =============================================================================


def _sg_req_v1() raises -> List[UInt8]:
    var g = _Golden()
    g.add("000e")  # RequestApiKey = 14
    g.add("0001")  # RequestApiVersion = 1
    g.add("00000051")  # CorrelationId = 81
    g.add("0001 63")  # ClientId = "c"
    g.add("0002 6731")  # GroupId string = "g1"
    g.add("00000002")  # GenerationId int32 = 2
    g.add("0002 6d31")  # MemberId string = "m1"
    g.add("00000002")  # Assignments array length = 2
    g.add("0002 6d31")  #   [0] MemberId = "m1"
    g.add("00000002 0102")  #   [0] Assignment bytes = 01 02
    g.add("0002 6d32")  #   [1] MemberId = "m2"
    g.add("00000000")  #   [1] Assignment bytes = (empty)
    return g.bytes()


def _sg_req_v2() raises -> List[UInt8]:
    var g = _Golden()
    g.add("000e")  # RequestApiKey = 14
    g.add("0002")  # RequestApiVersion = 2 (same layout as v1)
    g.add("00000052")  # CorrelationId = 82
    g.add("ffff")  # ClientId = null
    g.add("0002 6731")  # GroupId = "g1"
    g.add("ffffffff")  # GenerationId = -1
    g.add("0000")  # MemberId = ""
    g.add("00000000")  # Assignments array length = 0
    return g.bytes()


def _sg_req_v3() raises -> List[UInt8]:
    var g = _Golden()
    g.add("000e")  # RequestApiKey = 14
    g.add("0003")  # RequestApiVersion = 3
    g.add("00000053")  # CorrelationId = 83
    g.add("0001 63")  # ClientId = "c"
    g.add("0002 6731")  # GroupId = "g1"
    g.add("00000004")  # GenerationId = 4
    g.add("0002 6d32")  # MemberId = "m2"
    g.add("0002 6931")  # GroupInstanceId nullable string = "i1" (v3+)
    g.add("00000001")  # Assignments array length = 1
    g.add("0002 6d32")  #   [0] MemberId = "m2"
    g.add("00000001 09")  #   [0] Assignment bytes = 09
    return g.bytes()


def _decode_sg(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    _ = decode_sync_group_request(dec, h.api_version)
    return dec.pos()


def test_sync_group_request_v1() raises:
    var b = _sg_req_v1()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_key, API_KEY_SYNC_GROUP)
    assert_equal(h.api_version, Int16(1))
    assert_equal(h.correlation_id, Int32(81))
    var r = decode_sync_group_request(dec, h.api_version)
    assert_equal(r.group_id, "g1")
    assert_equal(r.generation_id, Int32(2))
    assert_equal(r.member_id, "m1")
    assert_equal(len(r.assignments), 2)
    var a0 = r.assignments[0].copy()
    assert_equal(a0.member_id, "m1")
    assert_equal(len(a0.assignment), 2)
    assert_equal(a0.assignment[0], UInt8(1))
    assert_equal(a0.assignment[1], UInt8(2))
    assert_equal(r.assignments[1].member_id, "m2")
    assert_equal(len(r.assignments[1].assignment), 0)
    _every_prefix_refused(b, _decode_sg, "SyncGroup request v1")


def test_sync_group_request_v2() raises:
    var b = _sg_req_v2()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_version, Int16(2))
    var r = decode_sync_group_request(dec, h.api_version)
    assert_equal(r.group_id, "g1")
    assert_equal(r.generation_id, Int32(-1))
    assert_equal(r.member_id, "")
    assert_equal(len(r.assignments), 0)
    _every_prefix_refused(b, _decode_sg, "SyncGroup request v2")


def test_sync_group_request_v3() raises:
    var b = _sg_req_v3()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_version, Int16(3))
    var r = decode_sync_group_request(dec, h.api_version)
    assert_equal(r.group_id, "g1")
    assert_equal(r.generation_id, Int32(4))
    assert_equal(r.member_id, "m2")
    # GroupInstanceId is read and discarded (the struct has no field for it);
    # the assignment after it decoding right is what proves it was consumed.
    assert_equal(len(r.assignments), 1)
    assert_equal(r.assignments[0].member_id, "m2")
    assert_equal(len(r.assignments[0].assignment), 1)
    assert_equal(r.assignments[0].assignment[0], UInt8(9))
    assert_equal(dec.remaining(), 0)
    _every_prefix_refused(b, _decode_sg, "SyncGroup request v3")


def test_sync_group_response_v0() raises:
    var g = _Golden()
    g.add("00000050")  # CorrelationId = 80
    # v0: no ThrottleTimeMs (v1+)
    g.add("001b")  # ErrorCode int16 = 27
    g.add("00000000")  # Assignment bytes = (empty)
    var got = encode_sync_group_response(
        Int32(80), Int16(0), Int16(27), List[UInt8]()
    )
    _assert_bytes_eq(got, g.bytes(), "SyncGroup response v0")


def test_sync_group_response_v1_v3() raises:
    for v in range(1, 4):
        var g = _Golden()
        g.add("00000051")  # CorrelationId = 81
        g.add("00000000")  # ThrottleTimeMs int32 = 0 (v1+)
        g.add("0000")  # ErrorCode = 0
        g.add("00000003 010203")  # Assignment bytes = 01 02 03
        var asg = List[UInt8]()
        asg.append(1)
        asg.append(2)
        asg.append(3)
        var got = encode_sync_group_response(
            Int32(81), Int16(v), Int16(0), asg
        )
        _assert_bytes_eq(got, g.bytes(), "SyncGroup response v" + String(v))


# =============================================================================
# §3 — Heartbeat (api_key 12).
# =============================================================================


def _hb_req(version: Int) raises -> List[UInt8]:
    # v0..v2 share one layout (GroupInstanceId is v3+).
    var g = _Golden()
    g.add("000c")  # RequestApiKey = 12
    g.add("000" + String(version))  # RequestApiVersion
    g.add("00000061")  # CorrelationId = 97
    g.add("0001 63")  # ClientId = "c"
    g.add("0002 6731")  # GroupId string = "g1"
    g.add("00000002")  # GenerationId int32 = 2
    g.add("0002 6d31")  # MemberId string = "m1"
    return g.bytes()


def _decode_hb(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    _ = parse_request_header(dec, False)
    _ = decode_heartbeat_request(dec)
    return dec.pos()


def test_heartbeat_request_v1_v2() raises:
    for v in range(1, 3):
        var b = _hb_req(v)
        var dec = KafkaDecoder(Span(b))
        var h = parse_request_header(dec, False)
        assert_equal(h.api_key, API_KEY_HEARTBEAT)
        assert_equal(h.api_version, Int16(v))
        assert_equal(h.correlation_id, Int32(97))
        var r = decode_heartbeat_request(dec)
        assert_equal(r.group_id, "g1")
        assert_equal(r.generation_id, Int32(2))
        assert_equal(r.member_id, "m1")
        _every_prefix_refused(
            b, _decode_hb, "Heartbeat request v" + String(v)
        )


def test_heartbeat_response() raises:
    var g0 = _Golden()
    g0.add("00000060")  # CorrelationId = 96
    g0.add("0019")  # ErrorCode int16 = 25 (v0: no ThrottleTimeMs)
    _assert_bytes_eq(
        encode_heartbeat_response(Int32(96), Int16(0), Int16(25)),
        g0.bytes(),
        "Heartbeat response v0",
    )
    for v in range(1, 3):
        var g = _Golden()
        g.add("00000061")  # CorrelationId = 97
        g.add("00000000")  # ThrottleTimeMs int32 = 0 (v1+)
        g.add("001b")  # ErrorCode = 27
        _assert_bytes_eq(
            encode_heartbeat_response(Int32(97), Int16(v), Int16(27)),
            g.bytes(),
            "Heartbeat response v" + String(v),
        )


# =============================================================================
# §4 — LeaveGroup (api_key 13).
# =============================================================================


def _lg_req(version: Int) raises -> List[UInt8]:
    # v0..v2: top-level MemberId (the Members array is v3+).
    var g = _Golden()
    g.add("000d")  # RequestApiKey = 13
    g.add("000" + String(version))  # RequestApiVersion
    g.add("00000071")  # CorrelationId = 113
    g.add("ffff")  # ClientId = null
    g.add("0002 6731")  # GroupId string = "g1"
    g.add("0002 6d32")  # MemberId string = "m2"
    return g.bytes()


def _decode_lg(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    _ = parse_request_header(dec, False)
    _ = decode_leave_group_request(dec)
    return dec.pos()


def test_leave_group_request_v1_v2() raises:
    for v in range(1, 3):
        var b = _lg_req(v)
        var dec = KafkaDecoder(Span(b))
        var h = parse_request_header(dec, False)
        assert_equal(h.api_key, API_KEY_LEAVE_GROUP)
        assert_equal(h.api_version, Int16(v))
        var r = decode_leave_group_request(dec)
        assert_equal(r.group_id, "g1")
        assert_equal(r.member_id, "m2")
        _every_prefix_refused(
            b, _decode_lg, "LeaveGroup request v" + String(v)
        )


def test_leave_group_response() raises:
    var g0 = _Golden()
    g0.add("00000070")  # CorrelationId = 112
    g0.add("0000")  # ErrorCode = 0 (v0: no ThrottleTimeMs)
    _assert_bytes_eq(
        encode_leave_group_response(Int32(112), Int16(0), Int16(0)),
        g0.bytes(),
        "LeaveGroup response v0",
    )
    for v in range(1, 3):
        var g = _Golden()
        g.add("00000071")  # CorrelationId = 113
        g.add("00000000")  # ThrottleTimeMs int32 = 0 (v1+)
        g.add("0019")  # ErrorCode = 25
        _assert_bytes_eq(
            encode_leave_group_response(Int32(113), Int16(v), Int16(25)),
            g.bytes(),
            "LeaveGroup response v" + String(v),
        )


def main() raises:
    test_join_group_request_v0()
    test_join_group_request_v1()
    test_join_group_request_v2()
    test_join_group_request_v3_v4()
    test_join_group_response_v0()
    test_join_group_response_v1()
    test_join_group_response_v2()
    test_join_group_response_v3_v4()
    test_sync_group_request_v1()
    test_sync_group_request_v2()
    test_sync_group_request_v3()
    test_sync_group_response_v0()
    test_sync_group_response_v1_v3()
    test_heartbeat_request_v1_v2()
    test_heartbeat_response()
    test_leave_group_request_v1_v2()
    test_leave_group_response()
    print("test_kafka_golden_group_apis: OK")
