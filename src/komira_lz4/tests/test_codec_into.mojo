# =============================================================================
# src/komira_lz4/tests/test_codec_into.mojo
#   The into-buffer entries of komira_lz4.codec: lz4_compress_into and
#   lz4_decompress_into (Span in, Span out, bytes written back).
# =============================================================================
#
# The known-answer vector is golden/gettysburg.txt.lz4, an LZ4 frame the
# reference C liblz4 wrote, with golden/gettysburg.txt its plain text; both are
# pinned by sha256 in //third_party/lz4-golden and staged at golden/. A frame
# is a header, then blocks, each one a 4-byte little-endian size followed by an
# LZ4 raw block (doc/lz4_Frame_format.md in the lz4 repository); this test
# takes the one block out of the frame and decodes it as a raw block.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_lz4.codec import (
    lz4_compress,
    lz4_compress_bound,
    lz4_compress_into,
    lz4_decompress,
    lz4_decompress_into,
)

comptime _GOLDEN_TEXT = "golden/gettysburg.txt"
comptime _GOLDEN_FRAME = "golden/gettysburg.txt.lz4"


def _read(path: String) raises -> List[UInt8]:
    return Path(path).read_bytes()


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
    assert_equal(Int(frame[0]), 0x04)
    assert_equal(Int(frame[1]), 0x22)
    assert_equal(Int(frame[2]), 0x4D)
    assert_equal(Int(frame[3]), 0x18)
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
    # The frame ends with the end mark (four zero bytes) right after the block,
    # or after a 4-byte block checksum when FLG bit 4 is set.
    var end = at + size_word + (4 if flg & 0x10 else 0)
    assert_equal(_le_u32(frame, end), 0, "one block, then the end mark")
    return block^


def _filled(n: Int, value: UInt8) -> List[UInt8]:
    return List[UInt8](length=n, fill=value)


def _assert_same(got: Span[UInt8, _], want: Span[UInt8, _]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        if got[i] != want[i]:
            assert_equal(Int(got[i]), Int(want[i]), "byte " + String(i))


def _round_trip(data: List[UInt8]) raises:
    var packed = _filled(lz4_compress_bound(len(data)), 0)
    var plen = lz4_compress_into(Span(packed), Span(data))
    assert_true(plen > 0 and plen <= len(packed))
    var out = _filled(len(data), 0xAA)
    var n = lz4_decompress_into(Span(out), Span(packed)[0:plen])
    assert_equal(n, len(data))
    _assert_same(Span(out), Span(data))
    # The List API reads what the into API wrote.
    var listed = lz4_decompress(Span(packed)[0:plen], len(data))
    _assert_same(Span(listed), Span(data))


# --- known answer -------------------------------------------------------------


def test_golden_block_decodes_to_golden_text() raises:
    var text = _read(_GOLDEN_TEXT)
    var block = _golden_block()
    var out = _filled(len(text), 0)
    var n = lz4_decompress_into(Span(out), Span(block))
    assert_equal(n, len(text))
    _assert_same(Span(out), Span(text))


def test_golden_block_into_a_larger_buffer_reports_its_length() raises:
    var text = _read(_GOLDEN_TEXT)
    var block = _golden_block()
    var out = _filled(len(text) + 100, 0)
    var n = lz4_decompress_into(Span(out), Span(block))
    assert_equal(n, len(text))
    _assert_same(Span(out)[0:n], Span(text))


def test_golden_text_round_trips() raises:
    _round_trip(_read(_GOLDEN_TEXT))


# --- round trips --------------------------------------------------------------


def test_round_trip_single_byte() raises:
    _round_trip(_filled(1, 42))


def test_round_trip_varied_1k() raises:
    var data = List[UInt8]()
    for i in range(1024):
        data.append(UInt8((i * 7 + 13) & 0xFF))
    _round_trip(data)


def test_round_trip_64k() raises:
    var data = List[UInt8]()
    for i in range(65536):
        data.append(UInt8((i * 31 + 5) & 0xFF))
    _round_trip(data)


def test_round_trip_compressible_256k() raises:
    var data = List[UInt8]()
    for i in range(1 << 18):
        data.append(UInt8((i // 64) & 0x0F))
    _round_trip(data)


def test_into_output_matches_list_api() raises:
    var data = _read(_GOLDEN_TEXT)
    var packed = _filled(lz4_compress_bound(len(data)), 0)
    var plen = lz4_compress_into(Span(packed), Span(data))
    var listed = lz4_compress(Span(data))
    _assert_same(Span(packed)[0:plen], Span(listed))


# --- empty input --------------------------------------------------------------


def test_empty_source_compresses_to_the_empty_block() raises:
    var empty = List[UInt8]()
    var packed = _filled(lz4_compress_bound(0), 0xAA)
    var plen = lz4_compress_into(Span(packed), Span(empty))
    assert_equal(plen, 1)
    assert_equal(Int(packed[0]), 0x00)


def test_empty_block_decodes_to_nothing() raises:
    var block = _filled(1, 0x00)
    var none = List[UInt8]()
    assert_equal(lz4_decompress_into(Span(none), Span(block)), 0)
    var some = _filled(8, 0xAA)
    assert_equal(lz4_decompress_into(Span(some), Span(block)), 0)
    assert_equal(Int(some[0]), 0xAA)


def test_empty_source_does_not_decode() raises:
    var empty = List[UInt8]()
    var out = _filled(8, 0)
    var raised = False
    try:
        _ = lz4_decompress_into(Span(out), Span(empty))
    except e:
        raised = True
        assert_true("empty source" in String(e), String(e))
    assert_true(raised, "an empty source is not an LZ4 block")


# --- too-small destination ----------------------------------------------------


def test_decompress_refuses_a_destination_one_byte_short() raises:
    var text = _read(_GOLDEN_TEXT)
    var block = _golden_block()
    var out = _filled(len(text) - 1, 0)
    var raised = False
    try:
        _ = lz4_decompress_into(Span(out), Span(block))
    except:
        raised = True
    assert_true(raised, "a block larger than the destination must be refused")


def test_decompress_refuses_an_empty_destination() raises:
    var block = _golden_block()
    var none = List[UInt8]()
    var raised = False
    try:
        _ = lz4_decompress_into(Span(none), Span(block))
    except:
        raised = True
    assert_true(raised, "a non-empty block into an empty destination")


def test_compress_refuses_a_destination_below_the_bound() raises:
    var data = _read(_GOLDEN_TEXT)
    var short = _filled(lz4_compress_bound(len(data)) - 1, 0xAA)
    var raised = False
    try:
        _ = lz4_compress_into(Span(short), Span(data))
    except e:
        raised = True
        assert_true("lz4_compress_bound" in String(e), String(e))
    assert_true(raised, "a destination below the bound must be refused")
    # Refused before liblz4 ran: nothing was written.
    for i in range(len(short)):
        assert_equal(Int(short[i]), 0xAA)


# --- corrupt input ------------------------------------------------------------


def test_truncated_block_does_not_decode() raises:
    """The last sequence of a block is literals running to the block's end, so
    a block one byte short claims more literals than it holds."""
    var text = _read(_GOLDEN_TEXT)
    var block = _golden_block()
    var out = _filled(len(text), 0)
    var raised = False
    try:
        _ = lz4_decompress_into(Span(out), Span(block)[0 : len(block) - 1])
    except:
        raised = True
    assert_true(raised, "a truncated block must be refused")


def test_offset_before_the_output_does_not_decode() raises:
    """Point the first match 65535 bytes back, before anything was written."""
    var text = _read(_GOLDEN_TEXT)
    var block = _golden_block()
    # Token: literal length in the high nibble; 15 means more length bytes
    # follow, each added, until one below 255.
    var at = 0
    var lits = Int(block[at]) >> 4
    at += 1
    if lits == 15:
        while True:
            var more = Int(block[at])
            at += 1
            lits += more
            if more != 255:
                break
    at += lits  # the literals, then the 2-byte little-endian match offset
    assert_true(lits < 65535 and at + 1 < len(block))
    block[at] = 0xFF
    block[at + 1] = 0xFF
    var out = _filled(len(text), 0)
    var raised = False
    try:
        _ = lz4_decompress_into(Span(out), Span(block))
    except:
        raised = True
    assert_true(raised, "a match before the start of the output must be refused")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
