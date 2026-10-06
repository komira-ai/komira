# =============================================================================
# src/komira_lz4/tests/test_frame.mojo
#   The LZ4 FRAME entries of komira_lz4.frame: lz4_frame_compress_bound,
#   lz4_frame_compress_into, lz4_frame_decompress_into and Lz4FrameDecoder.
# =============================================================================
#
# The known-answer vector is golden/gettysburg.txt.lz4, a whole LZ4 frame the
# reference C liblz4 wrote, with golden/gettysburg.txt its plain text; both are
# pinned by sha256 in //third_party/pierrec-lz4 and staged at golden/.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_lz4.frame import (
    Lz4FrameDecoder,
    lz4_frame_compress_bound,
    lz4_frame_compress_into,
    lz4_frame_decompress_into,
)

comptime _GOLDEN_TEXT = "golden/gettysburg.txt"
comptime _GOLDEN_FRAME = "golden/gettysburg.txt.lz4"


def _read(path: String) raises -> List[UInt8]:
    return Path(path).read_bytes()


def _filled(n: Int, value: UInt8) -> List[UInt8]:
    return List[UInt8](length=n, fill=value)


def _assert_same(got: Span[UInt8, _], want: Span[UInt8, _]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        if got[i] != want[i]:
            assert_equal(Int(got[i]), Int(want[i]), "byte " + String(i))


def _varied(n: Int) -> List[UInt8]:
    var data = List[UInt8](capacity=n)
    for i in range(n):
        data.append(UInt8(((i * 31 + 5) ^ (i >> 7)) & 0xFF))
    return data^


def _refused_containing[
    o: MutOrigin
](dst: Span[UInt8, o], src: Span[UInt8, _], needle: String) raises:
    var raised = False
    try:
        _ = lz4_frame_decompress_into(dst, src)
    except e:
        raised = True
        assert_true(needle in String(e), String(e))
    assert_true(raised, "expected a refusal containing '" + needle + "'")


# --- known answer -------------------------------------------------------------


def test_golden_frame_decodes_to_golden_text() raises:
    var text = _read(_GOLDEN_TEXT)
    var frame = _read(_GOLDEN_FRAME)
    var out = _filled(len(text), 0)
    var n = lz4_frame_decompress_into(Span(out), Span(frame))
    assert_equal(n, len(text))
    _assert_same(Span(out), Span(text))


def test_golden_frame_into_a_larger_buffer_reports_its_length() raises:
    var text = _read(_GOLDEN_TEXT)
    var frame = _read(_GOLDEN_FRAME)
    var out = _filled(len(text) + 100, 0)
    var n = lz4_frame_decompress_into(Span(out), Span(frame))
    assert_equal(n, len(text))
    _assert_same(Span(out)[0:n], Span(text))


def test_one_decoder_decodes_many_frames() raises:
    var text = _read(_GOLDEN_TEXT)
    var frame = _read(_GOLDEN_FRAME)
    var decoder = Lz4FrameDecoder()
    for _ in range(3):
        var out = _filled(len(text), 0x5A)
        var n = decoder.decompress_into(Span(out), Span(frame))
        assert_equal(n, len(text))
        _assert_same(Span(out), Span(text))


# --- round trips --------------------------------------------------------------


def test_round_trips() raises:
    for size in [0, 1, 1548, 65536, 65537, 300000]:
        var data = _varied(size)
        var packed = _filled(lz4_frame_compress_bound(size), 0)
        var plen = lz4_frame_compress_into(Span(packed), Span(data))
        assert_true(plen >= 7 and plen <= len(packed), String(plen))
        assert_equal(Int(packed[0]), 0x04)
        assert_equal(Int(packed[1]), 0x22)
        assert_equal(Int(packed[2]), 0x4D)
        assert_equal(Int(packed[3]), 0x18)
        var out = _filled(size, 0xAA)
        var n = lz4_frame_decompress_into(Span(out), Span(packed)[0:plen])
        assert_equal(n, size)
        _assert_same(Span(out), Span(data))


# --- refusals -----------------------------------------------------------------


def test_too_small_compress_destination_is_refused() raises:
    var data = _varied(1000)
    var need = lz4_frame_compress_bound(len(data))
    var packed = _filled(need - 1, 0)
    var raised = False
    try:
        _ = lz4_frame_compress_into(Span(packed), Span(data))
    except e:
        raised = True
        assert_true("below lz4_frame_compress_bound" in String(e), String(e))
    assert_true(raised)


def test_corrupt_frames_are_refused() raises:
    var frame = _read(_GOLDEN_FRAME)
    var out = _filled(4096, 0)
    var bad_magic = frame.copy()
    bad_magic[0] = UInt8(0x05)
    _refused_containing(Span(out), Span(bad_magic), "LZ4F_decompress failed")
    # The header checksum byte guards the descriptor: it follows magic, FLG,
    # BD and the optional content size (FLG bit 3) and dictionary id (bit 0).
    var flg = Int(frame[4])
    var hc = 6 + (8 if flg & 0x08 else 0) + (4 if flg & 0x01 else 0)
    var bad_hc = frame.copy()
    bad_hc[hc] = bad_hc[hc] ^ UInt8(0xFF)
    _refused_containing(Span(out), Span(bad_hc), "LZ4F_decompress failed")


def test_two_frames_in_one_source_are_refused() raises:
    var frame = _read(_GOLDEN_FRAME)
    var two = frame.copy()
    two.extend(Span(frame))
    var out = _filled(8192, 0)
    _refused_containing(Span(out), Span(two), "incomplete decode")


def test_a_failed_frame_leaves_the_decoder_usable() raises:
    var text = _read(_GOLDEN_TEXT)
    var frame = _read(_GOLDEN_FRAME)
    var bad = frame.copy()
    bad[0] = UInt8(0x05)
    var decoder = Lz4FrameDecoder()
    var out = _filled(len(text), 0)
    var raised = False
    try:
        _ = decoder.decompress_into(Span(out), Span(bad))
    except:
        raised = True
    assert_true(raised)
    var n = decoder.decompress_into(Span(out), Span(frame))
    assert_equal(n, len(text))
    _assert_same(Span(out), Span(text))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
