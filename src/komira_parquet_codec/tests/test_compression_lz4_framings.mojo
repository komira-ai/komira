# =============================================================================
# The LZ4 framings: LZ4 frames, and the three layouts of the deprecated
# Parquet LZ4 codec (id 5)
# =============================================================================
#
# The known-answer vector is golden/gettysburg.txt.lz4, an LZ4 frame the
# reference C liblz4 wrote, with golden/gettysburg.txt its plain text; both are
# pinned by sha256 in //third_party/pierrec-lz4 and staged at golden/. The
# frame holds one compressed block; the tests take it out to build the other
# two layouts of codec id 5:
#
#   * the frame itself (arm 2, recognised by its magic),
#   * the bare raw block (arm 3),
#   * the raw block behind Hadoop's 8-byte big-endian prefix (arm 1:
#     uncompressed length, then compressed length).
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_parquet_api import CompressionCodec
from komira_parquet_codec.compression import (
    Lz4TextFraming,
    compress,
    compress_bound,
    compress_lz4_frame,
    decompress,
    decompress_lz4_frame,
    lz4_frame_compress_bound,
    lz4_frame_declared_content_size,
    lz4_text_framing_of,
)

comptime _GOLDEN_TEXT = "golden/gettysburg.txt"
comptime _GOLDEN_FRAME = "golden/gettysburg.txt.lz4"


def _read(path: String) raises -> List[UInt8]:
    return Path(path).read_bytes()


def _filled(n: Int, b: UInt8) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(b)
    return out^


def _le_u32(b: List[UInt8], at: Int) -> Int:
    return (
        Int(b[at])
        | (Int(b[at + 1]) << 8)
        | (Int(b[at + 2]) << 16)
        | (Int(b[at + 3]) << 24)
    )


def _golden_block() raises -> List[UInt8]:
    """The one LZ4 raw block inside the golden frame.

    Frame header (lz4_Frame_format.md): magic 04 22 4D 18; FLG (bits 7-6 the
    version, 01; bit 3 a content size follows, 8 bytes; bit 0 a dictionary id
    follows, 4 bytes); BD; the header checksum byte. Then the block size,
    whose high bit set would mean the block is stored uncompressed.
    """
    var frame = _read(_GOLDEN_FRAME)
    var flg = Int(frame[4])
    assert_equal(flg >> 6, 1, "frame format version")
    var at = 6  # magic + FLG + BD
    if flg & 0x08:
        at += 8
    if flg & 0x01:
        at += 4
    at += 1  # header checksum
    var size_word = _le_u32(frame, at)
    assert_equal(size_word >> 31, 0, "the golden block is compressed")
    at += 4
    var block = List[UInt8](capacity=size_word)
    for i in range(size_word):
        block.append(frame[at + i])
    return block^


def _append_be32(mut buf: List[UInt8], v: Int):
    buf.append(UInt8((v >> 24) & 0xFF))
    buf.append(UInt8((v >> 16) & 0xFF))
    buf.append(UInt8((v >> 8) & 0xFF))
    buf.append(UInt8(v & 0xFF))


def _assert_text(got: List[UInt8], n: Int, text: List[UInt8]) raises:
    assert_equal(n, len(text))
    for i in range(len(text)):
        assert_equal(Int(got[i]), Int(text[i]), "byte " + String(i))


# --- LZ4 frames ---------------------------------------------------------------


def test_golden_frame_decodes() raises:
    var text = _read(_GOLDEN_TEXT)
    var frame = _read(_GOLDEN_FRAME)
    var out = _filled(len(text) + 64, 0)
    var n = decompress_lz4_frame(Span(frame), Span(out))
    _assert_text(out, n, text)


def test_golden_frame_into_a_too_small_buffer_says_so() raises:
    var text = _read(_GOLDEN_TEXT)
    var frame = _read(_GOLDEN_FRAME)
    var out = _filled(len(text) - 1, 0)
    var msg = String("")
    try:
        _ = decompress_lz4_frame(Span(frame), Span(out))
    except e:
        msg = String(e)
    # A caller's grow-and-retry loop matches this substring.
    assert_true(
        msg.find("LZ4F dst buffer too small") >= 0,
        "expected the dst-too-small marker, got: " + msg,
    )


def test_frame_round_trip() raises:
    var text = _read(_GOLDEN_TEXT)
    var packed = _filled(lz4_frame_compress_bound(len(text)), 0)
    var n = compress_lz4_frame(Span(text), Span(packed))
    assert_true(n > 0)
    var framed = Span(packed)[0:n]
    assert_true(lz4_text_framing_of(framed) == Lz4TextFraming.FRAME)
    var out = _filled(len(text), 0)
    var m = decompress_lz4_frame(framed, Span(out))
    _assert_text(out, m, text)


def test_text_framing_classifies_frame_and_raw_block() raises:
    var frame = _read(_GOLDEN_FRAME)
    var block = _golden_block()
    assert_true(lz4_text_framing_of(Span(frame)) == Lz4TextFraming.FRAME)
    assert_true(lz4_text_framing_of(Span(block)) == Lz4TextFraming.RAW_BLOCK)
    var short: List[UInt8] = [UInt8(0x04), UInt8(0x22), UInt8(0x4D)]
    assert_true(lz4_text_framing_of(Span(short)) == Lz4TextFraming.RAW_BLOCK)


def test_declared_content_size() raises:
    var text = _read(_GOLDEN_TEXT)
    var frame = _read(_GOLDEN_FRAME)
    var declared = lz4_frame_declared_content_size(Span(frame))
    if Int(frame[4]) & 0x08:
        assert_true(Bool(declared), "FLG bit 3 set: a content size is present")
        assert_equal(declared.value(), len(text))
    else:
        assert_false(Bool(declared), "FLG bit 3 clear: no content size")
    # A frame header that declares 1548 bytes (FLG 0x68: version 01, bit 3).
    var hdr: List[UInt8] = [
        0x04, 0x22, 0x4D, 0x18, 0x68, 0x40,
        0x0C, 0x06, 0, 0, 0, 0, 0, 0,
        0x00,
    ]
    var d2 = lz4_frame_declared_content_size(Span(hdr))
    assert_true(Bool(d2))
    assert_equal(d2.value(), 1548)
    # A raw block declares nothing.
    var block = _golden_block()
    assert_false(Bool(lz4_frame_declared_content_size(Span(block))))


def _refuses_truncated(keep: Int) raises:
    var text = _read(_GOLDEN_TEXT)
    var frame = _read(_GOLDEN_FRAME)
    var cut = List[UInt8]()
    for i in range(keep):
        cut.append(frame[i])
    var out = _filled(len(text) + 64, 0)
    var raised = False
    try:
        _ = decompress_lz4_frame(Span(cut), Span(out))
    except:
        raised = True
    assert_true(raised, "a frame cut to " + String(keep) + " bytes must raise")


def test_frame_without_its_end_mark_is_refused() raises:
    # The frame ends with a 4-byte end mark (FLG bit 2 clear: no content
    # checksum after it). Every block decodes, but the frame never ends.
    var frame = _read(_GOLDEN_FRAME)
    var trailer = 4 + (4 if Int(frame[4]) & 0x04 else 0)
    _refuses_truncated(len(frame) - trailer)


def test_frame_cut_inside_its_block_is_refused() raises:
    var frame = _read(_GOLDEN_FRAME)
    _refuses_truncated(len(frame) // 2)


# --- codec id 5, the deprecated LZ4 -------------------------------------------


def test_deprecated_lz4_frame_arm() raises:
    var text = _read(_GOLDEN_TEXT)
    var frame = _read(_GOLDEN_FRAME)
    var out = _filled(len(text), 0)
    var n = decompress(CompressionCodec.LZ4, Span(frame), Span(out))
    _assert_text(out, n, text)


def test_deprecated_lz4_bare_raw_block_arm() raises:
    var text = _read(_GOLDEN_TEXT)
    var block = _golden_block()
    var out = _filled(len(text), 0)
    var n = decompress(CompressionCodec.LZ4, Span(block), Span(out))
    _assert_text(out, n, text)


def test_deprecated_lz4_hadoop_arm() raises:
    var text = _read(_GOLDEN_TEXT)
    var block = _golden_block()
    var framed = List[UInt8]()
    var u = len(text)
    var c = len(block)
    _append_be32(framed, u)
    _append_be32(framed, c)
    for i in range(c):
        framed.append(block[i])
    var out = _filled(len(text), 0)
    var n = decompress(CompressionCodec.LZ4, Span(framed), Span(out))
    _assert_text(out, n, text)


def test_deprecated_lz4_reads_what_lz4_raw_writes() raises:
    var text = _read(_GOLDEN_TEXT)
    var packed = _filled(compress_bound(CompressionCodec.LZ4_RAW, len(text)), 0)
    var n = compress(CompressionCodec.LZ4_RAW, Span(text), Span(packed))
    var out = _filled(len(text), 0)
    var m = decompress(CompressionCodec.LZ4, Span(packed)[0:n], Span(out))
    _assert_text(out, m, text)


def test_deprecated_lz4_garbage_names_all_three_framings() raises:
    var junk: List[UInt8] = [UInt8(0xFF), UInt8(0xFF), UInt8(0xFF), UInt8(0xFF)]
    var out = _filled(100, 0)
    var msg = String("")
    try:
        _ = decompress(CompressionCodec.LZ4, Span(junk), Span(out))
    except e:
        msg = String(e)
    assert_true(msg.find("NONE of its three known framings") >= 0, msg)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
