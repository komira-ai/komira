# =============================================================================
# Tests for Parquet encoding/decoding: PLAIN, RLE, DELTA_BINARY_PACKED
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true
from std.sys import size_of

from komira_parquet import (
    decode_plain_int32,
    decode_plain_int64,
    decode_plain_float32,
    decode_plain_float64,
    decode_plain_boolean,
    decode_plain_byte_array,
)
from komira_parquet import RleDecoder, decode_rle_int32, read_uleb128
from komira_parquet import DeltaDecoder


# =============================================================================
# Helper: build a raw byte buffer from a list of Int32 values (PLAIN encoding)
# =============================================================================


def _make_plain_int32_buf(values: List[Int32]) -> List[UInt8]:
    """Create a raw PLAIN-encoded Int32 buffer from a list of values."""
    var count = len(values)
    comptime elem_size = size_of[Int32]()
    var buf = List[UInt8](length=count * elem_size, fill=0)
    var typed = buf.unsafe_ptr().bitcast[Int32]()
    for i in range(count):
        (typed + i).unsafe_write(values[i])
    return buf^


def _make_plain_int64_buf(values: List[Int64]) -> List[UInt8]:
    """Create a raw PLAIN-encoded Int64 buffer."""
    var count = len(values)
    comptime elem_size = size_of[Int64]()
    var buf = List[UInt8](length=count * elem_size, fill=0)
    var typed = buf.unsafe_ptr().bitcast[Int64]()
    for i in range(count):
        (typed + i).unsafe_write(values[i])
    return buf^


def _make_plain_float64_buf(values: List[Float64]) -> List[UInt8]:
    """Create a raw PLAIN-encoded Float64 buffer."""
    var count = len(values)
    comptime elem_size = size_of[Float64]()
    var buf = List[UInt8](length=count * elem_size, fill=0)
    var typed = buf.unsafe_ptr().bitcast[Float64]()
    for i in range(count):
        (typed + i).unsafe_write(values[i])
    return buf^


# =============================================================================
# Helper: build RLE-encoded byte streams
# =============================================================================


def _encode_rle_run(value: Int, count: Int, bit_width: Int) -> List[UInt8]:
    """Encode a single RLE run: header (count << 1 | 0) + value bytes."""
    var result: List[UInt8] = []
    # Write varint header: (count << 1) | 0
    var header = count << 1
    while header >= 0x80:
        result.append(UInt8((header & 0x7F) | 0x80))
        header = header >> 7
    result.append(UInt8(header))

    # Write value in ceil(bit_width/8) bytes, little-endian.
    var value_bytes = (bit_width + 7) >> 3
    for b in range(value_bytes):
        result.append(UInt8((value >> (b * 8)) & 0xFF))
    return result^


def _encode_bitpacked_group(values: List[Int], bit_width: Int) -> List[UInt8]:
    """Encode values as a single bit-packed group.

    Groups are always 8 values. Pads with zeros if fewer than 8 are provided.
    Header: (num_groups << 1) | 1
    """
    var result: List[UInt8] = []
    var num_groups = (len(values) + 7) // 8

    # Write header varint.
    var header = (num_groups << 1) | 1
    while header >= 0x80:
        result.append(UInt8((header & 0x7F) | 0x80))
        header = header >> 7
    result.append(UInt8(header))

    # Bit-pack the values, 8 per group, bit_width bits each.
    var total_bits = num_groups * 8 * bit_width
    var total_bytes = (total_bits + 7) // 8
    # Build a zero-filled packed buffer.
    var packed = List[UInt8](length=total_bytes, fill=0)

    var bit_pos = 0
    for i in range(num_groups * 8):
        var val = 0
        if i < len(values):
            val = values[i]

        var byte_idx = bit_pos >> 3
        var bit_offset = bit_pos & 7
        # Write value bits spanning byte boundaries.
        var remaining = bit_width
        var v = val
        var bi = byte_idx
        var bo = bit_offset
        while remaining > 0 and bi < total_bytes:
            var space = 8 - bo
            var write_bits = min(remaining, space)
            var mask = (1 << write_bits) - 1
            packed[bi] = packed[bi] | UInt8((v & mask) << bo)
            v = v >> write_bits
            remaining -= write_bits
            bo = 0
            bi += 1

        bit_pos += bit_width

    for i in range(total_bytes):
        result.append(packed[i])

    return result^


# =============================================================================
# Helper: build DELTA_BINARY_PACKED encoded streams
# =============================================================================


def _write_uleb128(mut output: List[UInt8], value: Int):
    """Write a ULEB128 varint into the output list."""
    var v = value
    while True:
        var byte = v & 0x7F
        v = v >> 7
        if v != 0:
            byte = byte | 0x80
        output.append(UInt8(byte))
        if v == 0:
            break


def _write_zigzag_varint(mut output: List[UInt8], value: Int):
    """Write a zigzag-encoded varint into the output list."""
    var encoded = (value << 1) ^ (value >> 63)
    # Handle negative encoding results by masking. In Mojo, Int is 64-bit
    # and arithmetic shift preserves sign, so the XOR may produce a negative.
    # ULEB128 just reads the low 7 bits at a time, so it works correctly.
    _write_uleb128(output, encoded)


def _bits_needed(max_val: Int) -> Int:
    """Minimum bits to represent max_val (unsigned)."""
    if max_val == 0:
        return 0
    var bits = 0
    var v = max_val
    while v > 0:
        bits += 1
        v = v >> 1
    return bits


def _pack_miniblock_values(
    values: List[Int], bit_width: Int
) -> List[UInt8]:
    """Bit-pack a miniblock of delta offset values."""
    var total_bytes = (len(values) * bit_width + 7) // 8
    var packed = List[UInt8](length=max(total_bytes, 1), fill=0)

    var bit_pos = 0
    for i in range(len(values)):
        var val = values[i]
        var byte_idx = bit_pos >> 3
        var bit_offset = bit_pos & 7
        var remaining = bit_width
        var v = val
        var bi = byte_idx
        var bo = bit_offset
        while remaining > 0 and bi < total_bytes:
            var space = 8 - bo
            var write_bits = min(remaining, space)
            var mask = (1 << write_bits) - 1
            packed[bi] = packed[bi] | UInt8((v & mask) << bo)
            v = v >> write_bits
            remaining -= write_bits
            bo = 0
            bi += 1
        bit_pos += bit_width

    var result: List[UInt8] = []
    for i in range(total_bytes):
        result.append(packed[i])
    return result^


def _encode_delta_binary_packed(values: List[Int64]) -> List[UInt8]:
    """Encode Int64 values as DELTA_BINARY_PACKED.

    Uses block_size=128, miniblock_count=4.
    """
    var output: List[UInt8] = []
    var block_size = 128
    var miniblock_count = 4
    var miniblock_size = block_size // miniblock_count  # 32

    _write_uleb128(output, block_size)
    _write_uleb128(output, miniblock_count)
    _write_uleb128(output, len(values))

    if len(values) == 0:
        _write_zigzag_varint(output, 0)
        return output^

    _write_zigzag_varint(output, Int(values[0]))

    if len(values) <= 1:
        return output^

    # Compute deltas.
    var deltas: List[Int] = []
    for i in range(1, len(values)):
        deltas.append(Int(values[i]) - Int(values[i - 1]))

    # Process in blocks.
    var delta_idx = 0
    while delta_idx < len(deltas):
        var block_end = min(delta_idx + block_size, len(deltas))

        # Find min_delta in this block.
        var min_delta = deltas[delta_idx]
        for i in range(delta_idx + 1, block_end):
            if deltas[i] < min_delta:
                min_delta = deltas[i]

        _write_zigzag_varint(output, min_delta)

        # Compute normalized deltas and bit widths per miniblock.
        var all_normalized: List[List[Int]] = []
        var bit_widths: List[Int] = []

        for mb in range(miniblock_count):
            var mb_start = delta_idx + mb * miniblock_size
            var mb_end = min(mb_start + miniblock_size, block_end)

            var mb_normalized: List[Int] = []
            var max_val = 0

            if mb_start < block_end:
                for i in range(mb_start, mb_end):
                    var norm = deltas[i] - min_delta
                    mb_normalized.append(norm)
                    if norm > max_val:
                        max_val = norm
                # Pad to miniblock_size.
                while len(mb_normalized) < miniblock_size:
                    mb_normalized.append(0)
            else:
                for _p in range(miniblock_size):
                    mb_normalized.append(0)

            all_normalized.append(mb_normalized^)
            bit_widths.append(_bits_needed(max_val))

        # Write bit widths.
        for mb in range(miniblock_count):
            output.append(UInt8(bit_widths[mb]))

        # Write bit-packed miniblocks.
        for mb in range(miniblock_count):
            var bw = bit_widths[mb]
            if bw > 0:
                var packed = _pack_miniblock_values(all_normalized[mb], bw)
                for i in range(len(packed)):
                    output.append(packed[i])
            else:
                # bw=0: no bytes needed (all deltas == min_delta).
                pass

        delta_idx = block_end

    return output^


# =============================================================================
# PLAIN ENCODING TESTS
# =============================================================================


def test_plain_int32_known_values() raises:
    """Decode PLAIN Int32 with known values [10, 20, 30, 40, 50]."""
    var values: List[Int32] = [Int32(10), Int32(20), Int32(30), Int32(40), Int32(50)]
    var buf = _make_plain_int32_buf(values)
    var arr = decode_plain_int32(Span(buf), 5)
    assert_equal(arr.length, 5)
    assert_equal(arr.get(0), Scalar[DType.int32](10))
    assert_equal(arr.get(1), Scalar[DType.int32](20))
    assert_equal(arr.get(2), Scalar[DType.int32](30))
    assert_equal(arr.get(3), Scalar[DType.int32](40))
    assert_equal(arr.get(4), Scalar[DType.int32](50))


def test_plain_int32_empty() raises:
    """Decode PLAIN Int32 with 0 values."""
    var buf = List[UInt8](length=1, fill=0)
    var arr = decode_plain_int32(Span(buf)[0:0], 0)
    assert_equal(arr.length, 0)


def test_plain_int64_known_values() raises:
    """Decode PLAIN Int64 with known values."""
    var values: List[Int64] = [
        Int64(100000),
        Int64(-200000),
        Int64(300000),
        Int64(0),
    ]
    var buf = _make_plain_int64_buf(values)
    var arr = decode_plain_int64(Span(buf), 4)
    assert_equal(arr.length, 4)
    assert_equal(arr.get(0), Scalar[DType.int64](100000))
    assert_equal(arr.get(1), Scalar[DType.int64](-200000))
    assert_equal(arr.get(2), Scalar[DType.int64](300000))
    assert_equal(arr.get(3), Scalar[DType.int64](0))


def test_plain_float64_known_values() raises:
    """Decode PLAIN Float64 with known values."""
    var values: List[Float64] = [Float64(1.5), Float64(-2.7), Float64(3.14159)]
    var buf = _make_plain_float64_buf(values)
    var arr = decode_plain_float64(Span(buf), 3)
    assert_equal(arr.length, 3)
    # Float comparison: assert_true with tolerance.
    var v0 = arr.get(0)
    var v1 = arr.get(1)
    var v2 = arr.get(2)
    assert_true(abs(Float64(v0) - 1.5) < 1e-10)
    assert_true(abs(Float64(v1) - (-2.7)) < 1e-10)
    assert_true(abs(Float64(v2) - 3.14159) < 1e-10)


def test_plain_float32_known_values() raises:
    """Decode PLAIN Float32 with known values."""
    comptime elem_size = size_of[Float32]()
    var buf = List[UInt8](length=3 * elem_size, fill=0)
    var typed = buf.unsafe_ptr().bitcast[Float32]()
    (typed + 0).unsafe_write(Float32(1.0))
    (typed + 1).unsafe_write(Float32(2.0))
    (typed + 2).unsafe_write(Float32(3.0))
    var arr = decode_plain_float32(Span(buf), 3)
    assert_equal(arr.length, 3)
    assert_true(abs(Float64(arr.get(0)) - 1.0) < 1e-5)
    assert_true(abs(Float64(arr.get(1)) - 2.0) < 1e-5)
    assert_true(abs(Float64(arr.get(2)) - 3.0) < 1e-5)


def test_plain_boolean_known_pattern() raises:
    """Decode PLAIN boolean with known bit pattern.

    Byte 0xA5 = 10100101 -> [T, F, T, F, F, T, F, T] (LSB-first).
    """
    var buf: List[UInt8] = [UInt8(0xA5)]
    var arr = decode_plain_boolean(Span(buf), 8)
    assert_equal(arr.length, 8)
    assert_equal(arr.get(0), True)   # bit 0 = 1
    assert_equal(arr.get(1), False)  # bit 1 = 0
    assert_equal(arr.get(2), True)   # bit 2 = 1
    assert_equal(arr.get(3), False)  # bit 3 = 0
    assert_equal(arr.get(4), False)  # bit 4 = 0
    assert_equal(arr.get(5), True)   # bit 5 = 1
    assert_equal(arr.get(6), False)  # bit 6 = 0
    assert_equal(arr.get(7), True)   # bit 7 = 1


def test_plain_boolean_partial_byte() raises:
    """Decode PLAIN boolean with fewer values than a full byte (5 of 8 bits)."""
    # 0xFF = all bits set, but only decode 5 values.
    var buf: List[UInt8] = [UInt8(0xFF)]
    var arr = decode_plain_boolean(Span(buf), 5)
    assert_equal(arr.length, 5)
    for i in range(5):
        assert_equal(arr.get(i), True)


def test_plain_byte_array_known_strings() raises:
    """Decode PLAIN BYTE_ARRAY with known strings ["hello", "world", "!"]."""
    # Format: [len: u32_le][bytes] for each string.
    var total_size = (4 + 5) + (4 + 5) + (4 + 1)  # 23 bytes
    var buf = List[UInt8]()
    var words: List[String] = ["hello", "world", "!"]
    for w in range(len(words)):
        var n = words[w].byte_length()
        for k in range(4):
            buf.append(UInt8((n >> (8 * k)) & 0xFF))
        var b = words[w].as_bytes()
        for k in range(n):
            buf.append(b[k])
    assert_equal(len(buf), total_size)

    var arr = decode_plain_byte_array(Span(buf), 3)
    assert_equal(arr.length, 3)
    assert_equal(arr.get(0), "hello")
    assert_equal(arr.get(1), "world")
    assert_equal(arr.get(2), "!")


def test_plain_byte_array_empty() raises:
    """Decode PLAIN BYTE_ARRAY with 0 values."""
    var buf = List[UInt8](length=1, fill=0)
    var arr = decode_plain_byte_array(Span(buf), 0)
    assert_equal(arr.length, 0)


# =============================================================================
# RLE ENCODING TESTS
# =============================================================================


def test_rle_run_all_same() raises:
    """Decode an RLE run where all 10 values are the same (value=42)."""
    var encoded = _encode_rle_run(42, 10, 8)

    var output = List[Int32](length=10, fill=0)
    var decoder = RleDecoder(Span(encoded), 8)
    var decoded = decoder.decode_int32(10, Span(output))

    assert_equal(decoded, 10)
    for i in range(10):
        assert_equal(output[i], Int32(42))


def test_rle_bitpacked_group() raises:
    """Decode a bit-packed group with bit_width=1 (8 boolean-like values)."""
    var values: List[Int] = [1, 0, 1, 0, 0, 1, 0, 1]
    var encoded = _encode_bitpacked_group(values, 1)

    var output = List[Int32](length=8, fill=0)
    var decoder = RleDecoder(Span(encoded), 1)
    var decoded = decoder.decode_int32(8, Span(output))

    assert_equal(decoded, 8)
    assert_equal(output[0], Int32(1))
    assert_equal(output[1], Int32(0))
    assert_equal(output[2], Int32(1))
    assert_equal(output[3], Int32(0))
    assert_equal(output[4], Int32(0))
    assert_equal(output[5], Int32(1))
    assert_equal(output[6], Int32(0))
    assert_equal(output[7], Int32(1))


def test_rle_mixed_rle_and_bitpacked() raises:
    """Decode a stream with an RLE run followed by a bit-packed group."""
    # RLE run: 4 copies of value 3, bit_width=4
    var rle_part = _encode_rle_run(3, 4, 4)
    # Bit-packed: 8 values [0,1,2,3,4,5,6,7] at bit_width=4
    var bp_values: List[Int] = [0, 1, 2, 3, 4, 5, 6, 7]
    var bp_part = _encode_bitpacked_group(bp_values, 4)

    var combined: List[UInt8] = []
    for i in range(len(rle_part)):
        combined.append(rle_part[i])
    for i in range(len(bp_part)):
        combined.append(bp_part[i])

    var output = List[Int32](length=12, fill=0)
    var decoder = RleDecoder(Span(combined), 4)
    var decoded = decoder.decode_int32(12, Span(output))

    assert_equal(decoded, 12)
    # First 4: RLE value 3.
    for i in range(4):
        assert_equal(output[i], Int32(3))
    # Next 8: bit-packed [0..7].
    for i in range(8):
        assert_equal(output[4 + i], Int32(i))


def test_rle_bitwidth_2() raises:
    """Decode bit-packed data at bit_width=2."""
    var values: List[Int] = [0, 1, 2, 3, 0, 1, 2, 3]
    var encoded = _encode_bitpacked_group(values, 2)

    var output = List[Int32](length=8, fill=0)
    var decoder = RleDecoder(Span(encoded), 2)
    var decoded = decoder.decode_int32(8, Span(output))

    assert_equal(decoded, 8)
    for i in range(8):
        assert_equal(output[i], Int32(values[i]))


def test_rle_bitwidth_4() raises:
    """Decode bit-packed data at bit_width=4."""
    var values: List[Int] = [0, 5, 10, 15, 1, 6, 11, 14]
    var encoded = _encode_bitpacked_group(values, 4)

    var output = List[Int32](length=8, fill=0)
    var decoder = RleDecoder(Span(encoded), 4)
    var decoded = decoder.decode_int32(8, Span(output))

    assert_equal(decoded, 8)
    for i in range(8):
        assert_equal(output[i], Int32(values[i]))


def test_rle_bitwidth_8() raises:
    """Decode bit-packed data at bit_width=8."""
    var values: List[Int] = [0, 42, 100, 200, 255, 128, 64, 1]
    var encoded = _encode_bitpacked_group(values, 8)

    var output = List[Int32](length=8, fill=0)
    var decoder = RleDecoder(Span(encoded), 8)
    var decoded = decoder.decode_int32(8, Span(output))

    assert_equal(decoded, 8)
    for i in range(8):
        assert_equal(output[i], Int32(values[i]))


def test_rle_varint_reading() raises:
    """Test varint reading with multi-byte varints."""
    # Encode 300 as ULEB128: 300 = 0b100101100 -> [0xAC, 0x02]
    var buf: List[UInt8] = [UInt8(0xAC), UInt8(0x02)]

    var result = read_uleb128(Span(buf), 0)
    assert_equal(result[0], 300)
    assert_equal(result[1], 2)


def test_rle_varint_single_byte() raises:
    """Test varint reading with a single-byte varint."""
    var buf: List[UInt8] = [UInt8(42)]

    var result = read_uleb128(Span(buf), 0)
    assert_equal(result[0], 42)
    assert_equal(result[1], 1)


# =============================================================================
# DELTA ENCODING TESTS
# =============================================================================


def test_delta_sequential_values() raises:
    """Decode sequential values (constant delta=1): [0, 1, 2, ..., 99]."""
    var values: List[Int64] = []
    for i in range(100):
        values.append(Int64(i))

    var encoded = _encode_delta_binary_packed(values)

    var output = List[Int64](length=100, fill=0)
    var decoder = DeltaDecoder(Span(encoded))
    var decoded = decoder.decode_int64(100, Span(output))

    assert_equal(decoded, 100)
    for i in range(100):
        assert_equal(output[i], Int64(i))


def test_delta_constant_values() raises:
    """Decode constant values (delta=0): all values are 42."""
    var values: List[Int64] = []
    for _i in range(50):
        values.append(Int64(42))

    var encoded = _encode_delta_binary_packed(values)

    var output = List[Int64](length=50, fill=0)
    var decoder = DeltaDecoder(Span(encoded))
    var decoded = decoder.decode_int64(50, Span(output))

    assert_equal(decoded, 50)
    for i in range(50):
        assert_equal(output[i], Int64(42))


def test_delta_varying_deltas() raises:
    """Decode values with varying deltas: [0, 1, 3, 6, 10, 15, 21, 28]."""
    var values: List[Int64] = [
        Int64(0),
        Int64(1),
        Int64(3),
        Int64(6),
        Int64(10),
        Int64(15),
        Int64(21),
        Int64(28),
    ]

    var encoded = _encode_delta_binary_packed(values)

    var output = List[Int64](length=8, fill=0)
    var decoder = DeltaDecoder(Span(encoded))
    var decoded = decoder.decode_int64(8, Span(output))

    assert_equal(decoded, 8)
    for i in range(8):
        assert_equal(output[i], values[i])


def test_delta_single_value() raises:
    """Decode a single value."""
    var values: List[Int64] = [Int64(12345)]
    var encoded = _encode_delta_binary_packed(values)

    var output = List[Int64](length=1, fill=0)
    var decoder = DeltaDecoder(Span(encoded))
    var decoded = decoder.decode_int64(1, Span(output))

    assert_equal(decoded, 1)
    assert_equal(output[0], Int64(12345))


def test_delta_int32_decode() raises:
    """Decode delta-encoded values narrowed to Int32."""
    var values: List[Int64] = [Int64(10), Int64(20), Int64(30), Int64(40), Int64(50)]
    var encoded = _encode_delta_binary_packed(values)

    var output = List[Int32](length=5, fill=0)
    var decoder = DeltaDecoder(Span(encoded))
    var decoded = decoder.decode_int32(5, Span(output))

    assert_equal(decoded, 5)
    assert_equal(output[0], Int32(10))
    assert_equal(output[1], Int32(20))
    assert_equal(output[2], Int32(30))
    assert_equal(output[3], Int32(40))
    assert_equal(output[4], Int32(50))


def test_delta_negative_deltas() raises:
    """Decode values with negative deltas: [100, 97, 94, 91, 88]."""
    var values: List[Int64] = [
        Int64(100),
        Int64(97),
        Int64(94),
        Int64(91),
        Int64(88),
    ]
    var encoded = _encode_delta_binary_packed(values)

    var output = List[Int64](length=5, fill=0)
    var decoder = DeltaDecoder(Span(encoded))
    var decoded = decoder.decode_int64(5, Span(output))

    assert_equal(decoded, 5)
    for i in range(5):
        assert_equal(output[i], values[i])


def test_delta_large_values() raises:
    """Decode values with large magnitudes: [1000000, 2000000, 3000000]."""
    var values: List[Int64] = [Int64(1000000), Int64(2000000), Int64(3000000)]
    var encoded = _encode_delta_binary_packed(values)

    var output = List[Int64](length=3, fill=0)
    var decoder = DeltaDecoder(Span(encoded))
    var decoded = decoder.decode_int64(3, Span(output))

    assert_equal(decoded, 3)
    assert_equal(output[0], Int64(1000000))
    assert_equal(output[1], Int64(2000000))
    assert_equal(output[2], Int64(3000000))


# =============================================================================
# ENTRY POINT
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
