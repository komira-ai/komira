# =============================================================================
# test_codec_edges.mojo
# =============================================================================
#
# Boundary and failure inputs of the conformers past those of
# test_codec_conformers.mojo:
#   * Gzip at a level libz refuses (10), through both compress entries, and
#     Lz4Raw given a source one byte past LZ4_MAX_INPUT_SIZE: the refusals
#     keep the conformer's name in front of the library layer's message.
#   * Lz4Raw: the valid empty block decoded, a corrupt one-byte block, a
#     truncated block and a size one byte short of the decoded length.
#   * Snappy: a hand-built block with a copy tag decoded to its bytes, a
#     repetitive input (copy tags of the encoder) round-tripped, the length
#     varint at 127, 128, 16383 and 16384 bytes, a literal and a copy cut off
#     after a valid length preamble, and an `expected_size` past the decoded
#     length.
#   * Zstd: a cached context reused after a destination too small and after
#     a truncated frame (with the bytes past the destination checked), a
#     negative size or capacity at every sized entry, and levels 1 and 19.
#   * `_CodecDctxHandle`: a handle moved after it made a context keeps that
#     context, and two handles decoding in turn keep two contexts.
# Refusals are compared whole where the message holds only this package's
# and the library's fixed text; the three LZ4 decode failures carry
# liblz4's own negative position, so they are compared up to it and after it.
#
# What it catches: a conformer prefix dropped from a refusal a caller can
# reach, an Lz4Raw decode that returns a prefix of a corrupt or short block,
# a snappy decode that trusts a preamble over the bytes that follow it or
# cuts the output at `expected_size` instead of the decoded length, a
# cached zstd context left in a failed state, a capacity check that lets a
# negative value through, a level whose frame does not decode, and a handle
# whose move or second instance shares or loses a context.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_compression.compression_codecs import (
    Gzip,
    Lz4Raw,
    Snappy,
    Uncompressed,
    Zstd,
    _CodecDctxHandle,
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


def _repetitive(n: Int) -> List[UInt8]:
    """`n` bytes of a 13-byte cycle: every codec here turns it into matches."""
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(0x41 + i % 13))
    return out^


def _bytes(s: StaticString) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _prefix(b: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(b[i])
    return out^


def _assert_same(got: Span[UInt8, _], want: Span[UInt8, _], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": byte " + String(i))


def _assert_pad_untouched(buf: List[UInt8], n: Int, what: String) raises:
    for i in range(n, len(buf)):
        assert_equal(buf[i], _SENTINEL, what + ": byte " + String(i) + " past the destination was written")


# -----------------------------------------------------------------------------
# Gzip and Lz4Raw: reachable refusals keep the conformer's name
# -----------------------------------------------------------------------------


def test_gzip_refuses_a_level_libz_does_not_take() raises:
    var data = _bytes("hello")
    var msg = String("")
    try:
        _ = Gzip[10].compress(Span(data))
    except e:
        msg = String(e)
    # Z_STREAM_ERROR is -2; 15 is the zlib framing's window bits.
    assert_equal(
        msg,
        "Gzip.compress: libz deflateInit2_ failed (rc=-2, level=10,"
        " window_bits=15)",
    )
    msg = ""
    try:
        _ = Gzip[10].compress_gzip_file(Span(data))
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "Gzip.compress_gzip_file: libz deflateInit2_ failed (rc=-2, level=10,"
        " window_bits=15)",
    )


def test_lz4_raw_refuses_a_source_past_the_liblz4_limit() raises:
    var one = List[UInt8](length=1, fill=0)
    var msg = String("")
    try:
        # SAFETY: the Span claims LZ4_MAX_INPUT_SIZE + 1 bytes over a 1-byte
        # buffer. liblz4's bound for it is 0, so nothing is allocated, and
        # lz4_compress_into checks the length first and raises before reading
        # any byte; `one` outlives the call.
        var big = Span[UInt8, origin_of(one)](
            unsafe_ptr=one.unsafe_ptr(), length=0x7E000000 + 1
        )
        _ = Lz4Raw.compress(big)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "Lz4Raw.compress: lz4_compress_into: source of 2113929217 bytes"
        " exceeds LZ4_MAX_INPUT_SIZE (2113929216)",
    )


# -----------------------------------------------------------------------------
# Lz4Raw decode
# -----------------------------------------------------------------------------


def _lz4_raw_refusal(src: Span[UInt8, _], size: Int) raises -> String:
    try:
        _ = Lz4Raw.decompress(src, size)
    except e:
        return String(e)
    return ""


def _assert_lz4_safe_failure(msg: String, input_len: Int, cap: Int) raises:
    var head = "Lz4Raw.decompress: lz4_decompress_into: LZ4_decompress_safe failed (result=-"
    var tail = ", input_len=" + String(input_len) + ", output_cap=" + String(cap) + ")"
    assert_true(msg.startswith(head) and msg.endswith(tail), msg)


def test_lz4_raw_decodes_the_empty_block_and_refuses_bad_ones() raises:
    # 0x00: a token of no literals and no match, the one-byte empty block.
    var empty_block: List[UInt8] = [UInt8(0x00)]
    assert_equal(len(Lz4Raw.decompress(Span(empty_block), 1)), 0)

    # 0xF0: fifteen literals or more, with no length byte and no literal.
    var corrupt: List[UInt8] = [UInt8(0xF0)]
    _assert_lz4_safe_failure(_lz4_raw_refusal(Span(corrupt), 16), 1, 16)

    var data = _repetitive(4096)
    var packed = Lz4Raw.compress(Span(data))
    var cut = _prefix(packed, len(packed) - 3)
    _assert_lz4_safe_failure(_lz4_raw_refusal(Span(cut), 4096), len(cut), 4096)

    # One byte short of the decoded length: refused, not cut.
    _assert_lz4_safe_failure(
        _lz4_raw_refusal(Span(packed), 4095), len(packed), 4095
    )
    _assert_same(Span(Lz4Raw.decompress(Span(packed), 4096)), Span(data), "lz4 raw")


# -----------------------------------------------------------------------------
# Snappy
# -----------------------------------------------------------------------------


def test_snappy_decodes_a_hand_built_copy_block() raises:
    # Preamble 12; literal tag (4 - 1) << 2 with "abcd"; a copy with a 1-byte
    # offset: tag 0x01 | (8 - 4) << 2, offset 4. Decodes to "abcd" * 3.
    var block: List[UInt8] = [
        UInt8(0x0C), UInt8(0x0C), UInt8(0x61), UInt8(0x62), UInt8(0x63),
        UInt8(0x64), UInt8(0x11), UInt8(0x04),
    ]
    var want = _bytes("abcdabcdabcd")
    _assert_same(Span(Snappy.decompress(Span(block), 0)), Span(want), "copy block")
    _assert_same(Span(Snappy.decompress(Span(block), 12)), Span(want), "copy block sized")
    # A size past the decoded length is a capacity: the output is the 12 bytes.
    _assert_same(Span(Snappy.decompress(Span(block), 100)), Span(want), "copy block roomy")

    # Cut after the literal's second byte, and after the copy's tag byte.
    var cuts = [4, 7]
    for cut in cuts:
        var short = _prefix(block, cut)
        var msg = String("")
        try:
            _ = Snappy.decompress(Span(short), 0)
        except e:
            msg = String(e)
        assert_equal(
            msg,
            "Snappy.decompress: snappy_uncompress failed (status=1, input_len="
            + String(cut) + ", output_cap=12)",
        )


def test_snappy_repetitive_input_and_length_varint_boundaries() raises:
    var data = _repetitive(65536)
    var packed = Snappy.compress(Span(data))
    assert_true(len(packed) * 4 < len(data), "a 13-byte cycle compressed to " + String(len(packed)))
    _assert_same(Span(Snappy.decompress(Span(packed), 0)), Span(data), "repetitive")

    # The preamble is the length as a little-endian base-128 varint.
    var lengths = [127, 128, 16383, 16384]
    var preambles = List[List[UInt8]]()
    preambles.append([UInt8(0x7F)])
    preambles.append([UInt8(0x80), UInt8(0x01)])
    preambles.append([UInt8(0xFF), UInt8(0x7F)])
    preambles.append([UInt8(0x80), UInt8(0x80), UInt8(0x01)])
    for i in range(len(lengths)):
        var src = _repetitive(lengths[i])
        var block = Snappy.compress(Span(src))
        _assert_same(
            Span(block)[0 : len(preambles[i])],
            Span(preambles[i]),
            "preamble of " + String(lengths[i]),
        )
        _assert_same(Span(Snappy.decompress(Span(block), 0)), Span(src), "varint unsized")
        _assert_same(
            Span(Snappy.decompress(Span(block), lengths[i])), Span(src), "varint sized"
        )


# -----------------------------------------------------------------------------
# Zstd
# -----------------------------------------------------------------------------


def test_zstd_cached_context_recovers_after_failed_decodes() raises:
    var data = _repetitive(4096)
    var packed = Zstd[3].compress(Span(data))
    var n = len(packed)
    var dctx = Zstd[3].create_dctx()

    var small = List[UInt8](length=100 + _PAD, fill=_SENTINEL)
    var msg = String("")
    try:
        _ = Zstd[3].decompress_into_with_dctx(dctx, Span(packed), small.unsafe_ptr(), 100)
    except e:
        msg = String(e)
    # dstSize_tooSmall is zstd error 70.
    assert_equal(
        msg,
        "Zstd.decompress_into_with_dctx: ZSTD_decompressDCtx failed"
        " (result=-70, n=" + String(n) + ", dst_capacity=100)",
    )
    _assert_pad_untouched(small, 100, "short destination")

    var out = List[UInt8](length=4096 + _PAD, fill=_SENTINEL)
    assert_equal(
        Zstd[3].decompress_into_with_dctx(dctx, Span(packed), out.unsafe_ptr(), 4096),
        4096,
    )
    _assert_same(Span(out)[0:4096], Span(data), "after a short destination")
    _assert_pad_untouched(out, 4096, "after a short destination")

    var cut = _prefix(packed, n - 1)
    msg = ""
    try:
        _ = Zstd[3].decompress_into_with_dctx(dctx, Span(cut), out.unsafe_ptr(), 4096)
    except e:
        msg = String(e)
    # srcSize_wrong (the frame ends early) is zstd error 72.
    assert_equal(
        msg,
        "Zstd.decompress_into_with_dctx: ZSTD_decompressDCtx failed"
        " (result=-72, n=" + String(n - 1) + ", dst_capacity=4096)",
    )
    _assert_pad_untouched(out, 4096, "truncated frame")

    var again = List[UInt8](length=4096 + _PAD, fill=_SENTINEL)
    assert_equal(
        Zstd[3].decompress_into_with_dctx(dctx, Span(packed), again.unsafe_ptr(), 4096),
        4096,
    )
    _assert_same(Span(again)[0:4096], Span(data), "after a truncated frame")
    Zstd[3].free_dctx(dctx)


def test_zstd_refuses_negative_sizes_and_capacities() raises:
    var data = _bytes("hello")
    var dst = List[UInt8](length=16, fill=0)
    var dctx = Zstd[3].create_dctx()
    var msgs = List[String]()
    try:
        _ = Zstd[3].decompress(Span(data), -1)
    except e:
        msgs.append(String(e))
    try:
        _ = Zstd[3].decompress_into(Span(data), dst.unsafe_ptr(), -1)
    except e:
        msgs.append(String(e))
    try:
        _ = Zstd[3].compress_into(Span(data), dst.unsafe_ptr(), -1)
    except e:
        msgs.append(String(e))
    try:
        _ = Zstd[3].decompress_into_with_dctx(dctx, Span(data), dst.unsafe_ptr(), -1)
    except e:
        msgs.append(String(e))
    Zstd[3].free_dctx(dctx)
    assert_equal(len(msgs), 4)
    assert_equal(msgs[0], "Zstd.decompress: expected_size must be > 0 (got -1)")
    assert_equal(msgs[1], "Zstd.decompress_into: dst_capacity must be > 0 (got -1)")
    assert_equal(msgs[2], "Zstd.compress_into: dst_capacity must be > 0 (got -1)")
    assert_equal(
        msgs[3], "Zstd.decompress_into_with_dctx: dst_capacity must be > 0 (got -1)"
    )


def test_zstd_levels_1_and_19_round_trip() raises:
    var data = _repetitive(65536)
    var fast = Zstd[1].compress(Span(data))
    var slow = Zstd[19].compress(Span(data))
    _assert_same(Span(Zstd[1].decompress(Span(fast), len(data))), Span(data), "level 1")
    _assert_same(Span(Zstd[19].decompress(Span(slow), len(data))), Span(data), "level 19")
    # Each level's frame is the one zstd_frame writes at that level, through
    # the `*_into` entry too.
    var bound = Zstd[19].compress_bound(len(data))
    var into = List[UInt8](length=bound, fill=0)
    var w = Zstd[19].compress_into(Span(data), into.unsafe_ptr(), bound)
    _assert_same(Span(into)[0:w], Span(slow), "level 19 into")


# -----------------------------------------------------------------------------
# _CodecDctxHandle ownership
# -----------------------------------------------------------------------------


def test_dctx_handle_move_keeps_its_context_and_two_handles_keep_two() raises:
    var hello = _bytes("hello")
    var world = _bytes("world, again")
    var frame_a = Zstd[3].compress(Span(hello))
    var frame_b = Zstd[3].compress(Span(world))

    var first = _CodecDctxHandle[Zstd[3]].create()
    var made = Int(first._raw)
    var moved = first^
    assert_equal(Int(moved._raw), made, "a move changed the context")

    var other = _CodecDctxHandle[Zstd[3]].create()
    assert_true(Int(other._raw) != made, "two handles share one context")
    for round in range(3):
        var a = List[UInt8](length=16, fill=0)
        var b = List[UInt8](length=16, fill=0)
        assert_equal(moved.decompress_into_with_dctx(Span(frame_a), a.unsafe_ptr(), 16), 5)
        assert_equal(other.decompress_into_with_dctx(Span(frame_b), b.unsafe_ptr(), 16), 12)
        _assert_same(Span(a)[0:5], Span(hello), "handle a round " + String(round))
        _assert_same(Span(b)[0:12], Span(world), "handle b round " + String(round))
    assert_equal(Int(moved._raw), made, "the moved handle made another context")

    # The null context of Uncompressed moves as well.
    var plain = _CodecDctxHandle[Uncompressed].create()
    var plain_moved = plain^
    assert_equal(Int(plain_moved._raw), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
