# =============================================================================
# typed_column_builders: every arm of the 22 widened-type builders.
# =============================================================================
#
# `typed_column_builders.mojo` turns the cells of one column into an Arrow
# column for the types the base cascade (Int64, Float64, Date32, Bool, String)
# does not build. Each builder has the same arms, and this file drives each
# one for every type:
#
#   R  The reader path. A one-column CSV with CRLF line ends (RFC 4180,
#      section 2, rule 1) read by `read_csv_bytes_to_batch[Rfc4180]` with
#      the column's type DECLARED (`declared_column_types`), so the reader
#      routes it to `dispatch_typed_builder`. Four records: a valid value, the
#      null token `NA`, a cell that type cannot hold, and the valid value
#      again as a quoted field (rule 5: a field may be enclosed in quotes; the
#      quotes are not part of the value). Proves: the routing (the column's
#      type tag), the value written, the null-token arm and the parse-failure
#      arm (each clears the validity bit AND counts the null).
#   M  The missing-cell arm. `check_csv_record_shape` refuses a short record
#      before any builder runs, so no reader reaches it; the builders keep it
#      as a bounds guard, and `dispatch_typed_builder` is public. Rows
#      scanned from `1,<v>` / `2` / `3,NA` are handed to it directly: row 1
#      has no cell at column 1 and must read as null, and the rows after it
#      must still be built.
#   T  The temporal fast paths. Date64 parses the 10-byte date with the SIMD
#      path and every longer form with the scalar parser; both are read. For
#      Timestamp_* and Time_* a cell the SIMD gate refuses goes to the scalar
#      parser and is refused there too (the null in R).
#   D  Decimal128: the sign of the mantissa sets the high word (sign
#      extension); `-0.00` is zero, not negative.
#   U  A declared type no builder handles is refused with the column number.
#   S  Float32 honours `decimal_separator`.
#
# Values are RFC-shaped boundary cases (type limits, the first
# out-of-range value), not a fuzz corpus.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_csv import (
    CsvReadOptions,
    Rfc4180,
    dispatch_typed_builder,
    read_csv_bytes_to_batch,
    scan_csv_phase1_into_cells,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _value(col: Column[HeapRegion], r: Int) raises -> Int:
    """Row `r` of `col` as an Int, read at the storage width its type tag
    names (so a builder that wrote the wrong width cannot pass)."""
    var t = col.arrow_type
    if t == ArrowType.UINT8:
        return Int(col.as_primitive[DType.uint8]().get(r))
    if t == ArrowType.UINT16:
        return Int(col.as_primitive[DType.uint16]().get(r))
    if t == ArrowType.UINT32:
        return Int(col.as_primitive[DType.uint32]().get(r))
    if t == ArrowType.UINT64:
        return Int(col.as_primitive[DType.uint64]().get(r))
    if t == ArrowType.INT8:
        return Int(col.as_primitive[DType.int8]().get(r))
    if t == ArrowType.INT16:
        return Int(col.as_primitive[DType.int16]().get(r))
    if t == ArrowType.INT32 or t == ArrowType.TIME32_S or t == ArrowType.TIME32_MS:
        return Int(col.as_primitive[DType.int32]().get(r))
    if t == ArrowType.FLOAT32:
        return Int(col.as_primitive[DType.float32]().get(r))
    if t == ArrowType.DECIMAL128:
        return Int(col.as_decimal128().get_low(r))
    return Int(col.as_primitive[DType.int64]().get(r))


def _options(dtype: ArrowType) -> CsvReadOptions:
    var opts = CsvReadOptions()
    opts.declared_column_types.append(dtype)
    return opts^


def _check_reader(
    dtype: ArrowType, valid: String, expected: Int, invalid: String
) raises:
    """R: valid / NA / invalid / quoted valid, CRLF, declared type."""
    var text = (
        String("v\r\n") + valid + "\r\nNA\r\n" + invalid + "\r\n\"" + valid
        + "\"\r\n"
    )
    var buf = _bytes(text)
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), _options(dtype))
    var what = String(dtype) + " reading " + valid + " / " + invalid
    assert_equal(rb.num_rows(), 4, what)
    assert_true(rb.schema.field_at(0).arrow_type == dtype, what)
    ref col = rb.column_at(0)
    assert_true(col.arrow_type == dtype, "column tag: " + what)
    assert_equal(col.length(), 4, what)
    assert_false(col.is_null_at(0), what)
    assert_equal(_value(col, 0), expected, "value: " + what)
    assert_true(col.is_null_at(1), "NA is null: " + what)
    assert_true(col.is_null_at(2), invalid + " is null: " + what)
    assert_false(col.is_null_at(3), "quoted: " + what)
    assert_equal(_value(col, 3), expected, "quoted value: " + what)
    assert_equal(col.null_count(), 2, "null count: " + what)


def _check_missing_cell(
    dtype: ArrowType, valid: String, expected: Int
) raises:
    """M: a row with no cell at the column reads as null; the next rows are
    built."""
    var text = String("k,v\n1,") + valid + "\n2\n3,NA\n"
    var buf = _bytes(text)
    var cells = scan_csv_phase1_into_cells[Rfc4180](
        Span(buf), UInt8(ord(",")), UInt8(ord("\""))
    )
    assert_equal(cells.num_cells_in_row(2), 1, "row `2` is short")
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(Span(buf), cells, 1, 1, dtype, 3, opts)
    var what = String(dtype) + " missing cell after " + valid
    assert_true(col.arrow_type == dtype, what)
    assert_equal(col.length(), 3, what)
    assert_false(col.is_null_at(0), what)
    assert_equal(_value(col, 0), expected, what)
    assert_true(col.is_null_at(1), "missing cell is null: " + what)
    assert_true(col.is_null_at(2), "NA after it is null: " + what)
    assert_equal(col.null_count(), 2, "null count: " + what)


def _check(
    dtype: ArrowType, valid: String, expected: Int, invalid: String
) raises:
    _check_reader(dtype, valid, expected, invalid)
    _check_missing_cell(dtype, valid, expected)


# --- integers ----------------------------------------------------------------


def test_unsigned() raises:
    _check(ArrowType.UINT8, "255", 255, "-1")
    _check(ArrowType.UINT16, "65535", 65535, "65536")
    _check(ArrowType.UINT32, "4294967295", 4294967295, "+1")
    _check(ArrowType.UINT64, "4294967296", 4294967296, "18446744073709551616")


def test_narrow_signed() raises:
    _check(ArrowType.INT8, "-128", -128, "128")
    _check(ArrowType.INT16, "-32768", -32768, "32768")
    _check(ArrowType.INT32, "-2147483648", -2147483648, "2147483648")


# --- float32 -----------------------------------------------------------------


def test_float32() raises:
    # 1e39 is above Float32 max: refused, not stored as inf.
    _check(ArrowType.FLOAT32, "-2", -2, "1e39")


def test_float32_decimal_separator() raises:
    """S: `1,5` with `,` as the decimal separator (and `;` as the delimiter)
    is 1.5; with the default separator it is a parse failure."""
    var buf = _bytes(String("a;b\r\n1,5;1.5\r\n"))
    var opts = CsvReadOptions()
    opts.delimiter = UInt8(ord(";"))
    opts.decimal_separator = UInt8(ord(","))
    opts.declared_column_types.append(ArrowType.FLOAT32)
    opts.declared_column_types.append(ArrowType.FLOAT32)
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    var a = rb.column_at(0).as_primitive[DType.float32]()
    assert_false(a.is_null(0))
    assert_equal(Float64(a.get(0)), 1.5)
    assert_true(rb.column_at(1).is_null_at(0), "`1.5` under `,` separator")


# --- date64 ------------------------------------------------------------------


def test_date64() raises:
    # 2026-09-01 is day 20697 of the epoch. 10-byte date: SIMD path.
    # 2026-09-31 passes the SIMD shape gate, fails its day check (September
    # has 30 days), and fails the scalar parser.
    _check(ArrowType.DATE64, "2026-09-01", 1788220800000, "2026-09-31")
    # Datetime form: the SIMD path declines it, the scalar parser reads it.
    _check(ArrowType.DATE64, "2026-09-01T00:00:01.5Z", 1788220801500, "2026-09-01T")
    _check(ArrowType.DATE64, "2026-09-01 23:59:59", 1788307199000, "2026-09-01X23:59:59")


# --- timestamps --------------------------------------------------------------


def test_timestamps() raises:
    # Seconds: a fraction is refused (it would be lost).
    # 2026-09-01 is day 20697 of the epoch.
    _check(ArrowType.TIMESTAMP_S, "2026-09-02 00:00:01", 1788307201, "2026-09-02 00:00:01.5")
    _check(ArrowType.TIMESTAMP_MS, "2026-09-01T00:00:00.123Z", 1788220800123, "2026-09-01T00:00:00.1234")
    _check(ArrowType.TIMESTAMP_US, "2026-09-01T23:59:59.999999", 1788307199999999, "2026-09-01T23:59:59.9999999")
    # Nanoseconds: 2262-04-12 is past the last day Int64 nanoseconds reach.
    _check(ArrowType.TIMESTAMP_NS, "2026-09-01T00:00:00.000000001", 1788220800000000001, "2262-04-12T00:00:00")


# --- times -------------------------------------------------------------------


def test_times() raises:
    _check(ArrowType.TIME32_S, "23:59:59", 86399, "24:00:00")
    _check(ArrowType.TIME32_MS, "00:00:01.5", 1500, "00:00:01.")
    _check(ArrowType.TIME64_US, "12:00:00.000001", 43200000001, "12:00")
    _check(ArrowType.TIME64_NS, "00:00:00.999999999", 999999999, "00:60:00")


# --- durations ---------------------------------------------------------------


def test_durations() raises:
    # ISO 8601 form and plain seconds.
    _check(ArrowType.DURATION_S, "P1DT1H", 90000, "PT5")
    _check(ArrowType.DURATION_MS, "1.5", 1500, "P")
    _check(ArrowType.DURATION_US, "-PT1S", -1000000, "abc")
    _check(ArrowType.DURATION_NS, "PT0.000000001S", 1, "P1H")


# --- decimal128 --------------------------------------------------------------


def test_decimal128() raises:
    # Default (precision 18, scale 2): `-1.5` is mantissa -150; three
    # fraction digits exceed the scale.
    _check(ArrowType.DECIMAL128, "-1.5", -150, "1.234")
    _check(ArrowType.DECIMAL128, "12", 1200, "1.2.3")


def test_decimal128_sign_extension() raises:
    """D: the high word is -1 exactly when the mantissa is negative."""
    var buf = _bytes(String("v\r\n-0.01\r\n-0.00\r\n0.01\r\n"))
    var rb = read_csv_bytes_to_batch[Rfc4180](
        Span(buf), _options(ArrowType.DECIMAL128)
    )
    var d = rb.column_at(0).as_decimal128()
    assert_equal(Int(d.get_low(0)), -1)
    assert_equal(Int(d.get_high(0)), -1, "-0.01 sign-extends")
    assert_equal(Int(d.get_low(1)), 0)
    assert_equal(Int(d.get_high(1)), 0, "-0.00 is zero, high word 0")
    assert_equal(Int(d.get_low(2)), 1)
    assert_equal(Int(d.get_high(2)), 0)
    assert_equal(d.precision, 18)
    assert_equal(d.scale, 2)


# --- unsupported -------------------------------------------------------------


def test_unsupported_declared_type_refused() raises:
    """U: TIMESTAMP (the unit-less tag) has no builder; the read is refused
    and the message names the column and the type."""
    var buf = _bytes(String("a,b\r\n1,2026-09-01T00:00:00\r\n"))
    var opts = CsvReadOptions()
    opts.declared_column_types.append(ArrowType.INT64)
    opts.declared_column_types.append(ArrowType.TIMESTAMP)
    var msg = String("")
    try:
        _ = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    except e:
        msg = String(e)
    assert_true(
        "unsupported ArrowType for column 1 " in msg,
        "refusal names column 1: " + msg,
    )
    assert_true(
        "got " + String(ArrowType.TIMESTAMP) in msg, "names the type: " + msg
    )


def main() raises:
    test_unsigned()
    test_narrow_signed()
    test_float32()
    test_float32_decimal_separator()
    test_date64()
    test_timestamps()
    test_times()
    test_durations()
    test_decimal128()
    test_decimal128_sign_extension()
    test_unsupported_declared_type_refused()
    print("test_csv_typed_column_builders: 11/11 PASS")
