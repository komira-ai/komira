# =============================================================================
# test_row_projection_math_extract_kerneldirect.mojo — row-typed EXTRACT /
# date-part projection VERIFICATION (kernel-direct).
# =============================================================================
#
# VERIFIES the row-typed projection math+extract batch:
#   * EXTRACT(field FROM temporal) — EXPR_EXTRACT_I64 over a temporal column.
#     The child epoch is read as Int64 (Date32 = i32 days; Date64 = i64 ms);
#     the walker floor-divides by ticks-per-day to recover days-since-1970,
#     runs Howard Hinnant's civil_from_days, and emits the requested calendar
#     (YEAR/QUARTER/MONTH/DAY) or clock (HOUR/MINUTE/SECOND) field as Int64.
#   * The i64->f64 wrap path (the "F64 case") — EXTRACT inside a float-family
#     projection wraps the Int64 field in EXPR_I64_TO_F64.
#
# CONSTRUCTIBILITY: the math fns (ABS/ROUND/FLOOR/CEIL) are
# UNCONSTRUCTIBLE — the IR carries NO MATH_ABS/ROUND/FLOOR/CEIL op code (only
# MATH_SIN/COS/SQRT/ASIN/RADIANS) and there is NO SDK builder for them anywhere.
# So there is no math-fn walker arm to test; only EXTRACT (fully constructible
# via Expr.year/month/day/quarter/hour/minute/second) is covered here.
#
# WHY KERNEL-DIRECT (the whole point):
# ------------------------------------
# `ctx.materialize` / `ctx.read_csv` + `collect` compile the full plan dispatch tree, a large comptime instantiation this test
# avoids. It is FULLY kernel-direct: hand-build a RowBlock, run
# the EXTRACT evaluator over a borrowed `RowCellSource`, assert each output cell
# vs a HAND-COMPUTED oracle — NO `ctx`, NO `read_csv*`, NO `collect`, NO
# `materialize`.
#
# The seam exercised is the EXACT production project-walker kernel
# (the row-streaming project walker calls these evaluators per
# computed cell):
#   * `ExpressionExecutor._eval_i64_from_source[RowCellSource]`  (EXTRACT_I64)
#   * `ExpressionExecutor._eval_f64_from_source[RowCellSource]`  (EXTRACT -> i64_to_f64)
# over a `RowCellSource` borrowing a hand-built `RowBlock`. The walker's only
# additional work over this seam is the cell byte-write + the `_dt_list_to_cell_dt`
# tag mapping (covered by the F64 / passthrough row-projection tests); the
# EXTRACT LOGIC under test lives entirely in the i64 evaluator arm.
#
# Encapsulation: NO UnsafePointer / wildcard origins /
# unsafe_from_address / take_pointee. eval surface only. `fn` style.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_row_format.row_block import RowBlock
from komira_row_format.cell_source import (
    RowCellSource,
    CELL_DT_I32,
    CELL_DT_I64,
)
from komira_eval.expression_executor import ExpressionExecutor
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    make_col,
    make_extract_i64,
    make_i64_to_f64,
    RT_EXTRACT_YEAR,
    RT_EXTRACT_QUARTER,
    RT_EXTRACT_MONTH,
    RT_EXTRACT_DAY,
    RT_EXTRACT_HOUR,
    RT_EXTRACT_MINUTE,
    RT_EXTRACT_SECOND,
    RT_EXTRACT_DAYOFYEAR,
    RT_EXTRACT_WEEK,
    RT_EXTRACT_ISOYEAR,
    RT_EXTRACT_YEARWEEK,
)


# =============================================================================
# Fixture: a 2-column input row layout — col0 = Date32 (i32 days) @ 0,
# col1 = Date64 (i64 ms) @ 8, stride 16 (no validity). CELL_DT col0 = I32,
# col1 = I64 (the date backings the cell source reads via read_i64).
# =============================================================================

comptime _OFF_D32: Int = 0
comptime _OFF_D64: Int = 8
comptime _STRIDE: Int = 16

comptime _MS_PER_DAY: Int64 = 86_400_000


def _build_block(d32_days: List[Int32], d64_ms: List[Int64]) raises -> RowBlock:
    """Hand-build a RowBlock: col0 = Date32 days @ 0 (i32), col1 = Date64 ms @ 8
    (i64), stride 16."""
    var n = len(d32_days)
    var rb = RowBlock.with_capacity(n, 0, _STRIDE)
    for i in range(n):
        rb.write_fixed[DType.int32](i, _OFF_D32, d32_days[i])
        rb.write_fixed[DType.int64](i, _OFF_D64, d64_ms[i])
    rb.set_n_rows(n)
    return rb^


def _offsets() -> List[Int]:
    """Logical col 0 -> Date32 @ 0, col 1 -> Date64 @ 8."""
    var offs = List[Int]()
    offs.append(_OFF_D32)
    offs.append(_OFF_D64)
    return offs^


def _dtypes() -> List[UInt8]:
    """CELL_DT space — Date32 i32-backed, Date64 i64-backed (mirrors the project
    walker's `_dt_list_to_cell_dt` seam: DT_DATE32 -> CELL_DT_I32, DT_DATE64 ->
    CELL_DT_I64)."""
    var dts = List[UInt8]()
    dts.append(CELL_DT_I32)
    dts.append(CELL_DT_I64)
    return dts^


# Days-since-1970 for a few known civil dates (Hinnant days_from_civil):
#   1970-01-01 -> 0
#   1970-02-15 -> 45
#   1999-12-31 -> 10956
#   2000-01-01 -> 10957
#   2024-07-04 -> 19908
#   1969-12-31 -> -1   (pre-epoch, exercises floor-div)
comptime _D_1970_01_01: Int32 = 0
comptime _D_1970_02_15: Int32 = 45
comptime _D_1999_12_31: Int32 = 10956
comptime _D_2000_01_01: Int32 = 10957
comptime _D_2024_07_04: Int32 = 19908
comptime _D_1969_12_31: Int32 = -1


# =============================================================================
# §1 — EXTRACT(YEAR FROM Date32). col0 = Date32 days.
#
# Pool:
#   0: EXPR_COL(col0)                     Date32 i32-day leaf
#   1: EXPR_EXTRACT_I64(child=0, YEAR, tpd=1)  ROOT
# =============================================================================
def test_extract_year_date32() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))                                  # 0
    pool.append(make_extract_i64(0, RT_EXTRACT_YEAR, Int64(1)))  # 1 ROOT

    var d32 = List[Int32]()
    d32.append(_D_1970_01_01); d32.append(_D_1999_12_31)
    d32.append(_D_2000_01_01); d32.append(_D_2024_07_04)
    d32.append(_D_1969_12_31)
    var d64 = List[Int64]()
    for _ in range(len(d32)):
        d64.append(Int64(0))

    var rb = _build_block(d32, d64)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String]())

    var want = List[Int64]()
    want.append(1970); want.append(1999); want.append(2000)
    want.append(2024); want.append(1969)
    for r in range(rb.n_rows):
        var got = exec._eval_i64_from_source(cs, 1, r)
        assert_equal(
            got, want[r],
            "EXTRACT(YEAR) row " + String(r) + " (days=" + String(d32[r]) + ")",
        )


# =============================================================================
# §2 — EXTRACT(MONTH / DAY / QUARTER FROM Date32). Three roots over col0.
# =============================================================================
def test_extract_month_day_quarter_date32() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))                                   # 0 col
    pool.append(make_extract_i64(0, RT_EXTRACT_MONTH, Int64(1)))    # 1 MONTH
    pool.append(make_extract_i64(0, RT_EXTRACT_DAY, Int64(1)))      # 2 DAY
    pool.append(make_extract_i64(0, RT_EXTRACT_QUARTER, Int64(1)))  # 3 QUARTER

    var d32 = List[Int32]()
    d32.append(_D_1970_02_15)  # month 2, day 15, Q1
    d32.append(_D_2024_07_04)  # month 7, day 4,  Q3
    d32.append(_D_1999_12_31)  # month 12, day 31, Q4
    d32.append(_D_2000_01_01)  # month 1, day 1,  Q1
    var d64 = List[Int64]()
    for _ in range(len(d32)):
        d64.append(Int64(0))

    var rb = _build_block(d32, d64)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String]())

    var want_month = List[Int64]()
    want_month.append(2); want_month.append(7); want_month.append(12)
    want_month.append(1)
    var want_day = List[Int64]()
    want_day.append(15); want_day.append(4); want_day.append(31)
    want_day.append(1)
    var want_q = List[Int64]()
    want_q.append(1); want_q.append(3); want_q.append(4); want_q.append(1)

    for r in range(rb.n_rows):
        assert_equal(
            exec._eval_i64_from_source(cs, 1, r), want_month[r],
            "EXTRACT(MONTH) row " + String(r),
        )
        assert_equal(
            exec._eval_i64_from_source(cs, 2, r), want_day[r],
            "EXTRACT(DAY) row " + String(r),
        )
        assert_equal(
            exec._eval_i64_from_source(cs, 3, r), want_q[r],
            "EXTRACT(QUARTER) row " + String(r),
        )


# =============================================================================
# §3 — EXTRACT(YEAR / MONTH / DAY FROM Date64). col1 = Date64 ms (tpd = ms/day).
# Same civil dates as Date32 but stored as milliseconds-since-epoch, so the
# walker floor-divides by 86_400_000 first. Exercises the ticks-per-day path.
# =============================================================================
def test_extract_date64_ms() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(1))                                          # 0 Date64 col
    pool.append(make_extract_i64(0, RT_EXTRACT_YEAR, _MS_PER_DAY))    # 1 YEAR
    pool.append(make_extract_i64(0, RT_EXTRACT_MONTH, _MS_PER_DAY))   # 2 MONTH
    pool.append(make_extract_i64(0, RT_EXTRACT_DAY, _MS_PER_DAY))     # 3 DAY

    var d32 = List[Int32]()
    var d64 = List[Int64]()
    # 2024-07-04 stored as ms-since-epoch (+ a sub-day offset to prove floor).
    d64.append(Int64(_D_2024_07_04) * _MS_PER_DAY + Int64(12_345))
    # 1999-12-31.
    d64.append(Int64(_D_1999_12_31) * _MS_PER_DAY)
    # 1970-01-01.
    d64.append(Int64(_D_1970_01_01) * _MS_PER_DAY)
    for _ in range(len(d64)):
        d32.append(Int32(0))

    var rb = _build_block(d32, d64)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String]())

    var want_year = List[Int64]()
    want_year.append(2024); want_year.append(1999); want_year.append(1970)
    var want_month = List[Int64]()
    want_month.append(7); want_month.append(12); want_month.append(1)
    var want_day = List[Int64]()
    want_day.append(4); want_day.append(31); want_day.append(1)

    for r in range(rb.n_rows):
        assert_equal(
            exec._eval_i64_from_source(cs, 1, r), want_year[r],
            "Date64 EXTRACT(YEAR) row " + String(r),
        )
        assert_equal(
            exec._eval_i64_from_source(cs, 2, r), want_month[r],
            "Date64 EXTRACT(MONTH) row " + String(r),
        )
        assert_equal(
            exec._eval_i64_from_source(cs, 3, r), want_day[r],
            "Date64 EXTRACT(DAY) row " + String(r),
        )


# =============================================================================
# §4 — EXTRACT(HOUR / MINUTE / SECOND FROM Date64). Clock fields read the
# within-day remainder. col1 = Date64 ms.
# =============================================================================
def test_extract_clock_fields_date64() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(1))                                           # 0 Date64
    pool.append(make_extract_i64(0, RT_EXTRACT_HOUR, _MS_PER_DAY))     # 1 HOUR
    pool.append(make_extract_i64(0, RT_EXTRACT_MINUTE, _MS_PER_DAY))   # 2 MINUTE
    pool.append(make_extract_i64(0, RT_EXTRACT_SECOND, _MS_PER_DAY))   # 3 SECOND

    # 2024-07-04 at 13:37:42 (= 13*3600 + 37*60 + 42 = 49062 s).
    var secs_of_day = Int64(13) * 3600 + Int64(37) * 60 + Int64(42)
    var ms = Int64(_D_2024_07_04) * _MS_PER_DAY + secs_of_day * 1000

    var d32 = List[Int32]()
    var d64 = List[Int64]()
    d32.append(Int32(0))
    d64.append(ms)

    var rb = _build_block(d32, d64)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String]())

    assert_equal(exec._eval_i64_from_source(cs, 1, 0), Int64(13), "HOUR")
    assert_equal(exec._eval_i64_from_source(cs, 2, 0), Int64(37), "MINUTE")
    assert_equal(exec._eval_i64_from_source(cs, 3, 0), Int64(42), "SECOND")


# =============================================================================
# §5 — EXTRACT(YEAR FROM Date32) wrapped in an i64->f64 cast (the "F64 case":
# EXTRACT inside a float-family projection). Pool root is EXPR_I64_TO_F64 over
# the EXTRACT node; the f64 evaluator widens the Int64 year to Float64.
#
# Pool:
#   0: EXPR_COL(col0)
#   1: EXPR_EXTRACT_I64(child=0, YEAR, tpd=1)
#   2: EXPR_I64_TO_F64(child=1)   ROOT (f64)
# =============================================================================
def test_extract_year_to_f64() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))                                      # 0
    pool.append(make_extract_i64(0, RT_EXTRACT_YEAR, Int64(1)))   # 1
    pool.append(make_i64_to_f64(1))                               # 2 ROOT

    var d32 = List[Int32]()
    d32.append(_D_2024_07_04); d32.append(_D_1999_12_31)
    d32.append(_D_1970_01_01)
    var d64 = List[Int64]()
    for _ in range(len(d32)):
        d64.append(Int64(0))

    var rb = _build_block(d32, d64)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 2, List[String]())

    var want = List[Float64]()
    want.append(2024.0); want.append(1999.0); want.append(1970.0)
    for r in range(rb.n_rows):
        var got = exec._eval_f64_from_source(cs, 2, r)
        assert_true(
            (got - want[r]) < 1e-9 and (want[r] - got) < 1e-9,
            "EXTRACT(YEAR)->f64 row " + String(r) + ": got " + String(got),
        )



# =============================================================================
# §6 — BC-YEAR PARITY. The ISO week-date family over a
# NON-POSITIVE ISO year, through the ROW TOWER.
# =============================================================================
#
# ⛔⛔ THIS SECTION EXISTS BECAUSE THE ROW TOWER IS A SECOND IMPLEMENTATION,
# NOT A SECOND CALLER. `expression_executor._eval_i64_from_source` re-derives
# the whole calendar locally (`_ee_civil_from_days` / `_ee_days_from_civil`),
# deliberately, so the per-cell walker pays no cross-module call — which means
# a fix applied to `temporal_extract` alone leaves this door answering the OLD
# number, and a wrong answer that depends on WHICH EXECUTOR RAN is worse than
# one that is uniformly wrong. Every row below was also asserted against the
# column kernel in `komira_compiler.tests.test_temporal_extract`; the two
# lists are the same numbers on purpose.
#
# ⚠ RAW DAY LITERALS, NOT `date_to_days(...)`: that helper carries the same
# era idiom the walker's own helper avoids, and is one day short for a BC year.
# Each literal is `floor(epoch_us(make_timestamp(y,m,d,0,0,0.0)) / 86400e6)`
# read off duckdb v1.5.3.

comptime _D_BC44_03_15: Int32 = -735525   # -0044-03-15  iso -44 wk 11
comptime _D_0000_12_31: Int32 = -719163   #  0000-12-31  iso   0 wk 52
comptime _D_0000_01_01: Int32 = -719528   #  0000-01-01  iso  -1 wk 52
comptime _D_BC01_12_31: Int32 = -719529   # -0001-12-31  iso  -1 wk 52
comptime _D_BC45_12_29: Int32 = -735602   # -0045-12-29  iso -45 wk 52
comptime _D_0001_01_01: Int32 = -719162   #  0001-01-01  iso   1 wk  1
comptime _D_2021_01_01: Int32 = 18628     #  2021-01-01  iso 2020 wk 53
comptime _D_2026_03_15: Int32 = 20527     #  2026-03-15  iso 2026 wk 11


def test_row_yearweek_over_a_NON_POSITIVE_isoyear_negates_the_week_half() raises:
    """`yearweek` = isoyear * 100 + (isoyear > 0 ? week : -week), measured on
    duckdb v1.5.3 — through the ROW walker.

        day       civil        iso  wk   DuckDB    WAS
        -735525   -0044-03-15  -44  11    -4411   -4389
        -719163    0000-12-31    0  52      -52     +52   ★ sign FLIPPED
        -719528    0000-01-01   -1  52     -152     -48
        -719529   -0001-12-31   -1  52     -152     -48
        -735602   -0045-12-29  -45  52    -4552   -4448
        -719162    0001-01-01    1   1      101     101   AD — MUST NOT MOVE
        18628      2021-01-01 2020  53   202053  202053   AD — MUST NOT MOVE
        20527      2026-03-15 2026  11   202611  202611   AD — MUST NOT MOVE

    ★ THE ISO-YEAR-**ZERO** ROW IS THE UNFAKEABLE ONE: `iso * 100` is 0, so
    the week half is the whole answer and the old code differed from DuckDB in
    nothing but the sign.

    ⚠ THE `week` COLUMN IS ASSERTED TOO, and it is not redundant: with a wrong
    era rule in `_ee_days_from_civil` rows 3 and 4 answer 53, so the sign rule
    ALONE would produce -153 here, not -152.

    Pool: 0 = col0 (Date32 days), 1 = ISOYEAR, 2 = WEEK, 3 = YEARWEEK."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))                                       # 0 col
    pool.append(make_extract_i64(0, RT_EXTRACT_ISOYEAR, Int64(1)))   # 1
    pool.append(make_extract_i64(0, RT_EXTRACT_WEEK, Int64(1)))      # 2
    pool.append(make_extract_i64(0, RT_EXTRACT_YEARWEEK, Int64(1)))  # 3

    var d32 = List[Int32]()
    d32.append(_D_BC44_03_15); d32.append(_D_0000_12_31)
    d32.append(_D_0000_01_01); d32.append(_D_BC01_12_31)
    d32.append(_D_BC45_12_29); d32.append(_D_0001_01_01)
    d32.append(_D_2021_01_01); d32.append(_D_2026_03_15)
    var d64 = List[Int64]()
    for _ in range(len(d32)):
        d64.append(Int64(0))

    var rb = _build_block(d32, d64)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 3, List[String]())

    var want_iso = List[Int64]()
    want_iso.append(-44); want_iso.append(0); want_iso.append(-1)
    want_iso.append(-1); want_iso.append(-45); want_iso.append(1)
    want_iso.append(2020); want_iso.append(2026)
    var want_wk = List[Int64]()
    want_wk.append(11); want_wk.append(52); want_wk.append(52)
    want_wk.append(52); want_wk.append(52); want_wk.append(1)
    want_wk.append(53); want_wk.append(11)
    var want_yw = List[Int64]()
    want_yw.append(-4411); want_yw.append(-52); want_yw.append(-152)
    want_yw.append(-152); want_yw.append(-4552); want_yw.append(101)
    want_yw.append(202053); want_yw.append(202611)

    for r in range(rb.n_rows):
        assert_equal(
            exec._eval_i64_from_source(cs, 1, r), want_iso[r],
            "row ISOYEAR row " + String(r) + " (day " + String(d32[r]) + ")",
        )
        assert_equal(
            exec._eval_i64_from_source(cs, 2, r), want_wk[r],
            "row WEEK row " + String(r) + " (day " + String(d32[r]) + ")",
        )
        assert_equal(
            exec._eval_i64_from_source(cs, 3, r), want_yw[r],
            "row YEARWEEK row " + String(r) + " (day " + String(d32[r]) + ")",
        )


def test_row_dayofyear_over_a_BC_date_is_not_off_by_one() raises:
    """`_ee_days_from_civil`'s era line must not apply the C floor idiom over a
    `//` that ALREADY floors: that subtracts a second era and every BC day
    count comes back one day short.

    duckdb v1.5.3: -0044-03-15 -> 75 (year -44 is leap); 0000-12-31 -> 366
    (year 0 is divisible by 400); -0001-12-31 -> 365; -0045-12-29 -> 363;
    2026-03-15 -> 74. The double-era bug answers 76 / 366 / 366 / 364 / 74 —
    one too many wherever the era correction fires, and CORRECT on the AD
    row, which is why an AD-only fixture cannot see it."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))                                        # 0 col
    pool.append(make_extract_i64(0, RT_EXTRACT_DAYOFYEAR, Int64(1)))  # 1 ROOT

    var d32 = List[Int32]()
    d32.append(_D_BC44_03_15); d32.append(_D_0000_12_31)
    d32.append(_D_BC01_12_31); d32.append(_D_BC45_12_29)
    d32.append(_D_2026_03_15)
    var d64 = List[Int64]()
    for _ in range(len(d32)):
        d64.append(Int64(0))

    var rb = _build_block(d32, d64)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String]())

    var want = List[Int64]()
    want.append(75); want.append(366); want.append(365)
    want.append(363); want.append(74)
    for r in range(rb.n_rows):
        assert_equal(
            exec._eval_i64_from_source(cs, 1, r), want[r],
            "row DAYOFYEAR row " + String(r) + " (day " + String(d32[r]) + ")",
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_extract_year_date32]()
    suite.test[test_extract_month_day_quarter_date32]()
    suite.test[test_extract_date64_ms]()
    suite.test[test_extract_clock_fields_date64]()
    suite.test[test_extract_year_to_f64]()
    # §6 BC-year parity — the row tower's own copy of the calendar (2)
    suite.test[test_row_yearweek_over_a_NON_POSITIVE_isoyear_negates_the_week_half]()
    suite.test[test_row_dayofyear_over_a_BC_date_is_not_off_by_one]()
    suite^.run()
