# The shared writer helpers (`writer_helpers`): page-body compression,
# schema builders, integer statistics builders.
#
# What each test proves, and the defect it catches:
#   * _compress_page_body round-trips through komira_parquet_codec's
#     `decompress` for every codec the writer may write (SNAPPY, GZIP, ZSTD,
#     LZ4_RAW): a result not cut to the compressed length, or a codec
#     mix-up, fails the round trip; UNCOMPRESSED and an empty body come back
#     unchanged; the deprecated LZ4 (id 5) is refused, never written.
#   * make_schema_elements stamps ConvertedType.UTF8 on every BYTE_ARRAY
#     column: without it a text column reads back as `binary` (BYTE_ARRAY
#     with no annotation is binary in parquet.thrift).
#   * make_schema_elements_nullable: OPTIONAL/REQUIRED per column, the
#     `column_binary` flag suppresses UTF8, and each length mismatch raises.
#   * make_int64_statistics / make_int32_statistics: little-endian bytes,
#     two's complement for negatives.
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_parquet_api.types import (
    CONVERTED_TYPE_UTF8,
    CompressionCodec,
    FieldRepetitionType,
    ParquetType,
)
from komira_parquet_codec.compression import decompress
from komira_parquet_writer.writer_helpers import (
    _compress_page_body,
    make_int32_statistics,
    make_int64_statistics,
    make_schema_elements,
    make_schema_elements_nullable,
)


def _body(n: Int) -> List[UInt8]:
    """Compressible: a short repeating pattern with a slow drift."""
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i % 7) + (i // 97)))
    return out^


def _assert_same(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), what + ": byte " + String(i))


def test_compress_round_trips_every_written_codec() raises:
    var codecs: List[CompressionCodec] = [
        CompressionCodec.SNAPPY,
        CompressionCodec.GZIP,
        CompressionCodec.ZSTD,
        CompressionCodec.LZ4_RAW,
    ]
    var original = _body(5000)
    for c in range(len(codecs)):
        var codec = codecs[c]
        var packed = _compress_page_body(codec, original.copy())
        assert_true(len(packed) < len(original), String(codec) + " compresses")
        var out = List[UInt8](length=len(original), fill=0)
        var n = decompress(codec, Span(packed), Span(out))
        assert_equal(n, len(original), String(codec))
        _assert_same(out, original, String(codec))


def test_uncompressed_and_empty_pass_through() raises:
    var original = _body(100)
    _assert_same(
        _compress_page_body(CompressionCodec.UNCOMPRESSED, original.copy()),
        original,
        "UNCOMPRESSED",
    )
    assert_equal(len(_compress_page_body(CompressionCodec.ZSTD, List[UInt8]())), 0)


def test_deprecated_lz4_is_never_written() raises:
    with assert_raises(contains="LZ4_RAW"):
        _ = _compress_page_body(CompressionCodec.LZ4, _body(10))


def test_byte_array_columns_are_text() raises:
    var names: List[String] = ["id", "name"]
    var types: List[ParquetType] = [ParquetType.INT64, ParquetType.BYTE_ARRAY]
    var els = make_schema_elements(names^, types)
    assert_equal(len(els), 3)
    assert_equal(els[0].num_children, 2)
    assert_false(els[1].converted_type.__bool__())
    assert_equal(els[2].converted_type.value(), CONVERTED_TYPE_UTF8)
    assert_true(els[1].repetition_type.value() == FieldRepetitionType.REQUIRED)


def test_nullable_and_binary_flags() raises:
    var names: List[String] = ["a", "b", "c"]
    var types: List[ParquetType] = [
        ParquetType.BYTE_ARRAY,
        ParquetType.BYTE_ARRAY,
        ParquetType.INT32,
    ]
    var nullable: List[Bool] = [True, False, True]
    var binary: List[Bool] = [False, True, False]
    var els = make_schema_elements_nullable(names^, types, nullable, binary^)
    assert_true(els[1].repetition_type.value() == FieldRepetitionType.OPTIONAL)
    assert_true(els[2].repetition_type.value() == FieldRepetitionType.REQUIRED)
    assert_equal(els[1].converted_type.value(), CONVERTED_TYPE_UTF8)
    assert_false(els[2].converted_type.__bool__(), "a binary column is not text")
    assert_true(els[3].type.value() == ParquetType.INT32)


def test_length_mismatches_raise() raises:
    var types: List[ParquetType] = [ParquetType.INT32]
    with assert_raises(contains="column_types length"):
        _ = make_schema_elements(["a", "b"], types)
    with assert_raises(contains="column_nullable length"):
        _ = make_schema_elements_nullable(["a"], types, [True, False])
    var two_flags: List[Bool] = [True, True]
    with assert_raises(contains="column_binary length"):
        _ = make_schema_elements_nullable(["a"], types, [True], two_flags^)


def test_integer_statistics_bytes() raises:
    var s64 = make_int64_statistics(-2, 258, 1, 5)
    _assert_same(s64.min_value.value(), [0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], "min64")
    _assert_same(s64.max_value.value(), [0x02, 0x01, 0, 0, 0, 0, 0, 0], "max64")
    assert_equal(s64.null_count.value(), 1)
    assert_equal(s64.distinct_count.value(), 5)
    var s32 = make_int32_statistics(-1, 65536)
    _assert_same(s32.min_value.value(), [0xFF, 0xFF, 0xFF, 0xFF], "min32")
    _assert_same(s32.max_value.value(), [0x00, 0x00, 0x01, 0x00], "max32")
    assert_false(s32.distinct_count.__bool__())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
