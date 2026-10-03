# =============================================================================
# test_orc_byte_boolean_rle.mojo — ORC byte RLE + boolean RLE (PRESENT stream).
# =============================================================================
#
# Byte RLE backs TINYINT
# DATA + UNION tags + the PRESENT null bitmap (boolean RLE = byte RLE of
# bit-packed booleans). Fixtures hand-emitted (inverse of the decoders).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_orc import decode_byte_rle, decode_boolean_rle


# =============================================================================
# Byte RLE — run + literal.
# =============================================================================


def test_byte_rle_run() raises:
    # RUN: header = len-3, then one repeated byte. len 5, value 0xAB.
    var data = List[UInt8]()
    data.append(UInt8(5 - 3))
    data.append(UInt8(0xAB))
    var out = decode_byte_rle(data, 5)
    assert_equal(len(out), 5)
    for i in range(5):
        assert_equal(out[i], UInt8(0xAB))


def test_byte_rle_literal() raises:
    # LITERAL: header = 256 - count, then count raw bytes. count 3: 1,2,3.
    var data = List[UInt8]()
    data.append(UInt8(256 - 3))
    data.append(UInt8(1))
    data.append(UInt8(2))
    data.append(UInt8(3))
    var out = decode_byte_rle(data, 3)
    assert_equal(out[0], UInt8(1))
    assert_equal(out[1], UInt8(2))
    assert_equal(out[2], UInt8(3))


def test_byte_rle_mixed() raises:
    # A literal run of 2 (10, 20) followed by a run of 4 x 0x07.
    var data = List[UInt8]()
    data.append(UInt8(256 - 2))
    data.append(UInt8(10))
    data.append(UInt8(20))
    data.append(UInt8(4 - 3))
    data.append(UInt8(0x07))
    var out = decode_byte_rle(data, 6)
    assert_equal(len(out), 6)
    assert_equal(out[0], UInt8(10))
    assert_equal(out[1], UInt8(20))
    assert_equal(out[2], UInt8(0x07))
    assert_equal(out[5], UInt8(0x07))


# =============================================================================
# Boolean RLE — PRESENT stream: byte RLE of bit-packed booleans, MSB-first.
# =============================================================================


def test_boolean_rle_all_present() raises:
    # 8 rows, all present (0xFF). One literal byte.
    var data = List[UInt8]()
    data.append(UInt8(256 - 1))  # literal, 1 byte
    data.append(UInt8(0xFF))
    var out = decode_boolean_rle(data, 8)
    assert_equal(len(out), 8)
    for i in range(8):
        assert_true(out[i])


def test_boolean_rle_pattern() raises:
    # 5 rows with present pattern [T, F, T, T, F]. MSB-first byte = 0b10110000.
    var data = List[UInt8]()
    data.append(UInt8(256 - 1))  # literal, 1 byte (covers 8 bits, 5 used)
    data.append(UInt8(0b10110000))
    var out = decode_boolean_rle(data, 5)
    assert_equal(len(out), 5)
    assert_true(out[0])
    assert_true(not out[1])
    assert_true(out[2])
    assert_true(out[3])
    assert_true(not out[4])


def test_boolean_rle_run() raises:
    # 16 rows, all present. A run needs >=3 repeated bytes; a run of 3 0xFF
    # bytes = 24 bits, of which we take 16.
    var d2 = List[UInt8]()
    d2.append(UInt8(3 - 3))  # run length 3
    d2.append(UInt8(0xFF))
    var out = decode_boolean_rle(d2, 16)
    assert_equal(len(out), 16)
    for i in range(16):
        assert_true(out[i])


def main() raises:
    test_byte_rle_run()
    test_byte_rle_literal()
    test_byte_rle_mixed()
    test_boolean_rle_all_present()
    test_boolean_rle_pattern()
    test_boolean_rle_run()
    print("test_orc_byte_boolean_rle: ALL PASS")
