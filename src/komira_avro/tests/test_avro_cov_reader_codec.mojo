# =============================================================================
# test_avro_cov_reader_codec.mojo -- the scalar byte reader, the standalone
# zigzag decoder, the block codec dispatch and the block emitters, at the
# arms the file-level tests never reach.
# =============================================================================
#
# What each case proves, and the mutant planted in the product code to see
# it fail (each alone, then restored; the red message is quoted):
#   R1  every AvroByteReader refusal (boolean, float, double, bytes, string,
#       bytes-span, string-span, fixed, fixed-span, skip, an 11-byte long,
#       a start offset outside the payload) names its own arm; an exact-fit
#       fixed read is accepted. Mutant: read_fixed_span's `n > len - pos`
#       -> `>=`: red, "TRUNCATED: fixed payload overrun" vs "(accepted)".
#   R2  read_fixed / read_fixed_span / skip_long / skip_n / an empty string
#       return the right bytes and move the cursor by the right amount.
#       Mutant: read_fixed's `self.pos += n` -> `pass`: red, the following
#       read_int reads the fixed bytes (2 vs 5).
#   R3  decode_zigzag_long decodes multi-byte values (300, -65, Int64.MAX)
#       and refuses an 11-byte varint. Mutant `shift += 7` -> `shift += 8`
#       (multi-byte loop): red, 556 vs 300.
#   C1  decompress_block and compress_block refuse an unknown codec tag by
#       name; a snappy payload shorter than its 4-byte CRC trailer is
#       refused; a snappy stream declaring 2^31 + 1 bytes is refused before
#       any allocation. Mutant: decompress_block's unknown-tag raise ->
#       `return List[UInt8]()`: red, "(accepted)" vs UNKNOWN_CODEC tag 42.
#   E1  emit_ocf_block with the NULL codec frames the raw payload unchanged
#       (count, length, bytes, sync); should_flush_block never flushes an
#       empty block, and flushes on bytes OR rows.
#   E2  emit_ocf_header_kv writes the two standard pairs first, then the
#       extra pairs (min of the two list lengths), and the result decodes.
#       Mutant: the `len(extra_vals) < n_extra` clamp made False: red, an
#       assert abort ("index 2 is out of bounds").
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_avro import (
    AvroByteReader,
    decode_zigzag_long,
    decompress_block,
    compress_block,
    decode_ocf_header,
    emit_ocf_block,
    should_flush_block,
    encode_long,
    AVRO_CODEC_NULL,
    AVRO_CODEC_SNAPPY,
    OCF_SYNC_LEN,
)
from komira_avro.ocf_block_emit import emit_ocf_header_kv


def _bytes(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for v in vals:
        out.append(UInt8(v))
    return out^


def _err_bool(data: List[UInt8]) -> String:
    try:
        var r = AvroByteReader(Span(data))
        _ = r.read_boolean()
    except e:
        return String(e)
    return String("(accepted)")


def _err_float(data: List[UInt8]) -> String:
    try:
        var r = AvroByteReader(Span(data))
        _ = r.read_float()
    except e:
        return String(e)
    return String("(accepted)")


def _err_double(data: List[UInt8]) -> String:
    try:
        var r = AvroByteReader(Span(data))
        _ = r.read_double()
    except e:
        return String(e)
    return String("(accepted)")


def _err_bytes(data: List[UInt8]) -> String:
    try:
        var r = AvroByteReader(Span(data))
        _ = r.read_bytes()
    except e:
        return String(e)
    return String("(accepted)")


def _err_string(data: List[UInt8]) -> String:
    try:
        var r = AvroByteReader(Span(data))
        _ = r.read_string()
    except e:
        return String(e)
    return String("(accepted)")


def _err_bytes_span(data: List[UInt8]) -> String:
    try:
        var r = AvroByteReader(Span(data))
        _ = r.read_bytes_span()
    except e:
        return String(e)
    return String("(accepted)")


def _err_string_span(data: List[UInt8]) -> String:
    try:
        var r = AvroByteReader(Span(data))
        _ = r.read_string_span()
    except e:
        return String(e)
    return String("(accepted)")


def _err_fixed(data: List[UInt8], n: Int) -> String:
    try:
        var r = AvroByteReader(Span(data))
        _ = r.read_fixed(n)
    except e:
        return String(e)
    return String("(accepted)")


def _err_fixed_span(data: List[UInt8], n: Int) -> String:
    try:
        var r = AvroByteReader(Span(data))
        _ = r.read_fixed_span(n)
    except e:
        return String(e)
    return String("(accepted)")


def _err_skip(data: List[UInt8], start: Int, n: Int) -> String:
    try:
        var r = AvroByteReader(Span(data), start)
        r.skip_n(n)
    except e:
        return String(e)
    return String("(accepted)")


def _err_long(data: List[UInt8]) -> String:
    try:
        var r = AvroByteReader(Span(data))
        _ = r.read_long()
    except e:
        return String(e)
    return String("(accepted)")


comptime _TR = "AvroDecodeError.TRUNCATED: "
comptime _MAL = "AvroDecodeError.MALFORMED: "


def test_reader_refusals() raises:
    """R1."""
    var empty = List[UInt8]()
    assert_equal(_err_bool(empty), _TR + "boolean overrun")
    assert_equal(_err_float(_bytes(1, 2, 3)), _TR + "float overrun")
    assert_equal(_err_double(_bytes(1, 2, 3, 4, 5, 6, 7)), _TR + "double overrun")
    # Length -1 is zigzag 0x01; length 3 is zigzag 0x06.
    assert_equal(_err_bytes(_bytes(0x01)), _MAL + "negative bytes length")
    assert_equal(_err_bytes(_bytes(0x06, 1, 2)), _TR + "bytes payload overrun")
    assert_equal(_err_string(_bytes(0x01)), _MAL + "negative string length")
    assert_equal(_err_string(_bytes(0x06, 0x61)), _TR + "string payload overrun")
    assert_equal(_err_bytes_span(_bytes(0x01)), _MAL + "negative bytes length")
    assert_equal(
        _err_bytes_span(_bytes(0x06, 1, 2)), _TR + "bytes payload overrun"
    )
    assert_equal(
        _err_string_span(_bytes(0x01)), _MAL + "negative string length"
    )
    assert_equal(_err_fixed(_bytes(1, 2), -1), _MAL + "negative fixed size")
    assert_equal(_err_fixed(_bytes(1, 2), 3), _TR + "fixed payload overrun")
    assert_equal(_err_fixed(_bytes(1, 2), 2), "(accepted)")
    assert_equal(_err_fixed_span(_bytes(1, 2), -1), _MAL + "negative fixed size")
    assert_equal(_err_fixed_span(_bytes(1, 2), 3), _TR + "fixed payload overrun")
    assert_equal(_err_fixed_span(_bytes(1, 2), 2), "(accepted)")
    assert_equal(
        _err_skip(_bytes(1, 2, 3), 1, 3),
        _TR + "skip of 3 bytes at payload offset 1 overruns the 3-byte block"
        " payload",
    )
    assert_equal(
        _err_skip(_bytes(1, 2, 3), 1, -1),
        _TR + "skip of -1 bytes at payload offset 1 overruns the 3-byte block"
        " payload",
    )
    assert_equal(_err_skip(_bytes(1, 2, 3), 1, 2), "(accepted)")
    assert_equal(
        _err_skip(_bytes(1, 2, 3), 4, 0),
        _TR + "reader start offset 4 is outside the 3-byte payload",
    )
    assert_equal(
        _err_skip(_bytes(1, 2, 3), -1, 0),
        _TR + "reader start offset -1 is outside the 3-byte payload",
    )
    var eleven = List[UInt8]()
    for _ in range(10):
        eleven.append(0xFF)
    eleven.append(0x01)
    assert_equal(
        _err_long(eleven), "AvroDecodeError.MALFORMED_VARINT: long > 10 bytes"
    )


def test_reader_fixed_and_skips() raises:
    """R2. Wire: fixed(3) "abc", int 5 (0x0A), long 300 (0xD8 0x04), four
    raw bytes skipped, an empty string (0x00), int -1 (0x01)."""
    var data = _bytes(
        0x61, 0x62, 0x63, 0x0A, 0xD8, 0x04, 9, 9, 9, 9, 0x00, 0x01
    )
    var r = AvroByteReader(Span(data))
    var f = r.read_fixed(3)
    assert_equal(len(f), 3)
    assert_equal(Int(f[0]), 0x61)
    assert_equal(Int(f[2]), 0x63)
    assert_equal(Int(r.read_int()), 5)
    r.skip_long()
    assert_equal(r.pos, 6)
    r.skip_n(4)
    assert_equal(r.read_string(), "")
    assert_equal(Int(r.read_int()), -1)
    assert_true(r.at_end())
    # The span twin, from a mid-payload start.
    var r2 = AvroByteReader(Span(data), 1)
    var s = r2.read_fixed_span(2)
    assert_equal(len(s), 2)
    assert_equal(Int(s[0]), 0x62)
    assert_equal(Int(s[1]), 0x63)
    assert_equal(r2.pos, 3)
    assert_equal(r2.remaining(), len(data) - 3)
    var z = r2.read_fixed(0)
    assert_equal(len(z), 0)
    assert_equal(r2.pos, 3)


def test_zigzag_multibyte() raises:
    """R3."""
    var b300 = _bytes(0xD8, 0x04)
    var z = decode_zigzag_long(Span(b300), 0)
    assert_equal(Int(z.value), 300)
    assert_equal(z.new_pos, 2)
    var bm65 = _bytes(0x00, 0x81, 0x01)
    z = decode_zigzag_long(Span(bm65), 1)
    assert_equal(Int(z.value), -65)
    assert_equal(z.new_pos, 3)
    var mx = List[UInt8]()
    encode_long(Int64.MAX, mx)
    assert_equal(len(mx), 10)
    z = decode_zigzag_long(Span(mx), 0)
    assert_equal(z.value, Int64.MAX)
    assert_equal(z.new_pos, 10)
    var eleven = List[UInt8]()
    for _ in range(10):
        eleven.append(0x80)
    eleven.append(0x00)
    var got = String("(accepted)")
    try:
        _ = decode_zigzag_long(Span(eleven), 0)
    except e:
        got = String(e)
    assert_equal(got, "AvroDecodeError.MALFORMED_VARINT: long > 10 bytes")


def _decompress_err(tag: Int, payload: List[UInt8]) -> String:
    try:
        _ = decompress_block(tag, Span(payload))
    except e:
        return String(e)
    return String("(accepted)")


def test_codec_dispatch_refusals() raises:
    """C1."""
    var p = _bytes(1, 2, 3)
    assert_equal(
        _decompress_err(42, p), "AvroCodecError.UNKNOWN_CODEC: tag 42"
    )
    var got = String("(accepted)")
    try:
        _ = compress_block(-7, Span(p))
    except e:
        got = String(e)
    assert_equal(got, "AvroCodecError.UNKNOWN_CODEC: tag -7")
    assert_equal(
        _decompress_err(AVRO_CODEC_SNAPPY, p),
        "AvroCodecError.SNAPPY_TRUNCATED: payload < 4-byte CRC trailer",
    )
    # Snappy preamble varint32 of 2^31 + 1 (0x81 0x80 0x80 0x80 0x08), then a
    # 4-byte trailer.
    var big = _bytes(0x81, 0x80, 0x80, 0x80, 0x08, 0, 0, 0, 0)
    assert_equal(
        _decompress_err(AVRO_CODEC_SNAPPY, big),
        "AvroCodecError.SNAPPY_LENGTH_OUT_OF_RANGE: stream declares 2147483649"
        " uncompressed bytes from a 5-byte block; the ceiling is 2147483648",
    )


def _sync() -> Array[UInt8, OCF_SYNC_LEN]:
    var s = Array[UInt8, OCF_SYNC_LEN](fill=0)
    for i in range(OCF_SYNC_LEN):
        s[i] = UInt8(0xC0 + i)
    return s^


def test_emit_null_codec_block_and_flush() raises:
    """E1."""
    var payload = _bytes(7, 8, 9)
    var out = List[UInt8]()
    emit_ocf_block(Span(payload), 2, AVRO_CODEC_NULL, _sync(), out)
    assert_equal(len(out), 2 + 3 + OCF_SYNC_LEN)
    assert_equal(Int(out[0]), 4)  # zigzag(2)
    assert_equal(Int(out[1]), 6)  # zigzag(3)
    assert_equal(Int(out[2]), 7)
    assert_equal(Int(out[4]), 9)
    assert_equal(Int(out[5]), 0xC0)
    assert_equal(Int(out[20]), 0xCF)
    # The cases come from a List so the calls are not folded at compile
    # time: (bytes, rows, block_size_bytes, block_size_rows, expected).
    var cases: List[Int] = [
        1 << 30, 0, 10, 10, 0,
        10, 1, 10, 100, 1,
        0, 5, 10, 5, 1,
        9, 4, 10, 5, 0,
    ]
    for i in range(0, len(cases), 5):
        assert_equal(
            should_flush_block(
                cases[i], cases[i + 1], cases[i + 2], cases[i + 3]
            ),
            cases[i + 4] == 1,
            "flush case " + String(i // 5),
        )


def test_emit_header_kv() raises:
    """E2."""
    var schema = String(
        '{"type":"record","name":"R","fields":[{"name":"a","type":"int"}]}'
    )
    var keys: List[String] = ["k1", "k2", "k3"]
    var vals: List[String] = ["v1", "v2"]
    var out = List[UInt8]()
    emit_ocf_header_kv(schema, AVRO_CODEC_SNAPPY, _sync(), keys, vals, out)
    var h = decode_ocf_header(Span(out))
    assert_equal(h.schema_json, schema)
    assert_equal(h.codec_name(), "snappy")
    assert_equal(h.header_len, len(out))
    assert_equal(Int(h.sync_marker[0]), 0xC0)
    # The map count is 4 (2 standard + min(3, 2) extra): zigzag 8.
    assert_equal(Int(out[4]), 8)
    # The extra pairs follow the codec value, in order.
    var text = String()
    for i in range(len(out)):
        var c = out[i]
        if c >= 0x61 and c <= 0x7A or c >= 0x30 and c <= 0x39:
            text += chr(Int(c))
    assert_true(text.find("k1v1k2v2") > text.find("snappy"), text)
    assert_true(text.find("k3") < 0, text)


def main() raises:
    test_reader_refusals()
    test_reader_fixed_and_skips()
    test_zigzag_multibyte()
    test_codec_dispatch_refusals()
    test_emit_null_codec_block_and_flush()
    test_emit_header_kv()
    print("test_avro_cov_reader_codec: ALL PASS")
