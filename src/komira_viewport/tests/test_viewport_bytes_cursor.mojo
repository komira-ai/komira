# =============================================================================
# The byte cursor (viewport_bytes.mojo): exact wire bytes and every refusal.
#
# A ticket is untrusted bytes, and every field of it goes through
# ViewportReader. This suite holds the cursor to its contract byte by byte:
#
#   * the UTF-8 gate of read_string, swept across every sequence length and
#     every boundary of RFC 3629 (the lowest and highest code point of each
#     length, the overlong forms, the surrogate range, past U+10FFFF, bad lead
#     and continuation bytes, a sequence cut off at the buffer end);
#   * the fixed-width floats and the zigzag varint, by their exact
#     little-endian bytes (a round trip alone would pass a wrong-but-symmetric
#     encoding);
#   * every truncation and cap refusal, with the reason it names;
#   * the cursor position after each read (a read that does not advance, or
#     advances by the wrong amount, shows up in the next read).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_viewport import ViewportWriter, ViewportReader, VIEWPORT_MAX_BYTESTRING_LEN


def _reader_of(bytes: List[UInt8]) -> ViewportReader:
    return ViewportReader.from_span(Span(bytes))


def _string_field(payload: List[UInt8]) raises -> String:
    """Read `payload` as one length-prefixed string field (the path every
    locator, column name, alias and string literal takes)."""
    var w = ViewportWriter()
    w.write_uvarint(UInt64(len(payload)))
    for i in range(len(payload)):
        w.write_u8(payload[i])
    var r = ViewportReader(w.take_bytes())
    var s = r.read_string()
    r.expect_end()
    return s^


def _assert_utf8_accepted(payload: List[UInt8]) raises:
    """The field decodes, and to exactly its bytes, with ASCII on both sides
    (so a wrong advance past the sequence misreads the trailing 'z')."""
    var framed = List[UInt8]()
    framed.append(UInt8(0x61))  # 'a'
    for i in range(len(payload)):
        framed.append(payload[i])
    framed.append(UInt8(0x7A))  # 'z'
    var s = _string_field(framed)
    var got = s.as_bytes()
    assert_equal(len(got), len(framed))
    for i in range(len(framed)):
        assert_equal(got[i], framed[i])


def _assert_utf8_rejected(payload: List[UInt8]) raises:
    with assert_raises(contains="not valid UTF-8"):
        _ = _string_field(payload)


def _b(a: Int) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(a))
    return out^


def _b(a: Int, b: Int) -> List[UInt8]:
    var out = _b(a)
    out.append(UInt8(b))
    return out^


def _b(a: Int, b: Int, c: Int) -> List[UInt8]:
    var out = _b(a, b)
    out.append(UInt8(c))
    return out^


def _b(a: Int, b: Int, c: Int, d: Int) -> List[UInt8]:
    var out = _b(a, b, c)
    out.append(UInt8(d))
    return out^


# --- UTF-8: accepted sequences, at every length boundary ----------------------


def test_utf8_two_byte_range() raises:
    _assert_utf8_accepted(_b(0xC2, 0x80))  # U+0080, lowest 2-byte
    _assert_utf8_accepted(_b(0xC3, 0xA9))  # U+00E9
    _assert_utf8_accepted(_b(0xDF, 0xBF))  # U+07FF, highest 2-byte


def test_utf8_three_byte_range() raises:
    _assert_utf8_accepted(_b(0xE0, 0xA0, 0x80))  # U+0800, lowest 3-byte
    _assert_utf8_accepted(_b(0xED, 0x9F, 0xBF))  # U+D7FF, just below surrogates
    _assert_utf8_accepted(_b(0xEE, 0x80, 0x80))  # U+E000, just above surrogates
    _assert_utf8_accepted(_b(0xEF, 0xBF, 0xBF))  # U+FFFF, highest 3-byte


def test_utf8_four_byte_range() raises:
    _assert_utf8_accepted(_b(0xF0, 0x90, 0x80, 0x80))  # U+10000, lowest 4-byte
    _assert_utf8_accepted(_b(0xF0, 0x9F, 0x98, 0x80))  # U+1F600
    _assert_utf8_accepted(_b(0xF4, 0x8F, 0xBF, 0xBF))  # U+10FFFF, highest


def test_utf8_sequence_ending_the_buffer() raises:
    # The last byte of the field is the last continuation byte: the
    # truncation check must not refuse a sequence that fits exactly.
    var s = _string_field(_b(0xE2, 0x82, 0xAC))  # U+20AC, nothing after it
    assert_equal(s.byte_length(), 3)
    var s4 = _string_field(_b(0xF0, 0x9F, 0x98, 0x80))
    assert_equal(s4.byte_length(), 4)


# --- UTF-8: refused sequences -------------------------------------------------


def test_utf8_invalid_lead_bytes() raises:
    _assert_utf8_rejected(_b(0x80))  # a continuation byte as lead
    _assert_utf8_rejected(_b(0xBF))
    _assert_utf8_rejected(_b(0xF8, 0x88, 0x80, 0x80))  # 5-byte lead
    # 0xFC's low three bits equal 0xF4's: read as a 4-byte lead it would decode
    # to U+100000, in range, so only the lead-byte mask refuses it.
    _assert_utf8_rejected(_b(0xFC, 0x80, 0x80, 0x80))
    _assert_utf8_rejected(_b(0xFF))


def test_utf8_truncated_at_buffer_end() raises:
    _assert_utf8_rejected(_b(0x61, 0xC3))  # 2-byte lead, nothing after
    _assert_utf8_rejected(_b(0xE2, 0x82))  # 3-byte, one continuation short
    _assert_utf8_rejected(_b(0xF0, 0x9F, 0x98))  # 4-byte, one short


def test_utf8_bad_continuation_at_each_position() raises:
    _assert_utf8_rejected(_b(0xC3, 0x28))
    _assert_utf8_rejected(_b(0xE2, 0x28, 0xA1))
    _assert_utf8_rejected(_b(0xE2, 0x82, 0x28))
    _assert_utf8_rejected(_b(0xF0, 0x28, 0x8C, 0xBC))
    _assert_utf8_rejected(_b(0xF0, 0x90, 0x28, 0xBC))
    _assert_utf8_rejected(_b(0xF0, 0x90, 0x8C, 0x28))
    _assert_utf8_rejected(_b(0xC3, 0xC3))  # a lead byte where a continuation belongs


def test_utf8_overlong_forms() raises:
    _assert_utf8_rejected(_b(0xC0, 0x80))  # U+0000 in 2 bytes
    _assert_utf8_rejected(_b(0xC1, 0xBF))  # U+007F in 2 bytes
    _assert_utf8_rejected(_b(0xE0, 0x9F, 0xBF))  # U+07FF in 3 bytes
    _assert_utf8_rejected(_b(0xF0, 0x8F, 0xBF, 0xBF))  # U+FFFF in 4 bytes


def test_utf8_beyond_unicode() raises:
    _assert_utf8_rejected(_b(0xF4, 0x90, 0x80, 0x80))  # U+110000
    _assert_utf8_rejected(_b(0xF7, 0xBF, 0xBF, 0xBF))  # U+1FFFFF


def test_utf8_surrogates() raises:
    _assert_utf8_rejected(_b(0xED, 0xA0, 0x80))  # U+D800, lowest
    _assert_utf8_rejected(_b(0xED, 0xBF, 0xBF))  # U+DFFF, highest


# --- read_u8 / read_bool ------------------------------------------------------


def test_read_u8_at_end_refused() raises:
    var r = _reader_of(_b(0x07))
    assert_equal(r.read_u8(), UInt8(7))
    assert_true(r.at_end())
    with assert_raises(contains="expected a byte at end of buffer"):
        _ = r.read_u8()


def test_read_bool_bytes() raises:
    var r = _reader_of(_b(0x00, 0x01, 0x02))
    assert_false(r.read_bool())
    assert_true(r.read_bool())
    with assert_raises(contains="malformed bool byte 2"):
        _ = r.read_bool()
    var r2 = _reader_of(_b(0xFF))
    with assert_raises(contains="malformed bool byte 255"):
        _ = r2.read_bool()


def test_write_bool_bytes() raises:
    var w = ViewportWriter()
    w.write_bool(True)
    w.write_bool(False)
    var b = w.take_bytes()
    assert_equal(len(b), 2)
    assert_equal(b[0], UInt8(1))
    assert_equal(b[1], UInt8(0))


# --- fixed-width floats -------------------------------------------------------


def test_f64_little_endian_bytes() raises:
    var w = ViewportWriter()
    w.write_f64(Float64(1.0))  # 0x3FF0000000000000
    w.write_f64(Float64(-2.5))  # 0xC004000000000000
    var b = w.take_bytes()
    assert_equal(len(b), 16)
    for i in range(6):
        assert_equal(b[i], UInt8(0))
    assert_equal(b[6], UInt8(0xF0))
    assert_equal(b[7], UInt8(0x3F))
    assert_equal(b[14], UInt8(0x04))
    assert_equal(b[15], UInt8(0xC0))
    var r = ViewportReader(b^)
    assert_equal(r.read_f64(), Float64(1.0))
    assert_equal(r.remaining(), 8)
    assert_equal(r.read_f64(), Float64(-2.5))
    r.expect_end()


def test_f32_little_endian_bytes() raises:
    var w = ViewportWriter()
    w.write_f32(Float32(1.0))  # 0x3F800000
    w.write_f32(Float32(-0.5))  # 0xBF000000
    var b = w.take_bytes()
    assert_equal(len(b), 8)
    assert_equal(b[0], UInt8(0))
    assert_equal(b[1], UInt8(0))
    assert_equal(b[2], UInt8(0x80))
    assert_equal(b[3], UInt8(0x3F))
    assert_equal(b[7], UInt8(0xBF))
    var r = ViewportReader(b^)
    assert_equal(r.read_f32(), Float32(1.0))
    assert_equal(r.remaining(), 4)
    assert_equal(r.read_f32(), Float32(-0.5))
    r.expect_end()


def test_f64_truncated() raises:
    var seven = List[UInt8]()
    for _ in range(7):
        seven.append(UInt8(0))
    var r = _reader_of(seven)
    with assert_raises(contains="expected 8 bytes for f64"):
        _ = r.read_f64()


def test_f32_truncated() raises:
    var r = _reader_of(_b(0, 0, 0))
    with assert_raises(contains="expected 4 bytes for f32"):
        _ = r.read_f32()


# --- zigzag varints, by their bytes -------------------------------------------


def test_ivarint_zigzag_bytes() raises:
    var w = ViewportWriter()
    w.write_ivarint(Int64(0))  # 00
    w.write_ivarint(Int64(-1))  # 01
    w.write_ivarint(Int64(1))  # 02
    w.write_ivarint(Int64(-64))  # 7F
    w.write_ivarint(Int64(64))  # 80 01
    var b = w.take_bytes()
    assert_equal(len(b), 6)
    assert_equal(b[0], UInt8(0x00))
    assert_equal(b[1], UInt8(0x01))
    assert_equal(b[2], UInt8(0x02))
    assert_equal(b[3], UInt8(0x7F))
    assert_equal(b[4], UInt8(0x80))
    assert_equal(b[5], UInt8(0x01))


def test_ivarint_extremes_roundtrip() raises:
    var vals = List[Int64]()
    vals.append(Int64.MIN)
    vals.append(Int64.MIN + 1)
    vals.append(Int64(-1))
    vals.append(Int64(0))
    vals.append(Int64.MAX)
    var w = ViewportWriter()
    for i in range(len(vals)):
        w.write_ivarint(vals[i])
    var b = w.take_bytes()
    # MAX zigzags to 2^64 - 2 and MIN to 2^64 - 1: ten bytes each.
    var r = ViewportReader(b^)
    for i in range(len(vals)):
        assert_equal(r.read_ivarint(), vals[i])
    r.expect_end()


def test_uvarint_high_bytes_roundtrip() raises:
    var w = ViewportWriter()
    w.write_uvarint(UInt64(0xFFFFFFFFFFFFFFFF))
    w.write_uvarint(UInt64(0x8000000000000000))
    var b = w.take_bytes()
    assert_equal(len(b), 20)
    assert_equal(b[9], UInt8(0x01))
    var r = ViewportReader(b^)
    assert_equal(r.read_uvarint(), UInt64(0xFFFFFFFFFFFFFFFF))
    assert_equal(r.read_uvarint(), UInt64(0x8000000000000000))
    r.expect_end()


# --- strings: cap, truncation, advance ----------------------------------------


def test_string_length_over_cap() raises:
    var w = ViewportWriter()
    w.write_uvarint(UInt64(VIEWPORT_MAX_BYTESTRING_LEN + 1))
    var r = ViewportReader(w.take_bytes())
    with assert_raises(contains="string length 16777217 exceeds cap 16777216"):
        _ = r.read_string()


def test_string_length_with_high_bytes() raises:
    # A length with every high bit set must hit the cap, not wrap negative.
    var w = ViewportWriter()
    w.write_uvarint(UInt64(0xFFFFFFFFFFFFFFFF))
    var r = ViewportReader(w.take_bytes())
    with assert_raises(contains="exceeds cap"):
        _ = r.read_string()
    var w2 = ViewportWriter()
    w2.write_uvarint(UInt64(0x8000000000000000))
    var r2 = ViewportReader(w2.take_bytes())
    with assert_raises(contains="exceeds cap"):
        _ = r2.read_string()


def test_string_length_at_cap_is_not_a_cap_refusal() raises:
    # Exactly the cap passes the cap check and fails on the missing bytes.
    var w = ViewportWriter()
    w.write_uvarint(UInt64(VIEWPORT_MAX_BYTESTRING_LEN))
    var r = ViewportReader(w.take_bytes())
    with assert_raises(contains="declared string length 16777216 runs past buffer end (0 left)"):
        _ = r.read_string()


def test_string_runs_past_end() raises:
    var w = ViewportWriter()
    w.write_uvarint(UInt64(3))
    w.write_u8(UInt8(0x61))
    w.write_u8(UInt8(0x62))
    var r = ViewportReader(w.take_bytes())
    with assert_raises(contains="declared string length 3 runs past buffer end (2 left)"):
        _ = r.read_string()


def test_strings_advance_the_cursor() raises:
    var w = ViewportWriter()
    w.write_string(String("ab"))
    w.write_string(String(""))
    w.write_string(String("cde"))
    w.write_u8(UInt8(9))
    var r = ViewportReader(w.take_bytes())
    assert_equal(r.read_string(), String("ab"))
    assert_equal(r.read_string(), String(""))
    assert_equal(r.read_string(), String("cde"))
    assert_equal(r.read_u8(), UInt8(9))
    r.expect_end()


# --- writer and reader state ---------------------------------------------------


def test_take_bytes_empties_the_writer() raises:
    var w = ViewportWriter(capacity_hint=4)
    w.write_u8(UInt8(1))
    w.write_u8(UInt8(2))
    var first = w.take_bytes()
    assert_equal(len(first), 2)
    var second = w.take_bytes()
    assert_equal(len(second), 0)
    w.write_u8(UInt8(3))
    var third = w.take_bytes()
    assert_equal(len(third), 1)
    assert_equal(third[0], UInt8(3))


def test_expect_end_names_the_trailing_count() raises:
    var r = _reader_of(_b(1, 2, 3))
    _ = r.read_u8()
    assert_equal(r.remaining(), 2)
    assert_false(r.at_end())
    with assert_raises(contains="2 trailing bytes after message end"):
        r.expect_end()
    _ = r.read_u8()
    _ = r.read_u8()
    r.expect_end()


def test_from_span_copies_the_view() raises:
    var src = _b(0x11, 0x22)
    var r = ViewportReader.from_span(Span(src))
    src[0] = UInt8(0x99)
    assert_equal(r.read_u8(), UInt8(0x11))
    assert_equal(r.read_u8(), UInt8(0x22))
    assert_true(r.at_end())


def main() raises:
    var suite = TestSuite()
    suite.test[test_utf8_two_byte_range]()
    suite.test[test_utf8_three_byte_range]()
    suite.test[test_utf8_four_byte_range]()
    suite.test[test_utf8_sequence_ending_the_buffer]()
    suite.test[test_utf8_invalid_lead_bytes]()
    suite.test[test_utf8_truncated_at_buffer_end]()
    suite.test[test_utf8_bad_continuation_at_each_position]()
    suite.test[test_utf8_overlong_forms]()
    suite.test[test_utf8_beyond_unicode]()
    suite.test[test_utf8_surrogates]()
    suite.test[test_read_u8_at_end_refused]()
    suite.test[test_read_bool_bytes]()
    suite.test[test_write_bool_bytes]()
    suite.test[test_f64_little_endian_bytes]()
    suite.test[test_f32_little_endian_bytes]()
    suite.test[test_f64_truncated]()
    suite.test[test_f32_truncated]()
    suite.test[test_ivarint_zigzag_bytes]()
    suite.test[test_ivarint_extremes_roundtrip]()
    suite.test[test_uvarint_high_bytes_roundtrip]()
    suite.test[test_string_length_over_cap]()
    suite.test[test_string_length_with_high_bytes]()
    suite.test[test_string_length_at_cap_is_not_a_cap_refusal]()
    suite.test[test_string_runs_past_end]()
    suite.test[test_strings_advance_the_cursor]()
    suite.test[test_take_bytes_empties_the_writer]()
    suite.test[test_expect_end_names_the_trailing_count]()
    suite.test[test_from_span_copies_the_view]()
    suite^.run()
