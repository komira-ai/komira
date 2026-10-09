# =============================================================================
# Every enum's name for every byte, the values Parquet does not define included
# =============================================================================
#
# A reader holds whatever byte a file's footer carries, so each enum must
# write a value it has no name for as `<Type>(<n>)`, not as a neighbour's
# name and not as an empty string. Each test sweeps the whole byte range
# 0..255 through both constructors (UInt8 and Int), built from a runtime
# value, and checks the written form: the defined values by their Thrift
# names (the numbers are held to parquet.thrift by
# test_values_match_parquet_thrift), every other value in the fallback form.
# Encoding's gap at 1 (the removed GROUP_VAR_INT) is one of those others.

from std.testing import TestSuite, assert_equal

from komira_parquet_api import (
    PageType,
    Encoding,
    CompressionCodec,
    ParquetType,
    FieldRepetitionType,
    BoundaryOrder,
)


def _expected(names: List[String], type_name: String, v: Int) -> String:
    """The name `names[v]` when it is defined (non-empty), else `T(v)`."""
    if v < len(names) and names[v] != "":
        return names[v]
    return type_name + "(" + String(v) + ")"


def _bytes() -> List[Int]:
    """0..255, built at run time so no constructor call is folded away."""
    var out = List[Int]()
    for v in range(256):
        out.append(v)
    return out^


def test_page_type_every_byte() raises:
    var names: List[String] = [
        "DATA_PAGE",
        "INDEX_PAGE",
        "DICTIONARY_PAGE",
        "DATA_PAGE_V2",
    ]
    for v in _bytes():
        var want = _expected(names, "PageType", v)
        assert_equal(String(PageType(UInt8(v))), want)
        assert_equal(String(PageType(v)), want)


def test_encoding_every_byte() raises:
    var names: List[String] = [
        "PLAIN",
        "",
        "PLAIN_DICTIONARY",
        "RLE",
        "BIT_PACKED",
        "DELTA_BINARY_PACKED",
        "DELTA_LENGTH_BYTE_ARRAY",
        "DELTA_BYTE_ARRAY",
        "RLE_DICTIONARY",
        "BYTE_STREAM_SPLIT",
    ]
    for v in _bytes():
        var want = _expected(names, "Encoding", v)
        assert_equal(String(Encoding(UInt8(v))), want)
        assert_equal(String(Encoding(v)), want)


def test_compression_codec_every_byte() raises:
    var names: List[String] = [
        "UNCOMPRESSED",
        "SNAPPY",
        "GZIP",
        "LZO",
        "BROTLI",
        "LZ4",
        "ZSTD",
        "LZ4_RAW",
    ]
    for v in _bytes():
        var want = _expected(names, "CompressionCodec", v)
        assert_equal(String(CompressionCodec(UInt8(v))), want)
        assert_equal(String(CompressionCodec(v)), want)


def test_parquet_type_every_byte() raises:
    var names: List[String] = [
        "BOOLEAN",
        "INT32",
        "INT64",
        "INT96",
        "FLOAT",
        "DOUBLE",
        "BYTE_ARRAY",
        "FIXED_LEN_BYTE_ARRAY",
    ]
    for v in _bytes():
        var want = _expected(names, "ParquetType", v)
        assert_equal(String(ParquetType(UInt8(v))), want)
        assert_equal(String(ParquetType(v)), want)


def test_field_repetition_type_every_byte() raises:
    var names: List[String] = ["REQUIRED", "OPTIONAL", "REPEATED"]
    for v in _bytes():
        var want = _expected(names, "FieldRepetitionType", v)
        assert_equal(String(FieldRepetitionType(UInt8(v))), want)
        assert_equal(String(FieldRepetitionType(v)), want)


def test_boundary_order_every_byte() raises:
    var names: List[String] = ["UNORDERED", "ASCENDING", "DESCENDING"]
    for v in _bytes():
        var want = _expected(names, "BoundaryOrder", v)
        assert_equal(String(BoundaryOrder(UInt8(v))), want)
        assert_equal(String(BoundaryOrder(v)), want)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
