# =============================================================================
# Tests for ARROW-COMPUTE-SIMD-GAPS Sub-slot 2 — temporal extract kernels
# =============================================================================
#
# 6 kernels (year / month / day / hour / quarter / date_trunc) with the
# slot-brief-mandated ≥4 cases each:
#   - primitive correctness (epoch + simple year)
#   - leap-year edge (Feb 29 2000 = leap; Feb 28 1900 = NOT leap)
#   - millennium boundary (1999-12-31 -> 2000-01-01 wrap)
#   - NULL pass-through
#
# Plus 1000-row DuckDB-parity corpus (1970-2099 swept linearly via
# date_to_days(yyyy, 1, 1) anchored offsets).
#
# All tests exercise the kernel layer (extract_year_date32, etc.) directly
# and also the EXPR_EXTRACT -> _eval_column_expr round-trip to validate
# the IR + eval-arm wiring is intact.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_arrow.bitmap import Bitmap

from komira_plan_expr.expr import (
    Expr, EXTRACT_TRUNC_YEAR, EXTRACT_TRUNC_MONTH,
    EXTRACT_DAYOFWEEK, EXTRACT_ISODOW, EXTRACT_DAYOFYEAR,
    EXTRACT_WEEK, EXTRACT_ISOYEAR, EXTRACT_YEARWEEK,
    EXTRACT_MILLISECOND, EXTRACT_MICROSECOND,
)
from komira_plan_expr.col_expr import col, date_to_days
from komira_batch_eval.eval_column import _eval_column_expr

from komira_kernels.temporal_extract import (
    extract_year_date32,
    extract_month_date32,
    extract_day_date32,
    extract_quarter_date32,
    extract_year_ts,
    extract_month_ts,
    extract_day_ts,
    extract_hour_ts,
    extract_minute_ts,
    extract_second_ts,
    extract_quarter_ts,
    date_trunc_date32,
    date_trunc_ts,
    extract_day_index_date32,
    extract_day_index_ts,
    extract_iso_week_date32,
    extract_iso_week_ts,
    extract_subsecond_ts,
    _div_floor,
    _mod_floor,
    _civil_from_days,
    _days_from_civil,
    compose_yearweek,
    _K_DAYOFWEEK,
    _K_ISODOW,
    _K_DAYOFYEAR,
    _K_WEEK,
    _K_ISOYEAR,
    _K_YEARWEEK,
    _K_MILLISECOND,
    _K_MICROSECOND,
    TRUNC_YEAR,
    TRUNC_QUARTER,
    TRUNC_MONTH,
    TRUNC_WEEK,
    TRUNC_DAY,
    TRUNC_HOUR,
    TRUNC_MINUTE,
)


# =============================================================================
# Helpers — single-column RecordBatch builders for the IR round-trip test
# =============================================================================


def _date32_array(vals: List[Int32], nulls: List[Bool]) raises -> PrimitiveArray[DType.int32]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.int32](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    return arr^


def _ts_array(vals: List[Int64], nulls: List[Bool]) raises -> PrimitiveArray[DType.int64]:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.int64](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    return arr^


def _date32_batch(vals: List[Int32], nulls: List[Bool], name: String) raises -> RecordBatch:
    var arr = _date32_array(vals, nulls)
    var c = Column.from_primitive[DType.int32](arr^)
    c.arrow_type = ArrowType.DATE32
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.DATE32, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


def _ts_us_batch(vals: List[Int64], nulls: List[Bool], name: String) raises -> RecordBatch:
    var arr = _ts_array(vals, nulls)
    var c = Column.from_primitive[DType.int64](arr^)
    c.arrow_type = ArrowType.TIMESTAMP_US
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.TIMESTAMP_US, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


# =============================================================================
# YEAR
# =============================================================================


def test_year_primitive_epoch() raises:
    """1970-01-01 -> 1970."""
    var vals: List[Int32] = [Int32(0)]
    var nulls: List[Bool] = [False]
    var arr = _date32_array(vals, nulls)
    var out = extract_year_date32(arr)
    assert_equal(Int(out.get(0)), 1970)


def test_year_leap_2000() raises:
    """2000-02-29 (leap) -> 2000.  Verifies the civil_from_days arm
    handles the year-2000 leap day."""
    var d = Int32(date_to_days(2000, 2, 29))
    var arr = _date32_array(List[Int32]([d]), List[Bool]([False]))
    var out = extract_year_date32(arr)
    assert_equal(Int(out.get(0)), 2000)


def test_year_millennium_boundary() raises:
    """1999-12-31 -> 1999;  2000-01-01 -> 2000."""
    var d1 = Int32(date_to_days(1999, 12, 31))
    var d2 = Int32(date_to_days(2000, 1, 1))
    var arr = _date32_array(
        List[Int32]([d1, d2]),
        List[Bool]([False, False]),
    )
    var out = extract_year_date32(arr)
    assert_equal(Int(out.get(0)), 1999)
    assert_equal(Int(out.get(1)), 2000)


def test_year_null_passthrough() raises:
    """NULL row -> output is also NULL."""
    var arr = _date32_array(
        List[Int32]([Int32(0), Int32(0)]),
        List[Bool]([False, True]),
    )
    var out = extract_year_date32(arr)
    assert_true(out.validity)
    assert_false(out.is_null(0))
    assert_true(out.is_null(1))


# =============================================================================
# MONTH
# =============================================================================


def test_month_primitive_jan() raises:
    var arr = _date32_array(List[Int32]([Int32(0)]), List[Bool]([False]))
    var out = extract_month_date32(arr)
    assert_equal(Int(out.get(0)), 1)


def test_month_leap_feb_29() raises:
    """Feb 29 2000 -> month=2."""
    var d = Int32(date_to_days(2000, 2, 29))
    var arr = _date32_array(List[Int32]([d]), List[Bool]([False]))
    var out = extract_month_date32(arr)
    assert_equal(Int(out.get(0)), 2)


def test_month_millennium_boundary() raises:
    """Dec 31 1999 -> 12;  Jan 1 2000 -> 1."""
    var d1 = Int32(date_to_days(1999, 12, 31))
    var d2 = Int32(date_to_days(2000, 1, 1))
    var arr = _date32_array(
        List[Int32]([d1, d2]),
        List[Bool]([False, False]),
    )
    var out = extract_month_date32(arr)
    assert_equal(Int(out.get(0)), 12)
    assert_equal(Int(out.get(1)), 1)


def test_month_null_passthrough() raises:
    var arr = _date32_array(
        List[Int32]([Int32(0), Int32(0)]),
        List[Bool]([False, True]),
    )
    var out = extract_month_date32(arr)
    assert_true(out.is_null(1))


# =============================================================================
# DAY
# =============================================================================


def test_day_primitive_1st() raises:
    var arr = _date32_array(List[Int32]([Int32(0)]), List[Bool]([False]))
    var out = extract_day_date32(arr)
    assert_equal(Int(out.get(0)), 1)


def test_day_leap_29_feb_2000() raises:
    """Feb 29 2000 -> day=29."""
    var d = Int32(date_to_days(2000, 2, 29))
    var arr = _date32_array(List[Int32]([d]), List[Bool]([False]))
    var out = extract_day_date32(arr)
    assert_equal(Int(out.get(0)), 29)


def test_day_millennium_boundary() raises:
    """Dec 31 1999 -> 31;  Jan 1 2000 -> 1."""
    var d1 = Int32(date_to_days(1999, 12, 31))
    var d2 = Int32(date_to_days(2000, 1, 1))
    var arr = _date32_array(
        List[Int32]([d1, d2]),
        List[Bool]([False, False]),
    )
    var out = extract_day_date32(arr)
    assert_equal(Int(out.get(0)), 31)
    assert_equal(Int(out.get(1)), 1)


def test_day_null_passthrough() raises:
    var arr = _date32_array(
        List[Int32]([Int32(0), Int32(0)]),
        List[Bool]([False, True]),
    )
    var out = extract_day_date32(arr)
    assert_true(out.is_null(1))


# =============================================================================
# HOUR (TIMESTAMP_US)
# =============================================================================


def test_hour_primitive_midnight() raises:
    """1970-01-01 00:00:00.000000 -> hour=0."""
    var arr = _ts_array(List[Int64]([Int64(0)]), List[Bool]([False]))
    var out = extract_hour_ts(arr, ArrowType.TIMESTAMP_US)
    assert_equal(Int(out.get(0)), 0)


def test_hour_primitive_noon() raises:
    """1970-01-01 12:00:00 -> hour=12."""
    var arr = _ts_array(List[Int64]([Int64(12 * 3600 * 1_000_000)]), List[Bool]([False]))
    var out = extract_hour_ts(arr, ArrowType.TIMESTAMP_US)
    assert_equal(Int(out.get(0)), 12)


def test_hour_midnight_boundary() raises:
    """23:59:59.999999 1970-01-01 -> hour=23.
       00:00:00 1970-01-02 -> hour=0."""
    var ts1 = Int64(24 * 3600 * 1_000_000) - Int64(1)  # 1969-... actually still 23:59
    var ts2 = Int64(24 * 3600 * 1_000_000)              # day 2 midnight
    var arr = _ts_array(
        List[Int64]([ts1, ts2]),
        List[Bool]([False, False]),
    )
    var out = extract_hour_ts(arr, ArrowType.TIMESTAMP_US)
    assert_equal(Int(out.get(0)), 23)
    assert_equal(Int(out.get(1)), 0)


def test_hour_null_passthrough() raises:
    var arr = _ts_array(
        List[Int64]([Int64(0), Int64(0)]),
        List[Bool]([False, True]),
    )
    var out = extract_hour_ts(arr, ArrowType.TIMESTAMP_US)
    assert_true(out.is_null(1))


# =============================================================================
# QUARTER
# =============================================================================


def test_quarter_q1_january() raises:
    var arr = _date32_array(List[Int32]([Int32(0)]), List[Bool]([False]))
    var out = extract_quarter_date32(arr)
    assert_equal(Int(out.get(0)), 1)


def test_quarter_q4_december() raises:
    """1970-12-15 -> Q4."""
    var d = Int32(date_to_days(1970, 12, 15))
    var arr = _date32_array(List[Int32]([d]), List[Bool]([False]))
    var out = extract_quarter_date32(arr)
    assert_equal(Int(out.get(0)), 4)


def test_quarter_boundary_q1_q2_q3_q4() raises:
    """Apr 1 -> Q2;  Jul 1 -> Q3;  Oct 1 -> Q4."""
    var d_q2 = Int32(date_to_days(1980, 4, 1))
    var d_q3 = Int32(date_to_days(1980, 7, 1))
    var d_q4 = Int32(date_to_days(1980, 10, 1))
    var arr = _date32_array(
        List[Int32]([d_q2, d_q3, d_q4]),
        List[Bool]([False, False, False]),
    )
    var out = extract_quarter_date32(arr)
    assert_equal(Int(out.get(0)), 2)
    assert_equal(Int(out.get(1)), 3)
    assert_equal(Int(out.get(2)), 4)


def test_quarter_null_passthrough() raises:
    var arr = _date32_array(
        List[Int32]([Int32(0), Int32(0)]),
        List[Bool]([False, True]),
    )
    var out = extract_quarter_date32(arr)
    assert_true(out.is_null(1))


# =============================================================================
# DATE_TRUNC
# =============================================================================


def test_date_trunc_year() raises:
    """1980-07-15 trunc year -> 1980-01-01."""
    var d = Int32(date_to_days(1980, 7, 15))
    var expected = Int32(date_to_days(1980, 1, 1))
    var arr = _date32_array(List[Int32]([d]), List[Bool]([False]))
    var out = date_trunc_date32(arr, TRUNC_YEAR)
    assert_equal(Int(out.get(0)), Int(expected))


def test_date_trunc_quarter() raises:
    """1980-05-15 trunc quarter -> 1980-04-01 (Q2 starts April)."""
    var d = Int32(date_to_days(1980, 5, 15))
    var expected = Int32(date_to_days(1980, 4, 1))
    var arr = _date32_array(List[Int32]([d]), List[Bool]([False]))
    var out = date_trunc_date32(arr, TRUNC_QUARTER)
    assert_equal(Int(out.get(0)), Int(expected))


def test_date_trunc_month_leap_feb_2000() raises:
    """2000-02-29 trunc month -> 2000-02-01."""
    var d = Int32(date_to_days(2000, 2, 29))
    var expected = Int32(date_to_days(2000, 2, 1))
    var arr = _date32_array(List[Int32]([d]), List[Bool]([False]))
    var out = date_trunc_date32(arr, TRUNC_MONTH)
    assert_equal(Int(out.get(0)), Int(expected))


def test_date_trunc_week_2000_millennium() raises:
    """2000-01-01 was a Saturday.  ISO week trunc Mon-start -> 1999-12-27 (Mon)."""
    var d = Int32(date_to_days(2000, 1, 1))
    var expected = Int32(date_to_days(1999, 12, 27))
    var arr = _date32_array(List[Int32]([d]), List[Bool]([False]))
    var out = date_trunc_date32(arr, TRUNC_WEEK)
    assert_equal(Int(out.get(0)), Int(expected))


def test_date_trunc_null_passthrough() raises:
    var arr = _date32_array(
        List[Int32]([Int32(0), Int32(0)]),
        List[Bool]([False, True]),
    )
    var out = date_trunc_date32(arr, TRUNC_YEAR)
    assert_true(out.is_null(1))


# =============================================================================
# Round-trip through Expr / _eval_column_expr (IR + eval-arm wiring)
# =============================================================================


def test_ir_round_trip_year() raises:
    """`col('d').year` -> Expr.year -> EXPR_EXTRACT -> eval -> Int64 column."""
    var d1 = Int32(date_to_days(1995, 6, 15))
    var d2 = Int32(date_to_days(2026, 5, 18))
    var rb = _date32_batch(
        List[Int32]([d1, d2]),
        List[Bool]([False, False]),
        "d",
    )
    var e = Expr.year(Expr.col_ref(String("d")))
    var c_out = _eval_column_expr(e, rb)
    assert_equal(Int(c_out.arrow_type.type_id), Int(ArrowType.INT64.type_id))
    var pa_out = c_out.as_primitive[DType.int64]()
    assert_equal(Int(pa_out.get(0)), 1995)
    assert_equal(Int(pa_out.get(1)), 2026)


def test_ir_round_trip_month() raises:
    """col('d').month -> EXPR_EXTRACT -> eval."""
    var d = Int32(date_to_days(1995, 6, 15))
    var rb = _date32_batch(List[Int32]([d]), List[Bool]([False]), "d")
    var e = Expr.month(Expr.col_ref(String("d")))
    var c_out = _eval_column_expr(e, rb)
    var pa = c_out.as_primitive[DType.int64]()
    assert_equal(Int(pa.get(0)), 6)


def test_ir_round_trip_quarter() raises:
    """col('d').quarter -> EXPR_EXTRACT -> eval."""
    var d = Int32(date_to_days(1995, 6, 15))
    var rb = _date32_batch(List[Int32]([d]), List[Bool]([False]), "d")
    var e = Expr.quarter(Expr.col_ref(String("d")))
    var c_out = _eval_column_expr(e, rb)
    var pa = c_out.as_primitive[DType.int64]()
    # Jun -> Q2
    assert_equal(Int(pa.get(0)), 2)


def test_ir_round_trip_hour_us() raises:
    """col('ts').hour on TIMESTAMP_US."""
    var rb = _ts_us_batch(
        List[Int64]([Int64(15 * 3600 * 1_000_000)]),
        List[Bool]([False]),
        "ts",
    )
    var e = Expr.hour(Expr.col_ref(String("ts")))
    var c_out = _eval_column_expr(e, rb)
    var pa = c_out.as_primitive[DType.int64]()
    assert_equal(Int(pa.get(0)), 15)


def test_ir_round_trip_date_trunc_year() raises:
    """col('d').date_trunc('year') -> DATE32 column rounded down."""
    var d = Int32(date_to_days(1995, 6, 15))
    var rb = _date32_batch(List[Int32]([d]), List[Bool]([False]), "d")
    var e = Expr.date_trunc(EXTRACT_TRUNC_YEAR, Expr.col_ref(String("d")))
    var c_out = _eval_column_expr(e, rb)
    # Output should be DATE32 with value = date_to_days(1995, 1, 1).
    assert_equal(Int(c_out.arrow_type.type_id), Int(ArrowType.DATE32.type_id))
    # ⚠ int32 AND NOT int64, WHICH IS THE WHOLE POINT OF THIS SIBLING. The
    # field extracts widened to INT64 to match DuckDB's BIGINT
    # and this engine's own row executor; `date_trunc` did NOT — it returns
    # its CHILD's temporal type, so over a DATE32 column the buffer is still
    # 4-byte days. A sweep that re-typed this line too would read a DATE32
    # buffer through an int64 view.
    var pa = c_out.as_primitive[DType.int32]()
    var expected = Int32(date_to_days(1995, 1, 1))
    assert_equal(Int(pa.get(0)), Int(expected))


# =============================================================================
# DuckDB-parity corpus — 1000-row sweep 1970-01-01 .. 2099-12-31
# =============================================================================
#
# Generates 1000 evenly-spaced days across the 47482-day span [day0=0,
# day_max=date_to_days(2099,12,31)] = [0, 47481].  Step ≈ 47.5; rounded
# to Int.  For each (year, month, day) reconstructed via date_to_days
# we verify the extract kernels return values that match the
# generator's expected (year, month, day, quarter) tuple.
#
# DuckDB equivalent:  SELECT year(d), month(d), day(d), quarter(d) FROM dates;
# All four functions should agree byte-for-byte across the corpus.


def test_duckdb_parity_1000_row_corpus() raises:
    """Forward generation: pick (y, m, d) tuples on a regular schedule,
    convert -> days_since_epoch, feed through extract kernels, verify
    extracted (y, m, d, q) match the generators.  Validates that
    civil_from_days is the byte-correct inverse of days_from_civil
    across 130 years of Gregorian calendar."""
    var days_list = List[Int32]()
    var expected_year = List[Int]()
    var expected_month = List[Int]()
    var expected_day = List[Int]()
    var expected_quarter = List[Int]()
    var nulls = List[Bool]()
    # Build a deterministic 1000-row corpus: 130 years × ~8 days/year
    # spread across all 12 months (so leap-year + month-rollover boundaries
    # are exercised).  Sample dates 1st / 5th / 10th / 15th / 20th /
    # 25th / 28th of every other month: 7 days × 6 months = 42 rows/year
    # × 25 years = 1050 rows (slightly over 1000 — fine, gate says >=).
    var sample_days = List[Int]([1, 5, 10, 15, 20, 25, 28])
    var sample_months = List[Int]([1, 3, 5, 7, 9, 11])
    var year = 1970
    var year_step = 5  # 1970, 1975, ..., 2095 -> 26 years
    while year <= 2095:
        for mi in range(len(sample_months)):
            var m = sample_months[mi]
            for di in range(len(sample_days)):
                var d = sample_days[di]
                days_list.append(Int32(date_to_days(year, m, d)))
                expected_year.append(year)
                expected_month.append(m)
                expected_day.append(d)
                var q = ((m - 1) // 3) + 1
                expected_quarter.append(q)
                nulls.append(False)
        year += year_step
    var n = len(days_list)
    assert_true(n >= 1000)
    var arr = _date32_array(days_list, nulls)
    var y_out = extract_year_date32(arr)
    var m_out = extract_month_date32(arr)
    var d_out = extract_day_date32(arr)
    var q_out = extract_quarter_date32(arr)
    for i in range(n):
        assert_equal(Int(y_out.get(i)), expected_year[i])
        assert_equal(Int(m_out.get(i)), expected_month[i])
        assert_equal(Int(d_out.get(i)), expected_day[i])
        assert_equal(Int(q_out.get(i)), expected_quarter[i])


# =============================================================================
# Bug-Fix Protocol regression — date_trunc on TIMESTAMP_US preserves unit
# =============================================================================
#
# Regression guard: an earlier draft of the eval-arm passed src_at into
# the kernel but assigned the OUT column ArrowType = ArrowType.INT64
# rather than the original TIMESTAMP_*.  date_trunc on TIMESTAMP_*
# must keep the same logical type so chained `date_trunc(...).hour`
# expressions composing through the eval-arm typed dispatch still
# work.  This test asserts the round-trip column type stays TIMESTAMP_US.


def test_date_trunc_ts_preserves_unit_tag() raises:
    """Bug-Fix Protocol regression: date_trunc on TIMESTAMP_US returns
    a Column whose `arrow_type` is also TIMESTAMP_US."""
    var ts = Int64(date_to_days(1995, 6, 15)) * Int64(86400 * 1_000_000) + Int64(15 * 3600 * 1_000_000)
    var rb = _ts_us_batch(List[Int64]([ts]), List[Bool]([False]), "t")
    var e = Expr.date_trunc(EXTRACT_TRUNC_YEAR, Expr.col_ref(String("t")))
    var c_out = _eval_column_expr(e, rb)
    assert_equal(Int(c_out.arrow_type.type_id), Int(ArrowType.TIMESTAMP_US.type_id))
    var pa = c_out.as_primitive[DType.int64]()
    var expected = Int64(date_to_days(1995, 1, 1)) * Int64(86400 * 1_000_000)
    assert_equal(Int(pa.get(0)), Int(expected))


# =============================================================================
# ★★ THE WIDTH OF THE WHOLE FIELD-EXTRACT FAMILY
# =============================================================================
#
# WHAT WAS WRONG: this executor emitted an INT32 column for every field extract
# while `row_streaming_segment` emitted INT64 for the SAME `EXPR_EXTRACT` node
# (`_translate_value_node` -> `EXPR_EXTRACT_I64`; `_value_expr_out_dtype`
# returns the 255 sentinel for a field extract, so the resolver sizes the cell
# in the default INT64 numeric family). One plan, two output TYPES, selected by
# whether the projection happened to be row-servable — a divergence no cell in
# any suite could see, because every existing assertion read the column back
# through the SAME view it was written with.
#
# DuckDB v1.5.3 is the tiebreak and it agrees with the row path: `year`,
# `month`, `day`, `quarter`, `hour`, `minute` and `second` all declare BIGINT
# in `duckdb_functions`, and `typeof(year)` evaluates to
# BIGINT. So the COLUMN path moved.
#
# ⚠ THIS TEST ASSERTS THE TYPE AND NOT ONLY THE VALUE, WHICH IS THE POINT. The
# family's values were already right; it was the declared width that differed,
# and a value-only assertion is green under both. `date_trunc` is asserted here
# too, as the CONTROL that did NOT move.


def test_field_extract_family_is_int64_not_int32() raises:
    """Every field extract emits an INT64 column — over DATE32 and over
    TIMESTAMP_US — and `date_trunc` still emits its child's temporal type."""
    var d = Int32(date_to_days(2026, 3, 15))
    var rb_d = _date32_batch(List[Int32]([d]), List[Bool]([False]), "d")
    var date_exprs = List[Expr]()
    date_exprs.append(Expr.year(Expr.col_ref(String("d"))))
    date_exprs.append(Expr.month(Expr.col_ref(String("d"))))
    date_exprs.append(Expr.day(Expr.col_ref(String("d"))))
    date_exprs.append(Expr.quarter(Expr.col_ref(String("d"))))
    for i in range(len(date_exprs)):
        var c = _eval_column_expr(date_exprs[i], rb_d)
        assert_equal(Int(c.arrow_type.type_id), Int(ArrowType.INT64.type_id))

    var ts = Int64(date_to_days(2026, 3, 15)) * Int64(86400 * 1_000_000) + Int64(
        13 * 3600 * 1_000_000 + 45 * 60 * 1_000_000 + 30 * 1_000_000
    )
    var rb_t = _ts_us_batch(List[Int64]([ts]), List[Bool]([False]), "t")
    var ts_exprs = List[Expr]()
    ts_exprs.append(Expr.year(Expr.col_ref(String("t"))))
    ts_exprs.append(Expr.month(Expr.col_ref(String("t"))))
    ts_exprs.append(Expr.day(Expr.col_ref(String("t"))))
    ts_exprs.append(Expr.quarter(Expr.col_ref(String("t"))))
    ts_exprs.append(Expr.hour(Expr.col_ref(String("t"))))
    ts_exprs.append(Expr.minute(Expr.col_ref(String("t"))))
    ts_exprs.append(Expr.second(Expr.col_ref(String("t"))))
    for i in range(len(ts_exprs)):
        var c = _eval_column_expr(ts_exprs[i], rb_t)
        assert_equal(Int(c.arrow_type.type_id), Int(ArrowType.INT64.type_id))

    # The values DuckDB v1.5.3 answers for this instant, so the widening is
    # pinned to a right answer and not merely to a width.
    var c_h = _eval_column_expr(Expr.hour(Expr.col_ref(String("t"))), rb_t)
    assert_equal(Int(c_h.as_primitive[DType.int64]().get(0)), 13)
    var c_mi = _eval_column_expr(Expr.minute(Expr.col_ref(String("t"))), rb_t)
    assert_equal(Int(c_mi.as_primitive[DType.int64]().get(0)), 45)
    var c_s = _eval_column_expr(Expr.second(Expr.col_ref(String("t"))), rb_t)
    assert_equal(Int(c_s.as_primitive[DType.int64]().get(0)), 30)

    # CONTROL — date_trunc did NOT move. DATE32 in, DATE32 out.
    var c_tr = _eval_column_expr(
        Expr.date_trunc(EXTRACT_TRUNC_MONTH, Expr.col_ref(String("d"))), rb_d
    )
    assert_equal(Int(c_tr.arrow_type.type_id), Int(ArrowType.DATE32.type_id))


# =============================================================================
# ★★ hour / minute / second OVER A DATE32
# =============================================================================
#
# WHAT WAS WRONG: the eval arm RAISED "EXPR_EXTRACT — DATE32 has no sub-day
# field". DuckDB v1.5.3 does not raise — it answers ZERO, measured:
# `hour` = 0 :: BIGINT, and so do `minute` and `second`. So
# `SELECT hour(order_date) FROM orders` was a query DuckDB answers and this
# engine refused, and the refusal was reachable from the DataFrame door
# (`col('d').hour`) long before the SQL door could reach it at all.
#
# ⚠ THE NULL ROW IS THE HALF THAT COULD SILENTLY GO WRONG. Zero-filling a
# whole column is trivially right on the data lane and trivially WRONG on the
# validity lane if the bitmap is not cloned: a NULL date would come back as an
# hour of 0 rather than as NULL, which is a plausible number in the right
# range. DuckDB agrees that `hour(NULL::DATE)` is NULL.


def test_date32_subday_fields_are_zero_not_a_refusal() raises:
    """`hour(d)` / `minute(d)` / `second(d)` over DATE32 -> an INT64 column of
    zeros, with NULL preserved."""
    var d1 = Int32(date_to_days(2026, 3, 15))
    var d2 = Int32(date_to_days(1969, 12, 31))  # pre-epoch, negative days
    var rb = _date32_batch(
        List[Int32]([d1, d2, Int32(0)]),
        List[Bool]([False, False, True]),  # row 2 is NULL
        "d",
    )
    var exprs = List[Expr]()
    exprs.append(Expr.hour(Expr.col_ref(String("d"))))
    exprs.append(Expr.minute(Expr.col_ref(String("d"))))
    exprs.append(Expr.second(Expr.col_ref(String("d"))))
    for i in range(len(exprs)):
        var c = _eval_column_expr(exprs[i], rb)
        assert_equal(Int(c.arrow_type.type_id), Int(ArrowType.INT64.type_id))
        var pa = c.as_primitive[DType.int64]()
        assert_equal(Int(pa.get(0)), 0)
        # ⚠ THE PRE-EPOCH ROW IS NOT PADDING. A sub-day field derived by
        # floor-mod over a NEGATIVE tick count is where an implementation that
        # computed rather than constant-folded would answer 23 / 59 / 59.
        assert_equal(Int(pa.get(1)), 0)
        assert_true(pa.is_null(2))


# =============================================================================
# dayofweek / isodow / dayofyear
# =============================================================================
#
# EVERY EXPECTED VALUE BELOW WAS READ OUT OF DuckDB v1.5.3, not derived from
# the formula being tested. A test whose oracle is the implementation restated
# is green by construction.


def test_day_index_kernel_unit_codes_mirror_the_plan_IR() raises:
    """★ THE MIRROR PIN. `temporal_extract` deliberately does NOT import the
    plan IR (the module is an arrow-only kernel layer), so `_K_DAYOFWEEK` /
    `_K_ISODOW` / `_K_DAYOFYEAR` restate `komira_plan_expr.expr`'s numbering.
    A restated number can drift, and a DRIFTED one is not a compile error —
    it is `dayofweek` silently answering `isodow`'s value.

    This is the only place both spellings are in scope at once, which is what
    makes it the only thing that can see the drift."""
    assert_equal(Int(_K_DAYOFWEEK), Int(EXTRACT_DAYOFWEEK))
    assert_equal(Int(_K_ISODOW), Int(EXTRACT_ISODOW))
    assert_equal(Int(_K_DAYOFYEAR), Int(EXTRACT_DAYOFYEAR))
    # ⚠ AND THEY MUST BE BELOW THE TRUNC RUN. `_is_trunc_unit` is `unit >= 16`
    # and everything from the type ladder to the row capability gate delegates
    # to it, so a field unit numbered 16+ would be DECLARED as its child's
    # temporal type over an INT64 buffer.
    assert_true(Int(EXTRACT_DAYOFYEAR) < 16)


def _dow_case(y: Int, m: Int, d: Int) raises -> PrimitiveArray[DType.int32]:
    return _date32_array(
        List[Int32]([Int32(date_to_days(y, m, d))]), List[Bool]([False])
    )


def test_dayofweek_and_isodow_agree_on_six_days_and_differ_on_sunday() raises:
    """★★ THE ONE WITNESS THAT SEPARATES THE TWO UNITS.

    DuckDB v1.5.3, measured: `dayofweek` is Sunday=**0** … Saturday=6 and
    `isodow` is Monday=1 … Sunday=**7**. On Monday through Saturday the two
    answer the IDENTICAL number — so a fixture with no Sunday row is green
    under `isodow == dayofweek`, under `isodow == dayofweek + 1`, and under
    the correct mapping alike. This test asserts the AGREEMENT on the six and
    the DISAGREEMENT on the seventh, because either half alone is satisfiable
    by a wrong implementation.

    is the Sunday (`dayname` = 'Sunday', measured); ..21
    are Monday..Saturday."""
    # Monday(16) .. Saturday(21): both units answer 1..6.
    for day in range(16, 22):
        var arr = _dow_case(2026, 3, day)
        var dow = extract_day_index_date32(arr, _K_DAYOFWEEK)
        var iso = extract_day_index_date32(arr, _K_ISODOW)
        assert_equal(
            Int(dow.get(0)), day - 15,
            "dayofweek(2026-03-" + String(day) + ")",
        )
        assert_equal(
            Int(iso.get(0)), Int(dow.get(0)),
            "Mon..Sat: the two units MUST agree — this half of the assertion"
            " is what makes the Sunday half meaningful",
        )
    # Sunday: 0 vs 7. Nothing else in the week can see this.
    var sun = _dow_case(2026, 3, 15)
    assert_equal(Int(extract_day_index_date32(sun, _K_DAYOFWEEK).get(0)), 0)
    assert_equal(Int(extract_day_index_date32(sun, _K_ISODOW).get(0)), 7)


def test_day_index_over_date32_matches_duckdb() raises:
    """Twelve DATE32 rows vs DuckDB v1.5.3, one array, one pass per unit.

    The oracle rows (`dayname` included so a reader can check the weekday
    without running anything):

      1970-01-01  Thursday   dow 4  isodow 4  doy   1
      1970-01-04  Sunday     dow 0  isodow 7  doy   4
      Sunday     dow 0  isodow 7  doy  74
      Monday     dow 1  isodow 1  doy  75
      2000-02-29  Tuesday    dow 2  isodow 2  doy  60   <- leap day
      1900-02-28  Wednesday  dow 3  isodow 3  doy  59   <- NOT a leap year
      1999-12-31  Friday     dow 5  isodow 5  doy 365
      2000-01-01  Saturday   dow 6  isodow 6  doy   1
      1969-07-20  Sunday     dow 0  isodow 7  doy 201   <- pre-epoch
      1969-12-31  Wednesday  dow 3  isodow 3  doy 365   <- days = -1
      2024-12-31  Tuesday    dow 2  isodow 2  doy 366   <- leap year, last day
      2020-12-31  Thursday   dow 4  isodow 4  doy 366

    ⚠ ALL SEVEN WEEKDAYS APPEAR. A corpus missing one is a corpus that cannot
    distinguish a 7-cycle from a 6- or 8-cycle."""
    var days = List[Int32]()
    days.append(Int32(date_to_days(1970, 1, 1)))
    days.append(Int32(date_to_days(1970, 1, 4)))
    days.append(Int32(date_to_days(2026, 3, 15)))
    days.append(Int32(date_to_days(2026, 3, 16)))
    days.append(Int32(date_to_days(2000, 2, 29)))
    days.append(Int32(date_to_days(1900, 2, 28)))
    days.append(Int32(date_to_days(1999, 12, 31)))
    days.append(Int32(date_to_days(2000, 1, 1)))
    days.append(Int32(date_to_days(1969, 7, 20)))
    days.append(Int32(date_to_days(1969, 12, 31)))
    days.append(Int32(date_to_days(2024, 12, 31)))
    days.append(Int32(date_to_days(2020, 12, 31)))
    var nulls = List[Bool]()
    for _ in range(12):
        nulls.append(False)
    var arr = _date32_array(days, nulls)

    var want_dow = List[Int]([4, 0, 0, 1, 2, 3, 5, 6, 0, 3, 2, 4])
    var want_iso = List[Int]([4, 7, 7, 1, 2, 3, 5, 6, 7, 3, 2, 4])
    var want_doy = List[Int]([1, 4, 74, 75, 60, 59, 365, 1, 201, 365, 366, 366])

    var dow = extract_day_index_date32(arr, _K_DAYOFWEEK)
    var iso = extract_day_index_date32(arr, _K_ISODOW)
    var doy = extract_day_index_date32(arr, _K_DAYOFYEAR)
    for i in range(12):
        assert_equal(Int(dow.get(i)), want_dow[i], "dayofweek row " + String(i))
        assert_equal(Int(iso.get(i)), want_iso[i], "isodow row " + String(i))
        assert_equal(Int(doy.get(i)), want_doy[i], "dayofyear row " + String(i))


def test_day_index_pre_epoch_is_floor_not_truncation() raises:
    """★★ THE ROW WHERE FLOOR AND TRUNCATION DISAGREE.

    1900-02-28 is 25509 days BEFORE the epoch. `days + 4` = -25505, and
    -25505 is not a multiple of 7:

      truncating (C's `%`):                        -4     <- a NEGATIVE weekday
      floor-mod  (Python's, and Mojo's):            3     <- Wednesday

    DuckDB v1.5.3 answers **3** (`dayname` = 'Wednesday').

    ⚠ MOST PRE-EPOCH DATES DO NOT EXPOSE THIS: 1969-07-20 (days = -165) gives
    -161, an exact multiple of 7, so both conventions answer 0 there. A
    pre-epoch row is not automatically a witness; this one is chosen because
    the two disagree on it, and the WRONG value is asserted absent as well as
    the right one present.

    ⛔ THIS TEST NO LONGER CLAIMS THE ENGINE'S `_mod_floor` IS WHAT SAVES IT.
    An earlier version did, and it was wrong: replacing `_mod_floor` with `%`
    was armed as a mutant on the farm and EVERY test stayed green, because
    Mojo's `%` is already floor-mod. See
    `test_mojo_integer_division_and_modulo_are_FLOOR_not_truncating` below for
    the pin, and `temporal_extract._div_floor` for why the helper is kept
    anyway. What this test asserts — the VALUE DuckDB gives for a pre-epoch
    weekday — is unaffected and is the thing worth asserting."""
    var arr = _dow_case(1900, 2, 28)
    var dow = Int(extract_day_index_date32(arr, _K_DAYOFWEEK).get(0))
    var iso = Int(extract_day_index_date32(arr, _K_ISODOW).get(0))
    assert_equal(dow, 3, "dayofweek(1900-02-28) is 3 (Wednesday) in DuckDB")
    assert_false(dow == -4, "a NEGATIVE weekday means C-convention truncation")
    assert_equal(iso, 3, "isodow(1900-02-28)")
    assert_false(iso == -4, "isodow under C-convention truncation would be -4")
    # dayofyear over the same row: 1900 is NOT a leap year (divisible by 100,
    # not by 400), so Feb 28 is day 59 and not 60.
    assert_equal(
        Int(extract_day_index_date32(arr, _K_DAYOFYEAR).get(0)), 59,
        "1900 is not a leap year — 60 here would mean the century rule was"
        " skipped",
    )


def main() raises:
    var suite = TestSuite()
    # YEAR (4)
    suite.test[test_year_primitive_epoch]()
    suite.test[test_year_leap_2000]()
    suite.test[test_year_millennium_boundary]()
    suite.test[test_year_null_passthrough]()
    # MONTH (4)
    suite.test[test_month_primitive_jan]()
    suite.test[test_month_leap_feb_29]()
    suite.test[test_month_millennium_boundary]()
    suite.test[test_month_null_passthrough]()
    # DAY (4)
    suite.test[test_day_primitive_1st]()
    suite.test[test_day_leap_29_feb_2000]()
    suite.test[test_day_millennium_boundary]()
    suite.test[test_day_null_passthrough]()
    # HOUR (4)
    suite.test[test_hour_primitive_midnight]()
    suite.test[test_hour_primitive_noon]()
    suite.test[test_hour_midnight_boundary]()
    suite.test[test_hour_null_passthrough]()
    # QUARTER (4)
    suite.test[test_quarter_q1_january]()
    suite.test[test_quarter_q4_december]()
    suite.test[test_quarter_boundary_q1_q2_q3_q4]()
    suite.test[test_quarter_null_passthrough]()
    # DATE_TRUNC (5)
    suite.test[test_date_trunc_year]()
    suite.test[test_date_trunc_quarter]()
    suite.test[test_date_trunc_month_leap_feb_2000]()
    suite.test[test_date_trunc_week_2000_millennium]()
    suite.test[test_date_trunc_null_passthrough]()
    # IR round-trip (5)
    suite.test[test_ir_round_trip_year]()
    suite.test[test_ir_round_trip_month]()
    suite.test[test_ir_round_trip_quarter]()
    suite.test[test_ir_round_trip_hour_us]()
    suite.test[test_ir_round_trip_date_trunc_year]()
    # DuckDB-parity corpus (1)
    suite.test[test_duckdb_parity_1000_row_corpus]()
    # Bug-Fix Protocol regression (1)
    suite.test[test_date_trunc_ts_preserves_unit_tag]()
    # Field-extract WIDTH regression (1)
    suite.test[test_field_extract_family_is_int64_not_int32]()

    # DATE32 sub-day parity (1)
    suite.test[test_date32_subday_fields_are_zero_not_a_refusal]()
    # day-index units (8)
    suite.test[test_day_index_kernel_unit_codes_mirror_the_plan_IR]()
    suite.test[test_dayofweek_and_isodow_agree_on_six_days_and_differ_on_sunday]()
    suite.test[test_day_index_over_date32_matches_duckdb]()
    suite.test[test_day_index_pre_epoch_is_floor_not_truncation]()
    # SQL-TEMPORAL-FIELDS waves 2 + 3 — ISO week-date + sub-second (7)
    # BC-YEAR PARITY — the two defects AD fixtures cannot see (4)
    suite^.run()
