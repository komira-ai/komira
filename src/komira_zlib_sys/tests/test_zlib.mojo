# =============================================================================
# test_zlib.mojo: zlib 1.3.2, linked statically, called through FFI
# =============================================================================
#
# komira_zlib_sys has an empty Mojo module: it ships the C library and nothing
# else. This test is the one place in the package that declares zlib's
# functions, and it calls them as a consumer of lib/libkomira_zlib_sys.a would,
# with `external_call`. It links the package's own archive, the one declared
# as `[native.komira_zlib_sys]` in mopm.toml.
#
# What each test would catch if zlib were built or vendored wrongly:
#   * the version string      a different release in the vendor directory, or
#                             another libz on the link line winning
#   * crc32 / adler32         a miscompiled table or loop; the values are the
#                             published check values, not read back from zlib
#   * compress, uncompress    the deflate and inflate halves disagreeing, at
#                             every level, on empty, text and incompressible data
#   * exact stream bytes      a changed default level or header; the two streams
#                             are derived from RFC 1950 and RFC 1951
#   * corrupt and short input refusals that became silent success
#
# FFI-BOUNDARY: every pointer handed to zlib below points into a `List[UInt8]`
# or a local `UInt64` of the calling frame, which outlives the synchronous
# call; zlib keeps none of them. The one pointer zlib returns, from
# zlibVersion(), is a static string owned by the library: it is read to its NUL
# inside `_zlib_version` and never leaves that function.
# =============================================================================

from std.ffi import external_call
from std.memory import UnsafePointer
from std.testing import TestSuite, assert_equal, assert_true

comptime Z_OK: Int32 = 0
comptime Z_BUF_ERROR: Int32 = -5
comptime Z_DATA_ERROR: Int32 = -3
comptime Z_DEFAULT_COMPRESSION: Int32 = -1


# SAFETY: private FFI shim. The untracked-origin result is a static string in
# the library and never leaves this function.
def _zlib_version() -> String:
    var p = external_call[
        "zlibVersion", UnsafePointer[UInt8, MutUntrackedOrigin]
    ]()
    var n = 0
    while p[n] != UInt8(0):
        n += 1
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(p[i])
    return String(unsafe_from_utf8=out)


def _crc32(crc: UInt64, data: Span[UInt8, _]) -> UInt64:
    # SAFETY: `data` holds `len(data)` readable bytes for this synchronous call.
    return external_call["crc32", UInt64](
        crc, data.unsafe_ptr(), UInt32(len(data))
    )


def _adler32(adler: UInt64, data: Span[UInt8, _]) -> UInt64:
    # SAFETY: as `_crc32`.
    return external_call["adler32", UInt64](
        adler, data.unsafe_ptr(), UInt32(len(data))
    )


def _compress_bound(n: Int) -> Int:
    return Int(external_call["compressBound", UInt64](UInt64(n)))


def _compress(src: Span[UInt8, _], level: Int32) raises -> List[UInt8]:
    var cap = _compress_bound(len(src))
    var dst = List[UInt8](length=cap, fill=UInt8(0))
    var dst_len = UInt64(cap)
    # SAFETY: `dst` holds `cap` writable bytes and `src` holds `len(src)`
    # readable bytes; `dst_len` is a local the call reads and updates.
    var rc = external_call["compress2", Int32](
        dst.unsafe_ptr(),
        UnsafePointer(to=dst_len),
        src.unsafe_ptr(),
        UInt64(len(src)),
        level,
    )
    assert_equal(Int(rc), Int(Z_OK), "compress2")
    dst.resize(Int(dst_len), UInt8(0))
    return dst^


# The return code of `uncompress` into a buffer of `cap` bytes, and the bytes
# written (empty unless the code is Z_OK).
struct Inflated(Movable):
    var rc: Int32
    var bytes: List[UInt8]

    def __init__(out self, rc: Int32, var bytes: List[UInt8]):
        self.rc = rc
        self.bytes = bytes^


def _uncompress(packed: Span[UInt8, _], cap: Int) -> Inflated:
    var dst = List[UInt8](length=max(cap, 1), fill=UInt8(0))
    var dst_len = UInt64(cap)
    # SAFETY: `dst` holds at least `cap` writable bytes (one more than `cap`
    # when `cap` is 0, so the pointer is never null) and `packed` holds
    # `len(packed)` readable bytes; `dst_len` is a local the call updates.
    var rc = external_call["uncompress", Int32](
        dst.unsafe_ptr(),
        UnsafePointer(to=dst_len),
        packed.unsafe_ptr(),
        UInt64(len(packed)),
    )
    if rc != Z_OK:
        return Inflated(rc, List[UInt8]())
    dst.resize(Int(dst_len), UInt8(0))
    return Inflated(rc, dst^)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8](capacity=len(s))
    for b in s.as_bytes():
        out.append(b)
    return out^


def _same(got: Span[UInt8, _], want: Span[UInt8, _]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(got)):
        if got[i] != want[i]:
            assert_equal(Int(got[i]), Int(want[i]), "byte " + String(i))


# Bytes that do not compress: a fixed linear congruential sequence.
def _noise(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    var x = UInt32(2463534242)
    for _ in range(n):
        x = x * UInt32(1664525) + UInt32(1013904223)
        out.append(UInt8((x >> 24) & UInt32(0xFF)))
    return out^


def _text(n: Int) -> List[UInt8]:
    var unit = _bytes("zlib compresses repeated text very well. ")
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(unit[i % len(unit)])
    return out^


# --- the library is the vendored release -------------------------------------


def test_zlib_version_is_the_vendored_release() raises:
    # vendor/zlib-1.3.2 is the tree compiled into the archive; this holds the
    # compiled library to that release.
    assert_equal(_zlib_version(), String("1.3.2"))


# --- checksums: the published check values -----------------------------------


def test_crc32_check_values() raises:
    # CRC-32 (the gzip and PNG polynomial): the standard check value of
    # "123456789", and a second well-known text.
    var nine = _bytes("123456789")
    assert_equal(Int(_crc32(0, Span(nine))), 0xCBF43926)
    var fox = _bytes("The quick brown fox jumps over the lazy dog")
    assert_equal(Int(_crc32(0, Span(fox))), 0x414FA339)
    var none = List[UInt8]()
    assert_equal(Int(_crc32(0, Span(none))), 0)


def test_crc32_is_incremental() raises:
    var fox = _bytes("The quick brown fox jumps over the lazy dog")
    var whole = _crc32(0, Span(fox))
    for cut in range(len(fox) + 1):
        var head = _crc32(0, Span(fox)[0:cut])
        var both = _crc32(head, Span(fox)[cut : len(fox)])
        assert_equal(Int(both), Int(whole), "cut " + String(cut))


def test_adler32_check_values() raises:
    # Adler-32 of RFC 1950: "123456789" worked by hand (a = 478, b = 2334), and
    # the "Wikipedia" example. The checksum of nothing is 1.
    var nine = _bytes("123456789")
    assert_equal(Int(_adler32(1, Span(nine))), 0x091E01DE)
    var wiki = _bytes("Wikipedia")
    assert_equal(Int(_adler32(1, Span(wiki))), 0x11E60398)
    var none = List[UInt8]()
    assert_equal(Int(_adler32(1, Span(none))), 1)


def test_adler32_is_incremental() raises:
    var data = _text(20000)
    var whole = _adler32(1, Span(data))
    var head = _adler32(1, Span(data)[0:7001])
    var both = _adler32(head, Span(data)[7001:20000])
    assert_equal(Int(both), Int(whole))


# --- compress, then uncompress ----------------------------------------------


def _round_trip(data: List[UInt8], level: Int32) raises:
    var packed = _compress(Span(data), level)
    var back = _uncompress(Span(packed), len(data))
    assert_equal(Int(back.rc), Int(Z_OK), "uncompress")
    _same(Span(back.bytes), Span(data))


def test_round_trip_every_level_on_text() raises:
    var data = _text(10000)
    for level in range(0, 10):
        _round_trip(data, Int32(level))
    _round_trip(data, Z_DEFAULT_COMPRESSION)


def test_round_trip_on_incompressible_data() raises:
    var data = _noise(5000)
    for level in range(0, 10):
        _round_trip(data, Int32(level))


def test_round_trip_on_empty_input() raises:
    var data = List[UInt8]()
    _round_trip(data, Z_DEFAULT_COMPRESSION)


def test_text_shrinks_and_noise_stays_within_the_bound() raises:
    var text = _text(10000)
    var packed = _compress(Span(text), Int32(9))
    assert_true(len(packed) < 400, "text of 10000 bytes took " + String(len(packed)))
    var noise = _noise(5000)
    var big = _compress(Span(noise), Int32(9))
    assert_true(len(big) <= _compress_bound(5000))
    assert_true(len(big) > 5000, "noise cannot shrink")


# --- exact streams (RFC 1950 and RFC 1951) -----------------------------------


def test_compress_abc_at_the_default_level_is_the_fixed_huffman_stream() raises:
    # zlib header 78 9c, one final block of fixed Huffman codes for "abc",
    # then Adler-32("abc") = 024d0127 big-endian.
    var abc = _bytes("abc")
    var packed = _compress(Span(abc), Z_DEFAULT_COMPRESSION)
    var want = List[UInt8](
        0x78, 0x9C, 0x4B, 0x4C, 0x4A, 0x06, 0x00, 0x02, 0x4D, 0x01, 0x27
    )
    _same(Span(packed), Span(want))


def test_compress_abc_at_level_0_is_a_stored_block() raises:
    # header 78 01; final stored block: 01, LEN 0003, NLEN fffc; "abc"; Adler-32.
    var abc = _bytes("abc")
    var packed = _compress(Span(abc), Int32(0))
    var want = List[UInt8](
        0x78, 0x01, 0x01, 0x03, 0x00, 0xFC, 0xFF, 0x61, 0x62, 0x63,
        0x02, 0x4D, 0x01, 0x27,
    )
    _same(Span(packed), Span(want))


def test_uncompress_reads_a_stream_it_did_not_write() raises:
    var stream = List[UInt8](
        0x78, 0x9C, 0x4B, 0x4C, 0x4A, 0x06, 0x00, 0x02, 0x4D, 0x01, 0x27
    )
    var got = _uncompress(Span(stream), 16)
    assert_equal(Int(got.rc), Int(Z_OK))
    var abc = _bytes("abc")
    _same(Span(got.bytes), Span(abc))


# --- refusals ----------------------------------------------------------------


def test_uncompress_refuses_a_flipped_checksum() raises:
    var stream = List[UInt8](
        0x78, 0x9C, 0x4B, 0x4C, 0x4A, 0x06, 0x00, 0x02, 0x4D, 0x01, 0x28
    )
    var got = _uncompress(Span(stream), 16)
    assert_equal(Int(got.rc), Int(Z_DATA_ERROR))


def test_uncompress_refuses_a_flipped_data_byte() raises:
    var data = _text(2000)
    var packed = _compress(Span(data), Z_DEFAULT_COMPRESSION)
    packed[len(packed) // 2] = packed[len(packed) // 2] ^ UInt8(0x55)
    var got = _uncompress(Span(packed), len(data))
    assert_true(got.rc != Z_OK, "a corrupt stream was accepted")


def test_uncompress_refuses_a_truncated_stream() raises:
    var data = _text(2000)
    var packed = _compress(Span(data), Z_DEFAULT_COMPRESSION)
    var got = _uncompress(Span(packed)[0 : len(packed) - 3], len(data) + 100)
    assert_true(got.rc != Z_OK, "a truncated stream was accepted")


def test_uncompress_into_a_short_buffer_reports_buf_error() raises:
    var data = _text(2000)
    var packed = _compress(Span(data), Z_DEFAULT_COMPRESSION)
    var got = _uncompress(Span(packed), 1999)
    assert_equal(Int(got.rc), Int(Z_BUF_ERROR))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
