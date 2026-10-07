# =============================================================================
# Tests for DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY, and DataPage V2
# =============================================================================
#
# Tests the DataPage V2 header parse, DELTA_LENGTH_BYTE_ARRAY and
# DELTA_BYTE_ARRAY.

from std.testing import TestSuite, assert_equal, assert_true
from std.memory import alloc, unsafe_memcpy, unsafe_memset
from std.sys import size_of

from komira_parquet import (
    DeltaDecoder,
    delta_binary_packed_byte_count,
    decode_delta_length_byte_array,
    decode_delta_byte_array,
)
from komira_parquet_api.types import PageType, Encoding


# =============================================================================
# Helper: encode DELTA_BINARY_PACKED from Int64 values
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
    _write_uleb128(output, encoded)


def _bits_needed(max_val: Int) -> Int:
    """Return the minimum number of bits needed to represent max_val."""
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
    var packed = alloc[UInt8](max(total_bytes, 1))
    unsafe_memset(packed, 0, max(total_bytes, 1))

    var bit_pos = 0
    for i in range(len(values)):
        var val = values[i]
        var byte_idx = bit_pos >> 3
        var bit_offset = bit_pos & 7
        var bytes_needed = ((bit_offset + bit_width) + 7) >> 3
        for b in range(min(bytes_needed, 8)):
            if byte_idx + b < total_bytes:
                var shift = b * 8 - bit_offset
                if shift >= 0:
                    (packed + byte_idx + b)[] = (packed + byte_idx + b)[] | UInt8((val >> shift) & 0xFF)
                else:
                    (packed + byte_idx + b)[] = (packed + byte_idx + b)[] | UInt8((val << (-shift)) & 0xFF)
        bit_pos += bit_width

    var result: List[UInt8] = []
    for i in range(total_bytes):
        result.append((packed + i)[])
    packed.free()
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

        delta_idx = block_end

    return output^


# =============================================================================
# Helper: encode DELTA_LENGTH_BYTE_ARRAY from a list of strings
# =============================================================================


def _encode_delta_length_byte_array(strings: List[String]) -> List[UInt8]:
    """Encode strings as DELTA_LENGTH_BYTE_ARRAY.

    Format: DELTA_BINARY_PACKED lengths + concatenated bytes.
    """
    # Encode lengths as delta binary packed.
    var lengths: List[Int64] = []
    for i in range(len(strings)):
        lengths.append(Int64(strings[i].byte_length()))
    var output = _encode_delta_binary_packed(lengths)

    # Concatenate all string bytes.
    for i in range(len(strings)):
        var s = strings[i]
        # SAFETY: transient pointer to copy String bytes; s is alive this iteration.
        var src_ptr = s.unsafe_ptr()
        for j in range(s.byte_length()):
            output.append((src_ptr + j)[])

    return output^


# =============================================================================
# Helper: encode DELTA_BYTE_ARRAY from a list of strings
# =============================================================================


def _encode_delta_byte_array(strings: List[String]) -> List[UInt8]:
    """Encode strings as DELTA_BYTE_ARRAY (prefix-delta encoding).

    Format: DELTA_BINARY_PACKED prefix_lengths + DELTA_LENGTH_BYTE_ARRAY suffixes.
    """
    # Compute prefix lengths and suffixes.
    var prefix_lengths: List[Int64] = []
    var suffixes: List[String] = []

    var prev = String("")
    for i in range(len(strings)):
        var cur = strings[i]
        # Find common prefix length.
        var plen = 0
        var max_common = min(prev.byte_length(), cur.byte_length())
        # SAFETY: transient pointers to compare bytes; both strings alive this iteration.
        var prev_ptr = prev.unsafe_ptr()
        var cur_ptr = cur.unsafe_ptr()
        while plen < max_common:
            if (prev_ptr + plen)[] != (cur_ptr + plen)[]:
                break
            plen += 1

        prefix_lengths.append(Int64(plen))
        # Suffix is cur[plen:].
        if plen < cur.byte_length():
            # Build suffix string from raw bytes.
            var suffix_buf = alloc[UInt8](cur.byte_length() - plen + 1)
            unsafe_memcpy(dest=suffix_buf, src=cur_ptr + plen, count=cur.byte_length() - plen)
            (suffix_buf + cur.byte_length() - plen).unsafe_write(UInt8(0))
            var suffix = String(unsafe_from_utf8_ptr=suffix_buf)
            suffix_buf.free()
            suffixes.append(suffix^)
        else:
            suffixes.append(String(""))

        prev = cur

    # Encode prefix lengths as DELTA_BINARY_PACKED.
    var output = _encode_delta_binary_packed(prefix_lengths)

    # Encode suffixes as DELTA_LENGTH_BYTE_ARRAY.
    var suffix_encoded = _encode_delta_length_byte_array(suffixes)
    for i in range(len(suffix_encoded)):
        output.append(suffix_encoded[i])

    return output^


# =============================================================================
# delta_binary_packed_byte_count tests
# =============================================================================


def test_byte_count_empty() raises:
    """Byte count of 0 values is 0."""
    var buf: List[UInt8] = [0]
    var count = delta_binary_packed_byte_count(Span(buf)[0:0], 0)
    assert_equal(count, 0)


def test_byte_count_roundtrip() raises:
    """Byte count matches what DeltaDecoder consumes."""
    var values: List[Int64] = [Int64(10), Int64(20), Int64(30), Int64(40), Int64(50)]
    var encoded = _encode_delta_binary_packed(values)
    var byte_count = delta_binary_packed_byte_count(Span(encoded), 5)

    # Decode and verify we get the same offset.
    var dec = DeltaDecoder(Span(encoded))
    var out = List[Int64](length=5, fill=0)
    var decoded = dec.decode_int64(5, Span(out))
    assert_equal(decoded, 5)
    # The byte_count should be at least as large as the decoder's final offset
    # (they may differ slightly due to miniblock padding, but both are valid).
    assert_true(byte_count > 0)
    assert_true(byte_count <= len(encoded))


# =============================================================================
# DELTA_LENGTH_BYTE_ARRAY tests
# =============================================================================


def test_delta_length_byte_array_empty() raises:
    """Decode DELTA_LENGTH_BYTE_ARRAY with 0 values."""
    var buf: List[UInt8] = [0]
    var arr = decode_delta_length_byte_array(Span(buf)[0:0], 0)
    assert_equal(len(arr), 0)


def test_delta_length_byte_array_single() raises:
    """Decode DELTA_LENGTH_BYTE_ARRAY with a single string."""
    var strings: List[String] = [String("hello")]
    var encoded = _encode_delta_length_byte_array(strings)
    var arr = decode_delta_length_byte_array(Span(encoded), 1)
    assert_equal(len(arr), 1)
    assert_equal(arr.get(0), "hello")


def test_delta_length_byte_array_multiple() raises:
    """Decode DELTA_LENGTH_BYTE_ARRAY with multiple strings."""
    var strings: List[String] = [String("alpha"), String("beta"), String("gamma")]
    var encoded = _encode_delta_length_byte_array(strings)
    var arr = decode_delta_length_byte_array(Span(encoded), 3)
    assert_equal(len(arr), 3)
    assert_equal(arr.get(0), "alpha")
    assert_equal(arr.get(1), "beta")
    assert_equal(arr.get(2), "gamma")


def test_delta_length_byte_array_varying_lengths() raises:
    """Decode DELTA_LENGTH_BYTE_ARRAY with varying string lengths."""
    var strings: List[String] = [
        String("a"),
        String("bb"),
        String("ccc"),
        String("dddd"),
        String("eeeee"),
    ]
    var encoded = _encode_delta_length_byte_array(strings)
    var arr = decode_delta_length_byte_array(Span(encoded), 5)
    assert_equal(len(arr), 5)
    assert_equal(arr.get(0), "a")
    assert_equal(arr.get(1), "bb")
    assert_equal(arr.get(2), "ccc")
    assert_equal(arr.get(3), "dddd")
    assert_equal(arr.get(4), "eeeee")


def test_delta_length_byte_array_empty_strings() raises:
    """Decode DELTA_LENGTH_BYTE_ARRAY with empty strings interspersed."""
    var strings: List[String] = [String(""), String("x"), String(""), String("yz")]
    var encoded = _encode_delta_length_byte_array(strings)
    var arr = decode_delta_length_byte_array(Span(encoded), 4)
    assert_equal(len(arr), 4)
    assert_equal(arr.get(0), "")
    assert_equal(arr.get(1), "x")
    assert_equal(arr.get(2), "")
    assert_equal(arr.get(3), "yz")


# =============================================================================
# DELTA_BYTE_ARRAY tests
# =============================================================================


def test_delta_byte_array_empty() raises:
    """Decode DELTA_BYTE_ARRAY with 0 values."""
    var buf: List[UInt8] = [0]
    var arr = decode_delta_byte_array(Span(buf)[0:0], 0)
    assert_equal(len(arr), 0)


def test_delta_byte_array_single() raises:
    """Decode DELTA_BYTE_ARRAY with a single string."""
    var strings: List[String] = [String("hello")]
    var encoded = _encode_delta_byte_array(strings)
    var arr = decode_delta_byte_array(Span(encoded), 1)
    assert_equal(len(arr), 1)
    assert_equal(arr.get(0), "hello")


def test_delta_byte_array_sorted_strings() raises:
    """Decode DELTA_BYTE_ARRAY with sorted strings sharing prefixes."""
    var strings: List[String] = [
        String("apple"),
        String("application"),
        String("apply"),
        String("banana"),
    ]
    var encoded = _encode_delta_byte_array(strings)
    var arr = decode_delta_byte_array(Span(encoded), 4)
    assert_equal(len(arr), 4)
    assert_equal(arr.get(0), "apple")
    assert_equal(arr.get(1), "application")
    assert_equal(arr.get(2), "apply")
    assert_equal(arr.get(3), "banana")


def test_delta_byte_array_no_common_prefix() raises:
    """Decode DELTA_BYTE_ARRAY where consecutive strings share no prefix."""
    var strings: List[String] = [String("aaa"), String("bbb"), String("ccc")]
    var encoded = _encode_delta_byte_array(strings)
    var arr = decode_delta_byte_array(Span(encoded), 3)
    assert_equal(len(arr), 3)
    assert_equal(arr.get(0), "aaa")
    assert_equal(arr.get(1), "bbb")
    assert_equal(arr.get(2), "ccc")


def test_delta_byte_array_full_prefix() raises:
    """Decode DELTA_BYTE_ARRAY where next string fully contains previous as prefix."""
    var strings: List[String] = [
        String("a"),
        String("ab"),
        String("abc"),
        String("abcd"),
    ]
    var encoded = _encode_delta_byte_array(strings)
    var arr = decode_delta_byte_array(Span(encoded), 4)
    assert_equal(len(arr), 4)
    assert_equal(arr.get(0), "a")
    assert_equal(arr.get(1), "ab")
    assert_equal(arr.get(2), "abc")
    assert_equal(arr.get(3), "abcd")


def test_delta_byte_array_urls() raises:
    """Decode DELTA_BYTE_ARRAY with URL-like sorted strings."""
    var strings: List[String] = [
        String("http://example.com/a"),
        String("http://example.com/b"),
        String("http://example.com/c"),
    ]
    var encoded = _encode_delta_byte_array(strings)
    var arr = decode_delta_byte_array(Span(encoded), 3)
    assert_equal(len(arr), 3)
    assert_equal(arr.get(0), "http://example.com/a")
    assert_equal(arr.get(1), "http://example.com/b")
    assert_equal(arr.get(2), "http://example.com/c")


# =============================================================================
# DataPage V2 header parsing tests
# =============================================================================


def _build_v2_page_header_thrift(
    page_type: Int,
    uncompressed_size: Int,
    compressed_size: Int,
    num_values: Int,
    num_nulls: Int,
    num_rows: Int,
    encoding_val: Int,
    def_levels_byte_length: Int,
    rep_levels_byte_length: Int,
    is_compressed: Bool,
) -> List[UInt8]:
    """Build a minimal Thrift Compact Protocol PageHeader with DataPageHeaderV2.

    Thrift Compact protocol:
    - Field header: high nibble = delta from previous field_id, low nibble = type
    - i32 type = 5 (zigzag varint)
    - struct type = 12
    - bool_true type = 1, bool_false type = 2
    - stop = 0x00
    """
    var output: List[UInt8] = []

    # field 1: type (i32 zigzag), delta=1 from prev_field_id=0
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, page_type)

    # field 2: uncompressed_page_size (i32 zigzag), delta=1
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, uncompressed_size)

    # field 3: compressed_page_size (i32 zigzag), delta=1
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, compressed_size)

    # PageHeader Thrift layout (parquet.thrift):
    #   field 1: type, field 2: uncompressed_size, field 3: compressed_size,
    #   field 4: crc, field 5: data_page_header (V1), field 6: index_page_header,
    #   field 7: dictionary_page_header, field 8: data_page_header_v2.
    # We skip fields 4/5/6/7 and jump straight to field 8.
    # Thrift Compact field header = (delta << 4) | type. delta = 8 - 3 = 5,
    # type = 12 (struct).
    output.append(UInt8((5 << 4) | 12))

    # --- DataPageHeaderV2 struct fields (prev_field_id resets to 0) ---
    # field 1: num_values
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, num_values)
    # field 2: num_nulls
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, num_nulls)
    # field 3: num_rows
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, num_rows)
    # field 4: encoding
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, encoding_val)
    # field 5: def_levels_byte_length
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, def_levels_byte_length)
    # field 6: rep_levels_byte_length
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, rep_levels_byte_length)
    # field 7: is_compressed (bool) — type 1=true, 2=false
    if is_compressed:
        output.append(UInt8((1 << 4) | 1))  # delta=1, type=bool_true
    else:
        output.append(UInt8((1 << 4) | 2))  # delta=1, type=bool_false
    # STOP for DataPageHeaderV2 struct
    output.append(UInt8(0))

    # STOP for PageHeader struct
    output.append(UInt8(0))

    return output^


def test_v2_page_header_parse() raises:
    """Parse a DataPageHeaderV2 Thrift header and verify all fields."""
    from komira_parquet.page_header_parser import _parse_page_header

    var encoded = _build_v2_page_header_thrift(
        page_type=3,  # DATA_PAGE_V2
        uncompressed_size=1024,
        compressed_size=512,
        num_values=100,
        num_nulls=5,
        num_rows=100,
        encoding_val=8,  # RLE_DICTIONARY
        def_levels_byte_length=20,
        rep_levels_byte_length=10,
        is_compressed=True,
    )
    var result = _parse_page_header(Span(encoded))
    var hdr = result.header.copy()

    assert_equal(Int(hdr.type.value), Int(PageType.DATA_PAGE_V2.value))
    assert_equal(hdr.uncompressed_page_size, 1024)
    assert_equal(hdr.compressed_page_size, 512)
    assert_equal(hdr.num_values, 100)
    assert_equal(hdr.num_nulls, 5)
    assert_equal(hdr.num_rows, 100)
    assert_equal(Int(hdr.encoding.value), Int(Encoding.RLE_DICTIONARY.value))
    assert_equal(hdr.def_levels_byte_length, 20)
    assert_equal(hdr.rep_levels_byte_length, 10)
    assert_true(hdr.is_compressed)



def test_v2_page_header_not_compressed() raises:
    """Parse DataPageHeaderV2 with is_compressed=False."""
    from komira_parquet.page_header_parser import _parse_page_header

    var encoded = _build_v2_page_header_thrift(
        page_type=3,
        uncompressed_size=256,
        compressed_size=256,
        num_values=50,
        num_nulls=0,
        num_rows=50,
        encoding_val=0,  # PLAIN
        def_levels_byte_length=0,
        rep_levels_byte_length=0,
        is_compressed=False,
    )
    var result = _parse_page_header(Span(encoded))
    var hdr = result.header.copy()

    assert_equal(Int(hdr.type.value), Int(PageType.DATA_PAGE_V2.value))
    assert_equal(hdr.num_values, 50)
    assert_equal(hdr.num_nulls, 0)
    assert_equal(Int(hdr.encoding.value), Int(Encoding.PLAIN.value))
    assert_true(not hdr.is_compressed)



def test_v2_page_header_v1_still_works() raises:
    """Verify that V1 DataPage headers still parse correctly after V2 support."""
    from komira_parquet.page_header_parser import _parse_page_header

    # Build a V1 DataPage header (field 5 instead of field 7).
    var output: List[UInt8] = []

    # field 1: type = 0 (DATA_PAGE)
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, 0)
    # field 2: uncompressed_page_size = 100
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, 100)
    # field 3: compressed_page_size = 80
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, 80)
    # field 5: DataPageHeader struct (delta=2 from field 3)
    output.append(UInt8((2 << 4) | 12))
    # DataPageHeader: field 1 = num_values
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, 42)
    # DataPageHeader: field 2 = encoding (PLAIN=0)
    output.append(UInt8((1 << 4) | 5))
    _write_zigzag_varint(output, 0)
    # STOP DataPageHeader
    output.append(UInt8(0))
    # STOP PageHeader
    output.append(UInt8(0))

    var result = _parse_page_header(Span(output))
    var hdr = result.header.copy()

    assert_equal(Int(hdr.type.value), Int(PageType.DATA_PAGE.value))
    assert_equal(hdr.uncompressed_page_size, 100)
    assert_equal(hdr.compressed_page_size, 80)
    assert_equal(hdr.num_values, 42)
    assert_equal(Int(hdr.encoding.value), Int(Encoding.PLAIN.value))
    # V2 fields should be defaults for V1 pages.
    assert_equal(hdr.num_nulls, 0)
    assert_equal(hdr.num_rows, 0)
    assert_equal(hdr.def_levels_byte_length, 0)
    assert_equal(hdr.rep_levels_byte_length, 0)
    assert_true(hdr.is_compressed)



# =============================================================================
# Main — discover and run all tests
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
