# parquet_source_constants: the columns a multi-file scan builds without a
# column chunk.
#   - typed all-null columns for every supported type (BOOL bit-packed, one
#     bit per row; strings with n + 1 zero offsets), and a refusal for a
#     nested type;
#   - partition constants of every supported type: the value in every row,
#     the empty string as an all-null column, timestamps scaled per unit;
#   - partition text that is not a value of its type is refused, naming the
#     column, value and file: digits that overflow INT32 or an Int64,
#     impossible dates (Feb 30, Apr 31, Feb 29 of a non-leap year), trailing
#     text after a date, a timestamp with a bad separator, hour or minute.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_parquet.parquet_source_constants import (
    _build_constant_column,
    _build_typed_all_null_column,
)


def test_all_null_columns() raises:
    var types: List[ArrowType] = [
        ArrowType.INT8, ArrowType.UINT16, ArrowType.INT32, ArrowType.DATE32,
        ArrowType.INT64, ArrowType.TIMESTAMP_US, ArrowType.FLOAT32,
        ArrowType.FLOAT64, ArrowType.BOOL, ArrowType.STRING, ArrowType.BINARY,
    ]
    for k in range(len(types)):
        var c = _build_typed_all_null_column(types[k], 13)
        assert_true(c.arrow_type == types[k])
        assert_equal(c.length(), 13)
        assert_equal(c.null_count(), 13)
        for r in range(13):
            assert_true(c.is_null_at(r))
    # BOOL is one bit per row: 13 rows are 2 bytes.
    var b = _build_typed_all_null_column(ArrowType.BOOL, 13)
    assert_equal(Int(b._data.len()), 2)
    var s = _build_typed_all_null_column(ArrowType.STRING, 3)
    assert_equal(Int(s._offsets.value().len()), 16)
    with assert_raises(contains="no null column"):
        _ = _build_typed_all_null_column(ArrowType.LIST, 1)


def test_constants_of_each_type() raises:
    var s = _build_constant_column(ArrowType.STRING, "eu-west", 4, "region", "f")
    assert_equal(s.null_count(), 0)
    for r in range(4):
        assert_equal(s.as_string().get(r), "eu-west")
    var i64 = _build_constant_column(ArrowType.INT64, "-1234567890123", 3, "k", "f")
    assert_equal(Int(i64.as_primitive[DType.int64]().get(2)), -1234567890123)
    var i32 = _build_constant_column(ArrowType.INT32, "+2147483647", 2, "k", "f")
    assert_equal(Int(i32.as_primitive[DType.int32]().get(1)), 2147483647)
    var d = _build_constant_column(ArrowType.DATE32, "2028-02-29", 2, "dt", "f")
    assert_true(d.arrow_type == ArrowType.DATE32)
    assert_equal(Int(d.as_primitive[DType.int32]().get(0)), 21243)
    var ts_s = _build_constant_column(ArrowType.TIMESTAMP_S, "1970-01-02 01:02:03", 1, "t", "f")
    assert_equal(Int(ts_s.as_primitive[DType.int64]().get(0)), 86400 + 3723)
    var ts = _build_constant_column(ArrowType.TIMESTAMP, "1970-01-01 00:00:01", 1, "t", "f")
    assert_equal(Int(ts.as_primitive[DType.int64]().get(0)), 1_000_000)
    var ts_ns = _build_constant_column(ArrowType.TIMESTAMP_NS, "1970-01-01 00:00:01", 1, "t", "f")
    assert_equal(Int(ts_ns.as_primitive[DType.int64]().get(0)), 1_000_000_000)
    var f64 = _build_constant_column(ArrowType.FLOAT64, "2.5", 2, "x", "f")
    assert_equal(f64.as_primitive[DType.float64]().get(1), 2.5)
    var f32 = _build_constant_column(ArrowType.FLOAT32, "-0.25", 2, "x", "f")
    assert_equal(f32.as_primitive[DType.float32]().get(0), Float32(-0.25))
    var null = _build_constant_column(ArrowType.INT64, "", 5, "k", "f")
    assert_equal(null.null_count(), 5)


def _refused(t: ArrowType, value: String) raises:
    with assert_raises(contains="value '" + value + "' from file 'dir/f.parquet'"):
        _ = _build_constant_column(t, value, 1, "p", "dir/f.parquet")


def test_text_that_is_not_a_value_is_refused() raises:
    _refused(ArrowType.INT64, "12a")
    _refused(ArrowType.INT64, "-")
    _refused(ArrowType.INT64, "1234567890123456789")  # 19 digits
    _refused(ArrowType.INT32, "2147483648")
    _refused(ArrowType.INT32, "-2147483649")
    _refused(ArrowType.UINT32, "-1")
    _refused(ArrowType.DATE32, "2027-02-30")
    _refused(ArrowType.DATE32, "2027-04-31")
    _refused(ArrowType.DATE32, "2027-02-29")
    _refused(ArrowType.DATE32, "2027-01-01xyz")
    _refused(ArrowType.DATE32, "2027/01/01")
    _refused(ArrowType.TIMESTAMP, "2027-01-01T00:00:00")
    _refused(ArrowType.TIMESTAMP, "2027-01-01 24:00:00")
    _refused(ArrowType.TIMESTAMP, "2027-01-01 10:60:00")
    _refused(ArrowType.TIMESTAMP, "2027-01-01 10-00-00")
    _refused(ArrowType.FLOAT64, "two")
    with assert_raises(contains="no constant column"):
        _ = _build_constant_column(ArrowType.BOOL, "true", 1, "p", "f")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
