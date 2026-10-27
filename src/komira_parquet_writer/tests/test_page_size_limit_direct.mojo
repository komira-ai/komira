# The PageHeader i32 ceiling (`page_size_limit`) and its setter.
#
# What each test proves, and the defect it catches:
#   * the default ceiling is INT32_MAX, and a size at it passes while one
#     byte more is refused (an off-by-one in either direction fails).
#   * a negative size is refused (an upstream overflow must not become a
#     plausible header).
#   * the error names ParquetPageSizeOverflow, the column, the field, the
#     limit, and the wrapped value the narrowing would have written.
#   * set_parquet_page_size_limit lowers the trip point for the SAME header
#     serialisers ThriftCompactWriter uses (V1 and V2, both size fields),
#     and nothing is appended to the writer's buffer when it refuses.
#   * the setter can only lower: zero, negative and above-ceiling values
#     restore INT32_MAX (a setter that stored them would let a typo raise
#     the trip point past the i32 field).
# The setting is process-wide; each test sets what it needs and the last
# one restores the default.
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_parquet_api.types import Encoding
from komira_parquet_writer.page_size_limit import (
    PARQUET_PAGE_SIZE_MAX,
    check_parquet_page_size,
    parquet_page_size_limit,
    parquet_page_size_overflow,
    set_parquet_page_size_limit,
)
from komira_parquet_writer.thrift_writer import ThriftCompactWriter


def test_default_ceiling_is_int32_max() raises:
    set_parquet_page_size_limit(0)
    assert_equal(parquet_page_size_limit(), 2147483647)
    assert_equal(PARQUET_PAGE_SIZE_MAX, 2147483647)
    check_parquet_page_size("t", "f", PARQUET_PAGE_SIZE_MAX)
    with assert_raises(contains="ParquetPageSizeOverflow"):
        check_parquet_page_size("t", "f", PARQUET_PAGE_SIZE_MAX + 1)
    with assert_raises(contains="ParquetPageSizeOverflow"):
        check_parquet_page_size("t", "f", -1)


def test_error_text() raises:
    var e = parquet_page_size_overflow(
        "site", String("col_a"), "compressed_page_size", 2147483648, 2147483647
    )
    var msg = String(e)
    assert_true("column 'col_a'" in msg)
    assert_true("compressed_page_size" in msg)
    assert_true("2147483647" in msg)
    # 2^31 narrowed to i32 is -2^31.
    assert_true("-2147483648" in msg)
    var unnamed = String(parquet_page_size_overflow("s", String(), "f", 5, 4))
    assert_true("<unnamed column>" in unnamed)


def test_lowered_limit_trips_the_header_serialisers() raises:
    set_parquet_page_size_limit(1000)
    assert_equal(parquet_page_size_limit(), 1000)
    var w = ThriftCompactWriter()
    w.write_data_page_header(1000, 1000, 1, Encoding.PLAIN)
    var before = len(w.buf)
    with assert_raises(contains="uncompressed_page_size"):
        w.write_data_page_header(1001, 10, 1, Encoding.PLAIN)
    with assert_raises(contains="compressed_page_size"):
        w.write_data_page_header(10, 1001, 1, Encoding.PLAIN)
    with assert_raises(contains="write_data_page_v2_header"):
        w.write_data_page_v2_header(1001, 10, 1, 0, 1, Encoding.PLAIN, 0, 0)
    with assert_raises(contains="compressed_page_size"):
        w.write_data_page_v2_header(10, 1001, 1, 0, 1, Encoding.PLAIN, 0, 0)
    assert_equal(len(w.buf), before, "a refused header writes no byte")


def test_setter_only_lowers() raises:
    set_parquet_page_size_limit(-5)
    assert_equal(parquet_page_size_limit(), PARQUET_PAGE_SIZE_MAX)
    set_parquet_page_size_limit(PARQUET_PAGE_SIZE_MAX + 1)
    assert_equal(parquet_page_size_limit(), PARQUET_PAGE_SIZE_MAX)
    set_parquet_page_size_limit(1 << 40)
    assert_equal(parquet_page_size_limit(), PARQUET_PAGE_SIZE_MAX)
    set_parquet_page_size_limit(7)
    assert_equal(parquet_page_size_limit(), 7)
    set_parquet_page_size_limit(0)
    assert_equal(parquet_page_size_limit(), PARQUET_PAGE_SIZE_MAX)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
