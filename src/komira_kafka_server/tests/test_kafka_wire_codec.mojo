# =============================================================================
# test_kafka_wire_codec.mojo — Kafka wire-codec byte-exact unit tests
# =============================================================================
#
# NO live Kafka client — pure byte-exact assertions against
# the Apache Kafka protocol spec (fixed external spec) + round-trip equality.
#
# Coverage:
#   1. Primitives: INT8/16/32/64 big-endian byte-exact; UNSIGNED_VARINT
#      multi-byte; STRING / NULLABLE_STRING (null = -1) / COMPACT_STRING.
#   2. The framing length-prefix (INT32 message_size + payload).
#   3. Request header v1 + v2-flexible parse (api_key/version/correlation/
#      client_id), round-trip via a hand-built header.
#   4. ApiVersions response: byte-exact v0 (non-flexible) listing the
#      supported APIs + a v3 (flexible body, header v0 special case) decode.
#   5. Metadata response v1: a topic reporting N partitions, with the partition
#      count sourced from a BrokerTopicConfig-style num_partitions Int; decode
#      back + field-equal.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_kafka_server.wire.wire import KafkaEncoder, KafkaDecoder
from komira_kafka_server.wire.messages import (
    API_KEY_API_VERSIONS,
    API_KEY_METADATA,
    ERROR_NONE,
    RequestHeader,
    parse_request_header,
    ApiVersionRange,
    supported_api_versions,
    decode_api_versions_request_body,
    encode_api_versions_response,
    MetadataBroker,
    MetadataTopic,
    decode_metadata_request_body,
    encode_metadata_response_v1,
    frame_message,
    read_framed_message,
)


def _assert_bytes_eq(
    got: List[UInt8], want: List[UInt8], ctx: String
) raises:
    assert_equal(len(got), len(want), ctx + ": length mismatch")
    for i in range(len(want)):
        assert_equal(
            Int(got[i]),
            Int(want[i]),
            ctx + ": byte " + String(i) + " mismatch",
        )


# =============================================================================
# §1 — Primitives: big-endian byte-exactness.
# =============================================================================


def test_fixed_width_big_endian() raises:
    var enc = KafkaEncoder()
    enc.put_int8(Int8(0x12))
    enc.put_int16(Int16(0x1234))
    enc.put_int32(Int32(0x12345678))
    enc.put_int64(Int64(0x0102030405060708))
    var got = enc.take_bytes()

    var want = List[UInt8]()
    want.append(0x12)
    want.append(0x12)
    want.append(0x34)  # INT16 BE
    want.append(0x12)
    want.append(0x34)
    want.append(0x56)
    want.append(0x78)  # INT32 BE
    want.append(0x01)
    want.append(0x02)
    want.append(0x03)
    want.append(0x04)
    want.append(0x05)
    want.append(0x06)
    want.append(0x07)
    want.append(0x08)  # INT64 BE
    _assert_bytes_eq(got, want, "fixed-width BE")

    # Round-trip decode.
    var dec = KafkaDecoder(Span(got))
    assert_equal(Int(dec.get_int8()), 0x12, "int8 rt")
    assert_equal(Int(dec.get_int16()), 0x1234, "int16 rt")
    assert_equal(Int(dec.get_int32()), 0x12345678, "int32 rt")
    assert_equal(Int(dec.get_int64()), 0x0102030405060708, "int64 rt")


def test_negative_ints_two_complement() raises:
    var enc = KafkaEncoder()
    enc.put_int16(Int16(-1))  # 0xFFFF
    enc.put_int32(Int32(-1))  # 0xFFFFFFFF
    var got = enc.take_bytes()
    var want = List[UInt8]()
    for _ in range(2 + 4):
        want.append(0xFF)
    _assert_bytes_eq(got, want, "negative two's complement")

    var dec = KafkaDecoder(Span(got))
    assert_equal(Int(dec.get_int16()), -1, "int16 -1 rt")
    assert_equal(Int(dec.get_int32()), -1, "int32 -1 rt")


def test_unsigned_varint() raises:
    # Spec examples: 0 -> [0x00]; 1 -> [0x01]; 127 -> [0x7F];
    # 128 -> [0x80,0x01]; 300 -> [0xAC,0x02].
    var cases = List[UInt32]()
    cases.append(0)
    cases.append(1)
    cases.append(127)
    cases.append(128)
    cases.append(300)

    var enc = KafkaEncoder()
    for i in range(len(cases)):
        enc.put_unsigned_varint(cases[i])
    var got = enc.take_bytes()

    var want = List[UInt8]()
    want.append(0x00)
    want.append(0x01)
    want.append(0x7F)
    want.append(0x80)
    want.append(0x01)
    want.append(0xAC)
    want.append(0x02)
    _assert_bytes_eq(got, want, "unsigned varint")

    var dec = KafkaDecoder(Span(got))
    for i in range(len(cases)):
        assert_equal(
            Int(dec.get_unsigned_varint()),
            Int(cases[i]),
            "varint rt " + String(i),
        )


def test_string_forms() raises:
    var enc = KafkaEncoder()
    enc.put_string("kafka")  # STRING: 0x00 0x05 + "kafka"
    enc.put_nullable_string(Optional[String]())  # null: 0xFF 0xFF
    enc.put_nullable_string(Optional(String("x")))  # 0x00 0x01 'x'
    enc.put_compact_string("ab")  # varint(3)=0x03 + "ab"
    var got = enc.take_bytes()

    var want = List[UInt8]()
    # STRING "kafka"
    want.append(0x00)
    want.append(0x05)
    for c in String("kafka").as_bytes():
        want.append(c)
    # NULLABLE_STRING null
    want.append(0xFF)
    want.append(0xFF)
    # NULLABLE_STRING "x"
    want.append(0x00)
    want.append(0x01)
    want.append(UInt8(ord("x")))
    # COMPACT_STRING "ab"
    want.append(0x03)
    want.append(UInt8(ord("a")))
    want.append(UInt8(ord("b")))
    _assert_bytes_eq(got, want, "string forms")

    var dec = KafkaDecoder(Span(got))
    assert_equal(dec.get_string(), String("kafka"), "string rt")
    assert_false(Bool(dec.get_nullable_string()), "null nullable rt")
    var nx = dec.get_nullable_string()
    assert_true(Bool(nx), "present nullable rt")
    assert_equal(nx.value(), String("x"), "nullable value rt")
    assert_equal(dec.get_compact_string(), String("ab"), "compact rt")


# =============================================================================
# §2 — Framing length-prefix.
# =============================================================================


def test_framing_length_prefix() raises:
    var payload = List[UInt8]()
    payload.append(0xDE)
    payload.append(0xAD)
    payload.append(0xBE)
    var framed = frame_message(Span(payload))
    # INT32 size = 3 (BE) + payload.
    var want = List[UInt8]()
    want.append(0x00)
    want.append(0x00)
    want.append(0x00)
    want.append(0x03)
    want.append(0xDE)
    want.append(0xAD)
    want.append(0xBE)
    _assert_bytes_eq(framed, want, "frame prefix")

    var fm = read_framed_message(Span(framed))
    assert_equal(fm.size, 3, "framed size")
    _assert_bytes_eq(fm.payload, payload, "framed payload")


# =============================================================================
# §3 — Request header parse (v1 + v2-flexible).
# =============================================================================


def test_request_header_v1_parse() raises:
    # Hand-build a v1 request header: api_key=18, api_version=1,
    # correlation_id=42, client_id="cli".
    var enc = KafkaEncoder()
    enc.put_int16(API_KEY_API_VERSIONS)
    enc.put_int16(Int16(1))
    enc.put_int32(Int32(42))
    enc.put_nullable_string(Optional(String("cli")))
    var bytes = enc.take_bytes()

    var dec = KafkaDecoder(Span(bytes))
    var hdr = parse_request_header(dec, header_is_flexible=False)
    assert_equal(Int(hdr.api_key), 18, "v1 api_key")
    assert_equal(Int(hdr.api_version), 1, "v1 api_version")
    assert_equal(Int(hdr.correlation_id), 42, "v1 correlation_id")
    assert_true(Bool(hdr.client_id), "v1 client_id present")
    assert_equal(hdr.client_id.value(), String("cli"), "v1 client_id value")


def test_request_header_v2_flexible_parse() raises:
    # v2 header: same four fields + a trailing (empty) TAG_BUFFER.
    # client_id stays a REGULAR NULLABLE_STRING even in v2.
    var enc = KafkaEncoder()
    enc.put_int16(API_KEY_METADATA)
    enc.put_int16(Int16(9))
    enc.put_int32(Int32(7))
    enc.put_nullable_string(Optional[String]())  # null client_id
    enc.put_empty_tag_buffer()
    var bytes = enc.take_bytes()

    var dec = KafkaDecoder(Span(bytes))
    var hdr = parse_request_header(dec, header_is_flexible=True)
    assert_equal(Int(hdr.api_key), 3, "v2 api_key")
    assert_equal(Int(hdr.api_version), 9, "v2 api_version")
    assert_equal(Int(hdr.correlation_id), 7, "v2 correlation_id")
    assert_false(Bool(hdr.client_id), "v2 null client_id")
    assert_equal(dec.remaining(), 0, "v2 tag buffer consumed")


# =============================================================================
# §4 — ApiVersions response (byte-exact v0 + flexible v3 decode).
# =============================================================================


def test_api_versions_response_v0_byte_exact() raises:
    # Build a v0 response with a SINGLE advertised API to keep the byte string
    # short + hand-verifiable: correlation_id=99, error_code=0, one entry
    # {api_key=18, min=0, max=3}.
    var apis = List[ApiVersionRange]()
    apis.append(ApiVersionRange(API_KEY_API_VERSIONS, 0, 3))
    var msg = encode_api_versions_response(
        correlation_id=Int32(99),
        api_version=Int16(0),
        error_code=ERROR_NONE,
        apis=apis,
        throttle_time_ms=Int32(0),
    )

    var want = List[UInt8]()
    # response header v0: correlation_id INT32 = 99
    want.append(0x00)
    want.append(0x00)
    want.append(0x00)
    want.append(0x63)
    # error_code INT16 = 0
    want.append(0x00)
    want.append(0x00)
    # api_keys ARRAY (non-compact) length INT32 = 1
    want.append(0x00)
    want.append(0x00)
    want.append(0x00)
    want.append(0x01)
    # entry: api_key=18, min=0, max=3 (each INT16)
    want.append(0x00)
    want.append(0x12)
    want.append(0x00)
    want.append(0x00)
    want.append(0x00)
    want.append(0x03)
    # v0 has NO throttle_time_ms
    _assert_bytes_eq(want, msg, "ApiVersions v0 byte-exact")


def test_api_versions_response_v3_flexible_decode() raises:
    # Encode v3 (flexible body, header v0 special case) and decode it back,
    # asserting the structure round-trips. Header is v0 (bare correlation_id),
    # body is flexible (compact array + tag buffers + throttle_time).
    var apis = supported_api_versions()
    var msg = encode_api_versions_response(
        correlation_id=Int32(0x01020304),
        api_version=Int16(3),
        error_code=ERROR_NONE,
        apis=apis,
        throttle_time_ms=Int32(0),
    )

    var dec = KafkaDecoder(Span(msg))
    # response header v0 — NO tag buffer (the special case).
    assert_equal(
        Int(dec.get_int32()), 0x01020304, "v3 header correlation (bare)"
    )
    assert_equal(Int(dec.get_int16()), 0, "v3 error_code")
    var count = dec.get_compact_array_len()
    assert_equal(count, len(apis), "v3 compact api count")
    for i in range(count):
        assert_equal(Int(dec.get_int16()), Int(apis[i].api_key), "v3 key")
        assert_equal(Int(dec.get_int16()), Int(apis[i].min_version), "v3 min")
        assert_equal(Int(dec.get_int16()), Int(apis[i].max_version), "v3 max")
        dec.skip_tag_buffer()  # per-entry tag buffer
    assert_equal(Int(dec.get_int32()), 0, "v3 throttle_time")
    dec.skip_tag_buffer()  # response-level tag buffer
    assert_equal(dec.remaining(), 0, "v3 fully consumed")


def test_supported_api_set_advertises_handshake_apis() raises:
    var apis = supported_api_versions()
    var saw_api_versions = False
    var saw_metadata = False
    for i in range(len(apis)):
        if apis[i].api_key == API_KEY_API_VERSIONS:
            saw_api_versions = True
            assert_equal(Int(apis[i].max_version), 3, "ApiVersions max v3")
        if apis[i].api_key == API_KEY_METADATA:
            saw_metadata = True
            assert_equal(Int(apis[i].max_version), 9, "Metadata max v9")
    assert_true(saw_api_versions, "advertises ApiVersions")
    assert_true(saw_metadata, "advertises Metadata")


# =============================================================================
# §5 — Metadata response v1 (partition count from BrokerTopicConfig).
# =============================================================================


def test_metadata_response_v1_partition_count() raises:
    # A topic "orders" with num_partitions sourced from a BrokerTopicConfig-
    # style Int (3 here). Single-node placeholder: one broker, node_id=0.
    var brokers = List[MetadataBroker]()
    brokers.append(MetadataBroker(Int32(0), String("localhost"), Int32(9092)))

    var topics = List[MetadataTopic]()
    # `num_partitions` is exactly what BrokerTopicConfig.read_topic_config
    # supplies; the broker/server layer wires config.num_partitions here.
    var config_num_partitions = 3
    topics.append(
        MetadataTopic(String("orders"), config_num_partitions, False)
    )

    var msg = encode_metadata_response_v1(
        correlation_id=Int32(5),
        brokers=brokers,
        controller_id=Int32(0),
        topics=topics,
        leader_node_id=Int32(0),
    )

    # Decode + assert the topic reports exactly N partitions.
    var dec = KafkaDecoder(Span(msg))
    assert_equal(Int(dec.get_int32()), 5, "md correlation")
    # brokers
    var nb = dec.get_array_len()
    assert_equal(nb, 1, "md broker count")
    assert_equal(Int(dec.get_int32()), 0, "broker node_id")
    assert_equal(dec.get_string(), String("localhost"), "broker host")
    assert_equal(Int(dec.get_int32()), 9092, "broker port")
    assert_false(Bool(dec.get_nullable_string()), "broker rack null")
    # controller_id
    assert_equal(Int(dec.get_int32()), 0, "controller_id")
    # topics
    var nt = dec.get_array_len()
    assert_equal(nt, 1, "topic count")
    assert_equal(Int(dec.get_int16()), 0, "topic error_code")
    assert_equal(dec.get_string(), String("orders"), "topic name")
    assert_false(dec.get_bool(), "topic is_internal")
    # partitions: MUST equal config_num_partitions.
    var npart = dec.get_array_len()
    assert_equal(npart, config_num_partitions, "partition count == config")
    for pi in range(npart):
        assert_equal(Int(dec.get_int16()), 0, "part error_code")
        assert_equal(Int(dec.get_int32()), pi, "partition_index")
        assert_equal(Int(dec.get_int32()), 0, "leader_id")
        var nrep = dec.get_array_len()
        assert_equal(nrep, 1, "replica count")
        assert_equal(Int(dec.get_int32()), 0, "replica node")
        var nisr = dec.get_array_len()
        assert_equal(nisr, 1, "isr count")
        assert_equal(Int(dec.get_int32()), 0, "isr node")
    assert_equal(dec.remaining(), 0, "md fully consumed")


def test_metadata_request_decode_all_vs_named() raises:
    # null array == "all topics"
    var enc_all = KafkaEncoder()
    enc_all.put_array_len(-1)
    var all_bytes = enc_all.take_bytes()
    var dec_all = KafkaDecoder(Span(all_bytes))
    var req_all = decode_metadata_request_body(dec_all)
    assert_false(Bool(req_all.topics), "null array -> all topics")

    # named topics
    var enc_named = KafkaEncoder()
    enc_named.put_array_len(2)
    enc_named.put_string("a")
    enc_named.put_string("bb")
    var named_bytes = enc_named.take_bytes()
    var dec_named = KafkaDecoder(Span(named_bytes))
    var req_named = decode_metadata_request_body(dec_named)
    assert_true(Bool(req_named.topics), "named topics present")
    ref names = req_named.topics.value()
    assert_equal(len(names), 2, "two named topics")
    assert_equal(names[0], String("a"), "topic[0]")
    assert_equal(names[1], String("bb"), "topic[1]")


def test_api_versions_request_v3_body_decode() raises:
    # v3 request body: two COMPACT_STRINGs + a body tag buffer.
    var enc = KafkaEncoder()
    enc.put_compact_string("librdkafka")
    enc.put_compact_string("2.3.0")
    enc.put_empty_tag_buffer()
    var bytes = enc.take_bytes()
    var dec = KafkaDecoder(Span(bytes))
    var req = decode_api_versions_request_body(dec, Int16(3))
    assert_true(Bool(req.client_software_name), "v3 sw name present")
    assert_equal(
        req.client_software_name.value(),
        String("librdkafka"),
        "v3 sw name",
    )
    assert_equal(
        req.client_software_version.value(), String("2.3.0"), "v3 sw version"
    )


def main() raises:
    test_fixed_width_big_endian()
    test_negative_ints_two_complement()
    test_unsigned_varint()
    test_string_forms()
    test_framing_length_prefix()
    test_request_header_v1_parse()
    test_request_header_v2_flexible_parse()
    test_api_versions_response_v0_byte_exact()
    test_api_versions_response_v3_flexible_decode()
    test_supported_api_set_advertises_handshake_apis()
    test_metadata_response_v1_partition_count()
    test_metadata_request_decode_all_vs_named()
    test_api_versions_request_v3_body_decode()
    print("OK: komira_kafka_server.wire codec byte-exact unit tests passed")
