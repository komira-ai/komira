# =============================================================================
# subrg_cursor_pages: page decompression through every writable codec, FLOAT
# dictionaries, empty dictionaries and truncated string dictionaries.
#
# What each test proves:
#   * a page body compressed with SNAPPY, ZSTD, LZ4_RAW or GZIP is decoded
#     into the scratch buffer to exactly the original bytes and length, and a
#     scratch that already held a longer page is shortened to the new length;
#   * a compressed page declaring a negative uncompressed size is refused,
#     and the scratch keeps the length it had;
#   * a FLOAT dictionary page is widened to Float64 entry by entry and leaves
#     the integer list empty;
#   * a dictionary of no entries leaves both lists as they were;
#   * a string dictionary whose length prefix is cut short, or whose entry
#     runs past the page, reports failure with both lists emptied, and an
#     intact one reports its cumulative offsets and packed bytes.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_codec.compression import compress, compress_bound

from komira_parquet.subrg_cursor_pages import _decode_numeric_dict, _decode_string_dict, _decompress_page_into


def _payload(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i * 7 + i // 5) & 0xFF))
    return out^


def _stored(codec: CompressionCodec, body: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8](length=compress_bound(codec, len(body)), fill=UInt8(0))
    out.resize(compress(codec, Span(body), Span(out)), UInt8(0))
    return out^


def _check_codec(codec: CompressionCodec) raises:
    var body = _payload(3000)
    var stored = _stored(codec, body)
    # A scratch that held a longer page before.
    var scratch = OwnedAlignedBuffer(8000)
    scratch.set_length(8000)
    _decompress_page_into(codec, Span(stored), len(body), scratch)
    assert_equal(Int(scratch.length()), len(body))
    var view = scratch.view_ro()
    for i in range(len(body)):
        assert_equal(view.get_typed[UInt8](i), body[i])


def test_snappy_page_is_decoded_into_the_scratch() raises:
    _check_codec(CompressionCodec.SNAPPY)


def test_zstd_page_is_decoded_into_the_scratch() raises:
    _check_codec(CompressionCodec.ZSTD)


def test_lz4_raw_page_is_decoded_into_the_scratch() raises:
    _check_codec(CompressionCodec.LZ4_RAW)


def test_gzip_page_is_decoded_into_the_scratch() raises:
    _check_codec(CompressionCodec.GZIP)


def test_a_negative_uncompressed_size_is_refused() raises:
    var stored = _stored(CompressionCodec.SNAPPY, _payload(100))
    var scratch = OwnedAlignedBuffer(64)
    scratch.set_length(10)
    with assert_raises(contains="negative uncompressed_page_size -5"):
        _decompress_page_into(CompressionCodec.SNAPPY, Span(stored), -5, scratch)
    assert_equal(Int(scratch.length()), 10)


def test_a_float_dictionary_is_widened_to_float64() raises:
    var page = List[UInt8]()
    var vals: List[Float32] = [1.5, -2.0, 0.25]
    for v in vals:
        var u = bitcast[DType.uint32](v)
        for b in range(4):
            page.append(UInt8((u >> UInt32(8 * b)) & 0xFF))
    var ints = List[Int64]()
    var floats = List[Float64]()
    _decode_numeric_dict(ParquetType.FLOAT, Span(page), 3, ints, floats)
    assert_equal(len(ints), 0)
    assert_equal(len(floats), 3)
    assert_equal(floats[0], 1.5)
    assert_equal(floats[1], -2.0)
    assert_equal(floats[2], 0.25)


def test_an_empty_dictionary_leaves_both_lists_alone() raises:
    var ints: List[Int64] = [9]
    var floats: List[Float64] = [4.5]
    var page = List[UInt8]()
    _decode_numeric_dict(ParquetType.INT64, Span(page), 0, ints, floats)
    assert_equal(len(ints), 1)
    assert_equal(ints[0], 9)
    assert_equal(len(floats), 1)
    assert_equal(floats[0], 4.5)


def _entry(mut page: List[UInt8], s: String):
    var n = s.byte_length()
    for b in range(4):
        page.append(UInt8((n >> (8 * b)) & 0xFF))
    var bytes = s.as_bytes()
    for i in range(n):
        page.append(bytes[i])


def test_an_intact_string_dictionary_reports_offsets_and_bytes() raises:
    var page = List[UInt8]()
    _entry(page, "ab")
    _entry(page, "")
    _entry(page, "cde")
    var offsets = List[Int32]()
    var data = List[UInt8]()
    assert_true(_decode_string_dict(Span(page), 3, offsets, data))
    assert_equal(len(offsets), 4)
    assert_equal(offsets[0], 0)
    assert_equal(offsets[1], 2)
    assert_equal(offsets[2], 2)
    assert_equal(offsets[3], 5)
    assert_equal(len(data), 5)
    assert_equal(data[0], UInt8(ord("a")))
    assert_equal(data[4], UInt8(ord("e")))


def test_a_string_dictionary_with_a_cut_length_prefix_fails_emptied() raises:
    var page = List[UInt8]()
    _entry(page, "ab")
    page.append(UInt8(1))
    page.append(UInt8(0))
    var offsets = List[Int32]()
    var data = List[UInt8]()
    assert_false(_decode_string_dict(Span(page), 2, offsets, data))
    assert_equal(len(offsets), 0)
    assert_equal(len(data), 0)


def test_a_string_dictionary_entry_past_the_page_fails_emptied() raises:
    var page = List[UInt8]()
    _entry(page, "ab")
    # A second entry declaring 9 bytes with only 2 present.
    page.append(UInt8(9))
    page.append(UInt8(0))
    page.append(UInt8(0))
    page.append(UInt8(0))
    page.append(UInt8(ord("x")))
    page.append(UInt8(ord("y")))
    var offsets = List[Int32]()
    var data = List[UInt8]()
    assert_false(_decode_string_dict(Span(page), 2, offsets, data))
    assert_equal(len(offsets), 0)
    assert_equal(len(data), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
