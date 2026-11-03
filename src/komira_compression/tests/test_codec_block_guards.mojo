# =============================================================================
# test_codec_block_guards.mojo
# =============================================================================
#
# The guards of the block API (snappy_block, zstd_frame, bzip2_buffer,
# xz_buffer) that test_codec_block_api.mojo does not reach:
#   * a compress into a destination too small for the stream, refused by each
#     library with its own code (zstd error 70, BZ_OUTBUFF_FULL -8,
#     LZMA_BUF_ERROR 10) and the input length and capacity in the message;
#   * a negative length handed to `zstd_compress_bound`;
#   * a source past libbz2's 32-bit length, at the boundary (2^32 - 1 is
#     accepted, 2^32 is refused) without allocating it;
#   * the check behind every entry that a length the C library stored back is
#     within the capacity it was given (snappy and libzstd never break it, so
#     the check is called here with both answers);
#   * parameters the libraries refuse: a bzip2 block size of 0 or 10 and a
#     work factor of 251 (BZ_PARAM_ERROR -2), an xz preset of 10
#     (LZMA_OPTIONS_ERROR 8) and an integrity check id past the last one
#     (LZMA_PROG_ERROR 11);
#   * an xz decode with a 1-byte memory limit (LZMA_MEMLIMIT_ERROR 6);
#   * a bzip2 stream cut inside its trailer (None into an exact destination,
#     BZ_UNEXPECTED_EOF -7 with a byte more room) and one with a byte of
#     its block changed after valid headers (BZ_DATA_ERROR -4), with the bytes
#     past the destination checked after each.
# Every refusal is compared with its whole message.
#
# What it catches: a compress that reports success into a short destination,
# a bound that accepts a negative length, a 32-bit limit off by one, a
# written-length check that lets a length past the capacity through or
# refuses one at the capacity, and a message that drops the code or a size.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_compression.bzip2_buffer import (
    BZIP2_DEFAULT_BLOCK_SIZE_100K,
    BZIP2_DEFAULT_WORK_FACTOR,
    _check_source,
    bzip2_compress_into,
    bzip2_decompress_into,
)
from komira_compression.snappy_block import (
    _check_written as _snappy_check_written,
)
from komira_compression.xz_buffer import (
    XZ_CHECK_CRC64,
    XZ_DEFAULT_MEMLIMIT,
    XZ_PRESET_DEFAULT,
    xz_compress_into,
    xz_decompress_into,
)
from komira_compression.zstd_frame import (
    ZSTD_DEFAULT_LEVEL,
    _check_written as _zstd_check_written,
    zstd_compress_bound,
    zstd_compress_into,
)


def _incompressible(n: Int) -> List[UInt8]:
    """`n` bytes of a 32-bit LCG's high byte: no codec here shrinks them."""
    var out = List[UInt8](capacity=n)
    var state: UInt32 = 0x9E3779B9
    for _ in range(n):
        state = state * UInt32(1103515245) + UInt32(12345)
        out.append(UInt8((state >> 24) & 0xFF))
    return out^


def test_compress_into_a_short_destination_names_the_code() raises:
    var data = _incompressible(4096)
    var dst = List[UInt8](length=16, fill=0)

    var msg = String("")
    try:
        _ = zstd_compress_into(Span(dst)[0:1], Span(data), ZSTD_DEFAULT_LEVEL)
    except e:
        msg = String(e)
    # dstSize_tooSmall is zstd error 70.
    assert_equal(
        msg, "ZSTD_compress failed (result=-70, input_len=4096, output_cap=1)"
    )

    msg = ""
    try:
        _ = bzip2_compress_into(
            Span(dst),
            Span(data),
            BZIP2_DEFAULT_BLOCK_SIZE_100K,
            BZIP2_DEFAULT_WORK_FACTOR,
        )
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "BZ2_bzBuffToBuffCompress failed (rc=-8, input_len=4096,"
        " output_cap=16)",
    )

    msg = ""
    try:
        _ = xz_compress_into(Span(dst), Span(data), XZ_PRESET_DEFAULT, XZ_CHECK_CRC64)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "lzma_easy_buffer_encode failed (rc=10, input_len=4096, output_cap=16)",
    )


def test_zstd_compress_bound_refuses_a_negative_length() raises:
    assert_equal(zstd_compress_bound(0) > 0, True)
    var msg = String("")
    try:
        _ = zstd_compress_bound(-1)
    except e:
        msg = String(e)
    assert_equal(msg, "zstd_compress_bound: negative src_len -1")


def test_bzip2_source_limit_is_32_bits() raises:
    _check_source("bzip2_compress_into", 4294967295)
    var msg = String("")
    try:
        _check_source("bzip2_compress_into", 4294967296)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "bzip2_compress_into: a source of 4294967296 bytes is past libbz2's"
        " 32-bit length",
    )


def test_a_written_length_past_the_capacity_is_refused() raises:
    assert_equal(_snappy_check_written("snappy_compress", 8, 8), 8)
    assert_equal(_zstd_check_written("ZSTD_compress", 0, 8), 0)
    var msg = String("")
    try:
        _ = _snappy_check_written("snappy_uncompress", 9, 8)
    except e:
        msg = String(e)
    assert_equal(msg, "snappy_uncompress reported 9 bytes written into a 8-byte buffer")
    msg = ""
    try:
        _ = _zstd_check_written("ZSTD_decompress", 9, 8)
    except e:
        msg = String(e)
    assert_equal(msg, "ZSTD_decompress reported 9 bytes written into a 8-byte buffer")


comptime _SENTINEL: UInt8 = 0xA5
comptime _PAD: Int = 16


def _assert_pad_untouched(buf: List[UInt8], n: Int, what: String) raises:
    for i in range(n, len(buf)):
        assert_equal(buf[i], _SENTINEL, what + ": byte " + String(i) + " past the destination was written")


def _bzip2_refusal(block: Int32, work: Int32) raises -> String:
    var data = _incompressible(4096)
    var dst = List[UInt8](length=8192, fill=0)
    try:
        _ = bzip2_compress_into(Span(dst), Span(data), block, work)
    except e:
        return String(e)
    return ""


def _xz_refusal(preset: UInt32, check: Int32) raises -> String:
    var data = _incompressible(4096)
    var dst = List[UInt8](length=8192, fill=0)
    try:
        _ = xz_compress_into(Span(dst), Span(data), preset, check)
    except e:
        return String(e)
    return ""


def test_parameters_the_libraries_refuse_are_named() raises:
    var bz = "BZ2_bzBuffToBuffCompress failed (rc=-2, input_len=4096, output_cap=8192)"
    assert_equal(_bzip2_refusal(0, BZIP2_DEFAULT_WORK_FACTOR), bz)
    assert_equal(_bzip2_refusal(10, BZIP2_DEFAULT_WORK_FACTOR), bz)
    assert_equal(_bzip2_refusal(BZIP2_DEFAULT_BLOCK_SIZE_100K, 251), bz)
    assert_equal(
        _xz_refusal(10, XZ_CHECK_CRC64),
        "lzma_easy_buffer_encode failed (rc=8, input_len=4096, output_cap=8192)",
    )
    assert_equal(
        _xz_refusal(XZ_PRESET_DEFAULT, 16),
        "lzma_easy_buffer_encode failed (rc=11, input_len=4096, output_cap=8192)",
    )


def test_xz_decode_past_its_memory_limit_is_refused() raises:
    var data = _incompressible(4096)
    var packed = List[UInt8](length=8192, fill=0)
    var n = xz_compress_into(Span(packed), Span(data), XZ_PRESET_DEFAULT, XZ_CHECK_CRC64)
    packed.resize(unsafe_uninit_length=n)
    var out = List[UInt8](length=4096 + _PAD, fill=_SENTINEL)
    var msg = String("")
    try:
        _ = xz_decompress_into(Span(out)[0:4096], Span(packed), 1)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "lzma_stream_buffer_decode failed (rc=6, input_len=" + String(n)
        + ", output_cap=4096)",
    )
    _assert_pad_untouched(out, 4096, "xz memory limit")
    # The same stream within the default limit decodes.
    var got = xz_decompress_into(Span(out)[0:4096], Span(packed), XZ_DEFAULT_MEMLIMIT)
    assert_true(got)
    assert_equal(got.value(), 4096)


def test_bzip2_truncated_and_corrupted_streams_are_refused() raises:
    var data = _incompressible(4096)
    var packed = List[UInt8](length=8192, fill=0)
    var n = bzip2_compress_into(
        Span(packed), Span(data), BZIP2_DEFAULT_BLOCK_SIZE_100K, BZIP2_DEFAULT_WORK_FACTOR
    )
    packed.resize(unsafe_uninit_length=n)

    # Cut inside the end-of-stream trailer, after every decoded byte. Into a
    # destination of exactly the decoded size libbz2 answers BZ_OUTBUFF_FULL
    # (None: it cannot tell a full buffer from more data to come); with room
    # for one byte more it reaches the cut and answers BZ_UNEXPECTED_EOF.
    var out = List[UInt8](length=4097 + _PAD, fill=_SENTINEL)
    var cut = Span(packed)[0 : n - 10]
    var full = bzip2_decompress_into(Span(out)[0:4096], cut)
    assert_true(not full, "a cut trailer into an exact destination is None")
    var msg = String("")
    try:
        _ = bzip2_decompress_into(Span(out)[0:4097], cut)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "BZ2_bzBuffToBuffDecompress failed (rc=-7, input_len=" + String(n - 10)
        + ", output_cap=4097)",
    )
    _assert_pad_untouched(out, 4097, "bzip2 truncated")

    # The stream header ("BZh9") and the block magic stay; a byte in the
    # middle of the block changes, so the block's CRC no longer matches.
    var bad = packed.copy()
    bad[n // 2] = bad[n // 2] ^ UInt8(0xFF)
    msg = ""
    try:
        _ = bzip2_decompress_into(Span(out)[0:4097], Span(bad))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "BZ2_bzBuffToBuffDecompress failed (rc=-4, input_len=" + String(n)
        + ", output_cap=4097)",
    )
    _assert_pad_untouched(out, 4097, "bzip2 corrupted")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
