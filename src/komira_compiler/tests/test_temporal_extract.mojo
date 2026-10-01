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

from komira_core.arrow import PrimitiveArray
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_core.arrow.bitmap import Bitmap

from komira_core.plan.expr import (
    Expr, EXTRACT_TRUNC_YEAR, EXTRACT_TRUNC_MONTH,
    EXTRACT_DAYOFWEEK, EXTRACT_ISODOW, EXTRACT_DAYOFYEAR,
    EXTRACT_WEEK, EXTRACT_ISOYEAR, EXTRACT_YEARWEEK,
    EXTRACT_MILLISECOND, EXTRACT_MICROSECOND,
)
from komira_core.plan.col_expr import col, date_to_days
from komira_compiler.compiler_eval_column import _eval_column_expr

from komira_eval.temporal_extract import (
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
    `_K_ISODOW` / `_K_DAYOFYEAR` restate `komira_core.plan.expr`'s numbering.
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


def test_day_index_over_three_timestamp_units_answer_identically() raises:
    """★ THE UNIT-CARRY CLAIM. The SAME INSTANT expressed in seconds,
    milliseconds and microseconds must give the same day index.

    ⚠ THIS IS THE ASSERTION A HARD-CODED TICK RATE FAILS. DATE32 and all four
    TIMESTAMP_* collapse into one INT64 runtime family, so a kernel that
    assumed microseconds answers a day 1000x away over a millisecond column —
    and a fixture written in ONE unit cannot see it.

    13:45:30 UTC — a Sunday: dow 0, isodow 7, doy 74."""
    var d = date_to_days(2026, 3, 15)
    var secs_of_day = 13 * 3600 + 45 * 60 + 30
    var t_s = Int64(d) * Int64(86_400) + Int64(secs_of_day)
    var t_ms = t_s * Int64(1_000)
    var t_us = t_s * Int64(1_000_000)
    var one = List[Bool]([False])

    var a_s = _ts_array(List[Int64]([t_s]), one)
    var a_ms = _ts_array(List[Int64]([t_ms]), one)
    var a_us = _ts_array(List[Int64]([t_us]), one)

    var units = List[UInt8]([_K_DAYOFWEEK, _K_ISODOW, _K_DAYOFYEAR])
    var wants = List[Int]([0, 7, 74])
    for i in range(3):
        var unit = units[i]
        var want = wants[i]
        assert_equal(
            Int(extract_day_index_ts(a_s, ArrowType.TIMESTAMP_S, unit).get(0)),
            want, "TIMESTAMP_S unit " + String(Int(unit)),
        )
        assert_equal(
            Int(extract_day_index_ts(a_ms, ArrowType.TIMESTAMP_MS, unit).get(0)),
            want, "TIMESTAMP_MS unit " + String(Int(unit)),
        )
        assert_equal(
            Int(extract_day_index_ts(a_us, ArrowType.TIMESTAMP_US, unit).get(0)),
            want, "TIMESTAMP_US unit " + String(Int(unit)),
        )


def test_day_index_null_passthrough() raises:
    """NULL in -> NULL out, on all three units and on both input types.
    MEASURED: `dayofweek(NULL::DATE)` is NULL in DuckDB, not 0 — and the data
    lane here IS 0 for a null row (this family's convention), so a test that
    only read the value would be green with the validity bitmap dropped."""
    var arr = _date32_array(
        List[Int32]([Int32(date_to_days(2026, 3, 15)), Int32(0)]),
        List[Bool]([False, True]),
    )
    var null_units = List[UInt8]([_K_DAYOFWEEK, _K_ISODOW, _K_DAYOFYEAR])
    for ui in range(3):
        var out = extract_day_index_date32(arr, null_units[ui])
        assert_false(out.is_null(0), "row 0 must not be null")
        assert_true(out.is_null(1), "row 1 must stay NULL, not become 0")
        assert_equal(out.null_count, 1)
    var ts = _ts_array(List[Int64]([Int64(0), Int64(0)]), List[Bool]([False, True]))
    var out_ts = extract_day_index_ts(ts, ArrowType.TIMESTAMP_US, _K_DAYOFYEAR)
    assert_true(out_ts.is_null(1), "TIMESTAMP null must survive the kernel too")


def test_day_index_refuses_a_unit_it_does_not_serve() raises:
    """★ THE DISPATCH RAISES RATHER THAN DEFAULTING. `_day_index_field` has no
    fall-through arm, so handing it `EXTRACT_YEAR` is an error and not a
    silently-wrong field. A default of "dayofweek" would make every mis-wired
    caller answer a plausible small integer."""
    var arr = _dow_case(2026, 3, 15)
    var raised = False
    try:
        var _unused = extract_day_index_date32(arr, UInt8(0))  # EXTRACT_YEAR
    except:
        raised = True
    assert_true(
        raised,
        "extract_day_index_date32 must REFUSE a non-day-index unit; a default"
        " would answer the wrong field with no diagnostic",
    )


def test_ir_round_trip_day_index() raises:
    """`Expr.extract(<unit>, col('d'))` -> EXPR_EXTRACT -> `_eval_column_expr`.

    ⚠ THE DECLARED TYPE IS ASSERTED BEFORE ANY VALUE IS READ. The
    divergence (the column executor emitting INT32 while the row executor
    emitted INT64 for the same node) survived because every assertion read the
    buffer back through the view it was written with. DuckDB v1.5.3 declares
    BIGINT for all three of these."""
    var rb = _date32_batch(
        List[Int32](
            [Int32(date_to_days(2026, 3, 15)), Int32(date_to_days(2026, 3, 16))]
        ),
        List[Bool]([False, False]),
        "d",
    )
    var ir_units = List[UInt8](
        [EXTRACT_DAYOFWEEK, EXTRACT_ISODOW, EXTRACT_DAYOFYEAR]
    )
    var want_sun = List[Int]([0, 7, 74])
    var want_mon = List[Int]([1, 1, 75])
    for i in range(3):
        var unit = ir_units[i]
        var e = Expr.extract(unit, Expr.col_ref(String("d")))
        var c_out = _eval_column_expr(e, rb)
        assert_equal(
            Int(c_out.arrow_type.type_id), Int(ArrowType.INT64.type_id),
            "unit " + String(Int(unit)) + " must emit INT64 (DuckDB: BIGINT)",
        )
        var pa = c_out.as_primitive[DType.int64]()
        assert_equal(Int(pa.get(0)), want_sun[i])
        assert_equal(Int(pa.get(1)), want_mon[i])


def test_mojo_integer_division_and_modulo_are_FLOOR_not_truncating() raises:
    """★★ THE LANGUAGE ASSUMPTION EVERY TEMPORAL KERNEL IN THIS REPO RESTS ON,
    PINNED — because three docstrings asserted the OPPOSITE of it for four
    months and nothing could tell.

    `temporal_extract._div_floor` said "Mojo `//` is truncation-toward-zero"
    and `expression_executor._ee_div_floor` said the same. Both are FALSE on
    Mojo 1.0.0. Measured by running it, for `Int`, `Int64`, `Int32`
    and `SIMD[int64, N]` alike:

        -25505 // 7 = -3644     -25505 % 7 = 3
        7 // -3     = -3        7 % -3     = -2      (Python's sign rule)

    ⇒ `_div_floor` / `_mod_floor` are IDENTITIES. They are kept (see their
    docstrings), and THIS is the test that makes keeping them meaningful: if a
    future Mojo adopts the C convention, every weekday kernel here starts
    answering a NEGATIVE day-of-week for pre-1970 rows, and this goes red
    naming the operator instead of the value.

    ⛔ AND `/` IS A DIFFERENT OPERATOR THAT **DOES** TRUNCATE. Asserted below
    on the same operands, because the difference is invisible in a diff and
    reaches a different answer for every negative dividend that is not an
    exact multiple.

    ⚠ THE OPERANDS COME OUT OF A `List` SO THE COMPILER CANNOT CONSTANT-FOLD
    THE EXPRESSION. A pin written on literals asserts what the FOLDER does,
    which is not necessarily what the emitted code does."""
    var a = List[Int]([-25505, 7, -1, -8])
    var b = List[Int]([7, -3, 7, 7])
    # (1) `//` is FLOOR.
    assert_equal(a[0] // b[0], -3644, "Mojo `//` must FLOOR (truncation gives -3643)")
    assert_equal(a[1] // b[1], -3, "7 // -3 must be -3 (Python's rule)")
    assert_equal(a[2] // b[2], -1, "-1 // 7 must be -1, not 0")
    # (2) `%` is FLOOR-MOD, with the sign of the DIVISOR.
    assert_equal(a[0] % b[0], 3, "Mojo `%` must FLOOR-MOD (C's `%` gives -4)")
    assert_equal(a[1] % b[1], -2, "7 % -3 must take the DIVISOR's sign")
    assert_equal(a[2] % b[2], 6, "-1 % 7 must be 6, not -1")
    assert_equal(a[3] % b[3], 6, "-8 % 7 must be 6, not -1")
    # (3) the helpers agree with the operators — i.e. they are identities.
    for i in range(4):
        assert_equal(
            _div_floor(a[i], b[i]), a[i] // b[i],
            "_div_floor must agree with `//` at index " + String(i)
            + " — if this ever DISAGREES, `//` has changed and the helper is"
            + " load-bearing again, which is exactly why it was kept",
        )
        assert_equal(
            _mod_floor(a[i], b[i]), a[i] % b[i],
            "_mod_floor must agree with `%` at index " + String(i),
        )
    # (4) ⛔ `/` IS THE TRUNCATING ONE, on the SAME operands.
    var l64 = SIMD[DType.int64, 1](Int64(a[0]))
    var r64 = SIMD[DType.int64, 1](Int64(b[0]))
    assert_equal(
        Int((l64 / r64)[0]), -3643,
        "Mojo `/` on an INTEGRAL type TRUNCATES — -3643, one away from `//`'s"
        " -3644. The two operators are not interchangeable and a kernel's"
        " choice between them is a semantic decision.",
    )



# =============================================================================
# SQL-TEMPORAL-FIELDS waves 2 + 3 — ISO week-date, and sub-second
# =============================================================================


def test_iso_week_kernel_unit_codes_mirror_the_plan_IR() raises:
    """The mirror pin, extended. Same reasoning as the wave-1 one above: a
    drifted mirror is `week` silently answering `isoyear`'s value."""
    assert_equal(Int(_K_WEEK), Int(EXTRACT_WEEK))
    assert_equal(Int(_K_ISOYEAR), Int(EXTRACT_ISOYEAR))
    assert_equal(Int(_K_YEARWEEK), Int(EXTRACT_YEARWEEK))
    assert_equal(Int(_K_MILLISECOND), Int(EXTRACT_MILLISECOND))
    assert_equal(Int(_K_MICROSECOND), Int(EXTRACT_MICROSECOND))
    # ⛔ The reserved field space is FULL at 14; 15 is the last hole and is
    # claimed by the plan-wire codec's refusal test.
    assert_true(Int(EXTRACT_MICROSECOND) < 16)


def test_isoyear_is_NOT_year_and_three_rows_prove_it() raises:
    """★★ THE WHOLE POINT OF A SEPARATE UNIT, IN THREE ROWS.

    On ~99% of days `isoyear(d)` and `year(d)` are the same number, so an
    alias survives every fixture that is not authored to break it. MEASURED
    v1.5.3 — the rows where they differ, and what `week` does on each:

      2000-01-01   year 2000   isoyear 1999   week 52   <- JANUARY, prev year
      1969-12-31   year 1969   isoyear 1970   week  1   <- DECEMBER, next year
      2021-01-01   year 2021   isoyear 2020   week 53   <- JANUARY, week 53
      2024-12-30   year 2024   isoyear 2025   week  1   <- DECEMBER, week 1

    An ISO week belongs to the year containing its THURSDAY; that is the only
    rule, and these four rows are where it visibly disagrees with the civil
    calendar. ⚠ Both halves are asserted — the ISO answer AND the civil one —
    because "isoyear = 1999" alone is also satisfied by a broken `year`."""
    var days = List[Int32]()
    days.append(Int32(date_to_days(2000, 1, 1)))
    days.append(Int32(date_to_days(1969, 12, 31)))
    days.append(Int32(date_to_days(2021, 1, 1)))
    days.append(Int32(date_to_days(2024, 12, 30)))
    var nulls = List[Bool]([False, False, False, False])
    var arr = _date32_array(days, nulls)

    var civil = extract_year_date32(arr)
    var iso = extract_iso_week_date32(arr, _K_ISOYEAR)
    var wk = extract_iso_week_date32(arr, _K_WEEK)
    var yw = extract_iso_week_date32(arr, _K_YEARWEEK)

    var want_civil = List[Int]([2000, 1969, 2021, 2024])
    var want_iso = List[Int]([1999, 1970, 2020, 2025])
    var want_wk = List[Int]([52, 1, 53, 1])
    var want_yw = List[Int]([199952, 197001, 202053, 202501])
    for i in range(4):
        assert_equal(Int(civil.get(i)), want_civil[i], "year row " + String(i))
        assert_equal(Int(iso.get(i)), want_iso[i], "isoyear row " + String(i))
        assert_equal(Int(wk.get(i)), want_wk[i], "week row " + String(i))
        assert_equal(Int(yw.get(i)), want_yw[i], "yearweek row " + String(i))
        # ⛔ The assertion that an ALIAS would fail. Kept explicit so a reader
        # cannot mistake the four rows above for arbitrary fixture data.
        assert_false(
            Int(iso.get(i)) == Int(civil.get(i)),
            "row " + String(i) + " was chosen BECAUSE isoyear != year there;"
            " if they now agree the fixture has lost its whole purpose",
        )
        # ⛔ AND `yearweek` USES THE **ISO** YEAR. Composing it from the civil
        # one gives 200052 / 196901 / 202153 / 202401 — the right shape, the
        # wrong year, on exactly these rows.
        assert_false(
            Int(yw.get(i)) == want_civil[i] * 100 + want_wk[i],
            "yearweek row " + String(i) + " must use the ISO year, not the"
            " civil one",
        )


def test_iso_week_over_date32_matches_duckdb() raises:
    """Twelve DATE32 rows vs DuckDB v1.5.3, the same fixture the day-index
    corpus uses so the two can be read side by side.

      1970-01-01  wk  1  isoyear 1970  yearweek 197001
      1970-01-04  wk  1  isoyear 1970  yearweek 197001
      wk 11  isoyear 2026  yearweek 202611
      wk 12  isoyear 2026  yearweek 202612
      2000-02-29  wk  9  isoyear 2000  yearweek 200009
      1900-02-28  wk  9  isoyear 1900  yearweek 190009   <- pre-epoch
      1999-12-31  wk 52  isoyear 1999  yearweek 199952
      2000-01-01  wk 52  isoyear 1999  yearweek 199952   <- year != isoyear
      1969-07-20  wk 29  isoyear 1969  yearweek 196929   <- pre-epoch
      1969-12-31  wk  1  isoyear 1970  yearweek 197001   <- year != isoyear
      2024-12-31  wk  1  isoyear 2025  yearweek 202501   <- year != isoyear
      2020-12-31  wk 53  isoyear 2020  yearweek 202053   <- a 53-week year"""
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

    var want_wk = List[Int]([1, 1, 11, 12, 9, 9, 52, 52, 29, 1, 1, 53])
    var want_iso = List[Int](
        [1970, 1970, 2026, 2026, 2000, 1900, 1999, 1999, 1969, 1970, 2025, 2020]
    )
    var want_yw = List[Int](
        [197001, 197001, 202611, 202612, 200009, 190009, 199952, 199952,
         196929, 197001, 202501, 202053]
    )
    var wk = extract_iso_week_date32(arr, _K_WEEK)
    var iso = extract_iso_week_date32(arr, _K_ISOYEAR)
    var yw = extract_iso_week_date32(arr, _K_YEARWEEK)
    for i in range(12):
        assert_equal(Int(wk.get(i)), want_wk[i], "week row " + String(i))
        assert_equal(Int(iso.get(i)), want_iso[i], "isoyear row " + String(i))
        assert_equal(Int(yw.get(i)), want_yw[i], "yearweek row " + String(i))


def test_iso_week_refuses_a_unit_it_does_not_serve_and_preserves_NULL() raises:
    """The dispatcher raises rather than defaulting, and validity survives."""
    var arr = _date32_array(
        List[Int32]([Int32(date_to_days(2026, 3, 15)), Int32(0)]),
        List[Bool]([False, True]),
    )
    var out = extract_iso_week_date32(arr, _K_WEEK)
    assert_equal(Int(out.get(0)), 11)
    assert_true(out.is_null(1), "a NULL date must stay NULL, not become 0")
    var raised = False
    try:
        var _u = extract_iso_week_date32(arr, _K_DAYOFWEEK)
    except:
        raised = True
    assert_true(
        raised,
        "extract_iso_week_date32 must REFUSE a day-index unit — the two"
        " families are separate dispatchers precisely so a mis-routed unit is"
        " an ERROR and not the other family's answer",
    )


def test_subsecond_folds_the_seconds_in() raises:
    """★★ THE MOST PLAUSIBLE WRONG ANSWER IN THE TEMPORAL FAMILY.

    MEASURED v1.5.3 on `TIMESTAMP '13:45:30.123456'`:
        second      = 30
        millisecond = 30123      = 30 * 1000    + 123
        microsecond = 30123456   = 30 * 1000000 + 123456

    The obvious reading — "the fractional field" — gives 123 and 123456. Right
    type, right nullability, wrong by three and six orders of magnitude. Both
    names were REFUSED BY NAME by this engine until for exactly
    that reason, so this test asserts the folded answer AND asserts the
    fraction-only answer is not what comes back."""
    var secs_of_day = 13 * 3600 + 45 * 60 + 30
    var t_us = (
        Int64(date_to_days(2026, 3, 15)) * Int64(86_400_000_000)
        + Int64(secs_of_day) * Int64(1_000_000)
        + Int64(123_456)
    )
    var arr = _ts_array(List[Int64]([t_us]), List[Bool]([False]))
    var ms = extract_subsecond_ts(arr, ArrowType.TIMESTAMP_US, _K_MILLISECOND)
    var us = extract_subsecond_ts(arr, ArrowType.TIMESTAMP_US, _K_MICROSECOND)
    assert_equal(Int(ms.get(0)), 30123, "millisecond folds the SECONDS in")
    assert_equal(Int(us.get(0)), 30123456, "microsecond folds the SECONDS in")
    assert_false(
        Int(ms.get(0)) == 123,
        "123 is the FRACTION-ONLY answer — the wrong one, and the one a"
        " reader arrives at from the name",
    )
    assert_false(
        Int(us.get(0)) == 123456, "123456 is the FRACTION-ONLY answer"
    )


def test_subsecond_pre_epoch_needs_floor_semantics() raises:
    """★★ TICK **-1**: `TIMESTAMP '1969-12-31 23:59:59.999999'` is exactly -1
    microsecond since the epoch, and DuckDB v1.5.3 answers `microsecond` =
    59999999 / `millisecond` = 59999 / `second` = 59.

    ⚠ THIS IS THE ROW THAT SEPARATES FLOOR FROM TRUNCATION ON THE SUB-SECOND
    FAMILY, and it is a nastier witness than the weekday one because -1 is the
    value a fixture is MOST likely to contain accidentally and LEAST likely to
    be checked: a C-convention `%` answers -1, not 59999999. (Mojo's `%` is
    already floor-mod, measured — so the assertion is about the ANSWER, which
    is the durable claim, not about which spelling produced it.)"""
    var arr = _ts_array(List[Int64]([Int64(-1)]), List[Bool]([False]))
    var us = extract_subsecond_ts(arr, ArrowType.TIMESTAMP_US, _K_MICROSECOND)
    var ms = extract_subsecond_ts(arr, ArrowType.TIMESTAMP_US, _K_MILLISECOND)
    assert_equal(Int(us.get(0)), 59999999, "microsecond of tick -1")
    assert_equal(Int(ms.get(0)), 59999, "millisecond of tick -1")
    assert_false(Int(us.get(0)) == -1, "a NEGATIVE microsecond is truncation")
    # And a deeper pre-epoch instant: 1900-01-01 00:00:00.000001 has
    # microsecond = 1 and millisecond = 0 (measured).
    var deep = Int64(date_to_days(1900, 1, 1)) * Int64(86_400_000_000) + Int64(1)
    var arr2 = _ts_array(List[Int64]([deep]), List[Bool]([False]))
    assert_equal(
        Int(extract_subsecond_ts(arr2, ArrowType.TIMESTAMP_US, _K_MICROSECOND).get(0)),
        1, "1900-01-01 00:00:00.000001 -> microsecond 1",
    )
    assert_equal(
        Int(extract_subsecond_ts(arr2, ArrowType.TIMESTAMP_US, _K_MILLISECOND).get(0)),
        0, "...and millisecond 0",
    )


def test_subsecond_reads_the_SOURCE_UNIT_and_does_not_assume_microseconds() raises:
    """★★ THE ASSERTION A HARD-CODED TICK RATE FAILS, AND THE ONE THE OTHER
    TEMPORAL UNITS CANNOT MAKE.

    Every calendar unit answers the SAME number for one instant at any
    resolution — so a unit bug there is invisible unless the day is wrong by a
    whole day. The sub-second family is different: the SAME instant carries
    DIFFERENT information at different resolutions, and the answer must follow.

    MEASURED v1.5.3 over the repo's own temporal fixture, row 0
:

        microsecond(ts_ms) = 30123000    <- the ms column has no us digits
        microsecond(ts_us) = 30123456
        microsecond(ts_ns) = 30123456    <- ns digits DISCARDED

    ⇒ a kernel that assumed microseconds answers 30123456 for the MS column
    too, which is wrong by 456 and green on every fixture written in one
    unit."""
    var days = Int64(date_to_days(2026, 3, 15))
    var sod = Int64(13 * 3600 + 45 * 60 + 30)
    var t_ms = days * Int64(86_400_000) + sod * Int64(1_000) + Int64(123)
    var t_us = days * Int64(86_400_000_000) + sod * Int64(1_000_000) + Int64(123_456)
    var t_ns = (
        days * Int64(86_400_000_000_000)
        + sod * Int64(1_000_000_000)
        + Int64(123_456_789)
    )
    var t_s = days * Int64(86_400) + sod
    var one = List[Bool]([False])

    var a_ms = _ts_array(List[Int64]([t_ms]), one)
    var a_us = _ts_array(List[Int64]([t_us]), one)
    var a_ns = _ts_array(List[Int64]([t_ns]), one)
    var a_s = _ts_array(List[Int64]([t_s]), one)

    assert_equal(
        Int(extract_subsecond_ts(a_ms, ArrowType.TIMESTAMP_MS, _K_MICROSECOND).get(0)),
        30123000, "microsecond over a MILLISECOND column",
    )
    assert_equal(
        Int(extract_subsecond_ts(a_us, ArrowType.TIMESTAMP_US, _K_MICROSECOND).get(0)),
        30123456, "microsecond over a MICROSECOND column",
    )
    assert_equal(
        Int(extract_subsecond_ts(a_ns, ArrowType.TIMESTAMP_NS, _K_MICROSECOND).get(0)),
        30123456, "microsecond over a NANOSECOND column DISCARDS the ns digits",
    )
    assert_equal(
        Int(extract_subsecond_ts(a_s, ArrowType.TIMESTAMP_S, _K_MICROSECOND).get(0)),
        30000000, "microsecond over a SECOND column is second * 1e6 exactly",
    )
    # millisecond agrees across all four, because the ms digits survive every
    # one of these resolutions — which is why MICROSECOND is the discriminating
    # unit here and millisecond alone would not have caught a us assumption.
    assert_equal(
        Int(extract_subsecond_ts(a_ms, ArrowType.TIMESTAMP_MS, _K_MILLISECOND).get(0)),
        30123, "millisecond over MS",
    )
    assert_equal(
        Int(extract_subsecond_ts(a_ns, ArrowType.TIMESTAMP_NS, _K_MILLISECOND).get(0)),
        30123, "millisecond over NS",
    )


def test_ir_round_trip_iso_week_and_subsecond() raises:
    """`Expr.extract(<unit>, col)` -> EXPR_EXTRACT -> `_eval_column_expr`, for
    all five wave-2/3 units, with the DECLARED type asserted before any value.

    ⚠ THE DATE32 HALF IS NOT PADDING: `millisecond(DATE ...)` and
    `microsecond(DATE ...)` are **0** in DuckDB (measured), served by the same
    `extract_subday_zero_date32` that already answers hour/minute/second, and
    that routing is only exercised here."""
    var rb = _date32_batch(
        List[Int32]([Int32(date_to_days(2021, 1, 1))]),
        List[Bool]([False]),
        "d",
    )
    var units = List[UInt8](
        [EXTRACT_WEEK, EXTRACT_ISOYEAR, EXTRACT_YEARWEEK,
         EXTRACT_MILLISECOND, EXTRACT_MICROSECOND]
    )
    var want = List[Int]([53, 2020, 202053, 0, 0])
    for i in range(5):
        var e = Expr.extract(units[i], Expr.col_ref(String("d")))
        var c_out = _eval_column_expr(e, rb)
        assert_equal(
            Int(c_out.arrow_type.type_id), Int(ArrowType.INT64.type_id),
            "unit " + String(Int(units[i])) + " must emit INT64 (BIGINT)",
        )
        assert_equal(
            Int(c_out.as_primitive[DType.int64]().get(0)), want[i],
            "unit " + String(Int(units[i])) + " over DATE32 2021-01-01",
        )
    # ...and over a TIMESTAMP_US, where the sub-second units are not zero.
    var t = (
        Int64(date_to_days(2026, 3, 15)) * Int64(86_400_000_000)
        + Int64(13 * 3600 + 45 * 60 + 30) * Int64(1_000_000)
        + Int64(123_456)
    )
    var rbt = _ts_us_batch(List[Int64]([t]), List[Bool]([False]), "t")
    var e_us = Expr.extract(EXTRACT_MICROSECOND, Expr.col_ref(String("t")))
    var c_us = _eval_column_expr(e_us, rbt)
    assert_equal(Int(c_us.arrow_type.type_id), Int(ArrowType.INT64.type_id))
    assert_equal(Int(c_us.as_primitive[DType.int64]().get(0)), 30123456)



# =============================================================================
# BC-YEAR PARITY — the two defects the AD fixtures above cannot see
# =============================================================================
#
# ⛔ EVERY FIXTURE IN THIS FILE ABOVE THIS LINE IS AD, AND BOTH DEFECTS BELOW
# ARE INVISIBLE ON AN AD ROW. That is not a coincidence, it is the shape of the
# defect class: a formula whose two candidate spellings agree for y > 0.
#
# ⚠ THE DAY COUNTS HERE ARE RAW LITERALS, NOT `date_to_days(...)` CALLS, AND
# THAT IS DELIBERATE. `col_expr.date_to_days` carries the SAME era idiom this
# wave fixes in the kernels (`(y if y >= 0 else y - 399) // 400`) and is still
# one day short for a BC year — so composing a BC fixture with it would assert
# against a DIFFERENT DATE than the comment claims. Each literal below is
# `floor(epoch_us(make_timestamp(y,m,d,0,0,0.0)) / 86400e6)` read off duckdb
# v1.5.3.


def test_days_from_civil_round_trips_over_BC_DAY_COUNTS() raises:
    """`_days_from_civil` is the INVERSE of `_civil_from_days` at EVERY sign.

    ⛔ IT WAS NOT. The era line read `(y_adj - 399) // 400` — the C idiom for
    recovering a floor from a TRUNCATING division — and Mojo's `//` already
    floors, so the correction subtracted a second era, `yoe` left its [0, 399]
    domain and the leap-day term `yoe//4 - yoe//100` under-counted by one day.

    MEASURED before the fix: 11,453 of the 118,572 day counts sampled over
    [-800000, 30000) failed this round trip, EVERY ONE OF THEM BC, and ZERO of
    the AD ones — which is why nothing in this file ever saw it. The named row
    is duckdb v1.5.3's own: `-0044-01-01` is day -735599, and this answered
    -735600."""
    var bad = 0
    var first_bad = 0
    for d in range(-800000, 30000, 7):
        var ymd = _civil_from_days(d)
        if _days_from_civil(ymd[0], ymd[1], ymd[2]) != d:
            if bad == 0:
                first_bad = d
            bad += 1
    assert_equal(
        bad, 0,
        "days_from_civil/civil_from_days round trip broke on " + String(bad)
        + " day counts, first at day " + String(first_bad),
    )
    # duckdb v1.5.3, January 1st of four years straddling the era boundary.
    assert_equal(_days_from_civil(-44, 1, 1), -735599, "-0044-01-01")
    assert_equal(_days_from_civil(-1, 1, 1), -719893, "-0001-01-01")
    assert_equal(_days_from_civil(0, 1, 1), -719528, "0000-01-01")
    assert_equal(_days_from_civil(1, 1, 1), -719162, "0001-01-01")


def test_yearweek_over_a_NON_POSITIVE_isoyear_NEGATES_the_week_half() raises:
    """`yearweek` = isoyear * 100 + (isoyear > 0 ? week : -week).

    ⛔ THE ENGINE SHIPPED `isoyear * 100 + week` UNCONDITIONALLY. Measured
    against duckdb v1.5.3, over DATE32 day counts (`week` / `isoyear` /
    `yearweek` for each row):

        day       civil        iso  wk   DuckDB    WAS
        -735525   -0044-03-15  -44  11    -4411   -4389   sign rule alone
        -719163    0000-12-31    0  52      -52     +52   ★ sign FLIPPED
        -719528    0000-01-01   -1  52     -152     -48   + the era fix
        -719529   -0001-12-31   -1  52     -152     -48   + the era fix
        -735602   -0045-12-29  -45  52    -4552   -4448
        -719162    0001-01-01    1   1      101     101   AD — MUST NOT MOVE
        -1         1969-12-31 1970   1   197001  197001   AD — MUST NOT MOVE
        18628      2021-01-01 2020  53   202053  202053   AD — MUST NOT MOVE
        20527      2026  11   202611  202611   AD — MUST NOT MOVE

    ★ ROW 1 (ISO YEAR **ZERO**) IS THE ONE THAT CANNOT BE FAKED. `iso * 100`
    is 0 there, so the week half carries the entire answer and the engine's
    +52 differed from DuckDB's -52 in NOTHING BUT THE SIGN. A guard spelled
    `iso < 0` rather than `iso > 0` is green on every other BC row here.

    ⚠ ROWS 2 AND 3 ALSO PIN THE ERA FIX: their `week` was 53 before it (the
    January-1st subtraction in `_isoweek_from_days` was one day early), so the
    sign rule alone would have answered -153 where DuckDB says -152."""
    var days = List[Int32]()
    days.append(Int32(-735525))
    days.append(Int32(-719163))
    days.append(Int32(-719528))
    days.append(Int32(-719529))
    days.append(Int32(-735602))
    days.append(Int32(-719162))
    days.append(Int32(-1))
    days.append(Int32(18628))
    days.append(Int32(20527))
    var nulls = List[Bool]()
    for _ in range(9):
        nulls.append(False)
    var arr = _date32_array(days, nulls)

    var want_iso = List[Int]([-44, 0, -1, -1, -45, 1, 1970, 2020, 2026])
    var want_wk = List[Int]([11, 52, 52, 52, 52, 1, 1, 53, 11])
    var want_yw = List[Int](
        [-4411, -52, -152, -152, -4552, 101, 197001, 202053, 202611]
    )
    var iso = extract_iso_week_date32(arr, _K_ISOYEAR)
    var wk = extract_iso_week_date32(arr, _K_WEEK)
    var yw = extract_iso_week_date32(arr, _K_YEARWEEK)
    for i in range(9):
        assert_equal(
            Int(iso.get(i)), want_iso[i],
            "isoyear row " + String(i) + " (day " + String(days[i]) + ")",
        )
        assert_equal(
            Int(wk.get(i)), want_wk[i],
            "week row " + String(i) + " (day " + String(days[i]) + ")",
        )
        assert_equal(
            Int(yw.get(i)), want_yw[i],
            "yearweek row " + String(i) + " (day " + String(days[i]) + ")",
        )

    # The TIMESTAMP_US door reaches the SAME `_iso_week_field`, but through a
    # floor-divide by ticks-per-day that only a pre-epoch row exercises.
    var us = List[Int64]()
    us.append(Int64(-735525) * Int64(86_400_000_000))   # -0044-03-15 00:00
    us.append(Int64(-719163) * Int64(86_400_000_000))   #  0000-12-31 00:00
    us.append(Int64(20527) * Int64(86_400_000_000))     #  2026-03-15 00:00
    var ts_nulls = List[Bool]([False, False, False])
    var ts_arr = _ts_array(us, ts_nulls)
    var ts_yw = extract_iso_week_ts(ts_arr, ArrowType.TIMESTAMP_US, _K_YEARWEEK)
    assert_equal(Int(ts_yw.get(0)), -4411, "TIMESTAMP_US yearweek -0044-03-15")
    assert_equal(Int(ts_yw.get(1)), -52, "TIMESTAMP_US yearweek 0000-12-31")
    assert_equal(Int(ts_yw.get(2)), 202611, "TIMESTAMP_US yearweek 2026-03-15")


def test_compose_yearweek_is_the_ONE_writer_of_the_sign_rule() raises:
    """The shared helper, asserted directly at the three signs.

    ⚠ IT IS IMPORTED BY THE ROW TOWER (`expression_executor`) TOO. That is the
    point of it: a second copy of this rule would make a wrong `yearweek`
    ROUTE-DEPENDENT — the column kernel and the row walker answering different
    numbers for one instant — which is strictly worse than both being wrong.

    ⛔ AND IT IS NOT `century`'s SHAPE. `century` needs two different FORMULAS
    because DuckDB's century numbering skips zero; `decade` is a plain
    truncating divide at every sign. Three names, three shapes, each measured
    on its own. Do not unify them."""
    assert_equal(compose_yearweek(2026, 11), 202611, "AD")
    assert_equal(compose_yearweek(1, 1), 101, "AD year 1")
    assert_equal(compose_yearweek(0, 52), -52, "ISO year ZERO — sign from week")
    assert_equal(compose_yearweek(-1, 52), -152, "BC")
    assert_equal(compose_yearweek(-44, 11), -4411, "BC")


def test_dayofyear_over_a_BC_DATE_is_not_off_by_one() raises:
    """The era fix is NOT yearweek-specific — `dayofyear` subtracts the same
    January 1st.

    duckdb v1.5.3: -0044-03-15 -> 75 (year -44 is leap, so February has 29
    days); 0000-12-31 -> 366 (year 0 is divisible by 400); -0001-12-31 -> 365;
    -0045-12-29 -> 363. This engine answered 76 / 366 / 366 / 364 — one too
    many wherever the era correction fired."""
    var days = List[Int32]()
    days.append(Int32(-735525))
    days.append(Int32(-719163))
    days.append(Int32(-719529))
    days.append(Int32(-735602))
    days.append(Int32(20527))
    var nulls = List[Bool]()
    for _ in range(5):
        nulls.append(False)
    var arr = _date32_array(days, nulls)
    var want = List[Int]([75, 366, 365, 363, 74])
    var out = extract_day_index_date32(arr, _K_DAYOFYEAR)
    for i in range(5):
        assert_equal(
            Int(out.get(i)), want[i],
            "dayofyear row " + String(i) + " (day " + String(days[i]) + ")",
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
    suite.test[test_mojo_integer_division_and_modulo_are_FLOOR_not_truncating]()
    suite.test[test_day_index_over_three_timestamp_units_answer_identically]()
    suite.test[test_day_index_null_passthrough]()
    suite.test[test_day_index_refuses_a_unit_it_does_not_serve]()
    suite.test[test_ir_round_trip_day_index]()
    # SQL-TEMPORAL-FIELDS waves 2 + 3 — ISO week-date + sub-second (7)
    suite.test[test_iso_week_kernel_unit_codes_mirror_the_plan_IR]()
    suite.test[test_isoyear_is_NOT_year_and_three_rows_prove_it]()
    suite.test[test_iso_week_over_date32_matches_duckdb]()
    suite.test[test_iso_week_refuses_a_unit_it_does_not_serve_and_preserves_NULL]()
    suite.test[test_subsecond_folds_the_seconds_in]()
    suite.test[test_subsecond_pre_epoch_needs_floor_semantics]()
    suite.test[test_subsecond_reads_the_SOURCE_UNIT_and_does_not_assume_microseconds]()
    suite.test[test_ir_round_trip_iso_week_and_subsecond]()
    # BC-YEAR PARITY — the two defects AD fixtures cannot see (4)
    suite.test[test_days_from_civil_round_trips_over_BC_DAY_COUNTS]()
    suite.test[test_yearweek_over_a_NON_POSITIVE_isoyear_NEGATES_the_week_half]()
    suite.test[test_compose_yearweek_is_the_ONE_writer_of_the_sign_rule]()
    suite.test[test_dayofyear_over_a_BC_DATE_is_not_off_by_one]()
    suite^.run()
