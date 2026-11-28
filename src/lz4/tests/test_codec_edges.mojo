# =============================================================================
# test_codec_edges.mojo
# =============================================================================
#
# The refusals and edge inputs of lz4.codec and lz4.frame that the round-trip
# and golden tests do not reach: negative sizes, an empty compressed input
# with a nonzero decoded size, a block that decodes to a different size than
# the caller claimed, an empty destination, a decoder moved to a new owner,
# and the looping decode of concatenated frames
# (`lz4_frames_decompress_into`) with its three refusals.
#
# What it catches: a size check that lets a negative length through to
# liblz4; a decode that returns a block of the wrong size without
# naming the mismatch; a frame loop that drops the second frame, stops at a
# skippable frame, returns a prefix of a truncated frame, or reports a full
# destination as truncated input (or the reverse); a decoder moved out of
# that frees its context twice or leaves it unusable.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from lz4.codec import (
    lz4_compress,
    lz4_compress_bound,
    lz4_decompress,
    lz4_decompress_into,
)
from lz4.frame import (
    Lz4FrameDecoder,
    lz4_frame_compress_bound,
    lz4_frame_compress_into,
    lz4_frame_decompress_into,
    lz4_frames_decompress_into,
)

def _text(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(UInt8(97 + (i // 3) % 7))
    return out^


def _filled(n: Int, value: UInt8) -> List[UInt8]:
    return List[UInt8](length=n, fill=value)


def _prefix(b: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(b[i])
    return out^


def _assert_same(got: Span[UInt8, _], want: Span[UInt8, _]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        if got[i] != want[i]:
            assert_equal(Int(got[i]), Int(want[i]), "byte " + String(i))


def _frame_of(data: List[UInt8]) raises -> List[UInt8]:
    var packed = _filled(lz4_frame_compress_bound(len(data)), 0)
    var n = lz4_frame_compress_into(Span(packed), Span(data))
    return _prefix(packed, n)


def _skippable_frame() -> List[UInt8]:
    """A skippable frame (magic 0x184D2A50, 3 payload bytes) that decodes to
    nothing."""
    var out = List[UInt8]()
    for b in [0x50, 0x2A, 0x4D, 0x18, 3, 0, 0, 0, 1, 2, 3]:
        out.append(UInt8(b))
    return out^


def _frames_error[
    o: MutOrigin
](dst: Span[UInt8, o], src: Span[UInt8, _]) raises -> String:
    try:
        _ = lz4_frames_decompress_into(dst, src)
    except e:
        return String(e)
    raise Error("lz4_frames_decompress_into did not refuse")


# --- raw block: sizes ---


def test_compress_bound_refuses_a_negative_length() raises:
    var raised = False
    try:
        _ = lz4_compress_bound(-1)
    except e:
        raised = True
        assert_equal(String(e), "lz4_compress_bound: negative input_len -1")
    assert_true(raised, "a negative length has no bound")


def test_decompress_refuses_a_negative_decoded_length() raises:
    var block = lz4_compress(Span(_text(100)))
    var raised = False
    try:
        _ = lz4_decompress(Span(block), -5)
    except e:
        raised = True
        assert_equal(
            String(e), "lz4_decompress: negative uncompressed_len -5"
        )
    assert_true(raised, "a negative decoded length must be refused")


def test_decompress_refuses_empty_input_for_a_nonempty_result() raises:
    var empty = List[UInt8]()
    var raised = False
    try:
        _ = lz4_decompress(Span(empty), 10)
    except e:
        raised = True
        assert_equal(
            String(e),
            "lz4_decompress: empty compressed input but uncompressed_len=10",
        )
    assert_true(raised, "no bytes cannot decode to ten")


def test_decompress_names_a_block_that_decodes_to_another_size() raises:
    var data = _text(500)
    var block = lz4_compress(Span(data))
    var raised = False
    try:
        _ = lz4_decompress(Span(block), len(data) + 7)
    except e:
        raised = True
        assert_equal(
            String(e),
            "lz4_decompress: produced 500 bytes, expected 507"
            " (corrupt or wrong uncompressed_len)",
        )
    assert_true(raised, "a block of 500 bytes is not 507")


def test_decompress_refuses_a_block_larger_than_the_claimed_length() raises:
    var data = _text(500)
    var block = lz4_compress(Span(data))
    var raised = False
    try:
        _ = lz4_decompress(Span(block), len(data) - 1)
    except e:
        raised = True
        assert_true("LZ4_decompress_safe failed (" in String(e), String(e))
        assert_true("output_cap=499" in String(e), String(e))
    assert_true(raised, "a block that overruns the claimed length")


def test_decompress_refuses_a_corrupt_block() raises:
    var data = _text(500)
    var block = lz4_compress(Span(data))
    var cut = _prefix(block, len(block) - 1)
    var raised = False
    try:
        _ = lz4_decompress(Span(cut), len(data))
    except e:
        raised = True
        assert_true("LZ4_decompress_safe failed (" in String(e), String(e))
        assert_true(
            "input_len=" + String(len(cut)) in String(e), String(e)
        )
    assert_true(raised, "a truncated block must be refused")


def test_decompress_into_names_the_corrupt_block_call() raises:
    var data = _text(500)
    var block = lz4_compress(Span(data))
    var cut = _prefix(block, len(block) - 1)
    var out = _filled(len(data), 0)
    var raised = False
    try:
        _ = lz4_decompress_into(Span(out), Span(cut))
    except e:
        raised = True
        assert_true(
            "lz4_decompress_into: LZ4_decompress_safe failed (" in String(e),
            String(e),
        )
    assert_true(raised, "a truncated block must be refused")


def test_frame_compress_bound_refuses_a_negative_length() raises:
    var raised = False
    try:
        _ = lz4_frame_compress_bound(-1)
    except e:
        raised = True
        assert_equal(
            String(e), "lz4_frame_compress_bound: negative src_len -1"
        )
    assert_true(raised, "a negative length has no bound")


def test_an_empty_frame_decodes_into_an_empty_destination() raises:
    var empty = List[UInt8]()
    var frame = _frame_of(empty)
    var none = List[UInt8]()
    assert_equal(lz4_frame_decompress_into(Span(none), Span(frame)), 0)
    var decoder = Lz4FrameDecoder()
    assert_equal(decoder.decompress_into(Span(none), Span(frame)), 0)
    assert_equal(lz4_frames_decompress_into(Span(none), Span(frame)), 0)


def test_a_moved_decoder_decodes_and_frees_its_context_once() raises:
    var data = _text(2000)
    var frame = _frame_of(data)
    var first = Lz4FrameDecoder()
    var second = first^
    for _ in range(2):
        var out = _filled(len(data), 0)
        assert_equal(second.decompress_into(Span(out), Span(frame)), len(data))
        _assert_same(Span(out), Span(data))


# --- frames: the looping decode ---


def test_frames_decode_one_frame() raises:
    var data = _text(3000)
    var frame = _frame_of(data)
    var out = _filled(len(data), 0)
    assert_equal(lz4_frames_decompress_into(Span(out), Span(frame)), len(data))
    _assert_same(Span(out), Span(data))


def test_frames_decode_concatenated_frames_in_order() raises:
    var a = _text(3000)
    var b = _text(70000)
    var both = _frame_of(a)
    both.extend(Span(_frame_of(b)))
    var want = a.copy()
    want.extend(Span(b))
    var out = _filled(len(want) + 50, 0xAA)
    var n = lz4_frames_decompress_into(Span(out), Span(both))
    assert_equal(n, len(want))
    _assert_same(Span(out)[0:n], Span(want))
    assert_equal(Int(out[n]), 0xAA)


def test_frames_skip_skippable_frames_among_frames() raises:
    var a = _text(1500)
    var src = _skippable_frame()
    src.extend(Span(_frame_of(a)))
    src.extend(Span(_skippable_frame()))
    src.extend(Span(_frame_of(a)))
    var want = a.copy()
    want.extend(Span(a))
    var out = _filled(len(want), 0)
    assert_equal(lz4_frames_decompress_into(Span(out), Span(src)), len(want))
    _assert_same(Span(out), Span(want))


def test_frames_refuse_bytes_after_a_frame_that_are_no_frame() raises:
    var a = _text(1500)
    var src = _frame_of(a)
    src.extend(Span(_filled(8, 0xFF)))
    var out = _filled(len(a), 0)
    var message = _frames_error(Span(out), Span(src))
    assert_true("LZ4F_decompress failed (code=" in message, message)


def test_frames_refuse_a_destination_that_fills_before_the_end() raises:
    var a = _text(3000)
    var frame = _frame_of(a)
    var out = _filled(100, 0)
    assert_equal(
        _frames_error(Span(out), Span(frame)), "LZ4F dst buffer too small"
    )
    # The first frame fits exactly; the second has no room.
    var two = frame.copy()
    two.extend(Span(frame))
    var exact = _filled(len(a), 0)
    assert_equal(
        _frames_error(Span(exact), Span(two)), "LZ4F dst buffer too small"
    )


def test_frames_refuse_a_nonempty_frame_into_an_empty_destination() raises:
    var frame = _frame_of(_text(3000))
    var none = List[UInt8]()
    assert_equal(
        _frames_error(Span(none), Span(frame)), "LZ4F dst buffer too small"
    )


def test_frames_refuse_input_that_ends_inside_a_frame() raises:
    var a = _text(3000)
    var frame = _frame_of(a)
    var out = _filled(len(a) + 100, 0)
    for cut in [3, 7, len(frame) // 2, len(frame) - 1]:
        var src = _prefix(frame, cut)
        assert_equal(
            _frames_error(Span(out), Span(src)),
            "LZ4F frame truncated: the " + String(cut)
            + "-byte input ends before the frame does",
        )


def test_frames_refuse_empty_input() raises:
    var none = List[UInt8]()
    var out = _filled(16, 0)
    assert_equal(
        _frames_error(Span(out), Span(none)),
        "LZ4F frame truncated: the 0-byte input ends before the frame does",
    )
    var no_room = List[UInt8]()
    assert_equal(
        _frames_error(Span(no_room), Span(none)), "LZ4F dst buffer too small"
    )


def test_frames_refuse_a_missing_end_mark_into_a_full_buffer() raises:
    # All the data fits and the buffer is full, but the end mark never comes:
    # the output filled, so the refusal is the destination's, not the input's.
    var a = _text(3000)
    var frame = _frame_of(a)
    var src = _prefix(frame, len(frame) - 4)
    var out = _filled(len(a), 0)
    assert_equal(
        _frames_error(Span(out), Span(src)), "LZ4F dst buffer too small"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
