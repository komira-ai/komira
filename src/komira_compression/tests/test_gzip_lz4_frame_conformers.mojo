# =============================================================================
# test_gzip_lz4_frame_conformers.mojo
# =============================================================================
#
# The `Gzip` and `Lz4Frame` conformers of komira_compression.compression_codecs,
# pinned by bytes, not only by round trips (a self round trip cannot see a
# framing change: the read path auto-detects).
#
# Known answers:
#   * `Gzip.compress(b"hello")` is the RFC 1950 zlib stream
#     78 9c | cb 48 cd c9 c9 07 00 | 06 2c 02 15 (header for level 6, the
#     fixed-Huffman deflate of "hello", Adler-32 0x062C0215).
#   * `Gzip.compress_gzip_file(b"hello")` is the RFC 1952 member
#     1f 8b 08 00 00000000 00 ff | <the same deflate> | crc32 0x3610A686 LE |
#     isize 5 LE: MTIME 0, XFL 0 at level 6, OS 255.
#   * golden/gettysburg.txt.lz4, an LZ4 frame the reference C liblz4 wrote
#     (pinned by sha256 in //third_party/pierrec-lz4), decodes through every
#     `Lz4Frame` decode entry to golden/gettysburg.txt.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_compression.compression_codecs import Gzip, Lz4Frame

comptime _GOLDEN_TEXT = "golden/gettysburg.txt"
comptime _GOLDEN_FRAME = "golden/gettysburg.txt.lz4"


def _read(path: String) raises -> List[UInt8]:
    return Path(path).read_bytes()


def _hello() -> List[UInt8]:
    return [UInt8(0x68), UInt8(0x65), UInt8(0x6C), UInt8(0x6C), UInt8(0x6F)]


def _assert_same(got: Span[UInt8, _], want: Span[UInt8, _]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        if got[i] != want[i]:
            assert_equal(Int(got[i]), Int(want[i]), "byte " + String(i))


def _varied(n: Int) -> List[UInt8]:
    var data = List[UInt8](capacity=n)
    var state: UInt32 = 0x12345678
    for i in range(n):
        if (i // 512) % 2 == 0:
            data.append(UInt8(i % 13))  # compressible run
        else:
            state = state * UInt32(1103515245) + UInt32(12345)
            data.append(UInt8((state >> 16) & 0xFF))  # high entropy
    return data^


# --- Gzip: known answers --------------------------------------------------------


def test_gzip_compress_is_the_zlib_stream() raises:
    var want: List[UInt8] = [
        0x78, 0x9C,
        0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00,
        0x06, 0x2C, 0x02, 0x15,
    ]
    var got = Gzip.compress(Span(_hello()))
    _assert_same(Span(got), Span(want))


def test_gzip_file_is_the_rfc1952_member() raises:
    var want: List[UInt8] = [
        0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
        0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00,
        0x86, 0xA6, 0x10, 0x36,
        0x05, 0x00, 0x00, 0x00,
    ]
    var got = Gzip.compress_gzip_file(Span(_hello()))
    _assert_same(Span(got), Span(want))


def test_gzip_file_xfl_follows_the_level() raises:
    var fast = Gzip[1].compress_gzip_file(Span(_hello()))
    var best = Gzip[9].compress_gzip_file(Span(_hello()))
    assert_equal(Int(fast[8]), 4, "XFL for level 1")
    assert_equal(Int(best[8]), 2, "XFL for level 9")


def test_gzip_empty_input() raises:
    var empty = List[UInt8]()
    var z: List[UInt8] = [
        0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01,
    ]
    _assert_same(Span(Gzip.compress(Span(empty))), Span(z))
    var gz = Gzip.compress_gzip_file(Span(empty))
    var want: List[UInt8] = [
        0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
        0x03, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ]
    _assert_same(Span(gz), Span(want))


# --- Gzip: round trips and refusals ---------------------------------------------


def test_gzip_round_trips_both_framings() raises:
    var data = _varied(70000)
    var z = Gzip.compress(Span(data))
    assert_equal(Int(z[0]), 0x78)
    _assert_same(Span(Gzip.decompress(Span(z), len(data))), Span(data))
    var gz = Gzip[9].compress_gzip_file(Span(data))
    assert_equal(Int(gz[0]), 0x1F)
    assert_equal(Int(gz[1]), 0x8B)
    _assert_same(Span(Gzip.decompress(Span(gz), len(data))), Span(data))


def test_gzip_decompress_refuses_a_non_positive_size() raises:
    var z = Gzip.compress(Span(_hello()))
    var raised = False
    try:
        _ = Gzip.decompress(Span(z), 0)
    except e:
        raised = True
        assert_true("expected_size must be > 0" in String(e), String(e))
    assert_true(raised)


def test_gzip_decompress_refuses_garbage() raises:
    var junk: List[UInt8] = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0]
    var raised = False
    try:
        _ = Gzip.decompress(Span(junk), 64)
    except:
        raised = True
    assert_true(raised, "a stream with no zlib or gzip header must not decode")


# --- Lz4Frame -------------------------------------------------------------------


def test_lz4_frame_golden_decodes_through_every_entry() raises:
    var text = _read(_GOLDEN_TEXT)
    var frame = _read(_GOLDEN_FRAME)

    _assert_same(Span(Lz4Frame.decompress(Span(frame), len(text))), Span(text))

    var out = List[UInt8](length=len(text), fill=UInt8(0xAA))
    var n = Lz4Frame.decompress_into(Span(frame), out.unsafe_ptr(), len(out))
    assert_equal(n, len(text))
    _assert_same(Span(out), Span(text))

    # One context, two frames: the reset between uses must hold.
    var dctx = Lz4Frame.create_dctx()
    for _ in range(2):
        var again = List[UInt8](length=len(text), fill=UInt8(0x55))
        var m = Lz4Frame.decompress_into_with_dctx(
            dctx, Span(frame), again.unsafe_ptr(), len(again)
        )
        assert_equal(m, len(text))
        _assert_same(Span(again), Span(text))
    Lz4Frame.free_dctx(dctx)


def test_lz4_frame_compress_paths_agree_and_round_trip() raises:
    var data = _varied(200000)
    var listed = Lz4Frame.compress(Span(data))
    assert_equal(Int(listed[0]), 0x04)
    assert_equal(Int(listed[1]), 0x22)
    assert_equal(Int(listed[2]), 0x4D)
    assert_equal(Int(listed[3]), 0x18)

    var bound = Lz4Frame.compress_bound(len(data))
    assert_true(bound >= len(listed))
    var into = List[UInt8](length=bound, fill=UInt8(0))
    var w = Lz4Frame.compress_into(Span(data), into.unsafe_ptr(), bound)
    _assert_same(Span(into)[0:w], Span(listed))

    _assert_same(
        Span(Lz4Frame.decompress(Span(listed), len(data))), Span(data)
    )


def test_lz4_frame_refusals() raises:
    var frame = _read(_GOLDEN_FRAME)
    var raised = False
    try:
        _ = Lz4Frame.decompress(Span(frame), 0)
    except e:
        raised = True
        assert_true("expected_size must be > 0" in String(e), String(e))
    assert_true(raised)

    # A wrong magic number is a corrupt frame.
    var bad = frame.copy()
    bad[0] = UInt8(0x05)
    raised = False
    try:
        _ = Lz4Frame.decompress(Span(bad), 4096)
    except:
        raised = True
    assert_true(raised, "a frame with a wrong magic must not decode")

    # The same through a cached context, which then still decodes a good frame.
    var text = _read(_GOLDEN_TEXT)
    var dctx = Lz4Frame.create_dctx()
    var out = List[UInt8](length=len(text), fill=UInt8(0))
    raised = False
    try:
        _ = Lz4Frame.decompress_into_with_dctx(
            dctx, Span(bad), out.unsafe_ptr(), len(out)
        )
    except:
        raised = True
    assert_true(raised, "a cached context must refuse a wrong magic too")
    var n = Lz4Frame.decompress_into_with_dctx(
        dctx, Span(frame), out.unsafe_ptr(), len(out)
    )
    assert_equal(n, len(text))
    _assert_same(Span(out), Span(text))
    Lz4Frame.free_dctx(dctx)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
