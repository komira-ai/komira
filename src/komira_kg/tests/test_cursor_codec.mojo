# =============================================================================
# test_cursor_codec.mojo -- the stored form of a cursor, and what it refuses.
# =============================================================================
#
#   round trip   decode inverts encode for empty fields, multi-byte text, a
#                zero byte inside a field, negative and extreme integers.
#   layout       the first byte is the format version, strings are little-endian
#                length-prefixed, integers are 8 bytes little-endian.
#   refusals     an empty body, an unknown version, every proper prefix of a
#                valid body, a byte after the last field, a length larger than
#                the bytes that remain (including 0xFFFFFFFF), a length over the
#                field limit, and text that is not UTF-8 each raise an error that
#                names the defect; none allocates from the claimed length.
# No test reads a clock or the environment.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises

from komira_kg import (
    CURSOR_FORMAT_VERSION,
    CURSOR_MAX_FIELD_BYTES,
    SurfaceCursor,
    decode_cursor,
    encode_cursor,
)


def _round_trips(c: SurfaceCursor) raises:
    var got = decode_cursor(encode_cursor(c))
    assert_equal(got.partition_id, c.partition_id)
    assert_equal(got.source_key, c.source_key)
    assert_equal(got.token, c.token)
    assert_equal(got.watermark, c.watermark)
    assert_equal(got.synced_at, c.synced_at)


def test_decode_inverts_encode() raises:
    _round_trips(SurfaceCursor("p", "feed", "tok", Int64(7), Int64(8)))
    _round_trips(SurfaceCursor("", "", "", Int64(0), Int64(0)))
    _round_trips(SurfaceCursor("pé", "日本", "naïve ✓", Int64(1), Int64(2)))
    _round_trips(SurfaceCursor("p", "k", "a" + chr(0) + "b", Int64(1), Int64(2)))
    _round_trips(SurfaceCursor("p", "k", "t", Int64(-5), Int64(-6)))
    _round_trips(SurfaceCursor("p", "k", "t", Int64.MAX, Int64.MIN))
    var longest = String("")
    for _ in range(CURSOR_MAX_FIELD_BYTES):
        longest += "x"
    _round_trips(SurfaceCursor("p", "k", longest, Int64(1), Int64(2)))


def test_the_layout_is_fixed() raises:
    var b = encode_cursor(SurfaceCursor("ab", "c", "", Int64(1), Int64(256)))
    var expect = List[Int]()
    expect.append(CURSOR_FORMAT_VERSION)
    expect.append(2)
    expect.append(0)
    expect.append(0)
    expect.append(0)
    expect.append(97)
    expect.append(98)
    expect.append(1)
    expect.append(0)
    expect.append(0)
    expect.append(0)
    expect.append(99)
    expect.append(0)
    expect.append(0)
    expect.append(0)
    expect.append(0)
    expect.append(1)
    for _ in range(7):
        expect.append(0)
    expect.append(0)
    expect.append(1)
    for _ in range(6):
        expect.append(0)
    assert_equal(len(b), len(expect))
    for i in range(len(expect)):
        assert_equal(Int(b[i]), expect[i])
    assert_equal(CURSOR_FORMAT_VERSION, 1)


def test_an_empty_body_and_an_unknown_version_are_refused() raises:
    with assert_raises(contains="truncated format version"):
        _ = decode_cursor(List[UInt8]())
    var b = encode_cursor(SurfaceCursor("p", "k", "t", Int64(1), Int64(2)))
    b[0] = UInt8(2)
    with assert_raises(contains="format version 2"):
        _ = decode_cursor(b)
    b[0] = UInt8(0)
    with assert_raises(contains="format version 0"):
        _ = decode_cursor(b)


def test_every_proper_prefix_is_refused() raises:
    var b = encode_cursor(SurfaceCursor("pp", "kk", "tt", Int64(1), Int64(2)))
    for n in range(len(b)):
        var cut = List[UInt8]()
        for i in range(n):
            cut.append(b[i])
        with assert_raises(contains="truncated"):
            _ = decode_cursor(cut)


def test_trailing_bytes_are_refused() raises:
    var b = encode_cursor(SurfaceCursor("p", "k", "t", Int64(1), Int64(2)))
    b.append(UInt8(0))
    with assert_raises(contains="1 trailing bytes"):
        _ = decode_cursor(b)


def _with_first_length(length: List[Int]) -> List[UInt8]:
    """A body whose partition-id length field is `length` (four bytes) and
    which has only three bytes of text behind it."""
    var out = List[UInt8]()
    out.append(UInt8(CURSOR_FORMAT_VERSION))
    for i in range(4):
        out.append(UInt8(length[i]))
    out.append(UInt8(97))
    out.append(UInt8(98))
    out.append(UInt8(99))
    return out^


def test_a_length_past_the_end_is_refused() raises:
    var four = List[Int]()
    four.append(4)
    four.append(0)
    four.append(0)
    four.append(0)
    with assert_raises(contains="truncated partition id"):
        _ = decode_cursor(_with_first_length(four))
    var huge = List[Int]()
    for _ in range(4):
        huge.append(255)
    with assert_raises(contains="over the limit"):
        _ = decode_cursor(_with_first_length(huge))
    var over = List[Int]()
    over.append(1)
    over.append(0)
    over.append(1)
    over.append(0)  # 65537
    with assert_raises(contains="claims 65537 bytes"):
        _ = decode_cursor(_with_first_length(over))


def test_text_that_is_not_utf8_is_refused() raises:
    var b = encode_cursor(SurfaceCursor("pp", "k", "t", Int64(1), Int64(2)))
    b[5] = UInt8(0xFF)
    with assert_raises(contains="partition id is not valid UTF-8"):
        _ = decode_cursor(b)
    var c = encode_cursor(SurfaceCursor("p", "k", "t", Int64(1), Int64(2)))
    # The token's one byte: version 1 + (4+1) + (4+1) + 4 = offset 15.
    c[15] = UInt8(0x80)
    with assert_raises(contains="token is not valid UTF-8"):
        _ = decode_cursor(c)


def test_an_oversize_field_is_refused_on_encode() raises:
    var big = String("")
    for _ in range(CURSOR_MAX_FIELD_BYTES + 1):
        big += "x"
    with assert_raises(contains="partition id is 65537 bytes"):
        _ = encode_cursor(SurfaceCursor(big, "k", "t", Int64(1), Int64(2)))
    with assert_raises(contains="source key is 65537 bytes"):
        _ = encode_cursor(SurfaceCursor("p", big, "t", Int64(1), Int64(2)))
    with assert_raises(contains="token is 65537 bytes"):
        _ = encode_cursor(SurfaceCursor("p", "k", big, Int64(1), Int64(2)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
