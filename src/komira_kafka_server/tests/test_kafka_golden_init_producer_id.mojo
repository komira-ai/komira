# =============================================================================
# test_kafka_golden_init_producer_id.mojo — InitProducerId (api_key 22)
# against independent reference bytes
# =============================================================================
#
# Every reference message below is assembled by hand from the Apache Kafka
# message schemas (tag 3.9.0, clients/src/main/resources/common/message/):
# RequestHeader.json, ResponseHeader.json, InitProducerIdRequest.json,
# InitProducerIdResponse.json. Provenance and license: tests/GOLDENS.md.
#
# The schemas give "validVersions": "0-5" and "flexibleVersions": "2+":
#   * v0 and v1: request header v1, NULLABLE_STRING TransactionalId, response
#     header v0, no tag buffers ("Version 1 is the same as version 0").
#   * v2+: request header v2 (ClientId stays a non-compact nullable string,
#     then a tag buffer), COMPACT_NULLABLE_STRING TransactionalId, a body tag
#     buffer, response header v1 and a response body tag buffer.
#   * v3+: the request carries ProducerId (int64) and ProducerEpoch (int16).
#   * v4, v5: new error codes only; the bytes are the v3 bytes.
# Every version has a request reference (decoded, every field asserted,
# consumed exactly, every strict prefix refused) and a response reference
# (encoded from the field values, compared byte for byte). Versions outside
# 0..5 are refused with an exact message by the decoder and the encoder.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_kafka_server.wire.wire import KafkaDecoder
from komira_kafka_server.wire.messages import parse_request_header
from komira_kafka_server.wire.init_producer_id import (
    API_KEY_INIT_PRODUCER_ID,
    ERROR_INVALID_PRODUCER_EPOCH,
    INIT_PRODUCER_ID_MAX_VERSION,
    decode_init_producer_id_request,
    encode_init_producer_id_response,
    init_producer_id_is_flexible,
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


# -----------------------------------------------------------------------------
# Requests. v0..v1: request header v1, non-flexible body.
# -----------------------------------------------------------------------------


def _ipi_req_v0() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0016")  # RequestApiKey = 22
    g.add("0000")  # RequestApiVersion = 0
    g.add("00000090")  # CorrelationId = 144
    g.add("ffff")  # ClientId = null
    # InitProducerIdRequest v0
    g.add("0003 747831")  # TransactionalId nullable string = "tx1"
    g.add("00007530")  # TransactionTimeoutMs int32 = 30000
    return g.bytes()


def _ipi_req_v1() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0016")  # RequestApiKey = 22
    g.add("0001")  # RequestApiVersion = 1
    g.add("00000091")  # CorrelationId = 145
    g.add("0001 63")  # ClientId = "c"
    # InitProducerIdRequest v1 (same as v0)
    g.add("ffff")  # TransactionalId = null (idempotent, non-transactional)
    g.add("0000ea60")  # TransactionTimeoutMs = 60000
    return g.bytes()


def _decode_ipi_v1_header(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    _ = decode_init_producer_id_request(dec, h.api_version)
    return dec.pos()


def _decode_ipi_v2_header(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, True)
    _ = decode_init_producer_id_request(dec, h.api_version)
    return dec.pos()


def test_init_producer_id_request_v0() raises:
    var b = _ipi_req_v0()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, init_producer_id_is_flexible(0))
    assert_equal(h.api_key, API_KEY_INIT_PRODUCER_ID)
    assert_equal(h.api_version, Int16(0))
    assert_equal(h.correlation_id, Int32(144))
    var r = decode_init_producer_id_request(dec, h.api_version)
    assert_equal(r.transactional_id.value(), "tx1")
    assert_equal(r.transaction_timeout_ms, Int32(30000))
    assert_equal(r.producer_id, Int64(-1))  # not on the wire below v3
    assert_equal(r.producer_epoch, Int16(-1))
    assert_equal(dec.remaining(), 0)
    _every_prefix_refused(b, _decode_ipi_v1_header, "InitProducerId request v0")


def test_init_producer_id_request_v1() raises:
    var b = _ipi_req_v1()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, init_producer_id_is_flexible(1))
    assert_equal(h.api_version, Int16(1))
    assert_equal(h.correlation_id, Int32(145))
    assert_equal(h.client_id.value(), "c")
    var r = decode_init_producer_id_request(dec, h.api_version)
    assert_false(Bool(r.transactional_id))
    assert_equal(r.transaction_timeout_ms, Int32(60000))
    assert_equal(r.producer_id, Int64(-1))
    assert_equal(r.producer_epoch, Int16(-1))
    assert_equal(dec.remaining(), 0)
    _every_prefix_refused(b, _decode_ipi_v1_header, "InitProducerId request v1")


# -----------------------------------------------------------------------------
# Requests. v2+: request header v2, flexible body.
# -----------------------------------------------------------------------------


def _ipi_req_v2() raises -> List[UInt8]:
    var g = _Golden()
    # RequestHeader v2 (flexible): ClientId stays a non-compact nullable
    # string ("flexibleVersions": "none" on that field), then a tag buffer.
    g.add("0016")  # RequestApiKey = 22
    g.add("0002")  # RequestApiVersion = 2
    g.add("00000092")  # CorrelationId = 146
    g.add("0001 63")  # ClientId = "c"
    g.add("00")  # header TAG_BUFFER: 0 tagged fields
    # InitProducerIdRequest v2
    g.add("04 747831")  # TransactionalId COMPACT_NULLABLE_STRING = "tx1"
    g.add("0000ea60")  # TransactionTimeoutMs int32 = 60000
    g.add("00")  # body TAG_BUFFER: 0 tagged fields
    return g.bytes()


def _ipi_req_v3() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0016")  # RequestApiKey = 22
    g.add("0003")  # RequestApiVersion = 3
    g.add("00000093")  # CorrelationId = 147
    g.add("ffff")  # ClientId = null
    g.add("00")  # header TAG_BUFFER
    # InitProducerIdRequest v3
    g.add("00")  # TransactionalId COMPACT_NULLABLE_STRING = null
    g.add("00007530")  # TransactionTimeoutMs = 30000
    g.add("000000000000abcd")  # ProducerId int64 = 43981 (v3+)
    g.add("0003")  # ProducerEpoch int16 = 3 (v3+)
    g.add("00")  # body TAG_BUFFER
    return g.bytes()


def _ipi_req_v4() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0016")  # RequestApiKey = 22
    g.add("0004")  # RequestApiVersion = 4
    g.add("00000094")  # CorrelationId = 148
    g.add("0001 63")  # ClientId = "c"
    g.add("00")  # header TAG_BUFFER
    # InitProducerIdRequest v4 (same fields as v3)
    g.add("04 747831")  # TransactionalId = "tx1"
    g.add("0000ea60")  # TransactionTimeoutMs = 60000
    g.add("ffffffffffffffff")  # ProducerId = -1 (the schema default)
    g.add("ffff")  # ProducerEpoch = -1
    # body TAG_BUFFER with one tagged field this schema does not define
    # (tag 7, 2 bytes); a receiver skips unknown tagged fields (KIP-482).
    g.add("01")  # tagged field count = 1
    g.add("07 02 abcd")  # tag = 7, size = 2, data
    return g.bytes()


def _ipi_req_v5() raises -> List[UInt8]:
    var g = _Golden()
    g.add("0016")  # RequestApiKey = 22
    g.add("0005")  # RequestApiVersion = 5
    g.add("00000095")  # CorrelationId = 149
    g.add("0001 63")  # ClientId = "c"
    g.add("00")  # header TAG_BUFFER
    # InitProducerIdRequest v5 (same fields as v3)
    g.add("04 747832")  # TransactionalId = "tx2"
    g.add("0000ea60")  # TransactionTimeoutMs = 60000
    g.add("0000000000001234")  # ProducerId = 4660
    g.add("0007")  # ProducerEpoch = 7
    g.add("00")  # body TAG_BUFFER
    return g.bytes()


def test_init_producer_id_request_v2() raises:
    var b = _ipi_req_v2()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, init_producer_id_is_flexible(2))
    assert_equal(h.api_key, API_KEY_INIT_PRODUCER_ID)
    assert_equal(h.api_version, Int16(2))
    assert_equal(h.correlation_id, Int32(146))
    assert_equal(h.client_id.value(), "c")
    var r = decode_init_producer_id_request(dec, h.api_version)
    assert_equal(r.transactional_id.value(), "tx1")
    assert_equal(r.transaction_timeout_ms, Int32(60000))
    assert_equal(r.producer_id, Int64(-1))  # not on the wire below v3
    assert_equal(r.producer_epoch, Int16(-1))
    assert_equal(dec.remaining(), 0)
    _every_prefix_refused(b, _decode_ipi_v2_header, "InitProducerId request v2")


def test_init_producer_id_request_v3() raises:
    var b = _ipi_req_v3()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, init_producer_id_is_flexible(3))
    assert_equal(h.api_version, Int16(3))
    assert_equal(h.correlation_id, Int32(147))
    assert_false(Bool(h.client_id))
    var r = decode_init_producer_id_request(dec, h.api_version)
    assert_false(Bool(r.transactional_id))
    assert_equal(r.transaction_timeout_ms, Int32(30000))
    assert_equal(r.producer_id, Int64(43981))
    assert_equal(r.producer_epoch, Int16(3))
    assert_equal(dec.remaining(), 0)
    _every_prefix_refused(b, _decode_ipi_v2_header, "InitProducerId request v3")


def test_init_producer_id_request_v4_skips_unknown_tag() raises:
    var b = _ipi_req_v4()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, init_producer_id_is_flexible(4))
    assert_equal(h.api_version, Int16(4))
    assert_equal(h.correlation_id, Int32(148))
    var r = decode_init_producer_id_request(dec, h.api_version)
    assert_equal(r.transactional_id.value(), "tx1")
    assert_equal(r.transaction_timeout_ms, Int32(60000))
    assert_equal(r.producer_id, Int64(-1))
    assert_equal(r.producer_epoch, Int16(-1))
    assert_equal(dec.remaining(), 0)
    _every_prefix_refused(b, _decode_ipi_v2_header, "InitProducerId request v4")


def test_init_producer_id_request_v5() raises:
    var b = _ipi_req_v5()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, init_producer_id_is_flexible(5))
    assert_equal(h.api_version, Int16(5))
    assert_equal(h.correlation_id, Int32(149))
    var r = decode_init_producer_id_request(dec, h.api_version)
    assert_equal(r.transactional_id.value(), "tx2")
    assert_equal(r.transaction_timeout_ms, Int32(60000))
    assert_equal(r.producer_id, Int64(4660))
    assert_equal(r.producer_epoch, Int16(7))
    assert_equal(dec.remaining(), 0)
    _every_prefix_refused(b, _decode_ipi_v2_header, "InitProducerId request v5")


def test_v2_reference_is_the_flexible_form() raises:
    """Checks the v2 references with the primitive decoder only, so the
    reference bytes are confirmed independently of the codec under test."""
    var b = _ipi_req_v2()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, True)
    assert_equal(h.api_version, Int16(2))
    assert_equal(dec.get_compact_nullable_string().value(), "tx1")
    assert_equal(dec.get_int32(), Int32(60000))
    dec.skip_tag_buffer()
    assert_equal(dec.remaining(), 0)
    var rb = _ipi_resp_flexible()
    var rdec = KafkaDecoder(Span(rb))
    assert_equal(rdec.get_int32(), Int32(146))
    rdec.skip_tag_buffer()
    assert_equal(rdec.get_int32(), Int32(0))
    assert_equal(rdec.get_int16(), Int16(0))
    assert_equal(rdec.get_int64(), Int64(43981))
    assert_equal(rdec.get_int16(), Int16(3))
    rdec.skip_tag_buffer()
    assert_equal(rdec.remaining(), 0)


# -----------------------------------------------------------------------------
# Responses. v0..v1: response header v0; v2+: response header v1 + body tag
# buffer. The response body has the same four fields at every version.
# -----------------------------------------------------------------------------


def _ipi_resp_v0_v1() raises -> List[UInt8]:
    var g = _Golden()
    g.add("00000091")  # ResponseHeader v0: CorrelationId = 145
    g.add("00000000")  # ThrottleTimeMs int32 = 0
    g.add("0000")  # ErrorCode int16 = 0
    g.add("000000000000abcd")  # ProducerId int64 = 43981
    g.add("0003")  # ProducerEpoch int16 = 3
    return g.bytes()


def _ipi_resp_flexible() raises -> List[UInt8]:
    # v2..v5 responses are the same bytes; the encoder's version only picks
    # between this form and the v0/v1 form.
    var g = _Golden()
    g.add("00000092")  # ResponseHeader v1: CorrelationId = 146
    g.add("00")  # header TAG_BUFFER
    g.add("00000000")  # ThrottleTimeMs = 0
    g.add("0000")  # ErrorCode = 0
    g.add("000000000000abcd")  # ProducerId = 43981
    g.add("0003")  # ProducerEpoch = 3
    g.add("00")  # body TAG_BUFFER
    return g.bytes()


def test_init_producer_id_response_v0_v1() raises:
    for v in range(2):
        var got = encode_init_producer_id_response(
            Int32(145), Int16(v), Int16(0), Int64(43981), Int16(3)
        )
        _assert_bytes_eq(
            got, _ipi_resp_v0_v1(), "InitProducerId response v" + String(v)
        )


def test_init_producer_id_response_v2_to_v5() raises:
    for v in range(2, 6):
        var got = encode_init_producer_id_response(
            Int32(146), Int16(v), Int16(0), Int64(43981), Int16(3)
        )
        _assert_bytes_eq(
            got, _ipi_resp_flexible(), "InitProducerId response v" + String(v)
        )


def test_init_producer_id_response_error_v1() raises:
    var g = _Golden()
    g.add("00000092")  # CorrelationId = 146
    g.add("00000000")  # ThrottleTimeMs = 0
    g.add("002f")  # ErrorCode = 47 (INVALID_PRODUCER_EPOCH)
    g.add("ffffffffffffffff")  # ProducerId = -1
    g.add("ffff")  # ProducerEpoch = -1
    var got = encode_init_producer_id_response(
        Int32(146), Int16(1), ERROR_INVALID_PRODUCER_EPOCH, Int64(-1), Int16(-1)
    )
    _assert_bytes_eq(got, g.bytes(), "InitProducerId response v1 (error)")


def test_init_producer_id_response_error_v3() raises:
    var g = _Golden()
    g.add("00000093")  # ResponseHeader v1: CorrelationId = 147
    g.add("00")  # header TAG_BUFFER
    g.add("00000000")  # ThrottleTimeMs = 0
    g.add("002f")  # ErrorCode = 47 (INVALID_PRODUCER_EPOCH)
    g.add("ffffffffffffffff")  # ProducerId = -1
    g.add("ffff")  # ProducerEpoch = -1
    g.add("00")  # body TAG_BUFFER
    var got = encode_init_producer_id_response(
        Int32(147), Int16(3), ERROR_INVALID_PRODUCER_EPOCH, Int64(-1), Int16(-1)
    )
    _assert_bytes_eq(got, g.bytes(), "InitProducerId response v3 (error)")


# -----------------------------------------------------------------------------
# Version range.
# -----------------------------------------------------------------------------


def test_flexible_from_v2() raises:
    assert_false(init_producer_id_is_flexible(0))
    assert_false(init_producer_id_is_flexible(1))
    for v in range(2, Int(INIT_PRODUCER_ID_MAX_VERSION) + 1):
        assert_true(init_producer_id_is_flexible(Int16(v)), String(v))
    assert_equal(INIT_PRODUCER_ID_MAX_VERSION, Int16(5))


def _decode_err(api_version: Int16) raises -> String:
    var b = _ipi_req_v5()
    var dec = KafkaDecoder(Span(b))
    _ = parse_request_header(dec, True)
    try:
        _ = decode_init_producer_id_request(dec, api_version)
    except e:
        return String(e)
    return String("<accepted>")


def _encode_err(api_version: Int16) raises -> String:
    try:
        _ = encode_init_producer_id_response(
            Int32(1), api_version, Int16(0), Int64(1), Int16(0)
        )
    except e:
        return String(e)
    return String("<accepted>")


def test_unsupported_versions_refused() raises:
    assert_equal(
        _decode_err(Int16(6)),
        "komira_kafka_server.wire: InitProducerId version 6 is not supported"
        " (this codec serves v0..v5)",
    )
    assert_equal(
        _decode_err(Int16(-1)),
        "komira_kafka_server.wire: InitProducerId version -1 is not supported"
        " (this codec serves v0..v5)",
    )
    assert_equal(
        _encode_err(Int16(6)),
        "komira_kafka_server.wire: InitProducerId version 6 is not supported"
        " (this codec serves v0..v5)",
    )
    assert_equal(
        _encode_err(Int16(-1)),
        "komira_kafka_server.wire: InitProducerId version -1 is not supported"
        " (this codec serves v0..v5)",
    )


def main() raises:
    test_init_producer_id_request_v0()
    test_init_producer_id_request_v1()
    test_init_producer_id_request_v2()
    test_init_producer_id_request_v3()
    test_init_producer_id_request_v4_skips_unknown_tag()
    test_init_producer_id_request_v5()
    test_v2_reference_is_the_flexible_form()
    test_init_producer_id_response_v0_v1()
    test_init_producer_id_response_v2_to_v5()
    test_init_producer_id_response_error_v1()
    test_init_producer_id_response_error_v3()
    test_flexible_from_v2()
    test_unsupported_versions_refused()
    print("test_kafka_golden_init_producer_id: OK")
