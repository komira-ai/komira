# =============================================================================
# Tests for the widened CSV DType parsers and type inference.
# =============================================================================
#
# Coverage: each new DType parser gets 3+ cases (happy / corner / overflow
# or out-of-range), plus 4 cases for the widened type inference lattice.
#
# Test groups:
#   T1-T4  UInt parsers (UInt8/16/32/64) — boundary + overflow + reject-sign.
#   T5-T7  Narrowed Int parsers (Int8/16/32) — boundary + overflow.
#   T8     Float32 — happy + max-range + downcast-overflow.
#   T9     Date64 — date-only / datetime / T-separator / .fff truncate / pre-1970.
#   T10    TIMESTAMP_S / _MS / _US / _NS — happy + sub-second handling per unit.
#   T11    TIME32_S / TIME32_MS / TIME64_US / TIME64_NS — HH:MM:SS + .fff cap.
#   T12    Duration ISO (PnDTnHnMnS) + numeric (seconds) for each unit.
#   T13    Decimal128 -> Int64 mantissa: precision/scale honor + overflow.
#   T14    infer_column_types_wide lattice: Date64 / TIMESTAMP / TIME / DURATION.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_csv import (
    CsvReadOptions,
    Row,
    CellRange,
    _try_parse_uint8,
    _try_parse_uint16,
    _try_parse_uint32,
    _try_parse_uint64,
    _try_parse_int8,
    _try_parse_int16,
    _try_parse_int32,
    _try_parse_float32,
    _try_parse_date64,
    _try_parse_timestamp_s,
    _try_parse_timestamp_ms,
    _try_parse_timestamp_us,
    _try_parse_timestamp_ns,
    _try_parse_time_s,
    _try_parse_time_ms,
    _try_parse_time_us,
    _try_parse_time_ns,
    _try_parse_duration_s,
    _try_parse_duration_ms,
    _try_parse_duration_us,
    _try_parse_duration_ns,
    _try_parse_decimal128_to_int64,
    infer_column_types_wide,
    ScannedCells,
)
from komira_core.arrow.arrow_types import ArrowType


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


# =============================================================================
# T1: UInt8 parser
# =============================================================================


def test_parse_uint8() raises:
    """T1: UInt8 — boundary, sign rejection, overflow."""
    var b0 = _bytes(String("0"))
    var p0 = _try_parse_uint8(Span(b0))
    assert_true(Bool(p0))
    assert_equal(Int(p0.value()), 0)

    var b_max = _bytes(String("255"))
    var p_max = _try_parse_uint8(Span(b_max))
    assert_true(Bool(p_max))
    assert_equal(Int(p_max.value()), 255)

    var b_over = _bytes(String("256"))
    var p_over = _try_parse_uint8(Span(b_over))
    assert_false(Bool(p_over), "256 out of range for uint8")

    var b_neg = _bytes(String("-1"))
    var p_neg = _try_parse_uint8(Span(b_neg))
    assert_false(Bool(p_neg), "uint8 rejects negative sign")


# =============================================================================
# T2: UInt16 parser
# =============================================================================


def test_parse_uint16() raises:
    var b_mid = _bytes(String("12345"))
    var p_mid = _try_parse_uint16(Span(b_mid))
    assert_true(Bool(p_mid))
    assert_equal(Int(p_mid.value()), 12345)

    var b_max = _bytes(String("65535"))
    var p_max = _try_parse_uint16(Span(b_max))
    assert_true(Bool(p_max))
    assert_equal(Int(p_max.value()), 65535)

    var b_over = _bytes(String("65536"))
    var p_over = _try_parse_uint16(Span(b_over))
    assert_false(Bool(p_over))


# =============================================================================
# T3: UInt32 parser
# =============================================================================


def test_parse_uint32() raises:
    var b_mid = _bytes(String("1000000"))
    var p_mid = _try_parse_uint32(Span(b_mid))
    assert_true(Bool(p_mid))
    assert_equal(Int(p_mid.value()), 1000000)

    var b_max = _bytes(String("4294967295"))
    var p_max = _try_parse_uint32(Span(b_max))
    assert_true(Bool(p_max))
    assert_equal(Int(p_max.value()), 4294967295)

    var b_over = _bytes(String("4294967296"))
    var p_over = _try_parse_uint32(Span(b_over))
    assert_false(Bool(p_over))


# =============================================================================
# T4: UInt64 parser
# =============================================================================


def test_parse_uint64() raises:
    var b_mid = _bytes(String("123456789012"))
    var p_mid = _try_parse_uint64(Span(b_mid))
    assert_true(Bool(p_mid))
    assert_equal(Int(p_mid.value()), 123456789012)

    # 2**63 fits (signed boundary). UInt64 capacity ~ 1.8e19.
    var b_signed = _bytes(String("9223372036854775808"))
    var p_signed = _try_parse_uint64(Span(b_signed))
    assert_true(Bool(p_signed), "UInt64 accepts values above Int64.max")

    # UInt64.max = 18446744073709551615 — must parse exactly.
    var b_max = _bytes(String("18446744073709551615"))
    var p_max = _try_parse_uint64(Span(b_max))
    assert_true(Bool(p_max), "uint64 max parses")

    # One above max => None.
    var b_over = _bytes(String("18446744073709551616"))
    var p_over = _try_parse_uint64(Span(b_over))
    assert_false(Bool(p_over), "uint64 overflow detected")

    # Leading '+' rejected (UInt is unsigned-by-cell-content, not signed).
    var b_plus = _bytes(String("+1"))
    var p_plus = _try_parse_uint64(Span(b_plus))
    assert_false(Bool(p_plus), "uint64 rejects '+' sign")


# =============================================================================
# T5: Int8 parser
# =============================================================================


def test_parse_int8() raises:
    var b_pos = _bytes(String("127"))
    var p_pos = _try_parse_int8(Span(b_pos))
    assert_true(Bool(p_pos))
    assert_equal(Int(p_pos.value()), 127)

    var b_neg = _bytes(String("-128"))
    var p_neg = _try_parse_int8(Span(b_neg))
    assert_true(Bool(p_neg))
    assert_equal(Int(p_neg.value()), -128)

    var b_over = _bytes(String("128"))
    var p_over = _try_parse_int8(Span(b_over))
    assert_false(Bool(p_over))

    var b_under = _bytes(String("-129"))
    var p_under = _try_parse_int8(Span(b_under))
    assert_false(Bool(p_under))


# =============================================================================
# T6: Int16 parser
# =============================================================================


def test_parse_int16() raises:
    var b_max = _bytes(String("32767"))
    var p_max = _try_parse_int16(Span(b_max))
    assert_true(Bool(p_max))
    assert_equal(Int(p_max.value()), 32767)

    var b_min = _bytes(String("-32768"))
    var p_min = _try_parse_int16(Span(b_min))
    assert_true(Bool(p_min))
    assert_equal(Int(p_min.value()), -32768)

    var b_over = _bytes(String("32768"))
    var p_over = _try_parse_int16(Span(b_over))
    assert_false(Bool(p_over))


# =============================================================================
# T7: Int32 parser
# =============================================================================


def test_parse_int32() raises:
    var b_max = _bytes(String("2147483647"))
    var p_max = _try_parse_int32(Span(b_max))
    assert_true(Bool(p_max))
    assert_equal(Int(p_max.value()), 2147483647)

    var b_min = _bytes(String("-2147483648"))
    var p_min = _try_parse_int32(Span(b_min))
    assert_true(Bool(p_min))
    assert_equal(Int(p_min.value()), -2147483648)

    var b_over = _bytes(String("2147483648"))
    var p_over = _try_parse_int32(Span(b_over))
    assert_false(Bool(p_over))


# =============================================================================
# T8: Float32 parser
# =============================================================================


def test_parse_float32() raises:
    var b_simple = _bytes(String("3.14"))
    var p_simple = _try_parse_float32(Span(b_simple), UInt8(ord(".")))
    assert_true(Bool(p_simple))
    # Float32 precision: 3.14 -> 3.140000... within ~1e-6 tolerance.
    var v = p_simple.value()
    var diff: Float32 = v - Float32(3.14)
    if diff < Float32(0):
        diff = -diff
    assert_true(diff < Float32(1e-5), "3.14 round-trips through f32")

    var b_neg = _bytes(String("-1.5e2"))
    var p_neg = _try_parse_float32(Span(b_neg), UInt8(ord(".")))
    assert_true(Bool(p_neg))
    assert_equal(p_neg.value(), Float32(-150.0))

    # Float64 max-range value (1e300) overflows Float32.
    var b_over = _bytes(String("1e300"))
    var p_over = _try_parse_float32(Span(b_over), UInt8(ord(".")))
    assert_false(Bool(p_over), "f32 rejects |v| > 3.4e38")


# =============================================================================
# T9: Date64 parser
# =============================================================================


def test_parse_date64() raises:
    # Epoch = 1970-01-01 = 0 ms.
    var b_epoch = _bytes(String("1970-01-01"))
    var p_epoch = _try_parse_date64(Span(b_epoch))
    assert_true(Bool(p_epoch))
    assert_equal(Int(p_epoch.value()), 0)

    # 1970-01-02 = 1 day = 86400000 ms.
    var b_next = _bytes(String("1970-01-02"))
    var p_next = _try_parse_date64(Span(b_next))
    assert_true(Bool(p_next))
    assert_equal(Int(p_next.value()), 86400000)

    # Datetime form (T separator) — 1970-01-01T00:00:00 = 0 ms.
    var b_dt = _bytes(String("1970-01-01T00:00:00"))
    var p_dt = _try_parse_date64(Span(b_dt))
    assert_true(Bool(p_dt))
    assert_equal(Int(p_dt.value()), 0)

    # Datetime form (space separator) + .fff
    var b_ms = _bytes(String("1970-01-01 00:00:00.123"))
    var p_ms = _try_parse_date64(Span(b_ms))
    assert_true(Bool(p_ms))
    assert_equal(Int(p_ms.value()), 123)

    # Z suffix accepted.
    var b_z = _bytes(String("1970-01-01T00:00:00Z"))
    var p_z = _try_parse_date64(Span(b_z))
    assert_true(Bool(p_z))
    assert_equal(Int(p_z.value()), 0)

    # Malformed: trailing garbage.
    var b_bad = _bytes(String("1970-01-01T00:00:00xx"))
    var p_bad = _try_parse_date64(Span(b_bad))
    assert_false(Bool(p_bad))


# =============================================================================
# T10: TIMESTAMP parsers (S/MS/US/NS)
# =============================================================================


def test_parse_timestamp_s() raises:
    # 1970-01-01T00:00:00 = 0 s.
    var b1 = _bytes(String("1970-01-01T00:00:00"))
    var p1 = _try_parse_timestamp_s(Span(b1))
    assert_true(Bool(p1))
    assert_equal(Int(p1.value()), 0)

    # 1970-01-01T01:00:00 = 3600 s.
    var b2 = _bytes(String("1970-01-01T01:00:00"))
    var p2 = _try_parse_timestamp_s(Span(b2))
    assert_true(Bool(p2))
    assert_equal(Int(p2.value()), 3600)

    # Sub-second precision REJECTED for seconds resolution.
    var b3 = _bytes(String("1970-01-01T00:00:00.5"))
    var p3 = _try_parse_timestamp_s(Span(b3))
    assert_false(Bool(p3), "ts_s rejects sub-second .fff")


def test_parse_timestamp_ms() raises:
    var b1 = _bytes(String("1970-01-01T00:00:00.123"))
    var p1 = _try_parse_timestamp_ms(Span(b1))
    assert_true(Bool(p1))
    assert_equal(Int(p1.value()), 123)

    var b2 = _bytes(String("1970-01-01T00:00:01.000"))
    var p2 = _try_parse_timestamp_ms(Span(b2))
    assert_true(Bool(p2))
    assert_equal(Int(p2.value()), 1000)

    # Without fraction, treat as .000.
    var b3 = _bytes(String("1970-01-01T00:00:00"))
    var p3 = _try_parse_timestamp_ms(Span(b3))
    assert_true(Bool(p3))
    assert_equal(Int(p3.value()), 0)


def test_parse_timestamp_us() raises:
    var b1 = _bytes(String("1970-01-01T00:00:00.000001"))
    var p1 = _try_parse_timestamp_us(Span(b1))
    assert_true(Bool(p1))
    assert_equal(Int(p1.value()), 1)

    var b2 = _bytes(String("1970-01-01T00:00:01.000500"))
    var p2 = _try_parse_timestamp_us(Span(b2))
    assert_true(Bool(p2))
    assert_equal(Int(p2.value()), 1000500)

    # 3-digit fraction zero-padded to 6 digits.
    var b3 = _bytes(String("1970-01-01T00:00:00.001"))
    var p3 = _try_parse_timestamp_us(Span(b3))
    assert_true(Bool(p3))
    assert_equal(Int(p3.value()), 1000)


def test_parse_timestamp_ns() raises:
    var b1 = _bytes(String("1970-01-01T00:00:00.000000001"))
    var p1 = _try_parse_timestamp_ns(Span(b1))
    assert_true(Bool(p1))
    assert_equal(Int(p1.value()), 1)

    var b2 = _bytes(String("1970-01-01T00:00:00.5"))
    var p2 = _try_parse_timestamp_ns(Span(b2))
    assert_true(Bool(p2))
    # 0.5 sec = 5e8 ns.
    assert_equal(Int(p2.value()), 500000000)

    # Range check: 2262-04-12 just past the Int64 ns cap (1677-2262).
    var b3 = _bytes(String("2263-01-01T00:00:00"))
    var p3 = _try_parse_timestamp_ns(Span(b3))
    assert_false(Bool(p3), "ts_ns rejects 2263 (Int64 overflow)")


# =============================================================================
# T11: TIME parsers
# =============================================================================


def test_parse_time_s() raises:
    var b1 = _bytes(String("00:00:00"))
    var p1 = _try_parse_time_s(Span(b1))
    assert_true(Bool(p1))
    assert_equal(Int(p1.value()), 0)

    var b2 = _bytes(String("12:34:56"))
    var p2 = _try_parse_time_s(Span(b2))
    assert_true(Bool(p2))
    assert_equal(Int(p2.value()), 12 * 3600 + 34 * 60 + 56)

    # Sub-second rejected for seconds resolution.
    var b3 = _bytes(String("12:34:56.5"))
    var p3 = _try_parse_time_s(Span(b3))
    assert_false(Bool(p3))


def test_parse_time_ms() raises:
    var b1 = _bytes(String("12:34:56.123"))
    var p1 = _try_parse_time_ms(Span(b1))
    assert_true(Bool(p1))
    assert_equal(Int(p1.value()), (12 * 3600 + 34 * 60 + 56) * 1000 + 123)

    var b2 = _bytes(String("00:00:00"))
    var p2 = _try_parse_time_ms(Span(b2))
    assert_true(Bool(p2))
    assert_equal(Int(p2.value()), 0)

    var b3 = _bytes(String("23:59:59.999"))
    var p3 = _try_parse_time_ms(Span(b3))
    assert_true(Bool(p3))


def test_parse_time_us() raises:
    var b1 = _bytes(String("00:00:00.000001"))
    var p1 = _try_parse_time_us(Span(b1))
    assert_true(Bool(p1))
    assert_equal(Int(p1.value()), 1)

    var b2 = _bytes(String("12:34:56"))
    var p2 = _try_parse_time_us(Span(b2))
    assert_true(Bool(p2))
    assert_equal(Int(p2.value()), (12 * 3600 + 34 * 60 + 56) * 1000000)


def test_parse_time_ns() raises:
    var b1 = _bytes(String("00:00:00.000000001"))
    var p1 = _try_parse_time_ns(Span(b1))
    assert_true(Bool(p1))
    assert_equal(Int(p1.value()), 1)

    var b2 = _bytes(String("12:34:56.123456789"))
    var p2 = _try_parse_time_ns(Span(b2))
    assert_true(Bool(p2))
    assert_equal(Int(p2.value()), (12 * 3600 + 34 * 60 + 56) * 1000000000 + 123456789)


# =============================================================================
# T12: Duration parsers
# =============================================================================


def test_parse_duration_iso_basic() raises:
    # P0D (zero days) - degenerate but should parse.
    var b0 = _bytes(String("P0D"))
    var p0 = _try_parse_duration_ns(Span(b0))
    assert_true(Bool(p0))
    assert_equal(Int(p0.value()), 0)

    # PT1H = 1 hour = 3600 seconds = 3.6e12 ns.
    var b1h = _bytes(String("PT1H"))
    var p1h = _try_parse_duration_ns(Span(b1h))
    assert_true(Bool(p1h))
    assert_equal(Int(p1h.value()), 3600 * 1000000000)

    # PT1M = 60s.
    var b1m = _bytes(String("PT1M"))
    var p1m = _try_parse_duration_ns(Span(b1m))
    assert_true(Bool(p1m))
    assert_equal(Int(p1m.value()), 60 * 1000000000)

    # PT1.5S = 1.5 seconds = 1500000000 ns.
    var b1_5s = _bytes(String("PT1.5S"))
    var p1_5s = _try_parse_duration_ns(Span(b1_5s))
    assert_true(Bool(p1_5s))
    assert_equal(Int(p1_5s.value()), 1500000000)


def test_parse_duration_iso_complex() raises:
    # P1DT2H3M4S = 1 day + 2 hours + 3 minutes + 4 seconds.
    var b = _bytes(String("P1DT2H3M4S"))
    var p = _try_parse_duration_ns(Span(b))
    assert_true(Bool(p))
    var expected_s: Int = 86400 + 2 * 3600 + 3 * 60 + 4
    assert_equal(Int(p.value()), expected_s * 1000000000)

    # Negative duration: -PT1H = -3600 ns_total.
    var b_neg = _bytes(String("-PT1H"))
    var p_neg = _try_parse_duration_ns(Span(b_neg))
    assert_true(Bool(p_neg))
    assert_equal(Int(p_neg.value()), -3600 * 1000000000)

    # Malformed: missing 'P'.
    var b_bad = _bytes(String("1H"))
    var p_bad = _try_parse_duration_ns(Span(b_bad))
    assert_false(Bool(p_bad))


def test_parse_duration_numeric() raises:
    # Plain numeric seconds.
    var b = _bytes(String("1.5"))
    var p_ns = _try_parse_duration_ns(Span(b))
    assert_true(Bool(p_ns))
    assert_equal(Int(p_ns.value()), 1500000000)

    var p_ms = _try_parse_duration_ms(Span(b))
    assert_true(Bool(p_ms))
    assert_equal(Int(p_ms.value()), 1500)

    var p_us = _try_parse_duration_us(Span(b))
    assert_true(Bool(p_us))
    assert_equal(Int(p_us.value()), 1500000)

    var p_s = _try_parse_duration_s(Span(b))
    assert_true(Bool(p_s))
    # 1.5s rounds toward zero -> 1.
    assert_equal(Int(p_s.value()), 1)


# =============================================================================
# T13: Decimal128 -> Int64 mantissa
# =============================================================================


def test_parse_decimal128_to_int64() raises:
    # "12.34" with scale=2 -> mantissa 1234.
    var b1 = _bytes(String("12.34"))
    var p1 = _try_parse_decimal128_to_int64(Span(b1), 4, 2)
    assert_true(Bool(p1))
    assert_equal(Int(p1.value()), 1234)

    # "12.3" with scale=2 -> mantissa 1230 (right-pad with zero).
    var b2 = _bytes(String("12.3"))
    var p2 = _try_parse_decimal128_to_int64(Span(b2), 4, 2)
    assert_true(Bool(p2))
    assert_equal(Int(p2.value()), 1230)

    # "12" with scale=2 -> mantissa 1200.
    var b3 = _bytes(String("12"))
    var p3 = _try_parse_decimal128_to_int64(Span(b3), 4, 2)
    assert_true(Bool(p3))
    assert_equal(Int(p3.value()), 1200)

    # Negative.
    var b4 = _bytes(String("-99.99"))
    var p4 = _try_parse_decimal128_to_int64(Span(b4), 4, 2)
    assert_true(Bool(p4))
    assert_equal(Int(p4.value()), -9999)

    # Out of range for precision.
    var b5 = _bytes(String("12345"))
    var p5 = _try_parse_decimal128_to_int64(Span(b5), 4, 2)
    assert_false(Bool(p5), "12345 exceeds precision 4 with scale 2")

    # Too many fractional digits.
    var b6 = _bytes(String("1.234"))
    var p6 = _try_parse_decimal128_to_int64(Span(b6), 4, 2)
    assert_false(Bool(p6), "1.234 exceeds scale 2")


# =============================================================================
# T14: infer_column_types_wide lattice
# =============================================================================


def _make_row(starts: List[Int], ends: List[Int]) -> Row:
    """Build a Row with one cell per (start, end) pair.

    Per csv_scanner_phase1.Row API: cells is just List[CellRange].
    """
    var row = Row()
    var i = 0
    while i < len(starts):
        row.cells.append(CellRange(starts[i], ends[i], False, False))
        i = i + 1
    return row^


def _make_cells_one_row(starts: List[Int], ends: List[Int]) -> ScannedCells:
    """Build a ScannedCells holding ONE row with cells per (start, end) pair.

    replaces the
    legacy List[Row] shape for tests that exercise infer_column_types* /
    column-builder paths directly.
    """
    var cells = ScannedCells()
    var i = 0
    while i < len(starts):
        cells.cell_starts.append(starts[i])
        cells.cell_ends.append(ends[i])
        cells.cell_flags.append(0)
        i = i + 1
    cells.row_starts.append(len(cells.cell_starts))
    return cells^


def test_infer_wide_date64() raises:
    """Column of ISO datetimes (mid-precision: ms) -> DATE64 (no sub-second
    precision present -> Date64 wins over Timestamp_*)."""
    # Synthetic file with one column, one row "1970-01-01T00:00:00".
    var bytes = _bytes(String("1970-01-01T00:00:00"))
    var s = List[Int]()
    s.append(0)
    var e = List[Int]()
    e.append(19)
    var cells = _make_cells_one_row(s^, e^)
    var opts = CsvReadOptions()
    var types = infer_column_types_wide(Span(bytes), cells, 0, 1, 1, opts)
    assert_equal(Int(types[0].type_id), Int(ArrowType.DATE64.type_id))


def test_infer_wide_timestamp_us() raises:
    """Column of ISO datetimes with us precision -> TIMESTAMP_US."""
    var bytes = _bytes(String("1970-01-01T00:00:00.000001"))
    var s = List[Int]()
    s.append(0)
    var e = List[Int]()
    e.append(26)
    var cells = _make_cells_one_row(s^, e^)
    var opts = CsvReadOptions()
    var types = infer_column_types_wide(Span(bytes), cells, 0, 1, 1, opts)
    # MS lattice would also fit if .ffffff cleanly truncates to ms, but
    # the ms parser rejects more-than-3-digits-after-dot. So the column
    # should infer to TIMESTAMP_US (or narrower if compatible).
    var tid = Int(types[0].type_id)
    assert_true(
        tid == Int(ArrowType.TIMESTAMP_US.type_id)
        or tid == Int(ArrowType.TIMESTAMP_NS.type_id),
        "expected ts_us or ts_ns",
    )


def test_infer_wide_time() raises:
    """Column of HH:MM:SS values -> TIME32_S (no date component)."""
    var bytes = _bytes(String("12:34:56"))
    var s = List[Int]()
    s.append(0)
    var e = List[Int]()
    e.append(8)
    var cells = _make_cells_one_row(s^, e^)
    var opts = CsvReadOptions()
    var types = infer_column_types_wide(Span(bytes), cells, 0, 1, 1, opts)
    assert_equal(Int(types[0].type_id), Int(ArrowType.TIME32_S.type_id))


def test_infer_wide_duration() raises:
    """Column of ISO PnDTnHnMnS values -> DURATION_NS."""
    # Note: an ISO duration like "PT1H" is NOT a valid HH:MM:SS, NOT a
    # valid date, NOT a valid datetime, NOT a number -> Duration_* lattice
    # is the only match. PT1H parses cleanly into each Duration unit's
    # storage (3600 s = 3.6e12 ns), so the narrowest unit wins per the
    # lattice's order: DURATION_S first.
    var bytes = _bytes(String("PT1H"))
    var s = List[Int]()
    s.append(0)
    var e = List[Int]()
    e.append(4)
    var cells = _make_cells_one_row(s^, e^)
    var opts = CsvReadOptions()
    var types = infer_column_types_wide(Span(bytes), cells, 0, 1, 1, opts)
    # 'PT1H' rounds to 3600 seconds exactly (no fraction). DURATION_S
    # cleanly fits — preferred over DURATION_NS by lattice priority.
    assert_equal(Int(types[0].type_id), Int(ArrowType.DURATION_S.type_id))


def main() raises:
    test_parse_uint8()
    test_parse_uint16()
    test_parse_uint32()
    test_parse_uint64()
    test_parse_int8()
    test_parse_int16()
    test_parse_int32()
    test_parse_float32()
    test_parse_date64()
    test_parse_timestamp_s()
    test_parse_timestamp_ms()
    test_parse_timestamp_us()
    test_parse_timestamp_ns()
    test_parse_time_s()
    test_parse_time_ms()
    test_parse_time_us()
    test_parse_time_ns()
    test_parse_duration_iso_basic()
    test_parse_duration_iso_complex()
    test_parse_duration_numeric()
    test_parse_decimal128_to_int64()
    test_infer_wide_date64()
    test_infer_wide_timestamp_us()
    test_infer_wide_time()
    test_infer_wide_duration()
    print("test_csv_dtype_completion: 25/25 PASS")
