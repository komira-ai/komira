# =============================================================================
# BROTLI through the public decompress dispatch (libbrotlidec)
# =============================================================================
#
# The known answers are google/brotli's own decoder test vectors
# (tests/testdata/*.compressed next to the text each decodes to), extracted
# from the release archive //third_party/brotli pins by sha256 and staged at
# brotli/. They check the libbrotlidec call itself: the argument order, the
# in/out decoded size, and the success code.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_parquet_api import CompressionCodec
from komira_parquet_codec.compression import decompress

comptime _DIR = "brotli/tests/testdata/"


def _read(name: String) raises -> List[UInt8]:
    return Path(String(_DIR) + name).read_bytes()


def _filled(n: Int, b: UInt8) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(b)
    return out^


def _raises(blob: List[UInt8], cap: Int) -> Bool:
    var out = _filled(cap, 0)
    try:
        _ = decompress(CompressionCodec.BROTLI, Span(blob), Span(out))
    except:
        return True
    return False


def test_known_answer() raises:
    var want = _read("ukkonooa")
    var blob = _read("ukkonooa.compressed")
    assert_true(len(want) > len(blob), "the vector is compressed")
    # Into the exact size, and into a buffer with room to spare: the return
    # is the decoded length, not the capacity.
    for extra in range(2):
        var out = _filled(len(want) + 64 * extra, 0xAA)
        var n = decompress(CompressionCodec.BROTLI, Span(blob), Span(out))
        assert_equal(n, len(want))
        for i in range(len(want)):
            assert_equal(Int(out[i]), Int(want[i]), "byte " + String(i))
        for i in range(len(want), len(out)):
            assert_equal(Int(out[i]), 0xAA, "wrote past the decoded length")


def test_empty_stream() raises:
    assert_equal(len(_read("empty")), 0)
    var blob = _read("empty.compressed")
    var out = _filled(16, 0)
    assert_equal(decompress(CompressionCodec.BROTLI, Span(blob), Span(out)), 0)


def test_too_small_output_is_refused() raises:
    var want = _read("ukkonooa")
    assert_true(
        _raises(_read("ukkonooa.compressed"), len(want) - 1),
        "a stream into one byte less than it decodes to must raise",
    )


def test_truncated_input_is_refused() raises:
    var blob = _read("ukkonooa.compressed")
    var cut = List[UInt8]()
    for i in range(len(blob) - 1):
        cut.append(blob[i])
    assert_true(_raises(cut, 1024), "a stream missing its last byte must raise")


def test_empty_input_is_refused() raises:
    assert_true(_raises(List[UInt8](), 16), "no bytes are not a Brotli stream")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
