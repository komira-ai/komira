# Snappy short-offset (2..15) copies, which expand a repeating pattern (RLE),
# and a long literal with a one-byte extended length, on hand-built blobs.
# Each blob is decoded by both decoders (the C library's and the Mojo one),
# into a buffer with kSlopBytes of room and into one of the exact size.

from std.testing import TestSuite, assert_equal

from komira_parquet_codec.snappy import (
    SnappyDecoder,
    kSlopBytes,
    set_snappy_decoder,
    snappy_decompress,
)


def _filled(n: Int, b: UInt8) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(b)
    return out^


def _check(blob: List[UInt8], want: List[UInt8]) raises:
    """Decode `blob` with each decoder, with and without slop; each must give
    exactly `want`."""
    for d in range(2):
        var decoder = SnappyDecoder.MOJO if d == 1 else SnappyDecoder.C_LIBRARY
        for slop in range(2):
            var out = _filled(len(want) + (kSlopBytes if slop == 1 else 0), 0)
            set_snappy_decoder(decoder)
            var n = snappy_decompress(Span(blob), Span(out))
            set_snappy_decoder(SnappyDecoder.C_LIBRARY)
            var where = String(decoder) + (" +slop" if slop == 1 else " exact")
            assert_equal(n, len(want), where + ": length")
            for i in range(len(want)):
                assert_equal(
                    Int(out[i]), Int(want[i]), where + ": byte " + String(i)
                )


def _repeat(unit: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for i in range(n):
        out.append(unit[i % len(unit)])
    return out^


def test_offset_2() raises:
    # "ab" repeated to 18 bytes:
    #   varint(18)       = 0x12
    #   literal tag(3)   = (2<<2)|0 = 0x08, then bytes 'a','b','a'
    #   copy-2 tag(15,2) = tag=(14<<2)|2=0x3A, offset_lo=0x02, offset_hi=0x00
    var blob: List[UInt8] = [18, 0x08, 0x61, 0x62, 0x61, 0x3A, 0x02, 0x00]
    _check(blob, _repeat([UInt8(0x61), UInt8(0x62)], 18))


def test_offset_3() raises:
    # "abc" repeated to 18 bytes: literal(3) 'a','b','c', copy-2(15, offset=3).
    var blob: List[UInt8] = [18, 0x08, 0x61, 0x62, 0x63, 0x3A, 0x03, 0x00]
    _check(blob, _repeat([UInt8(0x61), UInt8(0x62), UInt8(0x63)], 18))


def test_offset_5() raises:
    # "abcde" repeated to 20 bytes: literal(5) (tag (4<<2)|0 = 0x10),
    # copy-2(15, offset=5).
    var blob: List[UInt8] = [
        20, 0x10, 0x61, 0x62, 0x63, 0x64, 0x65, 0x3A, 0x05, 0x00,
    ]
    _check(
        blob,
        _repeat(
            [UInt8(0x61), UInt8(0x62), UInt8(0x63), UInt8(0x64), UInt8(0x65)],
            20,
        ),
    )


def test_long_literal_one_byte_length() raises:
    # 100 bytes of 0xAB as one long literal: varint(100) = 0x64; tag
    # len_minus_1 = 60 (one extra length byte) = (60 << 2) | 0 = 0xF0; the
    # extra byte is 99 (100 - 1); then the 100 literal bytes.
    var blob: List[UInt8] = [100, 0xF0, 99]
    for _ in range(100):
        blob.append(0xAB)
    _check(blob, _filled(100, 0xAB))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
