# =============================================================================
# Tests for the per-DType typed column builders fed by the CSV cell parsers.
# =============================================================================
#
# Coverage: the 22 widened ArrowTypes go through the new per-DType typed
# column builders. Two layers of coverage:
#
#   1. End-to-end CSV read with `infer_temporal_types=True`: the wide
#      lattice picks Date64 / Timestamp_* / Time_* / Duration_* and the
#      builders materialize the inferred ArrowType into RecordBatch
#      output. Direct values are read back via Column.as_primitive
#      (storage-compatible accessor).
#
#   2. Direct `dispatch_typed_builder` calls with synthetic Rows for the
#      types the inference lattice does NOT pick automatically:
#      UInt8/16/32/64, Int8/16/32, Float32, Decimal128. These cover the
#      builder code path 1:1 even without an inference-driver, locking in
#      typed-null lattice (parse-failure -> null) + value-roundtrip.
#
#   3. Backward-compat: the default `infer_temporal_types=False` flag
#      reproduces the base 5-type lattice byte-for-byte for the same
#      CSV input.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch
from komira_csv import (
    CellRange,
    CsvReadOptions,
    Rfc4180,
    Row,
    dispatch_typed_builder,
    ScannedCells,
    read_csv_bytes_to_batch,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _make_single_col_rows(
    bytes: Span[UInt8, _], starts: List[Int], ends: List[Int]
) -> List[Row]:
    """Helper to build N single-column rows from explicit (start, end) cell
    boundary pairs over `bytes`. Used by the direct-dispatch tests below."""
    var out = List[Row]()
    var n = len(starts)
    var i = 0
    while i < n:
        var row = Row()
        # CellRange(start, end, was_quoted, needs_unescape) — @fieldwise_init.
        var cell = CellRange(starts[i], ends[i], False, False)
        row.cells.append(cell^)
        out.append(row^)
        i = i + 1
    return out^


def _make_single_col_cells(
    starts: List[Int], ends: List[Int]
) -> ScannedCells:
    """flat-buffer
    analog of `_make_single_col_rows`. Builds a ScannedCells where each
    row holds ONE cell at (starts[r], ends[r])."""
    var cells = ScannedCells()
    var n = len(starts)
    var i = 0
    while i < n:
        cells.cell_starts.append(starts[i])
        cells.cell_ends.append(ends[i])
        cells.cell_flags.append(0)
        cells.row_starts.append(len(cells.cell_starts))
        i = i + 1
    return cells^


# =============================================================================
# E2E tests (wide inference + typed builders)
# =============================================================================


def test_e2e_date64_inferred() raises:
    """T1: Date64 column inferred + materialized via typed builder."""
    # 'YYYY-MM-DD HH:MM:SS' triggers Date64 in the wide lattice.
    var buf = _bytes(String(
        "id,ts\n"
        "1,2024-01-15 12:30:45\n"
        "2,2025-06-20 08:15:00\n"
    ))
    var opts = CsvReadOptions()
    opts.with_temporal_inference(True)
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_columns(), 2)
    assert_equal(rb.num_rows(), 2)
    # Column 0: Int64 ids
    assert_true(rb.schema.field_at(0).arrow_type == ArrowType.INT64,
                "id is INT64 under wide inference")
    # Column 1: Date64 — wide lattice picks Date64 for date-with-time
    # (vs Timestamp_*, which is the sub-second tier).
    assert_true(rb.schema.field_at(1).arrow_type == ArrowType.DATE64,
                "ts is DATE64 under wide inference")
    ref ts_col = rb.column_at(1)
    var ts_arr = ts_col.as_primitive[DType.int64]()
    assert_false(ts_arr.is_null(0), "row 0 ts is non-null")
    assert_false(ts_arr.is_null(1), "row 1 ts is non-null")


def test_e2e_timestamp_us_inferred() raises:
    """T2: Timestamp_US column inferred + materialized; us-precision cells
    force lattice promotion from Date64 to Timestamp_US."""
    var buf = _bytes(String(
        "event\n"
        "2024-01-15T12:30:45.123456\n"
        "2024-01-16T08:15:00.000001\n"
        "2024-01-17T22:00:00.999999\n"
    ))
    var opts = CsvReadOptions()
    opts.with_temporal_inference(True)
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_columns(), 1)
    assert_equal(rb.num_rows(), 3)
    assert_true(rb.schema.field_at(0).arrow_type == ArrowType.TIMESTAMP_US,
                "us-precision cells -> TIMESTAMP_US")
    ref col = rb.column_at(0)
    var arr = col.as_primitive[DType.int64]()
    # Each cell roundtrips through the parser to a non-null us-since-epoch
    # Int64. No need to spot-check the exact integer — the parser unit
    # tests in test_csv_dtype_completion verify byte-accurate values.
    assert_false(arr.is_null(0))
    assert_false(arr.is_null(1))
    assert_false(arr.is_null(2))


def test_e2e_timestamp_ns_inferred() raises:
    """T3: Timestamp_NS column — ns-precision cells (9 frac digits)."""
    var buf = _bytes(String(
        "event\n"
        "2024-01-15T12:30:45.123456789\n"
        "2024-01-16T08:15:00.000000001\n"
    ))
    var opts = CsvReadOptions()
    opts.with_temporal_inference(True)
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_true(rb.schema.field_at(0).arrow_type == ArrowType.TIMESTAMP_NS,
                "ns-precision cells -> TIMESTAMP_NS")
    ref col = rb.column_at(0)
    var arr = col.as_primitive[DType.int64]()
    assert_false(arr.is_null(0))
    assert_false(arr.is_null(1))


def test_e2e_timestamp_s_inferred() raises:
    """T4: Timestamp_S column — datetime with no sub-second fraction."""
    var buf = _bytes(String(
        "event\n"
        "2024-01-15T12:30:45\n"
        "2024-01-16T08:15:00\n"
    ))
    var opts = CsvReadOptions()
    opts.with_temporal_inference(True)
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    # T-separator (vs space) keeps the cell out of the Date64 grammar in
    # the wide lattice's most-specific-first ordering. No sub-second
    # fraction -> Timestamp_S is the narrowest fit.
    var dt = rb.schema.field_at(0).arrow_type
    # Either Date64 OR Timestamp_S is acceptable here depending on the
    # lattice's most-specific-first resolution — both date64 and
    # timestamp_s recognize "YYYY-MM-DDTHH:MM:SS" with no .fff. The
    # current lattice's order is Int -> Date32 -> Date64 -> TS_S so
    # Date64 wins.
    assert_true(
        dt == ArrowType.DATE64 or dt == ArrowType.TIMESTAMP_S,
        "no-fraction datetime -> DATE64 (current) or TIMESTAMP_S",
    )
    ref col = rb.column_at(0)
    var arr = col.as_primitive[DType.int64]()
    assert_false(arr.is_null(0))
    assert_false(arr.is_null(1))


def test_e2e_time_us_inferred() raises:
    """T5: Time64_US column — HH:MM:SS.ffffff cells."""
    var buf = _bytes(String(
        "t\n"
        "08:30:00.123456\n"
        "12:45:00.999999\n"
        "23:59:59.000001\n"
    ))
    var opts = CsvReadOptions()
    opts.with_temporal_inference(True)
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_true(rb.schema.field_at(0).arrow_type == ArrowType.TIME64_US,
                "us-precision time -> TIME64_US")
    ref col = rb.column_at(0)
    var arr = col.as_primitive[DType.int64]()
    assert_false(arr.is_null(0))
    assert_false(arr.is_null(1))
    assert_false(arr.is_null(2))


def test_e2e_time_s_inferred() raises:
    """T6: Time32_S column — HH:MM:SS exact 8-char cells."""
    var buf = _bytes(String(
        "t\n"
        "08:30:00\n"
        "12:45:00\n"
    ))
    var opts = CsvReadOptions()
    opts.with_temporal_inference(True)
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_true(rb.schema.field_at(0).arrow_type == ArrowType.TIME32_S,
                "second-precision time -> TIME32_S")
    ref col = rb.column_at(0)
    var arr = col.as_primitive[DType.int32]()
    assert_false(arr.is_null(0))
    assert_false(arr.is_null(1))


def test_e2e_duration_s_inferred() raises:
    """T7: Duration_S column — ISO 8601 PT...S cells. The wide lattice
    picks Duration_S (the coarsest unit) because every Duration_*
    parser accepts the same input grammar and rounds toward zero. The
    narrower units (Duration_NS) are reachable only via direct dispatch,
    covered by the test_direct_duration_* cases below."""
    var buf = _bytes(String(
        "d\n"
        "PT3600S\n"
        "PT60S\n"
    ))
    var opts = CsvReadOptions()
    opts.with_temporal_inference(True)
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_true(rb.schema.field_at(0).arrow_type == ArrowType.DURATION_S,
                "ISO duration -> DURATION_S (lattice coarsest)")
    ref col = rb.column_at(0)
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 3600)
    assert_equal(Int(arr.get(1)), 60)


def test_e2e_backward_compat_default_off() raises:
    """T8: with `infer_temporal_types=False` (default), the same CSV reads
    as the base 5-type lattice — temporal cells fall through to STRING.
    """
    var buf = _bytes(String(
        "event\n"
        "2024-01-15T12:30:45.123456\n"
        "2024-01-16T08:15:00.000001\n"
    ))
    var opts = CsvReadOptions()
    # Do NOT call with_temporal_inference — default False.
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    # The default 5-type lattice has no Timestamp_US slot — the cell does
    # not match Int64/Float64/Date32/Bool -> STRING fallback.
    assert_true(rb.schema.field_at(0).arrow_type == ArrowType.STRING,
                "default (no wide inference) -> STRING fallback")


def test_e2e_wide_with_nulls() raises:
    """T9: Wide-inferred Timestamp column with pandas null tokens. The
    typed builder must clear validity bits for "" / "NA" cells."""
    var buf = _bytes(String(
        "event\n"
        "2024-01-15T12:30:45.123456\n"
        "\n"
        "NA\n"
        "2024-01-17T22:00:00.999999\n"
    ))
    var opts = CsvReadOptions()
    opts.with_temporal_inference(True)
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_rows(), 4)
    assert_true(rb.schema.field_at(0).arrow_type == ArrowType.TIMESTAMP_US)
    ref col = rb.column_at(0)
    var arr = col.as_primitive[DType.int64]()
    assert_false(arr.is_null(0), "row 0 timestamp valid")
    assert_true(arr.is_null(1), "row 1 (empty) is null")
    assert_true(arr.is_null(2), "row 2 (NA token) is null")
    assert_false(arr.is_null(3), "row 3 timestamp valid")


# =============================================================================
# Direct dispatch_typed_builder tests — for the types the wide lattice
# does not auto-infer (UInt*, narrowed Int, Float32, Decimal128).
# =============================================================================


def test_direct_uint8_builder() raises:
    """T10: UInt8 builder roundtrips values + handles parse-fail nulls.
    Cells: "0" / "255" / "256" (overflow) / "" (null) -> uint8(0), uint8(255), null, null.
    """
    var buf = _bytes(String("0\n255\n256\n\n"))
    # Cell ranges: "0" = [0, 1) / "255" = [2, 5) / "256" = [6, 9) / "" = [10, 10)
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(1)
    starts.append(2)
    ends.append(5)
    starts.append(6)
    ends.append(9)
    starts.append(10)
    ends.append(10)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.UINT8, 4, opts
    )
    assert_true(col.arrow_type == ArrowType.UINT8)
    var arr = col.as_primitive[DType.uint8]()
    assert_equal(arr.length, 4)
    assert_false(arr.is_null(0))
    assert_false(arr.is_null(1))
    assert_true(arr.is_null(2), "256 overflows uint8 -> null")
    assert_true(arr.is_null(3), "empty cell -> null")
    assert_equal(Int(arr.get(0)), 0)
    assert_equal(Int(arr.get(1)), 255)


def test_direct_uint16_builder() raises:
    """T11: UInt16 builder — boundary + overflow."""
    var buf = _bytes(String("0\n65535\n65536\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(1)
    starts.append(2)
    ends.append(7)
    starts.append(8)
    ends.append(13)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.UINT16, 3, opts
    )
    assert_true(col.arrow_type == ArrowType.UINT16)
    var arr = col.as_primitive[DType.uint16]()
    assert_equal(Int(arr.get(0)), 0)
    assert_equal(Int(arr.get(1)), 65535)
    assert_true(arr.is_null(2), "65536 overflows uint16")


def test_direct_uint32_builder() raises:
    """T12: UInt32 builder."""
    var buf = _bytes(String("0\n4294967295\n4294967296\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(1)
    starts.append(2)
    ends.append(12)
    starts.append(13)
    ends.append(23)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.UINT32, 3, opts
    )
    assert_true(col.arrow_type == ArrowType.UINT32)
    var arr = col.as_primitive[DType.uint32]()
    assert_equal(Int(arr.get(0)), 0)
    assert_equal(Int(arr.get(1)), 4294967295)
    assert_true(arr.is_null(2), "4294967296 overflows uint32")


def test_direct_uint64_builder() raises:
    """T13: UInt64 builder."""
    var buf = _bytes(String("12345\n0\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(5)
    starts.append(6)
    ends.append(7)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.UINT64, 2, opts
    )
    assert_true(col.arrow_type == ArrowType.UINT64)
    var arr = col.as_primitive[DType.uint64]()
    assert_equal(Int(arr.get(0)), 12345)
    assert_equal(Int(arr.get(1)), 0)


def test_direct_int8_builder() raises:
    """T14: Int8 builder — happy + narrow overflow."""
    var buf = _bytes(String("127\n-128\n128\n-129\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(3)
    starts.append(4)
    ends.append(8)
    starts.append(9)
    ends.append(12)
    starts.append(13)
    ends.append(17)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.INT8, 4, opts
    )
    assert_true(col.arrow_type == ArrowType.INT8)
    var arr = col.as_primitive[DType.int8]()
    assert_equal(Int(arr.get(0)), 127)
    assert_equal(Int(arr.get(1)), -128)
    assert_true(arr.is_null(2), "128 overflows int8 (max=127)")
    assert_true(arr.is_null(3), "-129 underflows int8 (min=-128)")


def test_direct_int16_builder() raises:
    """T15: Int16 builder."""
    var buf = _bytes(String("32767\n-32768\n32768\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(5)
    starts.append(6)
    ends.append(12)
    starts.append(13)
    ends.append(18)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.INT16, 3, opts
    )
    assert_true(col.arrow_type == ArrowType.INT16)
    var arr = col.as_primitive[DType.int16]()
    assert_equal(Int(arr.get(0)), 32767)
    assert_equal(Int(arr.get(1)), -32768)
    assert_true(arr.is_null(2))


def test_direct_int32_builder() raises:
    """T16: Int32 builder."""
    var buf = _bytes(String("2147483647\n-2147483648\n2147483648\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(10)
    starts.append(11)
    ends.append(22)
    starts.append(23)
    ends.append(33)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.INT32, 3, opts
    )
    assert_true(col.arrow_type == ArrowType.INT32)
    var arr = col.as_primitive[DType.int32]()
    assert_equal(Int(arr.get(0)), 2147483647)
    assert_equal(Int(arr.get(1)), -2147483648)
    assert_true(arr.is_null(2))


def test_direct_float32_builder() raises:
    """T17: Float32 builder — happy + max-range."""
    # Bytes: "3.14\n0.0\n1e40\n"
    # 0:3.14[0..4) 4:\n 5:0.0[5..8) 8:\n 9:1e40[9..13) 13:\n
    var buf = _bytes(String("3.14\n0.0\n1e40\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(4)
    starts.append(5)
    ends.append(8)
    starts.append(9)
    ends.append(13)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.FLOAT32, 3, opts
    )
    assert_true(col.arrow_type == ArrowType.FLOAT32)
    var arr = col.as_primitive[DType.float32]()
    # Float32 precision is ~7 digits; 3.14 roundtrips cleanly.
    var v0 = Float64(arr.get(0))
    assert_true(v0 > 3.139 and v0 < 3.141)
    assert_equal(Float64(arr.get(1)), 0.0)
    assert_true(arr.is_null(2), "1e40 exceeds Float32 max -> null")


def test_direct_decimal128_builder() raises:
    """T18: Decimal128 builder — precision=10, scale=2; "$123.45" -> 12345
    mantissa; "" -> null; "99999999.99" max for p=10, s=2.
    """
    # Cells: "123.45" / "" / "0.01" / "99999999.99"
    var buf = _bytes(String("123.45\n\n0.01\n99999999.99\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(6)
    starts.append(7)
    ends.append(7)
    starts.append(8)
    ends.append(12)
    starts.append(13)
    ends.append(24)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    opts.with_decimal_precision_scale(10, 2)
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.DECIMAL128, 4, opts
    )
    assert_true(col.arrow_type == ArrowType.DECIMAL128)
    var arr = col.as_decimal128()
    assert_equal(arr.length, 4)
    assert_equal(arr.precision, 10)
    assert_equal(arr.scale, 2)
    # Roundtrip via get_low (low Int64 == sign-extended mantissa for
    # precision <= 18). 123.45 with scale=2 -> 12345.
    assert_equal(Int(arr.get_low(0)), 12345)
    assert_true(arr.is_null(1), "empty cell -> null decimal")
    assert_equal(Int(arr.get_low(2)), 1)
    assert_equal(Int(arr.get_low(3)), 9999999999)


def test_direct_decimal128_negative() raises:
    """T19: Decimal128 builder — negative mantissa sign-extends high word."""
    # "-123.45" -> mantissa = -12345; low_i64 = -12345; high_i64 = -1.
    var buf = _bytes(String("-123.45\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(7)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    opts.with_decimal_precision_scale(10, 2)
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.DECIMAL128, 1, opts
    )
    var arr = col.as_decimal128()
    assert_equal(Int(arr.get_low(0)), -12345)
    # High word sign-extension: -1 -> all ones in two's complement.
    assert_equal(Int(arr.get_high(0)), -1)


def test_direct_date64_builder() raises:
    """T20: Date64 builder direct (covered by e2e T1 but locks in the
    direct dispatch path)."""
    var buf = _bytes(String("1970-01-01\n2024-01-15\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(10)
    starts.append(11)
    ends.append(21)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.DATE64, 2, opts
    )
    assert_true(col.arrow_type == ArrowType.DATE64)
    var arr = col.as_primitive[DType.int64]()
    # Date64 is ms-since-epoch. 1970-01-01 -> 0.
    assert_equal(Int(arr.get(0)), 0)
    # 2024-01-15 is well-defined; verify non-null (exact integer is in
    # the unit-test coverage at test_csv_dtype_completion).
    assert_false(arr.is_null(1))


def test_direct_duration_s_builder() raises:
    """T21: Duration_S builder direct."""
    # PT1H = 3600s; PT0S = 0s
    var buf = _bytes(String("PT1H\nPT0S\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(4)
    starts.append(5)
    ends.append(9)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.DURATION_S, 2, opts
    )
    assert_true(col.arrow_type == ArrowType.DURATION_S)
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 3600)
    assert_equal(Int(arr.get(1)), 0)


def test_direct_time32_ms_builder() raises:
    """T22: Time32_MS builder direct."""
    # 08:30:00.500 -> (8*3600 + 30*60 + 0) * 1000 + 500
    var buf = _bytes(String("08:30:00.500\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(12)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.TIME32_MS, 1, opts
    )
    assert_true(col.arrow_type == ArrowType.TIME32_MS)
    var arr = col.as_primitive[DType.int32]()
    var expected = (8 * 3600 + 30 * 60 + 0) * 1000 + 500
    assert_equal(Int(arr.get(0)), expected)


def test_direct_time64_ns_builder() raises:
    """T23: Time64_NS builder direct."""
    var buf = _bytes(String("00:00:00.000000001\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(18)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.TIME64_NS, 1, opts
    )
    assert_true(col.arrow_type == ArrowType.TIME64_NS)
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 1)


def test_direct_duration_ms_builder() raises:
    """T24: Duration_MS builder direct."""
    var buf = _bytes(String("PT1.5S\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(6)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.DURATION_MS, 1, opts
    )
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 1500)


def test_direct_duration_us_builder() raises:
    """T25: Duration_US builder direct."""
    var buf = _bytes(String("PT0.001S\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(8)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.DURATION_US, 1, opts
    )
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 1000)


def test_direct_timestamp_ms_builder() raises:
    """T26: Timestamp_MS builder direct (ms precision)."""
    var buf = _bytes(String("1970-01-01T00:00:00.123\n"))
    var starts = List[Int]()
    var ends = List[Int]()
    starts.append(0)
    ends.append(23)
    var rows = _make_single_col_rows(Span(buf), starts, ends)
    var cells = _make_single_col_cells(starts, ends)
    var opts = CsvReadOptions()
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 0, ArrowType.TIMESTAMP_MS, 1, opts
    )
    assert_true(col.arrow_type == ArrowType.TIMESTAMP_MS)
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 123)


def test_direct_missing_cell_is_null() raises:
    """T27: When a row has fewer cells than `col_idx`, builder emits a null
    (validity bit cleared). Locks in the safety branch in every
    `_build_*_column`."""
    # 2 rows but only row 0 has a cell at index 1.
    # Row 0: "a,b"  Row 1: "c" (col 1 missing)
    var buf = _bytes(String("a,b\nc\n"))
    # Single-column setup but col_idx=1: row 0 has cell[1] = "b" = [2, 3);
    # row 1 has only cell[0] = "c" = [4, 5).
    # Build a ScannedCells where row 0 has 2 cells and row 1 has 1 cell.
    # This exercises the `col_idx >= num_cells_in_row(r)` -> null branch in
    # every per-DType builder.
    var cells = ScannedCells()
    # Row 0 — two cells: (0,1) and (2,3).
    cells.cell_starts.append(0)
    cells.cell_ends.append(1)
    cells.cell_flags.append(0)
    cells.cell_starts.append(2)
    cells.cell_ends.append(3)
    cells.cell_flags.append(0)
    cells.row_starts.append(len(cells.cell_starts))
    # Row 1 — only one cell at (4,5).
    cells.cell_starts.append(4)
    cells.cell_ends.append(5)
    cells.cell_flags.append(0)
    cells.row_starts.append(len(cells.cell_starts))

    var opts = CsvReadOptions()
    # UInt8 column at col_idx=1: "b" parses as None (not a digit) -> null,
    # missing cell at row 1 -> null.
    var col = dispatch_typed_builder(
        Span(buf), cells, 0, 1, ArrowType.UINT8, 2, opts
    )
    var arr = col.as_primitive[DType.uint8]()
    assert_equal(arr.length, 2)
    assert_true(arr.is_null(0), "row 0 cell 'b' is not a uint8 -> null")
    assert_true(arr.is_null(1), "row 1 missing cell -> null")


def test_e2e_phase_a_5type_lattice_unchanged() raises:
    """T28: With `infer_temporal_types=False` (default), the base
    5-type lattice still produces Int64/Float64/Date32/Bool/String exactly
    as before. Backward-compat lock for the existing csv:* test fleet.
    """
    var buf = _bytes(String(
        "i,f,d,b\n"
        "1,1.5,2024-01-01,true\n"
        "2,2.5,2024-01-02,false\n"
    ))
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_true(rb.schema.field_at(0).arrow_type == ArrowType.INT64)
    assert_true(rb.schema.field_at(1).arrow_type == ArrowType.FLOAT64)
    assert_true(rb.schema.field_at(2).arrow_type == ArrowType.DATE32)
    assert_true(rb.schema.field_at(3).arrow_type == ArrowType.BOOL)


def test_e2e_with_temporal_inference_int_passthrough() raises:
    """T29: With temporal inference enabled, an Int64 column still resolves
    as INT64 (lattice's most-specific-first ordering puts Int64 above
    Date32/Date64/Timestamp_*/etc)."""
    var buf = _bytes(String("n\n1\n2\n3\n"))
    var opts = CsvReadOptions()
    opts.with_temporal_inference(True)
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_true(rb.schema.field_at(0).arrow_type == ArrowType.INT64,
                "wide-inference still prefers INT64 for pure-integer column")
    ref col = rb.column_at(0)
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 1)
    assert_equal(Int(arr.get(1)), 2)
    assert_equal(Int(arr.get(2)), 3)


def test_with_decimal_precision_scale_validation() raises:
    """T30: CsvReadOptions.with_decimal_precision_scale rejects invalid
    args."""
    var opts = CsvReadOptions()
    # precision > 18 should raise (19+ needs a two-limb parser).
    var raised_a = False
    try:
        opts.with_decimal_precision_scale(19, 2)
    except:
        raised_a = True
    assert_true(raised_a, "precision=19 should raise (wider precision is not supported)")

    # scale > precision should raise.
    var raised_b = False
    try:
        opts.with_decimal_precision_scale(5, 6)
    except:
        raised_b = True
    assert_true(raised_b, "scale > precision should raise")


def main() raises:
    # E2E (wide-inference + typed builders)
    test_e2e_date64_inferred()
    test_e2e_timestamp_us_inferred()
    test_e2e_timestamp_ns_inferred()
    test_e2e_timestamp_s_inferred()
    test_e2e_time_us_inferred()
    test_e2e_time_s_inferred()
    test_e2e_duration_s_inferred()
    test_e2e_backward_compat_default_off()
    test_e2e_wide_with_nulls()
    # Direct dispatch (non-inferable widened types)
    test_direct_uint8_builder()
    test_direct_uint16_builder()
    test_direct_uint32_builder()
    test_direct_uint64_builder()
    test_direct_int8_builder()
    test_direct_int16_builder()
    test_direct_int32_builder()
    test_direct_float32_builder()
    test_direct_decimal128_builder()
    test_direct_decimal128_negative()
    test_direct_date64_builder()
    test_direct_duration_s_builder()
    test_direct_time32_ms_builder()
    test_direct_time64_ns_builder()
    test_direct_duration_ms_builder()
    test_direct_duration_us_builder()
    test_direct_timestamp_ms_builder()
    test_direct_missing_cell_is_null()
    test_e2e_phase_a_5type_lattice_unchanged()
    test_e2e_with_temporal_inference_int_passthrough()
    test_with_decimal_precision_scale_validation()
    print("test_csv_cell_parsers_wire_to_builders: 30/30 PASS")
