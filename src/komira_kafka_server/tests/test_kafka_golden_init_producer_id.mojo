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
# The codec (init_producer_id.mojo) states v1..v2 with one non-flexible body.
# The schema says "Version 1 is the same as version 0" and "Version 2 is the
# first flexible version" ("flexibleVersions": "2+"). So v0 and v1 are
# checked against the codec here. v2 is NOT: its reference below (request
# header v2 with a tag buffer, COMPACT_NULLABLE_STRING TransactionalId,
# trailing tag buffers, response header v1) disagrees with the codec, which
# reads and writes the v0/v1 bytes at every version.
# TODO(kafka-goldens): run the v2 reference through the codec once it handles
# the flexible v2 form; until then only the reference itself is checked
# (test_v2_reference_is_the_flexible_form).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_kafka_server.wire.wire import KafkaDecoder
from komira_kafka_server.wire.messages import parse_request_header
from komira_kafka_server.wire.init_producer_id import (
    API_KEY_INIT_PRODUCER_ID,
    ERROR_INVALID_PRODUCER_EPOCH,
    decode_init_producer_id_request,
    encode_init_producer_id_response,
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


def _decode_ipi(b: List[UInt8]) raises -> Int:
    var dec = KafkaDecoder(Span(b))
    _ = parse_request_header(dec, False)
    _ = decode_init_producer_id_request(dec)
    return dec.pos()


def test_init_producer_id_request_v0() raises:
    var b = _ipi_req_v0()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_key, API_KEY_INIT_PRODUCER_ID)
    assert_equal(h.api_version, Int16(0))
    assert_equal(h.correlation_id, Int32(144))
    var r = decode_init_producer_id_request(dec)
    assert_equal(r.transactional_id.value(), "tx1")
    assert_equal(r.transaction_timeout_ms, Int32(30000))
    assert_equal(dec.remaining(), 0)
    _every_prefix_refused(b, _decode_ipi, "InitProducerId request v0")


def test_init_producer_id_request_v1() raises:
    var b = _ipi_req_v1()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, False)
    assert_equal(h.api_version, Int16(1))
    assert_equal(h.correlation_id, Int32(145))
    assert_equal(h.client_id.value(), "c")
    var r = decode_init_producer_id_request(dec)
    assert_false(Bool(r.transactional_id))
    assert_equal(r.transaction_timeout_ms, Int32(60000))
    _every_prefix_refused(b, _decode_ipi, "InitProducerId request v1")


def test_init_producer_id_response_v0_v1() raises:
    # v0 and v1 responses are the same bytes; the encoder takes no version.
    var g = _Golden()
    g.add("00000091")  # ResponseHeader v0: CorrelationId = 145
    g.add("00000000")  # ThrottleTimeMs int32 = 0
    g.add("0000")  # ErrorCode int16 = 0
    g.add("000000000000abcd")  # ProducerId int64 = 43981
    g.add("0003")  # ProducerEpoch int16 = 3
    var got = encode_init_producer_id_response(
        Int32(145), Int16(0), Int64(43981), Int16(3)
    )
    _assert_bytes_eq(got, g.bytes(), "InitProducerId response v1")


def test_init_producer_id_response_error() raises:
    var g = _Golden()
    g.add("00000092")  # CorrelationId = 146
    g.add("00000000")  # ThrottleTimeMs = 0
    g.add("002f")  # ErrorCode = 47 (INVALID_PRODUCER_EPOCH)
    g.add("ffffffffffffffff")  # ProducerId = -1
    g.add("ffff")  # ProducerEpoch = -1
    var got = encode_init_producer_id_response(
        Int32(146), ERROR_INVALID_PRODUCER_EPOCH, Int64(-1), Int16(-1)
    )
    _assert_bytes_eq(got, g.bytes(), "InitProducerId response (error)")


# -----------------------------------------------------------------------------
# v2 (flexible) — reference only; see the TODO in the file header.
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


def _ipi_resp_v2() raises -> List[UInt8]:
    var g = _Golden()
    g.add("00000092")  # ResponseHeader v1: CorrelationId = 146
    g.add("00")  # header TAG_BUFFER
    g.add("00000000")  # ThrottleTimeMs = 0
    g.add("0000")  # ErrorCode = 0
    g.add("000000000000abcd")  # ProducerId = 43981
    g.add("0003")  # ProducerEpoch = 3
    g.add("00")  # body TAG_BUFFER
    return g.bytes()


def test_v2_reference_is_the_flexible_form() raises:
    """Checks the v2 reference with the primitive decoder only (the codec's
    v2 path disagrees with the schema; see the file header)."""
    var b = _ipi_req_v2()
    var dec = KafkaDecoder(Span(b))
    var h = parse_request_header(dec, True)
    assert_equal(h.api_version, Int16(2))
    assert_equal(dec.get_compact_nullable_string().value(), "tx1")
    assert_equal(dec.get_int32(), Int32(60000))
    dec.skip_tag_buffer()
    assert_equal(dec.remaining(), 0)
    var rb = _ipi_resp_v2()
    var rdec = KafkaDecoder(Span(rb))
    assert_equal(rdec.get_int32(), Int32(146))
    rdec.skip_tag_buffer()
    assert_equal(rdec.get_int32(), Int32(0))
    assert_equal(rdec.get_int16(), Int16(0))
    assert_equal(rdec.get_int64(), Int64(43981))
    assert_equal(rdec.get_int16(), Int16(3))
    rdec.skip_tag_buffer()
    assert_equal(rdec.remaining(), 0)


def main() raises:
    test_init_producer_id_request_v0()
    test_init_producer_id_request_v1()
    test_init_producer_id_response_v0_v1()
    test_init_producer_id_response_error()
    test_v2_reference_is_the_flexible_form()
    print("test_kafka_golden_init_producer_id: OK")
