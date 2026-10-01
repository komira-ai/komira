# =============================================================================
# tests/test_L2_h2_continuation_splitter.mojo
# =============================================================================
#
# — split_header_block_into_frames boundary
# tests. RFC 9113 §6.10 wire shape for HEADERS+CONTINUATION sequences.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_http.codec.h2 import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_CONTINUATION,
    FRAME_HEADERS,
    FRAME_DECODE_OK,
    decode_frame,
    split_header_block_into_frames,
)


# Helper: build a synthetic header-block of length `n` with byte = i % 256.
def _make_block(n: Int) -> List[UInt8]:
    var b = List[UInt8]()
    var i = 0
    while i < n:
        b.append(UInt8(i % 256))
        i = i + 1
    return b^


# Helper: decode_frame on `buf`, starting at `off`. Returns the frame's
# (kind, flags, length, stream_id, next_off).
def _peek_frame(
    buf: Span[UInt8, _], off: Int, max_frame_size: Int,
) -> Tuple[UInt8, UInt8, Int, UInt32, Int]:
    var view = buf[off:]
    var res = decode_frame(view, max_frame_size)
    if res.status != FRAME_DECODE_OK:
        return (UInt8(0xff), UInt8(0xff), -1, UInt32(0), -1)
    return (
        res.frame.header.kind,
        res.frame.header.flags,
        Int(res.frame.header.length),
        res.frame.header.stream_id,
        off + res.consumed,
    )


# =============================================================================
# Test 1 — empty block: one HEADERS with END_HEADERS, optional END_STREAM.
# =============================================================================


def test_empty_block_single_headers_frame() raises:
    var block = List[UInt8]()
    var out = List[UInt8]()
    split_header_block_into_frames(
        UInt32(1), block^, 16384, True, out,
    )
    # Expect ONE HEADERS frame: 9-byte header, 0-byte payload.
    assert_equal(len(out), 9)
    var view = Span(out)
    var p = _peek_frame(view, 0, 16384)
    assert_equal(Int(p[0]), Int(FRAME_HEADERS))
    # Flags: END_HEADERS | END_STREAM.
    assert_equal(Int(p[1]) & Int(FLAG_END_HEADERS), Int(FLAG_END_HEADERS))
    assert_equal(Int(p[1]) & Int(FLAG_END_STREAM), Int(FLAG_END_STREAM))
    assert_equal(p[2], 0)


# =============================================================================
# Test 2 — block smaller than max_frame_size: ONE HEADERS with END_HEADERS.
# =============================================================================


def test_block_smaller_than_max_single_frame() raises:
    var block = _make_block(100)
    var out = List[UInt8]()
    split_header_block_into_frames(
        UInt32(3), block^, 16384, False, out,
    )
    # Single HEADERS frame: 9 header + 100 payload = 109 bytes.
    assert_equal(len(out), 9 + 100)
    var view = Span(out)
    var p = _peek_frame(view, 0, 16384)
    assert_equal(Int(p[0]), Int(FRAME_HEADERS))
    assert_equal(Int(p[1]) & Int(FLAG_END_HEADERS), Int(FLAG_END_HEADERS))
    assert_equal(Int(p[1]) & Int(FLAG_END_STREAM), 0)
    assert_equal(p[2], 100)
    assert_equal(Int(p[3]), 3)


# =============================================================================
# Test 3 — block EXACTLY max_frame_size: ONE HEADERS with END_HEADERS.
# =============================================================================


def test_block_exactly_max_frame_size_single_frame() raises:
    var mfs = 64
    var block = _make_block(mfs)
    var out = List[UInt8]()
    split_header_block_into_frames(
        UInt32(5), block^, mfs, True, out,
    )
    # ONE HEADERS frame with END_HEADERS + END_STREAM.
    assert_equal(len(out), 9 + mfs)
    var view = Span(out)
    var p = _peek_frame(view, 0, mfs * 2)
    assert_equal(Int(p[0]), Int(FRAME_HEADERS))
    assert_equal(Int(p[1]) & Int(FLAG_END_HEADERS), Int(FLAG_END_HEADERS))
    assert_equal(Int(p[1]) & Int(FLAG_END_STREAM), Int(FLAG_END_STREAM))
    assert_equal(p[2], mfs)


# =============================================================================
# Test 4 — block > max_frame_size: HEADERS (no END_HEADERS) + 1 CONTINUATION
# with END_HEADERS.
# =============================================================================


def test_block_two_frames_headers_plus_continuation() raises:
    var mfs = 64
    var block = _make_block(100)  # 64 in HEADERS + 36 in CONTINUATION
    var out = List[UInt8]()
    split_header_block_into_frames(
        UInt32(7), block^, mfs, False, out,
    )
    # Expect 9 + 64 + 9 + 36 = 118 bytes.
    assert_equal(len(out), 9 + 64 + 9 + 36)
    var view = Span(out)
    # First frame: HEADERS, NO END_HEADERS, NO END_STREAM, len=64.
    var p1 = _peek_frame(view, 0, mfs * 2)
    assert_equal(Int(p1[0]), Int(FRAME_HEADERS))
    assert_equal(Int(p1[1]) & Int(FLAG_END_HEADERS), 0)
    assert_equal(Int(p1[1]) & Int(FLAG_END_STREAM), 0)
    assert_equal(p1[2], 64)
    # Second frame: CONTINUATION, END_HEADERS, len=36, same stream_id.
    var p2 = _peek_frame(view, p1[4], mfs * 2)
    assert_equal(Int(p2[0]), Int(FRAME_CONTINUATION))
    assert_equal(Int(p2[1]) & Int(FLAG_END_HEADERS), Int(FLAG_END_HEADERS))
    assert_equal(p2[2], 36)
    assert_equal(Int(p2[3]), 7)


# =============================================================================
# Test 5 — block much larger than max_frame_size (3+ CONTINUATION frames).
# =============================================================================


def test_block_many_frames() raises:
    var mfs = 16  # tiny so we span many CONTINUATION
    var block = _make_block(100)
    var out = List[UInt8]()
    split_header_block_into_frames(
        UInt32(9), block^, mfs, True, out,
    )
    # 100 / 16 = 6 full chunks + 4 remainder = 7 frames total.
    # Expected wire bytes: 7 * 9 (headers) + 100 (payload) = 163.
    assert_equal(len(out), 7 * 9 + 100)
    var view = Span(out)
    # First frame: HEADERS, NO END_HEADERS, END_STREAM, len=16.
    var p1 = _peek_frame(view, 0, mfs * 10)
    assert_equal(Int(p1[0]), Int(FRAME_HEADERS))
    assert_equal(Int(p1[1]) & Int(FLAG_END_HEADERS), 0)
    assert_equal(Int(p1[1]) & Int(FLAG_END_STREAM), Int(FLAG_END_STREAM))
    # Iterate through CONTINUATION frames; the LAST should have END_HEADERS.
    var off = p1[4]
    var n_continuations = 0
    var last_had_end_headers = False
    while off < len(out):
        var pn = _peek_frame(view, off, mfs * 10)
        if pn[4] < 0:
            break
        assert_equal(Int(pn[0]), Int(FRAME_CONTINUATION))
        # CONTINUATION must NOT have END_STREAM (RFC 9113 §6.10).
        assert_equal(Int(pn[1]) & Int(FLAG_END_STREAM), 0)
        last_had_end_headers = (
            Int(pn[1]) & Int(FLAG_END_HEADERS)
        ) == Int(FLAG_END_HEADERS)
        n_continuations = n_continuations + 1
        off = pn[4]
    assert_equal(n_continuations, 6)
    assert_true(last_had_end_headers)


# =============================================================================
# Test 6 — round-trip: split, then reassemble, byte-identical to source.
# =============================================================================


def test_split_and_reassemble_round_trip() raises:
    var mfs = 32
    var src = _make_block(200)
    var src_copy = _make_block(200)  # for comparison
    var out = List[UInt8]()
    split_header_block_into_frames(
        UInt32(11), src^, mfs, False, out,
    )
    # Walk frames; concatenate payloads; compare against src_copy.
    var view = Span(out)
    var off = 0
    var reasm = List[UInt8]()
    while off < len(out):
        var p = _peek_frame(view, off, mfs * 100)
        if p[4] < 0:
            break
        # Copy payload bytes (frame_start + 9 .. frame_start + 9 + length).
        var payload_start = off + 9
        var payload_end = payload_start + p[2]
        var k = payload_start
        while k < payload_end:
            reasm.append(out[k])
            k = k + 1
        off = p[4]
    assert_equal(len(reasm), len(src_copy))
    var i = 0
    while i < len(reasm):
        assert_equal(Int(reasm[i]), Int(src_copy[i]))
        i = i + 1


# =============================================================================
# main
# =============================================================================


def main() raises:
    print("test_L2_h2_continuation_splitter: start")
    test_empty_block_single_headers_frame()
    print(" empty_block_single_headers_frame PASS")
    test_block_smaller_than_max_single_frame()
    print(" block_smaller_than_max_single_frame PASS")
    test_block_exactly_max_frame_size_single_frame()
    print(" block_exactly_max_frame_size_single_frame PASS")
    test_block_two_frames_headers_plus_continuation()
    print(" block_two_frames_headers_plus_continuation PASS")
    test_block_many_frames()
    print(" block_many_frames PASS")
    test_split_and_reassemble_round_trip()
    print(" split_and_reassemble_round_trip PASS")
    print("test_L2_h2_continuation_splitter: ALL 6 TESTS PASS")
