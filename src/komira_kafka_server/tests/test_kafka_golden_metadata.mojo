# Metadata v4, v5..v8 and v9 responses and the v9 request, the ApiVersions
# request below v3 and response v1/v2, and the framing refusal, against
# reference bytes written by hand from the Apache Kafka message schemas
# (MetadataRequest.json, MetadataResponse.json, ApiVersionsRequest.json,
# ApiVersionsResponse.json at tag 3.9.0; provenance in GOLDENS.md).
#
# One cluster is encoded at every Metadata version: broker 1 "kb":9092,
# controller 1, a topic "t1" with two partitions and an explicit leader map
# [1, 2], and an internal topic "in" with one partition and no map, which
# reports the encoder's fallback leader 7. So each golden checks the
# per-partition leader map and the fallback, and each version's added fields:
# leader_epoch (v7+), offline_replicas (v5+), the authorized operations (v8+),
# and at v9 the compact forms and tag buffers.
#
# A leaderless partition (map entry -1) is deliberately not encoded here: the
# encoder reports it with error_code 0 and replicas/isr [-1], which the
# MetadataResponse schema does not allow (komira-ai/komira#1034), so no golden
# pins those bytes. The -1 entry takes the same lines as any other leader.

from std.testing import assert_equal, assert_false, assert_true

from komira_kafka_server.wire.messages import (
    ApiVersionRange,
    MetadataBroker,
    MetadataTopic,
    decode_api_versions_request_body,
    decode_metadata_request_body_v9,
    encode_api_versions_response,
    encode_metadata_response_v1,
    encode_metadata_response_v4,
    encode_metadata_response_v5_to_v8,
    encode_metadata_response_v9,
    read_framed_message,
)
from komira_kafka_server.wire.wire import KafkaDecoder


def _hex(s: String) -> List[UInt8]:
    """Bytes from hex digits; anything else (spaces, `|`) separates them."""
    var b = s.as_bytes()
    var out = List[UInt8]()
    var hi = -1
    for i in range(len(b)):
        var c = Int(b[i])
        var v = -1
        if c >= 48 and c <= 57:
            v = c - 48
        elif c >= 97 and c <= 102:
            v = c - 87
        if v < 0:
            continue
        if hi < 0:
            hi = v
        else:
            out.append(UInt8(hi * 16 + v))
            hi = -1
    return out^


def _assert_bytes_eq(got: List[UInt8], want: List[UInt8], ctx: String) raises:
    assert_equal(len(got), len(want), ctx + ": length")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), ctx + ": byte " + String(i))


def _brokers() -> List[MetadataBroker]:
    var out = List[MetadataBroker]()
    out.append(MetadataBroker(Int32(1), String("kb"), Int32(9092)))
    return out^


def _topics() -> List[MetadataTopic]:
    var leaders = List[Int32]()
    leaders.append(Int32(1))
    leaders.append(Int32(2))
    var out = List[MetadataTopic]()
    out.append(MetadataTopic(String("t1"), 2, False, leaders^))
    out.append(MetadataTopic(String("in"), 1, True))
    return out^


def _nonflexible_golden(version: Int) -> String:
    """The Metadata response at `version` (1, or 4 through 8), header v0."""
    var epoch = String(" 00 00 00 00") if version >= 7 else String("")
    var offline = String(" 00 00 00 00") if version >= 5 else String("")
    var topic_ops = String(" 80 00 00 00") if version >= 8 else String("")
    var s = String("00 00 00 0a")  # correlation_id 10
    if version >= 3:
        s += " 00 00 00 00"  # throttle_time_ms
    s += " 00 00 00 01"  # brokers: 1
    s += " 00 00 00 01 | 00 02 6b 62 | 00 00 23 84 | ff ff"  # 1 "kb" 9092 rack null
    if version >= 2:
        s += " ff ff"  # cluster_id null
    s += " 00 00 00 01"  # controller_id 1
    s += " 00 00 00 02"  # topics: 2
    s += " 00 00 | 00 02 74 31 | 00 | 00 00 00 02"  # "t1", not internal, 2 parts
    s += " 00 00 | 00 00 00 00 | 00 00 00 01" + epoch  # p0, leader 1
    s += " 00 00 00 01 00 00 00 01 | 00 00 00 01 00 00 00 01" + offline
    s += " 00 00 | 00 00 00 01 | 00 00 00 02" + epoch  # p1, leader 2
    s += " 00 00 00 01 00 00 00 02 | 00 00 00 01 00 00 00 02" + offline
    s += topic_ops
    s += " 00 00 | 00 02 69 6e | 01 | 00 00 00 01"  # "in", internal, 1 part
    s += " 00 00 | 00 00 00 00 | 00 00 00 07" + epoch  # p0, fallback 7
    s += " 00 00 00 01 00 00 00 07 | 00 00 00 01 00 00 00 07" + offline
    s += topic_ops
    if version >= 8:
        s += " 80 00 00 00"  # cluster_authorized_operations
    return s


def test_metadata_response_v1_leader_map() raises:
    var got = encode_metadata_response_v1(
        Int32(10), _brokers(), Int32(1), _topics(), Int32(7)
    )
    _assert_bytes_eq(got, _hex(_nonflexible_golden(1)), "v1")


def test_metadata_response_v4() raises:
    var got = encode_metadata_response_v4(
        Int32(10), _brokers(), Int32(1), _topics(), Int32(7)
    )
    _assert_bytes_eq(got, _hex(_nonflexible_golden(4)), "v4")


def test_metadata_response_v5_to_v8() raises:
    for v in range(5, 9):
        var got = encode_metadata_response_v5_to_v8(
            Int32(10), Int16(v), _brokers(), Int32(1), _topics(), Int32(7)
        )
        _assert_bytes_eq(got, _hex(_nonflexible_golden(v)), "v" + String(v))


def test_metadata_response_v9() raises:
    var got = encode_metadata_response_v9(
        Int32(10), _brokers(), Int32(1), _topics(), Int32(7)
    )
    var want = _hex(
        "00 00 00 0a 00"  # correlation_id 10, header tag buffer
        " 00 00 00 00"  # throttle_time_ms
        " 02"  # brokers: 1
        " 00 00 00 01 | 03 6b 62 | 00 00 23 84 | 00 | 00"  # rack null, tags
        " 00"  # cluster_id null
        " 00 00 00 01"  # controller_id
        " 03"  # topics: 2
        " 00 00 | 03 74 31 | 00 | 03"  # "t1", 2 partitions
        " 00 00 | 00 00 00 00 | 00 00 00 01 | 00 00 00 00"  # p0 leader 1, epoch
        " 02 00 00 00 01 | 02 00 00 00 01 | 01 | 00"  # replicas, isr, offline
        " 00 00 | 00 00 00 01 | 00 00 00 02 | 00 00 00 00"  # p1 leader 2
        " 02 00 00 00 02 | 02 00 00 00 02 | 01 | 00"
        " 80 00 00 00 | 00"  # topic_authorized_operations, tags
        " 00 00 | 03 69 6e | 01 | 02"  # "in", internal, 1 partition
        " 00 00 | 00 00 00 00 | 00 00 00 07 | 00 00 00 00"  # p0 fallback 7
        " 02 00 00 00 07 | 02 00 00 00 07 | 01 | 00"
        " 80 00 00 00 | 00"
        " 80 00 00 00"  # cluster_authorized_operations
        " 00"  # top-level tag buffer
    )
    _assert_bytes_eq(got, want, "v9")


def test_metadata_copies() raises:
    var t = _topics()
    var c = t[0].copy()
    t[0].partition_leaders[1] = Int32(5)
    assert_equal(c.name, String("t1"), "topic name")
    assert_equal(c.num_partitions, 2, "partitions")
    assert_false(c.is_internal, "internal")
    assert_equal(len(c.partition_leaders), 2, "map length")
    assert_equal(Int(c.partition_leaders[1]), 2, "the copy's map is its own")
    var b = _brokers()[0].copy()
    assert_equal(Int(b.node_id), 1, "node")
    assert_equal(b.host, String("kb"), "host")
    assert_equal(Int(b.port), 9092, "port")


# -----------------------------------------------------------------------------
# The v9 request: topics COMPACT_ARRAY of {name, tags}, three booleans, tags.
# At v9 a topic name is not nullable (MetadataRequest.json: Name
# "nullableVersions": "10+"); the decoder accepts and skips a null name
# (komira-ai/komira#1033), so no input here carries one.
# -----------------------------------------------------------------------------
def test_metadata_request_v9_named() raises:
    var b = _hex(
        "03"  # topics: 2
        " 03 74 31 | 00"  # "t1", no tags
        " 02 61 | 01 00 01 ff"  # "a", one tagged field (tag 0, 1 byte)
        " 01 00 01"  # allow_auto_topic_creation, include_cluster_ops, include_topic_ops
        " 00"  # tags
    )
    var dec = KafkaDecoder(Span(b))
    var req = decode_metadata_request_body_v9(dec)
    assert_equal(dec.remaining(), 0, "consumed")
    assert_true(Bool(req.topics), "named")
    ref names = req.topics.value()
    assert_equal(len(names), 2, "two names")
    assert_equal(names[0], String("t1"), "name 0")
    assert_equal(names[1], String("a"), "name 1")
    for cut in range(len(b)):
        var short = List[UInt8]()
        for i in range(cut):
            short.append(b[i])
        var d = KafkaDecoder(Span(short))
        var refused = False
        try:
            _ = decode_metadata_request_body_v9(d)
        except:
            refused = True
        assert_true(refused, "prefix " + String(cut) + " accepted")


def test_metadata_request_v9_all_topics() raises:
    var b = _hex("00 | 01 01 00 | 01 05 01 aa")  # null topics; one tagged field
    var dec = KafkaDecoder(Span(b))
    var req = decode_metadata_request_body_v9(dec)
    assert_false(Bool(req.topics), "null array is all topics")
    assert_equal(dec.remaining(), 0, "consumed")
    for cut in range(len(b)):
        var short = List[UInt8]()
        for i in range(cut):
            short.append(b[i])
        var d = KafkaDecoder(Span(short))
        var refused = False
        try:
            _ = decode_metadata_request_body_v9(d)
        except:
            refused = True
        assert_true(refused, "prefix " + String(cut) + " accepted")


# -----------------------------------------------------------------------------
# ApiVersions below v3: the request body is empty; the response gains
# throttle_time_ms at v1.
# -----------------------------------------------------------------------------
def test_api_versions_request_below_v3_reads_nothing() raises:
    var b = _hex("00 00")  # not a body: nothing may be read at v0..v2
    for v in range(0, 3):
        var dec = KafkaDecoder(Span(b))
        var req = decode_api_versions_request_body(dec, Int16(v))
        assert_false(Bool(req.client_software_name), "no name")
        assert_false(Bool(req.client_software_version), "no version")
        assert_equal(dec.remaining(), 2, "nothing read at v" + String(v))


def test_api_versions_response_v1_v2() raises:
    var apis = List[ApiVersionRange]()
    apis.append(ApiVersionRange(Int16(18), Int16(0), Int16(3)))
    apis.append(ApiVersionRange(Int16(3), Int16(0), Int16(9)))
    var want = _hex(
        "00 00 00 03"  # correlation_id
        " 00 00"  # error_code
        " 00 00 00 02"  # api_keys: 2
        " 00 12 00 00 00 03"  # ApiVersions 0..3
        " 00 03 00 00 00 09"  # Metadata 0..9
        " 00 00 00 64"  # throttle_time_ms 100 (v1+)
    )
    for v in range(1, 3):
        var got = encode_api_versions_response(
            Int32(3), Int16(v), Int16(0), apis, Int32(100)
        )
        _assert_bytes_eq(got, want, "v" + String(v))


# -----------------------------------------------------------------------------
# Framing: a negative message_size is refused.
# -----------------------------------------------------------------------------
def test_framed_negative_size() raises:
    for raw in [String("ff ff ff ff"), String("80 00 00 00 01")]:
        var b = _hex(raw)
        var msg = String("<accepted>")
        try:
            _ = read_framed_message(Span(b))
        except e:
            msg = String(e)
        var size = String("-1") if len(b) == 4 else String("-2147483648")
        assert_equal(
            msg, "komira_kafka_server.wire: negative message_size " + size, raw
        )


def main() raises:
    test_metadata_response_v1_leader_map()
    test_metadata_response_v4()
    test_metadata_response_v5_to_v8()
    test_metadata_response_v9()
    test_metadata_copies()
    test_metadata_request_v9_named()
    test_metadata_request_v9_all_topics()
    test_api_versions_request_below_v3_reads_nothing()
    test_api_versions_response_v1_v2()
    test_framed_negative_size()
    print("test_kafka_golden_metadata: OK")
