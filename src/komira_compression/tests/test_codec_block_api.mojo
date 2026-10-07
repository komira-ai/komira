# =============================================================================
# test_codec_block_api.mojo
# =============================================================================
#
# The codec API this package owns for other packages: snappy_block,
# zstd_frame, bzip2_buffer, xz_buffer and the zlib / lz4 re-exports. For each
# codec: a round trip of the empty input and of 4 KiB of incompressible
# bytes, a hand-built or known stream decoded to its exact bytes where one is
# small enough to write here, a destination of exactly the decoded size with
# sentinel bytes past it (nothing is written there), a destination one byte
# short, and a corrupt input refused with the exact message.
#
# What it catches: a capacity passed to the C library that is not `len(dst)`
# (the sentinels change, or the short destination is accepted), a status
# code read as success, a zlib_inflate_once with an empty destination that
# drops the source instead of handing it to libz, the Optional "destination
# full" answers of bzip2 / xz swapped with a raise, and an error message that
# drops the code, the input length or the capacity.
#
# What it cannot catch: an empty Span handed to C as a null pointer. Spans
# and Lists built in Mojo carry a dangling, non-null pointer when empty, so
# no test here can hand C a null, and removing the empty-Span scratch
# branches leaves these tests green. snappy, libzstd and liblzma accept a
# null pointer at length 0 anyway; libbz2 refuses it (BZ_PARAM_ERROR, -2,
# whatever the length), so the scratch branch in bzip2_buffer is what keeps
# an empty Span built from a null pointer working.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_compression.bzip2_buffer import (
    BZIP2_DEFAULT_BLOCK_SIZE_100K,
    BZIP2_DEFAULT_WORK_FACTOR,
    bzip2_compress_into,
    bzip2_decompress_into,
)
from komira_compression.lz4 import (
    lz4_frame_compress_bound,
    lz4_frame_compress_into,
    lz4_frames_decompress_into,
)
from komira_compression.snappy_block import (
    snappy_compress_into,
    snappy_max_compressed_length,
    snappy_uncompress_into,
    snappy_uncompressed_length,
)
from komira_compression.xz_buffer import (
    XZ_CHECK_CRC64,
    XZ_DEFAULT_MEMLIMIT,
    XZ_PRESET_DEFAULT,
    xz_compress_into,
    xz_decompress_into,
)
from komira_compression.zlib import (
    ZLIB_WINDOW_BITS_RAW,
    Z_BUF_ERROR,
    Z_OK,
    Z_STREAM_END,
    zlib_inflate_once,
)
from komira_compression.zstd_frame import (
    ZSTD_DEFAULT_LEVEL,
    zstd_compress_bound,
    zstd_compress_into,
    zstd_decompress_into,
    zstd_frame_content_size,
)

comptime _SENTINEL: UInt8 = 0xA5
comptime _PAD: Int = 16


def _incompressible(n: Int) -> List[UInt8]:
    """`n` bytes of a 32-bit LCG's high byte: no codec here shrinks them."""
    var out = List[UInt8](capacity=n)
    var state: UInt32 = 0x9E3779B9
    for _ in range(n):
        state = state * UInt32(1103515245) + UInt32(12345)
        out.append(UInt8((state >> 24) & 0xFF))
    return out^


def _bytes(s: StaticString) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _guarded(n: Int) -> List[UInt8]:
    """`n + _PAD` bytes of the sentinel: a destination is `[0:n]` of it."""
    return List[UInt8](length=n + _PAD, fill=_SENTINEL)


def _assert_pad_untouched(buf: List[UInt8], n: Int, what: String) raises:
    for i in range(n, len(buf)):
        assert_equal(buf[i], _SENTINEL, what + ": byte " + String(i) + " past the destination was written")


def _assert_same(got: Span[UInt8, _], want: Span[UInt8, _], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": byte " + String(i))


# -----------------------------------------------------------------------------
# snappy
# -----------------------------------------------------------------------------


def _snappy_compress(src: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8](length=snappy_max_compressed_length(len(src)), fill=0)
    var n = snappy_compress_into(Span(out), Span(src))
    out.resize(unsafe_uninit_length=n)
    return out^


def test_snappy_empty_and_incompressible_round_trip() raises:
    var empty = List[UInt8]()
    var packed = _snappy_compress(empty)
    # The empty block is its length preamble, the varint 0.
    assert_equal(len(packed), 1)
    assert_equal(packed[0], 0)
    assert_equal(snappy_uncompressed_length(Span(packed)), 0)
    var none = List[UInt8]()
    assert_equal(snappy_uncompress_into(Span(none), Span(packed)), 0)

    var data = _incompressible(4096)
    packed = _snappy_compress(data)
    assert_true(len(packed) >= len(data), "random bytes do not shrink")
    assert_equal(snappy_uncompressed_length(Span(packed)), len(data))
    var dst = _guarded(len(data))
    var n = snappy_uncompress_into(Span(dst)[0 : len(data)], Span(packed))
    assert_equal(n, len(data))
    _assert_same(Span(dst)[0:n], Span(data), "snappy round trip")
    _assert_pad_untouched(dst, len(data), "snappy exact destination")


def test_snappy_hand_built_block() raises:
    # Preamble 5, then a literal tag ((5 - 1) << 2) and the five bytes.
    var block: List[UInt8] = [5, 0x10, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
    var dst = _guarded(5)
    assert_equal(snappy_uncompress_into(Span(dst)[0:5], Span(block)), 5)
    _assert_same(Span(dst)[0:5], Span(_bytes("hello")), "snappy literal")
    _assert_pad_untouched(dst, 5, "snappy literal")


def test_snappy_refusals_name_status_and_sizes() raises:
    var block: List[UInt8] = [5, 0x10, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
    var short = _guarded(4)
    var msg = String("")
    try:
        _ = snappy_uncompress_into(Span(short)[0:4], Span(block))
    except e:
        msg = String(e)
    assert_equal(
        msg, "snappy_uncompress failed (status=2, input_len=7, output_cap=4)"
    )
    _assert_pad_untouched(short, 0, "snappy short destination")

    # A copy tag whose offset reaches before the start of the output.
    var corrupt: List[UInt8] = [4, 0x01, 0x05]
    var dst = _guarded(4)
    msg = ""
    try:
        _ = snappy_uncompress_into(Span(dst)[0:4], Span(corrupt))
    except e:
        msg = String(e)
    assert_equal(
        msg, "snappy_uncompress failed (status=1, input_len=3, output_cap=4)"
    )

    var empty = List[UInt8]()
    msg = ""
    try:
        _ = snappy_uncompress_into(Span(dst)[0:4], Span(empty))
    except e:
        msg = String(e)
    assert_equal(
        msg, "snappy_uncompress failed (status=1, input_len=0, output_cap=4)"
    )
    msg = ""
    try:
        _ = snappy_uncompressed_length(Span(empty))
    except e:
        msg = String(e)
    assert_equal(msg, "snappy_uncompressed_length failed (status=1, input_len=0)")

    var data = _bytes("abc")
    var tiny = List[UInt8](length=snappy_max_compressed_length(3) - 1, fill=0)
    msg = ""
    try:
        _ = snappy_compress_into(Span(tiny), Span(data))
    except e:
        msg = String(e)
    assert_equal(
        msg, "snappy_compress failed (status=2, input_len=3, output_cap=34)"
    )


# -----------------------------------------------------------------------------
# zstd
# -----------------------------------------------------------------------------

# A single-segment frame holding one raw block: magic 28 B5 2F FD, frame
# header descriptor 0x20 (single segment, 1-byte content size), content size
# 5, block header 0x29 0x00 0x00 (last block, raw, size 5), then the bytes.
comptime _ZSTD_HELLO: List[UInt8] = [
    0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x05, 0x29, 0x00, 0x00,
    0x68, 0x65, 0x6C, 0x6C, 0x6F,
]


def test_zstd_known_frame_and_round_trips() raises:
    var frame = materialize[_ZSTD_HELLO]()
    assert_equal(zstd_frame_content_size(Span(frame)), UInt64(5))
    var dst = _guarded(5)
    assert_equal(zstd_decompress_into(Span(dst)[0:5], Span(frame)), 5)
    _assert_same(Span(dst)[0:5], Span(_bytes("hello")), "zstd raw block")
    _assert_pad_untouched(dst, 5, "zstd exact destination")

    var empty = List[UInt8]()
    var none = List[UInt8]()
    # libzstd decodes zero frames to zero bytes.
    assert_equal(zstd_decompress_into(Span(none), Span(empty)), 0)

    var cases = List[List[UInt8]]()
    cases.append(List[UInt8]())
    cases.append(_incompressible(4096))
    for c in range(len(cases)):
        var data = cases[c].copy()
        var packed = List[UInt8](length=zstd_compress_bound(len(data)), fill=0)
        var n = zstd_compress_into(Span(packed), Span(data), ZSTD_DEFAULT_LEVEL)
        packed.resize(unsafe_uninit_length=n)
        assert_equal(zstd_frame_content_size(Span(packed)), UInt64(len(data)))
        var out = _guarded(len(data))
        assert_equal(
            zstd_decompress_into(Span(out)[0 : len(data)], Span(packed)),
            len(data),
        )
        _assert_same(Span(out)[0 : len(data)], Span(data), "zstd round trip")
        _assert_pad_untouched(out, len(data), "zstd round trip")


def test_zstd_refusals_name_result_and_sizes() raises:
    var frame = materialize[_ZSTD_HELLO]()
    var short = _guarded(4)
    var msg = String("")
    try:
        _ = zstd_decompress_into(Span(short)[0:4], Span(frame))
    except e:
        msg = String(e)
    # dstSize_tooSmall is zstd error 70.
    assert_equal(
        msg, "ZSTD_decompress failed (result=-70, input_len=14, output_cap=4)"
    )
    _assert_pad_untouched(short, 4, "zstd short destination")

    var not_zstd = List[UInt8](length=16, fill=0x58)
    var dst = _guarded(16)
    msg = ""
    try:
        _ = zstd_decompress_into(Span(dst)[0:16], Span(not_zstd))
    except e:
        msg = String(e)
    # prefix_unknown (a bad magic number) is zstd error 10.
    assert_equal(
        msg, "ZSTD_decompress failed (result=-10, input_len=16, output_cap=16)"
    )

    msg = ""
    try:
        _ = zstd_decompress_into(Span(dst)[0:16], Span(frame)[0:13])
    except e:
        msg = String(e)
    # srcSize_wrong (the raw block ends early) is zstd error 72.
    assert_equal(
        msg, "ZSTD_decompress failed (result=-72, input_len=13, output_cap=16)"
    )


# -----------------------------------------------------------------------------
# bzip2
# -----------------------------------------------------------------------------


def _bzip2_compress(src: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8](length=len(src) + len(src) // 100 + 600, fill=0)
    var n = bzip2_compress_into(
        Span(out), Span(src), BZIP2_DEFAULT_BLOCK_SIZE_100K,
        BZIP2_DEFAULT_WORK_FACTOR,
    )
    out.resize(unsafe_uninit_length=n)
    return out^


def test_bzip2_round_trips_and_full_destination() raises:
    var cases = List[List[UInt8]]()
    cases.append(List[UInt8]())
    cases.append(_incompressible(4096))
    for c in range(len(cases)):
        var data = cases[c].copy()
        var packed = _bzip2_compress(data)
        # "BZh9": the magic and the block size.
        assert_equal(packed[0], 0x42)
        assert_equal(packed[3], 0x39)
        var out = _guarded(len(data))
        var got = bzip2_decompress_into(Span(out)[0 : len(data)], Span(packed))
        assert_true(got, "bzip2 decoded into an exact destination")
        assert_equal(got.value(), len(data))
        _assert_same(Span(out)[0 : len(data)], Span(data), "bzip2 round trip")
        _assert_pad_untouched(out, len(data), "bzip2 round trip")

    var data = _incompressible(4096)
    var packed = _bzip2_compress(data)
    var short = _guarded(4095)
    var full = bzip2_decompress_into(Span(short)[0:4095], Span(packed))
    assert_false(full, "a destination one byte short is BZ_OUTBUFF_FULL")
    _assert_pad_untouched(short, 4095, "bzip2 short destination")


def test_bzip2_corrupt_stream_names_rc() raises:
    var not_bzip2 = List[UInt8](length=4, fill=0x58)
    var dst = _guarded(64)
    var msg = String("")
    try:
        _ = bzip2_decompress_into(Span(dst)[0:64], Span(not_bzip2))
    except e:
        msg = String(e)
    # BZ_DATA_ERROR_MAGIC is -5.
    assert_equal(
        msg,
        "BZ2_bzBuffToBuffDecompress failed (rc=-5, input_len=4, output_cap=64)",
    )


# -----------------------------------------------------------------------------
# xz
# -----------------------------------------------------------------------------


def _xz_compress(src: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8](length=len(src) + len(src) // 3 + 1024, fill=0)
    var n = xz_compress_into(Span(out), Span(src), XZ_PRESET_DEFAULT, XZ_CHECK_CRC64)
    out.resize(unsafe_uninit_length=n)
    return out^


def test_xz_round_trips_and_full_destination() raises:
    var cases = List[List[UInt8]]()
    cases.append(List[UInt8]())
    cases.append(_incompressible(4096))
    for c in range(len(cases)):
        var data = cases[c].copy()
        var packed = _xz_compress(data)
        # FD 37 7A 58 5A 00: the .xz magic.
        assert_equal(packed[0], 0xFD)
        assert_equal(packed[5], 0x00)
        var out = _guarded(len(data))
        var got = xz_decompress_into(
            Span(out)[0 : len(data)], Span(packed), XZ_DEFAULT_MEMLIMIT
        )
        assert_true(got, "xz decoded into an exact destination")
        assert_equal(got.value(), len(data))
        _assert_same(Span(out)[0 : len(data)], Span(data), "xz round trip")
        _assert_pad_untouched(out, len(data), "xz round trip")

    var data = _incompressible(4096)
    var packed = _xz_compress(data)
    var short = _guarded(4095)
    var full = xz_decompress_into(Span(short)[0:4095], Span(packed), XZ_DEFAULT_MEMLIMIT)
    assert_false(full, "a destination one byte short is LZMA_BUF_ERROR")
    _assert_pad_untouched(short, 4095, "xz short destination")


def test_xz_corrupt_stream_names_rc() raises:
    var not_xz = List[UInt8](length=16, fill=0x58)
    var dst = _guarded(64)
    var msg = String("")
    try:
        _ = xz_decompress_into(Span(dst)[0:64], Span(not_xz), XZ_DEFAULT_MEMLIMIT)
    except e:
        msg = String(e)
    # LZMA_FORMAT_ERROR is 7.
    assert_equal(
        msg,
        "lzma_stream_buffer_decode failed (rc=7, input_len=16, output_cap=64)",
    )


def test_xz_truncated_stream_is_none_or_data_error_and_empty_is_data_error() raises:
    # What liblzma returns for a non-empty stream cut short depends on its
    # version (liblzma.so.5 is the system's): before xz 5.8.4 (and the same
    # fix on the v5.2, v5.4 and v5.6 branches) LZMA_BUF_ERROR, so None, the
    # same as a short destination; from 5.8.4 on LZMA_DATA_ERROR (9), which
    # raises. Either is accepted, but nothing else: no byte count, no other
    # rc, no write past the destination. An empty input is LZMA_DATA_ERROR
    # in every version.
    var data = _incompressible(4096)
    var packed = _xz_compress(data)
    var cuts = List[Int]()
    cuts.append(len(packed) - 1)  # only the stream footer's last byte gone
    cuts.append(len(packed) // 2)  # mid-block
    cuts.append(1)  # inside the magic
    for c in range(len(cuts)):
        var cut = cuts[c]
        var dst = _guarded(8192)
        var outcome = String("")
        try:
            var got = xz_decompress_into(
                Span(dst)[0:8192], Span(packed)[0:cut], XZ_DEFAULT_MEMLIMIT
            )
            outcome = "returned " + (String(got.value()) if got else String("None"))
        except e:
            outcome = String(e)
        var as_data_error = (
            "lzma_stream_buffer_decode failed (rc=9, input_len=" + String(cut)
            + ", output_cap=8192)"
        )
        if outcome != as_data_error:
            assert_equal(
                outcome,
                "returned None",
                "a truncated .xz is None or rc=9 (cut " + String(cut) + ")",
            )
        _assert_pad_untouched(dst, 8192, "xz truncated stream")

    var empty = List[UInt8]()
    var dst = _guarded(64)
    var msg = String("")
    try:
        var got = xz_decompress_into(Span(dst)[0:64], Span(empty), XZ_DEFAULT_MEMLIMIT)
        msg = "returned " + (String(got.value()) if got else String("None"))
    except e:
        msg = String(e)
    # LZMA_DATA_ERROR is 9.
    assert_equal(
        msg,
        "lzma_stream_buffer_decode failed (rc=9, input_len=0, output_cap=64)",
    )


# -----------------------------------------------------------------------------
# zlib (komira_zlib through this package)
# -----------------------------------------------------------------------------

# Raw deflate, one stored block: BFINAL=1 BTYPE=00, LEN 5, NLEN ~5, "hello".
comptime _RAW_HELLO: List[UInt8] = [
    0x01, 0x05, 0x00, 0xFA, 0xFF, 0x68, 0x65, 0x6C, 0x6C, 0x6F,
]


def test_zlib_inflate_once_hands_back_libz_state() raises:
    var stream = materialize[_RAW_HELLO]()
    var dst = _guarded(5)
    var done = zlib_inflate_once(Span(dst)[0:5], Span(stream), ZLIB_WINDOW_BITS_RAW)
    assert_equal(done.rc, Z_STREAM_END)
    assert_equal(done.written, 5)
    _assert_same(Span(dst)[0:5], Span(_bytes("hello")), "raw deflate")
    _assert_pad_untouched(dst, 5, "raw deflate")

    # Destination full: progress made, so Z_OK, with input left unread.
    var short = _guarded(3)
    var full = zlib_inflate_once(Span(short)[0:3], Span(stream), ZLIB_WINDOW_BITS_RAW)
    assert_equal(full.rc, Z_OK)
    assert_equal(full.written, 3)
    assert_equal(full.unwritten, 0)
    assert_true(full.unread > 0, "input left unread")
    _assert_pad_untouched(short, 3, "raw deflate short destination")

    # Source cut two bytes early: progress made, input used up, room left.
    var big = _guarded(16)
    var cut = zlib_inflate_once(Span(big)[0:16], Span(stream)[0:8], ZLIB_WINDOW_BITS_RAW)
    assert_equal(cut.rc, Z_OK)
    assert_equal(cut.written, 3)
    assert_equal(cut.unread, 0)
    assert_equal(cut.unwritten, 13)

    # Empty source: no progress possible.
    var empty = List[UInt8]()
    var none = zlib_inflate_once(Span(big)[0:16], Span(empty), ZLIB_WINDOW_BITS_RAW)
    assert_equal(none.rc, Z_BUF_ERROR)
    assert_equal(none.written, 0)

    # Empty destination: libz still reads the stored block's 5-byte header
    # and stops at the first output byte; progress made, so Z_OK.
    var no_room = List[UInt8]()
    var stuck = zlib_inflate_once(Span(no_room), Span(stream), ZLIB_WINDOW_BITS_RAW)
    assert_equal(stuck.rc, Z_OK)
    assert_equal(stuck.written, 0)
    assert_equal(stuck.unwritten, 0)
    assert_equal(stuck.unread, len(stream) - 5)


# -----------------------------------------------------------------------------
# lz4 frames (komira_lz4 through this package)
# -----------------------------------------------------------------------------


def _lz4_frame(src: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8](length=lz4_frame_compress_bound(len(src)), fill=0)
    var n = lz4_frame_compress_into(Span(out), Span(src))
    out.resize(unsafe_uninit_length=n)
    return out^


def test_lz4_frames_concatenated_truncated_and_short() raises:
    var a = _incompressible(4096)
    var b = _bytes("hello")
    var two = _lz4_frame(a)
    two.extend(Span(_lz4_frame(b)))
    var whole = a.copy()
    whole.extend(Span(b))
    var dst = _guarded(len(whole))
    var n = lz4_frames_decompress_into(Span(dst)[0 : len(whole)], Span(two))
    assert_equal(n, len(whole))
    _assert_same(Span(dst)[0:n], Span(whole), "two lz4 frames")
    _assert_pad_untouched(dst, len(whole), "two lz4 frames")

    var empty_frame = _lz4_frame(List[UInt8]())
    var none = List[UInt8]()
    assert_equal(lz4_frames_decompress_into(Span(none), Span(empty_frame)), 0)

    var one = _lz4_frame(a)
    # Without its 4-byte end mark the frame has not ended; the destination
    # has room left, so the input ran out first.
    var cut = len(one) - 4
    var room = _guarded(len(a) + 8)
    var msg = String("")
    try:
        _ = lz4_frames_decompress_into(
            Span(room)[0 : len(a) + 8], Span(one)[0:cut]
        )
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "LZ4F frame truncated: the " + String(cut)
        + "-byte input ends before the frame does",
    )

    # The same cut frame into a destination its data exactly fills: the
    # input and the room ran out together, which reads as a full destination
    # (a grow-and-retry caller grows, then sees the truncation).
    var exact = _guarded(len(a))
    msg = ""
    try:
        _ = lz4_frames_decompress_into(Span(exact)[0 : len(a)], Span(one)[0:cut])
    except e:
        msg = String(e)
    assert_equal(msg, "LZ4F dst buffer too small")

    var short = _guarded(len(a) - 1)
    msg = ""
    try:
        _ = lz4_frames_decompress_into(Span(short)[0 : len(a) - 1], Span(one))
    except e:
        msg = String(e)
    assert_equal(msg, "LZ4F dst buffer too small")
    _assert_pad_untouched(short, len(a) - 1, "lz4 short destination")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
