# The wire primitives the other tests leave out: the compact and nullable byte
# forms, the general TAG_BUFFER (tagged fields written and read back, not only
# skipped), the encoder's `new` and `snapshot`, and every refusal of the
# decoder with its exact message.
#
# Each expected byte string is written out by hand from the KIP-482 and
# protocol-guide encodings (unsigned varint, COMPACT_* = varint(len+1),
# NULLABLE = length -1 or varint 0 for null); none comes from the encoder.
#
# The refusal tests pin the message, because each length check has a later
# check behind it (a short read) that would still refuse the input with the
# first check deleted; the message says which check fired.
#
# `_read_raw` is the decoder's internal raw read, which the record-batch
# decoder in this package also calls; it is called here to reach the root
# bounds gate `_require` with a negative length, which no public accessor can
# hand it (each re-checks the sign first). The gate's docstring states the
# guarantee these cases hold: a negative length is refused and the cursor
# does not move backwards.

from std.testing import assert_equal, assert_false, assert_true

from komira_kafka_server.wire.wire import KafkaDecoder, KafkaEncoder, TaggedField


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


# -----------------------------------------------------------------------------
# Encoder: new, snapshot, compact and nullable byte forms, tagged fields.
# -----------------------------------------------------------------------------
def test_new_and_snapshot() raises:
    var enc = KafkaEncoder.new()
    assert_equal(enc.len(), 0, "new encoder is empty")
    enc.put_int8(Int8(1))
    var snap = enc.snapshot()
    enc.put_int8(Int8(2))
    _assert_bytes_eq(snap, _hex("01"), "snapshot holds the bytes so far")
    _assert_bytes_eq(enc.take_bytes(), _hex("01 02"), "encoder kept writing")


def test_compact_nullable_string_encode() raises:
    var enc = KafkaEncoder()
    enc.put_compact_nullable_string(Optional[String]())
    enc.put_compact_nullable_string(Optional(String("")))
    enc.put_compact_nullable_string(Optional(String("ab")))
    _assert_bytes_eq(
        enc.take_bytes(), _hex("00 | 01 | 03 61 62"), "null, empty, ab"
    )


def test_compact_bytes_round_trip() raises:
    var long = List[UInt8]()
    for i in range(130):
        long.append(UInt8(255 - i))
    var enc = KafkaEncoder()
    enc.put_compact_bytes(Span(List[UInt8]()))
    enc.put_compact_bytes(Span(_hex("de ad")))
    enc.put_compact_bytes(Span(long))
    var got = enc.take_bytes()
    # 131 = varint 0x83 0x01: the length needs a second group.
    var want = _hex("01 | 03 de ad | 83 01")
    for i in range(130):
        want.append(long[i])
    _assert_bytes_eq(got, want, "compact bytes")

    var dec = KafkaDecoder(Span(got))
    assert_equal(len(dec.get_compact_bytes()), 0, "empty")
    _assert_bytes_eq(dec.get_compact_bytes(), _hex("de ad"), "two bytes")
    _assert_bytes_eq(dec.get_compact_bytes(), long, "130 bytes")
    assert_equal(dec.remaining(), 0, "consumed")


def test_compact_nullable_bytes_round_trip() raises:
    var enc = KafkaEncoder()
    enc.put_compact_nullable_bytes(Optional[List[UInt8]]())
    enc.put_compact_nullable_bytes(Optional(List[UInt8]()))
    enc.put_compact_nullable_bytes(Optional(_hex("80 ff")))
    var got = enc.take_bytes()
    _assert_bytes_eq(got, _hex("00 | 01 | 03 80 ff"), "null, empty, 80 ff")

    var dec = KafkaDecoder(Span(got))
    assert_false(Bool(dec.get_compact_nullable_bytes()), "null")
    var empty = dec.get_compact_nullable_bytes()
    assert_true(Bool(empty), "empty is not null")
    assert_equal(len(empty.value()), 0, "empty")
    var two = dec.get_compact_nullable_bytes()
    _assert_bytes_eq(two.value(), _hex("80 ff"), "80 ff")
    assert_equal(dec.remaining(), 0, "consumed")


def test_nullable_bytes_decode() raises:
    var b = _hex("ff ff ff ff | 00 00 00 00 | 00 00 00 02 01 ff")
    var dec = KafkaDecoder(Span(b))
    assert_false(Bool(dec.get_nullable_bytes()), "-1 is null")
    var empty = dec.get_nullable_bytes()
    assert_true(Bool(empty), "length 0 is not null")
    assert_equal(len(empty.value()), 0, "length 0")
    _assert_bytes_eq(dec.get_nullable_bytes().value(), _hex("01 ff"), "two")
    assert_equal(dec.remaining(), 0, "consumed")


def test_tagged_fields_round_trip() raises:
    var long = List[UInt8]()
    for i in range(130):
        long.append(UInt8(i + 100))
    var fields = List[TaggedField]()
    fields.append(TaggedField(UInt32(1), _hex("aa")))
    fields.append(TaggedField(UInt32(200), long.copy()))
    var enc = KafkaEncoder()
    enc.put_tagged_fields(fields)
    var got = enc.take_bytes()
    # count 2 | tag 1, size 1, aa | tag 200 = c8 01, size 130 = 82 01, data
    var want = _hex("02 | 01 01 aa | c8 01 82 01")
    for i in range(130):
        want.append(long[i])
    _assert_bytes_eq(got, want, "tagged fields")

    var dec = KafkaDecoder(Span(got))
    var back = dec.get_tagged_fields()
    assert_equal(dec.remaining(), 0, "consumed")
    assert_equal(len(back), 2, "two fields")
    assert_equal(Int(back[0].tag), 1, "tag 0")
    _assert_bytes_eq(back[0].data, _hex("aa"), "data 0")
    assert_equal(Int(back[1].tag), 200, "tag 1")
    _assert_bytes_eq(back[1].data, long, "data 1")

    var enc0 = KafkaEncoder()
    enc0.put_tagged_fields(List[TaggedField]())
    var zero = enc0.take_bytes()
    _assert_bytes_eq(zero, _hex("00"), "no fields == empty tag buffer")
    var dec0 = KafkaDecoder(Span(zero))
    assert_equal(len(dec0.get_tagged_fields()), 0, "empty buffer reads empty")


def test_tagged_field_copy() raises:
    var f = TaggedField(UInt32(7), _hex("01 02"))
    var c = f.copy()
    f.data[0] = UInt8(9)
    assert_equal(Int(c.tag), 7, "copied tag")
    _assert_bytes_eq(c.data, _hex("01 02"), "copied data is its own")


# -----------------------------------------------------------------------------
# Decoder refusals, each with its message.
# -----------------------------------------------------------------------------
def test_unsigned_varint_five_byte_limit() raises:
    var five = _hex("ff ff ff ff 0f")
    var dec = KafkaDecoder(Span(five))
    assert_equal(Int(dec.get_unsigned_varint()), 4294967295, "5 bytes: max")
    var six = _hex("80 80 80 80 80 01")
    var dec6 = KafkaDecoder(Span(six))
    var msg = String("<accepted>")
    try:
        _ = dec6.get_unsigned_varint()
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_kafka_server.wire: unsigned varint exceeds 5 bytes (corrupt"
        " stream)",
    )


def test_string_negative_length() raises:
    for raw in [String("ff ff"), String("ff fe")]:
        var b = _hex(raw)
        var dec = KafkaDecoder(Span(b))
        var msg = String("<accepted>")
        try:
            _ = dec.get_string()
        except e:
            msg = String(e)
        assert_equal(
            msg,
            "komira_kafka_server.wire: negative length for non-nullable STRING",
            raw,
        )


def test_compact_string_null() raises:
    var b = _hex("00")
    var dec = KafkaDecoder(Span(b))
    var msg = String("<accepted>")
    try:
        _ = dec.get_compact_string()
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_kafka_server.wire: null length for non-nullable COMPACT_STRING",
    )


def test_compact_bytes_null() raises:
    var b = _hex("00")
    var dec = KafkaDecoder(Span(b))
    var msg = String("<accepted>")
    try:
        _ = dec.get_compact_bytes()
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_kafka_server.wire: null length for non-nullable COMPACT_BYTES",
    )


def test_bytes_negative_length() raises:
    var b = _hex("ff ff ff ff")
    var dec = KafkaDecoder(Span(b))
    var msg = String("<accepted>")
    try:
        _ = dec.get_bytes()
    except e:
        msg = String(e)
    assert_equal(
        msg, "komira_kafka_server.wire: negative length for non-nullable BYTES"
    )


def test_root_gate_refuses_negative_length() raises:
    var b = _hex("01 02 03")
    var dec = KafkaDecoder(Span(b))
    _ = dec.get_int8()
    var msg = String("<accepted>")
    try:
        _ = dec._read_raw(-3)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "komira_kafka_server.wire: negative read length -3 at offset 1"
        " (corrupt length prefix)",
    )
    assert_equal(dec.pos(), 1, "the cursor did not move")
    var msg2 = String("<accepted>")
    try:
        _ = dec._read_raw(-1)
    except e:
        msg2 = String(e)
    assert_equal(
        msg2,
        "komira_kafka_server.wire: negative read length -1 at offset 1"
        " (corrupt length prefix)",
    )
    assert_equal(len(dec._read_raw(0)), 0, "zero is a valid length")
    _assert_bytes_eq(dec._read_raw(2), _hex("02 03"), "then the bytes")


def main() raises:
    test_new_and_snapshot()
    test_compact_nullable_string_encode()
    test_compact_bytes_round_trip()
    test_compact_nullable_bytes_round_trip()
    test_nullable_bytes_decode()
    test_tagged_fields_round_trip()
    test_tagged_field_copy()
    test_unsigned_varint_five_byte_limit()
    test_string_negative_length()
    test_compact_string_null()
    test_compact_bytes_null()
    test_bytes_negative_length()
    test_root_gate_refuses_negative_length()
    print("test_kafka_wire_primitive_edges: OK")
