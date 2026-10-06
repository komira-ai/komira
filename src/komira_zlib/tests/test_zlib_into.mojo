# =============================================================================
# src/komira_zlib/tests/test_zlib_into.mojo
#   The Span entries of komira_zlib: zlib_deflate_into, zlib_inflate_into,
#   zlib_compress_bound, zlib_skip_stream and zlib_crc32.
# =============================================================================
#
# The known-answer vector is the zlib 1.3.1 release tarball, a gzip stream the
# zlib project published, pinned by sha256 in //third_party/zlib and staged at
# golden/zlib-1.3.1.tar.gz. Three of its members, extracted by the build's
# busybox tar (not by the code under test), are staged at golden/zlib/. The
# test inflates the tarball, walks the tar it decodes to, and holds each of
# those members to the busybox copy byte for byte. The gzip trailer (RFC 1952
# section 2.3.1) ends with ISIZE, the decoded length mod 2^32, little-endian,
# which sizes the destination exactly.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_zlib import (
    ZLIB_LEVEL_DEFAULT,
    ZLIB_WINDOW_BITS_AUTO,
    ZLIB_WINDOW_BITS_GZIP,
    ZLIB_WINDOW_BITS_RAW,
    ZLIB_WINDOW_BITS_ZLIB,
    zlib_compress_bound,
    zlib_crc32,
    zlib_deflate_into,
    zlib_inflate_into,
    zlib_skip_stream,
)

comptime _TARBALL = "golden/zlib-1.3.1.tar.gz"
comptime _MEMBER_DIR = "golden/zlib/"
comptime _MEMBER_PREFIX = "zlib-1.3.1/"


def _read(path: String) raises -> List[UInt8]:
    return Path(path).read_bytes()


def _filled(n: Int, value: UInt8) -> List[UInt8]:
    return List[UInt8](length=n, fill=value)


def _assert_same(got: Span[UInt8, _], want: Span[UInt8, _]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        if got[i] != want[i]:
            assert_equal(Int(got[i]), Int(want[i]), "byte " + String(i))


def _isize(gz: List[UInt8]) -> Int:
    var n = len(gz)
    return (
        Int(gz[n - 4])
        | (Int(gz[n - 3]) << 8)
        | (Int(gz[n - 2]) << 16)
        | (Int(gz[n - 1]) << 24)
    )


def _inflated_tarball() raises -> List[UInt8]:
    var gz = _read(_TARBALL)
    var tar = _filled(_isize(gz), 0)
    var n = zlib_inflate_into(Span(tar), Span(gz))
    assert_equal(n, len(tar))
    return tar^


def _cstr(b: List[UInt8], at: Int, width: Int) -> String:
    var s = String()
    for i in range(width):
        var c = b[at + i]
        if c == 0:
            break
        s += chr(Int(c))
    return s^


def _octal(b: List[UInt8], at: Int, width: Int) -> Int:
    var v = 0
    for i in range(width):
        var c = Int(b[at + i])
        if c >= 0x30 and c <= 0x37:
            v = v * 8 + (c - 0x30)
        elif v > 0:
            break
    return v


def _tar_member(tar: List[UInt8], name: String) raises -> List[UInt8]:
    """The bytes of regular file `name` in a ustar archive: 512-byte headers
    (name at 0, size in octal at 124, type flag at 156, name prefix at 345),
    each followed by its data padded to 512, ended by zero blocks."""
    var at = 0
    while at + 512 <= len(tar):
        var short = _cstr(tar, at, 100)
        if short == "":
            break
        var prefix = _cstr(tar, at + 345, 155)
        var full = short if prefix == "" else prefix + "/" + short
        var size = _octal(tar, at + 124, 12)
        var kind = Int(tar[at + 156])
        var data = at + 512
        if full == name and (kind == 0x30 or kind == 0):
            var out = List[UInt8](capacity=size)
            for i in range(size):
                out.append(tar[data + i])
            return out^
        at = data + ((size + 511) // 512) * 512
    raise Error("no member " + name + " in the tarball")


def _round_trip(
    data: List[UInt8], deflate_bits: Int32, inflate_bits: Int32
) raises:
    var packed = _filled(zlib_compress_bound(len(data), deflate_bits), 0)
    var plen = zlib_deflate_into(
        Span(packed), Span(data), ZLIB_LEVEL_DEFAULT, deflate_bits
    )
    assert_true(plen > 0 and plen <= len(packed))
    var out = _filled(len(data), 0xAA)
    var n = zlib_inflate_into(Span(out), Span(packed)[0:plen], inflate_bits)
    assert_equal(n, len(data))
    _assert_same(Span(out), Span(data))


def _varied(n: Int) -> List[UInt8]:
    var data = List[UInt8](capacity=n)
    for i in range(n):
        data.append(UInt8(((i * 31 + 5) ^ (i >> 7)) & 0xFF))
    return data^


def _raises_containing[
    o: MutOrigin
](
    dst: Span[UInt8, o],
    src: Span[UInt8, _],
    window_bits: Int32,
    needle: String,
) raises:
    var raised = False
    try:
        _ = zlib_inflate_into(dst, src, window_bits)
    except e:
        raised = True
        assert_true(needle in String(e), String(e))
    assert_true(raised, "expected a refusal containing '" + needle + "'")


# --- known answer -------------------------------------------------------------


def test_tarball_inflates_to_its_members() raises:
    var tar = _inflated_tarball()
    for member in ["README", "zlib.h", "LICENSE"]:
        var want = _read(_MEMBER_DIR + member)
        var got = _tar_member(tar, _MEMBER_PREFIX + member)
        _assert_same(Span(got), Span(want))


def test_tarball_inflates_under_explicit_gzip_framing() raises:
    var gz = _read(_TARBALL)
    var tar = _filled(_isize(gz), 0)
    assert_equal(
        zlib_inflate_into(Span(tar), Span(gz), ZLIB_WINDOW_BITS_GZIP), len(tar)
    )


def test_tarball_is_not_a_zlib_stream() raises:
    var gz = _read(_TARBALL)
    var tar = _filled(_isize(gz), 0)
    _raises_containing(Span(tar), Span(gz), ZLIB_WINDOW_BITS_ZLIB, "corrupt")


# --- round trips --------------------------------------------------------------


def test_round_trip_gzip() raises:
    var data = _read(_MEMBER_DIR + "zlib.h")
    _round_trip(data, ZLIB_WINDOW_BITS_GZIP, ZLIB_WINDOW_BITS_AUTO)
    _round_trip(data, ZLIB_WINDOW_BITS_GZIP, ZLIB_WINDOW_BITS_GZIP)


def test_round_trip_zlib() raises:
    var data = _varied(65536)
    _round_trip(data, ZLIB_WINDOW_BITS_ZLIB, ZLIB_WINDOW_BITS_AUTO)
    _round_trip(data, ZLIB_WINDOW_BITS_ZLIB, ZLIB_WINDOW_BITS_ZLIB)


def test_round_trip_raw_deflate() raises:
    var data = _read(_MEMBER_DIR + "README")
    _round_trip(data, ZLIB_WINDOW_BITS_RAW, ZLIB_WINDOW_BITS_RAW)


def test_round_trip_single_byte_every_level() raises:
    var data = _filled(1, 42)
    for level in range(10):
        var packed = _filled(zlib_compress_bound(1, ZLIB_WINDOW_BITS_GZIP), 0)
        var plen = zlib_deflate_into(
            Span(packed), Span(data), Int32(level), ZLIB_WINDOW_BITS_GZIP
        )
        var out = _filled(1, 0)
        assert_equal(zlib_inflate_into(Span(out), Span(packed)[0:plen]), 1)
        assert_equal(Int(out[0]), 42)


# --- empty input --------------------------------------------------------------


def test_empty_source_is_an_empty_stream() raises:
    var empty = List[UInt8]()
    var packed = _filled(zlib_compress_bound(0, ZLIB_WINDOW_BITS_GZIP), 0)
    var plen = zlib_deflate_into(
        Span(packed), Span(empty), ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_GZIP
    )
    # RFC 1952: a 10-byte header, the 2-byte empty final block, an 8-byte
    # trailer.
    assert_equal(plen, 20)
    var none = List[UInt8]()
    assert_equal(zlib_inflate_into(Span(none), Span(packed)[0:plen]), 0)
    var some = _filled(8, 0xAA)
    assert_equal(zlib_inflate_into(Span(some), Span(packed)[0:plen]), 0)
    assert_equal(Int(some[0]), 0xAA)


def test_empty_source_does_not_inflate() raises:
    var empty = List[UInt8]()
    var out = _filled(8, 0)
    _raises_containing(
        Span(out), Span(empty), ZLIB_WINDOW_BITS_AUTO, "empty source"
    )


# --- too-small destination ----------------------------------------------------


def test_inflate_refuses_a_destination_one_byte_short() raises:
    var gz = _read(_TARBALL)
    var tar = _filled(_isize(gz) - 1, 0)
    _raises_containing(Span(tar), Span(gz), ZLIB_WINDOW_BITS_AUTO, "more than")


def test_raw_inflate_refuses_a_destination_one_byte_short() raises:
    """Raw deflate has no trailer, so libz can take in the last input bytes
    before the output fills; the refusal must still name the destination."""
    var data = _read(_MEMBER_DIR + "README")
    var packed = _filled(
        zlib_compress_bound(len(data), ZLIB_WINDOW_BITS_RAW), 0
    )
    var plen = zlib_deflate_into(
        Span(packed), Span(data), ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_RAW
    )
    var out = _filled(len(data) - 1, 0)
    _raises_containing(
        Span(out), Span(packed)[0:plen], ZLIB_WINDOW_BITS_RAW, "more than"
    )


def test_inflate_refuses_an_empty_destination() raises:
    var data = _varied(100)
    var packed = _filled(zlib_compress_bound(100, ZLIB_WINDOW_BITS_ZLIB), 0)
    var plen = zlib_deflate_into(
        Span(packed), Span(data), ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_ZLIB
    )
    var none = List[UInt8]()
    _raises_containing(
        Span(none), Span(packed)[0:plen], ZLIB_WINDOW_BITS_AUTO, "more than"
    )


def test_deflate_refuses_a_destination_below_the_bound() raises:
    var data = _read(_MEMBER_DIR + "README")
    var need = zlib_compress_bound(len(data), ZLIB_WINDOW_BITS_GZIP)
    var short = _filled(need - 1, 0xAA)
    var raised = False
    try:
        _ = zlib_deflate_into(
            Span(short), Span(data), ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_GZIP
        )
    except e:
        raised = True
        assert_true("zlib_compress_bound" in String(e), String(e))
    assert_true(raised, "a destination below the bound must be refused")
    # Refused before libz ran: nothing was written.
    for i in range(len(short)):
        assert_equal(Int(short[i]), 0xAA)


# --- corrupt and truncated input ----------------------------------------------


def test_gzip_crc_mismatch_is_refused() raises:
    """The trailer's CRC-32 (8 bytes from the end) no longer matches."""
    var gz = _read(_TARBALL)
    gz[len(gz) - 8] ^= 0x01
    var tar = _filled(_isize(gz), 0)
    _raises_containing(Span(tar), Span(gz), ZLIB_WINDOW_BITS_AUTO, "corrupt")


def test_zlib_adler_mismatch_is_refused() raises:
    """The zlib trailer is the Adler-32 of the data, its last 4 bytes."""
    var data = _varied(4096)
    var packed = _filled(
        zlib_compress_bound(len(data), ZLIB_WINDOW_BITS_ZLIB), 0
    )
    var plen = zlib_deflate_into(
        Span(packed), Span(data), ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_ZLIB
    )
    packed[plen - 1] ^= 0x01
    var out = _filled(len(data), 0)
    _raises_containing(
        Span(out), Span(packed)[0:plen], ZLIB_WINDOW_BITS_AUTO, "corrupt"
    )


def test_bad_header_is_refused() raises:
    var gz = _read(_TARBALL)
    gz[0] = 0x00  # gzip's first magic byte is 0x1f
    var tar = _filled(_isize(gz), 0)
    _raises_containing(Span(tar), Span(gz), ZLIB_WINDOW_BITS_AUTO, "corrupt")


def test_truncated_stream_is_refused() raises:
    var gz = _read(_TARBALL)
    var tar = _filled(_isize(gz), 0)
    _raises_containing(
        Span(tar), Span(gz)[0 : len(gz) - 9], ZLIB_WINDOW_BITS_AUTO, "truncated"
    )


def test_gzip_missing_its_isize_is_refused() raises:
    """The deflate data and the CRC-32 are whole and the output is exactly
    full; only the 4-byte ISIZE is missing. A caller checking the count
    written against the expected size cannot see this."""
    var gz = _read(_TARBALL)
    var tar = _filled(_isize(gz), 0)
    _raises_containing(
        Span(tar), Span(gz)[0 : len(gz) - 4], ZLIB_WINDOW_BITS_AUTO, "truncated"
    )


def test_gzip_missing_its_whole_trailer_is_refused() raises:
    """The deflate data is whole and the output is exactly full; the 8-byte
    trailer (CRC-32, ISIZE) is missing."""
    var gz = _read(_TARBALL)
    var tar = _filled(_isize(gz), 0)
    _raises_containing(
        Span(tar), Span(gz)[0 : len(gz) - 8], ZLIB_WINDOW_BITS_AUTO, "truncated"
    )


def test_zlib_missing_its_adler_is_refused() raises:
    """The deflate data is whole and the output is exactly full; the 4-byte
    Adler-32 trailer is missing."""
    var data = _varied(4096)
    var packed = _filled(
        zlib_compress_bound(len(data), ZLIB_WINDOW_BITS_ZLIB), 0
    )
    var plen = zlib_deflate_into(
        Span(packed), Span(data), ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_ZLIB
    )
    var out = _filled(len(data), 0)
    for bits in [ZLIB_WINDOW_BITS_ZLIB, ZLIB_WINDOW_BITS_AUTO]:
        _raises_containing(
            Span(out), Span(packed)[0 : plen - 4], bits, "truncated"
        )


# --- skipping streams ---------------------------------------------------------


def test_skip_stream_finds_the_next_stream() raises:
    var first = _varied(3000)
    var second = _read(_MEMBER_DIR + "README")
    var bound = zlib_compress_bound(len(first), ZLIB_WINDOW_BITS_ZLIB)
    bound += zlib_compress_bound(len(second), ZLIB_WINDOW_BITS_ZLIB)
    var packed = _filled(bound, 0)
    var a = zlib_deflate_into(
        Span(packed), Span(first), ZLIB_LEVEL_DEFAULT, ZLIB_WINDOW_BITS_ZLIB
    )
    var b = zlib_deflate_into(
        Span(packed)[a:],
        Span(second),
        ZLIB_LEVEL_DEFAULT,
        ZLIB_WINDOW_BITS_ZLIB,
    )
    var both = Span(packed)[0 : a + b]
    assert_equal(zlib_skip_stream(both), a)
    var out = _filled(len(second), 0)
    assert_equal(zlib_inflate_into(Span(out), both[a:]), len(second))
    _assert_same(Span(out), Span(second))


def test_skip_stream_refuses_truncated_and_empty() raises:
    var gz = _read(_TARBALL)
    var raised = False
    try:
        _ = zlib_skip_stream(Span(gz)[0 : len(gz) - 9])
    except:
        raised = True
    assert_true(raised, "a truncated stream cannot be skipped")
    var empty = List[UInt8]()
    raised = False
    try:
        _ = zlib_skip_stream(Span(empty))
    except:
        raised = True
    assert_true(raised, "an empty source cannot be skipped")


# --- crc32 --------------------------------------------------------------------


def test_crc32_check_value() raises:
    # The CRC-32 check value of the ASCII digits "123456789" (the catalogue
    # value for CRC-32/ISO-HDLC, the gzip polynomial), and of nothing.
    var digits = List[UInt8](capacity=9)
    for d in range(9):
        digits.append(UInt8(0x31 + d))
    assert_equal(Int(zlib_crc32(Span(digits))), 0xCBF43926)
    var empty = List[UInt8]()
    assert_equal(Int(zlib_crc32(Span(empty))), 0)


def test_crc32_matches_the_tarball_trailer() raises:
    # RFC 1952: the member ends with CRC32 then ISIZE, both little-endian.
    var gz = _read(_TARBALL)
    var n = len(gz)
    var want = (
        Int(gz[n - 8])
        | (Int(gz[n - 7]) << 8)
        | (Int(gz[n - 6]) << 16)
        | (Int(gz[n - 5]) << 24)
    )
    var tar = _inflated_tarball()
    assert_equal(Int(zlib_crc32(Span(tar))), want)
    # Continued over two pieces, the same value.
    var half = len(tar) // 2
    var first = zlib_crc32(Span(tar)[0:half])
    assert_equal(Int(zlib_crc32(Span(tar)[half:], first)), want)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
